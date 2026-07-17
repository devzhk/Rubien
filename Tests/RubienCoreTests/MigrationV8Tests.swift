import XCTest
import GRDB
@testable import RubienCore

final class MigrationV8Tests: XCTestCase {
    private let localTables = ["scheduledJob", "scheduledJobRun"]

    func testFreshDatabaseHasLocalScheduledJobSchema() throws {
        let appDatabase = try AppDatabase(DatabaseQueue())

        try appDatabase.dbWriter.read { db in
            for table in localTables {
                XCTAssertTrue(try db.tableExists(table), "missing \(table)")
                let triggerCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name=?",
                    arguments: [table]
                )
                XCTAssertEqual(triggerCount, 0, "local-only \(table) must not sync")
            }
            let indexNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='scheduledJobRun'"
            )
            XCTAssertTrue(indexNames.contains("scheduledJobRun_status_scheduledFor"))
            XCTAssertTrue(indexNames.contains("scheduledJobRun_active_jobId"))
            XCTAssertTrue(indexNames.contains("scheduledJobRun_activityAt"))
            XCTAssertTrue(indexNames.contains("scheduledJobRun_jobId_activityAt"))
            let activeIndexSQL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name='scheduledJobRun_active_jobId'"
            )
            XCTAssertTrue(activeIndexSQL?.contains(
                "status NOT IN ('succeeded', 'failed', 'cancelled')"
            ) == true)
            let activityIndexSQL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name='scheduledJobRun_activityAt'"
            )
            XCTAssertTrue(activityIndexSQL?.contains("COALESCE(finishedAt, startedAt, scheduledFor)") == true)
        }
    }

    func testV7ShapedUpgradePreservesExistingReferences() throws {
        let queue = try DatabaseQueue()
        let appDatabase = try AppDatabase(queue)
        var reference = Reference(title: "Preserve me")
        try appDatabase.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)

        try queue.write { db in
            try db.execute(sql: "DROP TABLE scheduledJobRun")
            try db.execute(sql: "DROP TABLE scheduledJob")
        }

        try AppDatabase.runV8MigrationForTesting(on: queue)

        try queue.read { db in
            XCTAssertNotNil(try Reference.fetchOne(db, id: referenceId))
            for table in localTables {
                XCTAssertTrue(try db.tableExists(table), "upgrade missing \(table)")
            }
        }
    }

    func testRunUniquenessAndCascadeDelete() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let now = date("2026-07-13T07:00:00Z")
        let job = try database.createScheduledJob(
            definition(name: "Morning scan"),
            now: now,
            calendar: calendar
        )
        let claim = try database.claimManualScheduledJob(id: job.id, now: now)
        XCTAssertTrue(try database.finishScheduledJobRun(id: claim.run.id, status: .succeeded))

        XCTAssertThrowsError(try database.dbWriter.write { db in
            var duplicate = claim.run
            duplicate.id = UUID().uuidString.lowercased()
            duplicate.status = .succeeded
            duplicate.finishedAt = now
            try duplicate.insert(db)
        }) { error in
            XCTAssertTrue(error is DatabaseError)
        }
        let deduplicatedCount = try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledJobRun")
        }
        XCTAssertEqual(deduplicatedCount, 1)

        try database.deleteScheduledJob(id: job.id)

        let runCount = try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledJobRun")
        }
        XCTAssertEqual(runCount, 0)
    }

    private func definition(name: String) -> ScheduledJobDefinition {
        .init(
            name: name,
            prompt: "Find papers",
            recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
            provider: .claude
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
