import { describe, expect, test } from "bun:test";
import { LanguageSupport, syntaxTree } from "@codemirror/language";
import { EditorSelection, EditorState, TransactionSpec } from "@codemirror/state";
import { blockField } from "../src/editor/blocks";
import { vireoMarkdown } from "../src/editor/markdown";
import { focusEffect, focusField } from "../src/editor/reveal";

// The block field updates incrementally: it maps blocks through each edit and
// rescans only the changed region. Its output must equal a field built from
// scratch on the same document and selection, like Vireo's
// incremental-equals-full parser invariant.

const extensions = [new LanguageSupport(vireoMarkdown), focusField, blockField];

function create(doc: string, selection?: EditorSelection): EditorState {
  const state = EditorState.create({ doc, selection, extensions });
  return state.update({ effects: focusEffect.of(true) }).state;
}

function describeField(state: EditorState) {
  const { blocks, decorations } = state.field(blockField);
  const decos: string[] = [];
  decorations.between(0, state.doc.length, (from, to, value) => {
    const widget = value.spec.widget;
    decos.push(`${from}-${to}:${widget ? widget.constructor.name + JSON.stringify((widget as any).source ?? "") : "hide"}`);
  });
  return { blocks: JSON.stringify(blocks), decos };
}

function rng(seed: number) {
  return () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 2 ** 32;
  };
}

const fragments = [
  "```js\n",
  "```\n",
  "| a | b |\n|---|---|\n| 1 | 2 |\n",
  "| x |\n",
  "---\n",
  "Title\n===\n",
  "- item\n",
  "    - nested\n",
  "> quote\n",
  "\n",
  "\n\n",
  "text ",
  "x",
  "`",
  "|",
  "-",
];

const seedDoc = `# Doc

Intro paragraph.

\`\`\`swift
let a = 1
\`\`\`

| A | B |
|---|---|
| 1 | 2 |

---

Setext
------

- one
    \`\`\`
    code in a list
    \`\`\`
- two

> | q | t |
> |---|---|
`;

function randomEdit(state: EditorState, next: () => number): TransactionSpec {
  const len = state.doc.length;
  const roll = next();
  if (roll < 0.15) {
    const anchor = Math.floor(next() * (len + 1));
    return { selection: EditorSelection.cursor(anchor) };
  }
  const from = Math.floor(next() * (len + 1));
  if (roll < 0.45 && len > 0) {
    const to = Math.min(len, from + 1 + Math.floor(next() * 12));
    return { changes: { from, to }, selection: EditorSelection.cursor(from) };
  }
  const insert = fragments[Math.floor(next() * fragments.length)];
  return { changes: { from, insert }, selection: EditorSelection.cursor(from + insert.length) };
}

describe("block field", () => {
  test("hides fences, rules and setext underlines; draws tables", () => {
    const { decos } = describeField(create(seedDoc, EditorSelection.cursor(0)));
    expect(decos.filter((d) => d.includes("TableWidget")).length).toBe(2);
    expect(decos.filter((d) => d.includes("RuleWidget")).length).toBe(1);
    expect(decos.filter((d) => d.endsWith("hide")).length).toBe(5);
  });

  test("a caret inside a block reveals its source", () => {
    const at = seedDoc.indexOf("let a");
    const { decos } = describeField(create(seedDoc, EditorSelection.cursor(at)));
    expect(decos.filter((d) => d.endsWith("hide")).length).toBe(3);
  });

  const seeds = Number(process.env.FUZZ_SEEDS ?? 40);
  const steps = Number(process.env.FUZZ_STEPS ?? 150);
  for (let seed = 1; seed <= seeds; seed++) {
    test(`incremental equals full, seed ${seed}`, () => {
      const next = rng(seed);
      let state = create(seedDoc, EditorSelection.cursor(0));
      for (let step = 0; step < steps; step++) {
        const before = state;
        const spec = randomEdit(state, next);
        state = state.update(spec).state;
        expect(syntaxTree(state).length).toBe(state.doc.length);
        const fresh = create(state.doc.toString(), state.selection);
        const got = describeField(state);
        const want = describeField(fresh);
        const treeOf = (st: EditorState) => syntaxTree(st).toString();
        if (treeOf(state) !== treeOf(fresh)) {
          const single = create(before.doc.toString(), before.selection).update(spec).state;
          throw new Error(
            `seed ${seed} step ${step}: Lezer incremental tree differs from a fresh parse; one-step repro: ${treeOf(single) !== treeOf(fresh)}\n` +
              `BEFORE=${JSON.stringify(before.doc.toString())}\nEDIT=${JSON.stringify(spec)}`,
          );
        }
        if (got.blocks !== want.blocks || got.decos.join() !== want.decos.join()) {
          throw new Error(
            `seed ${seed} step ${step} diverged\n--- before ---\n${JSON.stringify(before.doc.toString())}\n--- edit ---\n${JSON.stringify(spec)}\n` +
              `--- after ---\n${JSON.stringify(state.doc.toString())}\n--- got ---\n${got.blocks}\n${got.decos.join("\n")}\n--- want ---\n${want.blocks}\n${want.decos.join("\n")}`,
          );
        }
      }
    });
  }
});
