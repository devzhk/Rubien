import XCTest
import GRDB
@testable import RubienCore

final class MigrationV7Tests: XCTestCase {
    private let syncedTables = ["readingActivity", "assistantActivity", "activityEpoch"]
    private let localTables = ["activityPendingClear", "activityQuarantine"]

    func testFreshDatabaseHasActivitySchemaAndDeterministicEpochs() throws {
        let appDatabase = try AppDatabase(DatabaseQueue())

        try appDatabase.dbWriter.read { db in
            for table in syncedTables + localTables {
                XCTAssertTrue(try db.tableExists(table), "missing \(table)")
            }

            let epochs = try ActivityEpoch.order(Column("kind")).fetchAll(db)
            XCTAssertEqual(epochs.count, 2)
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: epochs.map { ($0.kind, $0.generation) }),
                [.reading: "reading-v7-initial", .assistant: "assistant-v7-initial"]
            )
            XCTAssertTrue(epochs.allSatisfy { $0.revision == 0 && $0.resetAt == nil })

            let dirtyEpochs = try String.fetchAll(
                db,
                sql: """
                    SELECT entityId FROM syncState
                    WHERE entityType = 'activityEpoch' AND isDirty = 1
                    ORDER BY entityId
                    """
            )
            XCTAssertEqual(dirtyEpochs, ["assistant", "reading"])
        }
    }

    func testV6ShapedUpgradeCreatesV7SchemaWithoutTouchingExistingReferences() throws {
        let queue = try DatabaseQueue()
        let appDatabase = try AppDatabase(queue)
        var reference = Reference(title: "Preserve me")
        try appDatabase.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)

        // Remove only the v7 body, leaving the exact v1-v6 tables/data in place.
        try queue.write { db in
            for table in syncedTables + localTables {
                try db.execute(sql: "DROP TABLE \(table)")
            }
            try db.execute(sql: "DELETE FROM syncState WHERE entityType IN ('readingActivity', 'assistantActivity', 'activityEpoch')")
            try db.execute(sql: "DELETE FROM tombstone WHERE entityType IN ('readingActivity', 'assistantActivity', 'activityEpoch')")
        }

        try AppDatabase.runV7MigrationForTesting(on: queue)

        try queue.read { db in
            XCTAssertNotNil(try Reference.fetchOne(db, id: referenceId))
            for table in syncedTables + localTables {
                XCTAssertTrue(try db.tableExists(table), "upgrade missing \(table)")
            }
        }
    }

    func testOnlySyncedActivityTablesHaveDirtyTrackingTriggers() throws {
        let appDatabase = try AppDatabase(DatabaseQueue())
        try appDatabase.dbWriter.read { db in
            for table in syncedTables {
                let triggers = try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name=? ORDER BY name",
                    arguments: [table]
                )
                XCTAssertEqual(
                    triggers,
                    ["\(table)_ad", "\(table)_ai", "\(table)_au"],
                    "unexpected trigger set for \(table)"
                )
            }
            for table in localTables {
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name=?",
                    arguments: [table]
                )
                XCTAssertEqual(count, 0, "local-only \(table) must not sync")
            }
        }
    }

    func testReadingTriggerUsesGenerationScopedCompositeIdentity() throws {
        let appDatabase = try AppDatabase(DatabaseQueue())
        var reference = Reference(title: "Trigger paper")
        try appDatabase.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let context = try appDatabase.activityCaptureContext(for: .reading)
        let day = try XCTUnwrap(LocalDay(rawValue: "2026-07-15"))

        _ = try appDatabase.saveReadingActivityCounter(
            installationId: "installation-a",
            referenceId: referenceId,
            localDay: day,
            cumulativeActiveSeconds: 60,
            lastActiveAt: Date(timeIntervalSince1970: 100),
            context: context
        )

        let expected = "\(context.generation)/installation-a/\(referenceId)/2026-07-15"
        let isDirty = try appDatabase.dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT isDirty FROM syncState
                    WHERE entityType='readingActivity' AND entityId=?
                    """,
                arguments: [expected]
            )
        }
        XCTAssertEqual(isDirty, 1)
    }
}
