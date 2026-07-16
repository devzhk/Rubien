import Foundation
import GRDB

extension AppDatabase {
    /// Update this constant in the release that first ships activity capture.
    public static let activityTrackingIntroducedInVersion = "0.3.7"

    /// Gregorian calendar with the caller's locale/time-zone/week rules.
    public static func activityCalendar(basedOn source: Calendar = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = source.locale
        calendar.timeZone = source.timeZone
        calendar.firstWeekday = source.firstWeekday
        calendar.minimumDaysInFirstWeek = source.minimumDaysInFirstWeek
        return calendar
    }

    public func activityCaptureContext(for kind: ActivityKind) throws -> ActivityCaptureContext {
        try dbWriter.read { db in
            try Self.activityCaptureContext(for: kind, in: db)
        }
    }

    private static func activityCaptureContext(
        for kind: ActivityKind,
        in db: Database
    ) throws -> ActivityCaptureContext {
        guard let epoch = try ActivityEpoch.fetchOne(db, key: kind.rawValue) else {
            throw DatabaseError(
                resultCode: .SQLITE_CORRUPT,
                message: "Missing \(kind.rawValue) activity epoch"
            )
        }
        let pending = try ActivityPendingClear.fetchOne(db, key: kind.rawValue)
        return ActivityCaptureContext(
            kind: kind,
            revision: epoch.revision,
            generation: epoch.generation,
            pendingClearIntentId: pending?.intentId
        )
    }

    /// Fetch the persisted cumulative baseline for a reader accumulator.
    public func readingActivityComponent(
        installationId: String,
        referenceId: Int64,
        localDay: LocalDay,
        context: ActivityCaptureContext
    ) throws -> ReadingActivity? {
        guard context.kind == .reading else { return nil }
        return try dbWriter.read { db in
            try ReadingActivity.fetchOne(
                db,
                sql: """
                    SELECT * FROM readingActivity
                    WHERE generation = ?
                      AND installationId = ?
                      AND referenceId = ?
                      AND localDay = ?
                    """,
                arguments: [context.generation, installationId, referenceId, localDay]
            )
        }
    }

    /// Monotonically persist one reader accumulator. Delayed writes from an
    /// unrelated pre-clear epoch are rejected inside the write transaction.
    public func saveReadingActivityCounter(
        installationId: String,
        referenceId: Int64,
        localDay: LocalDay,
        cumulativeActiveSeconds: Int64,
        lastActiveAt: Date,
        context suppliedContext: ActivityCaptureContext,
        now: Date = Date()
    ) throws -> ActivityWriteDisposition<ReadingActivity> {
        precondition(cumulativeActiveSeconds >= 0)
        precondition(!installationId.contains("/"))
        guard suppliedContext.kind == .reading else { return .staleEpoch }

        return try dbWriter.write { db in
            let current = try Self.activityCaptureContext(for: .reading, in: db)
            guard let acceptedContext = Self.acceptedContext(
                supplied: suppliedContext,
                current: current
            ) else { return .staleEpoch }

            try db.execute(
                sql: """
                    INSERT INTO readingActivity
                        (installationId, referenceId, localDay, epochRevision, generation,
                         activeSeconds, lastActiveAt, dateModified)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(generation, installationId, referenceId, localDay)
                    DO UPDATE SET
                        epochRevision = MAX(readingActivity.epochRevision, excluded.epochRevision),
                        activeSeconds = MAX(readingActivity.activeSeconds, excluded.activeSeconds),
                        lastActiveAt = MAX(readingActivity.lastActiveAt, excluded.lastActiveAt),
                        dateModified = excluded.dateModified
                    """,
                arguments: [
                    installationId,
                    referenceId,
                    localDay,
                    acceptedContext.revision,
                    acceptedContext.generation,
                    cumulativeActiveSeconds,
                    lastActiveAt,
                    now,
                ]
            )

            let saved = try ReadingActivity.fetchOne(
                db,
                sql: """
                    SELECT * FROM readingActivity
                    WHERE generation = ? AND installationId = ?
                      AND referenceId = ? AND localDay = ?
                    """,
                arguments: [acceptedContext.generation, installationId, referenceId, localDay]
            )!
            return .saved(saved)
        }
    }

