import { SyntaxNode } from "@lezer/common";

// Renders a range of parsed inline markdown to DOM, for widgets such as tables
// that draw their own content instead of showing the source. `source` starts at
// document position `base`; node positions stay absolute.
export function renderInline(source: string, node: SyntaxNode, from: number, to: number, parent: HTMLElement, base = 0) {
  const slice = (a: number, b: number) => source.slice(a - base, b - base);
  let pos = from;
  const text = (end: number) => {
    if (end > pos) parent.append(slice(pos, end));
  };
  for (let child = node.firstChild; child; child = child.nextSibling) {
    if (child.to <= from || child.from >= to) continue;
    text(child.from);
    pos = child.to;
    switch (child.name) {
      case "Emphasis":
        parent.append(wrap("em", source, child, base));
        break;
      case "StrongEmphasis":
        parent.append(wrap("strong", source, child, base));
        break;
      case "Strikethrough":
        parent.append(wrap("s", source, child, base));
        break;
      case "InlineCode": {
        const code = document.createElement("code");
        code.textContent = innerText(slice, child, "CodeMark");
        parent.append(code);
        break;
      }
      case "Link": {
        const marks = child.getChildren("LinkMark");
        const a = document.createElement("a");
        a.className = "cm-md-link";
        if (marks.length >= 2) renderInline(source, child, marks[0].to, marks[1].from, a, base);
        parent.append(a);
        break;
      }
      case "Escape":
        parent.append(slice(child.from + 1, child.to));
        break;
      case "EmphasisMark":
      case "StrikethroughMark":
        break;
      default:
        parent.append(slice(child.from, child.to));
    }
  }
  text(to);
}

function wrap(tag: string, source: string, node: SyntaxNode, base: number): HTMLElement {
  const el = document.createElement(tag);
  const first = node.firstChild;
  const last = node.lastChild;
  const from = first && first.name.endsWith("Mark") ? first.to : node.from;
  const to = last && last !== first && last.name.endsWith("Mark") ? last.from : node.to;
  renderInline(source, node, from, to, el, base);
  return el;
}

function innerText(slice: (a: number, b: number) => string, node: SyntaxNode, mark: string): string {
  const marks = node.getChildren(mark);
  if (marks.length < 2) return slice(node.from, node.to);
  return slice(marks[0].to, marks[marks.length - 1].from);
}
