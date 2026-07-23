import Foundation
import GRDB

/// Assistant providers share the same persisted vocabulary as scheduled jobs.
/// Keeping one unknown-safe enum avoids provider spelling drift across the two
/// local data models.
public typealias AssistantProvider = ScheduledJobProvider

public enum AssistantConversationOrigin: RawStringCodable, Hashable, Sendable {
    case rubien
    case providerImport
    case legacyStub
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "rubien": self = .rubien
        case "providerImport": self = .providerImport
        case "legacyStub": self = .legacyStub
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .rubien: "rubien"
        case .providerImport: "providerImport"
        case .legacyStub: "legacyStub"
        case let .unknown(value): value
        }
    }

    /// Unknown origins and one-way legacy stubs stay out of normal History.
    public static let localHistoryRawValues = [
        AssistantConversationOrigin.rubien.rawValue,
        AssistantConversationOrigin.providerImport.rawValue,
    ]
}

public enum AssistantConversationContextKind: RawStringCodable, Hashable, Sendable {
    case library
    case reference
    case unclassified
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "library": self = .library
        case "reference": self = .reference
        case "unclassified": self = .unclassified
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .library: "library"
        case .reference: "reference"
        case .unclassified: "unclassified"
        case let .unknown(value): value
        }
    }

}

public enum AssistantTurnStatus: RawStringCodable, Hashable, Sendable {
    case queued
    case starting
    case running
    case succeeded
    case failed
    case interrupted
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "queued": self = .queued
        case "starting": self = .starting
        case "running": self = .running
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "interrupted": self = .interrupted
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .queued: "queued"
        case .starting: "starting"
        case .running: "running"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .interrupted: "interrupted"
        case let .unknown(value): value
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .interrupted: true
        case .queued, .starting, .running, .unknown: false
        }
    }

}

public enum AssistantTranscriptEntryKind: RawStringCodable, Hashable, Sendable {
    case user
    case assistant
    case tool
    case notice
    case paper
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "assistant": self = .assistant
        case "tool": self = .tool
        case "notice": self = .notice
        case "paper": self = .paper
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .tool: "tool"
        case .notice: "notice"
        case .paper: "paper"
        case let .unknown(value): value
        }
    }

}

public enum AssistantTranscriptEntryStatus: RawStringCodable, Hashable, Sendable {
    case streaming
    case completed
    case denied
    case interrupted
    case failed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "streaming": self = .streaming
        case "completed": self = .completed
        case "denied": self = .denied
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .streaming: "streaming"
        case .completed: "completed"
        case .denied: "denied"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case let .unknown(value): value
        }
    }

}

public enum StoredAssistantAttachmentKind: RawStringCodable, Hashable, Sendable {
    case image
    case text
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "image": self = .image
        case "text": self = .text
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .image: "image"
        case .text: "text"
        case let .unknown(value): value
        }
    }

}

public struct AssistantConversation: Identifiable, Codable, Hashable, Sendable {
    public static let databaseTableName = "assistantConversation"

    public var id: String
    public var provider: AssistantProvider
    public var origin: AssistantConversationOrigin
    public var workspaceIdentityHash: String?
    public var contextKind: AssistantConversationContextKind
    public var referenceId: Int64?
    public var scheduledJobRunId: String?
    public var continuedFromConversationId: String?
    public var continuationTransferredAt: Date?
    public var latestProviderSessionId: String?
    public var latestSessionTurnOrdinal: Int?
    public var latestSessionEventOrdinal: Int?
    public var createdAt: Date
    public var lastActivityAt: Date
    public var archivedAt: Date?

    public init(
        id: String = UUID().uuidString.lowercased(),
        provider: AssistantProvider,
        origin: AssistantConversationOrigin = .rubien,
        workspaceIdentityHash: String?,
        contextKind: AssistantConversationContextKind,
        referenceId: Int64? = nil,
        scheduledJobRunId: String? = nil,
        continuedFromConversationId: String? = nil,
        continuationTransferredAt: Date? = nil,
        latestProviderSessionId: String? = nil,
        latestSessionTurnOrdinal: Int? = nil,
        latestSessionEventOrdinal: Int? = nil,
        createdAt: Date = Date(),
        lastActivityAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.origin = origin
        self.workspaceIdentityHash = workspaceIdentityHash
        self.contextKind = contextKind
        self.referenceId = referenceId
        self.scheduledJobRunId = scheduledJobRunId
        self.continuedFromConversationId = continuedFromConversationId
        self.continuationTransferredAt = continuationTransferredAt
        self.latestProviderSessionId = latestProviderSessionId
        self.latestSessionTurnOrdinal = latestSessionTurnOrdinal
        self.latestSessionEventOrdinal = latestSessionEventOrdinal
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt ?? createdAt
        self.archivedAt = archivedAt
    }

