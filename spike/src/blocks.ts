import { syntaxTree } from "@codemirror/language";
import { EditorState, Range, StateField } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { SyntaxNode, Tree } from "@lezer/common";
import { renderInline } from "./inline";
import { focusField, revealed } from "./reveal";

type Block =
  | { kind: "fence"; from: number; to: number; open: [number, number]; close: [number, number] | null }
  | { kind: "table"; from: number; to: number; node: SyntaxNode }
  | { kind: "rule"; from: number; to: number }
  | { kind: "setext"; from: number; to: number; underline: [number, number] };

const containers = new Set(["Document", "BulletList", "OrderedList", "ListItem", "Blockquote"]);
const hideLine = Decoration.replace({ block: true });

export const blockStats = { scans: 0, lastScanMs: 0 };

function scan(state: EditorState, tree: Tree): Block[] {
  const t0 = performance.now();
  const doc = state.doc;
  const blocks: Block[] = [];
  const lineOf = (pos: number): [number, number] => {
    const line = doc.lineAt(pos);
    return [line.from, line.to];
  };
  // Block-level constructs only appear at the top level or inside containers,
  // so the walk never descends into paragraphs or inline content.
  tree.iterate({
    enter: (ref) => {
      if (containers.has(ref.name)) return;
      const node = ref.node;
      switch (ref.name) {
        case "FencedCode": {
          const marks = node.getChildren("CodeMark");
          const open = lineOf(node.from);
          const closeMark = marks.length > 1 ? marks[marks.length - 1] : null;
          const close = closeMark ? lineOf(closeMark.from) : null;
          blocks.push({ kind: "fence", from: node.from, to: node.to, open, close: close && close[0] > open[1] ? close : null });
          break;
        }
        case "Table":
          blocks.push({ kind: "table", from: lineOf(node.from)[0], to: lineOf(node.to)[1], node });
          break;
        case "HorizontalRule": {
          const [from, to] = lineOf(node.from);
          if (doc.sliceString(from, to).trim() === doc.sliceString(node.from, node.to).trim()) {
            blocks.push({ kind: "rule", from, to });
          }
          break;
        }
        case "SetextHeading1":
        case "SetextHeading2": {
          const mark = node.getChild("HeaderMark");
          if (mark) blocks.push({ kind: "setext", from: node.from, to: node.to, underline: lineOf(mark.from) });
          break;
        }
      }
      return false;
    },
  });
  blockStats.scans++;
  blockStats.lastScanMs = performance.now() - t0;
  return blocks;
}

class RuleWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const div = document.createElement("div");
    div.className = "cm-md-rule";
    div.append(document.createElement("hr"));
    return div;
  }
  get estimatedHeight() {
    return 24;
  }
}

class TableWidget extends WidgetType {
  constructor(readonly source: string, readonly node: SyntaxNode, readonly start: number) {
    super();
  }
  eq(other: TableWidget) {
    return other.source === this.source;
  }
  get estimatedHeight() {
    return this.source.split("\n").length * 36;
  }
  toDOM(view: EditorView) {
    const wrap = document.createElement("div");
    wrap.className = "cm-md-table";
    const table = document.createElement("table");
    wrap.append(table);
    const align = alignments(this.node, this.source, this.start);
    for (let row = this.node.firstChild; row; row = row.nextSibling) {
      if (row.name !== "TableHeader" && row.name !== "TableRow") continue;
      const tr = document.createElement("tr");
      let column = 0;
      for (const cell of row.getChildren("TableCell")) {
        const td = document.createElement(row.name === "TableHeader" ? "th" : "td");
        if (align[column]) td.style.textAlign = align[column];
        // Offsets are relative because eq() can keep this DOM across edits
        // that shift the table without changing it.
        td.dataset.offset = String(cell.to - this.start);
        renderInline(this.source, cell, cell.from, cell.to, td, this.start);
        tr.append(td);
        column++;
      }
      table.append(tr);
    }
    wrap.addEventListener("mousedown", (event) => {
      const cell = (event.target as HTMLElement).closest<HTMLElement>("td,th");
      event.preventDefault();
      const base = view.posAtDOM(wrap);
      const anchor = base + Number(cell?.dataset.offset ?? 0);
      view.dispatch({ selection: { anchor } });
      view.focus();
    });
    return wrap;
  }
  ignoreEvent() {
    return true;
  }
}

function alignments(node: SyntaxNode, source: string, start: number): string[] {
  const delimiter = node.getChildren("TableDelimiter")[0];
  if (!delimiter) return [];
  return source
    .slice(delimiter.from - start, delimiter.to - start)
    .split("|")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((s) => (s.startsWith(":") && s.endsWith(":") ? "center" : s.endsWith(":") ? "right" : s.startsWith(":") ? "left" : ""));
}

function decorate(state: EditorState, blocks: Block[]): DecorationSet {
  const out: Range<Decoration>[] = [];
  for (const block of blocks) {
    if (revealed(state, block.from, block.to)) continue;
    switch (block.kind) {
      case "fence":
        out.push(hideLine.range(block.open[0], block.open[1]));
        if (block.close) out.push(hideLine.range(block.close[0], block.close[1]));
        break;
      case "table":
        out.push(
          Decoration.replace({ block: true, widget: new TableWidget(state.doc.sliceString(block.from, block.to), block.node, block.from) }).range(
            block.from,
            block.to,
          ),
        );
        break;
      case "rule":
        out.push(Decoration.replace({ block: true, widget: new RuleWidget() }).range(block.from, block.to));
        break;
      case "setext":
        out.push(hideLine.range(block.underline[0], block.underline[1]));
        break;
    }
  }
  return Decoration.set(out, true);
}

interface BlockState {
  tree: Tree;
  blocks: Block[];
  decorations: DecorationSet;
}

export const blockField = StateField.define<BlockState>({
  create(state) {
    const tree = syntaxTree(state);
    const blocks = scan(state, tree);
    return { tree, blocks, decorations: decorate(state, blocks) };
  },
  update(value, tr) {
    const tree = syntaxTree(tr.state);
    const treeChanged = tree !== value.tree;
    if (
      !treeChanged &&
      !tr.selection &&
      tr.startState.field(focusField, false) === tr.state.field(focusField, false)
    ) {
      return value;
    }
    const blocks = treeChanged ? scan(tr.state, tree) : value.blocks;
    return { tree, blocks, decorations: decorate(tr.state, blocks) };
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
});
