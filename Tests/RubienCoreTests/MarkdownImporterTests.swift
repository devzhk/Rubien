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

    // MARK: Full clipper fixture (mirrors a real Obsidian Web Clipper file)

    func testObsidianClipperFixtureMapsAllFields() {
        let md = """
        ---
        title: "Solving OPSD (basically)"
        source: "https://x.com/ar0cket1/article/2065772402622263701"
        author:
          - "[[ar0cket1 (@ar0cket1)]]"
        published: 2026-06-13
        created: 2026-07-09
        description: "self hinted teachers will likely be common practice."
        tags:
          - "clippings"
        ---
        ![Image](https://example.com/img.jpg)

        Body paragraph.
        """
        let ref = MarkdownImporter.parse(md, filename: "Solving OPSD (basically)")
        XCTAssertEqual(ref.title, "Solving OPSD (basically)")
        XCTAssertEqual(ref.url, "https://x.com/ar0cket1/article/2065772402622263701")
        XCTAssertEqual(ref.siteName, "x.com")
        XCTAssertEqual(ref.referenceType, .webpage)
        XCTAssertEqual(ref.year, 2026)
        XCTAssertEqual(ref.issuedMonth, 6)
        XCTAssertEqual(ref.issuedDay, 13)
        XCTAssertEqual(ref.accessedDate, "2026-07-09")
        XCTAssertEqual(ref.abstract, "self hinted teachers will likely be common practice.")
        XCTAssertEqual(ref.authors.count, 1)
        XCTAssertFalse(ref.authors[0].displayName.contains("[["), "wiki-link wrapper stripped")
        XCTAssertEqual(ref.decodedWebContent?.body, "![Image](https://example.com/img.jpg)\n\nBody paragraph.")
    }

    // MARK: Authors

    func testFlowListAuthorsRespectQuotedCommas() {
        let md = "---\nauthor: [\"Smith, John\", \"[[Jane Doe]]\"]\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.authors.count, 2)
        XCTAssertEqual(ref.authors[0].family, "Smith")
        XCTAssertEqual(ref.authors[0].given, "John")
        XCTAssertEqual(ref.authors[1].displayName, "Jane Doe")
    }

    func testFlowListNestedBracketsDoNotSplit() {
        let md = "---\nauthor: [\"Lab [Systems, Core]\", Solo Author]\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.authors.count, 2, "comma inside nested brackets must not split")
    }

    func testScalarAuthor() {
        let md = "---\nauthor: Jane Doe\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.authors.count, 1)
        XCTAssertEqual(ref.authors[0].displayName, "Jane Doe")
    }

    func testUnsupportedEscapesStayLiteral() {
        let md = "---\ndescription: \"line\\nbreak\"\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.abstract, "line\\nbreak", "\\n is not an unescape we support")
    }

    // MARK: Nested keys must not leak (spec §1 / codex finding 5)

    func testNestedTitleDoesNotLeak() {
        let md = "---\nmetadata:\n  title: Wrong\nsource: https://example.com/x\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "right")
        XCTAssertEqual(ref.title, "right")
        XCTAssertEqual(ref.url, "https://example.com/x")
    }

    func testBlockScalarDescriptionYieldsNoAbstract() {
        let md = "---\ndescription: >\n  folded first line\n  folded second line\ntitle: T\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.title, "T")
        XCTAssertNil(ref.abstract, "unsupported block scalar contributes nothing")
    }

    func testBlockScalarWithModifiersConsumed() {
        let md = "---\ndescription: |2-\n    kept out\ntitle: T\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.title, "T")
        XCTAssertNil(ref.abstract)
    }

    // MARK: Source / type

    func testNonHTTPSourceIsIgnored() {
        let md = "---\nsource: file:///Users/x/doc.pdf\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertNil(ref.url)
        XCTAssertNil(ref.siteName)
        XCTAssertEqual(ref.referenceType, .markdown)
    }

    // MARK: Dates (spec §1 / codex finding 13)

    func testDateVariants() {
        func parseWith(published: String) -> Reference {
            MarkdownImporter.parse("---\npublished: \(published)\n---\nB", filename: "f")
        }
        XCTAssertEqual(parseWith(published: "2026").year, 2026)
        XCTAssertNil(parseWith(published: "2026").issuedMonth)
        XCTAssertEqual(parseWith(published: "2026-06").issuedMonth, 6)
        XCTAssertNil(parseWith(published: "2026-06").issuedDay)
        XCTAssertEqual(parseWith(published: "2024-02-29").issuedDay, 29, "leap day valid")
        XCTAssertNil(parseWith(published: "2025-02-31").year, "calendar-invalid rejected")
        XCTAssertNil(parseWith(published: "2025-01-0199").year, "digit continuation rejected")
        XCTAssertNil(parseWith(published: "garbage").year)
        XCTAssertEqual(parseWith(published: "2026-07-09T10:00:00").issuedDay, 9, "datetime truncates at T")
    }

    func testCreatedDatetimeTruncatesToDate() {
        let md = "---\ncreated: 2026-07-09T10:00:00\n---\nB"
        XCTAssertEqual(MarkdownImporter.parse(md, filename: "f").accessedDate, "2026-07-09")
    }

    func testTagsAreIgnored() {
        let md = "---\ntags:\n  - clippings\n  - ml\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, "Body")
    }
}
