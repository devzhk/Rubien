import XCTest
import GRDB
@testable import RubienCore

/// v4 (2026-05): add reader-activity columns (`lastReadAt`, `readCount`) to the
/// `reference` table. Pure ADD COLUMN — no data backfill, no row rewrites.
final class MigrationV4Tests: XCTestCase {

    /// Build a minimal v3-shaped `reference` table — just enough columns to
    /// satisfy NOT NULL constraints and prove the ADD COLUMNs work in place
    /// without churning existing data.
    private func makeV3ShapedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE reference (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    dateAdded TEXT NOT NULL,
                    dateModified TEXT NOT NULL,
                    referenceType TEXT NOT NULL DEFAULT 'Journal Article',
                    readingStatus TEXT NOT NULL DEFAULT 'Unread',
                    verificationStatus TEXT NOT NULL DEFAULT 'legacy',
                    authorsNormalized TEXT NOT NULL DEFAULT ''
                )
            """)
        }
        return queue
    }

    func testV4AddsLastReadAtAndReadCountColumns() throws {
        let queue = try makeV3ShapedQueue()
        try AppDatabase.runV4MigrationForTesting(on: queue)

        try queue.read { db in
            let columns = try Row.fetchAll(
                db,
                sql: "SELECT name, type, \"notnull\", dflt_value FROM pragma_table_info('reference')"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"] as String, $0) })

            let lastReadAt = try XCTUnwrap(byName["lastReadAt"], "v4 must add `lastReadAt` column")
            XCTAssertEqual(lastReadAt["type"] as String?, "DATETIME")
            XCTAssertEqual(lastReadAt["notnull"] as Int?, 0, "lastReadAt must be nullable")

            let readCount = try XCTUnwrap(byName["readCount"], "v4 must add `readCount` column")
            XCTAssertEqual(readCount["type"] as String?, "INTEGER")
            XCTAssertEqual(readCount["notnull"] as Int?, 1, "readCount must be NOT NULL")
            // dflt_value comes back as a SQL literal string, e.g. "0".
            XCTAssertEqual(readCount["dflt_value"] as String?, "0", "readCount must default to 0")
        }
    }

    func testV4ExistingRowsGetNullAndZeroDefaults() throws {
        let queue = try makeV3ShapedQueue()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)",
                arguments: ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"]
            )
        }

        try AppDatabase.runV4MigrationForTesting(on: queue)

        try queue.read { db in
            let row = try XCTUnwrap(
                try Row.fetchOne(db, sql: "SELECT lastReadAt, readCount FROM reference WHERE id = 1")
            )
            XCTAssertNil(row["lastReadAt"] as Date?, "pre-v4 rows start with NULL lastReadAt")
            XCTAssertEqual(row["readCount"] as Int?, 0, "pre-v4 rows start with readCount = 0")
        }
    }

    func testV4CreatesLastReadAtIndex() throws {
        let queue = try makeV3ShapedQueue()
        try AppDatabase.runV4MigrationForTesting(on: queue)

        try queue.read { db in
            let names = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='reference'"
            )
            XCTAssertTrue(
                names.contains("reference_lastReadAt"),
                "v4 must create `reference_lastReadAt` index for descending-sort performance"
            )
        }
    }

    func testV4PreservesExistingReferenceData() throws {
        let queue = try makeV3ShapedQueue()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reference(id, title, dateAdded, dateModified, referenceType, readingStatus)
                    VALUES(?, ?, ?, ?, ?, ?)
                """,
                arguments: [1, "Attention is All You Need", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", "Conference Paper", "Read"]
            )
        }

        try AppDatabase.runV4MigrationForTesting(on: queue)

        try queue.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM reference WHERE id = 1"))
            XCTAssertEqual(row["title"] as String?, "Attention is All You Need")
            XCTAssertEqual(row["referenceType"] as String?, "Conference Paper")
            XCTAssertEqual(row["readingStatus"] as String?, "Read")
        }
    }

    func testFullStackMigrationProducesV4Columns() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let columns: [String] = try Row.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('reference')"
            ).map { $0["name"] as String }
            XCTAssertTrue(columns.contains("lastReadAt"))
            XCTAssertTrue(columns.contains("readCount"))
        }
    }
}
