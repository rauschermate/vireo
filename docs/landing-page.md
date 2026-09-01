# Vireo — Landing Page Copy

> Draft 6 — simple hero. Replaces the long-form direct-response draft (draft 5, kept
> in git history if you want to revive it for a future `/story` or `/about` page).

## Why this draft replaces draft 5

The page now shows only a headline, a subheader, a download button, and a
screenshot beside it. It drops the founder's letter, the receipts section,
the "no" list, and the long close.

Draft 5 also claimed the syntax is invisible the entire time you type. That
claim is no longer true. Vireo now reveals the raw markdown, dimmed, in the
block that holds the caret. Every other block stays clean. The copy below
reflects this.

## Diagnosis (Schwartz method)

Market: people who already use Typora, Obsidian, or iA Writer and are tired
of the tradeoffs (weight, vaults, subscriptions). That makes this a
**product-aware** market at **stage 3 sophistication** — everyone claims
"hides the syntax," so the claim alone no longer earns belief.

Move: lead with the mechanism, not a bigger claim. Hidden everywhere,
revealed only where you're editing. Let the screenshot prove it in one
glance — the page has no room for a paragraph of explanation.

---

## HERO

### Headline

**Your agent writes markdown. Vireo lets you read it.**

### Subheader

A simple, fast markdown editor for macOS that hides the syntax — except right where you're editing.

### Download button

**Download for Mac — Free**

### Button meta line

Native · 4 MB · macOS 15+ · Apple Silicon

---

## SCREENSHOT

**Placement:** beside the hero text, not full-bleed below it.

**What it shows:** a real `.md` file. Most of the document renders clean —
a heading, bold text, a checkbox list. One paragraph, the one under the
caret, shows its raw markdown, dimmed. That dimmed paragraph is the whole
argument: it should make the subheader's tease pay off without reading
another word.

**Alt text:** A markdown document open in Vireo. Most of it renders clean;
the paragraph under the caret shows its raw markdown, dimmed.

**Optional caption** (only if the layout has room):
The syntax shows only where you're editing. Move on, and it hides again.

**How to regenerate:** `site/hero.png` renders from `site/hero-source.md`
through the real pipeline, not a mockup:

```bash
swift run VireoSnapshot site/hero-source.md site/hero.png --caret 89 --dark
```

`--caret <offset>` is a `VireoSnapshot`-only flag (`Sources/VireoSnapshot/main.swift`)
that reveals the block at that character offset, dimmed, the way the live
editor reveals the caret's block. `89` lands inside the second paragraph of
`hero-source.md`; recompute it if that file changes.

---

## SUPPORTING COPY (for `<head>` / social sharing, not shown on the page)

**Meta description:** Vireo is a fast, native macOS markdown editor. It
hides the syntax and shows it, dimmed, only where you're editing. Free,
4 MB, no vaults or plugins.

**Social one-liner:** Every other markdown app shows you the code. Vireo
shows you the words — except the one paragraph you're on.

---

## ALTERNATE HEADLINES

1. **Your agent writes markdown. Vireo lets you read it.** — chosen. Fresh
   agent-era hook; doesn't overclaim about the syntax being gone forever.
2. **Clean markdown. Except where you're editing.** — leads with the new
   mechanism directly; more literal, less identification-driven.
3. **Read it clean. Edit it raw. Never both at once.** — states the
   tradeoff Vireo resolves, in three short beats.
