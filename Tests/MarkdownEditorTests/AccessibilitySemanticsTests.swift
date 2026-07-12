import AppKit
import XCTest
import MarkdownRender
@testable import MarkdownEditor

@MainActor
final class AccessibilitySemanticsTests: XCTestCase {
    private let source = """
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
        XCTAssertTrue(value.contains("Read Vireo."))

        let layout = try XCTUnwrap(harness.textView.layoutManager
            as? MarkdownLayoutManager)
        let checkbox = try XCTUnwrap(layout.checkboxRects.values.first)
        XCTAssertGreaterThanOrEqual(checkbox.width, 40)
        XCTAssertGreaterThanOrEqual(checkbox.height, 40)
        let disclosure = try XCTUnwrap(layout.chevronRects.values.first)
        XCTAssertGreaterThanOrEqual(disclosure.width, 40)
        XCTAssertGreaterThanOrEqual(disclosure.height, 40)
        for cell in layout.tableCellGeometries.values {
            XCTAssertGreaterThanOrEqual(cell.rect.height, 40)
        }
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
