import { indentLess, insertTab } from "@codemirror/commands";
import { ChangeSpec } from "@codemirror/state";
import { Command, EditorView } from "@codemirror/view";

// Matches Vireo's MarkdownTextView: 4 spaces nests reliably in GFM.
const UNIT = "    ";
const LIST_LINE = /^(\s*)([-*+]|(\d+)[.)])(\s|$)/;

function adjust(view: EditorView, outdent: boolean): boolean {
  const { state } = view;
  const changes: ChangeSpec[] = [];
  const seen = new Set<number>();
  let onList = false;
  for (const range of state.selection.ranges) {
    for (let pos = range.from; pos <= range.to; ) {
      const line = state.doc.lineAt(pos);
      pos = line.to + 1;
      if (seen.has(line.from)) continue;
      seen.add(line.from);
      const m = LIST_LINE.exec(line.text);
      if (!m) continue;
      onList = true;
      if (outdent) {
        const remove = m[1].startsWith("\t") ? 1 : Math.min(UNIT.length, m[1].length - m[1].trimStart().length);
        if (remove > 0) changes.push({ from: line.from, to: line.from + remove });
      } else if (m[3] !== undefined) {
        // A sublist directly under an item's text only parses when it starts
        // with 1 (it cannot interrupt a paragraph otherwise).
        const digitsFrom = line.from + m[1].length;
        changes.push({ from: line.from, insert: UNIT }, { from: digitsFrom, to: digitsFrom + m[3].length, insert: "1" });
      } else {
        changes.push({ from: line.from, insert: UNIT });
      }
    }
  }
  // Off a list, fall back to plain Tab and Shift-Tab. On a top-level item,
  // Shift-Tab has nothing to remove but still must not dedent other text.
  if (!changes.length) return onList;
  view.dispatch({ changes, userEvent: outdent ? "delete.dedent" : "input.indent", scrollIntoView: true });
  return true;
}

export const listIndentKeymap: { key: string; run: Command }[] = [
  { key: "Tab", run: (view) => adjust(view, false) || insertTab(view) },
  { key: "Shift-Tab", run: (view) => adjust(view, true) || indentLess(view) },
];
