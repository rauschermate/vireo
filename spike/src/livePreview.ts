import { syntaxTree } from "@codemirror/language";
import { EditorState, Range } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from "@codemirror/view";
import { SyntaxNode } from "@lezer/common";
import { highlightCode, languageLoaded } from "./codeHighlight";
import { focusField, lineRevealed, revealed } from "./reveal";

const hide = Decoration.replace({});
const dim = Decoration.mark({ class: "cm-md-syntax" });
const inlineMarks: Record<string, Decoration> = {
  Emphasis: Decoration.mark({ class: "cm-md-em" }),
  StrongEmphasis: Decoration.mark({ class: "cm-md-strong" }),
  Strikethrough: Decoration.mark({ class: "cm-md-strike" }),
  InlineCode: Decoration.mark({ class: "cm-md-inline-code" }),
};
const delimiterOf: Record<string, string> = {
  Emphasis: "EmphasisMark",
  StrongEmphasis: "EmphasisMark",
  Strikethrough: "StrikethroughMark",
  InlineCode: "CodeMark",
};
const link = Decoration.mark({ class: "cm-md-link" });
const taskDone = Decoration.mark({ class: "cm-md-task-done" });
const headingLine = [1, 2, 3, 4, 5, 6].map((n) => Decoration.line({ class: `cm-md-h cm-md-h${n}` }));
const quoteLine = Decoration.line({ class: "cm-md-quote" });
const tableSourceLine = Decoration.line({ class: "cm-md-table-source" });
const codeLine = {
  only: Decoration.line({ class: "cm-md-code cm-md-code-first cm-md-code-last" }),
  first: Decoration.line({ class: "cm-md-code cm-md-code-first" }),
  middle: Decoration.line({ class: "cm-md-code" }),
  last: Decoration.line({ class: "cm-md-code cm-md-code-last" }),
};

class BulletWidget extends WidgetType {
  constructor(readonly depth: number) {
    super();
  }
  eq(other: BulletWidget) {
    return other.depth === this.depth;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-md-bullet";
    span.textContent = ["•", "◦", "▪"][this.depth % 3];
    return span;
  }
}

class NumberWidget extends WidgetType {
  constructor(readonly label: string) {
    super();
  }
  eq(other: NumberWidget) {
    return other.label === this.label;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-md-number";
    span.textContent = this.label;
    return span;
  }
}

class CheckboxWidget extends WidgetType {
  constructor(readonly checked: boolean) {
    super();
  }
  eq(other: CheckboxWidget) {
    return other.checked === this.checked;
  }
  toDOM(view: EditorView) {
    const box = document.createElement("span");
    box.className = "cm-md-checkbox" + (this.checked ? " is-checked" : "");
    box.setAttribute("role", "checkbox");
    box.setAttribute("aria-checked", String(this.checked));
    box.addEventListener("mousedown", (event) => {
      event.preventDefault();
      // The widget DOM survives edits elsewhere, so look its position up on
      // click instead of caching it at creation time.
      const pos = view.posAtDOM(box);
      const marker = view.state.doc.sliceString(pos, view.state.doc.lineAt(pos).to).indexOf("[");
      if (marker < 0) return;
      const at = pos + marker + 1;
      view.dispatch({
        changes: { from: at, to: at + 1, insert: this.checked ? " " : "x" },
        userEvent: "input.toggle",
      });
    });
    return box;
  }
  ignoreEvent() {
    return true;
  }
}

class ImageWidget extends WidgetType {
  constructor(readonly src: string, readonly alt: string) {
    super();
  }
  eq(other: ImageWidget) {
    return other.src === this.src && other.alt === this.alt;
  }
  toDOM(view: EditorView) {
    const img = document.createElement("img");
    img.className = "cm-md-image";
    img.alt = this.alt;
    img.src = this.src;
    img.addEventListener("load", () => view.requestMeasure());
    return img;
  }
}

