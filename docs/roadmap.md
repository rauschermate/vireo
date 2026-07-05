# Roadmap / follow-ups

Engineering follow-ups not yet done. Most came out of the PR #16 code review
(the `ux/editing-round-3` branch); the confirmed correctness bugs from that
review are already fixed and merged into the branch — what's left here is the
lower-severity tail plus a couple of ideas worth doing when the surrounding code
is next touched.

Line numbers drift; the function/file names are the stable anchors. Each item
notes roughly how big the change is and whether it's worth doing proactively or
only "while you're in there."

---

## Correctness

### Collapsing >32 chained folds under-renders
- **Where:** `EditorController.expandOverCollapsedSubtrees` (`Sources/MarkdownEditor/EditorController.swift`, the `while changed, iterations < 32` loop).
- **What:** When a restyle window intersects a collapsed fold, the window is grown to cover the whole fold so the renderer re-applies `.vireoCollapsed` over all of it. The growth is a fixed-point loop capped at 32 iterations. With more than ~32 collapsed folds whose hide-ranges chain-overlap the dirty window, the loop returns before reaching the fixed point, so the window fails to cover the tail of an outer fold and part of a collapsed section renders visible.
- **Why it matters:** Only reachable with a deeply nested outline and 32+ collapsed anchors chaining into one edit — rare. Not a crash (the final range is clamped), just wrong rendering.
- **Fix idea:** Replace the brute-force loop with a single ordered interval-merge pass: collect every collapsed fold's hide-range, sort, and merge the ones that transitively overlap the window. Linear and obviously convergent — no magic cap. **Effort:** small–medium. Do it if folds get heavier use.

---

## Performance

### Collapsed folds leave a growing blank band
- **Where:** `MarkdownRenderer` (`Sources/MarkdownRender/MarkdownRenderer.swift`), the `minimumLineHeight = 0.01` / `maximumLineHeight = 0.01` paragraph style applied to `.vireoCollapsed` ranges.
- **What:** Each hidden line keeps a ~0.01pt line fragment (deliberate — nulling every collapsed newline would merge a whole folded section onto one line, and the TextKit-1 typesetter breaks past ~16K glyphs on a line). So a fold hiding N lines accumulates ~N × 0.01pt of height: a 2,000-line section collapses to a ~20pt gap instead of nothing.
- **Why it matters:** Purely cosmetic, but the heading-fold feature (folds can span many blocks) makes big folds far more reachable than list folds did. A user collapsing a large `#` section sees a visible blank band under the heading.
- **Fix idea:** Investigate collapsing the whole hidden run into a single near-zero-height fragment without tripping the 16K-glyph line break — e.g. a custom `NSTextAttachment`-free layout that reports one fragment for the range, or capping the accumulated fold height. **Effort:** medium (TextKit-1 layout work); verify against the collapse invariants in `MarkdownLayoutManager`.

---

## Cleanup / maintainability

### Triplicated marker scanner (with a live divergence)
- **Where:** `MarkdownParser.synthesizeDanglingItem` and `MarkdownParser.scanMarkerLength` (`Sources/MarkdownEngine/MarkdownParser.swift`), and `ListLine.parse` (`Sources/MarkdownEditor/ListLine.swift`).
- **What:** Three separate hand-rolled scanners for the same thing — indent, then bullet (`- * +`) or ordered marker (digits + `.`/`)`), then an optional `[ ]`/`[x]` task box. They already disagree: `scanMarkerLength` consumes only spaces (`0x20`) after the marker while `synthesizeDanglingItem` also consumes tabs (`0x09`), and their task-box bound checks differ (`i + 2 < end` vs `i + 3 <= contentEnd`). So an edge input like `-⇥` (dash-tab) is treated as an empty bullet by one path and not the other.
- **Why it matters:** Any future change to marker syntax (a new bullet char, a task-box variant, an ordered delimiter) must be made in three places, and a missed copy fails silently. The two engine copies live in the same file, so at minimum they should share one scanner.
- **Fix idea:** Extract one private scanner returning `(markerEnd, ordered, ordinal, delimiter, checked)` and have all three call sites use it. Reconcile the tab-vs-space and task-box-bounds behaviour while doing so (add a test for `-⇥`). **Effort:** medium; touches parser hot paths, so keep the incremental == full-parse fuzz test green.

