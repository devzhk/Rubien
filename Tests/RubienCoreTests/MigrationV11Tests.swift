import XCTest
import GRDB
@testable import RubienCore

final class MigrationV11Tests: XCTestCase {
    private let expectedRunIndexes: Set<String> = [
        "scheduledJobRun_status_scheduledFor",
        "scheduledJobRun_active_jobId",
        "scheduledJobRun_activityAt",
        "scheduledJobRun_jobId_activityAt",
        "scheduledJobRun_unread",
        "scheduledJobRun_assistantTranscriptState",
    ]

    private let staleRunIndexes: [(name: String, columns: String)] = [
        ("scheduledJobRun_jobId_startedAt", "jobId, startedAt"),
        ("scheduledJobRun_status", "status"),
        ("scheduledJobRun_scheduledFor", "scheduledFor"),
        ("scheduledJobRun_jobId_scheduledFor", "jobId, scheduledFor"),
    ]

    func testCurrentSchemaVersionMatchesLastRegisteredMigration() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)

        let lastApplied = try queue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT identifier
                    FROM grdb_migrations
                    ORDER BY rowid DESC
                    LIMIT 1
                    """
            )
        }
        XCTAssertEqual(lastApplied, "v11")
        XCTAssertEqual(AppDatabase.currentSchemaVersion, lastApplied)
    }

    func testRegisteredMigrationCanRepairHealthyDatabaseAgainWithoutChangingData() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        try insertScheduledRun(on: queue)

        try markV11Pending(on: queue)
        XCTAssertNoThrow(try AppDatabase(queue))

        try queue.read { db in
            XCTAssertTrue(try appliedMigrations(db).contains("v11"))
            XCTAssertTrue(try db.columns(in: "activityQuarantine").contains {
                $0.name == "referenceId"
            })
            try assertScheduledFixturePreserved(db)
            XCTAssertTrue(expectedRunIndexes.isSubset(of: try indexNames(
                for: "scheduledJobRun",
                db: db
            )))
        }
    }

    func testMalformedDevelopmentSchemaIsRepairedWithoutLosingRows() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        try insertScheduledRun(on: queue)

        let quarantined = ReadingActivity(
            installationId: "remote-mac",
            referenceId: 42,
            localDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-16")),
            epochRevision: 0,
            generation: "reading-v7-initial",
            activeSeconds: 60,
            lastActiveAt: Date(timeIntervalSince1970: 100),
            dateModified: Date(timeIntervalSince1970: 101)
        )
        let recordData = try JSONEncoder().encode(quarantined)

        try queue.write { db in
            try db.execute(
                sql: "DROP INDEX activityQuarantine_entityType_referenceId_receivedAt"
            )
            try db.execute(
                sql: "ALTER TABLE activityQuarantine DROP COLUMN referenceId"
            )
            try db.execute(sql: """
                CREATE INDEX activityQuarantine_entityType_receivedAt
                ON activityQuarantine(entityType, receivedAt)
                """)
            try db.execute(
                sql: """
                    INSERT INTO activityQuarantine (
                        recordName, entityType, reason, epochRevision,
                        generation, recordData, receivedAt
                    ) VALUES (?, 'readingActivity', 'reference', 0,
                              'reading-v7-initial', ?, ?)
                    """,
                arguments: [
                    "readingActivity:\(quarantined.entityId)",
                    recordData,
                    Date(timeIntervalSince1970: 102),
                ]
            )

            for name in expectedRunIndexes {
                try db.execute(sql: "DROP INDEX \(name)")
            }
            for staleIndex in staleRunIndexes {
                try db.execute(sql: """
                    CREATE INDEX \(staleIndex.name)
                    ON scheduledJobRun(\(staleIndex.columns))
                    """)
            }
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'v11'"
            )
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertTrue(try appliedMigrations(db).contains("v11"))
            XCTAssertTrue(try db.columns(in: "activityQuarantine").contains {
                $0.name == "referenceId"
            })
            let quarantine = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT * FROM activityQuarantine")
            )
            XCTAssertEqual(quarantine["referenceId"] as Int64?, 42)
            XCTAssertEqual(
                quarantine["recordName"] as String?,
                "readingActivity:\(quarantined.entityId)"
            )
            XCTAssertEqual(quarantine["entityType"] as String?, "readingActivity")
            XCTAssertEqual(quarantine["reason"] as String?, "reference")
            XCTAssertEqual(quarantine["epochRevision"] as Int64?, 0)
            XCTAssertEqual(
                quarantine["generation"] as String?,
                "reading-v7-initial"
            )
            XCTAssertEqual(quarantine["recordData"] as Data?, recordData)
            XCTAssertEqual(
                quarantine["receivedAt"] as Date?,
                Date(timeIntervalSince1970: 102)
            )

            let quarantineIndexes = try indexNames(
                for: "activityQuarantine",
                db: db
            )
            XCTAssertTrue(quarantineIndexes.contains(
                "activityQuarantine_entityType_referenceId_receivedAt"
            ))
            XCTAssertFalse(quarantineIndexes.contains(
                "activityQuarantine_entityType_receivedAt"
            ))

            let runIndexes = try indexNames(for: "scheduledJobRun", db: db)
            XCTAssertTrue(expectedRunIndexes.isSubset(of: runIndexes))
            XCTAssertTrue(
                runIndexes.isDisjoint(with: staleRunIndexes.map(\.name))
            )
            try assertScheduledFixturePreserved(db)
        }
    }

    private func insertScheduledRun(on queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO scheduledJob (
                    id, name, prompt, weekdayMask, localMinuteOfDay,
                    isEnabled, provider, webAccess, notifyOnCompletion,
                    createdAt, dateModified
                ) VALUES (
                    'job-1', 'Job', 'Prompt', 127, 480,
                    1, 'codex', 1, 0, ?, ?
                )
                """, arguments: [
                    Date(timeIntervalSince1970: 1),
                    Date(timeIntervalSince1970: 1),
                ])
            try db.execute(sql: """
                INSERT INTO scheduledJobRun (
                    id, jobId, trigger, occurrenceKey, scheduledFor,
                    startedAt, finishedAt, status, provider,
                    providerSessionId, failureKind, isUnread, hiddenAt,
                    assistantTranscriptState, assistantTranscriptStatusCode
                ) VALUES (
                    'run-1', 'job-1', 'manual', 'one', ?,
                    ?, ?, 'succeeded', 'codex',
                    'session-1', 'none', 1, ?,
                    'imported', 'complete'
                )
                """, arguments: [
                    Date(timeIntervalSince1970: 2),
                    Date(timeIntervalSince1970: 3),
                    Date(timeIntervalSince1970: 4),
                    Date(timeIntervalSince1970: 5),
                ])
        }
    }

    private func markV11Pending(on queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'v11'"
            )
        }
    }

    private func appliedMigrations(_ db: Database) throws -> Set<String> {
        try Set(String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations"
        ))
    }

    private func assertScheduledFixturePreserved(
        _ db: Database,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let job = try XCTUnwrap(
            Row.fetchOne(db, sql: "SELECT * FROM scheduledJob WHERE id = 'job-1'"),
            file: file,
            line: line
        )
        XCTAssertEqual(job["name"] as String?, "Job", file: file, line: line)
        XCTAssertEqual(job["prompt"] as String?, "Prompt", file: file, line: line)
        XCTAssertEqual(job["weekdayMask"] as Int64?, 127, file: file, line: line)
        XCTAssertEqual(job["localMinuteOfDay"] as Int64?, 480, file: file, line: line)
        XCTAssertEqual(job["isEnabled"] as Bool?, true, file: file, line: line)
        XCTAssertEqual(job["provider"] as String?, "codex", file: file, line: line)
        XCTAssertEqual(job["webAccess"] as Bool?, true, file: file, line: line)
        XCTAssertEqual(
            job["notifyOnCompletion"] as Bool?,
            false,
            file: file,
            line: line
        )
        XCTAssertEqual(
            job["createdAt"] as Date?,
            Date(timeIntervalSince1970: 1),
            file: file,
            line: line
        )
        XCTAssertEqual(
            job["dateModified"] as Date?,
            Date(timeIntervalSince1970: 1),
            file: file,
            line: line
        )

        let run = try XCTUnwrap(
            Row.fetchOne(db, sql: "SELECT * FROM scheduledJobRun WHERE id = 'run-1'"),
            file: file,
            line: line
        )
        XCTAssertEqual(run["jobId"] as String?, "job-1", file: file, line: line)
        XCTAssertEqual(run["trigger"] as String?, "manual", file: file, line: line)
        XCTAssertEqual(run["occurrenceKey"] as String?, "one", file: file, line: line)
        XCTAssertEqual(
            run["scheduledFor"] as Date?,
            Date(timeIntervalSince1970: 2),
            file: file,
            line: line
        )
        XCTAssertEqual(
            run["startedAt"] as Date?,
            Date(timeIntervalSince1970: 3),
            file: file,
            line: line
        )
        XCTAssertEqual(
            run["finishedAt"] as Date?,
            Date(timeIntervalSince1970: 4),
            file: file,
            line: line
        )
        XCTAssertEqual(run["status"] as String?, "succeeded", file: file, line: line)
        XCTAssertEqual(run["provider"] as String?, "codex", file: file, line: line)
        XCTAssertEqual(
            run["providerSessionId"] as String?,
            "session-1",
            file: file,
            line: line
        )
        XCTAssertEqual(run["failureKind"] as String?, "none", file: file, line: line)
        XCTAssertEqual(run["isUnread"] as Bool?, true, file: file, line: line)
        XCTAssertEqual(
            run["hiddenAt"] as Date?,
            Date(timeIntervalSince1970: 5),
            file: file,
            line: line
        )
        XCTAssertEqual(
            run["assistantTranscriptState"] as String?,
            "imported",
            file: file,
            line: line
        )
        XCTAssertEqual(
            run["assistantTranscriptStatusCode"] as String?,
            "complete",
            file: file,
            line: line
        )
    }

    private func indexNames(for table: String, db: Database) throws -> Set<String> {
        try Set(String.fetchAll(
            db,
            sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND tbl_name = ?
                """,
            arguments: [table]
        ))
    }
}
