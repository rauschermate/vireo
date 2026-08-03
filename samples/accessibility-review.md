---
title: Accessibility review
owner: Vireo
---

# Accessibility and native interaction review

This fixture exercises the controls Vireo draws itself while keeping the Markdown source hidden.

## Semantic controls

- [ ] Parent task with a disclosure control
    - This child should disappear from both the page and VoiceOver after the parent collapses.
- [x] Completed task

- Parent list item with a disclosure control
    - Nested list content

Read [Vireo accessibility guidance](https://example.com/vireo-accessibility).

![Architecture diagram](missing-accessibility-review.png)

| Component | State | Owner |
| --- | --- | --- |
| Visible text | Ready | Maya |
| Custom controls | In review | Nico |

## Fold behavior

Collapse this heading. The paragraph and task below should disappear together, then return when expanded.

- [ ] Hidden while the heading is collapsed

## Formatting toolbar

Select this sentence to show the floating toolbar and verify that every button is comfortably clickable.

## App chrome

Open another tab, reveal the file sidebar and table of contents, then hover a tab long enough to show its tooltip.
