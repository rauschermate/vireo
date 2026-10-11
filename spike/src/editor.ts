import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting, syntaxTree } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { classHighlighter } from "@lezer/highlight";
import { blockField } from "./blocks";
import { livePreview } from "./livePreview";
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
      markdown({ base: markdownLanguage, codeLanguages: languages }),
      syntaxHighlighting(classHighlighter),
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
