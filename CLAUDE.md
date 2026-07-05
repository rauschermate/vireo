# CLAUDE.md

Vireo is a native macOS markdown viewer/editor whose defining feature is
**hidden markdown syntax even while editing** (Medium/Notion-like). Built as
local SPM packages consumed by a SwiftUI `Vireo` app target. Requires macOS 15+,
Xcode 26, Swift 6.

See `README.md` for the feature list and `docs/eng-design.md` for the full
architecture (§14 documents as-built deviations).

## Workflow

- **Commit after every meaningful change.** Once a logical chunk of work lands
  and builds, make a git commit with a clear message. Keep commits small and
  focused — don't batch unrelated changes. Don't push unless asked.
- Prefer small, frequent commits over large ones.

## Architecture (the load-bearing decisions)

- **The source string is the single source of truth.** The `NSTextView`'s text
  storage holds the raw markdown; parsing and styling are *derived*. Saving =
  write `textStorage.string` verbatim. Never build a rich model that serializes
  back to markdown.
- **TextKit 1, not TextKit 2.** Hiding syntax needs glyph-level control TextKit 2
  doesn't expose: `MarkdownLayoutManager` (in `MarkdownRender`) emits **null
  glyphs** for `.vireoMarker`-tagged ranges — present in the store, zero-width
  and invisible on screen. The same layout manager *draws* bullets, checkboxes,
  and images (they can't be `NSTextAttachment`s — those need U+FFFC characters,
  which would break source parity).
- **Marker ranges** are computed in `MarkdownEngine` by subtracting child AST
  node ranges from delimiter-node ranges (swift-markdown). Source-location →
  UTF-16 mapping lives in `SourceMapping.swift` (handles multibyte; cmark
  columns are UTF-8 bytes, ranges half-open).
- **Incremental parsing:** `IncrementalParser` (MarkdownEngine) diffs each edit,
  re-parses only the enclosing block region, and splices. **Invariant:
  incremental output must equal a full re-parse** — enforced by scenario + fuzz
  tests in `IncrementalParserTests`. Preserve it when touching the parser.
- Module is named `VireoCore`, **not** `CoreServices` (collides with the system
  framework and breaks the build).

### Packages
| Package | Responsibility |
|---|---|
| `MarkdownEngine` | GFM parse → marker/style ranges over the untouched source |
| `MarkdownRender` | Ranges → styled `NSAttributedString`; the syntax-hiding `NSLayoutManager` |
| `MarkdownEditor` | `NSTextView` (TextKit 1) in a SwiftUI `NSViewRepresentable`; formatting, links, toolbar |
| `VireoCore` | Atomic file I/O, file watcher, preferences |
| `Vireo` | SwiftUI app: tabs, sidebars, TOC, menus, zoom, auto-save |

## Build & verify

- `swift test` — parser / offset-mapping / editor tests. Run this after any
  engine or editor change.
- `swift build` — builds the libs + `Vireo`/`VireoSnapshot` executables. These
  are **targets, not products** (deliberate: keeps the SPM `Vireo` executable
  from clashing with the Xcode app target).
- `swift run VireoSnapshot <in.md> <out.png> [--dark]` — **headless render of the
  real TextKit pipeline to PNG.** This is the primary way to verify rendering:
  screencapture of the live screen is blocked in the agent shell. (Reading the
  resulting PNG back is how you "see" the output.)
- `./scripts/build-app.sh` — quick SPM-only app bundle (no Quick Look extension),
  for fast iteration. `./scripts/build-app-xcode.sh Debug` — full app + embedded
  `VireoQuickLook.appex` (needs `xcodegen`; regenerates `Vireo.xcodeproj` from
  `project.yml`).
- **Launch the app with `open -a build/Vireo.app <files>` — never `open … --args
  <files>`.** File paths in argv put AppKit in legacy auto-open mode which
  suppresses SwiftUI scene creation entirely (the app runs windowless).
- **Do NOT `swift run Vireo`** to "check" it — it's a GUI app and blocks forever.
  Use the bundle via `open` instead.
- `CGWindowListCopyWindowInfo` *does* see the user's windows (usable to verify
  window/tab geometry), but live-pixel capture APIs are blocked.

## Gotchas

- Verifying a **SwiftUI-chrome** change (tabs, sidebars) can't be done via
  VireoSnapshot (that only renders the editor pipeline). Build the app bundle and
  launch it; inspect window/tab bounds via `CGWindowListCopyWindowInfo` if needed.
- On open-file launches the AppDelegate must order the main window front itself
  (SwiftUI creates but never orders-in the window). Never mutate `@Published`
  state during open-event delivery — defer a runloop turn.
- Keystroke latency target: ~16ms on a 1.4MB document. `swift run -c release
  VireoSnapshot <f> --bench` profiles pipeline stages (`VIREO_BENCH=1` adds parse
  sub-stages).
