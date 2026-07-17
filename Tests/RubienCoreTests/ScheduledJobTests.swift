import XCTest
import GRDB
@testable import RubienCore

final class ScheduledJobTests: XCTestCase {
    func testRecurrenceUsesMondayBasedMaskAndIsStrictlyAfter() throws {
        let calendar = utcCalendar()
        let recurrence = ScheduledRecurrence(
            weekdayMask: ScheduledWeekday.monday.mask | ScheduledWeekday.wednesday.mask,
            localMinuteOfDay: 8 * 60 + 30
        )

        XCTAssertEqual(
            recurrence.nextOccurrence(after: date("2026-07-13T08:29:00Z"), calendar: calendar),
            date("2026-07-13T08:30:00Z")
        )
        XCTAssertEqual(
            recurrence.nextOccurrence(after: date("2026-07-13T08:30:00Z"), calendar: calendar),
            date("2026-07-15T08:30:00Z")
        )
        XCTAssertEqual(
            recurrence.latestOccurrence(onOrBefore: date("2026-07-15T09:00:00Z"), calendar: calendar),
            date("2026-07-15T08:30:00Z")
        )
    }

    func testSpringDSTGapMovesToNextValidLocalTime() throws {
        let calendar = losAngelesCalendar()
        let recurrence = ScheduledRecurrence(
            weekdayMask: ScheduledWeekday.sunday.mask,
            localMinuteOfDay: 2 * 60 + 30
        )

        let occurrence = try XCTUnwrap(
            recurrence.nextOccurrence(
                after: date("2026-03-08T09:00:00Z"),
                calendar: calendar
            )
        )
        let components = calendar.dateComponents([.hour, .minute], from: occurrence)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 0)
    }

    func testFallDSTRepeatUsesFirstOccurrence() throws {
        let calendar = losAngelesCalendar()
        let recurrence = ScheduledRecurrence(
            weekdayMask: ScheduledWeekday.sunday.mask,
            localMinuteOfDay: 90
        )

        XCTAssertEqual(
            recurrence.nextOccurrence(
                after: date("2026-11-01T07:00:00Z"),
                calendar: calendar
            ),
            date("2026-11-01T08:30:00Z")
        )
    }

    func testCreateNormalizesAndPauseRecomputesNextRun() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let job = try database.createScheduledJob(
            .init(
                name: "  Morning scan  ",
                prompt: "  Find papers  ",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
                provider: .claude,
                model: "  ",
                effort: " high "
            ),
            now: date("2026-07-13T07:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(job.name, "Morning scan")
        XCTAssertEqual(job.prompt, "Find papers")
        XCTAssertNil(job.model)
        XCTAssertEqual(job.effort, "high")
        XCTAssertEqual(job.nextRunAt, date("2026-07-13T08:00:00Z"))

        let paused = try database.setScheduledJobEnabled(
            id: job.id,
            isEnabled: false,
            now: date("2026-07-13T07:30:00Z"),
            calendar: calendar
        )
        XCTAssertFalse(paused.isEnabled)
        XCTAssertNil(paused.nextRunAt)
    }

    func testClaimSerializesRunsAndLeavesOtherJobsUnclaimed() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let creationTime = date("2026-07-13T07:00:00Z")
        let first = try database.createScheduledJob(
            definition(name: "First"), now: creationTime, calendar: calendar
        )
        let second = try database.createScheduledJob(
            definition(name: "Second"), now: creationTime, calendar: calendar
        )
        let dueTime = date("2026-07-13T08:01:00Z")

        let firstClaim = try XCTUnwrap(
            database.claimNextDueScheduledJob(now: dueTime, calendar: calendar)
        )
        XCTAssertTrue([first.id, second.id].contains(firstClaim.job.id))
        XCTAssertEqual(firstClaim.run.trigger, .scheduled)
        XCTAssertNil(try database.claimNextDueScheduledJob(now: dueTime, calendar: calendar))

        XCTAssertTrue(try database.markScheduledJobRunStarted(id: firstClaim.run.id, at: dueTime))
        XCTAssertTrue(try database.finishScheduledJobRun(id: firstClaim.run.id, status: .succeeded, at: dueTime))

        let secondClaim = try XCTUnwrap(
            database.claimNextDueScheduledJob(now: dueTime, calendar: calendar)
        )
        XCTAssertNotEqual(secondClaim.job.id, firstClaim.job.id)
    }

    func testManagementListOrdersEnabledByNextRunThenPausedByName() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let now = date("2026-07-13T07:00:00Z")
        _ = try database.createScheduledJob(
            .init(
                name: "Later",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 10 * 60),
                provider: .claude
            ),
            now: now,
            calendar: calendar
        )
        _ = try database.createScheduledJob(
            .init(
                name: "Sooner",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
                provider: .claude
            ),
            now: now,
            calendar: calendar
        )
        for name in ["Zulu", "Alpha"] {
            _ = try database.createScheduledJob(
                .init(
                    name: name,
                    prompt: "Find papers",
                    recurrence: .init(weekdayMask: 127, localMinuteOfDay: 9 * 60),
                    isEnabled: false,
                    provider: .claude
                ),
                now: now,
                calendar: calendar
            )
        }

        XCTAssertEqual(
            try database.fetchScheduledJobs().map(\.name),
            ["Sooner", "Later", "Alpha", "Zulu"]
        )
    }

    func testCatchUpClaimsOnlyMostRecentMissedOccurrence() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let job = try database.createScheduledJob(
            .init(
                name: "Weekly scan",
                prompt: "Find papers",
                recurrence: .init(
                    weekdayMask: ScheduledWeekday.monday.mask,
                    localMinuteOfDay: 8 * 60
                ),
                provider: .claude
            ),
            now: date("2026-07-06T07:00:00Z"),
            calendar: calendar
        )

        let claim = try XCTUnwrap(
            database.claimNextDueScheduledJob(
                now: date("2026-07-13T09:00:00Z"),
                calendar: calendar
            )
        )
        XCTAssertEqual(claim.job.id, job.id)
        XCTAssertEqual(claim.run.trigger, .catchUp)
        XCTAssertEqual(claim.run.scheduledFor, date("2026-07-13T08:00:00Z"))
        XCTAssertEqual(claim.run.occurrenceKey, "2026-07-13")
        XCTAssertEqual(claim.job.nextRunAt, date("2026-07-20T08:00:00Z"))
    }

    func testOccurrenceIdentityIsGregorianInTheSourceTimeZone() throws {
        let database = try AppDatabase(DatabaseQueue())
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let job = try database.createScheduledJob(
            .init(
                name: "Late scan",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 23 * 60 + 30),
                provider: .claude
            ),
            now: date("2026-07-14T05:00:00Z"), // July 13 at 22:00 in Los Angeles
            calendar: buddhist
        )

        let first = try XCTUnwrap(database.claimNextDueScheduledJob(
            now: date("2026-07-14T06:31:00Z"),
            calendar: buddhist
        ))
        XCTAssertEqual(first.run.scheduledFor, date("2026-07-14T06:30:00Z"))
        XCTAssertEqual(first.run.occurrenceKey, "2026-07-13")
        XCTAssertTrue(try database.finishScheduledJobRun(id: first.run.id, status: .succeeded))

        // Re-present the same occurrence through a different system calendar.
        // The Gregorian local-day identity must still deduplicate it.
        try database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE scheduledJob SET nextRunAt = ? WHERE id = ?",
                arguments: [first.run.scheduledFor, job.id]
            )
        }
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = buddhist.timeZone
        XCTAssertNil(try database.claimNextDueScheduledJob(
            now: date("2026-07-14T06:32:00Z"),
            calendar: japanese
        ))
        XCTAssertEqual(try database.fetchScheduledJobRuns(jobId: job.id).count, 1)
    }

    func testEditingAfterTodaysRunSkipsTheConsumedLocalDay() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let job = try database.createScheduledJob(
            definition(name: "Morning scan"),
            now: date("2026-07-13T07:00:00Z"),
            calendar: calendar
        )
        let run = try XCTUnwrap(database.claimNextDueScheduledJob(
            now: date("2026-07-13T08:01:00Z"),
            calendar: calendar
        ))
        XCTAssertTrue(try database.finishScheduledJobRun(id: run.run.id, status: .succeeded))

        let edited = try database.updateScheduledJob(
            id: job.id,
            definition: .init(
                name: "Later scan",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 9 * 60),
                provider: .claude
            ),
            now: date("2026-07-13T08:30:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(edited.nextRunAt, date("2026-07-14T09:00:00Z"))
        XCTAssertNil(try database.claimNextDueScheduledJob(
            now: date("2026-07-13T09:01:00Z"),
            calendar: calendar
        ))
    }

    func testClockRecalculationPreservesOverdueDeadlineForCatchUpClassification() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let job = try database.createScheduledJob(
            .init(
                name: "Weekly scan",
                prompt: "Find papers",
                recurrence: .init(
                    weekdayMask: ScheduledWeekday.monday.mask,
                    localMinuteOfDay: 8 * 60
                ),
                provider: .claude
            ),
            now: date("2026-07-06T07:00:00Z"),
            calendar: calendar
        )

        try database.recalculateScheduledJobNextRuns(
            now: date("2026-07-13T09:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(
            try database.fetchScheduledJob(id: job.id)?.nextRunAt,
            date("2026-07-06T08:00:00Z")
        )
        let claim = try XCTUnwrap(database.claimNextDueScheduledJob(
            now: date("2026-07-13T09:00:00Z"),
            calendar: calendar
        ))
        XCTAssertEqual(claim.run.trigger, .catchUp)
    }

    func testWestwardTimeZoneChangeDoesNotRunTodaysOccurrenceEarly() throws {
        let database = try AppDatabase(DatabaseQueue())
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var hawaii = Calendar(identifier: .gregorian)
        hawaii.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        let job = try database.createScheduledJob(
            .init(
                name: "Daily scan",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
                provider: .claude
            ),
            now: date("2026-07-12T14:00:00Z"),
            calendar: pacific
        )

        // Record the previous local day so recalculation does not legitimately
        // select it as a missed catch-up occurrence in the new zone.
        let previous = try database.claimNextDueScheduledJob(
            now: date("2026-07-12T16:00:00Z"),
            calendar: pacific
        )!
        XCTAssertTrue(try database.finishScheduledJobRun(id: previous.run.id, status: .succeeded))

        try database.recalculateScheduledJobNextRuns(
            now: date("2026-07-13T15:30:00Z"), // 05:30 in Hawaii
            calendar: hawaii
        )

        XCTAssertEqual(
            try database.fetchScheduledJob(id: job.id)?.nextRunAt,
            date("2026-07-13T18:00:00Z") // 08:00 in Hawaii
        )
        XCTAssertNil(try database.claimNextDueScheduledJob(
            now: date("2026-07-13T15:30:00Z"),
            calendar: hawaii
        ))
    }

    func testManualRunDoesNotAdvanceScheduleAndRecoveryClassifiesState() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let job = try database.createScheduledJob(
            definition(name: "Manual"),
            now: date("2026-07-13T07:00:00Z"),
            calendar: calendar
        )
        let originalNextRun = job.nextRunAt
        let pending = try database.claimManualScheduledJob(
            id: job.id,
            now: date("2026-07-13T07:10:00Z")
        )

        XCTAssertTrue(pending.run.occurrenceKey.hasPrefix("manual/"))

        XCTAssertEqual(try database.fetchScheduledJob(id: job.id)?.nextRunAt, originalNextRun)
        XCTAssertEqual(try database.recoverInterruptedScheduledJobRuns(), 1)
        let recoveredPending = try XCTUnwrap(database.fetchScheduledJobRun(id: pending.run.id))
        XCTAssertEqual(recoveredPending.status, .failed)
        XCTAssertEqual(recoveredPending.failureKind, .interruptedBeforeStart)
        XCTAssertTrue(recoveredPending.isUnread)

        let running = try database.claimManualScheduledJob(id: job.id)
        XCTAssertTrue(try database.markScheduledJobRunStarted(id: running.run.id))
        XCTAssertEqual(try database.recoverInterruptedScheduledJobRuns(), 1)
        let recoveredRunning = try XCTUnwrap(database.fetchScheduledJobRun(id: running.run.id))
        XCTAssertEqual(recoveredRunning.failureKind, .interrupted)
    }

    func testRecentRunsOrderByExecutionActivityInsteadOfNominalOccurrence() throws {
        let database = try AppDatabase(DatabaseQueue())
        let job = try database.createScheduledJob(
            definition(name: "History"),
            now: date("2026-07-13T07:00:00Z"),
            calendar: utcCalendar()
        )
        let earlier = try database.claimManualScheduledJob(
            id: job.id,
            now: date("2026-07-19T10:00:00Z")
        )
        XCTAssertTrue(try database.finishScheduledJobRun(
            id: earlier.run.id,
            status: .succeeded,
            at: date("2026-07-19T10:05:00Z")
        ))

        let catchUp = try database.claimManualScheduledJob(
            id: job.id,
            now: date("2026-07-20T10:00:00Z")
        )
        try database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE scheduledJobRun SET trigger = 'catchUp', scheduledFor = ? WHERE id = ?",
                arguments: [date("2026-07-01T08:00:00Z"), catchUp.run.id]
            )
        }
        XCTAssertTrue(try database.markScheduledJobRunStarted(
            id: catchUp.run.id,
            at: date("2026-07-20T10:00:00Z")
        ))
        XCTAssertTrue(try database.finishScheduledJobRun(
            id: catchUp.run.id,
            status: .succeeded,
            at: date("2026-07-20T10:05:00Z")
        ))

        XCTAssertEqual(
            try database.fetchRecentScheduledJobRuns(limit: 1).first?.id,
            catchUp.run.id
        )
        XCTAssertEqual(
            try database.fetchScheduledJobRuns(jobId: job.id, limit: 1).first?.id,
            catchUp.run.id
        )
    }

    func testUnknownPersistedEnumsDecodeWithoutFailure() throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let job = try database.createScheduledJob(
            definition(name: "Forward compatible"),
            now: date("2026-07-13T07:00:00Z"),
            calendar: calendar
        )
        let claim = try database.claimManualScheduledJob(id: job.id)
        try database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE scheduledJobRun SET trigger='futureTrigger', status='futureStatus' WHERE id=?",
                arguments: [claim.run.id]
            )
        }

        let run = try XCTUnwrap(database.fetchScheduledJobRun(id: claim.run.id))
        XCTAssertEqual(run.trigger, .unknown("futureTrigger"))
        XCTAssertEqual(run.status, .unknown("futureStatus"))
        XCTAssertTrue(run.status.isActive)
        XCTAssertFalse(run.status.isTerminal)
        XCTAssertNil(try database.claimNextDueScheduledJob(
            now: date("2026-07-13T08:01:00Z"),
            calendar: calendar
        ))
        XCTAssertThrowsError(try database.claimManualScheduledJob(id: job.id)) { error in
            XCTAssertEqual(error as? ScheduledJobError, .runnerBusy)
        }
        XCTAssertThrowsError(try database.deleteScheduledJob(id: job.id)) { error in
            XCTAssertEqual(error as? ScheduledJobError, .activeRunPreventsDeletion)
        }
    }

    func testIndependentWritersSerializeConcurrentClaims() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-scheduled-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let path = directory.appendingPathComponent("library.sqlite").path
        let firstDatabase = try AppDatabase(DatabasePool(path: path, configuration: configuration))
        let secondDatabase = try AppDatabase(DatabasePool(path: path, configuration: configuration))
        _ = try firstDatabase.createScheduledJob(
            definition(name: "Concurrent"),
            now: date("2026-07-13T07:00:00Z"),
            calendar: utcCalendar()
        )
        let due = date("2026-07-13T08:01:00Z")
        let calendar = utcCalendar()

        let claims = try await withThrowingTaskGroup(
            of: ScheduledJobExecutionClaim?.self,
            returning: [ScheduledJobExecutionClaim?].self
        ) { group in
            group.addTask {
                try firstDatabase.claimNextDueScheduledJob(now: due, calendar: calendar)
            }
            group.addTask {
                try secondDatabase.claimNextDueScheduledJob(now: due, calendar: calendar)
            }
            var results: [ScheduledJobExecutionClaim?] = []
            for try await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(claims.compactMap { $0 }.count, 1)
        let persistedCount = try await firstDatabase.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledJobRun") ?? 0
        }
        XCTAssertEqual(persistedCount, 1)
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

    private func losAngelesCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
