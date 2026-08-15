#if canImport(CloudKit)
import Foundation
import CloudKit
import GRDB
import RubienCore

/// `DatabaseView` ↔ `CKRecord` mapping.
///
/// The four JSON blobs (scope, columns, filters, sorts, groupBy) travel as
/// String fields verbatim so a newer peer's shape additions aren't silently
/// dropped through a local decode + re-encode cycle. Scalars are stamped in
/// CloudKit-native types (Int64 for displayOrder, Int64 0/1 for isDefault).
extension DatabaseView {

    public enum RecordField {
        public static let syncId          = SyncRecordIdentity.syncIdField
        public static let name            = "name"
        public static let icon            = "icon"
        public static let scopeJSON       = "scopeJSON"
        public static let columnsJSON     = "columnsJSON"
        public static let filtersJSON     = "filtersJSON"
        public static let sortsJSON       = "sortsJSON"
        public static let groupByJSON     = "groupByJSON"
        public static let columnWrapsJSON = "columnWrapsJSON"
        public static let scopeSyncJSON       = "scopeSyncJSON"
        public static let filtersSyncJSON     = "filtersSyncJSON"
        public static let sortsSyncJSON       = "sortsSyncJSON"
        public static let groupBySyncJSON     = "groupBySyncJSON"
        public static let columnWrapsSyncJSON = "columnWrapsSyncJSON"
        public static let isDefault       = "isDefault"
        public static let displayOrder    = "displayOrder"
        public static let dateCreated     = "dateCreated"
        public static let dateModified    = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    public static let allFieldNames: [String] = [
        RecordField.syncId,
        RecordField.name,
        RecordField.icon,
        RecordField.scopeJSON,
        RecordField.columnsJSON,
        RecordField.filtersJSON,
        RecordField.sortsJSON,
        RecordField.groupByJSON,
        RecordField.columnWrapsJSON,
        RecordField.scopeSyncJSON,
        RecordField.filtersSyncJSON,
        RecordField.sortsSyncJSON,
        RecordField.groupBySyncJSON,
        RecordField.columnWrapsSyncJSON,
        RecordField.isDefault,
        RecordField.displayOrder,
        RecordField.dateCreated,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        SyncRecordIdentity.write(syncId, to: record)
        record[RecordField.name]            = name
        record[RecordField.icon]            = icon
        record[RecordField.scopeJSON]       = scopeJSON
        record[RecordField.columnsJSON]     = columnsJSON
        record[RecordField.filtersJSON]     = filtersJSON
        record[RecordField.sortsJSON]       = sortsJSON
        record[RecordField.groupByJSON]     = groupByJSON
        record[RecordField.columnWrapsJSON] = columnWrapsJSON
        record[RecordField.isDefault]       = isDefault ? Int64(1) : Int64(0)
        record[RecordField.displayOrder]    = Int64(displayOrder)
        record[RecordField.dateCreated]     = dateCreated
        record[RecordField.dateModified]    = dateModified
    }

    func populateForSync(record: CKRecord, db: Database) throws {
        let legacyFields = [
            RecordField.scopeJSON,
            RecordField.filtersJSON,
            RecordField.sortsJSON,
            RecordField.groupByJSON,
            RecordField.columnWrapsJSON,
        ]
        let priorLegacy = Dictionary(uniqueKeysWithValues: legacyFields.map {
            ($0, record[$0])
        })
        populate(record: record)

        let projection = try DatabaseViewPortableCodec.projection(
            for: self,
            db: db
        )
        record[RecordField.scopeSyncJSON] = projection.scope
        record[RecordField.filtersSyncJSON] = projection.filters
        record[RecordField.sortsSyncJSON] = projection.sorts
        record[RecordField.groupBySyncJSON] = projection.groupBy
        record[RecordField.columnWrapsSyncJSON] = projection.columnWraps

        if projection.legacyIsLossless {
            record[RecordField.scopeJSON] = projection.legacyScope
            record[RecordField.filtersJSON] = projection.legacyFilters
            record[RecordField.sortsJSON] = projection.legacySorts
            record[RecordField.groupByJSON] = projection.legacyGroupBy
            record[RecordField.columnWrapsJSON] = projection.legacyColumnWraps
        } else {
            for field in legacyFields {
                record[field] = priorLegacy[field] ?? nil
            }
        }
    }

    public static func makeRecord(
        recordName: String,
        view: DatabaseView
    ) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(
            recordType: SyncConstants.RecordType.databaseView,
            recordID: id
        )
        view.populate(record: record)
        return record
    }

    /// Non-failable decode. Missing JSON fields fall back to the library
    /// defaults so a partial record still yields a usable view. The
    /// memberwise init encodes defaults through the typed accessors; we then
    /// overwrite each `*JSON` field with the peer's wire string so any
    /// future-shape additions survive round-trip intact.
    public init(record: CKRecord) {
        self.init(
            syncId: SyncRecordIdentity.decodedSyncId(
                from: record,
                expectedType: .databaseView
            ),
            name: (record[RecordField.name] as? String) ?? "",
            icon: (record[RecordField.icon] as? String) ?? "tablecells",
            scope: .all,
            columns: ColumnConfig.defaultColumns,
            filters: [],
            sorts: [.defaultSort],
            groupBy: nil,
            isDefault: Self.decodeBool(record[RecordField.isDefault]),
            displayOrder: Int((record[RecordField.displayOrder] as? Int64) ?? 0),
            dateCreated: (record[RecordField.dateCreated] as? Date) ?? Date(),
            dateModified: (record[RecordField.dateModified] as? Date) ?? Date()
        )

        if let json = record[RecordField.scopeJSON]       as? String { self.scopeJSON = json }
        if let json = record[RecordField.columnsJSON]     as? String { self.columnsJSON = json }
        if let json = record[RecordField.filtersJSON]     as? String { self.filtersJSON = json }
        if let json = record[RecordField.sortsJSON]       as? String { self.sortsJSON = json }
        if let json = record[RecordField.columnWrapsJSON] as? String { self.columnWrapsJSON = json }
        // groupByJSON is optional in DB; only overwrite when the wire has it,
        // else preserve nil (no group-by).
        if let json = record[RecordField.groupByJSON]     as? String { self.groupByJSON = json }
    }

    private static func decodeBool(_ value: CKRecordValue?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int64 { return int != 0 }
        return false
    }
}
#endif
