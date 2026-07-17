import Foundation
import GRDB

extension AppDatabase {
    @discardableResult
    public func createScheduledJob(
        _ proposedDefinition: ScheduledJobDefinition,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ScheduledJob {
        let definition = try normalizedScheduledJobDefinition(proposedDefinition)
        let nextRunAt = definition.isEnabled
            ? definition.recurrence.nextOccurrence(after: now, calendar: calendar)
            : nil
        guard !definition.isEnabled || nextRunAt != nil else {
            throw ScheduledJobError.invalidRecurrence
        }

        var job = ScheduledJob(
            id: UUID().uuidString.lowercased(),
            definition: definition,
            nextRunAt: nextRunAt,
            createdAt: now,
            dateModified: now
        )
        try dbWriter.write { db in
            try job.insert(db)
        }
        return job
    }

    @discardableResult
    public func updateScheduledJob(
        id: String,
        definition proposedDefinition: ScheduledJobDefinition,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ScheduledJob {
        let definition = try normalizedScheduledJobDefinition(proposedDefinition)
        let nextRunAt = definition.isEnabled
            ? definition.recurrence.nextOccurrence(after: now, calendar: calendar)
            : nil
        guard !definition.isEnabled || nextRunAt != nil else {
            throw ScheduledJobError.invalidRecurrence
        }

        return try dbWriter.write { db in
            guard let existing = try ScheduledJob.fetchOne(db, key: id) else {
                throw ScheduledJobError.notFound
            }
            let job = ScheduledJob(
                id: id,
                definition: definition,
                nextRunAt: nextRunAt,
                createdAt: existing.createdAt,
                dateModified: now
            )
            try job.update(db)
            return job
        }
    }

    @discardableResult
    public func setScheduledJobEnabled(
        id: String,
        isEnabled: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ScheduledJob {
        try dbWriter.write { db in
            guard var job = try ScheduledJob.fetchOne(db, key: id) else {
                throw ScheduledJobError.notFound
            }
            job.isEnabled = isEnabled
            job.nextRunAt = isEnabled
                ? job.recurrence.nextOccurrence(after: now, calendar: calendar)
                : nil
            job.dateModified = now
            try job.update(db)
            return job
        }
    }

    public func deleteScheduledJob(id: String) throws {
        try dbWriter.write { db in
            let activeCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM scheduledJobRun
                    WHERE jobId = ? AND status IN ('pending', 'running')
                    """,
                arguments: [id]
            ) ?? 0
            guard activeCount == 0 else {
                throw ScheduledJobError.activeRunPreventsDeletion
            }
            guard try ScheduledJob.deleteOne(db, key: id) else {
                throw ScheduledJobError.notFound
            }
        }
    }

    public func fetchScheduledJob(id: String) throws -> ScheduledJob? {
        try dbWriter.read { db in
            try ScheduledJob.fetchOne(db, key: id)
        }
    }

    public func fetchScheduledJobs() throws -> [ScheduledJob] {
        try dbWriter.read { db in
            try Self.fetchScheduledJobs(in: db)
        }
    }

    public func fetchUpcomingScheduledJobs(limit: Int = 3) throws -> [ScheduledJob] {
        guard limit > 0 else { return [] }
        return try dbWriter.read { db in
            try Self.fetchUpcomingScheduledJobs(in: db, limit: limit)
        }
    }

    public func fetchScheduledJobRun(id: String) throws -> ScheduledJobRun? {
        try dbWriter.read { db in
            try ScheduledJobRun.fetchOne(db, key: id)
        }
    }

    public func fetchRecentScheduledJobRuns(limit: Int = 50) throws -> [ScheduledJobRun] {
        guard limit > 0 else { return [] }
        return try dbWriter.read { db in
            try Self.fetchRecentScheduledJobRuns(in: db, limit: limit)
        }
    }

    public func fetchScheduledJobRuns(jobId: String, limit: Int = 50) throws -> [ScheduledJobRun] {
        guard limit > 0 else { return [] }
        return try dbWriter.read { db in
            try ScheduledJobRun.fetchAll(
                db,
                sql: """
                    SELECT * FROM scheduledJobRun
                    WHERE jobId = ?
                    ORDER BY scheduledFor DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [jobId, limit]
            )
        }
    }

    public func unreadScheduledJobRunCount() throws -> Int {
        try dbWriter.read { db in
            try Self.unreadScheduledJobRunCount(in: db)
        }
    }

    public func fetchScheduledJobDashboard(
        upcomingLimit: Int = 3,
        recentRunLimit: Int = 50
    ) throws -> ScheduledJobDashboardSnapshot {
        try dbWriter.read { db in
            ScheduledJobDashboardSnapshot(
                jobs: try Self.fetchScheduledJobs(in: db),
                upcomingJobs: try Self.fetchUpcomingScheduledJobs(
                    in: db,
                    limit: upcomingLimit
                ),
                recentRuns: try Self.fetchRecentScheduledJobRuns(
                    in: db,
                    limit: recentRunLimit
                ),
                unreadRunCount: try Self.unreadScheduledJobRunCount(in: db)
            )
        }
    }

    public func markScheduledJobRunRead(id: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE scheduledJobRun SET isUnread = 0 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func markAllScheduledJobRunsRead() throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE scheduledJobRun SET isUnread = 0 WHERE isUnread = 1")
        }
    }

    /// Rebuilds local wall-clock deadlines after a time-zone or system-clock
    /// change. An occurrence that became due in the new zone is retained as a
    /// catch-up candidate unless the job was created/edited after that time or
    /// that local-day occurrence already has a run row.
    public func recalculateScheduledJobNextRuns(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        try dbWriter.write { db in
            let jobs = try ScheduledJob
                .filter(ScheduledJob.Columns.isEnabled == true)
                .fetchAll(db)
            for job in jobs {
                let recurrence = job.recurrence
                let latest = recurrence.latestOccurrence(onOrBefore: now, calendar: calendar)
                // Preserve an overdue boundary only when the current local-time
                // schedule has genuinely reached (or passed) that boundary. After
                // westward travel, an old absolute deadline can be in the past while
                // today's new local occurrence is still hours away.
                if let current = job.nextRunAt,
                   current <= now,
                   let latest,
                   latest >= current {
                    continue
                }
                var nextRunAt = recurrence.nextOccurrence(after: now, calendar: calendar)
                if let latest, latest >= job.dateModified {
                    let key = LocalDay(date: latest, calendar: calendar).rawValue
                    let alreadyRan = try Bool.fetchOne(
                        db,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1 FROM scheduledJobRun
                                WHERE jobId = ? AND occurrenceKey = ?
                            )
                            """,
                        arguments: [job.id, key]
                    ) ?? false
                    if !alreadyRan { nextRunAt = latest }
                }
                try db.execute(
                    sql: "UPDATE scheduledJob SET nextRunAt = ? WHERE id = ?",
                    arguments: [nextRunAt, job.id]
                )
            }
        }
    }

    /// Claims at most one due occurrence. While a run is active, every other
    /// job stays unclaimed so its definition remains editable and a crash
    /// cannot strand a durable queue of stale snapshots.
    public func claimNextDueScheduledJob(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ScheduledJobExecutionClaim? {
        try dbWriter.write { db in
            guard try !Self.hasActiveScheduledRun(in: db) else { return nil }

            let dueJobs = try ScheduledJob.fetchAll(
                db,
                sql: """
                    SELECT * FROM scheduledJob
                    WHERE isEnabled = 1 AND nextRunAt IS NOT NULL AND nextRunAt <= ?
                    ORDER BY nextRunAt ASC, id ASC
                    """,
                arguments: [now]
            )
            for var job in dueJobs {
                guard let storedNextRunAt = job.nextRunAt else { continue }
                let latest = job.recurrence.latestOccurrence(onOrBefore: now, calendar: calendar)
                let scheduledFor: Date
                if let latest, latest >= storedNextRunAt {
                    scheduledFor = latest
                } else {
                    scheduledFor = storedNextRunAt
                }
                let occurrenceKey = LocalDay(date: scheduledFor, calendar: calendar).rawValue
                let alreadyClaimed = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM scheduledJobRun
                            WHERE jobId = ? AND occurrenceKey = ?
                        )
                        """,
                    arguments: [job.id, occurrenceKey]
                ) ?? false

                job.nextRunAt = job.recurrence.nextOccurrence(after: now, calendar: calendar)
                try db.execute(
                    sql: "UPDATE scheduledJob SET nextRunAt = ? WHERE id = ?",
                    arguments: [job.nextRunAt, job.id]
                )
                if alreadyClaimed { continue }

                let trigger: ScheduledJobRunTrigger =
                    scheduledFor.timeIntervalSince(storedNextRunAt) > 1 ? .catchUp : .scheduled
                var run = ScheduledJobRun(
                    id: UUID().uuidString.lowercased(),
                    jobId: job.id,
                    trigger: trigger,
                    occurrenceKey: occurrenceKey,
                    scheduledFor: scheduledFor,
                    startedAt: nil,
                    finishedAt: nil,
                    status: .pending,
                    provider: job.provider,
                    providerSessionId: nil,
                    failureKind: nil,
                    isUnread: false
                )
                try run.insert(db)
                return ScheduledJobExecutionClaim(job: job, run: run)
            }
            return nil
        }
    }

    public func claimManualScheduledJob(
        id: String,
        now: Date = Date()
    ) throws -> ScheduledJobExecutionClaim {
        try dbWriter.write { db in
            guard try !Self.hasActiveScheduledRun(in: db) else {
                throw ScheduledJobError.runnerBusy
            }
            guard let job = try ScheduledJob.fetchOne(db, key: id) else {
                throw ScheduledJobError.notFound
            }
            var run = ScheduledJobRun(
                id: UUID().uuidString.lowercased(),
                jobId: job.id,
                trigger: .manual,
                occurrenceKey: "manual/\(UUID().uuidString.lowercased())",
                scheduledFor: now,
                startedAt: nil,
                finishedAt: nil,
                status: .pending,
                provider: job.provider,
                providerSessionId: nil,
                failureKind: nil,
                isUnread: false
            )
            try run.insert(db)
            return ScheduledJobExecutionClaim(job: job, run: run)
        }
    }

    @discardableResult
    public func markScheduledJobRunStarted(id: String, at date: Date = Date()) throws -> Bool {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET status = 'running', startedAt = ?
                    WHERE id = ? AND status = 'pending'
                    """,
                arguments: [date, id]
            )
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func setScheduledJobRunProviderSessionID(id: String, sessionID: String) throws -> Bool {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun SET providerSessionId = ?
                    WHERE id = ? AND status IN ('pending', 'running')
                    """,
                arguments: [sessionID, id]
            )
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func finishScheduledJobRun(
        id: String,
        status: ScheduledJobRunStatus,
        failureKind: ScheduledJobFailureKind? = nil,
        at date: Date = Date()
    ) throws -> Bool {
        guard status.isTerminal else { return false }
        return try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET status = ?, failureKind = ?, finishedAt = ?, isUnread = 1
                    WHERE id = ? AND status IN ('pending', 'running')
                    """,
                arguments: [status.rawValue, failureKind?.rawValue, date, id]
            )
            return db.changesCount > 0
        }
    }

    /// App-launch crash recovery. A pending row never reached provider start;
    /// a running row did start but cannot be resumed automatically.
    @discardableResult
    public func recoverInterruptedScheduledJobRuns(at date: Date = Date()) throws -> Int {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET status = 'failed',
                        failureKind = CASE status
                            WHEN 'pending' THEN 'interruptedBeforeStart'
                            ELSE 'interrupted'
                        END,
                        finishedAt = ?,
                        isUnread = 1
                    WHERE status IN ('pending', 'running')
                    """,
                arguments: [date]
            )
            return db.changesCount
        }
    }

    private static func hasActiveScheduledRun(in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM scheduledJobRun
                    WHERE status IN ('pending', 'running')
                )
                """
        ) ?? false
    }

    private static func fetchScheduledJobs(in db: Database) throws -> [ScheduledJob] {
        try ScheduledJob.fetchAll(
            db,
            sql: """
                SELECT * FROM scheduledJob
                ORDER BY
                    CASE WHEN isEnabled = 1 THEN 0 ELSE 1 END,
                    CASE WHEN isEnabled = 1 THEN nextRunAt END ASC,
                    CASE WHEN isEnabled = 0 THEN name END COLLATE NOCASE ASC,
                    id ASC
                """
        )
    }

    private static func fetchUpcomingScheduledJobs(
        in db: Database,
        limit: Int
    ) throws -> [ScheduledJob] {
        guard limit > 0 else { return [] }
        return try ScheduledJob.fetchAll(
            db,
            sql: """
                SELECT * FROM scheduledJob
                WHERE isEnabled = 1 AND nextRunAt IS NOT NULL
                ORDER BY nextRunAt ASC, id ASC
                LIMIT ?
                """,
            arguments: [limit]
        )
    }

    private static func fetchRecentScheduledJobRuns(
        in db: Database,
        limit: Int
    ) throws -> [ScheduledJobRun] {
        guard limit > 0 else { return [] }
        return try ScheduledJobRun.fetchAll(
            db,
            sql: """
                SELECT * FROM scheduledJobRun
                ORDER BY scheduledFor DESC, id DESC
                LIMIT ?
                """,
            arguments: [limit]
        )
    }

    private static func unreadScheduledJobRunCount(in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM scheduledJobRun WHERE isUnread = 1"
        ) ?? 0
    }
}

private func normalizedScheduledJobDefinition(
    _ proposed: ScheduledJobDefinition
) throws -> ScheduledJobDefinition {
    var definition = proposed
    definition.name = proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)
    definition.prompt = proposed.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    definition.model = proposed.model?.trimmingCharacters(in: .whitespacesAndNewlines)
    definition.effort = proposed.effort?.trimmingCharacters(in: .whitespacesAndNewlines)
    if definition.model?.isEmpty == true { definition.model = nil }
    if definition.effort?.isEmpty == true { definition.effort = nil }

    guard (1 ... 200).contains(definition.name.count) else {
        throw ScheduledJobError.invalidName
    }
    guard (1 ... 20_000).contains(definition.prompt.count) else {
        throw ScheduledJobError.invalidPrompt
    }
    guard definition.recurrence.isValid else {
        throw ScheduledJobError.invalidRecurrence
    }
    guard definition.provider.isSupported else {
        throw ScheduledJobError.unsupportedProvider(definition.provider.rawValue)
    }
    return definition
}
