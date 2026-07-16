import Foundation
import GRDB

/// A Gregorian calendar date captured at the time activity occurred.
///
/// The raw value is deliberately time-zone-free. Once recorded, past activity
/// does not move when the user travels or changes calendar preferences.
public struct LocalDay: RawRepresentable, Codable, Hashable, Comparable, Sendable,
    CustomStringConvertible, DatabaseValueConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 10,
              rawValue[rawValue.index(rawValue.startIndex, offsetBy: 4)] == "-",
              rawValue[rawValue.index(rawValue.startIndex, offsetBy: 7)] == "-"
        else { return nil }

        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1 ... 9999).contains(year)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: date)
                == DateComponents(year: year, month: month, day: day)
        else { return nil }

        self.rawValue = rawValue
    }

    public init(date: Date, calendar sourceCalendar: Calendar = .current) {
        var calendar = sourceCalendar
        calendar.timeZone = sourceCalendar.timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        precondition(
            components.year != nil && components.month != nil && components.day != nil,
            "Calendar could not produce a local date"
        )
        rawValue = String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year!,
            components.month!,
            components.day!
        )
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = LocalDay(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a Gregorian local day in YYYY-MM-DD form"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var databaseValue: DatabaseValue { rawValue.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalDay? {
        String.fromDatabaseValue(dbValue).flatMap(LocalDay.init(rawValue:))
    }

    public func date(in sourceCalendar: Calendar = .current) -> Date? {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = sourceCalendar
        calendar.timeZone = sourceCalendar.timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public func addingDays(_ value: Int, calendar: Calendar = .current) -> LocalDay? {
        guard let date = date(in: calendar),
              let shifted = calendar.date(byAdding: .day, value: value, to: date)
        else { return nil }
        return LocalDay(date: shifted, calendar: calendar)
    }
}

/// Independent ledgers let Reading and Assistant statistics be cleared
/// without changing the other category's effective history.
public enum ActivityKind: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case reading
    case assistant
}

/// One installation's grow-only cumulative counter for one paper and local day.
public struct ReadingActivity: Codable, Hashable, Sendable {
    public static let databaseTableName = "readingActivity"

    public var installationId: String
    public var referenceId: Int64
    public var localDay: LocalDay
    public var epochRevision: Int
    public var generation: String
    public var activeSeconds: Int64
    public var lastActiveAt: Date
    public var dateModified: Date

    public init(
        installationId: String,
        referenceId: Int64,
        localDay: LocalDay,
        epochRevision: Int,
        generation: String,
        activeSeconds: Int64,
        lastActiveAt: Date,
        dateModified: Date = Date()
    ) {
        precondition(activeSeconds >= 0)
        self.installationId = installationId
        self.referenceId = referenceId
        self.localDay = localDay
        self.epochRevision = epochRevision
        self.generation = generation
        self.activeSeconds = activeSeconds
        self.lastActiveAt = lastActiveAt
        self.dateModified = dateModified
    }

    public var entityId: String {
        "\(generation)/\(installationId)/\(referenceId)/\(localDay.rawValue)"
    }

    public enum Columns: String, ColumnExpression {
        case installationId, referenceId, localDay, epochRevision, generation
        case activeSeconds, lastActiveAt, dateModified
    }
}

extension ReadingActivity: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        installationId = row[Columns.installationId]
        referenceId = row[Columns.referenceId]
        localDay = row[Columns.localDay]
        epochRevision = row[Columns.epochRevision]
        generation = row[Columns.generation]
        activeSeconds = row[Columns.activeSeconds]
        lastActiveAt = row[Columns.lastActiveAt]
        dateModified = row[Columns.dateModified]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.installationId] = installationId
        container[Columns.referenceId] = referenceId
        container[Columns.localDay] = localDay
        container[Columns.epochRevision] = epochRevision
        container[Columns.generation] = generation
        container[Columns.activeSeconds] = activeSeconds
        container[Columns.lastActiveAt] = lastActiveAt
        container[Columns.dateModified] = dateModified
    }
}

/// A successfully started fresh Rubien Assistant conversation.
public struct AssistantActivity: Identifiable, Codable, Hashable, Sendable {
    public static let databaseTableName = "assistantActivity"

    public var id: String
    public var provider: String
    public var epochRevision: Int
    public var generation: String
    public var startedAt: Date
    public var localDay: LocalDay
    public var dateModified: Date

