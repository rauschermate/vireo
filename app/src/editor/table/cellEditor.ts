import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, Prec, Transaction, TransactionSpec } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { livePreview } from "../livePreview";
import { vireoMarkdown } from "../markdown";
import { focusTracking } from "../reveal";
import { cellFormatting } from "../toolbar";
import { Align, escapeCell, Grid, insertColumn, insertRow, parseTable, removeColumn, removeRow, serialize, setAlign, Table, toGrid } from "./model";

// One cell is edited at a time, in a small nested CodeMirror that runs the
// same live preview and formatting as the document. A commit turns into one
// change in the outer document, so outer undo and file parity keep working.

type Nav = "finish" | "next" | "previous" | "down" | "cancel";

// The source each rendered table was drawn from, for reopening a cell after
// a commit replaced the widget.
export const tableSources = new WeakMap<HTMLElement, string>();

function tableDomAt(outer: EditorView, from: number): HTMLElement | null {
  for (const el of outer.contentDOM.querySelectorAll<HTMLElement>(".cm-md-table")) {
    if (outer.posAtDOM(el) === from) return el;
  }
  return null;
}

function reopen(outer: EditorView, from: number, row: number, col: number) {
  requestAnimationFrame(() => {
    const wrap = tableDomAt(outer, from);
    if (wrap) openCellEditor(outer, wrap, row, col);
  });
}

// Paste and dictation can bring newlines; a cell holds a single line.
const singleLine = EditorState.transactionFilter.of((tr: Transaction) => {
  if (!tr.docChanged || tr.newDoc.lines === 1) return tr;
  const changes: { from: number; to: number; insert: string }[] = [];
  tr.changes.iterChanges((from, to, _fb, _tb, inserted) => changes.push({ from, to, insert: inserted.toString().replace(/\r?\n|\r/g, " ") }));
  return { changes, selection: tr.selection, userEvent: tr.annotation(Transaction.userEvent) } as TransactionSpec;
});

// The cell editor sits inside the document editor, whose theme rules are
// descendant selectors. "&.cm-editor" outranks them, so the document's
// padding and width do not leak into the cell.
const cellTheme = EditorView.theme({
  "&.cm-editor": { fontSize: "inherit", background: "transparent", height: "auto" },
  "&.cm-editor.cm-focused": { outline: "none" },
  "&.cm-editor .cm-scroller": { fontFamily: "inherit", lineHeight: "inherit", overflow: "visible" },
  "&.cm-editor .cm-content": { padding: "0", margin: "0", maxWidth: "none", caretColor: "var(--fg)" },
  "&.cm-editor .cm-line": { padding: "0" },
});

interface MenuItem {
  label: string;
  enabled?: boolean;
  checked?: boolean;
  run: () => void;
}

function showMenu(anchor: HTMLElement, groups: MenuItem[][], onClose: () => void) {
  const menu = document.createElement("div");
  menu.className = "cm-vireo-menu";
  menu.setAttribute("role", "menu");
  groups.forEach((group, g) => {
    if (g > 0) menu.append(Object.assign(document.createElement("div"), { className: "cm-vireo-menu-sep" }));
    for (const item of group) {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.textContent = (item.checked ? "✓ " : "") + item.label;
      b.disabled = item.enabled === false;
      b.addEventListener("mousedown", (e) => e.preventDefault());
      b.addEventListener("click", () => item.run());
      menu.append(b);
    }
  });
  document.body.append(menu);
  const r = anchor.getBoundingClientRect();
  menu.style.left = `${Math.min(r.left, window.innerWidth - menu.offsetWidth - 8)}px`;
  const below = r.bottom + 4 + menu.offsetHeight <= window.innerHeight - 8;
  menu.style.top = `${below ? r.bottom + 4 : Math.max(8, r.top - 4 - menu.offsetHeight)}px`;
  const outside = (e: MouseEvent) => {
    if (!menu.contains(e.target as Node) && e.target !== anchor) close();
  };
  const close = () => {
    menu.remove();
    document.removeEventListener("mousedown", outside, true);
    onClose();
  };
  document.addEventListener("mousedown", outside, true);
  return { el: menu, close };
}

