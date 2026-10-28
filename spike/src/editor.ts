import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdownKeymap } from "@codemirror/lang-markdown";
import { LanguageSupport, syntaxTree } from "@codemirror/language";
import { EditorState, Prec } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { blockField } from "./blocks";
import { livePreview } from "./livePreview";
import { listIndentKeymap } from "./listIndent";
import { vireoMarkdown } from "./markdown";
import { focusTracking } from "./reveal";

const theme = EditorView.theme({
  "&": {
    height: "100%",
    fontSize: "calc(16px * var(--zoom))",
    backgroundColor: "var(--bg)",
    color: "var(--fg)",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: "var(--font-doc)", lineHeight: "1.55" },
  ".cm-content": {
    maxWidth: "720px",
    margin: "0 auto",
    padding: "48px 24px 40vh",
    caretColor: "var(--fg)",
  },
  ".cm-line": { padding: "0" },
  "::selection": { backgroundColor: "var(--selection)" },
});

const openLinks = EditorView.domEventHandlers({
  mousedown(event, view) {
    if (!event.metaKey) return false;
    const pos = view.posAtCoords(event);
    if (pos == null) return false;
    for (let node: ReturnType<typeof syntaxTree>["topNode"] | null = syntaxTree(view.state).resolveInner(pos, 1); node; node = node.parent) {
      if (node.name !== "Link" && node.name !== "Autolink" && node.name !== "URL") continue;
      const url = node.name === "URL" ? node : node.getChild("URL");
      if (!url) return false;
      window.open(view.state.sliceDoc(url.from, url.to), "_blank");
      event.preventDefault();
      return true;
    }
    return false;
  },
});

export function createState(doc: string): EditorState {
  return EditorState.create({
    doc,
    extensions: [
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap]),
      // markdown() would wrap the parser in a mixed parse for code and HTML,
      // which re-walks the whole tree per keystroke. See codeHighlight.ts.
      new LanguageSupport(vireoMarkdown),
      Prec.high(keymap.of([...listIndentKeymap, ...markdownKeymap])),
      EditorView.lineWrapping,
      EditorView.contentAttributes.of({ spellcheck: "true", autocorrect: "on", autocapitalize: "on" }),
      focusTracking,
      blockField,
      livePreview,
      openLinks,
      theme,
    ],
  });
}
