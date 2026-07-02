# Vireo

A fast, native macOS markdown viewer and editor that renders markdown as clean
formatted text and **hides the syntax entirely — even while editing**. See
[`docs/prd.md`](docs/prd.md) for the product vision and
[`docs/eng-design.md`](docs/eng-design.md) for the architecture.

## Build & run

Requires macOS 15+, Xcode 26 / Swift 6.

```bash
# Run the test suite (parser / offset mapping)
swift test

# Build and launch a double-clickable app bundle with a sample document
./scripts/build-app.sh debug
open build/Vireo.app --args "$PWD/samples/welcome.md"

# Or render the pipeline headlessly to a PNG (no window needed)
swift run VireoSnapshot samples/welcome.md /tmp/out.png          # light
swift run VireoSnapshot samples/welcome.md /tmp/out-dark.png --dark
```

## Architecture

Local SPM packages (see `docs/eng-design.md` §10), consumed by the `Vireo` app:

| Package | Responsibility |
|---|---|
| `MarkdownEngine` | Parse GFM (swift-markdown) → marker/style ranges over the **untouched source** |
| `MarkdownRender` | Ranges → styled `NSAttributedString`; custom `NSLayoutManager` that hides syntax and draws bullets/checkboxes/images |
| `MarkdownEditor` | `NSTextView` (TextKit 1) in a SwiftUI `NSViewRepresentable`; formatting, links, floating toolbar |
| `VireoCore` | Atomic file I/O, file watcher, preferences |
| `Vireo` | SwiftUI app: tabs, sidebars, TOC, menus, zoom, auto-save |

**Core invariant:** the markdown *source string* is always the single source of
truth. The text view holds the raw markdown; syntax markers are hidden by
emitting null glyphs (present in the store, invisible on screen), so saving is
just writing `textStorage.string` back to disk unchanged.

## Implemented (v1)

- Hidden-syntax rendering & inline editing: headings, bold, italic, bold-italic,
  strikethrough, inline code, links, blockquotes, ordered/unordered/nested lists,
  task checkboxes, fenced code with syntax highlighting, images (local + remote).
- Centered reading column, OS light/dark, proportional zoom (⌘+/⌘−/⌘0).
- Floating format toolbar on selection + ⌘B/⌘I/⌘K + Format menu.
- Native macOS window tabs (one window per document, merged into a tab group),
  folder sidebar, TOC sidebar, focus mode, in-document find (⌘F).
- Auto-save (default) or explicit ⌘S mode; external-change reload with conflict prompt.
- Registers `.md`/`.markdown` document types (open from Finder / command line).

## Known gaps / next steps

These are deliberately deferred (tracked against the eng-design phase plan):

- **Implementation deviation:** uses **TextKit 1** (`NSLayoutManager`) rather than
  TextKit 2 — the null-glyph technique for hiding syntax needs glyph-level control
  that TextKit 2 doesn't expose. Documented in eng-design §4 as the pragmatic route
  to the strict "hidden even while editing" requirement.
- **Tables** render as styled monospace (pipes visible), not a laid-out grid.
- **Caret over hidden markers**: arrow keys step through zero-width hidden marker
  characters (the eng-design's noted option-C caret nuance). Acceptable for v1.
- **Quick Look extension** and **notarized `.dmg`** packaging (eng-design Phase 5)
  require a real Xcode project; `scripts/build-app.sh` produces a local, ad-hoc
  signed bundle only.
