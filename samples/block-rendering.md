# Block rendering review

This fixture focuses on the block-level surfaces that should read as native document structure rather than decorated Markdown source.

## Fenced code

The code below should sit on one continuous rounded surface. The opening and closing fences should be completely hidden, with compact and even padding above and below.

```swift
struct ReadingState {
    let fileName: String
    let isEditing: Bool
}

let state = ReadingState(fileName: "notes.md", isEditing: true)
print(state.fileName)
```

Inline `code remains compact` and should not expand into a block surface.

~~~json
{
  "appearance": "dark",
  "syntax": "hidden"
}
~~~

## Block quote

> A continuous quote bar should establish the hierarchy of this quotation.
>
> It should remain aligned across multiple paragraphs without exposing the `>` markers, including when this deliberately longer line wraps within the reading column.

The paragraph after the quote should return cleanly to the normal reading margin.

## Thematic break

The next line should be a quiet full-width separator. No hyphens should remain visible.

---

Text after the rule should retain normal spacing and alignment.

The alternate forms should receive the same treatment:

___

* * *

End of fixture.
