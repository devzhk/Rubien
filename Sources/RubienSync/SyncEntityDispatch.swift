import Foundation
import GRDB
import CloudKit
import RubienCore

/// Per-entity glue for push and pull. Lives alongside `SyncEntityType` so the
/// actor's delegate methods stay thin — all "how do I decode a Reference
/// CKRecord into a DB row" knowledge is here.
///
/// Pre-A-pks conventions:
/// - For entities with an autoincrement Int64 PK, `entityId` is the
///   stringified rowID, so `Int64(entityId)` resolves to the local key.
/// - For the `referenceTag` pivot, `entityId` is `"refId/tagId"`; we split
///   and resolve both halves.
extension SyncEntityType {

    /// Compose the `"<type>:<entityId>"` CKRecord.recordName for a local row.
    /// Inverse of `parseRecordName`.
    public func qualifiedRecordName(entityId: String) -> String {
        "\(rawValue)\(SyncConstants.typeSeparator)\(entityId)"
    }

    /// Parse `"<type>:<entityId>"` back into a (type, entityId) pair.
    /// `entityId` may itself contain `:` in future schemes; we split on the
    /// first occurrence only. Returns nil if the prefix isn't a known type.
    public static func parseRecordName(_ recordName: String) -> (SyncEntityType, String)? {
        guard let separatorIdx = recordName.firstIndex(of: SyncConstants.typeSeparator) else {
            return nil
        }
        let typeRaw = String(recordName[..<separatorIdx])
        let entityId = String(recordName[recordName.index(after: separatorIdx)...])
        guard let type = SyncEntityType(rawValue: typeRaw) else { return nil }
        return (type, entityId)
    }

    /// Rehydrate a CKRecord suitable for pushing this row to the server.
    /// If we have cached system fields (i.e. we've synced before), rehydrate
    /// so the change-tag makes the save optimistic-concurrency-safe; else
    /// build a fresh record. Returns nil if the row has been locally
    /// deleted (the pending dirty flag is stale — the tombstone will carry
    /// the deletion on its own push).
    public func buildPushRecord(
        db: Database,
        entityId: String,
        systemFields: Data?
    ) throws -> CKRecord? {
        switch self {
        case .reference:
            guard let id = Int64(entityId),
                  let row = try Reference.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .tag:
            guard let id = Int64(entityId),
                  let row = try Tag.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .referenceTag:
            guard let (refId, tagId) = Self.splitPivotID(entityId),
                  let row = try ReferenceTag
                    .filter(Column("referenceId") == refId && Column("tagId") == tagId)
                    .fetchOne(db)
            else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .pdfAnnotation:
            guard let id = Int64(entityId),
                  let row = try PDFAnnotationRecord.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .webAnnotation:
            guard let id = Int64(entityId),
                  let row = try WebAnnotationRecord.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .metadataIntake:
            guard let id = Int64(entityId),
                  let row = try MetadataIntake.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .metadataEvidence:
            guard let id = Int64(entityId),
                  let row = try MetadataEvidence.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .propertyDefinition:
            guard let id = Int64(entityId),
                  let row = try PropertyDefinition.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .propertyValue:
            guard let id = Int64(entityId),
                  let row = try PropertyValue.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .databaseView:
            guard let id = Int64(entityId),
                  let row = try DatabaseView.fetchOne(db, key: id) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record
        }
    }

