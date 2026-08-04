#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class WebReaderMarkdownExportWorkerTests: XCTestCase {
    func testHTMLClipExportsTheSharedMarkdownProjectionAndCachesIt() throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(
            title: "Scaling & Structure",
            webContent: Reference.encodeWebContent(
                "<article><h1>Scaling</h1><p>Hello <strong>world</strong>.</p></article>",
                format: .html
            ),
            referenceType: .webpage
        )
        try database.saveReference(&reference)

        let data = try WebReaderMarkdownExportWorker.prepare(
            reference: reference,
            database: database
        )

        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "# Scaling\n\nHello **world**."
        )

        let cached: String? = try database.dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT markdown FROM webContentMarkdownCache WHERE referenceId = ?",
                arguments: [reference.id]
            )
        }
        XCTAssertEqual(cached, "# Scaling\n\nHello **world**.")
    }

    func testMarkdownClipExportsWithoutChangingItsBody() throws {
        let database = try AppDatabase(DatabaseQueue())
        let body = "# Existing Markdown\n\nKeep <details>raw HTML</details>."
        var reference = Reference(
            title: "Existing note",
            webContent: Reference.encodeWebContent(body, format: .markdown),
            referenceType: .markdown
        )
        try database.saveReference(&reference)

        let data = try WebReaderMarkdownExportWorker.prepare(
            reference: reference,
            database: database
        )

        XCTAssertEqual(String(data: data, encoding: .utf8), body)
        let cachedCount: Int = try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM webContentMarkdownCache") ?? -1
        }
        XCTAssertEqual(cachedCount, 0)
    }

    func testSuggestedFilenameIsSafeAndBounded() {
        XCTAssertEqual(
            WebReaderMarkdownExportWorker.suggestedFilename(for: "  A/B:C\\D  "),
            "A-B-C-D.md"
        )
        XCTAssertEqual(
            WebReaderMarkdownExportWorker.suggestedFilename(for: "   "),
            "Untitled reference.md"
        )
        XCTAssertLessThanOrEqual(
            WebReaderMarkdownExportWorker.suggestedFilename(
                for: String(repeating: "研究", count: 100)
            ).utf8.count,
            240
        )
    }

    func testRejectsReferenceWithoutClippedContent() throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(title: "Empty", referenceType: .webpage)
        try database.saveReference(&reference)

        XCTAssertThrowsError(
            try WebReaderMarkdownExportWorker.prepare(
                reference: reference,
                database: database
            )
        ) { error in
            XCTAssertEqual(
                error as? WebReaderMarkdownExportWorker.PreparationError,
                .missingContent
            )
        }
    }
}
#endif
