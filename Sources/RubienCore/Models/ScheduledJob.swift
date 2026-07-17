import Foundation
import GRDB

public enum ScheduledJobProvider: Codable, Hashable, Sendable {
    case claude
    case codex
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "claude": self = .claude
        case "codex": self = .codex
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case let .unknown(value): value
        }
    }

    public var isSupported: Bool {
        switch self {
        case .claude, .codex: true
        case .unknown: false
        }
    }

    public static let knownCases: [ScheduledJobProvider] = [.claude, .codex]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ScheduledJobRunTrigger: Codable, Hashable, Sendable {
    case scheduled
    case catchUp
    case manual
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "scheduled": self = .scheduled
        case "catchUp": self = .catchUp
        case "manual": self = .manual
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .scheduled: "scheduled"
        case .catchUp: "catchUp"
        case .manual: "manual"
        case let .unknown(value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ScheduledJobRunStatus: Codable, Hashable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "running": self = .running
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .running: "running"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case let .unknown(value): value
        }
    }

    public var isActive: Bool {
        switch self {
        case .pending, .running, .unknown: true
        case .succeeded, .failed, .cancelled: false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .pending, .running, .unknown: false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ScheduledJobFailureKind: Codable, Hashable, Sendable {
    case providerUnavailable
    case libraryChannelUnavailable
    case permissionDenied
    case interruptedBeforeStart
    case interrupted
    case launchFailed
    case providerFailed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "providerUnavailable": self = .providerUnavailable
        case "libraryChannelUnavailable": self = .libraryChannelUnavailable
        case "permissionDenied": self = .permissionDenied
        case "interruptedBeforeStart": self = .interruptedBeforeStart
        case "interrupted": self = .interrupted
        case "launchFailed": self = .launchFailed
        case "providerFailed": self = .providerFailed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .providerUnavailable: "providerUnavailable"
        case .libraryChannelUnavailable: "libraryChannelUnavailable"
        case .permissionDenied: "permissionDenied"
        case .interruptedBeforeStart: "interruptedBeforeStart"
        case .interrupted: "interrupted"
        case .launchFailed: "launchFailed"
        case .providerFailed: "providerFailed"
        case let .unknown(value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Monday is bit 0 and Sunday is bit 6. This is independent of the user's
/// first-weekday preference while occurrence calculations still use their
/// current calendar and time zone.
public enum ScheduledWeekday: Int, Codable, CaseIterable, Sendable {
    case monday = 0
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    public var mask: Int { 1 << rawValue }

    fileprivate var calendarWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}

public struct ScheduledRecurrence: Codable, Hashable, Sendable {
    public var weekdayMask: Int
    public var localMinuteOfDay: Int

    public init(weekdayMask: Int, localMinuteOfDay: Int) {
        self.weekdayMask = weekdayMask
        self.localMinuteOfDay = localMinuteOfDay
    }

    public var isValid: Bool {
        (1 ... 127).contains(weekdayMask) && (0 ... 1439).contains(localMinuteOfDay)
    }

    public func contains(_ weekday: ScheduledWeekday) -> Bool {
        weekdayMask & weekday.mask != 0
    }

    public func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        occurrence(relativeTo: date, calendar: calendar, searchingForward: true)
    }

    public func latestOccurrence(onOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        occurrence(relativeTo: date, calendar: calendar, searchingForward: false)
    }

    private func occurrence(
        relativeTo date: Date,
        calendar sourceCalendar: Calendar,
        searchingForward: Bool
    ) -> Date? {
        guard isValid else { return nil }
        var calendar = sourceCalendar
        calendar.timeZone = sourceCalendar.timeZone
        let start = calendar.startOfDay(for: date)
        let offsets = 0 ... 7

        for offset in offsets {
            let signedOffset = searchingForward ? offset : -offset
            guard let day = calendar.date(byAdding: .day, value: signedOffset, to: start),
                  let weekday = ScheduledWeekday(
                      calendarWeekday: calendar.component(.weekday, from: day)
                  ),
                  contains(weekday),
                  let candidate = localTime(on: day, calendar: calendar)
            else { continue }

            if searchingForward ? candidate > date : candidate <= date {
                return candidate
            }
        }
        return nil
    }

    private func localTime(on day: Date, calendar: Calendar) -> Date? {
        let hour = localMinuteOfDay / 60
        let minute = localMinuteOfDay % 60
        guard let candidate = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ), LocalDay(date: candidate, calendar: calendar) == LocalDay(date: day, calendar: calendar)
        else { return nil }
        return candidate
    }
}

private extension ScheduledWeekday {
    init?(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1: self = .sunday
        case 2: self = .monday
        case 3: self = .tuesday
        case 4: self = .wednesday
        case 5: self = .thursday
        case 6: self = .friday
        case 7: self = .saturday
        default: return nil
        }
    }
}

public struct ScheduledJobDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var prompt: String
    public var recurrence: ScheduledRecurrence
    public var isEnabled: Bool
    public var provider: ScheduledJobProvider
    public var model: String?
    public var effort: String?
    public var webAccess: Bool
    public var notifyOnCompletion: Bool

    public init(
        name: String,
        prompt: String,
        recurrence: ScheduledRecurrence,
        isEnabled: Bool = true,
        provider: ScheduledJobProvider,
        model: String? = nil,
        effort: String? = nil,
        webAccess: Bool = true,
        notifyOnCompletion: Bool = true
    ) {
        self.name = name
        self.prompt = prompt
        self.recurrence = recurrence
        self.isEnabled = isEnabled
        self.provider = provider
        self.model = model
        self.effort = effort
        self.webAccess = webAccess
        self.notifyOnCompletion = notifyOnCompletion
    }
}

