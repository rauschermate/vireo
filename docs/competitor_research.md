# Markdown Readers / Editors — Competitor Research

Focus: macOS-first, with cross-platform options noted. Grouped by tech stack, since that's where the real character differences live (native apps feel fast/light/Mac-like; Electron apps are heavier but cross-platform and extensible).

Date: June 2026

---

## Native macOS (Swift / AppKit / SwiftUI)

Fast launch, low memory, system fonts, real Apple chrome.

### iA Writer
- **Design:** Probably the most influential design in the category. Custom-designed monospace + duospace fonts, focus mode that dims everything but the current sentence, built-in "Authorship" tracking that visually distinguishes human-written from AI-generated text.
- **Stack:** Native (macOS/iOS); also ships on Windows/Android.
- **Pricing:** $49.99 one-time on Mac (iOS purchased separately).
- **Popularity:** Highly regarded; inspired a generation of distraction-free editors. Design has aged extremely well over a decade.
- **Trade-offs:** Opinionated about how you write. No Mermaid, no LaTeX. Pricey.

### Bear
- **Design:** Arguably the most visually polished note-style markdown editor on Apple platforms. Beautiful themes, gorgeous typography, hashtag-based (nested tag) organization.
- **Stack:** Native Apple-only (Mac, iPhone, iPad). Web beta launched Feb 2026, still early.
- **Pricing:** Subscription, Bear Pro ~$2.99/mo (adds sync + export to PDF/DOCX/HTML/JPG/ePub).
- **Popularity:** Award-winning, strong following among Apple-ecosystem writers.
- **Trade-offs:** Uses a modified flavor ("Polar Bear" markdown) stored in a database, not loose `.md` files. Apple-only lock-in. No Mermaid/LaTeX/plugins.

### Ulysses
- **Design:** Premium, clean, designed for long-form (books, article series, documentation sets). Library/sheet metaphor instead of files. Typewriter mode, dark themes, full-screen.
- **Stack:** Native Apple-only (Mac, iPad, iOS), near-identical experience across devices.
- **Pricing:** Subscription, ~$5.99/mo or ~$39/yr (covers all Apple platforms).
- **Popularity:** Mac App Store editor's choice; the go-to "writer's tool."
- **Trade-offs:** Uses its own "Markdown XL" flavor and a proprietary database (not flat `.md`). Overkill for quick notes.

### MarkEdit
- **Design:** Deliberate "TextEdit but for Markdown" aesthetic — clean, native, minimal. Native macOS UI controls (force-touch lookup, inline predictions, Writing Tools). No live preview by default; it's a pure editor (a `MarkEdit-preview` extension adds a preview pane).
- **Stack:** Native Swift + AppKit; editor surface built on CodeMirror 6 (multi-caret, code folding). ~4 MB installer, edits 10 MB / million-line files easily.
- **Pricing:** Free, open source (MIT). No telemetry.
- **Popularity:** Trending among developers/writers who want native performance + privacy. Available on Mac App Store, TestFlight, Homebrew (`brew install --cask markedit`).
- **Trade-offs:** Strict GFM only (no proprietary syntax). No live preview out of the box.

### MacDown
- **Design:** Classic split-pane (editor + live HTML preview), web-developer-flavored. Configurable syntax highlighting, TeX-like math, autocompletion.
- **Stack:** Native Cocoa, open source (MIT). Spiritual successor to Mou.
- **Pricing:** Free.
- **Popularity:** Long-standing favorite, but maintenance has slowed; a community fork ("MacDown 3000") is the current torch-bearer.
- **Trade-offs:** Hasn't reached parity with modern editors (no instant WYSIWYG, no cloud sync, no AI features).

### Also native / niche
- **Byword** — minimal, Markdown-focused; paid, subscription pricing.
- **MiaoYan** — lightweight, local-first, three-pane layout (folders/list/editor), presentation/PPT mode, LaTeX + Mermaid + PlantUML + Markmap baked in. Swift native.
- **Drafts** — quick-capture first; strong on iPad; generous free tier.

---

## Electron / Web-tech

Heavier (200–400 MB RAM is normal), but cross-platform and extensible.

### Obsidian
- **Design:** Default UI is utilitarian but extremely theme-able (Minimal, Things, AnuPpuccin). The draw is functionality: bidirectional `[[wikilinks]]`, graph view, 2000+ community plugins (Dataview, Excalidraw, Templater).
- **Stack:** Electron. Team has done unusual work to keep it responsive on large vaults. Files stored locally as plain `.md` in a "vault" folder.
- **Pricing:** Free for personal; $50/yr Catalyst (supporter); $8/mo for Sync; commercial license $50/yr.
- **Popularity:** Arguably the most popular markdown tool overall in 2026.
- **Trade-offs:** Electron memory weight (~300+ MB RAM idle, ~300 MB disk). Steep learning curve. Overkill for just opening a file.

### Typora
- **Design:** Pioneer of seamless inline WYSIWYG — type `# ` and the heading renders immediately, no preview pane, no toggle. Beautiful default themes, fully CSS-customizable. Polarizing (some find it disorienting).
- **Stack:** Electron. Supports tables, LaTeX math, sequence/flow diagrams, TOC, outline panel.
- **Pricing:** $14.99 one-time (after a long free beta).
- **Popularity:** Strong, especially among writers who dislike the edit/preview split.
- **Trade-offs:** Electron weight (~300+ MB RAM). Limited extensibility. No Mermaid by default.

### Mark Text
- Open-source Electron Typora-alike. Free, less polish, active.

### PKM / academic (all Electron)
- **Logseq** — outliner-first knowledge base.
- **Zettlr** — academia-flavored (Zotero integration, citations).
- **Joplin** — open-source Evernote replacement, notebooks + tags, `.md` notes.

### VS Code
- **Stack:** Electron IDE. Not a markdown editor by design, but with extensions (Markdown All in One, Markdown Preview Enhanced) it's many developers' default — especially when markdown lives alongside code.
- **Pricing:** Free.
- **Trade-offs:** Heavy, requires setup/extension hunting, no native Mac feel.

---

## Writer's-app hybrids

Bend markdown into something richer (block-based).

- **Craft** — Native on Apple, web elsewhere. Block-based (closer to Notion than plain markdown) but speaks markdown reasonably. Probably the prettiest "rich" editor on the Mac. Supports images/video, 50 GB cloud, collaboration.
- **Notion / Coda** — Electron block editors. Import/export markdown but aren't markdown-native.

---

## Quick mental model for picking

| Goal | Pick |
|------|------|
| Prettiest pure-writing experience, don't mind opinionation | **iA Writer** or **Bear** |
| Prettiest *editor*, no app/database wrapper | **MarkEdit** (free) or **Typora** (paid, WYSIWYG) |
| Knowledge graph, plugins, OK with Electron | **Obsidian** |
| Long-form writer's environment with serious export | **Ulysses** |
| Free + native + lightweight, just open/read `.md` | **MarkEdit** / **MacDown** |

**Native vs Electron note:** The gap is real and noticeable on Apple Silicon. Obsidian at idle uses roughly 30× the memory of MarkEdit, and you feel it in window-open latency and scroll smoothness. A common pairing for native-leaning developers is **MarkEdit** (editing) + **Obsidian** (graph/PKM).
