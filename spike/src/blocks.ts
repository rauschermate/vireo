import { markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxTree } from "@codemirror/language";
import { ChangeDesc, EditorSelection, EditorState, Range, StateField } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { SyntaxNode, Tree } from "@lezer/common";
import { renderInline } from "./inline";
import { focusField } from "./reveal";

type Block =
  | { kind: "fence"; from: number; to: number; open: [number, number]; close: [number, number] | null }
  | { kind: "table"; from: number; to: number }
  | { kind: "rule"; from: number; to: number }
  | { kind: "setext"; from: number; to: number; underline: [number, number] };

const containers = new Set(["Document", "BulletList", "OrderedList", "ListItem", "Blockquote"]);
const hideLine = Decoration.replace({ block: true });

export const blockStats = { lastUpdateMs: 0, blocks: 0, rescanned: 0 };

function scan(state: EditorState, tree: Tree, from: number, to: number): Block[] {
  const doc = state.doc;
  const blocks: Block[] = [];
  const lineOf = (pos: number): [number, number] => {
    const line = doc.lineAt(pos);
    return [line.from, line.to];
  };
  // Block-level constructs only appear at the top level or inside containers,
  // so the walk never descends into paragraphs or inline content.
  tree.iterate({
    from,
    to,
    enter: (ref) => {
      if (containers.has(ref.name)) return;
      if (ref.from < from || ref.to > to) return false;
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
          blocks.push({ kind: "table", from: lineOf(node.from)[0], to: lineOf(node.to)[1] });
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
  return blocks;
}

function mapBlock(block: Block, changes: ChangeDesc): Block {
  const m = (pos: number) => changes.mapPos(pos);
  const pair = (p: [number, number]): [number, number] => [m(p[0]), m(p[1])];
  switch (block.kind) {
    case "fence":
      return { ...block, from: m(block.from), to: m(block.to), open: pair(block.open), close: block.close && pair(block.close) };
    case "setext":
      return { ...block, from: m(block.from), to: m(block.to), underline: pair(block.underline) };
    default:
      return { ...block, from: m(block.from), to: m(block.to) };
  }
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

// The widget re-parses its own source. That keeps it independent of the
// document tree, which is partial and changes on every edit.
class TableWidget extends WidgetType {
  constructor(readonly source: string) {
    super();
  }
  eq(other: TableWidget) {
    return other.source === this.source;
  }
  get estimatedHeight() {
    return this.source.split("\n").length * 38 - 2;
  }
  toDOM(view: EditorView) {
    const wrap = document.createElement("div");
    wrap.className = "cm-md-table";
    const table = document.createElement("table");
    wrap.append(table);
    const node = markdownLanguage.parser.parse(this.source).topNode.getChild("Table");
    if (node) fillTable(table, node, this.source);
    wrap.addEventListener("mousedown", (event) => {
      const cell = (event.target as HTMLElement).closest<HTMLElement>("td,th");
      event.preventDefault();
      const anchor = view.posAtDOM(wrap) + Number(cell?.dataset.offset ?? 0);
      view.dispatch({ selection: { anchor } });
      view.focus();
    });
    return wrap;
  }
  ignoreEvent() {
    return true;
  }
}

function fillTable(table: HTMLTableElement, node: SyntaxNode, source: string) {
  const align = alignments(node, source);
  for (let row = node.firstChild; row; row = row.nextSibling) {
    if (row.name !== "TableHeader" && row.name !== "TableRow") continue;
    const tr = document.createElement("tr");
    row.getChildren("TableCell").forEach((cell, column) => {
      const td = document.createElement(row.name === "TableHeader" ? "th" : "td");
      if (align[column]) td.style.textAlign = align[column];
      td.dataset.offset = String(cell.to);
      renderInline(source, cell, cell.from, cell.to, td);
      tr.append(td);
    });
    table.append(tr);
  }
}

function alignments(node: SyntaxNode, source: string): string[] {
  const delimiter = node.getChildren("TableDelimiter")[0];
  if (!delimiter) return [];
  return source
    .slice(delimiter.from, delimiter.to)
    .split("|")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((s) => (s.startsWith(":") && s.endsWith(":") ? "center" : s.endsWith(":") ? "right" : s.startsWith(":") ? "left" : ""));
}

function decorationsFor(state: EditorState, block: Block, sel: EditorSelection | null): Range<Decoration>[] {
  if (sel && touches(sel, block)) return [];
  switch (block.kind) {
    case "fence":
      return block.close
        ? [hideLine.range(block.open[0], block.open[1]), hideLine.range(block.close[0], block.close[1])]
        : [hideLine.range(block.open[0], block.open[1])];
    case "table":
      return [Decoration.replace({ block: true, widget: new TableWidget(state.doc.sliceString(block.from, block.to)) }).range(block.from, block.to)];
    case "rule":
      return [Decoration.replace({ block: true, widget: new RuleWidget() }).range(block.from, block.to)];
    case "setext":
      return [hideLine.range(block.underline[0], block.underline[1])];
  }
}

function touches(sel: EditorSelection, block: Block): boolean {
  for (const r of sel.ranges) if (r.from <= block.to && r.to >= block.from) return true;
  return false;
}

// The selection that reveals blocks, or null while the editor is unfocused.
const revealing = (state: EditorState) => (state.field(focusField, false) ? state.selection : null);

interface BlockState {
  tree: Tree;
  blocks: Block[];
  decorations: DecorationSet;
}

// Expands a range to whole top-level blocks of the new tree, so a rescan
// never sees half a construct.
function expand(tree: Tree, from: number, to: number): [number, number] {
  // These pick the blocks that contain `from` and `to`, or the neighbors when
  // a position sits between blocks. The obvious childBefore(from) and
  // childAfter(to) step one block further out on each call, so `cover` would
  // walk to both ends of the document.
  const before = tree.topNode.childBefore(from + 1);
  const after = tree.topNode.childAfter(Math.max(0, to - 1));
  return [before ? Math.min(before.from, from) : 0, after ? Math.max(after.to, to) : Math.max(tree.length, to)];
}

// Index range [i, j) of the sorted, disjoint blocks that overlap [from, to].
function overlapping(blocks: Block[], from: number, to: number): [number, number] {
  let lo = 0;
  let hi = blocks.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (blocks[mid].to < from) lo = mid + 1;
    else hi = mid;
  }
  let j = lo;
  while (j < blocks.length && blocks[j].from <= to) j++;
  return [lo, j];
}

// An edit can change how any later part of the file parses. Closing a fence
// early inside a list ends the list sooner, and the paragraph after it can
// become a table. Like Lezer itself, grow the range until both edges are
// top-level block starts in the old and the new tree. From such a point on,
// both parses read the same text in the same state, so nothing past it
// differs.
function cover(tree: Tree, oldTree: Tree, toOld: ChangeDesc | null, from: number, to: number): [number, number] {
  const synced = (pos: number) => {
    if (!toOld || pos >= tree.length) return true;
    const old = toOld.mapPos(pos);
    if (old >= oldTree.length) return true;
    const child = oldTree.topNode.childAfter(old);
    return !child || child.from === old;
  };
  let [a, b] = expand(tree, from, to);
  while (a > 0 && !synced(a)) a = tree.topNode.childBefore(a)?.from ?? 0;
  for (;;) {
    const next = tree.topNode.childAfter(b);
    if (!next) {
      b = Math.max(b, tree.length);
      break;
    }
    if (synced(next.from)) break;
    b = next.to;
  }
  return [a, Math.min(b, Math.max(tree.length, to))];
}

function merge(ranges: [number, number][]): [number, number][] {
  ranges.sort((a, b) => a[0] - b[0]);
  const out: [number, number][] = [];
  for (const r of ranges) {
    const last = out[out.length - 1];
    if (last && r[0] <= last[1] + 1) last[1] = Math.max(last[1], r[1]);
    else out.push([r[0], r[1]]);
  }
  return out;
}

export const blockField = StateField.define<BlockState>({
  create(state) {
    const tree = syntaxTree(state);
    const blocks = scan(state, tree, 0, tree.length);
    const sel = revealing(state);
    return { tree, blocks, decorations: Decoration.set(blocks.flatMap((b) => decorationsFor(state, b, sel)), true) };
  },
  update(value, tr) {
    const tree = syntaxTree(tr.state);
    const oldSel = revealing(tr.startState);
    const newSel = revealing(tr.state);
    if (!tr.docChanged && tree === value.tree && oldSel === newSel) return value;
    const t0 = performance.now();

    let { blocks, decorations } = value;
    const dirty: [number, number][] = [];
    if (tr.docChanged) {
      blocks = blocks.map((b) => mapBlock(b, tr.changes));
      decorations = decorations.map(tr.changes);
      tr.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => dirty.push([fromB, toB]));
    }
    // The parser only runs a little past the viewport, so the tree grows as
    // the user scrolls. Scan only the newly parsed tail.
    const grownFrom = tr.changes.mapPos(value.tree.length);
    if (tree !== value.tree && tree.length > grownFrom) dirty.push([grownFrom, tree.length]);

    // Edits past the parsed tree wait until the tree grows over them.
    const toOld = tr.docChanged ? tr.changes.invertedDesc : null;
    const rescan = merge(dirty.filter(([a]) => a <= tree.length).map(([a, b]) => cover(tree, value.tree, toOld, a, Math.min(b, tree.length))));
    blockStats.rescanned = rescan.reduce((n, [a, b]) => n + b - a, 0);
    if (rescan.length) blocks = blocks.slice();
    for (const [a, b] of rescan) {
      const [i, j] = overlapping(blocks, a, b);
      blocks.splice(i, j - i, ...scan(tr.state, tree, a, b));
    }

    // Blocks that the caret entered or left need new decorations too.
    const mappedOld = oldSel && tr.docChanged ? oldSel.map(tr.changes) : oldSel;
    const touched: [number, number][] = [...rescan];
    if (mappedOld !== newSel) {
      const ranges = [...(mappedOld?.ranges ?? []), ...(newSel?.ranges ?? [])];
      for (const r of ranges) {
        const [i, j] = overlapping(blocks, r.from, r.to);
        for (const b of blocks.slice(i, j)) {
          const was = mappedOld ? touches(mappedOld, b) : false;
          const is = newSel ? touches(newSel, b) : false;
          if (was !== is) touched.push([b.from, b.to]);
        }
      }
    }

    for (const [a, b] of merge(touched)) {
      const [i, j] = overlapping(blocks, a, b);
      const add = blocks.slice(i, j).flatMap((x) => decorationsFor(tr.state, x, newSel));
      decorations = decorations.update({ filterFrom: a, filterTo: b, filter: () => false, add, sort: true });
    }

    blockStats.lastUpdateMs = performance.now() - t0;
    blockStats.blocks = blocks.length;
    return { tree, blocks, decorations };
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
});
