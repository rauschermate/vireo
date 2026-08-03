# Engineering Design — Vireo

Companion to [`prd.md`](./prd.md). The PRD says **what** and **why**; this doc says **how**. It fixes the architecture, names the central technical bet, and lays out a phased build plan that de-risks the hard part first.

Status: draft for v1. Anything marked **(spike)** must be validated by a working prototype before we commit to it.

---

## 1. Scope & the one hard problem

Most of Vireo is conventional, well-trodden macOS work: tabs, sidebars, a TOC, find, native menus, file I/O. If that were all, we'd just start coding.

The one genuinely hard, product-defining problem is **§2 of the PRD: seamless inline editing with markdown syntax fully hidden — in view *and* edit mode, with a live caret.** Get this right and Vireo exists; get it wrong and no amount of chrome saves it. So this doc is deliberately weighted toward the editor engine, and the build plan (§12) starts there.

Everything else is designed to be replaceable/conventional and to sit *around* the editor, not *inside* it.

---

## 2. Platform & toolchain

- **Language:** Swift 6.3 (strict concurrency on where practical; the text engine touches AppKit main-actor APIs heavily, so it lives on `@MainActor`).
- **Min deployment target:** **macOS 15 (Sequoia)**. Rationale: TextKit 2 (`NSTextLayoutManager`) only became fully load-bearing and bug-stable in recent releases, and we get modern SwiftUI window/scene APIs. We lose nothing by not chasing macOS 12–14 — our users are on current hardware and this is a new app. Revisit only if a concrete user demands an older OS.
- **UI:** SwiftUI for the app shell (window, scene, tabs, sidebars, menus, preferences) wrapping AppKit (`NSTextView` via `NSViewRepresentable`) for the editing surface.
- **IDE/build:** Xcode project (`.xcodeproj` or `.xcworkspace`) because we need app + Quick Look **extension** targets and notarization, which SPM alone can't produce. Core logic lives in **local SPM packages** the app target depends on (see §10) so it's unit-testable without launching the app.

---

## 3. Architecture at a glance

```
┌───────────────────────────────────────────────────────────────┐
│  App shell (SwiftUI)                                           │
│  scenes · tabs · left sidebar (files) · right sidebar (TOC)    │
│  menus · preferences · zoom · find bar                         │
└───────────────┬───────────────────────────────────────────────┘
                │ binds to
┌───────────────▼───────────────────────────────────────────────┐
│  DocumentModel  (one per open file / tab)                      │
│  • source of truth = the markdown String on disk               │
│  • parsed AST (swift-markdown)  • TOC  • dirty/auto-save state  │
└───────┬───────────────────────────────┬───────────────────────┘
        │                               │
┌───────▼─────────────┐   ┌─────────────▼─────────────────────────┐
│  MarkdownEngine     │   │  EditorView (NSViewRepresentable)      │
│  • parse (cmark-gfm) │  │  • NSTextView + TextKit 2              │
│  • incremental       │  │  • MarkdownTextStorage (holds source) │
│    re-parse          │  │  • hides syntax via custom layout     │
│  • AST → styling     │  │  • floating format toolbar            │
│    attributes        │  │  • edits mutate source → re-parse     │
└─────────────────────┘   └───────────────────────────────────────┘
        │
┌───────▼─────────────────────────────────────────────────────────┐
│  FileService  ·  bookmarks (security-scoped)  ·  fs watcher      │
│  auto-save / dirty model  ·  external-change reconcile           │
└─────────────────────────────────────────────────────────────────┘
```

**Key invariant:** the **markdown source string is always the source of truth.** The text view holds the real markdown characters; the AST and all styling are *derived*. We never keep a separate "rich" model that must be serialized back — that path (rich model → markdown) is a round-trip fidelity swamp. Saving is therefore trivial: write the text storage's backing string to disk, unchanged.

---

## 4. The bet: hidden-syntax inline editor (spike)

### 4.1 The requirement, precisely

PRD line 14: users never see `**bold**` or `# heading` — **not in view mode, not in edit mode.** This is stricter than Typora/MarkEdit, which *reveal* the raw markers when your caret enters a span. Vireo wants the markers gone even while editing that line.

### 4.2 Options considered

**A. Rich-text backing store, serialize to markdown on save.**
Rejected. Round-trip fidelity (preserving exact source, link reference styles, hard breaks, list markers) is notoriously lossy and buggy. Contradicts "plain markdown on disk continuously."