    public enum Columns: String, ColumnExpression {
        case id, provider, origin, workspaceIdentityHash, contextKind, referenceId
        case scheduledJobRunId, continuedFromConversationId
        case continuationTransferredAt, latestProviderSessionId
        case latestSessionTurnOrdinal, latestSessionEventOrdinal
        case createdAt, lastActivityAt, archivedAt
    }
}

extension AssistantConversation: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        id = row[Columns.id]
        provider = AssistantProvider(rawValue: row[Columns.provider])
        origin = AssistantConversationOrigin(rawValue: row[Columns.origin])
        workspaceIdentityHash = row[Columns.workspaceIdentityHash]
        let rawContext: String = row[Columns.contextKind]
        let storedReferenceId: Int64? = row[Columns.referenceId]
        let decodedContext = AssistantConversationContextKind(rawValue: rawContext)
        if case .unknown = decodedContext, storedReferenceId == nil {
            contextKind = .unclassified
        } else {
            contextKind = decodedContext
        }
        referenceId = storedReferenceId
        scheduledJobRunId = row[Columns.scheduledJobRunId]
        continuedFromConversationId = row[Columns.continuedFromConversationId]
        continuationTransferredAt = row[Columns.continuationTransferredAt]
        latestProviderSessionId = row[Columns.latestProviderSessionId]
        latestSessionTurnOrdinal = row[Columns.latestSessionTurnOrdinal]
        latestSessionEventOrdinal = row[Columns.latestSessionEventOrdinal]
        createdAt = row[Columns.createdAt]
        lastActivityAt = row[Columns.lastActivityAt]
        archivedAt = row[Columns.archivedAt]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.provider] = provider.rawValue
        container[Columns.origin] = origin.rawValue
        container[Columns.workspaceIdentityHash] = workspaceIdentityHash
        container[Columns.contextKind] = contextKind.rawValue
        container[Columns.referenceId] = referenceId
        container[Columns.scheduledJobRunId] = scheduledJobRunId
        container[Columns.continuedFromConversationId] = continuedFromConversationId
        container[Columns.continuationTransferredAt] = continuationTransferredAt
        container[Columns.latestProviderSessionId] = latestProviderSessionId
        container[Columns.latestSessionTurnOrdinal] = latestSessionTurnOrdinal
        container[Columns.latestSessionEventOrdinal] = latestSessionEventOrdinal
        container[Columns.createdAt] = createdAt
        container[Columns.lastActivityAt] = lastActivityAt
        container[Columns.archivedAt] = archivedAt
    }
}

public struct AssistantTurn: Identifiable, Codable, Hashable, Sendable {
    public static let databaseTableName = "assistantTurn"

    public var id: String
    public var conversationId: String
    public var ordinal: Int
    public var providerTurnId: String?
    public var status: AssistantTurnStatus
    public var requestedModel: String?
    public var requestedEffort: String?
    public var resolvedModel: String?
    public var resolvedEffort: String?
    public var failureKind: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var totalCostUSD: Double?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var dateModified: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        conversationId: String,
        ordinal: Int,
        providerTurnId: String? = nil,
        status: AssistantTurnStatus = .queued,
        requestedModel: String? = nil,
        requestedEffort: String? = nil,
        resolvedModel: String? = nil,
        resolvedEffort: String? = nil,
        failureKind: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        totalCostUSD: Double? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        dateModified: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.ordinal = ordinal
        self.providerTurnId = providerTurnId
        self.status = status
        self.requestedModel = requestedModel
        self.requestedEffort = requestedEffort
        self.resolvedModel = resolvedModel
        self.resolvedEffort = resolvedEffort
        self.failureKind = failureKind
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.dateModified = dateModified
    }

    public enum Columns: String, ColumnExpression {
        case id, conversationId, ordinal, providerTurnId, status
        case requestedModel, requestedEffort, resolvedModel, resolvedEffort
        case failureKind, inputTokens, outputTokens, cacheReadTokens
        case cacheCreationTokens, totalCostUSD, startedAt, finishedAt, dateModified
    }
}

