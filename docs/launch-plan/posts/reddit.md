# Reddit — per-subreddit drafts

> **Golden rules:** one subreddit per day, **never** paste identical text across
> subs (fastest way to get flagged/banned), always lead with a real image/GIF, and
> read each sub's current sidebar rules the day before (Reddit rules change per
> mod). Reply to every comment. Follow r/macapps's required promo template/flair.
> Frame each post for that community's actual interest — result, workflow, or build
> story — not a copy-paste ad.

---

## r/macapps  *(highest-value sub — post first, day 1–2)*

**Title:** `[Free] Vireo — a native markdown editor that hides the syntax while you edit`

**Body:**
Hey r/macapps — I made a small native Mac app and it's free, wanted to share it here first.

Vireo shows your markdown as a clean document and hides the syntax **while you're
editing**, not just in a preview. You type `**bold**` and only ever see **bold** —
no asterisks, no preview pane. It's still a plain `.md` file on disk the whole time.

- Native Swift / Apple Silicon, ~4MB, opens instantly (no Electron)
- Set it as your default `.md` handler → every markdown file in Finder opens clean, in tabs
- Quick Look renders in its style without even launching the app
- Tabs, folder sidebar, table of contents, focus mode, ⌘F, auto-save
- No account, no vault, no plugins, no subscription

macOS 15+, Apple Silicon. Free, notarized direct download: [link]

[demo GIF — before/after]

It's deliberately minimal (no plugins/sync/AI by design). Would love feedback from
this crowd specifically — what would make it your default markdown app?

---

## r/SideProject  *(friendly "I built this" sub — day 2)*

**Title:** `I built a native Mac markdown editor that hides the syntax even while editing — it's free`

**Body:**
I use AI tools all day and they generate a mountain of markdown. I was tired of
either staring at raw `##`/`**` or opening a 300MB app with a "vault" just to read
a text file — so I spent [a few months] building the thing I actually wanted.

Vireo hides markdown syntax while you edit (not in a separate preview — it never
shows on screen), stays byte-for-byte plain `.md` on disk, and it's native Swift at
about 4MB so it opens instantly.

No monetization — it's genuinely free, I just wanted it to exist. Happy to talk
about the build (the syntax-hiding is done with a custom layout manager emitting
null glyphs, which was the fun part). [link] + [GIF]

What do you think?

---

## r/ClaudeAI  *or*  r/ChatGPTCoding  *(AI-coding angle — day 3, pick ONE)*

**Title (r/ClaudeAI):** `Claude generates a ton of markdown — I built a free Mac app to actually read it`

**Body:**
If you use Claude (or Cursor/Codex) a lot, you know it outputs markdown constantly
— plans, READMEs, summaries. I kept saving those as `.md` and then having nothing
good to *read* them in: either raw syntax or a heavyweight notes app.

So I built Vireo: a native Mac editor that hides the markdown syntax while you edit
and shows it as a clean document, while keeping the file as plain `.md` on disk. It's
free, ~4MB, opens instantly.

It pairs really well with an agent workflow — point it at your project's `.md`
files and they read like docs instead of code. macOS 15+, Apple Silicon. [link] +
[GIF]

Curious how others here are managing all the markdown their agents produce.

*(For r/ChatGPTCoding / r/cursor: same idea, swap the model name and lead with the
"my agent dumps markdown, here's how I read it" workflow framing.)*

---

## r/productivity  *(bigger, stricter — day 4, lead with workflow not download)*

**Title:** `I stopped reading raw markdown syntax in my notes — here's the setup that fixed it`

**Body:**
My notes and everything my AI tools generate are all markdown, and I realized I was
spending real attention decoding `##`, `**`, and `- [ ]` instead of reading. A few
things that helped, in case useful to anyone here:

1. Keep everything as plain `.md` (portable, future-proof, openable anywhere).
2. Use an editor that renders the syntax *invisibly* so you read words, not code.

For #2 I ended up building my own native Mac app (Vireo) because nothing did the
"hide syntax even while editing" thing without a 300MB footprint — but the principle
stands regardless of app: stop staring at plumbing. It's free if you want to try it
[link], but mostly I'm curious how others keep markdown readable without going full
"second brain."

*(Note: r/productivity removes thin ads — this post has to genuinely lead with the
workflow. If the sub's current rules require self-promo in a specific thread, use it.)*

---

## r/markdown / r/ObsidianMD  *(topical — only if genuinely relevant, spaced out)*

**Title (r/markdown):** `Made a native Mac editor that hides markdown syntax while editing (free)`

**Body:**
Built a small native macOS app that renders GFM as a clean document and hides the
delimiters *while editing* — the `#`/`*` are drawn as zero-width glyphs but stay in
the file, so it's byte-for-byte plain markdown on disk. Free, ~4MB. Thought this
sub might appreciate the "source stays canonical, display is derived" approach.
[link] + [GIF] — feedback on edge cases welcome.

*(r/ObsidianMD is stricter about non-Obsidian promo — only post there if you frame
it as "a lightweight reader for your vault's raw `.md` files," and check rules first.)*
