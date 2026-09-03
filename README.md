# Vireo

Vireo is a fast, native macOS markdown viewer and editor. It renders markdown
as clean formatted text and hides the syntax.

The block that holds the caret shows its raw syntax, dimmed. Every other
block stays clean. When the caret moves away, the block hides its syntax
again.

See [`docs/prd.md`](docs/prd.md) for the product vision. See
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

#### Turning on auto-updates / cutting a release

One-time setup, then a repeatable release step:

1. **Generate the signing key (once per machine that cuts releases).**
   ```bash
   ./scripts/updater-keys.sh
   ```
   Writes the EdDSA public key into `project/App-Info.plist` (`SUPublicEDKey`);
   the private key stays in your login keychain. Commit the updated plist. Back
   the private key up offline — losing it means users can't verify future
   updates (they'd have to reinstall manually):
   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.pem
   ```

2. **Have a Developer ID + notary profile ready** (see the header of
   `scripts/release.sh`): `VIREO_TEAM_ID`, `VIREO_SIGN_IDENTITY`, and a
   `VIREO_NOTARY_PROFILE` created once via `xcrun notarytool store-credentials`.

3. **Bump the version** in `project.yml` (`MARKETING_VERSION`, and
   `CURRENT_PROJECT_VERSION` for each build) so the new release outranks the
   installed one.

4. **Build, sign, generate the appcast, and publish:**
   ```bash
   VIREO_TEAM_ID=… VIREO_SIGN_IDENTITY=… VIREO_NOTARY_PROFILE=… \
     ./scripts/release.sh --publish
   ```
   This notarizes `Vireo.dmg`, EdDSA-signs it, generates `appcast.xml`, and
   uploads both to a `v<version>` GitHub release. (Omit `--publish` to build the
   artifacts locally and print the upload command instead.)

Existing users' update pill then surfaces within `SUScheduledCheckInterval` (1h),
or immediately via **Vireo ▸ Check for Updates…**. The feed URL
(`releases/latest/download/appcast.xml`) is a GitHub alias that always resolves
to the newest release's appcast, so nothing else needs updating between releases.

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
truth. The text view holds the raw markdown. Syntax markers are hidden by null
glyphs: present in the store, invisible on screen. Saving writes
`textStorage.string` back to disk unchanged.

The caret's block is the one exception. Its markers render as dimmed text, so
the caret walks real characters and backspace deletes the character you see.

## Implemented (v1)

- Clean rendering with caret-block syntax reveal: headings, bold, italic,
  bold-italic, strikethrough, inline code, links, blockquotes,
  ordered/unordered/nested lists (nested ordered display cycles 1. → a. → i.),
  task checkboxes, fenced code with syntax highlighting, images (local + remote).
- List editing: Enter continues a list and renumbers the ordered items below;
  Enter on an empty item walks out one level; Tab/⇧Tab indent and outdent.
- Centered reading column, OS light/dark, proportional zoom (⌘+/⌘−/⌘0).
- Floating format toolbar on selection + ⌘B/⌘I/⌘K + Format menu.
- Obsidian-style tabs (min/max-width, content-derived titles for untitled tabs,
  inline rename, double-click full screen, ⌘T/⌘W/⌘N), workspace sidebar
  (Pinned / Recents / Everything tree, ⌘P quick-open, drag-to-move, inline
  rename, context menus, resizable), TOC sidebar, focus mode, in-document
  find (⌘F).
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

Behavior notes: GFM tables always render as a drawn grid; a click on a cell
opens a native cell editor over it, so the raw pipes never appear. Task
checkboxes toggle on click. Links open on ⌘-click (plain click edits);
`#anchor` and `file.md#anchor` links navigate.

## Known gaps / next steps

Implementation deviations from the eng-design are documented in
[`docs/eng-design.md` §14](docs/eng-design.md). Remaining work:

- **Caret polish across hidden blocks**: inside the caret's block the caret
  walks real characters. Movement across *other* blocks still crosses hidden
  markers through per-command snapping, and some paths (Home/End, ⌥-arrows)
  keep small gaps. Acceptable for v1.
- **Notarization** (`scripts/release.sh`) needs an Apple Developer ID — the app,
  Quick Look extension, dmg, and signing/notary scripts are all in place, but the
  actual notarized build can only be produced with your credentials.
- **Quick Look thumbnail extension** (PRD stretch) not built; QL previews can't
  load local sibling images (sandbox grants only the previewed file).
