# PRD — Vireo

**Name:** Vireo (locked). A macOS-native markdown viewer and editor. The goal is to be the **best in the basics**: fast, clean, distraction-free reading and editing — nothing more.

## Vision

Most markdown apps either drown the user in features or expose raw markdown syntax that non-technical users don't understand. This app does the opposite: it renders markdown as clean formatted text, hides the syntax entirely (even while editing), and gets out of the way. It should feel like reading a well-typeset document and editing it in place — the way Medium feels — not like editing code.

## Principles

- **Fast above all.** Instant launch, instant file open, no spinners, smooth scrolling, no jank on large files.
- **Native.** SwiftUI / AppKit, real macOS menus, OS-native light/dark mode, system fonts, Quick Look integration.
- **Minimal & calm.** Clean, generous whitespace, one obvious thing to do at a time.
- **No exposed syntax.** Users see formatted text, never `**bold**` or `# heading` — not in view mode, not in edit mode.
- **Zero feature creep.** When in doubt, leave it out.

## Target users

People who read and write markdown notes/docs but don't think of themselves as "markdown users" — plus power users who'll appreciate that it's fast and clean. Set-as-default-app for `.md` is a primary use case.

## Core features (v1)

### 1. Viewing
- Render markdown as clean formatted text with markdown syntax hidden.
- Center content column with a max width (~640–800px) for readability; column stays centered as the window resizes.
- Smooth scrolling.
- Light/dark mode following the OS automatically.
- **Code blocks** rendered with syntax highlighting (theme follows light/dark).
- **Images** rendered inline — both local (relative/absolute paths) and remote URLs.
- **Links:** external links open in the default browser; links between local `.md` files navigate within the app (open the target in a tab).

### 2. Editing — seamless inline ("medium" style)
- Edit directly in the rendered view; no separate "edit mode" toggle and no split preview pane.
- On text selection, show a floating **formatting toolbar** (heading, bold, italic, link, list, quote, code) positioned near the selection.
- The toolbar applies formatting **without ever exposing markdown syntax** to the user.
- Keyboard shortcuts for the same actions (⌘B, ⌘I, etc.).
- **Saving:** auto-save is the default — changes persist continuously to the underlying `.md` file as plain markdown on disk (Apple Notes–style, no ⌘S ceremony). A preferences checkbox (**Auto-save, on by default**) lets users turn it off; when off, the app switches to an explicit ⌘S dirty-document model with unsaved-changes indicators and save-on-close prompts. Full undo/redo retained in both modes.

### 3. Default app + Quick Look
- Registers as a handler for `.md` / `.markdown` files so it can be set as the default app.
- **Quick Look preview extension** so pressing spacebar in Finder renders the file in this app's style.
- (Stretch) Quick Look **thumbnail** extension for nice file icons.

### 4. Navigation chrome (all toggleable)
- **Tabs.** Single window with native macOS tabs; clicking a file in the sidebar opens it in a tab.
- **Left sidebar — file browser.** When a folder is opened, show its files and subfolders. Toggle to show/hide.
- **Right sidebar — table of contents.** Built from the document's headings; clicking a heading smooth-scrolls to it. Toggle to show/hide.
- **Focus / Zen mode.** Hides both sidebars, leaving only the centered content.

### 5. Find
- **In-document find (⌘F).** Native find bar with match highlighting and next/previous navigation, operating over the rendered text.

### 6. External file changes
- If the open file changes on disk (git pull, another editor), detect it and reload automatically. When auto-save is off and there are unsaved local edits, surface a conflict prompt (keep mine / reload theirs) rather than silently overwriting.

### 7. Native menus
- Standard macOS menu bar: **File, Edit, View, Window, Help** (and app menu).
- File: New, Open, Open Folder, Recent (Save / Save As shown only when auto-save is off).
- View: toggle left sidebar, toggle TOC, Focus/Zen mode, zoom in/out/reset.
- Edit: standard undo/redo/cut/copy/paste, Find, plus the formatting actions.

### 8. Typography & zoom
- A well-chosen default font and size tuned for reading.
- **⌘+ / ⌘− / ⌘0** to increase / decrease / reset zoom.
- Zoom scales the whole type system proportionally — headings, body, code — staying visually balanced.

## Non-goals (v1)

Deliberately **out of scope** to protect simplicity:
- Split-pane raw-markdown view / source mode.
- Plugins, themes/skins beyond light/dark, custom CSS.
- Cloud sync, accounts, collaboration, comments.

## Planned for v2

Explicitly deferred, but on the roadmap:
- **Export to PDF and HTML** (DOCX optional/later).
- **Math (LaTeX/KaTeX)** rendering.
- **Mermaid diagrams** and other embeds.

## Technical notes / risks

- **Rendering + inline editing is the hard part.** Pure SwiftUI `Text` can't do hidden-syntax editing with a live caret. This almost certainly needs **TextKit 2 (NSTextView)** with custom layout/attribute rendering so the document stays editable while syntax is hidden — wrapped in SwiftUI via `NSViewRepresentable`. This is the central engineering bet and should be prototyped first.
- **Performance on large files** likely needs incremental/virtualized layout (TextKit 2 handles much of this) and incremental markdown parsing.
- **Markdown parsing:** pick a fast, well-maintained parser (e.g. swift-markdown / cmark-gfm) and decide the supported flavor (see open questions).
- **Distribution: notarized direct download** (self-hosted `.dmg`). Chosen over the Mac App Store to keep broad file-system access for "open folder" simple and avoid review delays. Quick Look extensions and folder access still need security-scoped bookmarks for persistent permission.

## Decisions made

- **Markdown flavor: GFM** — tables, task lists, strikethrough, fenced code.
- **Saving: auto-save by default**, with a preferences toggle to switch to explicit ⌘S mode.
- **Windows: tabs** — single window, native macOS tabs.
- **Distribution: notarized direct download** — self-hosted `.dmg`, not the App Store.
- **Code blocks: syntax highlighting** — yes.
- **Images:** inline rendering of local + remote — yes.
- **Links:** external → browser; internal `.md` → navigate in-app.
- **Find (⌘F):** in scope.
- **External edits:** auto-reload on disk change, with conflict prompt when local unsaved edits exist.
- **Math / Mermaid:** deferred to v2.