public struct AssistantTurnAccounting: Codable, Hashable, Sendable {
    public var resolvedModel: String?
    public var resolvedEffort: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var totalCostUSD: Double?

    public init(
        resolvedModel: String? = nil,
        resolvedEffort: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        totalCostUSD: Double? = nil
    ) {
        self.resolvedModel = resolvedModel
        self.resolvedEffort = resolvedEffort
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
    }
}

extension AssistantTurn: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        id = row[Columns.id]
        conversationId = row[Columns.conversationId]
        ordinal = row[Columns.ordinal]
        providerTurnId = row[Columns.providerTurnId]
        status = AssistantTurnStatus(rawValue: row[Columns.status])
        requestedModel = row[Columns.requestedModel]
        requestedEffort = row[Columns.requestedEffort]
        resolvedModel = row[Columns.resolvedModel]
        resolvedEffort = row[Columns.resolvedEffort]
        failureKind = row[Columns.failureKind]
        inputTokens = row[Columns.inputTokens]
        outputTokens = row[Columns.outputTokens]
        cacheReadTokens = row[Columns.cacheReadTokens]
        cacheCreationTokens = row[Columns.cacheCreationTokens]
        totalCostUSD = row[Columns.totalCostUSD]
        startedAt = row[Columns.startedAt]
        finishedAt = row[Columns.finishedAt]
        dateModified = row[Columns.dateModified]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.conversationId] = conversationId
        container[Columns.ordinal] = ordinal
        container[Columns.providerTurnId] = providerTurnId
        container[Columns.status] = status.rawValue
        container[Columns.requestedModel] = requestedModel
        container[Columns.requestedEffort] = requestedEffort
        container[Columns.resolvedModel] = resolvedModel
        container[Columns.resolvedEffort] = resolvedEffort
        container[Columns.failureKind] = failureKind
        container[Columns.inputTokens] = inputTokens
        container[Columns.outputTokens] = outputTokens
        container[Columns.cacheReadTokens] = cacheReadTokens
        container[Columns.cacheCreationTokens] = cacheCreationTokens
        container[Columns.totalCostUSD] = totalCostUSD
        container[Columns.startedAt] = startedAt
        container[Columns.finishedAt] = finishedAt
        container[Columns.dateModified] = dateModified
    }
}

public struct AssistantTranscriptEntry: Identifiable, Codable, Hashable, Sendable {
    public static let databaseTableName = "assistantTranscriptEntry"
    public static let currentPayloadVersion = 1

    package var rowId: Int64?
    public var id: String
    public var turnId: String
    public var sequence: Int
    public var providerItemId: String?
    public var kind: AssistantTranscriptEntryKind
    public var body: String
    public var payloadVersion: Int
    public var payloadJSON: String?
    public var searchText: String
    public var status: AssistantTranscriptEntryStatus?
    public var createdAt: Date
    public var dateModified: Date

    public var hasUnavailablePayloadDetails: Bool {
        guard payloadJSON != nil else { return false }
        // Version is the compatibility boundary. Current payloads are decoded
        // only by the renderer that needs them; transcript listing/opening must
        // not eagerly parse every stored tool and paper payload.
        return payloadVersion != Self.currentPayloadVersion
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        turnId: String,
        sequence: Int,
        providerItemId: String? = nil,
        kind: AssistantTranscriptEntryKind,
        body: String,
        payloadVersion: Int = Self.currentPayloadVersion,
        payloadJSON: String? = nil,
        searchText: String? = nil,
        status: AssistantTranscriptEntryStatus? = nil,
        createdAt: Date = Date(),
        dateModified: Date? = nil
    ) {
        rowId = nil
        self.id = id
        self.turnId = turnId
        self.sequence = sequence
        self.providerItemId = providerItemId
        self.kind = kind
        self.body = body
        self.payloadVersion = payloadVersion
        self.payloadJSON = payloadJSON
        self.searchText = searchText ?? Self.defaultSearchText(kind: kind, body: body)
        self.status = status
        self.createdAt = createdAt
        self.dateModified = dateModified ?? createdAt
    }

