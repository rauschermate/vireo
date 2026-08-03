import AppKit
import XCTest
import MarkdownRender
@testable import MarkdownEditor

@MainActor
final class AccessibilitySemanticsTests: XCTestCase {
    private let source = """
    ---
    title: Internal only
    ---

    # Overview

    - [ ] Parent task
        - child

    Read [Vireo](https://example.com/vireo).

    ![Architecture diagram](missing.png)

    | Name | Role |
    | --- | --- |
    | Ada | Engineer |
    """

    func testCustomDrawingExposesSemanticRolesValuesAndActions() throws {
        let harness = makeHarness()
        let children = customChildren(of: harness.textView)

        let checkbox = try element(with: .checkBox, in: children)
        XCTAssertEqual((checkbox.accessibilityValue() as? NSNumber)?.boolValue,
                       false)
        XCTAssertTrue(checkbox.accessibilityPerformPress())
        XCTAssertTrue(harness.textView.string.contains("- [x] Parent task"))

        let disclosure = try element(with: .disclosureTriangle, in: children)
        XCTAssertEqual((disclosure.accessibilityValue() as? NSNumber)?.boolValue,
                       true)
        XCTAssertTrue(disclosure.accessibilityPerformPress())
        draw(harness.textView)
        let refreshedDisclosure = customChildren(of: harness.textView)
            .first(where: { $0.accessibilityIdentifier()
                == disclosure.accessibilityIdentifier() })
        XCTAssertEqual((refreshedDisclosure?.accessibilityValue() as? NSNumber)?
            .boolValue, false)

        var opened: String?
        harness.controller.onOpenLink = { opened = $0 }
        let link = try element(with: .link, in: children)
        XCTAssertEqual(link.accessibilityValue() as? String,
                       "https://example.com/vireo")
        XCTAssertTrue(link.accessibilityPerformPress())
        XCTAssertEqual(opened, "https://example.com/vireo")

        let image = try element(with: .image, in: children)
        XCTAssertEqual(image.accessibilityLabel(), "Architecture diagram")
        XCTAssertTrue(image.accessibilityHelp()?.contains("missing.png") == true)

        let sourceBlock = try element(with: .staticText, in: children)
        XCTAssertEqual(sourceBlock.accessibilityValue() as? String,
                       "Front matter · 1 field")

        let table = try element(with: .table, in: children)
        let rows = table.accessibilityChildren() as? [MarkdownAccessibilityElement]
        XCTAssertEqual(rows?.count, 2)
        let cells = rows?.flatMap {
            $0.accessibilityChildren() as? [MarkdownAccessibilityElement] ?? []
        } ?? []
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(Set(cells.compactMap { $0.accessibilityValue() as? String }),
                       Set(["Name", "Role", "Ada", "Engineer"]))
    }

    func testAccessibilityTextHidesTablePlumbingAndHitTargetsAreLarge() throws {
        let harness = makeHarness()
        let value = try XCTUnwrap(harness.textView.accessibilityValue())

        XCTAssertFalse(value.contains("| --- |"))
        XCTAssertFalse(value.contains("https://example.com/vireo"),
                       "the hidden link destination must stay out of the text value")
        XCTAssertFalse(value.contains("missing.png"),
                       "image source must be announced by its semantic element only")
        XCTAssertFalse(value.contains("Internal only"),
                       "source-only metadata must not leak through the text value")
        XCTAssertTrue(value.contains("Read Vireo."))

        let layout = try XCTUnwrap(harness.textView.layoutManager
            as? MarkdownLayoutManager)
        let checkbox = try XCTUnwrap(layout.checkboxRects.values.first)
        XCTAssertGreaterThanOrEqual(checkbox.width, 40)
        XCTAssertGreaterThanOrEqual(checkbox.height, 40)
        let disclosure = try XCTUnwrap(layout.chevronRects.values.first)
        XCTAssertGreaterThanOrEqual(disclosure.width, 40)
        XCTAssertGreaterThanOrEqual(disclosure.height, 40)
        let parentTask = try XCTUnwrap(harness.controller.parsed.tasks.first {
            $0.subtreeRange != nil
        })
        let taskCheckbox = try XCTUnwrap(layout.checkboxRects[parentTask.anchor])
        let taskDisclosure = try XCTUnwrap(layout.chevronRects[parentTask.anchor])
        XCTAssertTrue(NSIntersectionRect(taskCheckbox, taskDisclosure).isEmpty,
                      "adjacent 40-point actions must not compete for the same click")
        for cell in layout.tableCellGeometries.values {
            XCTAssertGreaterThanOrEqual(cell.rect.height, 40)
        }
    }

