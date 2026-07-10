import XCTest
import GRDB
@testable import RubienCore

final class MarkdownImportMergeTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(DatabaseQueue()) }

    func testURLMatchNeverOverwritesCuratedTitle() throws {
        let db = try makeDB()
        var curated = Reference(
            title: "Curated Title",
            url: "https://example.com/post",
            webContent: Reference.encodeWebContent("short", format: .markdown),
            referenceType: .webpage
        )
        _ = try db.saveReference(&curated)

        // Frontmatter-less re-import: title is the filename fallback.
        let incoming = MarkdownImporter.parse(
            "---\nsource: https://example.com/post\n---\nA much longer body than short.",
            filename: "some-filename"
        )
        let result = try db.batchImportReferences([incoming], mergePolicy: .markdownFillOnly)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.ids, [curated.id!], "merged, not duplicated")

        let merged = try db.fetchReferences(ids: [curated.id!]).first!
        XCTAssertEqual(merged.title, "Curated Title")
        XCTAssertEqual(merged.decodedWebContent?.body, "A much longer body than short.",
                       "longest content wins")
    }

    func testFillOnlyFieldsPopulateWhenEmpty() throws {
        let db = try makeDB()
        var bare = Reference(title: "Bare", url: "https://example.com/p2", referenceType: .webpage)
        _ = try db.saveReference(&bare)

        let md = """
        ---
        source: https://example.com/p2
        author: Jane Doe
        published: 2026-01-02
        description: An abstract.
        ---
        Body
        """
        _ = try db.batchImportReferences(
            [MarkdownImporter.parse(md, filename: "f")], mergePolicy: .markdownFillOnly
        )
        let merged = try db.fetchReferences(ids: [bare.id!]).first!
        XCTAssertEqual(merged.authors.first?.displayName, "Jane Doe")
        XCTAssertEqual(merged.year, 2026)
        XCTAssertEqual(merged.abstract, "An abstract.")
    }

    func testFillOnlyFieldsNeverOverwrite() throws {
        let db = try makeDB()
        var curated = Reference(
            title: "T", authors: [AuthorName(given: "Ada", family: "Lovelace")],
            year: 1815, url: "https://example.com/p3",
            abstract: "Curated abstract.", referenceType: .webpage
        )
        _ = try db.saveReference(&curated)

        let md = "---\nsource: https://example.com/p3\nauthor: Somebody Else\npublished: 2020-01-01\ndescription: New abstract.\n---\nB"
        _ = try db.batchImportReferences(
            [MarkdownImporter.parse(md, filename: "f")], mergePolicy: .markdownFillOnly
        )
        let merged = try db.fetchReferences(ids: [curated.id!]).first!
        XCTAssertEqual(merged.authors.first?.family, "Lovelace")
        XCTAssertEqual(merged.year, 1815)
        XCTAssertEqual(merged.abstract, "Curated abstract.")
    }

    func testURLLessNotesAlwaysInsert() throws {
        let db = try makeDB()
        let note = MarkdownImporter.parse("Body one", filename: "Meeting notes")
        _ = try db.batchImportReferences([note], mergePolicy: .markdownFillOnly)
        _ = try db.batchImportReferences([note], mergePolicy: .markdownFillOnly)
        let count = try db.dbWriter.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM reference WHERE title = 'Meeting notes'") ?? 0
        }
        XCTAssertEqual(count, 2, "no match key → duplicate is the documented v1 behavior")
    }

    /// Spec §10: prove FTS reaches imported markdown bodies. Single
    /// alphanumeric token (hyphens would tokenize into a phrase and couple
    /// the test to punctuation behavior).
    func testImportedBodyIsFTSSearchable() throws {
        let db = try makeDB()
        XCTAssertTrue(try db.searchReferences(query: "zanzibarquokka77").isEmpty,
                      "token must not pre-exist")
        let note = MarkdownImporter.parse(
            "The zanzibarquokka77 theorem holds.", filename: "unique-note"
        )
        let imported = try db.batchImportReferences([note], mergePolicy: .markdownFillOnly)
        let hits = try db.searchReferences(query: "zanzibarquokka77")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, imported.ids.first)
    }
}
