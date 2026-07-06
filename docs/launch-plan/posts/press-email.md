# Press / newsletter pitch emails

> Send ~1 week before launch (or right after, so you can cite HN/PH traction).
> 3 sentences, personal, no press-release voice. Attach the before/after image and
> a short GIF. One email at a time, addressed to a person. Best targets:
> **9to5Mac Indie App Spotlight** (michaelb@9to5mac.com) and **Indie Dev Monday**
> (newsletter@indiedevmonday.com).

---

## 9to5Mac — Indie App Spotlight (Michael Burkhardt)

**To:** michaelb@9to5mac.com
**Subject:** Indie App Spotlight: Vireo — a native Mac markdown editor that hides the syntax

Hi Michael,

I'm an indie dev and just launched **Vireo**, a native macOS markdown editor whose
one trick is that it hides the markdown syntax *while you edit* — no preview pane,
no raw `##` or `**`, but the file on disk stays byte-for-byte plain `.md`. It's
Swift on Apple Silicon, about 4MB, opens instantly, and it's completely free (no
account, no subscription).

I built it because every AI tool now writes markdown all day and I just wanted to
*read* it like a document without loading a 300MB Electron app. I saw the Indie App
Spotlight covers exactly this kind of thing — I'd be honored if it's a fit.

Download + before/after screenshots below. Happy to send anything else you need.

[link] · [before/after image] · [demo GIF]

Thanks for the series,
Mate Rauscher

---

## Indie Dev Monday

**To:** newsletter@indiedevmonday.com
**Subject:** Vireo — free native Mac markdown editor (indie launch)

Hi,

Just launched **Vireo**, a free, native macOS markdown editor that hides the syntax
even while you're editing — bold looks bold, no raw `##`, and it stays plain `.md`
on disk. Swift/Apple Silicon, ~4MB, opens instantly, no subscription.

Solo-built; I'd love to be considered for a future issue. Download and screenshots
below — thanks for covering indie work.

[link] · [before/after image]

Mate

---

## Generic short pitch (Six Colors / others — one personal email each, low expectations)

**Subject:** A tiny free Mac app you might personally like — Vireo

Hi [name] — long shot, but I built a free native Mac markdown editor that hides the
syntax even while editing (still plain `.md` underneath, ~4MB, opens instantly). No
pitch beyond "you might enjoy playing with it for ten seconds": open any `.md` file
in it and the syntax is just… gone. [link] · [GIF]. No worries if not a fit —
appreciate what you do. — Mate

---

## The Verge — Installer (David Pierce)

> Installer is a "what to download this week" newsletter and explicitly invites
> reader suggestions — so pitch it as *a tool recommendation*, not a press release.
> Reply directly to the newsletter email if you're a subscriber; else david@theverge.com.

**Subject:** An Installer suggestion: Vireo, a Mac app that hides markdown syntax

Hi David,

Installer suggestion: **Vireo**, a free native Mac app that shows your markdown as a
clean document and hides the syntax *while you're editing* — no preview pane, no raw
`##`, but the file stays plain `.md` on disk. It's ~4MB Swift (refreshing after a
year of Electron everything) and opens instantly.

The reason it feels timely: every AI tool now writes markdown all day, and this is
the first app that just lets you *read* it like a document. Ten-second demo: open
any `.md` in it and the syntax is simply gone. [link] · [GIF]

Love the newsletter — thanks for reading.
Mate

---

## iOS Dev Weekly (Dave Verwer)

> Link-submission newsletter for Apple devs. Don't pitch the *app* — pitch the
> *engineering writeup* (the null-glyph technique). That's what his readers click,
> and it reaches the exact devs who'd both use Vireo and amplify it. Use the
> "Suggest a link" form or dave@iosdevweekly.com.

**Subject:** Link suggestion: hiding markdown syntax in NSTextView with null glyphs

Hi Dave,

Link suggestion for iOS Dev Weekly: a writeup on how I made a native macOS editor
hide markdown syntax *while editing* — using a custom NSLayoutManager that emits
null glyphs for the delimiter ranges (present in the text storage, zero-width on
screen), keeping the file byte-for-byte plain `.md`. TextKit 1, swift-markdown AST,
incremental re-parsing. [writeup link]

It's from building a free app (Vireo, [link]) but the post is genuinely about the
technique, not a launch pitch. Thought your readers might enjoy the glyph-level
detail.

Thanks for the newsletter — long-time reader.
Mate

---

## MacStories (Federico Viticci) — long shot, personal

> High editorial bar, only personally-tested apps. Keep it short and human; send
> only once you have HN/PH traction to open with.

**Subject:** Vireo — a native Mac markdown editor that hides the syntax while editing

Hi Federico,

I just launched **Vireo**, a free native Mac markdown editor whose one idea is that
it hides the syntax *while you edit* (not in a preview) — bold looks bold, no raw
`##`, and it stays plain `.md` on disk. Swift, ~4MB, opens instantly. It [hit the
HN front page / reached #X on Product Hunt] this week.

I know your bar is "apps I actually use," so no pressure at all — but if you open a
`.md` file in it, I think the syntax-hiding will land in about three seconds. [link]
· [GIF]

Thanks for everything you do for indie Mac software.
Mate

---

## AI newsletters — Ben's Bites / TLDR AI (the reframe)

> Reframe entirely: this is an *AI-workflow* tool, not a Mac app. Their audience
> cares about the agent angle, not TextKit. Use each outlet's submission form.

**Subject:** The unglamorous side effect of the agent boom: everyone's drowning in markdown

Hi [name],

Quick tool tip for the newsletter: AI agents (Claude, Cursor, ChatGPT) now generate
an enormous amount of markdown — plans, READMEs, notes — and there's been no good
way to *read* it without either staring at raw `##`/`**` or loading a heavyweight
notes app.

I built **Vireo**, a free native Mac app that renders your agent's markdown as a
clean document and hides the syntax entirely (still plain `.md` on disk). It's a
small, on-the-nose fix for a very "2026" problem. [link] · [GIF]

Might be a fun one-liner for your readers. Thanks!
Mate

---

## Recomendo — mass-audience "cool tool" (via contact form)

> Recomendo recommends 6 small delightful things weekly to a huge general audience.
> Keep it warm, concrete, non-technical — write it the way *they* would.

**Subject:** A recommendation: Vireo, the markdown app that finally hides the code

A free Mac app called **Vireo** shows your markdown notes as clean, formatted text
and hides all the `#` and `*` symbols — even while you're typing. Your files stay
ordinary `.md` text files, so nothing's locked in. It's tiny (~4MB), native, opens
instantly, and there's no account or subscription. If you've ever been annoyed by
raw markdown symbols cluttering your notes, this quietly fixes it. [link]

---

## Under the Radar (podcast — via relay.fm feedback / host DMs)

> Not an email, but a ready blurb to paste into the feedback form or a DM. Angle:
> solo-dev build story + a genuinely novel technical trick = good episode material.

Hi Marco / David — indie-dev pitch for the show: I built **Vireo**, a free native
Mac markdown editor that hides the syntax while you edit. The build had a fun
constraint — you can't use TextKit 2 or NSTextAttachments without breaking source
parity, so it hides syntax via null glyphs in a custom TextKit 1 layout manager.
Happy to come on and talk through the native-vs-Electron tradeoffs and the rendering
pipeline, or it's just a possible "what we're using" mention. [link]
