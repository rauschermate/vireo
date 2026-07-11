import XCTest
@testable import MarkdownEditor

final class LinkDestinationTests: XCTestCase {
    func testNormalizesCommonDestinations() throws {
        XCTAssertEqual(try LinkDestination.normalize(" example.com "), "https://example.com")
        XCTAssertEqual(try LinkDestination.normalize("www.example.com/docs"),
                       "https://www.example.com/docs")
        XCTAssertEqual(try LinkDestination.normalize("hello@example.com"),
                       "mailto:hello@example.com")
        XCTAssertEqual(try LinkDestination.normalize("docs/read me.md"), "docs/read%20me.md")
    }

    func testPreservesURLsAnchorsPathsAndCustomSchemes() throws {
        XCTAssertEqual(try LinkDestination.normalize("https://example.com/a"),
                       "https://example.com/a")
        XCTAssertEqual(try LinkDestination.normalize("#section"), "#section")
        XCTAssertEqual(try LinkDestination.normalize("README.md"), "README.md")
        XCTAssertEqual(try LinkDestination.normalize("obsidian:open-note"), "obsidian:open-note")
    }

    func testRejectsEmptyAndIncompleteDestinations() {
        XCTAssertThrowsError(try LinkDestination.normalize(" ")) {
            XCTAssertEqual($0 as? LinkDestinationError, .empty)
        }
        XCTAssertThrowsError(try LinkDestination.normalize("https://")) {
            XCTAssertEqual($0 as? LinkDestinationError, .invalidURL)
        }
        XCTAssertThrowsError(try LinkDestination.normalize("https//example.com")) {
            XCTAssertEqual($0 as? LinkDestinationError, .invalidURL)
        }
    }
}

@MainActor
final class LinkEditingTests: XCTestCase {
    private func makeEditor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        return (controller, textView)
    }

    func testCreatesNormalizedLinkAndKeepsLabelSelected() {
        let (controller, textView) = makeEditor("Apple")

        XCTAssertTrue(controller.replaceLink(in: NSRange(location: 0, length: 5),
                                             label: "Apple", destination: "example.com"))
        XCTAssertEqual(textView.string, "[Apple](https://example.com)")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 5))
    }

    func testEditingDestinationPreservesFormattedLabelSource() {
        let (controller, textView) = makeEditor("[**Bold**](old.example)")
        let link = controller.parsed.links[0]
        let labelSource = (textView.string as NSString).substring(with: link.labelRange)

        XCTAssertTrue(controller.replaceLink(in: link.range, label: "Bold",
                                             destination: "https://new.example/path",
                                             preservedLabelSource: labelSource,
                                             preservedLabel: "Bold"))
        XCTAssertEqual(textView.string, "[**Bold**](https://new.example/path)")
    }

    func testChangingLabelEscapesMarkdownDelimiters() {
        let (controller, textView) = makeEditor("[Old](https://example.com)")
        let link = controller.parsed.links[0]

        XCTAssertTrue(controller.replaceLink(in: link.range, label: "New] label",
                                             destination: "docs/a (copy).md"))
        XCTAssertEqual(textView.string, #"[New\] label](docs/a%20\(copy\).md)"#)
    }

    func testRemoveLinkKeepsItsFormattedLabel() {
        let (controller, textView) = makeEditor("A [**bold**](https://example.com) label")
        let link = controller.parsed.links[0]
        let labelSource = (textView.string as NSString).substring(with: link.labelRange)

        controller.removeLink(in: link.range, keeping: labelSource)

        XCTAssertEqual(textView.string, "A **bold** label")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 8))
    }

    func testInvalidDestinationDoesNotChangeSource() {
        let (controller, textView) = makeEditor("Apple")

        XCTAssertFalse(controller.replaceLink(in: NSRange(location: 0, length: 5),
                                              label: "Apple", destination: "https://"))
        XCTAssertEqual(textView.string, "Apple")
    }
}
