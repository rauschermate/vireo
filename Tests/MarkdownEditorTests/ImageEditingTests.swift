import XCTest
@testable import MarkdownEditor

@MainActor
final class ImageEditingTests: XCTestCase {
    private func makeEditor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        return (controller, textView)
    }

    func testRenderedImageCanBeEditedWithoutRevealingSource() {
        let (controller, textView) = makeEditor("![Old](old.png)")
        controller.replaceImage(atAnchor: 0, alt: "New] label", source: "new (2).png")

        XCTAssertEqual(textView.string, #"![New\] label](new \(2\).png)"#)
    }

    func testRenderedImageCanBeRemoved() {
        let (controller, textView) = makeEditor("before\n\n![Diagram](diagram.png)\n\nafter")
        let anchor = controller.parsed.images[0].anchor
        controller.removeImage(atAnchor: anchor)

        XCTAssertEqual(textView.string, "before\n\n\n\nafter")
    }
}
