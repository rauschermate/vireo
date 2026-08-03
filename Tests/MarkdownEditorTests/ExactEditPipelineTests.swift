import XCTest
import MarkdownEngine
@testable import MarkdownEditor

@MainActor
final class ExactEditPipelineTests: XCTestCase {
    private func makeLargeSource() -> String {
        (0..<900).map { "Paragraph \($0) with **bold** text and a [link](https://example.com/\($0)).\n\n" }
            .joined()
    }

    func testApprovedTextViewEditReachesExactIncrementalPath() {
        let source = makeLargeSource()
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        guard let storage = textView.textStorage else { return XCTFail("missing storage") }
        let location = (storage.string as NSString).range(of: "Paragraph 450").upperBound
        let range = NSRange(location: location, length: 0)

        XCTAssertTrue(textView.shouldChangeText(in: range, replacementString: " edited"))
        storage.replaceCharacters(in: range, with: " edited")
        controller.scheduleRestyle()

        XCTAssertEqual(controller.lastIncrementalStrategy, .exactEdit)
        XCTAssertTrue(storage.string.contains("Paragraph 450 edited"))
    }

    func testMultipleReplacementsBeforeNotificationUseSafeDiff() {
        let source = makeLargeSource()
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        guard let storage = textView.textStorage else { return XCTFail("missing storage") }
        let original = storage.string as NSString
        let first = original.range(of: "Paragraph 450")

        XCTAssertTrue(textView.shouldChangeText(in: first, replacementString: "Section 450"))
        storage.replaceCharacters(in: first, with: "Section 450")
        let second = (storage.string as NSString).range(of: "bold",
                                                        options: [],
                                                        range: NSRange(location: first.location,
                                                                       length: 100))
        XCTAssertTrue(textView.shouldChangeText(in: second, replacementString: "strong"))
        storage.replaceCharacters(in: second, with: "strong")
        controller.scheduleRestyle()

        XCTAssertEqual(controller.lastIncrementalStrategy, .sourceDiff)
        XCTAssertEqual(controller.parsed, MarkdownParser().parse(storage.string))
    }
}