**B. Source backing store + reveal-on-cursor (Typora/CodeMirror model).**
The text storage holds raw markdown; markers are styled hidden *except* on the line/span containing the caret, where they reappear so you can edit them. Proven, shippable, comparatively cheap.
Downside: violates the strict PRD reading — syntax *does* momentarily show on the active line.

**C. Source backing store + always-hidden markers via TextKit 2 custom layout.**
The text storage holds raw markdown; syntax marker character ranges are collapsed to zero width by a custom `NSTextLayoutFragment` / attribute so they never render, and caret navigation treats them as atomic (arrow keys and clicks skip over the hidden markers as if they weren't there). Backspace at a span edge deletes the whole construct's markers together.
This is the true realization of the PRD. It is also the hard, unproven part.

### 4.3 Recommendation

**Target C, with B as the de-risking fallback.** Build the Phase-0 spike to attempt C directly. If C proves too unstable within the spike's time box (caret glitches, selection weirdness, IME/emoji edge cases), we ship B for v1 — which still *looks* fully rendered at rest and only reveals syntax on the exact line being edited — and revisit C later. This decision is made **at the end of the spike, on evidence**, not now.

Either way the backing store is the markdown source, so the fallback is a localized change in the layout/caret layer, not an architecture rewrite.

### 4.4 How C works (design sketch)

- **`MarkdownTextStorage: NSTextStorage`** subclass whose characters are the raw markdown. On every edit it asks `MarkdownEngine` for the affected node(s) and applies:
  - *visual attributes* to content ranges (font, weight, color, paragraph style for headings/quotes/lists/code), and
  - a *"syntax marker" attribute* on the delimiter ranges (`#`, `**`, `` ` ``, `>`, list bullets' raw chars, link brackets/URLs).
- **TextKit 2 layout** (`NSTextLayoutManager` + custom `NSTextLayoutFragment`) renders marker-attributed ranges at **zero width / not drawn**, so `# ` and `**` occupy no visual space.
- **Caret & selection** use a custom logic layer that maps *visual positions* to *source positions*, so pressing → at the end of visible bold text lands after the construct, skipping the hidden `**`. Selection ranges snap to whole constructs at their boundaries.
- **Links** render as styled text; the URL and brackets are marker ranges (hidden). A hover/edit affordance exposes the URL when needed.
- **Round-trip** is free: `textStorage.string` *is* the markdown; `FileService` writes it verbatim.

### 4.5 What the spike must prove

The Phase-0 spike is a throwaway single-window app that opens one hardcoded `.md` and must demonstrate, on a real document containing headings, bold/italic, inline code, a fenced code block, a list, a blockquote, and a link:

1. Syntax markers are invisible at rest.
2. You can place the caret, type, and delete with markers staying hidden and the caret behaving sanely (no stuck/echoing caret over hidden ranges).
3. Editing a word re-parses and re-styles only locally, with no visible flash/relayout of the whole doc.
4. `textStorage.string` round-trips byte-identically to the file when unchanged, and to valid GFM after edits.
5. It stays smooth (no perceptible jank) on a ~1–2 MB markdown file.

If 1–5 hold, C is green. If caret/selection (item 2) is the only failure, fall back to B and keep 1,3,4,5.

---

## 5. Markdown parsing & document model

- **Parser: [`swift-markdown`](https://github.com/apple/swift-markdown)** (Apple, cmark-gfm-backed). Gives us a typed GFM AST (headings, emphasis, lists, task list items, tables, strikethrough, fenced code, links, images) matching the PRD's decided flavor, is well-maintained, and is a natural Swift fit. cmark-gfm directly is the fallback if we need lower-level control over source ranges.
- **Visible support contract:** [`markdown-support.md`](./markdown-support.md) defines the intentional on-canvas treatment for GFM, source metadata, inline HTML, and unsupported extensions. Recognized source is always rendered, collapsed as metadata, shown literally, or surfaced as unsupported—never leaked accidentally.
- **Source ranges:** we need each AST node's exact character range in the source to place styling and marker attributes. swift-markdown exposes `SourceRange`; we validate in the spike that ranges are precise enough (a known watch-item — if not, drop to cmark-gfm which gives byte offsets).
- **Incremental re-parse:** on edit, re-parse the smallest enclosing block (paragraph/list-item/code-block) rather than the whole document. Full-document re-parse is the fallback for structural edits (e.g. typing `` ``` `` that opens a fence). Keep a debounce so rapid typing coalesces. Actual granularity is tuned in the spike against the perf target.
- **DocumentModel** owns: the source string, the current AST, the derived **TOC** (heading nodes → title + range), and save/dirty state. One instance per tab.

---

## 6. Rendering specifics

- **Code blocks — syntax highlighting.** Use a native highlighter (e.g. `Splash` for Swift-first, or a tree-sitter/`Highlightr` approach for many languages — decided in Phase 3; not on the critical path). Theme follows light/dark. Rendered as a styled fenced block with the fence markers hidden.
- **Images.** Inline `NSTextAttachment`-based rendering. Local paths resolved relative to the document's folder (needs the security-scoped bookmark, §7); remote URLs fetched async with a placeholder → swap on load, cached in-memory. Never block layout on a network image.
- **Links.** External (`http(s)`) → `NSWorkspace.open`. Internal `.md` (relative path) → resolve against the doc folder and open in a new tab via the app shell. Anchor links (`#heading`) → scroll within the doc.
- **Theming.** Light/dark only (PRD non-goal: custom themes). Colors from a single semantic palette that reads the OS appearance; zoom (§8) scales a base type-scale token that all fonts derive from, so headings/body/code stay proportional. Chrome uses the system **Liquid Glass** materials (see §8.0); the reading canvas stays calm and opaque.

---

## 7. Files, saving, external changes

- **Open file / open folder** via `NSOpenPanel`; persist access across launches with **security-scoped bookmarks** (required for sandbox-free notarized distribution to reliably re-access folders and for the Quick Look extension). A small bookmark store keyed by path.
- **Auto-save (default on).** Debounced write of the source string to disk after edits settle (e.g. ~500 ms idle) and on blur/close. Atomic write (write temp + rename) to avoid truncation on crash.
- **Explicit-save mode (pref off).** Standard dirty-document model: `NSDocument`-style edited flag, ⌘S, unsaved indicator in the tab, save-on-close prompt. We get much of this for free if each document is backed by an `NSDocument` subclass — **decision: use `NSDocument`** as the per-file controller in both modes (it also gives us Recent Files, autosave plumbing, and revert). Auto-save mode simply drives it via `autosavesInPlace`.
- **External change detection.** A file-system watcher (`DispatchSource` vnode watch, or `FSEvents` for folders) per open file. On external change:
  - no local unsaved edits → reload silently.
  - local unsaved edits (explicit-save mode) → conflict prompt: *Keep Mine / Reload Theirs*.

---

## 8. App shell (the conventional 80%)

### 8.0 Design language — Liquid Glass

Vireo adopts Apple's **Liquid Glass** design language (introduced WWDC 2025, the default look of macOS 26+). This is a direct expression of the PRD's "Native" and "Minimal & calm" principles — we use the *system's* materials rather than inventing our own chrome.

- **Let the OS do it.** On our macOS 15+/26 baseline, standard SwiftUI containers — the window, toolbar, sidebars, tab bar — adopt Liquid Glass automatically when built with the current SDK. We lean on that default and avoid custom backgrounds that would opt us out of it. Where we place bespoke floating surfaces we apply the glass material explicitly (SwiftUI `.glassEffect(...)` / `glassEffectContainer`, `NSGlassEffectView` on the AppKit side).
- **Chrome is glass; the page is paper.** The reading surface is the star. Chrome (sidebars, toolbar, tab bar, the floating format toolbar, find bar, popovers) uses the translucent, layered Liquid Glass material and floats over content; the centered content column itself stays a calm, legible, largely opaque "sheet of paper." We do **not** glassify the text canvas — legibility and reading comfort win over effect.
- **The floating format toolbar** (§8 below) is the signature Liquid Glass surface: a small concentric-radius glass panel that hovers near the selection, with the standard adaptive tint and shadow rather than a hand-rolled style.
- **Concentric geometry & spacing.** Follow the updated HIG: concentric corner radii (controls nested inside containers share the container's rounding), the refreshed control shapes/sizing, and generous margins so glass layers read cleanly.
- **Legibility guardrails.** Liquid Glass is translucent, so we rely on the system's automatic contrast/vibrancy adaptation and respect **Reduce Transparency** / **Increase Contrast** / **Reduce Motion** accessibility settings (the system materials handle these, which is another reason to use them rather than custom blur). Never place body text directly on a glass layer.
- **Light/dark** (§6) is unchanged — Liquid Glass materials are appearance-aware and adapt automatically.

This is a styling/adoption concern, **not** an architectural risk: it rides on standard SwiftUI/AppKit containers and touches only the shell, never the editor engine or the source-of-truth model. It lands naturally in Phase 2 (shell) and Phase 3 (floating toolbar).

### 8.1 Components

SwiftUI, one scene, native tabs. These are intentionally standard and low-risk:

- **Tabs** — SwiftUI window with `.tabbingMode`; each tab hosts one DocumentModel + EditorView. Opening a file/link adds a tab.
- **Left sidebar (files)** — `List`/`OutlineGroup` over the opened folder; toggleable. Selecting a file opens/focuses its tab.
- **Right sidebar (TOC)** — driven by `DocumentModel.toc`; click → smooth-scroll the text view to the heading's range. Toggleable.
- **Focus/Zen** — hides both sidebars (state toggle).
- **Find (⌘F)** — native `NSTextFinder` wired to the `NSTextView`, operating over the rendered/source text with match highlight + next/prev.
- **Menus** — SwiftUI `Commands` for File/Edit/View/Window/Help; Save/Save As shown only in explicit-save mode; View toggles + zoom; Edit gets the formatting actions (⌘B/⌘I/etc.) that call the same code as the floating toolbar.
- **Floating format toolbar** — an `NSPanel`/overlay positioned near the selection rect; buttons mutate the source (wrap selection in `**`, prefix line with `#`, etc.) through one `FormattingController` that both the toolbar and keyboard shortcuts share.

---

## 9. Quick Look extension

- **Preview extension** (`QLPreviewingController`) that renders the `.md` in Vireo's style. It must share the rendering path, so the **AST→attributed-string styling lives in a package** (`MarkdownRender`) usable from both the app and the extension (extensions can't depend on the full app). No editing in the preview — read-only render only.
- **Thumbnail extension** — PRD stretch goal; same package, render to image. Defer to after v1 core.
- Extension file access uses the security-scoped bookmark model (§7).

---

## 10. Project & module structure

```
Vireo.xcworkspace
├── Vireo (app target)                    SwiftUI shell, NSDocument, EditorView
├── VireoQuickLook (extension target)      QLPreviewingController
└── Packages/ (local SPM)
    ├── MarkdownEngine    parse + incremental re-parse + AST + source ranges
    ├── MarkdownRender    AST → attributed styling  (shared app + QuickLook)
    ├── MarkdownEditor    MarkdownTextStorage, TextKit 2 layout, caret logic
    └── CoreServices      FileService, bookmarks, fs watcher, prefs
```

Packages have unit tests and no AppKit UI dependency except `MarkdownEditor` (which is AppKit-bound by nature). This keeps the parsing/rendering/round-trip logic testable headlessly.

---

## 11. Distribution & signing

- **Notarized direct download**, self-hosted `.dmg` (PRD decision). Developer ID signing + `notarytool` in a release script. Not sandboxed (keeps "open folder" simple), which is why persistent access relies on security-scoped bookmarks rather than sandbox entitlements.
- Release automation is out of scope for the spike; a `scripts/release.sh` comes in Phase 5.
- **Auto-update via Sparkle.** Non–App-Store direct downloads need an in-app updater. Vireo uses **Sparkle** (proven EdDSA-signed download / atomic self-replace / relaunch) but suppresses Sparkle's own UI and renders the whole update surface as a small **update pill** in the window's bottom-left (modeled on cmux). Scheduled background checks make it appear on its own; a click downloads + installs + relaunches; it's dismissable. See §14 for the as-built shape and the release/appcast flow.

---

## 12. Phased build plan

Each phase ends with something runnable. **Phase 0 gates everything** — we don't build the shell until the editing bet is proven.

- **Phase 0 — Editor spike (the bet).** Throwaway app, one hardcoded file. Prove §4.5 items 1–5. Decide C vs B. *Exit criteria: the five proofs hold.*
- **Phase 1 — Core editor + model.** Promote the winning approach into `MarkdownEditor` + `MarkdownEngine` + `MarkdownRender` packages. Real DocumentModel, incremental re-parse, all GFM elements styled, images, code highlighting stub. Open a file passed on the command line. Round-trip + parse unit tests.
- **Phase 2 — App shell.** SwiftUI scene, NSDocument, tabs, open file/folder, left sidebar, TOC sidebar, zoom, menus, focus mode.
- **Phase 3 — Editing UX.** Floating toolbar + shortcuts via FormattingController, links (external/internal/anchor) navigation, code-block syntax highlighting for real, find bar.
- **Phase 4 — Files & robustness.** Auto-save + explicit-save modes, dirty/save-on-close, security-scoped bookmarks, external-change watcher + conflict prompt, Recent.
- **Phase 5 — Quick Look + distribution.** Preview extension (shared render package), then thumbnail (stretch). Signing/notarization/dmg release script.

v2 items (PDF/HTML export, KaTeX, Mermaid) are explicitly out of this plan.

---

## 13. Risks & open questions

- **(High) Always-hidden markers + sane caret (§4.3 option C).** The central risk; explicitly time-boxed in Phase 0 with a defined fallback (B). Everything downstream is insulated because the source string stays the source of truth.
- **(Med) swift-markdown source-range precision.** If node→source ranges aren't exact enough to place marker attributes, drop to cmark-gfm byte offsets. Validate in Phase 0.
- **(Med) Incremental re-parse granularity vs correctness.** Structural edits (opening a fence, changing list nesting) can affect beyond the local block. Start conservative (re-parse enclosing block, full-doc fallback on fence/structure changes), tune against the perf target.
- **(Low) Remote image fetching & caching policy.** Async with placeholder; bound cache; never block layout.
- **(Low) Non-sandboxed + bookmarks correctness** for the Quick Look extension's file access.

### Open questions to confirm

1. **macOS 15 baseline OK?** (Assumed yes — new app, current hardware.)
2. **Strict always-hidden syntax (C) vs pragmatic reveal-on-active-line (B)** if the spike forces a choice — is B an acceptable v1, or is C a hard gate? (Design assumes B is an acceptable fallback.)
3. **Bundle ID / team** for signing (needed by Phase 5, not before).

---

## 14. Implementation deviations (as built, v1)

Where the shipped implementation intentionally differs from the sections above:

- **TextKit 1, not TextKit 2 (§2, §4).** The always-hidden-syntax bet (option C)
  shipped — but via `NSLayoutManager` null glyphs, which need glyph-level control
  TextKit 2 doesn't expose. The spike's real outcome: C is achievable, on TK1.
- **One visual/source boundary model (§4).** Parsed marker ranges are normalized
  into an indexed `MarkerIndex`; caret movement, Shift/Option selection, line
  boundaries, insertion, atomic deletion, hit testing, Find, copy/cut and
  accessibility all map through it. If an already-rendered construct becomes
  temporarily invalid, its surviving delimiters retain their hidden presentation
  while the user remains in that paragraph. Newly typed unmatched punctuation is
  literal (and therefore visible) until it forms valid Markdown; leaving the
  repair paragraph commits any still-invalid punctuation as literal content.
- **Custom tab strip, not native window tabs (§8).** Native `NSWindow` tabbing
  shipped first, then was replaced: the system tab bar always fills the window
  width and offers no hooks for min/max-width tabs, content-derived titles,
  inline rename, or double-click actions (the Obsidian-style design the product
  settled on). The app is a single `Window` scene with an ordered document list
  and a SwiftUI tab bar; the window-close prompt walks all open tabs.
- **Custom `DocumentModel`, not `NSDocument` (§7).** The dirty model, save-on-close
  prompts, window dirty-dot/proxy-icon and Recents are hand-rolled (a
  `WindowDelegateProxy` adds `windowShouldClose`, `Preferences` keeps Recents).
  Rationale: the SwiftUI scene + native-window-tabs architecture (one
  `WindowGroup` instance per document) fit poorly with `NSDocument`'s
  window-controller model. Revisit only if document features outgrow this.
- **No security-scoped bookmarks (§7).** The app is not sandboxed (per §11), so
  plain paths persist fine; TCC prompts cover protected folders. The sandboxed
  Quick Look extension gets read access to the previewed file from Quick Look
  itself — but **cannot** load sibling local images (only remote, via the
  network-client entitlement). Bookmarks return to scope only if we ever sandbox.
- **Tables (§6 addendum).** GFM tables render as a drawn grid over transparent
  source text (null-hiding the whole table would collapse line heights). The grid
  now remains in place during editing: clicking or navigating into a cell mounts
  one native field over that cell, Tab/Shift-Tab/Return navigate the grid, and a
  compact cell menu adds/deletes rows or columns and changes alignment. Inline
  formatting and link destinations survive visible-text edits. Raw pipes and the
  separator row are never revealed.
- **Incremental re-parse (§5) — implemented.** `MarkdownTextView` passes a
  single AppKit-approved UTF-16 edit directly to `IncrementalParser`, avoiding
  a full-source allocation and prefix/suffix scan for ordinary typing. IME,
  undo, and multi-edit transactions retain the safe source-diff fallback. The
  parser expands the edit to blank-line/block boundaries
  (blocks may span blank lines: fences, HTML), re-parses only that slice with
  cmark, and splices it into the previous parse; attributes are re-applied only
  over the dirty range, bounding TextKit's layout invalidation. Sorted,
  non-overlapping run collections use binary-search slicing rather than a
  document-wide filter. Non-local edits
  (unbalanced fences, link reference definitions) fall back to a full parse.
  Contract enforced by tests: incremental output must be *identical* to a full
  re-parse (scenario + fuzz coverage). Measured keystroke cost: ~4.5 s → ~16 ms
  on a 1.4 MB document, ~240 ms → ~1.5 ms at 162 KB (release).
- **Full rendering performance (§4.5) — measured and budgeted.** Rendering now
  builds a sorted mutation plan, resolves overlapping block/inline/custom
  attributes in one boundary sweep, and applies the final runs directly to live
  `NSTextStorage`; the editor no longer builds an intermediate attributed string
  and enumerates it back into storage. Fonts, dynamic colors, dictionaries, and
  paragraph styles are cached once per render. Fenced blocks above 256 KiB keep
  their code font/surface but skip synchronous regex token coloring. Instruments
  signposts cover source notification, parse/splice, style application, glyph
  generation, and visible draw. TextKit layout is viewport-demand-driven:
  layout managers allow non-contiguous layout, and zero-sized pre-mount redraw
  invalidations explicitly avoid generating glyphs. Constructing an editor or
  jumping to a distant viewport therefore does not first typeset the full
  document.
  - Run the deterministic release suite with
    `swift run -c release VireoSnapshot --benchmark-suite --samples 5`.
  - Export the same large sources for manual app review with
    `swift run -c release VireoSnapshot --write-benchmark-fixtures <directory>`.
  - Add `--assert-budgets` to enforce attributed-render p95 ≤ 1 s and current
    open-to-pixel p95 ≤ 4 s on the deliberately adversarial 1.68 MiB dense
    fixture. The combined gate includes parsing, direct live application,
    initial viewport layout, and visible drawing.
- **Liquid Glass (§8.0).** The floating toolbar uses `NSGlassEffectView` on
  macOS 26+ (material fallback on 15); sidebars use standard system materials.
- **Quick Look thumbnail extension** (§9 stretch) not built.
- **Auto-updater (§11) — Sparkle, with a custom pill.** Two SPM libs keep the
  Sparkle plumbing out of the app: `VireoUpdater` owns the `SPUUpdater` and a
  custom `SPUUserDriver` that maps Sparkle's lifecycle onto an observable
  `UpdateModel` state machine (idle → checking → available → downloading →
  extracting → installing → error), and `VireoUpdaterUI` is the bottom-left
  pill. All of Sparkle's stock windows are suppressed; the driver auto-allows the
  permission prompt and, once the user clicks, drives straight through to
  install + relaunch (no second confirmation). The updater stays **dormant**
  unless the bundle carries a non-empty `SUFeedURL` **and** `SUPublicEDKey`, so
  ad-hoc dev builds (`build-app.sh`, empty key) never self-update — only the
  signed release build does.
  - *Feed & release flow.* `SUFeedURL` points at
    `releases/latest/download/appcast.xml`, a GitHub "latest release" alias that
    always resolves to the newest release's `appcast.xml` asset. `release.sh`
    builds + notarizes the DMG, then `generate_appcast` (Sparkle) EdDSA-signs it
    and writes the appcast; `--publish` uploads both to the GitHub release. The
    EdDSA key is generated once by `updater-keys.sh` (private key in the login
    keychain; public key baked into `App-Info.plist`).
  - *Xcode wiring gotcha.* Sparkle's dynamic XCFramework is embedded via the
    app target's direct package dependency (its XPC helpers + `Autoupdate` ride
    along); `VireoUpdater` links it transitively, so **no** explicit embed phase
    is added (that duplicates the copy and fails the build). Separately, an
    explicit shared **scheme** named `Vireo` was added to `project.yml`: the app
    target and the SPM package's `Vireo` executable target share a name, and
    without a shared scheme `xcodebuild -scheme Vireo` builds the bare executable
    instead of `Vireo.app` (a latent issue predating the updater).
  - *Verifying the pill.* Live screen capture is blocked, so
    `VireoUpdaterSnapshot` renders the pill in every phase to a PNG (same idea as
    `VireoSnapshot` for the editor); `UpdateModel.preview(_:)` pins a visual
    state for that and for SwiftUI previews.