    /// Insert a successfully started fresh Rubien conversation exactly once.
    @discardableResult
    public func recordAssistantActivity(
        conversationId: String,
        provider: String,
        startedAt: Date,
        localDay: LocalDay,
        context suppliedContext: ActivityCaptureContext,
        now: Date = Date()
    ) throws -> ActivityWriteDisposition<Bool> {
        guard suppliedContext.kind == .assistant else { return .staleEpoch }

        return try dbWriter.write { db in
            let current = try Self.activityCaptureContext(for: .assistant, in: db)
            guard let acceptedContext = Self.acceptedContext(
                supplied: suppliedContext,
                current: current
            ) else { return .staleEpoch }

            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO assistantActivity
                        (id, provider, epochRevision, generation, startedAt, localDay, dateModified)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    conversationId,
                    provider,
                    acceptedContext.revision,
                    acceptedContext.generation,
                    startedAt,
                    localDay,
                    now,
                ]
            )
            return .saved(db.changesCount > 0)
        }
    }

    /// Start a new visible/synced generation and remove the selected kind's
    /// retained facts. The returned epoch is immediately authoritative locally;
    /// CloudKit acknowledgement is asynchronous.
    @discardableResult
    public func clearActivity(kind: ActivityKind, now: Date = Date()) throws -> ActivityEpoch {
        try dbWriter.write { db in
            guard let current = try ActivityEpoch.fetchOne(db, key: kind.rawValue) else {
                throw DatabaseError(
                    resultCode: .SQLITE_CORRUPT,
                    message: "Missing \(kind.rawValue) activity epoch"
                )
            }

            let generation = UUID().uuidString.lowercased()
            let intentId = UUID().uuidString.lowercased()
            let next = ActivityEpoch(
                kind: kind,
                revision: current.revision + 1,
                generation: generation,
                resetAt: now,
                dateModified: now
            )
            var pending = ActivityPendingClear(
                kind: kind,
                intentId: intentId,
                revision: next.revision,
                generation: next.generation,
                resetAt: now,
                dateModified: now
            )
            try pending.save(db)

            switch kind {
            case .reading:
                try db.execute(sql: "DELETE FROM readingActivity")
            case .assistant:
                try db.execute(sql: "DELETE FROM assistantActivity")
            }

            try next.update(db)
            return next
        }
    }

    /// Called by sync only after CloudKit saves this exact epoch pair.
    public func acknowledgeActivityEpoch(
        kind: ActivityKind,
        revision: Int,
        generation: String
    ) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    DELETE FROM activityPendingClear
                    WHERE kind = ? AND revision = ? AND generation = ?
                    """,
                arguments: [kind.rawValue, revision, generation]
            )
        }
    }

    private static func acceptedContext(
        supplied: ActivityCaptureContext,
        current: ActivityCaptureContext
    ) -> ActivityCaptureContext? {
        if supplied.revision == current.revision,
           supplied.generation == current.generation
        {
            return current
        }
        if let intentId = supplied.pendingClearIntentId,
           intentId == current.pendingClearIntentId
        {
            return current
        }
        return nil
    }

    public func fetchReadingActivitySnapshot(
        dailyActivityStartDay: LocalDay,
        dailyActivityEndDay: LocalDay,
        asOf date: Date = Date(),
        calendar sourceCalendar: Calendar = .current
    ) throws -> ReadingActivitySnapshot {
        precondition(dailyActivityStartDay <= dailyActivityEndDay)
        let calendar = Self.activityCalendar(basedOn: sourceCalendar)
        let asOfDay = LocalDay(date: date, calendar: calendar)
        let weekStartDay = Self.weekStart(containing: date, calendar: calendar)

        return try dbWriter.read { db in
            let readingEpoch = try Self.requiredEpoch(.reading, in: db)
            let assistantEpoch = try Self.requiredEpoch(.assistant, in: db)
            let epochArguments: StatementArguments = [
                readingEpoch.generation,
                readingEpoch.revision,
            ]

            let totalRow = try Row.fetchOne(
                db,
                sql: Self.qualifiedReadingCTE + """
                    SELECT COUNT(DISTINCT referenceId) AS paperCount,
                           COALESCE(SUM(estimatedActiveSeconds), 0) AS activeSeconds
                    FROM qualified
                    """,
                arguments: epochArguments
            )!

            let weekRow = try Row.fetchOne(
                db,
                sql: Self.qualifiedReadingCTE + """
                    SELECT COUNT(DISTINCT referenceId) AS paperCount,
                           COALESCE(SUM(estimatedActiveSeconds), 0) AS activeSeconds
                    FROM qualified
                    WHERE localDay BETWEEN ? AND ?
                    """,
                arguments: epochArguments + [weekStartDay, asOfDay]
            )!

            let dailyRows = try Row.fetchAll(
                db,
                sql: Self.qualifiedReadingCTE + """
                    SELECT localDay,
                           COUNT(DISTINCT referenceId) AS paperCount,
                           SUM(estimatedActiveSeconds) AS activeSeconds
                    FROM qualified
                    WHERE localDay BETWEEN ? AND ?
                    GROUP BY localDay
                    ORDER BY localDay
                    """,
                arguments: epochArguments + [dailyActivityStartDay, dailyActivityEndDay]
            )
            let dailyActivity = dailyRows.map {
                DailyReadingActivity(
                    localDay: $0["localDay"],
                    paperCount: $0["paperCount"],
                    estimatedActiveSeconds: $0["activeSeconds"]
                )
            }

            let yesterday = asOfDay.addingDays(-1, calendar: calendar) ?? asOfDay
            let streakRow = try Row.fetchOne(
                db,
                sql: Self.qualifiedReadingCTE + """
                    , days AS (
                        SELECT DISTINCT localDay
                        FROM qualified
                        WHERE localDay <= ?
                    ), numbered AS (
                        SELECT localDay,
                               CAST(julianday(localDay) AS INTEGER)
                                   - ROW_NUMBER() OVER (ORDER BY localDay) AS island
                        FROM days
                    ), runs AS (
                        SELECT MAX(localDay) AS endDay, COUNT(*) AS runLength
                        FROM numbered
                        GROUP BY island
                    )
                    SELECT COALESCE(MAX(runLength), 0) AS longest,
                           COALESCE(MAX(
                               CASE WHEN endDay = ? OR endDay = ? THEN runLength ELSE 0 END
                           ), 0) AS currentDays
                    FROM runs
                    """,
                arguments: epochArguments + [asOfDay, asOfDay, yesterday]
            )!

            let recentRows = try Row.fetchAll(
                db,
                sql: Self.qualifiedReadingCTE + """
                    , recent AS (
                        SELECT referenceId, MAX(lastActiveAt) AS lastActiveAt
                        FROM qualified
                        WHERE localDay <= ?
                        GROUP BY referenceId
                        HAVING MAX(lastActiveAt) >= ? AND MAX(lastActiveAt) <= ?
                    )
                    SELECT reference.id AS referenceId,
                           reference.title AS title,
                           reference.authors AS authors,
                           reference.journal AS journal,
                           reference.siteName AS siteName,
                           reference.publisher AS publisher,
                           recent.lastActiveAt AS lastActiveAt
                    FROM recent
                    JOIN reference ON reference.id = recent.referenceId
                    ORDER BY recent.lastActiveAt DESC, reference.id DESC
                    LIMIT 5
                    """,
                arguments: epochArguments + [
                    asOfDay,
                    date.addingTimeInterval(-24 * 60 * 60),
                    date,
                ]
            )
            let recentPapers = recentRows.map(Self.recentReading(from:))

            let assistantSessions = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM assistantActivity
                    WHERE generation = ? AND epochRevision = ?
                    """,
                arguments: [assistantEpoch.generation, assistantEpoch.revision]
            ) ?? 0

            return ReadingActivitySnapshot(
                asOfLocalDay: asOfDay,
                dailyActivityStartDay: dailyActivityStartDay,
                dailyActivityEndDay: dailyActivityEndDay,
                papersReadTracked: totalRow["paperCount"],
                estimatedActiveSecondsTracked: totalRow["activeSeconds"],
                papersReadThisWeek: weekRow["paperCount"],
                estimatedActiveSecondsThisWeek: weekRow["activeSeconds"],
                assistantSessionsTracked: assistantSessions,
                currentStreakDays: streakRow["currentDays"],
                longestStreakDays: streakRow["longest"],
                dailyActivity: dailyActivity,
                recentPapers: recentPapers,
                coverage: ActivityCoverage(
                    trackingIntroducedInVersion: Self.activityTrackingIntroducedInVersion,
                    readingResetAt: readingEpoch.resetAt,
                    assistantResetAt: assistantEpoch.resetAt
                )
            )
        }
    }

    public func fetchReadingActivityStatistics(
        year: Int? = nil,
        asOf date: Date = Date(),
        calendar sourceCalendar: Calendar = .current
    ) throws -> ReadingActivityStatistics {
        let calendar = Self.activityCalendar(basedOn: sourceCalendar)
        let asOfDay = LocalDay(date: date, calendar: calendar)
        let selectedYear = year ?? Self.year(of: asOfDay)
        precondition((1970 ... 9999).contains(selectedYear))
        let start = LocalDay(rawValue: String(format: "%04d-01-01", selectedYear))!
        let end = LocalDay(rawValue: String(format: "%04d-12-31", selectedYear))!
        let snapshot = try fetchReadingActivitySnapshot(
            dailyActivityStartDay: start,
            dailyActivityEndDay: end,
            asOf: date,
            calendar: calendar
        )
        let weekStart = Self.weekStart(containing: date, calendar: calendar)
        return ReadingActivityStatistics(
            asOfLocalDay: snapshot.asOfLocalDay,
            trackedTotals: .init(
                papersRead: snapshot.papersReadTracked,
                estimatedActiveSeconds: snapshot.estimatedActiveSecondsTracked,
                assistantSessions: snapshot.assistantSessionsTracked
            ),
            currentWeek: .init(
                startDay: weekStart,
                throughDay: snapshot.asOfLocalDay,
                papersRead: snapshot.papersReadThisWeek,
                estimatedActiveSeconds: snapshot.estimatedActiveSecondsThisWeek
            ),
            streaks: .init(
                currentDays: snapshot.currentStreakDays,
                longestDays: snapshot.longestStreakDays
            ),
            yearActivity: .init(year: selectedYear, dailyActivity: snapshot.dailyActivity),
            recentPapers: snapshot.recentPapers,
            coverage: snapshot.coverage
        )
    }

    private static let qualifiedReadingCTE = """
        WITH qualified AS (
            SELECT readingActivity.referenceId AS referenceId,
                   readingActivity.localDay AS localDay,
                   SUM(readingActivity.activeSeconds) AS estimatedActiveSeconds,
                   MAX(readingActivity.lastActiveAt) AS lastActiveAt
            FROM readingActivity
            JOIN reference ON reference.id = readingActivity.referenceId
            WHERE readingActivity.generation = ?
              AND readingActivity.epochRevision = ?
            GROUP BY readingActivity.referenceId, readingActivity.localDay
            HAVING SUM(readingActivity.activeSeconds) >= 60
        )
        """

    private static func requiredEpoch(_ kind: ActivityKind, in db: Database) throws -> ActivityEpoch {
        guard let epoch = try ActivityEpoch.fetchOne(db, key: kind.rawValue) else {
            throw DatabaseError(
                resultCode: .SQLITE_CORRUPT,
                message: "Missing \(kind.rawValue) activity epoch"
            )
        }
        return epoch
    }

    private static func weekStart(containing date: Date, calendar: Calendar) -> LocalDay {
        if let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
            return LocalDay(date: interval.start, calendar: calendar)
        }
        return LocalDay(date: date, calendar: calendar)
    }

    private static func year(of day: LocalDay) -> Int {
        Int(day.rawValue.prefix(4))!
    }

    private static func recentReading(from row: Row) -> RecentReading {
        let rawAuthors: String = row["authors"]
        let authors: [AuthorName]
        if let data = rawAuthors.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AuthorName].self, from: data)
        {
            authors = decoded
        } else {
            authors = AuthorName.parseList(rawAuthors)
        }
        let byline = authors.displayString.rubien_nilIfBlank
        let journal: String? = row["journal"]
        let siteName: String? = row["siteName"]
        let publisher: String? = row["publisher"]
        return RecentReading(
            referenceId: row["referenceId"],
            title: row["title"],
            byline: byline,
            venue: journal?.rubien_nilIfBlank ?? siteName?.rubien_nilIfBlank ?? publisher?.rubien_nilIfBlank,
            lastActiveAt: row["lastActiveAt"]
        )
    }
}