// Visits the start of every line of [from, to] that lies in the viewport. A
// multi-megabyte code block must not cost a decoration per line it contains.
function eachLine(state: EditorState, viewport: { from: number; to: number }, from: number, to: number, f: (lineFrom: number) => void) {
  let pos = Math.max(from, viewport.from);
  const end = Math.min(to, viewport.to);
  while (pos <= end) {
    const line = state.doc.lineAt(pos);
    f(line.from);
    pos = line.to + 1;
  }
}

export const previewStats = { lastBuildMs: 0, decorations: 0 };

function build(view: EditorView): DecorationSet {
  const t0 = performance.now();
  try {
    return buildInner(view);
  } finally {
    previewStats.lastBuildMs = performance.now() - t0;
  }
}

function buildInner(view: EditorView): DecorationSet {
  const { state } = view;
  const out: Range<Decoration>[] = [];
  const doc = state.doc;
  const quoteLines = new Set<number>();
  const { from, to } = view.viewport;

  syntaxTree(state).iterate({
    from,
    to,
    enter: (ref) => {
      const node = ref.node;
      const name = node.name;

      if (name.startsWith("ATXHeading")) {
        heading(state, node, +name.slice(-1), out);
        return;
      }
      if (name.startsWith("SetextHeading")) {
        const mark = node.getChild("HeaderMark");
        const level = name.endsWith("1") ? 1 : 2;
        const end = mark ? doc.lineAt(mark.from).from - 1 : node.to;
        eachLine(state, view.viewport, node.from, end, (at) => out.push(headingLine[level - 1].range(at)));
        if (mark && revealed(state, node.from, node.to)) out.push(dim.range(mark.from, mark.to));
        return;
      }

      switch (name) {
        case "Emphasis":
        case "StrongEmphasis":
        case "Strikethrough":
        case "InlineCode":
          delimited(state, node, inlineMarks[name], delimiterOf[name], out);
          return name !== "InlineCode";
        case "Link":
          linkNode(state, node, out);
          return;
        case "Autolink": {
          const url = node.getChild("URL");
          if (url) out.push(link.range(url.from, url.to));
          const show = revealed(state, node.from, node.to);
          for (const m of node.getChildren("LinkMark")) out.push((show ? dim : hide).range(m.from, m.to));
          return false;
        }
        case "URL":
          if (node.parent?.name === "Paragraph" || node.parent?.name === "TableCell") {
            out.push(link.range(node.from, node.to));
          }
          return false;
        case "Image":
          image(state, node, out);
          return false;
        case "ListMark":
          listMark(state, node, out);
          return false;
        case "ListItem":
          listContinuation(view, node, out);
          return;
        case "Blockquote":
          eachLine(state, view.viewport, node.from, node.to, (at) => {
            if (quoteLines.has(at)) return;
            quoteLines.add(at);
            out.push(quoteLine.range(at));
          });
          return;
        case "QuoteMark": {
          if (lineRevealed(state, node.from)) out.push(dim.range(node.from, node.to));
          else out.push(hide.range(node.from, afterSpace(state, node.to)));
          return false;
        }
        case "FencedCode":
        case "CodeBlock":
          codeBlock(view, node, out);
          return false;
        case "Table":
          if (revealed(state, node.from, node.to)) {
            eachLine(state, view.viewport, node.from, node.to, (at) => out.push(tableSourceLine.range(at)));
          }
          return;
        case "TableDelimiter":
          if (node.parent?.name !== "Table") out.push(dim.range(node.from, node.to));
          return false;
        case "Escape":
          if (!revealed(state, node.from, node.to)) out.push(hide.range(node.from, node.from + 1));
          return false;
        case "HTMLTag":
        case "Comment":
          out.push(dim.range(node.from, node.to));
          return false;
      }
    },
  });

  previewStats.decorations = out.length;
  return Decoration.set(out, true);
}

function heading(state: EditorState, node: SyntaxNode, level: number, out: Range<Decoration>[]) {
  const line = state.doc.lineAt(node.from);
  out.push(headingLine[level - 1].range(line.from));
  const show = revealed(state, line.from, line.to);
  for (const mark of node.getChildren("HeaderMark")) {
    if (show) {
      out.push(dim.range(mark.from, mark.to));
      continue;
    }
    let from = mark.from;
    let to = mark.to;
    if (from === line.from) to = afterSpace(state, to);
    else while (from > line.from && /\s/.test(state.doc.sliceString(from - 1, from))) from--;
    if (to > from) out.push(hide.range(from, to));
  }
}

