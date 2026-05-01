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

        case .referencePDF:
            guard let id = Int64(entityId) else { return nil }
            let row: Row? = try Row.fetchOne(db,
                sql: "SELECT * FROM pdfCache WHERE referenceId = ? AND materializedAt IS NOT NULL",
                arguments: [id])
            guard let row else { return nil }
            let filename: String = row["localFilename"]
            let assetURL = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: assetURL.path) else { return nil }
            // Resolve "pending" placeholders. The v2 migration backfilled
            // existing pdfPaths with contentHash='pending' (skipping the
            // hash to keep launch fast). Recompute on first push so peers
            // receive a real SHA-256 they can verify against, and persist
            // the result so subsequent pushes don't re-hash.
            // PDFContentHasher streams in 1 MB chunks — safe inside the
            // push transaction.
            var contentHash: String = row["contentHash"]
            if contentHash == "pending" {
                contentHash = try PDFContentHasher.sha256(of: assetURL)
                try db.execute(
                    sql: "UPDATE pdfCache SET contentHash = ? WHERE referenceId = ?",
                    arguments: [contentHash, id]
                )
            }
            let payload = ReferencePDFRecord(
                referenceId: id,
                assetURL: assetURL,
                assetVersion: row["assetVersion"],
                contentHash: contentHash,
                originalFilename: filename,
                // dateModified at push time = now. Per Task 10's reviewer:
                // don't reuse pdfCache.lastOpenedAt (that's a UX timestamp,
                // not content-version). assetVersion already handles
                // last-write-wins; dateModified is debug/tiebreaker only.
                dateModified: Date()
            )
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            payload.populate(record: record)
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
            // Reference no longer carries a PDF filename (B8). Per-device PDF
            // state lives in the local-only `pdfCache` table — never written
            // to a CKRecord, never touched by this apply path. The pdfCache
            // row for `id` (if any) survives unchanged because we only write
            // to `reference` here.
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

        case .referencePDF:
            guard let id = Int64(entityId), let payload = ReferencePDFRecord(record: record) else { return }
            // Mac always materializes. Copy CKAsset's downloaded file into our
            // PDFs/ dir under a UUID-prefixed name (mirrors PDFService.importPDF).
            // The CKAsset's fileURL is in CloudKit's caches and may be cleaned
            // up; copy promotes the bytes to permanent storage.
            guard let srcURL = payload.assetURL else { return }
            // Capture the previous localFilename so we can unlink it after the
            // upsert succeeds. Without this, an asset re-pull (assetVersion bump)
            // overwrites the row's filename pointer but leaves the old file
            // orphaned in PDFs/ forever.
            let previousFilename = try String.fetchOne(db,
                sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                arguments: [id])
            let localFilename = "\(UUID().uuidString)_\(payload.originalFilename)"
            let dest = AppDatabase.pdfStorageURL.appendingPathComponent(localFilename)
            try FileManager.default.createDirectory(at: AppDatabase.pdfStorageURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: srcURL, to: dest)
            // ON CONFLICT deliberately omits `lastOpenedAt = excluded.lastOpenedAt`
            // (differs from PDFAssetCache.materialize which DOES bump it).
            // Rationale: a remote pull is the cloud telling us new bytes exist,
            // not the user opening the file. Bumping lastOpenedAt here would
            // distort the LRU signal that drives eviction (deferred to iOS-port
            // plan but the column semantics need to stay clean now).
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(referenceId) DO UPDATE SET
                    localFilename = excluded.localFilename,
                    contentHash = excluded.contentHash,
                    assetVersion = excluded.assetVersion,
                    materializedAt = excluded.materializedAt
            """, arguments: [id, localFilename, payload.contentHash, payload.assetVersion, Date(), Date()])
            // Best-effort unlink of the prior file. Skip if same name (shouldn't
            // happen — new name is always UUID-prefixed) or already gone.
            if let previousFilename, previousFilename != localFilename {
                let oldURL = AppDatabase.pdfStorageURL.appendingPathComponent(previousFilename)
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
    }

    /// Apply a pulled deletion. Calls `DELETE` by key; FK cascades handle
    /// children. Safe if the row is already gone (no-op).
    public func applyRemoteDelete(entityId: String, db: Database) throws {
        switch self {
        case .reference:
            if let id = Int64(entityId) {
                // Capture the PDF filename before delete; FK cascade will drop
                // the pdfCache row, but the on-disk file in PDFs/ has no FK so
                // it would persist forever. Also clear any orphan syncState /
                // tombstone for the sibling referencePDF entityType — the
                // remote already authoritatively deleted the parent, no need
                // to push a tombstone back from this device.
                let pdfFilename = try String.fetchOne(db,
                    sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                    arguments: [id])
                _ = try Reference.deleteOne(db, key: id)
                if let pdfFilename {
                    let url = AppDatabase.pdfStorageURL.appendingPathComponent(pdfFilename)
                    try? FileManager.default.removeItem(at: url)
                }
                try db.execute(sql: """
                    DELETE FROM syncState WHERE entityType='referencePDF' AND entityId=?
                    """, arguments: [String(id)])
                try db.execute(sql: """
                    DELETE FROM tombstone WHERE entityType='referencePDF' AND entityId=?
                    """, arguments: [String(id)])
            }
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
        case .referencePDF:
            if let id = Int64(entityId) {
                // Capture filename before delete so we can also nuke the file.
                let filename = try String.fetchOne(db,
                    sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                    arguments: [id])
                try db.execute(sql: "DELETE FROM pdfCache WHERE referenceId = ?", arguments: [id])
                if let filename {
                    let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: url)
                }
            }
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
