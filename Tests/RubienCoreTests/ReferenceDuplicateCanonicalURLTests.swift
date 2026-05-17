import XCTest
import GRDB
@testable import RubienCore

final class ReferenceDuplicateCanonicalURLTests: XCTestCase {

    // Setup pattern verified by `grep -n "AppDatabase(DatabaseQueue" Tests/RubienCoreTests/`:
    // existing tests like `StatusOptionMutationTests` and `MigrationV4Tests` use
    // `try AppDatabase(DatabaseQueue())` for in-memory databases.

    func testCanonicalFormDeduplicatesEquivalentURLs() throws {
        let appDB = try AppDatabase(DatabaseQueue())

        // Insert a paper-URL-derived reference with a canonical URL via the
        // same insert pattern existing tests use. (Look at how
        // StatusOptionMutationTests / MigrationV4Tests insert records — most
        // use `try appDB.dbWriter.write { db in try ref.insert(db) }`.)
        //
        // AuthorName.init signature is `(given: String, family: String)` —
        // verified at Sources/RubienCore/Models/Reference.swift:33. The plan
        // previously had the labels reversed.
        var first = Reference(
            title: "Sample Paper",
            authors: [AuthorName(given: "J.", family: "Smith")],
            url: "https://openreview.net/forum?id=ABCD",
            referenceType: .conferencePaper,
            metadataSource: .publisherCitationMeta
        )
        let firstID = try appDB.dbWriter.write { db -> Int64 in
            try first.insert(db)
            return first.id ?? db.lastInsertedRowID
        }

        // Simulate a second paste with a non-canonical form. After Task 3's
        // canonicalization, both should produce the same canonical URL.
        let inputURL = URL(string: "HTTPS://WWW.OPENREVIEW.NET/forum?id=ABCD#fragment")!
        let canonical = PaperURLResolver.canonicalize(inputURL)?.absoluteString
        XCTAssertEqual(canonical, "https://openreview.net/forum?id=ABCD")

        let probe = Reference(
            title: "Sample Paper (re-paste)",
            authors: [AuthorName(given: "J.", family: "Smith")],
            url: canonical,
            referenceType: .conferencePaper,
            metadataSource: .publisherCitationMeta
        )

        // findDuplicateReferenceID is an instance method on AppDatabase
        // (Sources/RubienCore/Database/AppDatabase.swift:1958), NOT a static.
        // Call through dbWriter.read.
        let match = try appDB.dbWriter.read { db in
            try appDB.findDuplicateReferenceID(for: probe, db: db)
        }
        XCTAssertEqual(match?.id, firstID,
                       "Canonical URL should match the existing row's URL")
    }
}