function delimited(state: EditorState, node: SyntaxNode, style: Decoration, mark: string, out: Range<Decoration>[]) {
  out.push(style.range(node.from, node.to));
  const show = revealed(state, node.from, node.to);
  for (const m of node.getChildren(mark)) {
    if (m.to > m.from) out.push((show ? dim : hide).range(m.from, m.to));
  }
}

function linkNode(state: EditorState, node: SyntaxNode, out: Range<Decoration>[]) {
  const marks = node.getChildren("LinkMark");
  if (marks.length < 2) return;
  const [open, close] = marks;
  if (close.from > open.to) out.push(link.range(open.to, close.from));
  if (revealed(state, node.from, node.to)) {
    out.push(dim.range(open.from, open.to));
    out.push(dim.range(close.from, node.to));
  } else {
    out.push(hide.range(open.from, open.to));
    out.push(hide.range(close.from, node.to));
  }
}

function image(state: EditorState, node: SyntaxNode, out: Range<Decoration>[]) {
  if (revealed(state, node.from, node.to)) {
    out.push(dim.range(node.from, node.to));
    return;
  }
  const marks = node.getChildren("LinkMark");
  const url = node.getChild("URL");
  if (!url || marks.length < 2) return;
  const alt = state.doc.sliceString(marks[0].to, marks[1].from);
  out.push(Decoration.replace({ widget: new ImageWidget(state.doc.sliceString(url.from, url.to), alt) }).range(node.from, node.to));
}

// Vireo's list geometry: the text column sits at (depth + 1) × 1.375em, and
// the marker draws in the 1.375em gutter to its left. Leading indent spaces
// stay in the source but are hidden, so wrapped lines align with the text.
const listLines = new Map<string, Decoration>();
function listLine(kind: "item" | "cont", depth: number): Decoration {
  const key = kind + depth;
  let deco = listLines.get(key);
  if (!deco) {
    deco = Decoration.line({ class: kind === "item" ? "cm-md-li" : "cm-md-li-cont", attributes: { style: `--li-depth: ${depth}` } });
    listLines.set(key, deco);
  }
  return deco;
}
const markerSource = Decoration.mark({ class: "cm-md-syntax cm-md-marker-source" });

function itemDepth(item: SyntaxNode): number {
  let depth = 0;
  for (let p = item.parent; p; p = p.parent) if (p.name === "ListItem") depth++;
  return depth;
}

// Ordered lists display renumbered from the first item, as Vireo does. The
// source keeps whatever numbers the user typed.
function ordinal(state: EditorState, mark: SyntaxNode, item: SyntaxNode, list: SyntaxNode): string {
  const first = list.getChild("ListItem")?.getChild("ListMark");
  const start = first ? parseInt(state.doc.sliceString(first.from, first.to), 10) || 0 : 1;
  let index = 0;
  for (let s = item.prevSibling; s; s = s.prevSibling) if (s.name === "ListItem") index++;
  return `${start + index}${state.doc.sliceString(mark.to - 1, mark.to)}`;
}

