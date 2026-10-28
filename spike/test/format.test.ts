import { describe, expect, test } from "bun:test";
import { LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, StateCommand, Transaction } from "@codemirror/state";
import { activeFormats, applyLink, linkTarget, makeHeading, removeLink, toggleLinePrefix, wrapSelection } from "../src/format";
import { vireoMarkdown } from "../src/markdown";

const create = (doc: string, anchor: number, head = anchor) =>
  EditorState.create({ doc, selection: EditorSelection.single(anchor, head), extensions: [new LanguageSupport(vireoMarkdown)] });

function run(cmd: StateCommand, doc: string, anchor: number, head = anchor) {
  let state = create(doc, anchor, head);
  cmd({ state, dispatch: (tr: Transaction) => (state = tr.state) });
  const { from, to } = state.selection.main;
  return { doc: state.doc.toString(), sel: [from, to] };
}

describe("wrapSelection", () => {
  test("wraps and keeps the text selected", () => {
    expect(run(wrapSelection("**"), "a word b", 2, 6)).toEqual({ doc: "a **word** b", sel: [4, 8] });
  });
  test("unwraps when the markers surround the selection", () => {
    expect(run(wrapSelection("**"), "a **word** b", 4, 8)).toEqual({ doc: "a word b", sel: [2, 6] });
  });
  test("unwraps when the selection includes the markers", () => {
    expect(run(wrapSelection("**"), "a **word** b", 2, 10)).toEqual({ doc: "a word b", sel: [2, 6] });
  });
  test("an empty selection inserts a marker pair around the caret", () => {
    expect(run(wrapSelection("*"), "ab", 1)).toEqual({ doc: "a**b", sel: [2, 2] });
  });
});

describe("line formats", () => {
  test("list prefix toggles", () => {
    expect(run(toggleLinePrefix("- "), "item", 2).doc).toBe("- item");
    expect(run(toggleLinePrefix("- "), "- item", 4).doc).toBe("item");
  });
  test("heading sets, replaces and toggles off", () => {
    expect(run(makeHeading(2), "Title", 0).doc).toBe("## Title");
    expect(run(makeHeading(1), "## Title", 4).doc).toBe("# Title");
    expect(run(makeHeading(2), "## Title", 4).doc).toBe("Title");
  });
});

describe("activeFormats", () => {
  test("a caret after bold text reports bold", () => {
    expect(activeFormats(create("a **bold** c", 7)).bold).toBe(true);
  });
  test("headings, lists and quotes", () => {
    expect(activeFormats(create("### H", 5)).heading).toBe(3);
    expect(activeFormats(create("- item", 4)).list).toBe(true);
    expect(activeFormats(create("> quote", 4)).quote).toBe(true);
  });
  test("a link", () => {
    expect(activeFormats(create("see [x](u)", 6)).link).toBe(true);
  });
});

describe("links", () => {
  test("a selection becomes a new link", () => {
    const state = create("see this", 4, 8);
    const target = linkTarget(state);
    expect(target).toEqual({ from: 4, to: 8, label: "this", url: "", existing: false });
    expect(applyLink(state, target, "this", "https://a.b").state.doc.toString()).toBe("see [this](https://a.b)");
  });
  test("the caret inside a link edits it", () => {
    const state = create("see [this](https://a.b) now", 6);
    const target = linkTarget(state);
    expect(target).toEqual({ from: 4, to: 23, label: "this", url: "https://a.b", existing: true });
    expect(applyLink(state, target, "that", "https://c.d").state.doc.toString()).toBe("see [that](https://c.d) now");
    expect(removeLink(state, target).state.doc.toString()).toBe("see this now");
  });
});