    /// Apply a pulled record to the local DB. Uses exists-then-branch
    /// (INSERT vs UPDATE) rather than `INSERT OR REPLACE` — the latter
    /// cascade-deletes children via FK, nuking annotations/tags/etc on
    /// every Reference round-trip.
    ///
    /// Caller's transaction must have set `applyingRemote` in `syncSession`
    /// so the triggers don't re-dirty the row we just wrote.
    public func applyRemoteRecord(_ record: CKRecord, entityId: String, db: Database) throws {
        // `entityId` is the caller-stripped local id (no "<type>:" prefix).
        // Don't read `record.recordID.recordName` directly — it carries the
        // prefixed form so `Int64(...)` would fail for every row.
        switch self {
        case .reference:
            guard let id = Int64(entityId) else { return }
            var row = Reference(record: record)
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .tag:
            guard let id = Int64(entityId) else { return }
            var row = Tag(record: record)
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .referenceTag:
            guard let pivot = ReferenceTag(record: record) else { return }
            // Pivot's only "fields" are its composite PK + dateModified, the
            // latter being schema-only. Insert-if-absent is enough — update
            // would be a no-op.
            let exists = try Bool.fetchOne(db, sql: """
                SELECT 1 FROM referenceTag WHERE referenceId = ? AND tagId = ? LIMIT 1
                """, arguments: [pivot.referenceId, pivot.tagId]) ?? false
            if !exists {
                try pivot.insert(db)
            }

        case .pdfAnnotation:
            guard let id = Int64(entityId), var row = PDFAnnotationRecord(record: record) else { return }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .webAnnotation:
            guard let id = Int64(entityId), var row = WebAnnotationRecord(record: record) else { return }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .metadataIntake:
            guard let id = Int64(entityId) else { return }
            var row = MetadataIntake(record: record)
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .metadataEvidence:
            guard let id = Int64(entityId), var row = MetadataEvidence(record: record) else { return }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .propertyDefinition:
            guard let id = Int64(entityId) else { return }
            var row = PropertyDefinition(record: record)
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .propertyValue:
            guard let id = Int64(entityId), var row = PropertyValue(record: record) else { return }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .databaseView:
            guard let id = Int64(entityId) else { return }
            var row = DatabaseView(record: record)
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }
        }
    }

    /// Apply a pulled deletion. Calls `DELETE` by key; FK cascades handle
    /// children. Safe if the row is already gone (no-op).
    public func applyRemoteDelete(entityId: String, db: Database) throws {
        switch self {
        case .reference:
            if let id = Int64(entityId) { _ = try Reference.deleteOne(db, key: id) }
        case .tag:
            if let id = Int64(entityId) { _ = try Tag.deleteOne(db, key: id) }
        case .referenceTag:
            guard let (refId, tagId) = Self.splitPivotID(entityId) else { return }
            try db.execute(
                sql: "DELETE FROM referenceTag WHERE referenceId = ? AND tagId = ?",
                arguments: [refId, tagId]
            )
        case .pdfAnnotation:
            if let id = Int64(entityId) { _ = try PDFAnnotationRecord.deleteOne(db, key: id) }
        case .webAnnotation:
            if let id = Int64(entityId) { _ = try WebAnnotationRecord.deleteOne(db, key: id) }
        case .metadataIntake:
            if let id = Int64(entityId) { _ = try MetadataIntake.deleteOne(db, key: id) }
        case .metadataEvidence:
            if let id = Int64(entityId) { _ = try MetadataEvidence.deleteOne(db, key: id) }
        case .propertyDefinition:
            if let id = Int64(entityId) { _ = try PropertyDefinition.deleteOne(db, key: id) }
        case .propertyValue:
            if let id = Int64(entityId) { _ = try PropertyValue.deleteOne(db, key: id) }
        case .databaseView:
            if let id = Int64(entityId) { _ = try DatabaseView.deleteOne(db, key: id) }
        }
    }

    // MARK: - Helpers

    private static func splitPivotID(_ entityId: String) -> (Int64, Int64)? {
        let parts = entityId.split(separator: Character(SyncConstants.pivotSeparator))
        guard parts.count == 2,
              let refId = Int64(parts[0]),
              let tagId = Int64(parts[1])
        else { return nil }
        return (refId, tagId)
    }

    /// Rehydrate the archived CKRecord if present AND its recordName matches
    /// the expected one, else build a fresh one. The recordName check
    /// handles the type-prefix migration: old cached `systemFields` carry
    /// the pre-prefix recordName (e.g. "1"), but we now need to push as
    /// "<type>:<id>" (e.g. "reference:1"). Rehydrating the stale one and
    /// pushing it would either revive the collision bug or get silently
    /// rejected. When the cached recordName mismatches, discard the
    /// change-tag (a fresh record is created server-side; the old one
    /// becomes orphaned). Post-migration pushes land correctly under
    /// the prefixed name.
    private static func rehydrateOrNew(
        systemFields: Data?,
        recordType: String,
        recordName: String
    ) -> CKRecord {
        if let data = systemFields,
           let rehydrated = SyncStateStore.rehydrateRecord(from: data),
           rehydrated.recordID.recordName == recordName {
            return rehydrated
        }
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        return CKRecord(recordType: recordType, recordID: id)
    }

    /// Table-agnostic UPSERT by primary key. `update` is invoked if a row
    /// with `id` exists; otherwise `insert` runs. Using closures keeps each
    /// call site's static type info intact (GRDB's `update`/`insert` need
    /// the concrete record type).
    ///
    /// The `row` parameter is unused at this level but keeping it in the
    /// signature makes call sites self-documenting — the exists-check is
    /// logically "does THIS row already exist" even though we look it up
    /// by id.
    private static func upsert<Row>(
        _ row: Row,
        id: Int64,
        tableName: String,
        db: Database,
        update: () throws -> Void,
        insert: () throws -> Void
    ) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM \(tableName) WHERE id = ? LIMIT 1",
            arguments: [id]
        ) ?? false
        if exists {
            try update()
        } else {
            try insert()
        }
    }
}
