# dev.to / Hashnode — engineering build story

> This is **content marketing, not a launch post** — a genuinely interesting
> engineering writeup that pulls the HN/dev crowd on a second, slower wave. Post on
> dev.to with tags `showdev, macos, swift, markdown` (max 4; `#showdev` is the
> sanctioned "I built this" tag, keep the tone non-salesy). Set `canonical_url` and
> cross-post to Hashnode same day. Cover image 1000×420 (use the before/after).
> Publish a few days *after* launch so it rides residual interest.

---

## Working title
**How I made a macOS text editor hide markdown syntax — while you're still editing**

Alt: *Null glyphs: rendering markdown with the syntax invisible in a native NSTextView*

---

## Outline

1. **The itch** (2 short paragraphs) — AI tools generate endless markdown; existing
   apps either show raw `##` or are 300MB Electron. I wanted native + syntax hidden
   *while editing*, not a preview. Link the app once, casually, at the end — not here.

2. **Why the obvious approaches don't work**
   - Preview panes / "render when cursor leaves the line" — not what I wanted.
   - TextKit 2 doesn't give glyph-level control to hide ranges.
   - `NSTextAttachment` for bullets/images inserts U+FFFC characters → breaks
     source parity (the file would no longer be byte-for-byte your markdown).

3. **The core idea: the source string is the single source of truth**
   - The `NSTextView` text storage holds the *raw* markdown, untouched.
   - Parsing → styling → marker ranges are all *derived*. Saving = write the string verbatim.
   - Never build a rich model that serializes back to markdown.

4. **Null glyphs (the trick)**
   - A custom `NSLayoutManager` (TextKit 1) emits **null glyphs** for delimiter
     ranges tagged as markers — present in the store, zero-width and invisible on screen.
   - The same layout manager *draws* bullets, checkboxes, and images itself
     (they can't be attachments, per #2).
   - Show a small code sketch of the layout-manager override.

5. **Computing the marker ranges**
   - swift-markdown (cmark-gfm) AST → subtract child node ranges from delimiter
     node ranges to get exactly the characters to hide.
   - Source-location → UTF-16 mapping gotchas: cmark columns are UTF-8 bytes,
     ranges are half-open, multibyte handling.

6. **Keeping it fast: incremental parsing**
   - Diff each edit, re-parse only the enclosing block region, splice.
   - The invariant that keeps it correct: *incremental output must equal a full
     re-parse* — enforced with scenario + fuzz tests. ~16ms keystroke target on a 1.4MB doc.

7. **Wrap-up** — what I'd do differently, and one line: "it's a free app called
   Vireo if you want to see it in action: [link]."

---

## Intro (drop-in for the first two paragraphs)

Every AI tool I use writes markdown all day — Claude, Cursor, ChatGPT. Plans,
READMEs, notes. And every time I went to *read* that markdown, I had two bad
options: an editor that showed me the raw `##` and `**`, or a 300MB app that wrapped
a plain text file in a browser and a "vault" just to display it.

I wanted something specific and slightly unusual: a native editor that hides the
markdown syntax **while you're still editing** — not in a preview pane, not "once
your cursor leaves the line," but genuinely never on screen — while keeping the file
byte-for-byte plain `.md` on disk. Here's how that actually works, because the
answer turned out to be more interesting than I expected: null glyphs.
