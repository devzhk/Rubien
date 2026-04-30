import XCTest
import GRDB
@testable import RubienCore

final class MigrationV2Tests: XCTestCase {

    func testV2CreatesPdfCacheTable() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let cols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('pdfCache')")
                .map { $0["name"] as String }
            XCTAssertEqual(
                Set(cols),
                Set(["referenceId", "localFilename", "contentHash", "assetVersion", "materializedAt", "lastOpenedAt"]),
                "pdfCache schema must match the spec"
            )
        }
    }

    func testV2CreatesPdfUploadQueueTable() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let cols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('pdfUploadQueue')")
                .map { $0["name"] as String }
            XCTAssertEqual(
                Set(cols),
                Set(["referenceId", "localFilename", "queuedAt"]),
                "pdfUploadQueue schema must match the spec"
            )
        }
    }

    /// Pre-v2 references with a populated pdfPath must end up with a pdfCache row
    /// AND a pdfUploadQueue row after migration. Cache row's contentHash is a
    /// placeholder ("pending") because we hash lazily on first read or upload —
    /// hashing during migration would block app launch on a large library.
    func testV2BackfillsPdfPathIntoCacheAndQueue() throws {
        // Build a v1-shaped DB by hand (we can't roll back the migrator, so we
        // fake the v1 layout in-memory + then run only v2 manually).
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE reference (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    dateAdded TEXT NOT NULL,
                    dateModified TEXT NOT NULL,
                    pdfPath TEXT,
                    referenceType TEXT NOT NULL DEFAULT 'Journal Article',
                    verificationStatus TEXT NOT NULL DEFAULT 'legacy',
                    readingStatus TEXT NOT NULL DEFAULT 'unread',
                    authorsNormalized TEXT NOT NULL DEFAULT ''
                )
            """)
            try db.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified, pdfPath)
                VALUES
                  (1, 'with-pdf',  '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'PDFs/abc.pdf'),
                  (2, 'no-pdf',    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL),
                  (3, 'empty-pdf', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '')
            """)
        }

        // Run only the v2 part of the AppDatabase migrator. (We can do this by
        // calling AppDatabase.makeMigrator with a fake mark; in practice this
        // helper is added in the implementation step below.)
        try AppDatabase.runV2MigrationForTesting(on: queue)

        try queue.read { db in
            let cacheCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache") ?? -1
            XCTAssertEqual(cacheCount, 1, "only ref 1 had a non-empty pdfPath")

            let cached = try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=1")!
            XCTAssertEqual(cached["localFilename"] as String?, "PDFs/abc.pdf")
            XCTAssertEqual(cached["contentHash"] as String?, "pending")
            XCTAssertEqual(cached["assetVersion"] as Int64?, 1)
            XCTAssertNotNil(cached["materializedAt"] as String?)

            let queueCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? -1
            XCTAssertEqual(queueCount, 1, "ref 1 needs to be pushed up to CloudKit on next sync")

            let queued = try Row.fetchOne(db, sql: "SELECT * FROM pdfUploadQueue WHERE referenceId=1")!
            XCTAssertEqual(queued["localFilename"] as String?, "PDFs/abc.pdf")
        }
    }

    /// Beyond column-shape: verify the load-bearing schema facts — FK cascade
    /// from reference to both new tables, materializedAt nullable (load-bearing
    /// "metadata known but file not on this device" signal), and that the
    /// sqlNowISO8601 default actually populates lastOpenedAt / queuedAt when
    /// callers omit them.
    func testV2SchemaSemanticsAreLoadBearing() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.write { db in
            // Insert a Reference + cache row; omit lastOpenedAt to exercise default.
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion)
                VALUES(1, 'x.pdf', 'h', 1)
            """)
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename) VALUES(1, 'x.pdf')
            """)

            // Default fired? lastOpenedAt and queuedAt must be non-null after
            // an insert that omitted them.
            let cacheLastOpened = try String.fetchOne(db, sql: "SELECT lastOpenedAt FROM pdfCache WHERE referenceId=1")
            XCTAssertNotNil(cacheLastOpened, "lastOpenedAt default must populate when caller omits the column")
            let queueQueuedAt = try String.fetchOne(db, sql: "SELECT queuedAt FROM pdfUploadQueue WHERE referenceId=1")
            XCTAssertNotNil(queueQueuedAt, "queuedAt default must populate when caller omits the column")

            // Nullability: materializedAt may be NULL (the on-demand "metadata
            // known but file not on this device" signal). Insert another row
            // with explicit NULL to confirm the column accepts it.
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(2, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(2, 'y.pdf', 'h', 1, NULL)
            """)
            let materialized = try String.fetchOne(db, sql: "SELECT materializedAt FROM pdfCache WHERE referenceId=2")
            XCTAssertNil(materialized, "materializedAt must accept NULL")

            // FK cascade: deleting a Reference must cascade-delete both child
            // rows (pdfCache + pdfUploadQueue).
            try db.execute(sql: "DELETE FROM reference WHERE id=1")
            let cacheCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=1") ?? -1
            XCTAssertEqual(cacheCount, 0, "pdfCache FK cascade must delete the row when its Reference is deleted")
            let queueCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue WHERE referenceId=1") ?? -1
            XCTAssertEqual(queueCount, 0, "pdfUploadQueue FK cascade must delete the row when its Reference is deleted")
        }
    }

    func testV2DropsPdfPathColumn() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let refCols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('reference')")
                .map { $0["name"] as String }
            XCTAssertFalse(
                refCols.contains("pdfPath"),
                "pdfPath column must be dropped from reference; lookups go through pdfCache"
            )
        }
    }
}
