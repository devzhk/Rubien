import XCTest
import GRDB
@testable import RubienCore

final class ReferenceTypeDecodingTests: XCTestCase {

    func testMarkdownCaseExists() {
        XCTAssertEqual(ReferenceType.markdown.rawValue, "Markdown")
        XCTAssertEqual(ReferenceType.markdown.icon, "doc.plaintext")
    }

    /// A newer peer may persist a rawValue this binary doesn't know.
    /// JSON decoding must fall back to .other, never throw — Reference is
    /// embedded in persisted metadata-intake JSON.
    func testUnknownRawValueJSONDecodesToOther() throws {
        let json = Data(#""Hologram""#.utf8)
        let decoded = try JSONDecoder().decode(ReferenceType.self, from: json)
        XCTAssertEqual(decoded, .other)
    }

    func testKnownRawValueJSONDecodesExactly() throws {
        let json = Data(#""Markdown""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ReferenceType.self, from: json), .markdown)
    }

    /// GRDB row decode of an unknown stored rawValue must not trap
    /// (downgrade / app-CLI skew on a shared library).
    func testUnknownRawValueRowDecodesToOther() throws {
        let db = try AppDatabase(DatabaseQueue())
        var ref = Reference(title: "Future type row")
        _ = try db.saveReference(&ref)
        try db.dbWriter.write { d in
            try d.execute(
                sql: "UPDATE reference SET referenceType = 'Hologram' WHERE id = ?",
                arguments: [ref.id]
            )
        }
        let fetched = try db.fetchReferences(ids: [ref.id!]).first
        XCTAssertEqual(fetched?.referenceType, .other)
    }

    func testCSLExportMapping() {
        XCTAssertEqual(ReferenceType.markdown.cslType, "document")
    }
}
