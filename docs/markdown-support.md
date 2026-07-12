# Markdown display support

Vireo reads and writes the original Markdown source unchanged. This contract defines what users see on the canvas when that source contains GFM, document metadata, or embedded HTML.

Every recognized construct has one intentional treatment:

1. **Rendered** as native document content.
2. **Collapsed metadata** represented by one quiet, labeled row.
3. **Literal content** shown exactly because it is not recognized syntax.
4. **Explicitly unsupported** represented by a compact HTML placeholder instead of a misleading partial render.

## Support matrix

| Source construct | Canvas treatment |
| --- | --- |
| CommonMark paragraphs, headings, emphasis, links, lists, quotes, rules, inline code, and fenced code | Rendered; syntax delimiters stay hidden. |
| GFM tables, task lists, and strikethrough | Rendered with native editing and interaction. |
| Images | Rendered from local or remote sources; failures use an alt-text placeholder. |
| Reference-style links | Link text is rendered; definition lines are collapsed into a “link references” metadata row. |
| YAML-style front matter at the start of a document | Collapsed into a “Front matter” metadata row with its field count. |
| HTML comments | Collapsed into an “HTML comment” metadata row. |
| Semantic inline HTML: `b`, `strong`, `i`, `em`, `del`, `s`, `strike`, `code`, `kbd`, `u`, `mark` | Tags stay hidden and their contents receive the equivalent native text style. Tag attributes are ignored. |
| HTML `<br>` | Raw syntax stays hidden and a compact line-break indicator is shown. |
| Other inline HTML | Opening tag becomes a compact HTML indicator with a tooltip; text content remains readable and the closing tag stays hidden. |
| HTML blocks, scripts, styles, forms, media, and browser-only elements | Replaced with a labeled “not rendered” block. Vireo never executes embedded HTML or JavaScript. |
| Unknown Markdown extensions | Shown as literal user content. Vireo does not guess at unsupported syntax. |

## Editing and fidelity

- The text storage always contains the exact source characters. Visual replacements do not rewrite or normalize the file.
- Saving without edits is byte-for-byte lossless.
- Metadata and unsupported-HTML rows are source-backed, so copying or opening the file in a source editor still exposes the original content.
- An unfinished construct remains literal until it becomes valid Markdown. This prevents Vireo from silently hiding text the user may have intended to type.

This contract applies to the app and Quick Look because both use the same parser and renderer.