    public init(
        id: String,
        provider: String,
        epochRevision: Int,
        generation: String,
        startedAt: Date,
        localDay: LocalDay,
        dateModified: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.epochRevision = epochRevision
        self.generation = generation
        self.startedAt = startedAt
        self.localDay = localDay
        self.dateModified = dateModified
    }
}

extension AssistantActivity: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        id = row["id"]
        provider = row["provider"]
        epochRevision = row["epochRevision"]
        generation = row["generation"]
        startedAt = row["startedAt"]
        localDay = row["localDay"]
        dateModified = row["dateModified"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["provider"] = provider
        container["epochRevision"] = epochRevision
        container["generation"] = generation
        container["startedAt"] = startedAt
        container["localDay"] = localDay
        container["dateModified"] = dateModified
    }
}

/// Synced, last-writer-wins reset boundary for one activity category.
public struct ActivityEpoch: Codable, Hashable, Sendable {
    public static let databaseTableName = "activityEpoch"

    public var kind: ActivityKind
    public var revision: Int
    public var generation: String
    public var resetAt: Date?
    public var dateModified: Date

    public init(
        kind: ActivityKind,
        revision: Int,
        generation: String,
        resetAt: Date?,
        dateModified: Date = Date()
    ) {
        self.kind = kind
        self.revision = revision
        self.generation = generation
        self.resetAt = resetAt
        self.dateModified = dateModified
    }

    public static func initial(_ kind: ActivityKind, dateModified: Date = Date()) -> ActivityEpoch {
        ActivityEpoch(
            kind: kind,
            revision: 0,
            generation: "\(kind.rawValue)-v7-initial",
            resetAt: nil,
            dateModified: dateModified
        )
    }
}

extension ActivityEpoch: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        kind = row["kind"]
        revision = row["revision"]
        generation = row["generation"]
        resetAt = row["resetAt"]
        dateModified = row["dateModified"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["kind"] = kind
        container["revision"] = revision
        container["generation"] = generation
        container["resetAt"] = resetAt
        container["dateModified"] = dateModified
    }
}

/// Local crash-recovery marker used while a clear is being synchronized.
public struct ActivityPendingClear: Codable, Hashable, Sendable {
    public static let databaseTableName = "activityPendingClear"

    public var kind: ActivityKind
    public var intentId: String
    public var revision: Int
    public var generation: String
    public var resetAt: Date
    public var dateModified: Date
}

extension ActivityPendingClear: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        kind = row["kind"]
        intentId = row["intentId"]
        revision = row["revision"]
        generation = row["generation"]
        resetAt = row["resetAt"]
        dateModified = row["dateModified"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["kind"] = kind
        container["intentId"] = intentId
        container["revision"] = revision
        container["generation"] = generation
        container["resetAt"] = resetAt
        container["dateModified"] = dateModified
    }
}

/// Local holding area for pulled rows that cannot yet be applied safely.
public struct ActivityQuarantine: Codable, Hashable, Sendable {
    public static let databaseTableName = "activityQuarantine"

    public var recordName: String
    public var entityType: String
    public var reason: String
    public var epochRevision: Int
    public var generation: String
    public var referenceId: Int64?
    public var recordData: Data
    public var receivedAt: Date
}

extension ActivityQuarantine: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        recordName = row["recordName"]
        entityType = row["entityType"]
        reason = row["reason"]
        epochRevision = row["epochRevision"]
        generation = row["generation"]
        referenceId = row["referenceId"]
        recordData = row["recordData"]
        receivedAt = row["receivedAt"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["recordName"] = recordName
        container["entityType"] = entityType
        container["reason"] = reason
        container["epochRevision"] = epochRevision
        container["generation"] = generation
        container["referenceId"] = referenceId
        container["recordData"] = recordData
        container["receivedAt"] = receivedAt
    }
}

// MARK: - Immutable statistics contract

public struct ReadingActivitySnapshot: Sendable, Equatable {
    public var asOfLocalDay: LocalDay
    public var dailyActivityStartDay: LocalDay
    public var dailyActivityEndDay: LocalDay
    public var papersReadTracked: Int
    public var estimatedActiveSecondsTracked: Int64
    public var papersReadThisWeek: Int
    public var estimatedActiveSecondsThisWeek: Int64
    public var assistantSessionsTracked: Int
    public var currentStreakDays: Int
    public var longestStreakDays: Int
    public var dailyActivity: [DailyReadingActivity]
    public var recentPapers: [RecentReading]
    public var coverage: ActivityCoverage
}

public struct DailyReadingActivity: Codable, Sendable, Equatable {
    public var localDay: LocalDay
    public var paperCount: Int
    public var estimatedActiveSeconds: Int64