    public static func defaultSearchText(
        kind: AssistantTranscriptEntryKind,
        body: String
    ) -> String {
        switch kind {
        case .user, .assistant, .paper:
            body
        case .tool, .notice, .unknown:
            ""
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, turnId, sequence, providerItemId, kind, body, payloadVersion
        case payloadJSON, searchText, status, createdAt, dateModified
    }

    public enum Columns: String, ColumnExpression {
        case rowId, id, turnId, sequence, providerItemId, kind, body
        case payloadVersion, payloadJSON, searchText, status, createdAt, dateModified
    }
}

extension AssistantTranscriptEntry: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        rowId = row[Columns.rowId]
        id = row[Columns.id]
        turnId = row[Columns.turnId]
        sequence = row[Columns.sequence]
        providerItemId = row[Columns.providerItemId]
        kind = AssistantTranscriptEntryKind(rawValue: row[Columns.kind])
        body = row[Columns.body]
        payloadVersion = row[Columns.payloadVersion]
        payloadJSON = row[Columns.payloadJSON]
        searchText = row[Columns.searchText]
        status = (row[Columns.status] as String?).map(AssistantTranscriptEntryStatus.init(rawValue:))
        createdAt = row[Columns.createdAt]
        dateModified = row[Columns.dateModified]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.rowId] = rowId
        container[Columns.id] = id
        container[Columns.turnId] = turnId
        container[Columns.sequence] = sequence
        container[Columns.providerItemId] = providerItemId
        container[Columns.kind] = kind.rawValue
        container[Columns.body] = body
        container[Columns.payloadVersion] = payloadVersion
        container[Columns.payloadJSON] = payloadJSON
        container[Columns.searchText] = searchText
        container[Columns.status] = status?.rawValue
        container[Columns.createdAt] = createdAt
        container[Columns.dateModified] = dateModified
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        rowId = inserted.rowID
    }
}

public struct StoredAssistantAttachment: Identifiable, Codable, Hashable, Sendable {
    public static let databaseTableName = "assistantAttachment"

    public var id: String
    public var entryId: String
    public var displayName: String
    public var kind: StoredAssistantAttachmentKind
    public var relativePath: String?
    public var mediaType: String
    public var byteCount: Int64
    public var sha256: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        entryId: String,
        displayName: String,
        kind: StoredAssistantAttachmentKind,
        relativePath: String?,
        mediaType: String,
        byteCount: Int64,
        sha256: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.entryId = entryId
        self.displayName = displayName
        self.kind = kind
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
    }

    public enum Columns: String, ColumnExpression {
        case id, entryId, displayName, kind, relativePath, mediaType
        case byteCount, sha256, createdAt
    }
}

public struct StoredAssistantAttachmentPath: Codable, Hashable, Sendable {
    public var id: String
    public var conversationId: String
    public var relativePath: String

    public init(id: String, conversationId: String, relativePath: String) {
        self.id = id
        self.conversationId = conversationId
        self.relativePath = relativePath
    }
}

extension StoredAssistantAttachment: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        id = row[Columns.id]
        entryId = row[Columns.entryId]
        displayName = row[Columns.displayName]
        kind = StoredAssistantAttachmentKind(rawValue: row[Columns.kind])
        relativePath = row[Columns.relativePath]
        mediaType = row[Columns.mediaType]
        byteCount = row[Columns.byteCount]
        sha256 = row[Columns.sha256]
        createdAt = row[Columns.createdAt]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.entryId] = entryId
        container[Columns.displayName] = displayName
        container[Columns.kind] = kind.rawValue
        container[Columns.relativePath] = relativePath
        container[Columns.mediaType] = mediaType
        container[Columns.byteCount] = byteCount
        container[Columns.sha256] = sha256
        container[Columns.createdAt] = createdAt
    }
}

public struct AssistantSessionAlias: Codable, Hashable, Sendable {
    public static let databaseTableName = "assistantSessionAlias"

    public var keyHash: String
    public var conversationId: String?
    public var provider: AssistantProvider
    public var ownerRevision: Int
    public var recordedAt: Date

