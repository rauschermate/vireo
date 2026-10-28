import { syntaxTree } from "@codemirror/language";
import { EditorSelection, EditorState, StateCommand } from "@codemirror/state";

// Formatting edits the markdown source directly, like Vireo's
// EditorController: wrap or unwrap the selection, or toggle a line prefix.

export function wrapSelection(prefix: string, suffix = prefix): StateCommand {
  return ({ state, dispatch }) => {
    const tr = state.changeByRange((range) => {
      const doc = state.doc;
      const before = doc.sliceString(range.from - prefix.length, range.from);
      const after = doc.sliceString(range.to, range.to + suffix.length);
      // Toggle off: the markers sit just outside the selection.
      if (range.from >= prefix.length && before === prefix && after === suffix) {
        return {
          changes: [
            { from: range.from - prefix.length, to: range.from },
            { from: range.to, to: range.to + suffix.length },
          ],
          range: EditorSelection.range(range.from - prefix.length, range.to - prefix.length),
        };
      }
      // Toggle off: the selection includes the markers.
      const selected = doc.sliceString(range.from, range.to);
      if (selected.length >= prefix.length + suffix.length && selected.startsWith(prefix) && selected.endsWith(suffix)) {
        const inner = selected.slice(prefix.length, selected.length - suffix.length);
        return {
          changes: { from: range.from, to: range.to, insert: inner },
          range: EditorSelection.range(range.from, range.from + inner.length),
        };
      }
      return {
        changes: [
          { from: range.from, insert: prefix },
          { from: range.to, insert: suffix },
        ],
        range: EditorSelection.range(range.from + prefix.length, range.to + prefix.length),
      };
    });
    dispatch(state.update(tr, { userEvent: "input.format", scrollIntoView: true }));
    return true;
  };
}

export function toggleLinePrefix(prefix: string): StateCommand {
  return ({ state, dispatch }) => {
    const line = state.doc.lineAt(state.selection.main.head);
    const on = line.text.startsWith(prefix);
    const change = on ? { from: line.from, to: line.from + prefix.length } : { from: line.from, insert: prefix };
    dispatch(state.update({ changes: change, userEvent: "input.format", scrollIntoView: true }));
    return true;
  };
}

// The current level toggles back to body text; another level replaces it.
export function makeHeading(level: number): StateCommand {
  return ({ state, dispatch }) => {
    const line = state.doc.lineAt(state.selection.main.head);
    const existing = /^#{1,6} /.exec(line.text)?.[0] ?? "";
    const target = "#".repeat(level) + " ";
    const insert = existing === target ? "" : target;
    dispatch(state.update({ changes: { from: line.from, to: line.from + existing.length, insert }, userEvent: "input.format", scrollIntoView: true }));
    return true;
  };
}

export interface ActiveFormats {
  bold: boolean;
  italic: boolean;
  strikethrough: boolean;
  code: boolean;
  link: boolean;
  heading: number | null;
  list: boolean;
  quote: boolean;
}

// For a caret, probe the character before it, which is the format typing
// would continue. Matches Vireo's ActiveFormats.
export function activeFormats(state: EditorState): ActiveFormats {
  const f: ActiveFormats = { bold: false, italic: false, strikethrough: false, code: false, link: false, heading: null, list: false, quote: false };
  const { from, to, empty } = state.selection.main;
  const tree = syntaxTree(state);
  const visit = (pos: number, side: -1 | 1) => {
    for (let n: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(pos, side); n; n = n.parent) {
      switch (n.name) {
        case "StrongEmphasis":
          f.bold = true;
          break;
        case "Emphasis":
          f.italic = true;
          break;
        case "Strikethrough":
          f.strikethrough = true;
          break;
        case "InlineCode":
        case "FencedCode":
        case "CodeBlock":
          f.code = true;
          break;
        case "Link":
          f.link = true;
          break;
        case "ListItem":
          f.list = true;
          break;
        case "Blockquote":
          f.quote = true;
          break;
        default:
          if (n.name.startsWith("ATXHeading")) f.heading = Number(n.name.slice(-1));
          else if (n.name.startsWith("SetextHeading")) f.heading = Number(n.name.slice(-1));
      }
    }
  };
  if (empty) visit(from, from > 0 ? -1 : 1);
  else visit(from, 1);
  if (!empty && to - 1 > from) visit(to, -1);
  return f;
}

export interface LinkTarget {
  from: number;
  to: number;
  label: string;
  url: string;
  existing: boolean;
}

// The link under the caret, or a new link around the selection.
export function linkTarget(state: EditorState): LinkTarget {
  const { from, to } = state.selection.main;
  for (let n: ReturnType<ReturnType<typeof syntaxTree>["resolveInner"]> | null = syntaxTree(state).resolveInner(from, 1); n; n = n.parent) {
    if (n.name !== "Link") continue;
    const marks = n.getChildren("LinkMark");
    const url = n.getChild("URL");
    if (marks.length < 2) break;
    return {
      from: n.from,
      to: n.to,
      label: state.doc.sliceString(marks[0].to, marks[1].from),
      url: url ? state.doc.sliceString(url.from, url.to) : "",
      existing: true,
    };
  }
  const selected = state.doc.sliceString(from, to);
  return { from, to, label: selected || "link", url: "", existing: false };
}

export function applyLink(state: EditorState, target: LinkTarget, label: string, url: string) {
  const insert = `[${label}](${url})`;
  return state.update({
    changes: { from: target.from, to: target.to, insert },
    selection: EditorSelection.cursor(target.from + insert.length),
    userEvent: "input.format",
    scrollIntoView: true,
  });
}

export function removeLink(state: EditorState, target: LinkTarget) {
  return state.update({
    changes: { from: target.from, to: target.to, insert: target.label },
    selection: EditorSelection.cursor(target.from + target.label.length),
    userEvent: "input.format",
  });
}
