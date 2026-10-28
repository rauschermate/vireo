import { EditorSelection, StateCommand } from "@codemirror/state";

// Inserts a block on its own lines below the caret's line, with blank lines
// around it, and puts the caret at `caret` inside the snippet.
export function insertBlock(snippet: string, caret = snippet.length): StateCommand {
  return ({ state, dispatch }) => {
    const line = state.doc.lineAt(state.selection.main.head);
    const empty = line.text.trim() === "";
    const at = empty ? line.from : line.to;
    const before = empty ? (line.number > 1 && state.doc.line(line.number - 1).text.trim() !== "" ? "\n" : "") : "\n\n";
    const nextLine = line.number < state.doc.lines ? state.doc.line(line.number + 1) : null;
    const after = nextLine && nextLine.text.trim() !== "" ? "\n" : "";
    const insert = before + snippet + after;
    dispatch(
      state.update({
        changes: { from: at, to: empty ? line.to : at, insert },
        selection: EditorSelection.cursor(at + before.length + caret),
        userEvent: "input.insert",
        scrollIntoView: true,
      }),
    );
    return true;
  };
}

export const insertTable = insertBlock("| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n|  |  |", 2);
export const insertCodeBlock = insertBlock("```\n\n```", 4);
export const insertRule = insertBlock("---");

export function insertImage(alt: string, src: string): StateCommand {
  const target = /[\s()]/.test(src) ? `<${src}>` : src;
  return ({ state, dispatch }) => {
    const text = `![${alt}](${target})`;
    const { from, to } = state.selection.main;
    dispatch(state.update({ changes: { from, to, insert: text }, selection: EditorSelection.cursor(from + text.length), userEvent: "input.insert", scrollIntoView: true }));
    return true;
  };
}