function listMark(state: EditorState, node: SyntaxNode, out: Range<Decoration>[]) {
  const item = node.parent;
  const list = item?.parent;
  if (!item || !list) return;
  const line = state.doc.lineAt(node.from);
  // Inside a blockquote the prefix holds "> ", which QuoteMark handles.
  const plain = /^[ \t]*$/.test(state.doc.sliceString(line.from, node.from));
  const start = plain ? line.from : node.from;
  if (plain) out.push(listLine("item", itemDepth(item)).range(line.from));

  const text = afterSpace(state, node.to);
  const task = item.getChild("Task");
  const marker = task?.getChild("TaskMarker");
  const isTask = !!marker && marker.from === text;
  const checked = isTask && state.doc.sliceString(marker!.from + 1, marker!.from + 2).toLowerCase() === "x";
  if (checked && task!.to > marker!.to) out.push(taskDone.range(afterSpace(state, marker!.to), task!.to));

  // The caret at the start of the item text keeps the bullet; only a caret on
  // the marker itself reveals the source.
  if (revealed(state, node.from, isTask ? marker!.to : node.to)) {
    if (start < node.from) out.push(hide.range(start, node.from));
    out.push(markerSource.range(node.from, isTask ? afterSpace(state, marker!.to) : text));
    return;
  }
  let widget: WidgetType;
  if (isTask) widget = new CheckboxWidget(checked);
  else if (list.name === "OrderedList") widget = new NumberWidget(ordinal(state, node, item, list));
  else {
    let bullets = 0;
    for (let p = list.parent; p; p = p.parent) if (p.name === "BulletList") bullets++;
    widget = new BulletWidget(bullets);
  }
  out.push(Decoration.replace({ widget }).range(start, isTask ? afterSpace(state, marker!.to) : text));
}

const notProse = new Set(["FencedCode", "CodeBlock", "Table", "HTMLBlock", "Blockquote"]);

// Lines of an item after its marker line: lazy or indented continuations.
function listContinuation(view: EditorView, item: SyntaxNode, out: Range<Decoration>[]) {
  const { state } = view;
  const doc = state.doc;
  const markerLine = doc.lineAt(item.from).from;
  const depth = itemDepth(item);
  eachLine(state, view.viewport, item.from, item.to, (lineFrom) => {
    if (lineFrom === markerLine) return;
    const line = doc.lineAt(lineFrom);
    const indent = /^[ \t]*/.exec(line.text)![0].length;
    if (indent === line.length) return;
    // Only the innermost item owns a line, and code keeps its own indent.
    for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(line.from + indent, 1); n; n = n.parent) {
      if (notProse.has(n.name)) return;
      if (n.name === "ListItem") {
        if (n.from !== item.from) return;
        break;
      }
    }
    out.push(listLine("cont", depth).range(line.from));
    if (indent > 0) out.push(hide.range(line.from, line.from + indent));
  });
}

function codeBlock(view: EditorView, node: SyntaxNode, out: Range<Decoration>[]) {
  const { state, viewport } = view;
  const doc = state.doc;
  let first = doc.lineAt(node.from).number;
  let last = doc.lineAt(node.to).number;
  // Fence lines are hidden by the block field unless the block is revealed,
  // so round the corners of the first and last lines that stay visible.
  if (node.name === "FencedCode" && !revealed(state, node.from, node.to)) {
    const marks = node.getChildren("CodeMark");
    if (marks.length > 0 && first < last) first++;
    if (marks.length > 1 && last > first) last--;
  }
  const visibleFirst = Math.max(first, doc.lineAt(Math.max(node.from, viewport.from)).number);
  const visibleLast = Math.min(last, doc.lineAt(Math.min(node.to, viewport.to)).number);
  for (let n = visibleFirst; n <= visibleLast; n++) {
    const line = doc.line(n);
    const deco = first === last ? codeLine.only : n === first ? codeLine.first : n === last ? codeLine.last : codeLine.middle;
    out.push(deco.range(line.from));
  }
  const info = node.getChild("CodeInfo");
  const code = node.getChild("CodeText");
  if (info && code) highlightCode(view, doc.sliceString(info.from, info.to), code.from, code.to, out);
  if (revealed(state, node.from, node.to)) {
    for (const m of node.getChildren("CodeMark")) out.push(dim.range(m.from, m.to));
    if (info) out.push(dim.range(info.from, info.to));
  }
}

function afterSpace(state: EditorState, pos: number): number {
  const line = state.doc.lineAt(pos);
  while (pos < line.to && state.doc.sliceString(pos, pos + 1) === " ") pos++;
  return pos;
}

export const livePreview = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = build(view);
    }
    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        update.startState.field(focusField, false) !== update.state.field(focusField, false) ||
        syntaxTree(update.startState) !== syntaxTree(update.state) ||
        update.transactions.some((tr) => tr.effects.some((e) => e.is(languageLoaded)))
      ) {
        this.decorations = build(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);
