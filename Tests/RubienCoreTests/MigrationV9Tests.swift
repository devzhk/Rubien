import GRDB
import XCTest
@testable import RubienCore

final class MigrationV9Tests: XCTestCase {
    func testFreshDatabaseHasHiddenRunHistoryMarker() throws {
        let database = try AppDatabase(DatabaseQueue())

        try database.dbWriter.read { db in
            let columns = try db.columns(in: "scheduledJobRun")
            let hiddenAt = try XCTUnwrap(columns.first { $0.name == "hiddenAt" })
            XCTAssertFalse(hiddenAt.isNotNull)
        }
    }

    func testV8UpgradePreservesRunsAsVisible() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try AppDatabase.runV8MigrationForTesting(on: queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO scheduledJob (
                    id, name, prompt, weekdayMask, localMinuteOfDay, isEnabled,
                    provider, webAccess, notifyOnCompletion, createdAt, dateModified
                ) VALUES ('job-1', 'Job', 'Prompt', 127, 480, 1,
                          'claude', 1, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """)
            try db.execute(sql: """
                INSERT INTO scheduledJobRun (
                    id, jobId, trigger, occurrenceKey, scheduledFor, finishedAt,
                    status, provider, isUnread
                ) VALUES ('run-1', 'job-1', 'scheduled', '2026-07-20/480',
                          CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'succeeded', 'claude', 1)
                """)
        }

        try AppDatabase.runV9MigrationForTesting(on: queue)

        try queue.read { db in
            let hiddenAt = try Date.fetchOne(
                db,
                sql: "SELECT hiddenAt FROM scheduledJobRun WHERE id = 'run-1'"
            )
            XCTAssertNil(hiddenAt)
        }
    }
}
