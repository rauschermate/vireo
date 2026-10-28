import { describe, expect, test } from "bun:test";
import { EditorSelection, EditorState, Transaction } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { listIndentKeymap } from "../src/editor/listIndent";

// The commands only read `state` and call `dispatch`, so a stand-in view is
// enough and the tests need no DOM.
function run(key: "Tab" | "Shift-Tab", doc: string, anchor: number, head = anchor): string {
  let state = EditorState.create({ doc, selection: EditorSelection.single(anchor, head) });
  const view = {
    get state() {
      return state;
    },
    dispatch(...specs: any[]) {
      state = (specs[0] instanceof Transaction ? specs[0] : state.update(...specs)).state;
    },
  } as unknown as EditorView;
  listIndentKeymap.find((k) => k.key === key)!.run(view);
  return state.doc.toString();
}

describe("list indent", () => {
  test("Tab nests a bullet by 4 spaces", () => {
    expect(run("Tab", "- a\n- b", 6)).toBe("- a\n    - b");
  });

  test("Shift-Tab removes one level", () => {
    expect(run("Shift-Tab", "- a\n        - b", 14)).toBe("- a\n    - b");
  });

  test("Shift-Tab on a top-level item changes nothing", () => {
    expect(run("Shift-Tab", "- a\n- b", 6)).toBe("- a\n- b");
  });

  test("Tab on an ordered item restarts the sublist at 1", () => {
    expect(run("Tab", "1. a\n2. b", 8)).toBe("1. a\n    1. b");
  });

  test("Tab indents every list line in the selection", () => {
    expect(run("Tab", "- a\n- b\n- c", 4, 11)).toBe("- a\n    - b\n    - c");
  });

  test("Tab off a list inserts a tab", () => {
    expect(run("Tab", "text", 4)).toBe("text\t");
  });

  test("task items nest like bullets", () => {
    expect(run("Tab", "- [ ] a\n- [x] b", 14)).toBe("- [ ] a\n    - [x] b");
  });
});
