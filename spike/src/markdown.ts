import { markdownLanguage } from "@codemirror/lang-markdown";
import { Language } from "@codemirror/language";
import { Input, Parser, PartialParse, TreeFragment } from "@lezer/common";

// @lezer/markdown's incremental parse can differ from a fresh parse near an
// edit (test/blocks.test.ts checks the trees after every random edit):
// - Before the edit, it reuses any old block that ends before the edited line.
//   But GFM block rules look one line ahead (a table needs its delimiter row),
//   so an edit can change how a block up to two lines above it ends. Typing
//   "-" after "|---|---|" turns the header back into text of the paragraph
//   above.
// - After the edit, it can reuse a block that started before the edit.
//   Deleting two spaces from "    |\n|" leaves a stale indented code block.
// The guard stops reuse a few lines short of each edit, on both sides.
const GUARD_LINES = 3;

class SafeReuseParser extends Parser {
  constructor(readonly inner: Parser) {
    super();
  }

  createParse(input: Input, fragments: readonly TreeFragment[], ranges: readonly { from: number; to: number }[]): PartialParse {
    const trimmed: TreeFragment[] = [];
    for (const f of fragments) {
      let { from, to } = f;
      if (f.openEnd) {
        for (let lines = 0; to > from && lines < GUARD_LINES; ) {
          to--;
          if (input.read(to, to + 1) === "\n") lines++;
        }
      }
      if (f.openStart) {
        for (let lines = 0; from < to && lines < GUARD_LINES; from++) {
          if (input.read(from, from + 1) === "\n") lines++;
        }
      }
      if (to > from) trimmed.push(from === f.from && to === f.to ? f : new TreeFragment(from, to, f.tree, f.offset, f.openStart, f.openEnd));
    }
    return this.inner.startParse(input, trimmed, ranges);
  }
}

export const vireoMarkdown = new Language(markdownLanguage.data, new SafeReuseParser(markdownLanguage.parser), [], "markdown");
