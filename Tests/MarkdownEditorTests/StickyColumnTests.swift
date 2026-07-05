import XCTest
import AppKit
@testable import MarkdownEditor

/// Vertical arrows no longer snap out of hidden list markers (that reset
/// AppKit's goal column and made the caret drift). Instead, typing snaps the
/// caret out of a marker so text still lands in the item's content.
@MainActor
final class StickyColumnTests: XCTestCase {
    func testTypingSnapsOutOfHiddenMarker() {
        let controller = EditorController()
        let (scroll, tv) = MarkdownSourceView.makeTextStack(source: "- item\n", controller: controller)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = scroll
        controller.restyle()
        win.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 1, length: 0))  // inside the "- " marker
        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.textStorage!.string, "- Xitem\n",
                       "typed char must land in content, after the marker")
    }
}
