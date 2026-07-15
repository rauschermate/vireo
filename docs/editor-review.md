# Editor and Rendering Review

**Date:** July 2026  
**Branch reviewed:** `review` at `7a89d30`  
**Scope:** Product intent, hidden-syntax editing, rendering correctness, perceived performance, native interaction quality, document safety, and release readiness.

## Executive summary

Vireo has a strong foundation and a genuinely differentiated premise. Its source-preserving TextKit architecture, modular package boundaries, incremental parser, and snapshot harness are all good decisions.

The remaining gaps, however, sit directly in the product's defining promises:

1. syntax-free editing is not yet consistent across caret movement, deletion, links, tables, malformed/transient Markdown, find, copy, and accessibility;
2. full-document rendering is too slow for the stated 1–2 MB performance target on formatting-dense files;
3. some rendered elements, most notably images and code blocks, have visible correctness or presentation defects;
4. tab switching does not appear to preserve the actual editor session;
5. autosave failures can be silent; and
6. the Xcode release bundle is missing required identity and version metadata.

The recommendation is to pause additional feature work and do a focused core-quality pass before making the absolute launch claims currently used in the product and marketing docs.

## Product intent

The product docs describe Vireo as the default macOS app for people who want to open, read, and lightly edit Markdown without thinking about Markdown syntax.

The intended experience is:

- **Fast above all:** instant launch and file open, smooth scrolling, and no typing jank on large files.
- **Native:** SwiftUI/AppKit, system typography and controls, macOS menus, light/dark mode, Liquid Glass chrome, and Quick Look.
- **Minimal and calm:** a paper-like reading surface with little product machinery around it.
- **No exposed syntax:** Markdown remains the source of truth on disk, but users do not see its delimiters while viewing or editing.
- **Deliberately narrow:** no vault, plugins, accounts, cloud sync, collaboration, or general knowledge-management feature set.

This makes the editor engine the product, not merely one feature within it. The engineering design says this explicitly: if seamless hidden-syntax editing is wrong, no amount of surrounding chrome compensates for it.

The more recent positioning around agent-generated Markdown also raises the performance bar. Agent output commonly contains many short headings, lists, links, code blocks, tables, and reference definitions—the exact structures that produce high parser/run density.

## What is already strong

- The raw Markdown string remains canonical. Saving does not serialize a separate rich-text model back into Markdown.
- TextKit 1 null glyphs are a pragmatic way to hide source characters without changing the backing string.
- Parser, renderer, editor, file services, updater, and app shell are separated into coherent packages.
- Incremental parsing has a clear correctness invariant: incremental output must match a full parse.
- The parser tests include scenarios, Unicode coverage, and deterministic fuzzing.
- Dirty-range rendering avoids a full restyle for ordinary localized edits.
- A headless snapshot executable exercises the real parse → render → TextKit pipeline.
- Local images are downsampled to display resolution, avoiding full-resolution bitmap retention.
- The code is unusually well commented; most load-bearing decisions and prior fixes are documented near the implementation.

## Priority findings

### P0 — Full-document rendering misses the performance promise

The incremental parser performs well on ordinary local edits, but opening and fully styling a formatting-dense document is much slower than the product's “instant file open” promise.

`MarkdownRenderer.render` creates a mutable attributed string and then applies block, inline, token, image, table, list, task, heading, marker, arrow, and fold attributes through many individual range mutations. On a document with hundreds of thousands of runs, this dominates the pipeline.

The edit path also retains document-wide work:

- `IncrementalParser.update` materializes the complete source as `[UInt16]` on every keystroke.
- It scans a common prefix and suffix to rediscover an edit range that AppKit already knew.
- Splicing copies and filters the document's run arrays.
- `ParsedMarkdown.slice` linearly filters every run collection for a small dirty window.
- `EditorController.scheduleRestyle` sends the complete storage string to `DocumentModel` before parsing again.
- The existing benchmark stops before attribute application into live storage, TextKit layout, drawing, autosave callbacks, and SwiftUI observation.

