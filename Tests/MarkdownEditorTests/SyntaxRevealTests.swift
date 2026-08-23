import XCTest
import AppKit
import MarkdownEngine
@testable import MarkdownRender
@testable import MarkdownEditor

/// The default editing behavior: the block that holds the caret shows its
/// raw dimmed syntax; every other block renders clean.
@MainActor
final class SyntaxRevealTests: XCTestCase {
    private func makeEditor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        return (controller, textView)
    }

    private func isMarker(_ textView: MarkdownTextView, at location: Int) -> Bool {
        textView.textStorage?.attribute(.vireoMarker, at: location,
                                        effectiveRange: nil) != nil
    }

    private func visibleText(_ controller: EditorController,
                             _ textView: MarkdownTextView) -> String {
        controller.markerIndex.visibleString(in: textView.string as NSString)
    }

    private func moveCaret(_ textView: MarkdownTextView,
                           _ controller: EditorController, to location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        controller.selectionChanged()
    }

    // "# Title\n\nBody **bold** here\n"
    //  heading marker 0..<2, bold markers 14..<16 and 20..<22
    private let source = "# Title\n\nBody **bold** here\n"

    func testRestingRenderKeepsEveryMarkerHidden() {
        let (controller, textView) = makeEditor(source)
        XCTAssertTrue(isMarker(textView, at: 0))
        XCTAssertTrue(isMarker(textView, at: 14))
        XCTAssertFalse(visibleText(controller, textView).contains("#"))
        XCTAssertFalse(visibleText(controller, textView).contains("*"))
        withExtendedLifetime(controller) {}
    }

    func testCaretBlockRevealsItsMarkersAndOtherBlocksStayClean() {
        let (controller, textView) = makeEditor(source)
        moveCaret(textView, controller, to: 3) // inside "# Title"

        // Heading markers reveal; the body's bold markers stay hidden.
        XCTAssertFalse(isMarker(textView, at: 0))
        XCTAssertTrue(isMarker(textView, at: 14))
        XCTAssertTrue(visibleText(controller, textView).contains("# Title"))
        XCTAssertFalse(visibleText(controller, textView).contains("*"))
        withExtendedLifetime(controller) {}
    }

    func testCaretMoveHidesTheOldBlockAndRevealsTheNewOne() {
        let (controller, textView) = makeEditor(source)
        moveCaret(textView, controller, to: 3)
        moveCaret(textView, controller, to: 10) // inside "Body"

        XCTAssertTrue(isMarker(textView, at: 0), "heading re-hides after the caret leaves")
        XCTAssertFalse(isMarker(textView, at: 14), "bold markers reveal in the caret's block")
        XCTAssertFalse(isMarker(textView, at: 20))
        withExtendedLifetime(controller) {}
    }

    func testCaretOnABlankLineHidesEverything() {
        let (controller, textView) = makeEditor(source)
        moveCaret(textView, controller, to: 3)
        XCTAssertFalse(isMarker(textView, at: 0))

        moveCaret(textView, controller, to: 8) // the blank separator line
        XCTAssertTrue(isMarker(textView, at: 0))
        XCTAssertTrue(isMarker(textView, at: 14))
        XCTAssertFalse(visibleText(controller, textView).contains("#"))
        withExtendedLifetime(controller) {}
    }

    func testRevealedMarkersUseTheDimSecondaryColor() {
        let (controller, textView) = makeEditor(source)
        moveCaret(textView, controller, to: 3)

        let color = textView.textStorage?.attribute(.foregroundColor, at: 0,
                                                    effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, controller.theme.secondaryColor)
        withExtendedLifetime(controller) {}
    }

    func testCaretMathTreatsRevealedMarkersAsPlainText() {
        let (controller, textView) = makeEditor(source)
        moveCaret(textView, controller, to: 10)

        // Inside the revealed block, arrows step through the `**` one
        // character at a time instead of jumping the hidden construct.
        moveCaret(textView, controller, to: 13) // before ' ' + '**'
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange().location, 14)
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange().location, 15)
        withExtendedLifetime(controller) {}
    }

    func testTypedSyntaxStaysVisibleUntilTheCaretLeavesTheBlock() {
        let (controller, textView) = makeEditor("Alpha\n\nBeta\n")
        moveCaret(textView, controller, to: 5)

        textView.insertText(" **b**", replacementRange: NSRange(location: 5, length: 0))
        controller.scheduleRestyle()
        // "Alpha **b**\n\nBeta\n" — markers at 6..<8 and 9..<11, caret at 11.
        XCTAssertFalse(isMarker(textView, at: 6), "syntax typed in the caret's block stays visible")

        moveCaret(textView, controller, to: 14) // inside "Beta"
        XCTAssertTrue(isMarker(textView, at: 6), "the block re-hides once the caret leaves")
        withExtendedLifetime(controller) {}
    }

    private func contentX(_ textView: MarkdownTextView, at charIndex: Int) -> CGFloat {
        guard let lm = textView.layoutManager else { return -1 }
        let glyph = lm.glyphIndexForCharacter(at: charIndex)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minX + lm.location(forGlyphAt: glyph).x
    }

    func testListContentKeepsItsColumnWhenTheLineReveals() {
        let (controller, textView) = makeEditor("- alpha\n    - beta\n\ntail\n")
        textView.setFrameSize(NSSize(width: 600, height: 400))
        let ns = textView.string as NSString
        let alpha = ns.range(of: "alpha").location
        let beta = ns.range(of: "beta").location
        let alphaResting = contentX(textView, at: alpha)
        let betaResting = contentX(textView, at: beta)

        // The revealed raw prefix hangs in the gutter; the item's content
        // must not move. This is what keeps Enter/Tab from feeling jumpy.
        moveCaret(textView, controller, to: alpha)
        XCTAssertFalse(isMarker(textView, at: 0))
        XCTAssertEqual(contentX(textView, at: alpha), alphaResting, accuracy: 1.0)

        moveCaret(textView, controller, to: beta)
        XCTAssertEqual(contentX(textView, at: beta), betaResting, accuracy: 1.0)
        XCTAssertEqual(contentX(textView, at: alpha), alphaResting, accuracy: 1.0,
                       "the line re-hides at the same column")
        withExtendedLifetime(controller) {}
    }

    func testFoldGeometryStaysPutWhenAListLineReveals() {
        let (controller, textView) = makeEditor("- alpha\n  - beta\n\ntail\n")
        textView.setFrameSize(NSSize(width: 600, height: 400))
        let lm = textView.layoutManager as! MarkdownLayoutManager
        let anchor = (textView.string as NSString).range(of: "alpha").location
        guard let before = lm.markerGeometry(anchor: anchor, markerText: "•")?.textX else {
            return XCTFail("no marker geometry before the reveal")
        }

        moveCaret(textView, controller, to: anchor)
        XCTAssertFalse(isMarker(textView, at: 0), "the `- ` marker is revealed")
        XCTAssertTrue(lm.isSyntaxRevealed(at: anchor))

        // The revealed `- ` pushes the anchor glyph right; chevrons, halos
        // and guides must keep the resting position instead of riding along.
        guard let after = lm.markerGeometry(anchor: anchor, markerText: "•")?.textX else {
            return XCTFail("no marker geometry after the reveal")
        }
        XCTAssertEqual(before, after, accuracy: 0.5)
        withExtendedLifetime(controller) {}
    }
}
