import XCTest
import GRDB
@testable import RubienCore

final class ReadingActivityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func makeReference(
        in database: AppDatabase,
        title: String,
        author: String,
        year: Int
    ) throws -> Reference {
        var reference = Reference(
            title: title,
            authors: [AuthorName.parse(author)],
            year: year,
            journal: "Test Journal"
        )
        try database.saveReference(&reference)
        return reference
    }

    private func assertStatisticsScale(
        paperCount: Int,
        expectedRowCount: Int,
        maximumQuerySeconds: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let database = try AppDatabase(DatabaseQueue())
        let context = try database.activityCaptureContext(for: .reading)
        let startDate = try date("2026-01-01T12:00:00Z")
        let dayCount = 100
        let installationCount = 5
        let secondsPerComponent: Int64 = 12
        XCTAssertEqual(paperCount * dayCount * installationCount, expectedRowCount)

        var referenceIds: [Int64] = []
        for index in 0 ..< paperCount {
            let reference = try makeReference(
                in: database,
                title: "Scale Paper \(index)",
                author: "Reader \(index)",
                year: 2026
            )
            referenceIds.append(try XCTUnwrap(reference.id))
        }

        try database.dbWriter.write { db in
            // This fixture measures the statistics read path, not dirty-queue
            // trigger throughput. Avoid materializing another 50k syncState
            // rows while preserving the production table and indexes queried
            // below.
            for suffix in ["ai", "au", "ad"] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS readingActivity_\(suffix)")
            }
            let insert = try db.makeStatement(sql: """
                INSERT INTO readingActivity
                    (installationId, referenceId, localDay, epochRevision, generation,
                     activeSeconds, lastActiveAt, dateModified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for dayOffset in 0 ..< dayCount {
                let activeAt = try XCTUnwrap(
                    calendar.date(byAdding: .day, value: dayOffset, to: startDate)
                )
                let localDay = LocalDay(date: activeAt, calendar: calendar)
                for referenceId in referenceIds {
                    for installation in 0 ..< installationCount {
                        try insert.execute(arguments: [
                            "scale-\(installation)", referenceId, localDay,
                            context.revision, context.generation, secondsPerComponent,
                            activeAt, activeAt,
                        ])
                    }
                }
            }
        }

        let retainedRows = try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM readingActivity") ?? 0
        }
        XCTAssertEqual(retainedRows, expectedRowCount, file: file, line: line)

        let asOf = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: dayCount - 1,
            to: startDate
        ))
        let started = ProcessInfo.processInfo.systemUptime
        let statistics = try database.fetchReadingActivityStatistics(
            year: 2026,
            asOf: asOf,
            calendar: calendar
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(
            elapsed,
            maximumQuerySeconds,
            "statistics over \(expectedRowCount) rows took \(elapsed)s",
            file: file,
            line: line
        )
        XCTAssertEqual(statistics.trackedTotals.papersRead, paperCount, file: file, line: line)
        XCTAssertEqual(
            statistics.trackedTotals.estimatedActiveSeconds,
            Int64(expectedRowCount) * secondsPerComponent,
            file: file,
            line: line
        )
        XCTAssertEqual(statistics.yearActivity.dailyActivity.count, dayCount, file: file, line: line)
        XCTAssertTrue(
            statistics.yearActivity.dailyActivity.allSatisfy {
                $0.paperCount == paperCount
                    && $0.estimatedActiveSeconds
                        == Int64(paperCount * installationCount) * secondsPerComponent
            },
            file: file,
            line: line
        )
        XCTAssertEqual(statistics.streaks.currentDays, dayCount, file: file, line: line)
        XCTAssertEqual(statistics.streaks.longestDays, dayCount, file: file, line: line)
        XCTAssertEqual(statistics.recentPapers.count, min(5, paperCount), file: file, line: line)
    }

    @discardableResult
    private func save(
        _ seconds: Int64,
        installation: String,
        referenceId: Int64,
        day: String,
        at: String,
        database: AppDatabase,
        context: ActivityCaptureContext
    ) throws -> ActivityWriteDisposition<ReadingActivity> {
        try database.saveReadingActivityCounter(
            installationId: installation,
            referenceId: referenceId,
            localDay: try XCTUnwrap(LocalDay(rawValue: day)),
            cumulativeActiveSeconds: seconds,
            lastActiveAt: try date(at),
            context: context,
            now: try date(at)
        )
    }

    func testSnapshotAppliesThresholdPerPaperDayBeforeAggregating() throws {
        let database = try AppDatabase(DatabaseQueue())
        let paperA = try makeReference(in: database, title: "Paper A", author: "Ada Author", year: 2026)
        let paperB = try makeReference(in: database, title: "Paper B", author: "Ben Writer", year: 2025)
        let paperAId = try XCTUnwrap(paperA.id)
        let paperBId = try XCTUnwrap(paperB.id)
        let readingContext = try database.activityCaptureContext(for: .reading)

        // Components for a paper/day sum before the 60-second qualification.
        try save(30, installation: "mac-a", referenceId: paperAId, day: "2026-07-14",
                 at: "2026-07-14T10:00:00Z", database: database, context: readingContext)
        try save(31, installation: "mac-b", referenceId: paperAId, day: "2026-07-14",
                 at: "2026-07-14T10:01:00Z", database: database, context: readingContext)
        try save(59, installation: "mac-a", referenceId: paperBId, day: "2026-07-14",
                 at: "2026-07-14T11:00:00Z", database: database, context: readingContext)
        try save(60, installation: "mac-a", referenceId: paperAId, day: "2026-07-15",
                 at: "2026-07-15T09:00:00Z", database: database, context: readingContext)
        try save(900, installation: "mac-a", referenceId: paperBId, day: "2026-07-15",
                 at: "2026-07-15T12:00:00Z", database: database, context: readingContext)

        let assistantContext = try database.activityCaptureContext(for: .assistant)
        let assistantStarted = try date("2026-07-15T13:00:00Z")
        let assistantDay = try XCTUnwrap(LocalDay(rawValue: "2026-07-15"))
        let first = try database.recordAssistantActivity(
            conversationId: "conversation-1",
            provider: "codex",
            startedAt: assistantStarted,
            localDay: assistantDay,
            context: assistantContext,
            now: assistantStarted
        )
        let duplicate = try database.recordAssistantActivity(
            conversationId: "conversation-1",
            provider: "codex",
            startedAt: assistantStarted,
            localDay: assistantDay,
            context: assistantContext,
            now: assistantStarted
        )
        if case .saved(let inserted) = first { XCTAssertTrue(inserted) } else { XCTFail("fresh epoch rejected") }
        if case .saved(let inserted) = duplicate { XCTAssertFalse(inserted) } else { XCTFail("fresh epoch rejected") }

        let snapshot = try database.fetchReadingActivitySnapshot(
            dailyActivityStartDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-01")),
            dailyActivityEndDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-31")),
            asOf: try date("2026-07-15T18:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.papersReadTracked, 2)
        XCTAssertEqual(snapshot.estimatedActiveSecondsTracked, 1_021)
        XCTAssertEqual(snapshot.papersReadThisWeek, 2)
        XCTAssertEqual(snapshot.estimatedActiveSecondsThisWeek, 1_021)
        XCTAssertEqual(snapshot.assistantSessionsTracked, 1)
        XCTAssertEqual(snapshot.currentStreakDays, 2)
        XCTAssertEqual(snapshot.longestStreakDays, 2)
        XCTAssertEqual(snapshot.dailyActivity, [
            DailyReadingActivity(
                localDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-14")),
                paperCount: 1,
                estimatedActiveSeconds: 61
            ),
            DailyReadingActivity(
                localDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-15")),
                paperCount: 2,
                estimatedActiveSeconds: 960
            ),
        ])
        XCTAssertEqual(snapshot.recentPapers.map(\.referenceId), [paperBId, paperAId])
        XCTAssertEqual(snapshot.recentPapers.first?.byline, "Ben Writer")
    }

    func testRecentPapersUseRollingTwentyFourHoursAndNewestFirst() throws {
        let database = try AppDatabase(DatabaseQueue())
        let newest = try makeReference(
            in: database, title: "Newest", author: "N Reader", year: 2026)
        let earlier = try makeReference(
            in: database, title: "Earlier", author: "E Reader", year: 2026)
        let expired = try makeReference(
            in: database, title: "Expired", author: "X Reader", year: 2026)
        let newestId = try XCTUnwrap(newest.id)
        let earlierId = try XCTUnwrap(earlier.id)
        let expiredId = try XCTUnwrap(expired.id)
        let context = try database.activityCaptureContext(for: .reading)

        try save(60, installation: "mac", referenceId: expiredId, day: "2026-07-14",
                 at: "2026-07-14T10:00:00Z", database: database, context: context)
        try save(60, installation: "mac", referenceId: earlierId, day: "2026-07-15",
                 at: "2026-07-15T09:00:00Z", database: database, context: context)
        try save(60, installation: "mac", referenceId: newestId, day: "2026-07-15",
                 at: "2026-07-15T11:30:00Z", database: database, context: context)

        let snapshot = try database.fetchReadingActivitySnapshot(
            dailyActivityStartDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-01")),
            dailyActivityEndDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-31")),
            asOf: try date("2026-07-15T12:00:00Z"),
            calendar: calendar)

        XCTAssertEqual(snapshot.recentPapers.map(\.referenceId), [newestId, earlierId])
        XCTAssertFalse(snapshot.recentPapers.contains { $0.referenceId == expiredId })
    }

    func testCurrentStreakAllowsTodayToBeInProgressAndIgnoresFutureDays() throws {
        let database = try AppDatabase(DatabaseQueue())
        let paper = try makeReference(in: database, title: "Streak", author: "A Reader", year: 2026)
        let id = try XCTUnwrap(paper.id)
        let context = try database.activityCaptureContext(for: .reading)
        try save(60, installation: "mac", referenceId: id, day: "2026-07-12",
                 at: "2026-07-12T10:00:00Z", database: database, context: context)
        try save(60, installation: "mac", referenceId: id, day: "2026-07-13",
                 at: "2026-07-13T10:00:00Z", database: database, context: context)
        try save(60, installation: "mac", referenceId: id, day: "2026-07-14",
                 at: "2026-07-14T10:00:00Z", database: database, context: context)
        try save(60, installation: "mac", referenceId: id, day: "2026-08-01",
                 at: "2026-08-01T10:00:00Z", database: database, context: context)

        let statistics = try database.fetchReadingActivityStatistics(
            year: 2026,
            asOf: try date("2026-07-15T08:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(statistics.streaks.currentDays, 3)
        XCTAssertEqual(statistics.streaks.longestDays, 3)
        XCTAssertEqual(statistics.currentWeek.startDay.rawValue, "2026-07-13")
        XCTAssertEqual(statistics.yearActivity.dailyActivity.last?.localDay.rawValue, "2026-08-01")
    }

    func testClearCreatesIndependentEpochAndRejectsStaleWrites() throws {
        let database = try AppDatabase(DatabaseQueue())
        let paper = try makeReference(in: database, title: "Clear", author: "A Reader", year: 2026)
        let id = try XCTUnwrap(paper.id)
        let oldContext = try database.activityCaptureContext(for: .reading)
        try save(120, installation: "mac", referenceId: id, day: "2026-07-15",
                 at: "2026-07-15T10:00:00Z", database: database, context: oldContext)

        let resetAt = try date("2026-07-15T11:00:00Z")
        let newEpoch = try database.clearActivity(kind: .reading, now: resetAt)
        XCTAssertEqual(newEpoch.revision, oldContext.revision + 1)
        XCTAssertNotEqual(newEpoch.generation, oldContext.generation)

        let stale = try save(180, installation: "mac", referenceId: id, day: "2026-07-15",
                             at: "2026-07-15T12:00:00Z", database: database, context: oldContext)
        if case .staleEpoch = stale {} else { XCTFail("pre-clear accumulator was admitted") }

        let snapshot = try database.fetchReadingActivitySnapshot(
            dailyActivityStartDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-01")),
            dailyActivityEndDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-31")),
            asOf: try date("2026-07-15T18:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(snapshot.papersReadTracked, 0)
        XCTAssertEqual(snapshot.estimatedActiveSecondsTracked, 0)
        XCTAssertEqual(snapshot.coverage.readingResetAt, resetAt)
        XCTAssertNil(snapshot.coverage.assistantResetAt)
    }

    func testLocalDayValidationRejectsImpossibleAndNonCanonicalDates() {
        XCTAssertNotNil(LocalDay(rawValue: "2024-02-29"))
        XCTAssertNil(LocalDay(rawValue: "2023-02-29"))
        XCTAssertNil(LocalDay(rawValue: "2026-7-15"))
        XCTAssertNil(LocalDay(rawValue: "2026-13-01"))
    }

    func testStatisticsQueryIsCorrectAtTenThousandReadingRows() throws {
        try assertStatisticsScale(
            paperCount: 20,
            expectedRowCount: 10_000,
            maximumQuerySeconds: 5
        )
    }

    func testStatisticsQueryIsCorrectAtFiftyThousandReadingRows() throws {
        try assertStatisticsScale(
            paperCount: 100,
            expectedRowCount: 50_000,
            maximumQuerySeconds: 10
        )
    }
}