    public init(localDay: LocalDay, paperCount: Int, estimatedActiveSeconds: Int64) {
        self.localDay = localDay
        self.paperCount = paperCount
        self.estimatedActiveSeconds = estimatedActiveSeconds
    }
}

public struct RecentReading: Codable, Sendable, Equatable {
    public var referenceId: Int64
    public var title: String
    public var byline: String?
    public var venue: String?
    public var lastActiveAt: Date

    public init(referenceId: Int64, title: String, byline: String?, venue: String?, lastActiveAt: Date) {
        self.referenceId = referenceId
        self.title = title
        self.byline = byline
        self.venue = venue
        self.lastActiveAt = lastActiveAt
    }

    private enum CodingKeys: String, CodingKey {
        case referenceId, title, byline, venue, lastActiveAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceId = try container.decode(Int64.self, forKey: .referenceId)
        title = try container.decode(String.self, forKey: .title)
        byline = try container.decodeIfPresent(String.self, forKey: .byline)
        venue = try container.decodeIfPresent(String.self, forKey: .venue)
        lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(referenceId, forKey: .referenceId)
        try container.encode(title, forKey: .title)
        if let byline { try container.encode(byline, forKey: .byline) }
        else { try container.encodeNil(forKey: .byline) }
        if let venue { try container.encode(venue, forKey: .venue) }
        else { try container.encodeNil(forKey: .venue) }
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
    }
}

public struct ActivityCoverage: Codable, Sendable, Equatable {
    public var trackingIntroducedInVersion: String
    public var readingResetAt: Date?
    public var assistantResetAt: Date?

    public init(trackingIntroducedInVersion: String, readingResetAt: Date?, assistantResetAt: Date?) {
        self.trackingIntroducedInVersion = trackingIntroducedInVersion
        self.readingResetAt = readingResetAt
        self.assistantResetAt = assistantResetAt
    }

    private enum CodingKeys: String, CodingKey {
        case trackingIntroducedInVersion, readingResetAt, assistantResetAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackingIntroducedInVersion = try container.decode(String.self, forKey: .trackingIntroducedInVersion)
        readingResetAt = try container.decodeIfPresent(Date.self, forKey: .readingResetAt)
        assistantResetAt = try container.decodeIfPresent(Date.self, forKey: .assistantResetAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackingIntroducedInVersion, forKey: .trackingIntroducedInVersion)
        if let readingResetAt { try container.encode(readingResetAt, forKey: .readingResetAt) }
        else { try container.encodeNil(forKey: .readingResetAt) }
        if let assistantResetAt { try container.encode(assistantResetAt, forKey: .assistantResetAt) }
        else { try container.encodeNil(forKey: .assistantResetAt) }
    }
}

/// Epoch identity captured when an asynchronous activity producer starts.
/// The optional intent lets a post-clear write follow a rebase of that same
/// user clear without admitting activity from an unrelated, later clear.
public struct ActivityCaptureContext: Codable, Sendable, Equatable {
    public var kind: ActivityKind
    public var revision: Int
    public var generation: String
    public var pendingClearIntentId: String?

    public init(
        kind: ActivityKind,
        revision: Int,
        generation: String,
        pendingClearIntentId: String?
    ) {
        self.kind = kind
        self.revision = revision
        self.generation = generation
        self.pendingClearIntentId = pendingClearIntentId
    }
}

public enum ActivityWriteDisposition<Value: Sendable>: Sendable {
    case saved(Value)
    case staleEpoch
}

public struct ReadingActivityStatistics: Codable, Sendable, Equatable {
    public struct TrackedTotals: Codable, Sendable, Equatable {
        public var papersRead: Int
        public var estimatedActiveSeconds: Int64
        public var assistantSessions: Int
    }

    public struct CurrentWeek: Codable, Sendable, Equatable {
        public var startDay: LocalDay
        public var throughDay: LocalDay
        public var papersRead: Int
        public var estimatedActiveSeconds: Int64
    }

    public struct Streaks: Codable, Sendable, Equatable {
        public var currentDays: Int
        public var longestDays: Int
    }

    public struct YearActivity: Codable, Sendable, Equatable {
        public var year: Int
        public var dailyActivity: [DailyReadingActivity]
    }

    public var asOfLocalDay: LocalDay
    public var trackedTotals: TrackedTotals
    public var currentWeek: CurrentWeek
    public var streaks: Streaks
    public var yearActivity: YearActivity
    public var recentPapers: [RecentReading]
    public var coverage: ActivityCoverage
}
