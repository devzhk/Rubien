import XCTest
@testable import RubienCore

final class MarkdownImporterTests: XCTestCase {

    // MARK: Title chain & body

    func testH1FirstLineBecomesTitleAndIsRemovedFromBody() {
        let ref = MarkdownImporter.parse("# My Note\n\nBody text.", filename: "file")
        XCTAssertEqual(ref.title, "My Note")
        let body = ref.decodedWebContent
        XCTAssertEqual(body?.format, .markdown)
        XCTAssertEqual(body?.body, "Body text.")
        XCTAssertEqual(ref.referenceType, .markdown)
    }

    func testFilenameFallbackWhenNoH1() {
        let ref = MarkdownImporter.parse("Just some text.", filename: "Meeting Notes")
        XCTAssertEqual(ref.title, "Meeting Notes")
        XCTAssertEqual(ref.decodedWebContent?.body, "Just some text.")
    }

    func testUntitledFallbackForStdin() {
        let ref = MarkdownImporter.parse("text", filename: nil)
        XCTAssertEqual(ref.title, "Untitled")
    }

    func testEmptyH1DoesNotBecomeTitle() {
        let ref = MarkdownImporter.parse("# \nBody", filename: "fallback")
        XCTAssertEqual(ref.title, "fallback")
        XCTAssertEqual(ref.decodedWebContent?.body, "# \nBody")
    }

    func testH2IsNotATitle() {
        let ref = MarkdownImporter.parse("## Section\nBody", filename: "f")
        XCTAssertEqual(ref.title, "f")
    }

    func testEmptyFileImportsMetadataOnly() {
        let ref = MarkdownImporter.parse("", filename: "empty")
        XCTAssertEqual(ref.title, "empty")
        XCTAssertNil(ref.webContent)
    }

    // MARK: Frontmatter detection / plausibility

    func testPlausibleFrontmatterIsStrippedEvenIfUnrecognized() {
        let md = "---\naliases:\n  - alt-name\n---\nBody here."
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, "Body here.")
        XCTAssertEqual(ref.title, "f", "unrecognized keys contribute no metadata")
    }

    func testThematicBreakDocumentIsNotFrontmatter() {
        let md = "---\nThis is prose between thematic breaks.\n---\nMore prose."
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, md, "nothing stripped")
    }

    /// Spec §1: list items must be indented under their key. An unindented
    /// `- item` is a markdown bullet list, not YAML — the candidate block is
    /// implausible and the document must be preserved verbatim.
    func testUnindentedDashLinesAreNotFrontmatter() {
        let md = "---\ntitle: looks-like-yaml\n- but this is a bullet\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, md, "implausible block preserved verbatim")
        XCTAssertEqual(ref.title, "f")
    }

    func testUnclosedFrontmatterTreatsWholeFileAsBody() {
        let md = "---\ntitle: Oops no closer\nBody."
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, md)
        XCTAssertEqual(ref.title, "f")
    }

    func testBOMAndCRLFTolerated() {
        let md = "\u{FEFF}---\r\ntitle: CRLF Note\r\n---\r\nBody\r\n"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.title, "CRLF Note")
        XCTAssertEqual(ref.decodedWebContent?.body, "Body")
    }

    func testFrontmatterOnlyFileHasNilContent() {
        let ref = MarkdownImporter.parse("---\ntitle: Only Meta\n---\n", filename: "f")
        XCTAssertEqual(ref.title, "Only Meta")
        XCTAssertNil(ref.webContent)
    }
}