    public init(
        keyHash: String,
        conversationId: String?,
        provider: AssistantProvider,
        ownerRevision: Int = 1,
        recordedAt: Date = Date()
    ) {
        self.keyHash = keyHash
        self.conversationId = conversationId
        self.provider = provider
        self.ownerRevision = ownerRevision
        self.recordedAt = recordedAt
    }

    public enum Columns: String, ColumnExpression {
        case keyHash, conversationId, provider, ownerRevision, recordedAt
    }
}

extension AssistantSessionAlias: FetchableRecord, MutablePersistableRecord {
    public init(row: Row) {
        keyHash = row[Columns.keyHash]
        conversationId = row[Columns.conversationId]
        provider = AssistantProvider(rawValue: row[Columns.provider])
        ownerRevision = row[Columns.ownerRevision]
        recordedAt = row[Columns.recordedAt]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.keyHash] = keyHash
        container[Columns.conversationId] = conversationId
        container[Columns.provider] = provider.rawValue
        container[Columns.ownerRevision] = ownerRevision
        container[Columns.recordedAt] = recordedAt
    }
}

public enum AssistantSessionAliasSnapshot: Codable, Hashable, Sendable {
    case absent
    case live(conversationId: String, ownerRevision: Int)
    case tombstone(ownerRevision: Int)
}

public enum AssistantConversationImportResult: Codable, Hashable, Sendable {
    case imported(conversationId: String)
    case existing(conversationId: String)

    public var conversationId: String {
        switch self {
        case .imported(let conversationId), .existing(let conversationId):
            conversationId
        }
    }
}

/// Result of atomically resolving a migrated scheduled run before any provider
/// transcript request is made. Only `admitted` authorizes provider traffic.
public enum ScheduledAssistantImportAdmission: Codable, Hashable, Sendable {
    case admitted
    case existing(conversationId: String)
    case deletedLocally
    case notEligible(state: AssistantTranscriptState)
}

/// Terminal result of committing a migrated scheduled transcript. A concurrent
/// ordinary import may win the alias while the provider read is in flight; in
/// that case the scheduled run records the local owner instead of replacing it.
public enum ScheduledAssistantImportResult: Codable, Hashable, Sendable {
    case imported(conversationId: String)
    case existing(conversationId: String)
    case deletedLocally

    public var conversationId: String? {
        switch self {
        case let .imported(conversationId), let .existing(conversationId):
            conversationId
        case .deletedLocally:
            nil
        }
    }
}

public struct AssistantConversationSummary: Codable, Hashable, Sendable {
    public static let previewCharacterLimit = 240
    static let previewSourceCharacterLimit = 2_048

    public var conversation: AssistantConversation
    public var preview: String
    public var turnCount: Int

    public init(conversation: AssistantConversation, preview: String, turnCount: Int) {
        self.conversation = conversation
        self.preview = preview
        self.turnCount = turnCount
    }

    static func boundedPreview(_ raw: String) -> String {
        let normalized = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count > previewCharacterLimit else {
            return normalized
        }
        return String(normalized.prefix(previewCharacterLimit - 1)) + "…"
    }
}

public struct AssistantConversationQuery: Hashable, Sendable {
    public var workspaceIdentityHash: String?
    public var provider: AssistantProvider?
    public var contextKind: AssistantConversationContextKind?
    public var referenceId: Int64?
    public var search: String?
    public var includeArchived: Bool
    public var limit: Int

    public init(
        workspaceIdentityHash: String? = nil,
        provider: AssistantProvider? = nil,
        contextKind: AssistantConversationContextKind? = nil,
        referenceId: Int64? = nil,
        search: String? = nil,
        includeArchived: Bool = false,
        limit: Int = 50
    ) {
        self.workspaceIdentityHash = workspaceIdentityHash
        self.provider = provider
        self.contextKind = contextKind
        self.referenceId = referenceId
        self.search = search
        self.includeArchived = includeArchived
        self.limit = limit
    }
}

/// Opaque keyset position for reading older transcript entries.
///
/// The token is intentionally the only serialized representation so callers do
/// not take a dependency on the database ordering fields.
public struct AssistantTranscriptCursor: Hashable, Sendable {
    package let conversationID: String
    package let turnOrdinal: Int
    package let sequence: Int