public struct ScheduledJob: Identifiable, Codable, Hashable, Sendable {
    public static let databaseTableName = "scheduledJob"

    public var id: String
    public var name: String
    public var prompt: String
    public var weekdayMask: Int
    public var localMinuteOfDay: Int
    public var isEnabled: Bool
    public var provider: ScheduledJobProvider
    public var model: String?
    public var effort: String?
    public var webAccess: Bool
    public var notifyOnCompletion: Bool
    public var nextRunAt: Date?
    public var createdAt: Date
    public var dateModified: Date

    public var recurrence: ScheduledRecurrence {
        .init(weekdayMask: weekdayMask, localMinuteOfDay: localMinuteOfDay)
    }

    public var definition: ScheduledJobDefinition {
        .init(
            name: name,
            prompt: prompt,
            recurrence: recurrence,
            isEnabled: isEnabled,
            provider: provider,
            model: model,
            effort: effort,
            webAccess: webAccess,
            notifyOnCompletion: notifyOnCompletion
        )
    }

    public init(
        id: String,
        definition: ScheduledJobDefinition,
        nextRunAt: Date?,
        createdAt: Date,
        dateModified: Date
    ) {
        self.id = id
        name = definition.name
        prompt = definition.prompt
        weekdayMask = definition.recurrence.weekdayMask
        localMinuteOfDay = definition.recurrence.localMinuteOfDay
        isEnabled = definition.isEnabled
        provider = definition.provider
        model = definition.model
        effort = definition.effort
        webAccess = definition.webAccess
        notifyOnCompletion = definition.notifyOnCompletion
        self.nextRunAt = nextRunAt
        self.createdAt = createdAt
        self.dateModified = dateModified
    }

    public enum Columns: String, ColumnExpression {
        case id, name, prompt, weekdayMask, localMinuteOfDay, isEnabled
        case provider, model, effort, webAccess, notifyOnCompletion
        case nextRunAt, createdAt, dateModified
    }
}