### `subtree(forAnchor:)` duplicated across two modules
- **Where:** `EditorController.subtree(forAnchor:)` (`Sources/MarkdownEditor/EditorController.swift`) and an identical copy in `MarkdownLayoutManager.subtree(forAnchor:)` (`Sources/MarkdownRender/MarkdownLayoutManager.swift`).
- **What:** Same helper (look up a fold subtree by anchor across `listMarkers` / `tasks` / `headings`) in two modules, each doing up to three linear `.first` scans. `EditorController` also calls it inside `expandOverCollapsedSubtrees`' loop, so a collapsed-document restyle is O(iterations × collapsed × (L+T+H)) linear scans per keystroke.
- **Fix idea:** Put one implementation on `ParsedMarkdown` (both modules already depend on `MarkdownEngine`) and, if the per-keystroke scans ever show up in a profile, back it with an anchor→subtree dictionary built once per parse. **Effort:** small (dedup) / medium (index).

### `listMarkerRange(containing:)` rebuilds a Set on every caret move
- **Where:** `EditorController.listMarkerRange(containing:)` (`Sources/MarkdownEditor/EditorController.swift`), called from `MarkdownTextView`'s `moveRight`/`moveLeft`/`mouseDown`/`insertText` snap paths.
- **What:** Each call allocates a fresh `Set` of every task + list-marker anchor and linearly scans all `markerRanges`. It runs on every horizontal arrow, click, and now keystroke.
- **Why it matters:** Wasted per-action work on large documents where the marker set is stable between edits. Not user-visible today, but avoidable.
- **Fix idea:** Cache the anchor set (and/or a sorted `markerRanges`) on the parse result and invalidate on restyle. **Effort:** small.

### Per-document TOC default resolved at three sites
- **Where:** `DocumentModel` (`Sources/Vireo/DocumentModel.swift`) calls `Self.defaultTOCVisibility(for:)` in `init(url:)`, `init(untitled:)`, and `adopt`/reload.
- **What:** Three call sites must stay in lockstep with the "resolve once at open, user toggle owns it after" contract. A future fourth document-creation path (duplicate tab, session restore, drag-in) that forgets to call it silently inherits `showTOC = true`, ignoring the Off/Dynamic preference — with no compile-time signal.
- **Fix idea:** Funnel document creation through one initializer that always resolves the default, or make `showTOC` a lazily-resolved computed default. **Effort:** small.

### Caret atomicity over hidden markers only covers basic arrows
- **Where:** `MarkdownTextView` (`Sources/MarkdownEditor/MarkdownTextView.swift`) — `snapCaretAfterListMarker`, `moveRight`, `moveLeft`, `mouseDown`, `insertText` (vertical moves intentionally don't snap — see the sticky-column fix).
- **What:** The caret is kept out of hidden zero-width markers via per-action snaps. Paths not covered still land in the dead zone: shift+arrow selection, ⌥+arrow word movement, and Home/End (`moveToBeginningOfLine`/`moveToEndOfLine`). This is the documented v1 "arrows step through hidden markers" gap (see `README.md` known gaps), only partially closed.
- **Fix idea:** Evaluate the central AppKit hook `selectionRange(forProposedRange:granularity:)` to make marker ranges atomic in one place instead of override-by-override. Caveat: verify it's actually consulted for keyboard selection (it's primarily a mouse/word-granularity hook) before betting on it; if not, the per-action approach stays but should be extended to the selection and line-extreme moves. **Effort:** medium; easy to regress caret feel, so verify live.

### `tabWidths` divider allowance is an approximation
- **Where:** `TabStrip.tabWidths` (`Sources/Vireo/TabBar.swift`), the `dividers` term using `count - 2`.
- **What:** The shared tab width reserves a worst-case allowance for inter-tab dividers, but dividers are only drawn between adjacent *non-selected* tabs — so when the selected tab is interior there are fewer real dividers than reserved, leaving a small unused gap at the strip's right edge.
- **Why it matters:** Cosmetic (a few px of slack); the width is a fragile approximation rather than a derivation of the actual divider layout.
- **Fix idea:** Compute the exact divider count from the current selection, or drop the per-tab dividers in favour of spacing-only and remove the term. **Effort:** small.
