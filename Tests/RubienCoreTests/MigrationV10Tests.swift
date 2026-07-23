import XCTest
import GRDB
@testable import RubienCore

final class MigrationV10Tests: XCTestCase {
    func testFreshDatabaseContainsLocalAssistantTranscriptSchema() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)

        try queue.read { db in
            for table in [
                "assistantConversation",
                "assistantTurn",
                "assistantTranscriptEntry",
                "assistantTranscriptEntryFts",
                "assistantAttachment",
                "assistantSessionAlias",
            ] {
                XCTAssertTrue(try db.tableExists(table), "Missing \(table)")
            }

            let runColumns = try db.columns(in: "scheduledJobRun")
            let state = try XCTUnwrap(
                runColumns.first { $0.name == "assistantTranscriptState" }
            )
            XCTAssertTrue(state.isNotNull)
            XCTAssertEqual(state.defaultValueSQL, "'none'")
            XCTAssertNotNil(
                runColumns.first { $0.name == "assistantTranscriptStatusCode" }
            )
        }
    }

    func testAssistantTranscriptTablesHaveNoCloudKitDirtyOrTombstoneTriggers() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)

        try queue.read { db in
            for table in [
                "assistantConversation",
                "assistantTurn",
                "assistantTranscriptEntry",
                "assistantAttachment",
                "assistantSessionAlias",
                "scheduledJob",
                "scheduledJobRun",
            ] {
                let triggerSQL = try String.fetchAll(
                    db,
                    sql: """
                        SELECT COALESCE(sql, '') FROM sqlite_master
                        WHERE type = 'trigger' AND tbl_name = ?
                        """,
                    arguments: [table]
                ).joined(separator: "\n")
                XCTAssertFalse(
                    triggerSQL.contains("syncState"),
                    "local-only \(table) must not enqueue CloudKit writes"
                )
                XCTAssertFalse(
                    triggerSQL.contains("INSERT INTO tombstone"),
                    "local-only \(table) must not create CloudKit tombstones"
                )
            }
        }
    }

    func testUpgradeClassifiesOnlyUsableVisibleProviderSessionsAsLegacyEligible() throws {
        let queue = try DatabaseQueue()
        try makeV9Shape(on: queue)
        let now = Date()

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduledJobRun (
                        id, jobId, trigger, occurrenceKey, scheduledFor,
                        status, provider, providerSessionId, isUnread, hiddenAt
                    ) VALUES
                        ('usable', 'job-1', 'manual', 'one', ?,
                         'succeeded', 'codex', ' thread-1 ', 0, NULL),
                        ('missing', 'job-1', 'manual', 'two', ?,
                         'succeeded', 'codex', NULL, 0, NULL),
                        ('blank', 'job-1', 'manual', 'three', ?,
                         'succeeded', 'claude', '   ', 0, NULL),
                        ('hidden', 'job-1', 'deleted', 'four', ?,
                         'cancelled', 'deleted', 'thread-4', 0, ?)
                    """,
                arguments: [now, now, now, now, now]
            )
        }

        try AppDatabase.runV10MigrationForTesting(on: queue)

        try queue.read { db in
            let states = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, assistantTranscriptState
                    FROM scheduledJobRun ORDER BY id
                    """
            ).reduce(into: [String: String]()) { result, row in
                result[row["id"] as String] = row["assistantTranscriptState"]
            }
            XCTAssertEqual(states["usable"], "legacyEligible")
            XCTAssertEqual(states["missing"], "none")
            XCTAssertEqual(states["blank"], "none")
            XCTAssertEqual(states["hidden"], "deleted")
        }
    }

    func testConversationDeleteLeavesRevisionedAliasTombstone() throws {
        let queue = try DatabaseQueue()
        let database = try AppDatabase(queue)
        let now = Date()

        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO assistantConversation (
                        id, provider, origin, contextKind, createdAt, lastActivityAt
                    ) VALUES ('conversation-1', 'codex', 'rubien', 'library', ?, ?)
                    """,
                arguments: [now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO assistantSessionAlias (
                        keyHash, conversationId, provider, ownerRevision, recordedAt
                    ) VALUES ('hash-1', 'conversation-1', 'codex', 3, ?)
                    """,
                arguments: [now]
            )
            try db.execute(
                sql: "DELETE FROM assistantConversation WHERE id = 'conversation-1'"
            )
        }

        try queue.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT conversationId, ownerRevision
                        FROM assistantSessionAlias WHERE keyHash = 'hash-1'
                        """
                )
            )
            XCTAssertNil(row["conversationId"] as String?)
            XCTAssertEqual(row["ownerRevision"] as Int, 4)
        }
    }

    private func makeV9Shape(on queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE reference (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE scheduledJob (id TEXT PRIMARY KEY)")
            try db.execute(sql: """
                CREATE TABLE scheduledJobRun (
                    id TEXT NOT NULL PRIMARY KEY,
                    jobId TEXT NOT NULL REFERENCES scheduledJob(id) ON DELETE CASCADE,
                    trigger TEXT NOT NULL,
                    occurrenceKey TEXT NOT NULL,
                    scheduledFor DATETIME NOT NULL,
                    startedAt DATETIME,
                    finishedAt DATETIME,
                    status TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    providerSessionId TEXT,
                    failureKind TEXT,
                    isUnread BOOLEAN NOT NULL,
                    hiddenAt DATETIME,
                    UNIQUE (jobId, occurrenceKey)
                )
                """)
            try db.execute(sql: "INSERT INTO scheduledJob(id) VALUES ('job-1')")
        }
    }
}