extension ScheduledJob: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        id = row[Columns.id]
        name = row[Columns.name]
        prompt = row[Columns.prompt]
        weekdayMask = row[Columns.weekdayMask]
        localMinuteOfDay = row[Columns.localMinuteOfDay]
        isEnabled = row[Columns.isEnabled]
        provider = ScheduledJobProvider(rawValue: row[Columns.provider])
        model = row[Columns.model]
        effort = row[Columns.effort]
        webAccess = row[Columns.webAccess]
        notifyOnCompletion = row[Columns.notifyOnCompletion]
        nextRunAt = row[Columns.nextRunAt]
        createdAt = row[Columns.createdAt]
        dateModified = row[Columns.dateModified]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.prompt] = prompt
        container[Columns.weekdayMask] = weekdayMask
        container[Columns.localMinuteOfDay] = localMinuteOfDay
        container[Columns.isEnabled] = isEnabled
        container[Columns.provider] = provider.rawValue
        container[Columns.model] = model
        container[Columns.effort] = effort
        container[Columns.webAccess] = webAccess
        container[Columns.notifyOnCompletion] = notifyOnCompletion
        container[Columns.nextRunAt] = nextRunAt
        container[Columns.createdAt] = createdAt
        container[Columns.dateModified] = dateModified
    }
}

public struct ScheduledJobRun: Identifiable, Codable, Hashable, Sendable {
    public static let databaseTableName = "scheduledJobRun"

    public var id: String
    public var jobId: String
    public var trigger: ScheduledJobRunTrigger
    public var occurrenceKey: String
    public var scheduledFor: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var status: ScheduledJobRunStatus
    public var provider: ScheduledJobProvider
    public var providerSessionId: String?
    public var failureKind: ScheduledJobFailureKind?
    public var isUnread: Bool

    /// The latest execution activity used to order and display run history.
    public var activityAt: Date {
        finishedAt ?? startedAt ?? scheduledFor
    }

    public enum Columns: String, ColumnExpression {
        case id, jobId, trigger, occurrenceKey, scheduledFor, startedAt, finishedAt
        case status, provider, providerSessionId, failureKind, isUnread
    }
}

extension ScheduledJobRun: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        id = row[Columns.id]
        jobId = row[Columns.jobId]
        trigger = ScheduledJobRunTrigger(rawValue: row[Columns.trigger])
        occurrenceKey = row[Columns.occurrenceKey]
        scheduledFor = row[Columns.scheduledFor]
        startedAt = row[Columns.startedAt]
        finishedAt = row[Columns.finishedAt]
        status = ScheduledJobRunStatus(rawValue: row[Columns.status])
        provider = ScheduledJobProvider(rawValue: row[Columns.provider])
        providerSessionId = row[Columns.providerSessionId]
        failureKind = (row[Columns.failureKind] as String?).map(ScheduledJobFailureKind.init(rawValue:))
        isUnread = row[Columns.isUnread]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.jobId] = jobId
        container[Columns.trigger] = trigger.rawValue
        container[Columns.occurrenceKey] = occurrenceKey
        container[Columns.scheduledFor] = scheduledFor
        container[Columns.startedAt] = startedAt
        container[Columns.finishedAt] = finishedAt
        container[Columns.status] = status.rawValue
        container[Columns.provider] = provider.rawValue
        container[Columns.providerSessionId] = providerSessionId
        container[Columns.failureKind] = failureKind?.rawValue
        container[Columns.isUnread] = isUnread
    }
}

public struct ScheduledJobExecutionClaim: Hashable, Sendable {
    public var job: ScheduledJob
    public var run: ScheduledJobRun

    public init(job: ScheduledJob, run: ScheduledJobRun) {
        self.job = job
        self.run = run
    }
}

public struct ScheduledJobDashboardSnapshot: Equatable, Sendable {
    public let jobs: [ScheduledJob]
    public let upcomingJobs: [ScheduledJob]
    public let recentRuns: [ScheduledJobRun]
    public let unreadRunCount: Int
}

public enum ScheduledJobError: Error, Equatable, LocalizedError {
    case invalidName
    case invalidPrompt
    case invalidRecurrence
    case unsupportedProvider(String)
    case notFound
    case runnerBusy
    case activeRunPreventsDeletion

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Job name must contain 1 to 200 characters."
        case .invalidPrompt: "Job prompt must contain 1 to 20,000 characters."
        case .invalidRecurrence: "Choose at least one weekday and a valid local time."
        case let .unsupportedProvider(provider): "The provider ‘\(provider)’ is not supported."
        case .notFound: "The scheduled job could not be found."
        case .runnerBusy: "Another scheduled job is already running."
        case .activeRunPreventsDeletion: "A job with an active run cannot be deleted."
        }
    }
}