#### Release benchmark results

These synthetic fixtures intentionally stress formatting/run density. They are not representative of every Markdown file, but they exercise the documented 1–2 MB target and are plausible for aggregated or agent-generated output.

| Fixture | Full parse | Attributed-string render | Incremental edit |
| --- | ---: | ---: | ---: |
| Formatting-dense, 1.68 MB | 682 ms | 7,245 ms | 9.7 ms parse/splice + 1.1 ms slice render |
| Formatting-dense, 2.35 MB | 1,124 ms | 10,672 ms | 14.4 ms parse/splice + 1.6 ms slice render |
| One fenced code block, 3.42 MB | 18.5 ms | 290.7 ms | Full fallback: 33.9 ms parse, then full render |

A 10 MB formatting-dense variant was still consuming one CPU core and approximately 1 GB of memory after one minute, so the run was stopped.

The single-code-block case is also important: expanding to an enclosing Markdown block makes the entire document dirty, so the benchmark's reported 33.9 ms parse is followed by a roughly 290 ms full render in the live editor. Layout and drawing come after that.

#### Suggested direction

- Add signposts around the complete key-to-pixel path: source notification, parse/diff, splice, slice, render, live attribute application, layout, and draw.
- Add representative fixtures and track median and p95 latency in release builds.
- Pass the actual AppKit edit range and replacement into the incremental engine instead of rediscovering it with a full-source diff.
- Build the attributed result in a sorted event sweep or otherwise batch/coalesce mutations instead of repeatedly modifying a large attributed string.
- Precompute fonts and attribute dictionaries once per render.
- Index sorted ranges so slicing and caret lookups can use binary search rather than full scans.
- Define a degraded strategy for exceptionally large single blocks instead of synchronously re-rendering the entire block on every character.

### P0 — The visual/source mapping layer is incomplete

The engineering design calls for a general mapping layer that treats hidden marker ranges as atomic visual boundaries. The implementation currently handles only part of that requirement.

`MarkdownTextView` snaps the caret across leading list markers for basic left/right movement, clicks, and insertion. It does not provide the same behavior for general inline markers or all native movement commands.

Known or likely affected interactions include:

- moving through `**`, `*`, backticks, link brackets, and hidden URLs;
- Shift+Arrow selection;
- Option+Arrow word movement;
- Home/End and line-boundary movement;
- vertical movement into hidden ranges;
- backspace/delete at a formatting boundary;
- clicking at an ambiguous visual boundary;
- selection normalization across multiple constructs;
- find results inside hidden URLs or delimiters;
- copying a visually formatted selection into another app; and
- VoiceOver reading the raw storage rather than the visible document.

This creates invisible caret stops, makes arrows appear stuck, and allows a deletion at a visible boundary to remove only one hidden delimiter. Once a construct becomes temporarily invalid, the parser no longer recognizes its markers and raw syntax can appear.

The roadmap already notes some caret cases, but this should be elevated from a lower-severity follow-up. It is part of Vireo's defining interaction.

#### Suggested direction

Create one indexed marker-boundary abstraction and use it for selection, movement, insertion, deletion, find, copy, hit testing, and accessibility. Ad hoc command overrides will continue to diverge as more interactions are covered.

The product also needs an explicit policy for transient invalid Markdown. Absolute syntax hiding is ambiguous when `*` might be an unfinished delimiter or a literal character. Options include:

- smart edit transactions that retain previous marker presentation while a construct is being edited;
- intercepting common Markdown delimiter input and converting it into formatting operations; or
- narrowing the promise to “valid Markdown syntax and toolbar-created formatting stay hidden.”

### P0 — Link creation has no visible destination editor

`EditorController.insertLink` inserts `[text](https://)` and places the caret just before the closing parenthesis. The entire destination is a hidden marker range, so users type the URL into an invisible location.

This is not a minor polish issue: the primary formatting toolbar exposes a Link button, but its result cannot be confidently completed or edited.