export function openCellEditor(outer: EditorView, wrap: HTMLElement, row: number, col: number) {
  const source = tableSources.get(wrap);
  if (source == null) return;
  const from = outer.posAtDOM(wrap);
  const table: Table = parseTable(source, from);
  const columns = table.align.length;
  const td = wrap.querySelectorAll("tr")[row]?.children[col] as HTMLElement | undefined;
  if (!td || col >= columns) return;
  const cell = table.rows[row]?.[col];
  const original = cell?.text ?? "";
  const rendered = [...td.childNodes];
  td.classList.add("is-editing");
  td.replaceChildren();

  let done = false;
  let menu: { el: HTMLElement; close: () => void } | null = null;
  const unchanged = () => outer.state.sliceDoc(from, from + source.length) === source;
  const restore = () => {
    td.classList.remove("is-editing");
    td.replaceChildren(...rendered);
  };
  const take = () => {
    done = true;
    const text = escapeCell(cellView.state.doc.toString());
    menu?.close();
    cellView.destroy();
    return text;
  };

  const rewrite = (grid: Grid) => outer.dispatch({ changes: { from, to: from + source.length, insert: serialize(grid) }, userEvent: "input.table" });

  const finish = (nav: Nav) => {
    if (done) return;
    const text = take();
    if (nav === "cancel" || !unchanged()) {
      restore();
      if (nav === "cancel") outer.focus();
      return;
    }
    const rows = table.rows.length;
    const needsRow = (nav === "next" && row === rows - 1 && col === columns - 1) || (nav === "down" && row === rows - 1);
    if (needsRow || !cell) {
      let grid = toGrid(table);
      grid.rows[row][col] = text;
      if (needsRow) grid = insertRow(grid, grid.rows.length);
      rewrite(grid);
      if (needsRow) reopen(outer, from, grid.rows.length - 1, nav === "next" ? 0 : col);
      return;
    }
    if (text !== original) {
      outer.dispatch({ changes: { from: cell.from, to: cell.to, insert: cell.empty ? ` ${text} ` : text }, userEvent: "input.table" });
    } else {
      restore();
    }
    const flat = row * columns + col;
    const next =
      nav === "next" ? [Math.floor((flat + 1) / columns), (flat + 1) % columns]
      : nav === "previous" ? [Math.floor(Math.max(0, flat - 1) / columns), Math.max(0, flat - 1) % columns]
      : nav === "down" ? [Math.min(rows - 1, row + 1), col]
      : null;
    if (next) reopen(outer, from, next[0], next[1]);
  };

  const act = (change: (g: Grid) => Grid, next: [number, number] | null) => {
    if (done || !unchanged()) return;
    const text = take();
    const grid = toGrid(table);
    grid.rows[row][col] = text;
    rewrite(change(grid));
    if (next) reopen(outer, from, next[0], next[1]);
    else outer.focus();
  };

  const align = (a: Align): MenuItem => ({
    label: a === "left" ? "Align Left" : a === "center" ? "Align Center" : "Align Right",
    checked: table.align[col] === a,
    run: () => act((g) => setAlign(g, col, a), [row, col]),
  });

  const menuButton = document.createElement("button");
  menuButton.type = "button";
  menuButton.className = "cm-md-cell-menu";
  menuButton.textContent = "⋯";
  menuButton.title = "Table cell actions";
  menuButton.setAttribute("aria-label", "Table cell actions");
  menuButton.addEventListener("mousedown", (e) => e.preventDefault());
  menuButton.addEventListener("click", () => {
    if (menu) return menu.close();
    const rows = table.rows.length;
    menu = showMenu(
      menuButton,
      [
        [
          { label: "Add Row Above", run: () => act((g) => insertRow(g, row), [Math.max(1, row), col]) },
          { label: "Add Row Below", run: () => act((g) => insertRow(g, row + 1), [row + 1, col]) },
          { label: "Delete Row", enabled: row > 0, run: () => act((g) => removeRow(g, row), [Math.min(row, rows - 2), col]) },
        ],
        [
          { label: "Add Column Left", run: () => act((g) => insertColumn(g, col), [row, col]) },
          { label: "Add Column Right", run: () => act((g) => insertColumn(g, col + 1), [row, col + 1]) },
          { label: "Delete Column", enabled: columns > 1, run: () => act((g) => removeColumn(g, col), [row, Math.min(col, columns - 2)]) },
        ],
        [align("left"), align("center"), align("right")],
        [
          {
            label: "Delete Table",
            run: () => {
              if (done || !unchanged()) return;
              take();
              const end = outer.state.sliceDoc(from + source.length, from + source.length + 1) === "\n" ? from + source.length + 1 : from + source.length;
              outer.dispatch({ changes: { from, to: end }, selection: { anchor: from }, userEvent: "delete.table" });
              outer.focus();
            },
          },
        ],
      ],
      () => (menu = null),
    );
  });

  const cellView: EditorView = new EditorView({
    parent: td,
    state: EditorState.create({
      doc: original,
      selection: EditorSelection.cursor(original.length),
      extensions: [
        Prec.highest(
          keymap.of([
            { key: "Tab", run: () => (finish("next"), true) },
            { key: "Shift-Tab", run: () => (finish("previous"), true) },
            { key: "Enter", run: () => (finish("down"), true) },
            { key: "Escape", run: () => (finish("cancel"), true) },
          ]),
        ),
        history(),
        keymap.of([...defaultKeymap, ...historyKeymap]),
        new LanguageSupport(vireoMarkdown),
        focusTracking,
        livePreview,
        cellFormatting,
        singleLine,
        EditorView.lineWrapping,
        EditorView.contentAttributes.of({ spellcheck: "true", autocorrect: "on" }),
        cellTheme,
      ],
    }),
  });
  td.append(menuButton);

  // Leaving the cell commits it, unless focus only moved to its own toolbar,
  // link editor or menu.
  cellView.dom.addEventListener("focusout", (e) => {
    const next = e.relatedTarget as Node | null;
    if (next && (cellView.dom.contains(next) || menu?.el.contains(next))) return;
    finish("finish");
  });
  cellView.focus();
}
