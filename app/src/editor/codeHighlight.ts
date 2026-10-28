import { LanguageDescription } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { Decoration, EditorView } from "@codemirror/view";
import { Range, StateEffect } from "@codemirror/state";
import { classHighlighter, highlightTree } from "@lezer/highlight";

// Code blocks are highlighted one at a time, from their own text, instead of
// through a mixed parse. A mixed parse re-walks the whole markdown tree on
// every keystroke, which costs milliseconds on a large document.

const marks = new Map<string, Decoration>();
const mark = (cls: string) => {
  let m = marks.get(cls);
  if (!m) marks.set(cls, (m = Decoration.mark({ class: cls })));
  return m;
};

type Spans = { from: number; to: number; cls: string }[];
const cache = new Map<string, Spans>();
const CACHE_LIMIT = 200;
// Above this size only the visible slice is parsed. Stream-based modes can
// lose state at the slice start, which only affects colors.
const WHOLE_BLOCK_LIMIT = 64 * 1024;

function spans(lang: LanguageDescription, text: string): Spans {
  const key = lang.name + "\0" + text;
  const hit = cache.get(key);
  if (hit) return hit;
  const out: Spans = [];
  const tree = lang.support!.language.parser.parse(text);
  highlightTree(tree, classHighlighter, (from, to, cls) => out.push({ from, to, cls }));
  if (cache.size >= CACHE_LIMIT) cache.delete(cache.keys().next().value!);
  cache.set(key, out);
  return out;
}

const loading = new Set<LanguageDescription>();

export const languageLoaded = StateEffect.define<null>();

export function highlightCode(
  view: EditorView,
  info: string,
  from: number,
  to: number,
  out: Range<Decoration>[],
) {
  const lang = LanguageDescription.matchLanguageName(languages, info, true);
  if (!lang || from >= to) return;
  if (!lang.support) {
    if (!loading.has(lang)) {
      loading.add(lang);
      lang.load().then(() => view.dispatch({ effects: languageLoaded.of(null) }));
    }
    return;
  }
  let start = from;
  let end = to;
  if (to - from > WHOLE_BLOCK_LIMIT) {
    start = view.state.doc.lineAt(Math.max(from, view.viewport.from)).from;
    end = view.state.doc.lineAt(Math.min(to, view.viewport.to)).to;
    if (start >= end) return;
  }
  for (const s of spans(lang, view.state.sliceDoc(start, end))) out.push(mark(s.cls).range(start + s.from, start + s.to));
}
