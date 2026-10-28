# Phase 1 findings: the CodeMirror spike

This spike tests one question: does CodeMirror 6 in a Tauri shell give a smoother edit experience than the TextKit 1 app? The spike keeps Vireo's rules: the raw markdown string is the only source of truth, and syntax stays hidden until the caret touches it.

The spike became `app/`. Its bench now lives at `bench.html`; see the app README for the commands.

## Acceptance moments (Phase 0)

| # | Moment | Budget |
|---|---|---|
| 1 | Open the 1.7 MB dense fixture to first pixel | < 300 ms |
| 2 | Type in the 1.7 MB file | work p95 < 16 ms; latency of 1 frame |
| 3 | Move the caret through hidden syntax | work p95 < 8 ms; no caret jumps |
| 4 | Zoom one step and toggle the theme on the 1.7 MB file | < 50 ms |
| 5 | Scroll fast through the 1.7 MB file | no long frames |
| 6 | Memory with the 1.7 MB file open | below Vireo (350–450 MB on 800 KB) |
| 7 | It *feels* better than Vireo when you write in it | your call |

## Results

All results are from an Apple Silicon Mac, on the same fixtures that `VireoSnapshot --benchmark-suite` uses. "Work" is main-thread time for the change, including CodeMirror's measure pass. "Latency" is the time from the change to the painted frame.

| Moment | Vireo (Swift) | Spike in WKWebView |
|---|---|---|
| Open 1.7 MB dense → pixel | 3,750 ms | **15 ms** |
| Open 3.4 MB code block → pixel | 142 ms | **31 ms** |
| Type, 1.7 MB dense | ~6 ms (800 KB) | **7 ms** p50, 11 ms p95 |
| Caret right / down, 1.7 MB | — | **2 ms** p50, 3–4 ms p95 |
| Zoom step, 1.7 MB | 265–900 ms (full restyle) | **20 ms** |
| Theme toggle | full restyle | **< 1 ms** |
| Scroll, 1.7 MB | — | 0 long frames smooth; 1 of 60 in a 2,000 px/frame flick |
| Memory, idle with welcome.md | ~59 MB | ~121 MB (31 app + 75 WebContent + 15 GPU) — worse |
| Memory, idle with 1.7 MB file | 350–450 MB (800 KB) | **~153 MB** (35 app + 103 WebContent + 15 GPU) |
| Memory, sustained fast scroll | — | 300–450 MB sawtooth; back to ~200 MB at rest |
| App bundle | — | 7.3 MB |
| IPC read of a 1.7–3.4 MB file | — | 6 ms p50, 20 ms p95 |

Moments 1–6 pass. The one regression is the idle floor: a web view costs about 60 MB more than AppKit on a small file. Moment 7 needs you.

## What I learned

1. **The win comes from lazy work, not from Rust.** CodeMirror parses and renders only around the viewport. After an edit, the parse stops a little past the viewport. The open-time gap (3.75 s → 15 ms) is this design, not a faster language.
2. **Every per-edit pass must be incremental or limited to the viewport.** My first block field rebuilt ~10,000 table and fence decorations on each keystroke (28 ms). Now it maps blocks through the edit and rescans only the changed region or the newly parsed tail (~1 ms).
3. **Do not use `markdown()` from `@codemirror/lang-markdown` as-is.** It always wraps the parser in `parseMixed` (for code and HTML), which re-walks the whole tree on every keystroke. I use `markdownLanguage` directly and highlight each visible code block with its own small parse. That cut typing at the end of the 1.7 MB file from 26 ms to 12 ms.
4. **The remaining typing cost grows with the parsed length.** The cause is the Lezer markdown fragment reuse, the tree re-balance, and the height map: ~2 ms at 100 KB, ~12 ms at 1.7 MB (caret near the end). Real notes stay far below this. If we need more, the fix belongs upstream in `@lezer/markdown`.
5. **WKWebView runs `requestAnimationFrame` at 60 Hz** (frame p50 = 16.7 ms), even on a ProMotion display. Native scroll still composites at 120 Hz, but JS-driven animation runs at 60 Hz. Check this when you try the app.
6. **Memory sawtooth during scroll.** The live-preview plugin rebuilds all viewport decorations on every viewport change. That garbage explains the sawtooth. Phase 2 item: rebuild only the lines that entered the viewport.

## Invariant: incremental equals full

Vireo's Swift parser guarantees that incremental output equals a full re-parse. The spike keeps that rule, and `bun test` enforces it. A fuzz test applies random edits and, after every edit, compares two things with a fresh parse of the same text:

- the Lezer tree, and
- the block field (fences, tables, rules, setext underlines) with its decorations.

`FUZZ_SEEDS=3000 FUZZ_STEPS=300 bun test` runs 900,000 edits (~80 s). The default run is 40 × 150.

The fuzz test found two bugs in `@lezer/markdown`. In both, the incremental tree differs from a fresh parse. `src/markdown.ts` works around them: it stops block reuse three lines short of each edit.

```js
// TreeFragment.applyChanges(..., minGap = 0), then parse with the fragments:
// 1. CommonMark: "    |\n|\n", delete chars 0-2 → incremental keeps a CodeBlock; fresh is one Paragraph.
// 2. GFM: "p\n| a | b |\n|---|---|", type "-" at the end → incremental gives two Paragraphs; fresh gives one.
```

It also found three bugs in my block field. Each one rescanned too little after an edit that changes how *later* text parses. The fix grows each rescan range until both edges are top-level block starts in both the old and the new tree.

## Gaps (on purpose, for Phase 2)

- Images resolve relative to the page, not the file. Tauri needs the asset protocol for local images.
- ⌘-click uses `window.open`. Tauri needs the opener plugin.
- No tabs, sidebar, TOC, file watcher, autosave, or Quick Look. This spike tests only the editor core.
- Native text services (spellcheck, autocorrect, dictation, IME) are enabled but not tested by hand yet.