#### Suggested direction

Use a native popover anchored to the selection or link. It should expose the destination, validate or normalize it, support existing-link editing/removal, and return focus without losing the selection.

### P0 — Inline image rendering has correctness defects

The shared rendering snapshot reproduced two visible defects:

1. the source's initial `!` remains visible; and
2. the raster is drawn upside down.

The parser records an `ImageRun` but does not add the image source range to `markerRanges`. The layout manager then draws over the source starting 12 points to the right, which leaves the leading source character visible. It also uses the `NSImage.draw(in:from:operation:fraction:)` overload in a flipped text context rather than the flipped-aware overload.

A failed or missing image has no useful rendered fallback and can expose the entire raw image expression.

#### Suggested direction

- Hide the complete image expression while preserving one draw anchor.
- Draw with flipped coordinates respected.
- Render a calm placeholder/error state using the alt text.
- Add light/dark snapshot tests for local, remote, missing, narrow, and oversized images.
- Add an image editing/removal affordance so users do not have to manipulate hidden source.

### P0 — Tab switching does not preserve the editor session

`EditorPane` creates only the active `MarkdownSourceView` and gives it `.id(doc.id)`. Changing tabs therefore replaces the representable. `EditorController` retains its text view and layout manager weakly, and no document-level state stores the scroll origin, selected range, or undo manager.

Switching away and back is therefore expected to create a new `NSTextStorage`/`NSTextView` stack, reset scroll and selection, lose the undo history, and perform another full restyle. This contradicts the nearby comment that the per-document surface preserves undo and scroll.

The notification observers registered in `MarkdownSourceView` are also not retained as tokens or removed in `dismantleNSView`, adding lifecycle/leak risk as editor views are recreated.

#### Suggested direction

Make each document own a persistent editor session containing its storage, layout manager, text view, scroll view, undo state, selection, and scroll position. The SwiftUI representable should mount that session rather than construct a new one on every tab activation.

### P0 — Autosave errors can silently lose work

For file-backed documents with auto-save enabled, `handleEdit` schedules a save but does not mark the document dirty. `saveNow` performs the UTF-8 conversion and atomic disk write synchronously on the main actor. If the write fails, it only logs to `NSLog` and leaves no durable error or dirty state for the UI.

Consequences:

- a slow disk, network volume, or file provider can block the UI 500 ms after typing stops;
- permission, disk-full, or I/O failures may be invisible;
- closing the tab/window after a failure can discard the in-memory version without a prompt; and
- the external-change path intentionally lets a pending local autosave overwrite a concurrent disk change without reconciliation.

#### Suggested direction

- Snapshot the source and write through a serial background writer with generation/version tokens.
- Represent `saving`, `saved`, and `failed` explicitly.
- On failure, keep the document dirty, surface a native error, and block silent close.
- Compare the disk version or modification identity before overwriting an external change.
- Add document-model tests for save failure, close, preference changes, and external-change races.

### P1 — Tables violate the absolute syntax-free promise

Tables render as a grid at rest, but moving the caret into one replaces the grid with raw pipe-delimited source. This is documented as an implementation deviation and is a reasonable engineering compromise, but it conflicts with current claims such as “syntax is gone, not toggled.”

#### Suggested direction

Choose explicitly between:

- building cell-level table editing, which is a substantial feature; or
- keeping the current raw-table exception and stating it honestly in product copy and launch materials.

For a deliberately simple v1, the second option is likely the better tradeoff.

### P1 — Valid GFM-related source can remain exposed

The snapshot review showed raw syntax for:

- inline HTML such as `<kbd>` and `<br>`;
- HTML blocks; and
- reference-link definitions such as `[ref]: https://example.com`.

The visible reference link itself is styled correctly, but its definition remains in the document as raw plumbing. YAML front matter and unsupported Markdown extensions will have similar ambiguity.

#### Suggested direction

Define a visible support contract for GFM constructs. Each recognized construct should have one of four intentional treatments:

