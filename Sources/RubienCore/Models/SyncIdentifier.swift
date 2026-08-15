import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

/// Cross-platform identity primitives shared by the SQLite and CloudKit
/// layers. SQLite row IDs are deliberately absent from this API: callers
/// either preserve a proven legacy identity or allocate a globally unique
/// value here.
public enum SyncIdentifier {
    public static let typeSeparator: Character = ":"
    public static let compoundSeparator = "/"

    public static func random() -> String {
        UUID().uuidString.lowercased()
    }

    public static func isCanonicalDecimal(_ value: String) -> Bool {
        guard let parsed = Int64(value) else { return false }
        return String(parsed) == value
    }

    public static func qualifiedRecordName(
        entityType: String,
        entityId: String
    ) -> String {
        "\(entityType)\(typeSeparator)\(entityId)"
    }

    /// Permanent convergence rule for independently-created identities.
    /// Grandfathered decimal identities win so an existing CloudKit graph is
    /// never re-keyed merely because a fresh peer seeded the same logical row.
    public static func preferred(_ lhs: String, _ rhs: String) -> String {
        let lhsDecimal = Int64(lhs).flatMap { String($0) == lhs ? $0 : nil }
        let rhsDecimal = Int64(rhs).flatMap { String($0) == rhs ? $0 : nil }
        switch (lhsDecimal, rhsDecimal) {
        case let (.some(left), .some(right)):
            return left <= right ? lhs : rhs
        case (.some, .none):
            return lhs
        case (.none, .some):
            return rhs
        case (.none, .none):
            return lhs <= rhs ? lhs : rhs
        }
    }
}

/// Codable compatibility for models embedded in pre-v13 durable JSON. Swift's
/// synthesized `Decodable` does not honor stored-property defaults when a key
/// is absent, so these wrappers provide explicit missing-key fallbacks while
/// keeping the on-wire representation a plain string.
@propertyWrapper
public struct RandomSyncIdentifier: Codable, Hashable, Sendable {
    public var wrappedValue: String

    public init(wrappedValue: String = SyncIdentifier.random()) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

@propertyWrapper
public struct EmptySyncIdentifier: Codable, Hashable, Sendable {
    public var wrappedValue: String

    public init(wrappedValue: String = "") {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

public extension KeyedDecodingContainer {
    func decode(
        _ type: RandomSyncIdentifier.Type,
        forKey key: Key
    ) throws -> RandomSyncIdentifier {
        try decodeIfPresent(type, forKey: key) ?? RandomSyncIdentifier()
    }

    func decode(
        _ type: EmptySyncIdentifier.Type,
        forKey key: Key
    ) throws -> EmptySyncIdentifier {
        try decodeIfPresent(type, forKey: key) ?? EmptySyncIdentifier()
    }
}

/// Schema-level entity catalog used during the v13 migration. RubienSync's
/// richer dispatch enum builds on the same raw values after migration.
public enum SyncIdentityEntity: String, CaseIterable, Sendable {
    case reference
    case tag
    case referenceTag
    case pdfAnnotation
    case webAnnotation
    case metadataIntake
    case metadataEvidence
    case propertyDefinition
    case propertyValue
    case databaseView
    case readingActivity
    case assistantActivity
    case activityEpoch
    case referencePDF

    public var recordType: String {
        switch self {
        case .reference:          return "CDReference"
        case .tag:                return "CDTag"
        case .referenceTag:       return "CDReferenceTag"
        case .pdfAnnotation:      return "CDPDFAnnotation"
        case .webAnnotation:      return "CDWebAnnotation"
        case .metadataIntake:     return "CDMetadataIntake"
        case .metadataEvidence:   return "CDMetadataEvidence"
        case .propertyDefinition: return "CDPropertyDefinition"
        case .propertyValue:      return "CDPropertyValue"
        case .databaseView:       return "CDDatabaseView"
        case .readingActivity:    return "CDReadingActivity"
        case .assistantActivity:  return "CDAssistantActivity"
        case .activityEpoch:      return "CDActivityEpoch"
        case .referencePDF:       return "CDReferencePDF"
        }
    }

    public func qualifiedRecordName(entityId: String) -> String {
        SyncIdentifier.qualifiedRecordName(
            entityType: rawValue,
            entityId: entityId
        )
    }
}

public enum SyncIdentityMigrationError: LocalizedError, Equatable {
    case requiresAppleIdentityMigration(archivedRecordCount: Int)
    case identityArchiveClassificationFailed(total: Int, failed: Int)
    case databaseSchemaIsNewerThanThisBuild
    case invalidIdentityData(String)

    public var errorDescription: String? {
        switch self {
        case .requiresAppleIdentityMigration(let count):
            return "This CloudKit-backed library has \(count) archived sync record(s). Open it once with Rubien v13 on macOS before using it on Linux. No migration changes were made."
        case let .identityArchiveClassificationFailed(total, failed):
            return "Rubien could not safely classify \(failed) of \(total) archived sync records. The identity migration made no changes. Stay on v12, preserve the complete library backup, and report these counts."
        case .databaseSchemaIsNewerThanThisBuild:
            return "This library was opened by a newer Rubien version. Use that version or restore the complete matching library backup."
        case .invalidIdentityData(let detail):
            return "The library contains invalid sync identity data: \(detail)"
        }
    }
}

struct ArchivedSyncRecordIdentity: Equatable, Sendable {
    let recordType: String
    let recordName: String
}

enum ArchivedSyncRecordInspector {
    #if canImport(CloudKit)
    static let isAvailable = true

    static func inspect(_ data: Data) -> ArchivedSyncRecordIdentity? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        guard let record = CKRecord(coder: unarchiver) else { return nil }
        return ArchivedSyncRecordIdentity(
            recordType: record.recordType,
            recordName: record.recordID.recordName
        )
    }
    #else
    static let isAvailable = false

    static func inspect(_ data: Data) -> ArchivedSyncRecordIdentity? {
        nil
    }
    #endif
}
