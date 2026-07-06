# Hacker News — Show HN

> **Rules that matter:** neutral factual title (no caps, no "!", no superlatives,
> no numbers-as-hype), the URL field points to your own site (not PH), text field
> left blank, and you post the maker comment *immediately* as the first reply.
> **Never** ask anyone to upvote — that's a bannable pattern and HN detects vote rings.
> Post Tue–Thu ~9–10am ET (or the low-competition Sun ~midnight–1am PT slot).

---

## Title (put in the title field; URL field = your landing page)

```
Show HN: Vireo – a native macOS markdown editor that hides the syntax while editing
```

Alternatives if the above feels long:
- `Show HN: Vireo – a Mac markdown editor that hides the syntax, even while editing`
- `Show HN: Vireo – markdown editor for macOS that renders syntax invisibly as you type`

*(Keep it descriptive and flat. No "fastest," no "4MB!", no em-dash drama. HN
punishes marketing tone in titles.)*

---

## First comment (post this yourself, immediately, as the top comment)

Hi HN — I'm Mate, the author.

Vireo is a small native macOS app for reading and editing markdown. The one thing
it does differently: it hides the markdown syntax **while you edit**, not just in
a separate preview. You type `**bold**` and you only ever see **bold** — no
asterisks, no preview pane, no "it renders once your cursor leaves the line." The
markers are still in the file; they're just drawn as zero-width glyphs on screen.
Save and it's byte-for-byte the same GitHub-Flavored Markdown on disk.

Why I built it: I use Claude/Cursor all day and they generate an enormous amount
of markdown — READMEs, plans, notes. I wanted to *read* that like a document
without either (a) staring at raw `##`/`**` or (b) loading a 300MB Electron app
with a vault and a plugin marketplace to look at a text file. So I wrote a native
one. It's Swift on TextKit 1, about 4MB, and it opens instantly.

The interesting technical bit is the syntax hiding. It can't be done with TextKit 2
or `NSTextAttachment`s (those insert U+FFFC characters and would break source
parity). Vireo uses a custom `NSLayoutManager` that emits **null glyphs** for the
delimiter ranges — present in the text storage, zero-width on screen — and the same
layout manager draws bullets/checkboxes/images. The source string stays the single
source of truth; parsing and styling are derived and re-parsed incrementally per edit.

**Honest limitations:** it's macOS 15+ and Apple Silicon only (no Windows/Linux,
and I have no near-term plans for them). It's deliberately minimal — no plugins,
no sync, no graph view, no AI features. If you want a "second brain," this isn't
it; it's a fast reader/editor for the `.md` files you already have. It's free and
a notarized direct download (not on the App Store).

Happy to answer anything about the rendering pipeline, the incremental parser, or
the design choices. Feedback and "here's where it broke for me" both very welcome.
