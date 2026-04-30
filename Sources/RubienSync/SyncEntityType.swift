import Foundation

/// One case per synced entity. The rawValue matches the SQLite table name
/// (and therefore `syncState.entityType` / `tombstone.entityType`) so the
/// engine and the database agree on a single identifier string.
///
/// `recordType` maps to the CloudKit record type constant in
/// `SyncConstants.RecordType`. The `CD` prefix disambiguates the sync-layer
/// type name from the local model name during grep.
public enum SyncEntityType: String, CaseIterable, Sendable {
    case reference          = "reference"
    case tag                = "tag"
    case referenceTag       = "referenceTag"
    case pdfAnnotation      = "pdfAnnotation"
    case webAnnotation      = "webAnnotation"
    case metadataIntake     = "metadataIntake"
    case metadataEvidence   = "metadataEvidence"
    case propertyDefinition = "propertyDefinition"
    case propertyValue      = "propertyValue"
    case databaseView       = "databaseView"
    case referencePDF       = "referencePDF"

    /// The CKRecord type name this entity pushes as. Mirrors
    /// `SyncConstants.RecordType.*`.
    public var recordType: String {
        switch self {
        case .reference:          return SyncConstants.RecordType.reference
        case .tag:                return SyncConstants.RecordType.tag
        case .referenceTag:       return SyncConstants.RecordType.referenceTag
        case .pdfAnnotation:      return SyncConstants.RecordType.pdfAnnotation
        case .webAnnotation:      return SyncConstants.RecordType.webAnnotation
        case .metadataIntake:     return SyncConstants.RecordType.metadataIntake
        case .metadataEvidence:   return SyncConstants.RecordType.metadataEvidence
        case .propertyDefinition: return SyncConstants.RecordType.propertyDefinition
        case .propertyValue:      return SyncConstants.RecordType.propertyValue
        case .databaseView:       return SyncConstants.RecordType.databaseView
        case .referencePDF:       return SyncConstants.RecordType.referencePDF
        }
    }

    /// Topological order for applying pulled records in one transaction.
    /// Lower values have no FK dependencies; each subsequent tier depends
    /// (transitively) only on earlier tiers. Inside the same tier, rows
    /// don't FK each other.
    ///
    /// Usage: sort a batch of pulled records by this key ascending before
    /// upserting. Combined with `PRAGMA defer_foreign_keys = ON`, ordering
    /// keeps the intermediate state queryable without constraint violations
    /// surfacing until commit.
    public var fkDependencyRank: Int {
        switch self {
        // Tier 0: no local FK deps
        case .propertyDefinition, .databaseView:                  return 0
        // Tier 1: FK to a tier-0 or no local FK
        case .reference, .tag:                                    return 1
        // Tier 2: FK to reference and/or tag
        case .referenceTag, .pdfAnnotation, .webAnnotation:       return 2
        case .propertyValue:                                      return 2  // FK → reference + propertyDefinition
        case .metadataIntake:                                     return 2  // FK → reference (nullable)
        case .referencePDF:                                       return 2  // FK → reference (1:1 sibling)
        // Tier 3: FK to tier-2 / tier-1 (evidence FKs both intake + reference, nullable)
        case .metadataEvidence:                                   return 3
        }
    }

    /// Recover a `SyncEntityType` from a CKRecord's record type string.
    /// Returns nil for unknown types (e.g. sibling asset record or a
    /// record type a newer peer introduced). The sync engine logs +
    /// skips nil cases rather than crashing.
    public static func forRecordType(_ recordType: String) -> SyncEntityType? {
        SyncEntityType.allCases.first { $0.recordType == recordType }
    }
}
