# Editor quality gates

This matrix turns the boundary cases identified in the
[editor review](../docs/editor-review.md#p1--current-tests-do-not-protect-the-whole-experience)
into named, repeatable gates.
Coverage is distributed across the focused implementation PRs so a regression
fails next to the subsystem that owns it. Run all gates after the stack is
integrated.

| Product boundary | Automated gate |
| --- | --- |
| Full open/render and exact edit deltas | `MarkdownRendererPerformanceTests`, `ExactEditPipelineTests`, `ParsedMarkdownSliceTests`, and `VireoSnapshot --benchmark-suite` in PR #34 |
| Large-document layout, draw, and scroll | `VisibleDecorationScalingTests` and `FileTreeServiceTests` in PR #35 |
| Caret, selection, deletion, find, copy, transient syntax | `MarkerIndexTests` and `MarkerInteractionTests` in PR #31 |
| Native typing/formatting undo and redo | `EditorExperienceRegressionTests` in this PR |
| IME composition and text-input-service replacement | `EditorExperienceRegressionTests` in this PR |
| Link destination creation/edit/removal | `LinkDestinationTests` and `LinkEditingTests` in PR #28 |
| Inline images and editor affordances | `ImageRenderingTests` and `ImageEditingTests` in PR #27 |
| Off-main image loading, cache bounds, targeted refresh, scroll anchoring, Quick Look refresh | `ImageLoaderTests`, `AsyncImageUpdateTests`, and `TextViewportAnchorTests` in PR #36 |
| Rich table entry, navigation, mutation, and source preservation | `EditableMarkdownTableTests` and `RichTableEditingTests` in PR #32 |
| GFM HTML, metadata, and reference definitions | `SourceTreatmentTests` and `SourceTreatmentRenderTests` in PR #33 |
| Autosave failure, close safety, preference changes, and external races | `DocumentWriterTests` and `DocumentModelTests` in PR #29 |
| Tab selection, scroll, and undo-session persistence | `EditorSessionTests` and `DocumentEditorSessionTests` in PR #30 |
| Block surfaces and appearance parity | `BlockDecorationTests` plus light/dark snapshot smoke tests in PR #38 and CI |
| Visible accessibility output, semantics, actions, and hit targets | `AccessibilitySemanticsTests` in PR #39 |
| App and Quick Look bundle identity/version | `verify-bundle-metadata.sh` in PR #26 |

The required local checks are:

```sh
swift test
./scripts/build-app-xcode.sh Debug
swift run VireoSnapshot samples/welcome.md /tmp/vireo-light.png
swift run VireoSnapshot samples/welcome.md /tmp/vireo-dark.png --dark
```

Also run the release-mode performance budget suite:

```sh
swift run -c release VireoSnapshot --benchmark-suite
```