    package init(
        conversationID: String,
        turnOrdinal: Int,
        sequence: Int
    ) {
        self.conversationID = conversationID
        self.turnOrdinal = turnOrdinal
        self.sequence = sequence
    }

    public init?(token: String) {
        guard token.count <= 4_096 else { return nil }
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.conversationID.isEmpty,
              payload.conversationID.count <= 512,
              payload.conversationID.trimmingCharacters(
                in: .whitespacesAndNewlines
              ) == payload.conversationID,
              payload.turnOrdinal >= 0,
              payload.sequence >= 0
        else {
            return nil
        }
        self.init(
            conversationID: payload.conversationID,
            turnOrdinal: payload.turnOrdinal,
            sequence: payload.sequence
        )
    }

    public var token: String {
        let payload = Payload(
            conversationID: conversationID,
            turnOrdinal: turnOrdinal,
            sequence: sequence
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            return ""
        }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct Payload: Codable {
        let conversationID: String
        let turnOrdinal: Int
        let sequence: Int
    }
}

extension AssistantTranscriptCursor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let token = try container.decode(String.self)
        guard let cursor = Self(token: token) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Assistant transcript cursor."
            )
        }
        self = cursor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

public struct AssistantConversationDetail: Codable, Hashable, Sendable {
    public static let defaultPageLimit = 200
    public static let maximumPageLimit = 500

    public var conversation: AssistantConversation
    public var turns: [AssistantTurn]
    public var entries: [AssistantTranscriptEntry]
    public var attachments: [StoredAssistantAttachment]
    public var olderCursor: AssistantTranscriptCursor?

    public init(
        conversation: AssistantConversation,
        turns: [AssistantTurn],
        entries: [AssistantTranscriptEntry],
        attachments: [StoredAssistantAttachment],
        olderCursor: AssistantTranscriptCursor? = nil
    ) {
        self.conversation = conversation
        self.turns = turns
        self.entries = entries
        self.attachments = attachments
        self.olderCursor = olderCursor
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, turns, entries, attachments, olderCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try container.decode(
            AssistantConversation.self,
            forKey: .conversation
        )
        turns = try container.decode([AssistantTurn].self, forKey: .turns)
        entries = try container.decode(
            [AssistantTranscriptEntry].self,
            forKey: .entries
        )
        attachments = try container.decode(
            [StoredAssistantAttachment].self,
            forKey: .attachments
        )
        olderCursor = try container.decodeIfPresent(
            AssistantTranscriptCursor.self,
            forKey: .olderCursor
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(turns, forKey: .turns)
        try container.encode(entries, forKey: .entries)
        try container.encode(attachments, forKey: .attachments)
        if let olderCursor {
            try container.encode(olderCursor, forKey: .olderCursor)
        } else {
            try container.encodeNil(forKey: .olderCursor)
        }
    }
}

public enum AssistantConversationError: Error, Equatable, LocalizedError {
    case notFound
    case invalidContext
    case invalidIdentifier
    case invalidOrdinal
    case invalidAttachment
    case activeConversation
    case aliasConflict
    case staleAliasSnapshot
    case staleSessionBinding
    case scheduledResultNotTerminal
    case continuationAlreadyTransferred
    case invalidTranscriptCursor

    public var errorDescription: String? {
        switch self {
        case .notFound: "The Assistant conversation could not be found."
        case .invalidContext: "The Assistant conversation context is invalid."
        case .invalidIdentifier: "The Assistant identifier is invalid."
        case .invalidOrdinal: "The Assistant transcript ordering is invalid."
        case .invalidAttachment: "The Assistant attachment metadata is invalid."
        case .activeConversation: "An active Assistant conversation cannot be deleted."
        case .aliasConflict: "That provider session already belongs to another local conversation."
        case .staleAliasSnapshot: "The provider session changed while its transcript was loading."
        case .staleSessionBinding: "A newer provider session binding already exists."
        case .scheduledResultNotTerminal: "The scheduled result is not ready to continue."
        case .continuationAlreadyTransferred: "This scheduled result already transferred its continuation."
        case .invalidTranscriptCursor:
            "The Assistant transcript cursor belongs to a different conversation."
        }
    }
}