    func testCollapsedContentLeavesAccessibilityTextUntilExpanded() throws {
        let harness = makeHarness()
        let parentTask = try XCTUnwrap(harness.controller.parsed.tasks.first {
            $0.subtreeRange != nil
        })
        let disclosure = try XCTUnwrap(customChildren(of: harness.textView)
            .first { $0.accessibilityIdentifier() == "markdown-fold-\(parentTask.anchor)" })

        XCTAssertTrue(harness.textView.accessibilityValue()?.contains("child") == true)
        XCTAssertTrue(disclosure.accessibilityPerformPress())
        draw(harness.textView)
        XCTAssertFalse(harness.textView.accessibilityValue()?.contains("child") == true)
    }

    func testContainerGeometryConvertsToScreenCoordinates() throws {
        let harness = makeHarness()
        let layout = try XCTUnwrap(harness.textView.layoutManager
            as? MarkdownLayoutManager)
        let imageRun = try XCTUnwrap(harness.controller.parsed.images.first)
        let containerRect = try XCTUnwrap(layout.imageRects[imageRun.anchor])
        let imageElement = try XCTUnwrap(customChildren(of: harness.textView)
            .first { $0.accessibilityIdentifier() == "markdown-image-\(imageRun.anchor)" })
        let viewRect = containerRect.offsetBy(dx: harness.textView.textContainerOrigin.x,
                                              dy: harness.textView.textContainerOrigin.y)
        let expected = harness.window.convertToScreen(
            harness.textView.convert(viewRect, to: nil)
        )
        let actual = imageElement.accessibilityFrame()

        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.5)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.5)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }

    private func makeHarness() -> (controller: EditorController,
                                   textView: MarkdownTextView,
                                   window: NSWindow) {
        let controller = EditorController()
        controller.automaticallyFocusTableEditors = false
        let stack = MarkdownSourceView.makeTextStack(source: source,
                                                     controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: 760, height: 900),
                              styleMask: [.titled], backing: .buffered,
                              defer: false)
        stack.scroll.frame = window.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: 760, height: 900)
        window.contentView = stack.scroll
        stack.textView.frame = NSRect(x: 0, y: 0, width: 760, height: 1_600)
        stack.textView.textContainerInset = NSSize(width: 37, height: 29)
        controller.restyle()
        draw(stack.textView)
        return (controller, stack.textView, window)
    }

    private func draw(_ textView: MarkdownTextView) {
        let layout = textView.layoutManager as! MarkdownLayoutManager
        let container = textView.textContainer!
        layout.ensureLayout(for: container)
        let canvas = NSImage(size: NSSize(width: 760, height: 1_600))
        canvas.lockFocus()
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs,
                          at: textView.textContainerOrigin)
        canvas.unlockFocus()
    }

    private func customChildren(of textView: MarkdownTextView)
        -> [MarkdownAccessibilityElement] {
        (textView.accessibilityChildren() ?? [])
            .compactMap { $0 as? MarkdownAccessibilityElement }
    }

    private func element(with role: NSAccessibility.Role,
                         in children: [MarkdownAccessibilityElement]) throws
        -> MarkdownAccessibilityElement {
        try XCTUnwrap(children.first { $0.accessibilityRole() == role })
    }
}
