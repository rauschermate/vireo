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

# Render the pipeline headlessly to a PNG (no window needed)
swift run VireoSnapshot samples/welcome.md /tmp/out.png          # light
swift run VireoSnapshot samples/welcome.md /tmp/out-dark.png --dark

# Build the full app with the embedded Quick Look extension (needs xcodegen)
brew install xcodegen
./scripts/build-app-xcode.sh Debug
open -a build/Vireo.app samples/welcome.md

# Install into /Applications and set Vireo as the default markdown app
# (double-clicking a .md in Finder then opens it in Vireo as a new tab)
./scripts/install.sh          # quick bundle; --full for the Quick Look build

# Package a distributable .dmg
./scripts/make-dmg.sh build/Vireo.app build/Vireo.dmg

# Notarized release + Sparkle appcast (needs a Developer ID — see scripts/release.sh)
./scripts/updater-keys.sh          # once: generate the EdDSA signing key
VIREO_TEAM_ID=… VIREO_SIGN_IDENTITY=… VIREO_NOTARY_PROFILE=… \
  ./scripts/release.sh --publish   # builds, signs, generates appcast.xml, uploads
```

### Auto-updates

Vireo checks for new releases in the background (Sparkle) and shows a small blue
**update pill** in the window's bottom-left corner when one is available. Click it
to download, install, and relaunch; dismiss it to be reminded on the next check.
The whole thing is driven from `VireoUpdater` (Sparkle wrapper + state machine)
and `VireoUpdaterUI` (the pill) — Sparkle's own windows are suppressed. Preview
the pill's states headlessly:

```bash
swift run VireoUpdaterSnapshot /tmp/pill.png          # light
swift run VireoUpdaterSnapshot /tmp/pill.png --dark
```

Updates only activate once `scripts/updater-keys.sh` has filled `SUPublicEDKey`
and a signed release + `appcast.xml` is published; unconfigured/dev builds keep
the updater dormant.

`scripts/build-app.sh` still produces a quick SPM-only bundle (no Quick Look
extension) for fast iteration on the app itself.

## Architecture

Local SPM packages (see `docs/eng-design.md` §10), consumed by the `Vireo` app:

| Package | Responsibility |
|---|---|
| `MarkdownEngine` | Parse GFM (swift-markdown) → marker/style ranges over the **untouched source** |
| `MarkdownRender` | Ranges → styled `NSAttributedString`; custom `NSLayoutManager` that hides syntax and draws bullets/checkboxes/images |
| `MarkdownEditor` | `NSTextView` (TextKit 1) in a SwiftUI `NSViewRepresentable`; formatting, links, floating toolbar |
| `VireoCore` | Atomic file I/O, file watcher, preferences |
| `VireoUpdater` | Sparkle wrapper + custom `SPUUserDriver` → observable update state machine |
| `VireoUpdaterUI` | The bottom-left update pill (SwiftUI), driven by `VireoUpdater` |
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
- Obsidian-style tabs (min/max-width, content-derived titles for untitled tabs,
  inline rename, double-click full screen, ⌘T/⌘W/⌘N), folder sidebar, TOC
  sidebar, focus mode, in-document find (⌘F).
- Auto-save (default) or explicit ⌘S mode; external-change reload with conflict prompt.
- Registers `.md`/`.markdown` document types (open from Finder / command line).
- **Quick Look preview extension** (`VireoQuickLook.appex`, embedded in the app)
  that renders `.md` in Vireo's style when you press space in Finder, sharing the
  exact parse → render → layout pipeline.
- Xcode project generated from `project.yml` (XcodeGen) for the app + extension;
  `.dmg` packaging and a Developer-ID notarization script.
- **Background auto-updates** (Sparkle): a dismissable blue update pill in the
  bottom-left, one-click download + install + relaunch, driven entirely from a
  custom UI (Sparkle's own dialogs suppressed).

Behavior notes: GFM tables render as a drawn grid; placing the caret inside one
reveals its raw source for editing. Task checkboxes toggle on click. Links open
on ⌘-click (plain click edits); `#anchor` and `file.md#anchor` links navigate.

## Known gaps / next steps

Smaller engineering follow-ups (from the PR #16 review) are tracked in
[`docs/roadmap.md`](docs/roadmap.md). Implementation deviations from the
eng-design are documented in [`docs/eng-design.md` §14](docs/eng-design.md).
Remaining work:

- **Caret over hidden markers**: arrow keys step through zero-width hidden marker
  characters (the eng-design's noted option-C caret nuance). Acceptable for v1.
- **Notarization** (`scripts/release.sh`) needs an Apple Developer ID — the app,
  Quick Look extension, dmg, and signing/notary scripts are all in place, but the
  actual notarized build can only be produced with your credentials.
- **Quick Look thumbnail extension** (PRD stretch) not built; QL previews can't
  load local sibling images (sandbox grants only the previewed file).
