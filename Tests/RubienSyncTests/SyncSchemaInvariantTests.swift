#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

/// THE BUG-CLASS DEFENSE.
///
/// On 2026-04-29 a routine launch of the signed app blanked `pdfPath` on every
/// Reference because the apply path wrote the full row from a CKRecord that
/// didn't carry pdfPath. Root cause shape: a synced table held a column the
/// CKRecord schema didn't carry; the apply path set it to nil; the GRDB UPDATE
/// wrote nil to the DB.
///
/// This test prevents that shape from recurring. For each `SyncEntityType`,
/// it diffs the synced table's persisted columns against the entity's
/// CKRecord field names. Any column on a synced table that isn't represented
/// in the CKRecord schema is a future blanking-bug waiting to happen.
///
/// Allowed exceptions live in `allowedExtraColumns`. The intent: this set is
/// EMPTY. If you find yourself adding a column here, ask whether the column
/// should be on a sibling local-only table instead (like `pdfCache` for
/// per-device PDF state).
final class SyncSchemaInvariantTests: XCTestCase {

    /// Per-table columns we explicitly allow to live on a synced table without
    /// matching CKRecord fields. This set MUST stay empty in mainline; a
    /// non-empty allow-list is acceptable only with a comment explaining why
    /// the column is auto-stamped or otherwise self-healing on apply.
    static let allowedExtraColumns: [String: Set<String>] = [:]

    /// Columns we never expect in CKRecord (they're SQL plumbing or computed).
    /// `id` is the local rowID — identity is in `CKRecord.recordName`.
    /// `authorsNormalized` is a computed Swift property recomputed on every
    /// encode of `authors`; storing it would round-trip stale data.
    static let neverInRecord: Set<String> = [
        "id",
        "authorsNormalized",
    ]

    func testEverySyncedColumnHasMatchingCKRecordField() throws {
        let db = try AppDatabase(DatabaseQueue())

        for entity in SyncEntityType.allCases {
            try assertSchemaSubset(entity: entity, db: db)
        }
    }

    private func assertSchemaSubset(entity: SyncEntityType, db: AppDatabase) throws {
        let tableName = entity.rawValue
        let columns: Set<String> = try db.dbWriter.read { db in
            let names: [String] = try Row.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info(?)",
                arguments: [tableName]
            ).map { $0["name"] as String }
            return Set(names)
        }
        guard !columns.isEmpty else {
            // No table for this entity (e.g. `.referencePDF` — its state is
            // built from the local-only `pdfCache` table at push time, never
            // a synced table itself). Nothing to diff.
            return
        }

        let fields: Set<String> = Set(allFieldNames(for: entity))
        let allowed: Set<String> = Self.allowedExtraColumns[tableName] ?? []

        let unexpected = columns
            .subtracting(fields)
            .subtracting(Self.neverInRecord)
            .subtracting(allowed)

        XCTAssertTrue(
            unexpected.isEmpty,
            """
            Synced table `\(tableName)` has columns not represented in its CKRecord
            schema: \(unexpected.sorted()).

            This is the shape of the 2026-04-29 pdfPath bug: on remote pull,
            applyRemoteRecord builds a model from the CKRecord (which lacks
            these columns), then row.update(db) writes nil to those columns.
            User data gets blanked silently.

            Fix one of:
              1) Add the column to the CKRecord schema (preferred when the
                 column is user-meaningful and should sync). Update the
                 entity's `RecordField`, `populate(record:)`, `init(record:)`,
                 and `allFieldNames`.
              2) Move the column to a dedicated local-only table that ISN'T
                 listed in syncedTables (the pdfCache pattern).
              3) Add the column to `SyncSchemaInvariantTests.allowedExtraColumns`
                 with a comment explaining why it's safe (e.g. auto-stamped by
                 a SQL default and self-healing on the next write). Strongly
                 discouraged.
            """
        )
    }

    /// Per-entity dispatch to the static `allFieldNames` declared on each
    /// CKRecord-mapping extension. Adding a new `SyncEntityType` case
    /// requires extending both `allFieldNames` on the new type and this
    /// switch — the compiler enforces the latter (exhaustive switch).
    private func allFieldNames(for entity: SyncEntityType) -> [String] {
        switch entity {
        case .reference:          return Reference.allFieldNames
        case .tag:                return Tag.allFieldNames
        case .referenceTag:       return ReferenceTag.allFieldNames
        case .pdfAnnotation:      return PDFAnnotationRecord.allFieldNames
        case .webAnnotation:      return WebAnnotationRecord.allFieldNames
        case .metadataIntake:     return MetadataIntake.allFieldNames
        case .metadataEvidence:   return MetadataEvidence.allFieldNames
        case .propertyDefinition: return PropertyDefinition.allFieldNames
        case .propertyValue:      return PropertyValue.allFieldNames
        case .databaseView:       return DatabaseView.allFieldNames
        case .readingActivity:    return ReadingActivity.allFieldNames
        case .assistantActivity:  return AssistantActivity.allFieldNames
        case .activityEpoch:      return ActivityEpoch.allFieldNames
        case .referencePDF:       return ReferencePDFRecord.allFieldNames
        }
    }
}
#endif
