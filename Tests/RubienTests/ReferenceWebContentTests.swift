#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class ReferenceWebContentTests: XCTestCase {
    func testEncodeAndDecodeHTMLWebContent() {
        let stored = Reference.encodeWebContent("<article><p>Hello</p></article>", format: .html)
        let decoded = Reference.decodeWebContent(stored)

        XCTAssertNotNil(stored)
        XCTAssertEqual(decoded?.format, .html)
        XCTAssertEqual(decoded?.body, "<article><p>Hello</p></article>")
    }

    func testPlainMarkdownDefaultsToMarkdownFormat() {
        let stored = Reference.encodeWebContent("# Title\n\nBody text", format: .markdown)
        let decoded = Reference.decodeWebContent(stored)

        XCTAssertTrue(stored?.hasPrefix("<!-- rubien:web-content:markdown -->") == true)
        XCTAssertEqual(decoded?.format, .markdown)
        XCTAssertEqual(decoded?.body, "# Title\n\nBody text")
    }

    func testRawHTMLBlockInsideMarkdownRemainsMarkdown() {
        let body = "<details><summary>Methods</summary>Body</details>"
        let stored = Reference.encodeWebContent(body, format: .markdown)
        let decoded = Reference.decodeWebContent(stored)

        XCTAssertEqual(decoded?.format, .markdown)
        XCTAssertEqual(decoded?.body, body)
    }

    func testLegacyMarkdownReferenceOverridesHTMLHeuristic() {
        let body = "<details><summary>Methods</summary>Legacy body</details>"
        let reference = Reference(
            title: "Legacy note",
            webContent: body,
            referenceType: .markdown
        )

        XCTAssertEqual(reference.decodedWebContent?.format, .markdown)
        XCTAssertEqual(reference.decodedWebContent?.body, body)
    }
}
#endif