1. rendered;
2. hidden as metadata;
3. shown as literal user content; or
4. surfaced as an explicitly unsupported block.

The current passthrough behavior is technically safe but contradicts the universal syntax-hiding claim.

### P1 — Scrolling contains document-wide drawing work

`MarkdownLayoutManager.drawListGuides` builds a combined array of every list marker and task on each draw, scans all of it, and may ask TextKit for glyph and bounding geometry across an entire subtree. A very long nested list can therefore defeat lazy layout while scrolling.

Table drawing also recomputes cell strings, text measurements, column widths, and grid geometry on every visible draw.

Other shell-level scaling risks include:

- the TOC uses `VStack` rather than `LazyVStack`;
- dynamic TOC defaults open it on long documents, making large heading collections especially relevant; and
- the file sidebar recursively walks and sorts the complete directory tree synchronously on the main actor.

#### Suggested direction

- Index decorations by visible character range.
- Cache list-guide and table geometry per parse/theme/container width.
- Avoid requesting layout for complete off-screen subtrees during paint.
- Use lazy TOC rows.
- Load folder children lazily or on a background task, with protection against symlink cycles.

### P1 — Image loading can cause main-thread jank and repeated full restyles

`ImageLoader` is `@MainActor`. Local file access and ImageIO downsampling happen synchronously inside `image(forSource:)`. Remote fetching suspends asynchronously, but decoding occurs in a task that inherits main-actor isolation.

When an image completes, the editor calls `restyle()` for the whole document. Multiple remote images can therefore trigger multiple full parses/renders/layout invalidations in succession. The cache is unbounded and keyed only by the source string rather than the resolved URL.

Quick Look does not install an `onChange` callback, so remote images can complete without causing the preview to redraw.

#### Suggested direction

- Resolve URLs on the main actor, then perform file/network I/O and decoding off-main.
- Bound the image cache by decoded cost.
- Key by resolved URL.
- Coalesce completions and invalidate only affected image paragraphs.
- Preserve scroll position when placeholder height changes.
- Wire Quick Look image completion into redraw/layout invalidation.

### P1 — The document rendering needs another visual pass

The baseline snapshots expose several presentation issues:

- fenced-code background color is applied to characters, producing fragmented rectangles rather than a coherent block surface;
- hidden fence lines can leave narrow background slivers;
- thematic breaks appear as faint centered `---` rather than a drawn rule;
- blockquotes are indented and italicized but do not use the available quote-bar color;
- wide tables can exceed the reading column without wrapping or another overflow treatment; and
- images lack a subtle neutral outline separating them from the page in light and dark appearances.

#### Suggested direction

Draw code-block surfaces, quote bars, rules, image outlines, and other block decorations in the layout manager using cached block geometry. Character background attributes are appropriate for inline code, not for full block containers.

### P1 — Accessibility and native interaction polish are incomplete

Several important elements are custom-drawn rather than native controls:

- task checkboxes;
- fold chevrons and collapsed expanders;
- images;
- tables; and
- some link behavior.

They currently lack corresponding accessibility elements, roles, state, labels, and actions. The underlying text view may expose raw Markdown characters to VoiceOver even though they are visually null glyphs.

Hit areas are also smaller than native accessibility guidance in several places:

- 16-point tab close buttons;
- 24–26-point titlebar buttons;
- 30-point formatting toolbar buttons; and
- 16-point fold chevron rectangles.

Custom sidebar, TOC, tab, tooltip, and smooth-scroll animations do not consult Reduce Motion even though the engineering design explicitly calls for it.

#### Suggested direction

- Expose a visible-text accessibility representation rather than the raw source.
- Add accessible elements/actions for every custom-drawn interactive item.
- Announce checkbox state, link destination/action, image alt text, table semantics, and fold state.
- Expand hit areas to at least 40–44 points without overlap.
- Respect Reduce Motion and other accessibility display preferences for custom animations.

### P1 — Current tests do not protect the whole experience

All existing tests pass, and the parser coverage is a real strength. The missing coverage is mostly at the boundaries where the product promise lives.

Important additions include:

- complete key-to-pixel performance tests or a repeatable benchmark suite;
- initial-open and full-render performance;
- layout/draw/scroll behavior on large documents;
- all caret, selection, word, line-boundary, delete, and backspace commands around markers;
- undo/redo across typing, formatting, autosave, and tab switches;
- visible link destination editing;
- image snapshot tests;
- raw/transient syntax exposure;
- table enter/exit behavior;
- find and copy semantics over hidden source;
- IME/marked text and dictation;
- accessibility output and actions;
- save failure and external-change races; and
- Quick Look remote-image refresh and centered-column parity.

## Release-readiness finding outside the editor

The full Xcode app and Quick Look extension compile, but their processed Info plists omit standard bundle metadata:

- `CFBundleIdentifier`;
- `CFBundleExecutable`;
- `CFBundleVersion`; and
- `CFBundleShortVersionString`.

The build warns that the extension version is null. Ad-hoc signing falls back to the identifier `Vireo` rather than `com.materauscher.vireo`. More importantly, `scripts/release.sh` reads `CFBundleShortVersionString` after notarization to create the release tag, so the release flow will fail at that point.

The SPM-only `scripts/Info.plist` contains these keys, but `project/App-Info.plist` and `project/QuickLook-Info.plist` do not.

This is a small fix but a release blocker. Both plists should use build-setting placeholders, and the built app/extension should be inspected in CI before notarization.

## Scope and product discipline

The implementation now includes sophisticated folding, custom tabs, inline rename, update UI, folder navigation, and several bespoke drawing behaviors. These are thoughtful features, but the remaining roadmap is increasingly dominated by complexity introduced by folds and custom chrome while core editing still has unresolved boundary behavior.

Until the P0 items are resolved, avoid adding more editor features. In particular:

- defer additional fold behavior;
- keep Quick Look thumbnails deferred;
- do not start export, Math, or Mermaid work;
- consider documenting the raw-table exception instead of building a table editor; and
- prioritize correctness and feel over expanding the feature list.

## Recommended implementation order

### Pass 1 — Contained launch blockers

1. Fix image marker hiding and flipped drawing.
2. Add the visible link destination popover.
3. Make autosave failures durable and user-visible.
4. Fix app/extension bundle metadata and verify the release script's version lookup.
5. Add regression tests for each fix.

### Pass 2 — The core editing bet

1. Specify visual/source boundary semantics.
2. Implement a centralized marker interval/index layer.
3. Cover all movement, selection, insertion, deletion, find, copy, and accessibility paths.
4. Decide how transient invalid Markdown is presented.
5. Add focused AppKit interaction tests.

### Pass 3 — Performance

1. Instrument the full live path.
2. Optimize full attributed-string construction.
3. Pass real edit deltas into the incremental engine.
4. Index run collections and visible decorations.
5. Move save and image work off the main actor.
6. Add release-mode performance budgets for representative fixtures.

### Pass 4 — Session and presentation polish

1. Persist the TextKit editor session per tab.
2. Cache list/table drawing geometry and validate scrolling.
3. Draw coherent code blocks, rules, quote bars, and image outlines.
4. Complete accessibility semantics, hit areas, and Reduce Motion support.
5. Align Quick Look layout and asynchronous image behavior with the app.

## Verification performed during this review

- `swift test`: 68 tests passed.
- `./scripts/build-app.sh release`: succeeded; emitted the existing `FileWatcher` Swift concurrency warning.
- `./scripts/build-app-xcode.sh Debug`: app and Quick Look extension built successfully; exposed missing bundle/version metadata warnings.
- Light and dark snapshots of `samples/welcome.md` were rendered through the real pipeline.
- Additional snapshots covered images, raw HTML, reference links, and table reveal state.
- Release benchmarks covered formatting-dense files and a large single fenced block.

No implementation changes were made as part of the review itself.
