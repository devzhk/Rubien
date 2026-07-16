#if canImport(CloudKit)
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

    /// Output of `prepareReferencePDFMaterialization`. Carries the bytes
    /// already on disk and the canonical `entityId` (`Int64`) parsed from
    /// `CKRecord.ID.recordName`. The wire payload's own `referenceId` is
    /// kept for scalar columns only — `entityId` is the DB key.
    struct PreparedReferencePDFMaterialization: Sendable {
        let entityId: Int64
        let payload: ReferencePDFRecord
        let stagedURL: URL
        let stagedFilename: String
    }

    /// Stage the CKAsset bytes onto disk under `PDFs/<UUID>_<originalFilename>`
    /// and return the metadata the apply step needs to upsert `pdfCache`.
    /// **No DB access.** Caller invokes this *before* opening the
    /// `dbWriter.write` transaction.
    ///
    /// Returns nil for:
    /// - records without an asset (`payload.assetURL == nil`)
    /// - records whose `recordName` doesn't parse as `referencePDF:<Int64>`
    ///
    /// On `copyItem` failure the partial staged file is removed before
    /// rethrowing so the PDFs/ dir doesn't accumulate orphans.
    static func prepareReferencePDFMaterialization(
        record: CKRecord
    ) throws -> PreparedReferencePDFMaterialization? {
        guard let (_, entityIdStr) = SyncEntityType.parseRecordName(record.recordID.recordName),
              let entityId = Int64(entityIdStr) else {
            return nil
        }
        guard let payload = ReferencePDFRecord(record: record),
              let srcURL = payload.assetURL else {
            return nil
        }
        let stagedFilename = "\(UUID().uuidString)_\(payload.originalFilename)"
        let stagedURL = AppDatabase.pdfStorageURL.appendingPathComponent(stagedFilename)
        try FileManager.default.createDirectory(
            at: AppDatabase.pdfStorageURL,
            withIntermediateDirectories: true
        )
        do {
            try FileManager.default.copyItem(at: srcURL, to: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        return PreparedReferencePDFMaterialization(
            entityId: entityId,
            payload: payload,
            stagedURL: stagedURL,
            stagedFilename: stagedFilename
        )
    }

    /// Run the small `pdfCache` upsert for a previously-prepared
    /// materialization. **No file I/O.** Returns the *previous*
    /// `localFilename` for this reference (if any), so the caller can unlink
    /// it post-commit — keeping that unlink off the writer queue too.
    ///
    /// Caller must have set `setApplyingRemote` in `syncSession` if other
    /// rows in the same transaction are synced tables; `pdfCache` itself is
    /// local-only (not in `syncedTables`) so its writes never fire dirty-
    /// tracking triggers, but the surrounding transaction often touches
    /// `reference` etc. which do.
    static func applyPreparedReferencePDF(
        _ prepared: PreparedReferencePDFMaterialization,
        db: Database
    ) throws -> String? {
        let id = prepared.entityId
        let previousFilename = try String.fetchOne(
            db,
            sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
            arguments: [id]
        )
        try db.execute(sql: """
            INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(referenceId) DO UPDATE SET
                localFilename = excluded.localFilename,
                contentHash = excluded.contentHash,
                assetVersion = excluded.assetVersion,
                materializedAt = excluded.materializedAt
        """, arguments: [
            id,
            prepared.stagedFilename,
            prepared.payload.contentHash,
            prepared.payload.assetVersion,
            Date(),
            Date(),
        ])
        if let previousFilename, previousFilename != prepared.stagedFilename {
            return previousFilename
        }
        return nil
    }

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

        case .readingActivity:
            guard let key = Self.splitReadingActivityID(entityId),
                  let row = try ReadingActivity.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM readingActivity
                        WHERE generation = ? AND installationId = ?
                          AND referenceId = ? AND localDay = ?
                        """,
                    arguments: [key.generation, key.installationId, key.referenceId, key.localDay]
                  )
            else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .assistantActivity:
            guard let row = try AssistantActivity.fetchOne(db, key: entityId) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .activityEpoch:
            guard let kind = ActivityKind(rawValue: entityId),
                  let row = try ActivityEpoch.fetchOne(db, key: kind.rawValue)
            else { return nil }
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
            // SAFETY NET — defense-in-depth only.
            //
            // Normal-path coverage:
            //   - migration backfill 'pending' rows: resolved at start()
            //     by SyncedLibrary.resolvePendingPDFContentHashes, BEFORE
            //     the engine is constructed;
            //   - freshly-imported 'pending' rows: resolved per-row by
            //     SyncedLibrary.drainPDFUploadQueueIntoSyncState, BEFORE
            //     the syncState dirty marker is written.
            //
            // Note: the early `guard FileManager.default.fileExists(...)
            // else { return nil }` above this block means this branch is
            // ALSO not reachable for rows whose local file has vanished —
            // the missing-file case returns nil before reaching the
            // 'pending' check. The only remaining reachability path is a
            // future code change that bypasses both resolver layers and
            // marks a 'pending' row dirty in syncState directly. Kept for
            // that defense-in-depth scenario only.
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
    /// Returns `true` if the record was applied/persisted (so the caller should
    /// `markPulled`), `false` if it was skipped — a malformed id/record, an
    /// empty-name tag, or a referencePDF with no materialization. A skipped
    /// record must NOT be `markPulled`: that would stamp the server's
    /// systemFields and clear `isDirty` on a row this device never synced,
    /// silently dropping a pending local edit.
    @discardableResult
    public func applyRemoteRecord(
        _ record: CKRecord,
        entityId: String,
        db: Database,
        stateStore: SyncStateStore = SyncStateStore()
    ) throws -> Bool {
        // `entityId` is the caller-stripped local id (no "<type>:" prefix).
        // Don't read `record.recordID.recordName` directly — it carries the
        // prefixed form so `Int64(...)` would fail for every row.
        switch self {
        case .reference:
            guard let id = Int64(entityId) else { return false }
            var row = Reference(record: record)
            row.id = id
            // Reference no longer carries a PDF filename (B8). Per-device PDF
            // state lives in the local-only `pdfCache` table — never written
            // to a CKRecord, never touched by this apply path. The pdfCache
            // row for `id` (if any) survives unchanged because we only write
            // to `reference` here.
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .tag:
            guard let id = Int64(entityId) else { return false }
            var row = Tag(record: record)
            row.id = id
            // Defense-in-depth: a missing/blank name decodes to "" (TagRecord) —
            // a malformed/forward-incompat record. Skip persistence (return false
            // → the caller skips markPulled, so we don't stamp server state on a
            // row we didn't apply) rather than upsert a "" that would itself trip
            // UNIQUE(name) and wedge a later batch.
            guard !row.name.isEmpty else { return false }
            // Reconcile a name collision the way `.propertyDefinition` does below,
            // but ADOPT THE INCOMING rowID. A local tag with the same name at a
            // different rowID (a peer's delete+recreate not yet applied here, or an
            // offline dual-create) makes the plain upsert throw UNIQUE(name) and
            // roll back the WHOLE fetched batch — silently wedging all sync on the
            // device. Unlike built-in PropertyDefinitions (which keep-local because
            // they carry no child rows), tags have `referenceTag` pivot children
            // and no stable secondary key, and the incoming fetch carries pivots
            // keyed to the INCOMING tagId — so we converge on the incoming rowID
            // and re-key the local pivots across.
            if let loserId = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tag WHERE name = ? AND id <> ? LIMIT 1",
                arguments: [row.name, id]
            ) {
                // Capture the loser's pivots (with their own dateModified, carried
                // through verbatim) before deleting them: in the delete-free apply
                // batch FK enforcement is OFF, so ON DELETE CASCADE does NOT fire —
                // this explicit cleanup is load-bearing.
                let pivots = try Row.fetchAll(
                    db,
                    sql: "SELECT referenceId, dateModified FROM referenceTag WHERE tagId = ?",
                    arguments: [loserId]
                )
                try db.execute(sql: "DELETE FROM referenceTag WHERE tagId = ?", arguments: [loserId])
                try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [loserId])  // frees the name
                // Triggers are suppressed under applyingRemote, so clear the loser's
                // stale bookkeeping by hand (tag + its pivots), else an orphan
                // syncState/tombstone keeps referencing the gone rowID.
                try db.execute(sql: "DELETE FROM syncState WHERE entityType = 'tag' AND entityId = ?", arguments: [String(loserId)])
                try db.execute(sql: "DELETE FROM tombstone WHERE entityType = 'tag' AND entityId = ?", arguments: [String(loserId)])
                try db.execute(sql: "DELETE FROM syncState WHERE entityType = 'referenceTag' AND entityId LIKE ?", arguments: ["%\(SyncConstants.pivotSeparator)\(loserId)"])
                try db.execute(sql: "DELETE FROM tombstone WHERE entityType = 'referenceTag' AND entityId LIKE ?", arguments: ["%\(SyncConstants.pivotSeparator)\(loserId)"])
                // Land the incoming tag at its rowID. UPDATE if that rowID is
                // already occupied by an unrelated tag (Option A: overwrite it —
                // the same outcome the plain-rowID upsert already produces on any
                // rowID collision; the occupant's own pivots survive and silently
                // re-label, the deferred A-pks bystander cost), else INSERT.
                try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }
                // Re-key the loser's pivots onto the incoming rowID, preserving each
                // pivot's own dateModified. INSERT OR IGNORE in case a reference
                // already carries it (UNIQUE PK). These re-keyed rows are LOCAL
                // truth the device must push, but the dirty-tracking trigger is
                // suppressed under applyingRemote — so dirty each one by hand, else
                // the association never propagates and is lost on other devices.
                for pivot in pivots {
                    let refId: Int64 = pivot["referenceId"]
                    let pivotDate: DatabaseValue = pivot["dateModified"]
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO referenceTag (referenceId, tagId, dateModified) VALUES (?, ?, ?)",
                        arguments: [refId, id, pivotDate]
                    )
                    try db.execute(
                        sql: """
                            INSERT INTO syncState (entityType, entityId, isDirty) VALUES ('referenceTag', ?, 1)
                                ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty = 1
                            """,
                        arguments: [ReferenceTag.recordName(referenceId: refId, tagId: id)]
                    )
                }
                return true
            }
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .referenceTag:
            guard let pivot = ReferenceTag(record: record) else { return false }
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
            guard let id = Int64(entityId), var row = PDFAnnotationRecord(record: record) else { return false }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .webAnnotation:
            guard let id = Int64(entityId), var row = WebAnnotationRecord(record: record) else { return false }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .metadataIntake:
            guard let id = Int64(entityId) else { return false }
            var row = MetadataIntake(record: record)
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .metadataEvidence:
            guard let id = Int64(entityId), var row = MetadataEvidence(record: record) else { return false }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .propertyDefinition:
            guard let id = Int64(entityId) else { return false }
            var row = PropertyDefinition(record: record)
            // Built-in PropertyDefinitions (defaultFieldKey != nil) are seeded
            // independently on every device, so their rowIDs diverge ("Last
            // Read" is id 29 on a fresh library, 339 on an older one). Syncing
            // them by rowID makes this INSERT collide on UNIQUE(name) and the
            // whole fetched batch rolls back. Reconcile by the stable
            // defaultFieldKey instead: update the local seeded row in place,
            // keeping its rowID. Safe because the only divergent built-ins
            // (Last Read/Read Count, date/number) carry no propertyValues; the
            // rest (ids 1-28) have matching rowIDs across devices. Custom defs
            // (nil defaultFieldKey, e.g. Method/Modality) keep the rowID upsert
            // below. Targeted stand-in until the A-pks migration gives seeded
            // rows deterministic UUIDs (see PropertyDefinitionRecord.swift).
            if let fieldKey = row.defaultFieldKey,
               let localId = try Int64.fetchOne(
                   db,
                   sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey = ? LIMIT 1",
                   arguments: [fieldKey]
               ) {
                row.id = localId
                // A defaultFieldKey-bearing row IS a built-in. `isDefault` is a
                // synced/mutable field, so never write the peer's value verbatim:
                // a stray isDefault=0 would make the built-in deletable and break
                // the next reconcile. Force it true.
                row.isDefault = true
                // Type built-in: never let a peer's options list drop enum-backed
                // options (an old peer pushes six options → "Markdown" would vanish
                // and the v6 migration never reruns). Heal structurally (unknown JSON
                // fields preserved); the applyingRemote guard already active during
                // pulls keeps this from dirtying the record — every device heals
                // itself, no push-back churn.
                if fieldKey == "referenceType" {
                    if let healed = TypeOptionsReconciler.appendingMissingTypeOptions(toOptionsJSON: row.optionsJSON) {
                        row.optionsJSON = healed
                    } else if let localOptions = try String.fetchOne(
                        db,
                        sql: "SELECT optionsJSON FROM propertyDefinition WHERE id = ? LIMIT 1",
                        arguments: [localId]
                    ) {
                        // Incoming optionsJSON is malformed (reconciler contract: nil = leave the
                        // stored value untouched). Never overwrite the valid local option list
                        // with a peer's garbage — keep local.
                        row.optionsJSON = localOptions
                    }
                }
                try row.update(db)
            } else {
                row.id = id
                try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }
            }

        case .propertyValue:
            guard let id = Int64(entityId), var row = PropertyValue(record: record) else { return false }
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .databaseView:
            guard let id = Int64(entityId) else { return false }
            var row = DatabaseView(record: record)
            row.id = id
            try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }

        case .readingActivity:
            guard let row = ReadingActivity(record: record),
                  row.entityId == entityId
            else { return false }
            if try Reference.fetchOne(db, id: row.referenceId) == nil,
               try stateStore.hasTombstone(
                    db,
                    entityType: .reference,
                    entityId: String(row.referenceId)
               )
            {
                try Self.queueActivityDeletion(
                    type: .readingActivity,
                    entityId: entityId,
                    recordName: record.recordID.recordName,
                    stateStore: stateStore,
                    db: db
                )
                return false
            }
            guard try Self.activityFactCanApply(
                kind: .reading,
                epochRevision: row.epochRevision,
                generation: row.generation,
                referenceId: row.referenceId,
                db: db
            ) else {
                try Self.quarantine(row, recordName: record.recordID.recordName, db: db)
                return true
            }
            let localSeconds = try Int64.fetchOne(
                db,
                sql: """
                    SELECT activeSeconds FROM readingActivity
                    WHERE generation = ? AND installationId = ?
                      AND referenceId = ? AND localDay = ?
                    """,
                arguments: [row.generation, row.installationId, row.referenceId, row.localDay]
            )
            try Self.upsertReadingActivity(row, db: db)
            if let localSeconds, localSeconds > row.activeSeconds {
                try stateStore.adoptSystemFieldsKeepingDirty(
                    db,
                    entityType: .readingActivity,
                    entityId: entityId,
                    record: record
                )
                return false
            }

        case .assistantActivity:
            guard let row = AssistantActivity(record: record, id: entityId) else { return false }
            guard try Self.activityFactCanApply(
                kind: .assistant,
                epochRevision: row.epochRevision,
                generation: row.generation,
                referenceId: nil,
                db: db
            ) else {
                try Self.quarantine(row, recordName: record.recordID.recordName, db: db)
                return true
            }
            try Self.upsertAssistantActivity(row, db: db)

        case .activityEpoch:
            guard let incoming = ActivityEpoch(record: record),
                  incoming.kind.rawValue == entityId,
                  let local = try ActivityEpoch.fetchOne(db, key: incoming.kind.rawValue)
            else { return false }

            if let pending = try ActivityPendingClear.fetchOne(db, key: incoming.kind.rawValue) {
                if pending.revision == incoming.revision,
                   pending.generation == incoming.generation
                {
                    try incoming.update(db)
                    _ = try ActivityPendingClear.deleteOne(db, key: incoming.kind.rawValue)
                    try Self.replayQuarantinedActivity(
                        epochKinds: Set([incoming.kind]),
                        db: db
                    )
                    return true
                }

                if incoming.revision >= pending.revision {
                    try Self.rebasePendingClear(
                        pending,
                        over: incoming,
                        serverRecord: record,
                        stateStore: stateStore,
                        db: db
                    )
                } else {
                    // Our Lamport revision already dominates this server value.
                    // Keep the intent/pair, but adopt the current change tag so
                    // the retry updates the existing stable epoch record.
                    try stateStore.adoptSystemFieldsKeepingDirty(
                        db,
                        entityType: .activityEpoch,
                        entityId: incoming.kind.rawValue,
                        record: record
                    )
                }
                return false
            }

            let incomingWins = incoming.revision > local.revision
                || (incoming.revision == local.revision && incoming.generation > local.generation)
            let samePair = incoming.revision == local.revision
                && incoming.generation == local.generation
            guard incomingWins || samePair else {
                try stateStore.adoptSystemFieldsKeepingDirty(
                    db,
                    entityType: .activityEpoch,
                    entityId: incoming.kind.rawValue,
                    record: record
                )
                return false
            }
            try incoming.update(db)
            try Self.replayQuarantinedActivity(
                epochKinds: Set([incoming.kind]),
                db: db
            )

        case .referencePDF:
            // Backwards-compat wrapper around the two-step pipeline.
            // Production hot paths drive prepare/apply directly so the file
            // copy stays out of the write transaction; this wrapper exists
            // only for the SyncEntityDispatchTests call sites that still
            // exercise the single-shot signature.
            guard let prepared = try Self.prepareReferencePDFMaterialization(record: record) else {
                return false
            }
            let previousFilename = try Self.applyPreparedReferencePDF(prepared, db: db)
            if let previousFilename {
                let oldURL = AppDatabase.pdfStorageURL.appendingPathComponent(previousFilename)
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        return true
    }

    /// Apply a pulled deletion. Calls `DELETE` by key; FK cascades handle
    /// children. Safe if the row is already gone (no-op).
    public func applyRemoteDelete(entityId: String, db: Database) throws {
        switch self {
        case .reference:
            if let id = Int64(entityId) {
                let stateStore = SyncStateStore()
                let materializedActivityIDs = try ReadingActivity.fetchAll(
                    db,
                    sql: "SELECT * FROM readingActivity WHERE referenceId = ?",
                    arguments: [id]
                ).map(\.entityId)
                let quarantinedRecordNames = try String.fetchAll(
                    db,
                    sql: """
                        SELECT recordName FROM activityQuarantine
                        WHERE entityType = 'readingActivity' AND referenceId = ?
                        """,
                    arguments: [id]
                )
                var childEntityIDs = Set(materializedActivityIDs)
                for recordName in quarantinedRecordNames {
                    if let parsed = SyncEntityType.parseRecordName(recordName),
                       parsed.0 == .readingActivity
                    {
                        childEntityIDs.insert(parsed.1)
                    }
                }
                for childID in childEntityIDs {
                    try stateStore.removeState(
                        db,
                        entityType: .readingActivity,
                        entityId: childID
                    )
                    try stateStore.upsertTombstone(
                        db,
                        entityType: .readingActivity,
                        entityId: childID,
                        confirmedByServer: false
                    )
                }
                try db.execute(
                    sql: """
                        DELETE FROM activityQuarantine
                        WHERE entityType = 'readingActivity' AND referenceId = ?
                        """,
                    arguments: [id]
                )
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
            if let id = Int64(entityId) {
                // Never honor a remote delete against a local built-in. Built-ins
                // are seeded + delete-protected on every device
                // (deletePropertyDefinition guards isDefault), and reconcile keeps
                // them at divergent local rowIDs, so a delete keyed on a peer's
                // built-in rowID must not drop whatever sits at that id locally.
                // Custom props (isDefault=0) delete normally.
                let isLocalDefault = try Bool.fetchOne(
                    db,
                    sql: "SELECT isDefault FROM propertyDefinition WHERE id = ? LIMIT 1",
                    arguments: [id]
                ) ?? false
                guard !isLocalDefault else { return }
                _ = try PropertyDefinition.deleteOne(db, key: id)
            }
        case .propertyValue:
            if let id = Int64(entityId) { _ = try PropertyValue.deleteOne(db, key: id) }
        case .databaseView:
            if let id = Int64(entityId) { _ = try DatabaseView.deleteOne(db, key: id) }
        case .readingActivity:
            if let key = Self.splitReadingActivityID(entityId) {
                try db.execute(
                    sql: """
                        DELETE FROM readingActivity
                        WHERE generation = ? AND installationId = ?
                          AND referenceId = ? AND localDay = ?
                        """,
                    arguments: [key.generation, key.installationId, key.referenceId, key.localDay]
                )
                try db.execute(
                    sql: "DELETE FROM activityQuarantine WHERE recordName = ?",
                    arguments: [qualifiedRecordName(entityId: entityId)]
                )
            }
        case .assistantActivity:
            _ = try AssistantActivity.deleteOne(db, key: entityId)
            try db.execute(
                sql: "DELETE FROM activityQuarantine WHERE recordName = ?",
                arguments: [qualifiedRecordName(entityId: entityId)]
            )
        case .activityEpoch:
            // Epoch rows are durable reset fences and are never removed.
            break
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

    private static func splitReadingActivityID(
        _ entityId: String
    ) -> (generation: String, installationId: String, referenceId: Int64, localDay: LocalDay)? {
        let parts = entityId.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              let referenceId = Int64(parts[2]),
              let localDay = LocalDay(rawValue: String(parts[3]))
        else { return nil }
        return (String(parts[0]), String(parts[1]), referenceId, localDay)
    }

    private static func activityFactCanApply(
        kind: ActivityKind,
        epochRevision: Int,
        generation: String,
        referenceId: Int64?,
        db: Database
    ) throws -> Bool {
        guard let epoch = try ActivityEpoch.fetchOne(db, key: kind.rawValue),
              epoch.revision == epochRevision,
              epoch.generation == generation
        else { return false }
        if let referenceId {
            return try Reference.fetchOne(db, id: referenceId) != nil
        }
        return true
    }

    /// Facts from a locally-cleared generation stay off CloudKit until the
    /// stable epoch record has been saved/pulled and its exact pair is clean.
    /// Returning false from the CKSyncEngine batch provider is safe because the
    /// durable dirty row remains; the epoch acknowledgement transaction wakes
    /// ingestion and re-enqueues it.
    func activityFactIsPushEligible(db: Database, entityId: String) throws -> Bool {
        let kind: ActivityKind
        let revision: Int
        let generation: String
        switch self {
        case .readingActivity:
            guard let key = Self.splitReadingActivityID(entityId),
                  let row = try ReadingActivity.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM readingActivity
                        WHERE generation = ? AND installationId = ?
                          AND referenceId = ? AND localDay = ?
                        """,
                    arguments: [key.generation, key.installationId, key.referenceId, key.localDay]
                  )
            else { return false }
            kind = .reading
            revision = row.epochRevision
            generation = row.generation
        case .assistantActivity:
            guard let row = try AssistantActivity.fetchOne(db, key: entityId) else { return false }
            kind = .assistant
            revision = row.epochRevision
            generation = row.generation
        default:
            return true
        }

        guard try ActivityPendingClear.fetchOne(db, key: kind.rawValue) == nil,
              let epoch = try ActivityEpoch.fetchOne(db, key: kind.rawValue),
              epoch.revision == revision,
              epoch.generation == generation
        else { return false }

        return try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM syncState
                    WHERE entityType = 'activityEpoch' AND entityId = ?
                      AND isDirty = 0 AND systemFields IS NOT NULL
                )
                """,
            arguments: [kind.rawValue]
        ) ?? false
    }

    private static func rebasePendingClear(
        _ pending: ActivityPendingClear,
        over incoming: ActivityEpoch,
        serverRecord: CKRecord,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        let oldRevision = pending.revision
        let oldGeneration = pending.generation
        let nextRevision = max(oldRevision, incoming.revision) + 1
        let nextGeneration = UUID().uuidString.lowercased()
        let now = Date()

        switch pending.kind {
        case .reading:
            let rows = try ReadingActivity.fetchAll(
                db,
                sql: """
                    SELECT * FROM readingActivity
                    WHERE epochRevision = ? AND generation = ?
                    """,
                arguments: [oldRevision, oldGeneration]
            )
            try db.execute(
                sql: """
                    UPDATE readingActivity
                    SET epochRevision = ?, generation = ?, dateModified = ?
                    WHERE epochRevision = ? AND generation = ?
                    """,
                arguments: [nextRevision, nextGeneration, now, oldRevision, oldGeneration]
            )
            for row in rows {
                let oldID = row.entityId
                let newID = "\(nextGeneration)/\(row.installationId)/\(row.referenceId)/\(row.localDay.rawValue)"
                try stateStore.removeState(db, entityType: .readingActivity, entityId: oldID)
                try stateStore.removeTombstone(db, entityType: .readingActivity, entityId: oldID)
                try db.execute(
                    sql: """
                        INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                        VALUES('readingActivity', ?, 1, 0)
                        ON CONFLICT(entityType, entityId)
                            DO UPDATE SET isDirty = 1, pushInFlight = 0
                        """,
                    arguments: [newID]
                )
            }

        case .assistant:
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM assistantActivity
                    WHERE epochRevision = ? AND generation = ?
                    """,
                arguments: [oldRevision, oldGeneration]
            )
            try db.execute(
                sql: """
                    UPDATE assistantActivity
                    SET epochRevision = ?, generation = ?, dateModified = ?
                    WHERE epochRevision = ? AND generation = ?
                    """,
                arguments: [nextRevision, nextGeneration, now, oldRevision, oldGeneration]
            )
            for id in ids {
                try db.execute(
                    sql: """
                        INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                        VALUES('assistantActivity', ?, 1, 0)
                        ON CONFLICT(entityType, entityId)
                            DO UPDATE SET isDirty = 1, pushInFlight = 0
                        """,
                    arguments: [id]
                )
            }
        }

        var rebasedEpoch = ActivityEpoch(
            kind: pending.kind,
            revision: nextRevision,
            generation: nextGeneration,
            resetAt: pending.resetAt,
            dateModified: now
        )
        try rebasedEpoch.update(db)

        var rebasedPending = pending
        rebasedPending.revision = nextRevision
        rebasedPending.generation = nextGeneration
        rebasedPending.dateModified = now
        try rebasedPending.update(db)

        try stateStore.adoptSystemFieldsKeepingDirty(
            db,
            entityType: .activityEpoch,
            entityId: pending.kind.rawValue,
            record: serverRecord
        )
    }

    static func queueActivityDeletion(
        type: SyncEntityType,
        entityId: String,
        recordName: String,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM activityQuarantine WHERE recordName = ?",
            arguments: [recordName]
        )
        try stateStore.removeState(db, entityType: type, entityId: entityId)
        try stateStore.upsertTombstone(
            db,
            entityType: type,
            entityId: entityId,
            confirmedByServer: false
        )
    }

    static func reconcileActivityQuarantineAfterFetch(
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        try replayQuarantinedActivity(all: true, db: db)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM activityQuarantine ORDER BY receivedAt"
        )
        let decoder = JSONDecoder()

        for row in rows {
            let recordName: String = row["recordName"]
            guard let (type, entityId) = SyncEntityType.parseRecordName(recordName),
                  type == .readingActivity || type == .assistantActivity
            else {
                try db.execute(
                    sql: "DELETE FROM activityQuarantine WHERE recordName = ?",
                    arguments: [recordName]
                )
                continue
            }

            let data: Data = row["recordData"]
            let kind: ActivityKind
            let revision: Int
            let generation: String
            if type == .readingActivity {
                guard let activity = try? decoder.decode(ReadingActivity.self, from: data) else {
                    try queueActivityDeletion(
                        type: type,
                        entityId: entityId,
                        recordName: recordName,
                        stateStore: stateStore,
                        db: db
                    )
                    continue
                }
                if try Reference.fetchOne(db, id: activity.referenceId) == nil {
                    // didFetchRecordZoneChanges is the end-of-zone boundary:
                    // a parent still absent now is permanent for this fetch.
                    try queueActivityDeletion(
                        type: type,
                        entityId: entityId,
                        recordName: recordName,
                        stateStore: stateStore,
                        db: db
                    )
                    continue
                }
                kind = .reading
                revision = activity.epochRevision
                generation = activity.generation
            } else {
                guard let activity = try? decoder.decode(AssistantActivity.self, from: data) else {
                    try queueActivityDeletion(
                        type: type,
                        entityId: entityId,
                        recordName: recordName,
                        stateStore: stateStore,
                        db: db
                    )
                    continue
                }
                kind = .assistant
                revision = activity.epochRevision
                generation = activity.generation
            }

            guard try ActivityPendingClear.fetchOne(db, key: kind.rawValue) == nil,
                  let epoch = try ActivityEpoch.fetchOne(db, key: kind.rawValue),
                  try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM syncState
                            WHERE entityType = 'activityEpoch' AND entityId = ?
                              AND isDirty = 0 AND systemFields IS NOT NULL
                        )
                        """,
                    arguments: [kind.rawValue]
                  ) == true
            else { continue }

            let isLosingPair = revision < epoch.revision
                || (revision == epoch.revision && generation != epoch.generation)
            if isLosingPair {
                try queueActivityDeletion(
                    type: type,
                    entityId: entityId,
                    recordName: recordName,
                    stateStore: stateStore,
                    db: db
                )
            }
        }
    }

    private static func upsertReadingActivity(_ row: ReadingActivity, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO readingActivity
                    (installationId, referenceId, localDay, epochRevision, generation,
                     activeSeconds, lastActiveAt, dateModified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(generation, installationId, referenceId, localDay)
                DO UPDATE SET
                    epochRevision = MAX(readingActivity.epochRevision, excluded.epochRevision),
                    activeSeconds = MAX(readingActivity.activeSeconds, excluded.activeSeconds),
                    lastActiveAt = MAX(readingActivity.lastActiveAt, excluded.lastActiveAt),
                    dateModified = MAX(readingActivity.dateModified, excluded.dateModified)
                """,
            arguments: [
                row.installationId, row.referenceId, row.localDay, row.epochRevision,
                row.generation, row.activeSeconds, row.lastActiveAt, row.dateModified,
            ]
        )
    }

    private static func upsertAssistantActivity(_ row: AssistantActivity, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO assistantActivity
                    (id, provider, epochRevision, generation, startedAt, localDay, dateModified)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider = CASE WHEN excluded.dateModified >= assistantActivity.dateModified
                                    THEN excluded.provider ELSE assistantActivity.provider END,
                    epochRevision = CASE WHEN excluded.dateModified >= assistantActivity.dateModified
                                         THEN excluded.epochRevision ELSE assistantActivity.epochRevision END,
                    generation = CASE WHEN excluded.dateModified >= assistantActivity.dateModified
                                      THEN excluded.generation ELSE assistantActivity.generation END,
                    startedAt = MIN(assistantActivity.startedAt, excluded.startedAt),
                    localDay = CASE WHEN excluded.dateModified >= assistantActivity.dateModified
                                    THEN excluded.localDay ELSE assistantActivity.localDay END,
                    dateModified = MAX(assistantActivity.dateModified, excluded.dateModified)
                """,
            arguments: [
                row.id, row.provider, row.epochRevision, row.generation,
                row.startedAt, row.localDay, row.dateModified,
            ]
        )
    }

    private static func quarantine(
        _ row: ReadingActivity,
        recordName: String,
        db: Database
    ) throws {
        let reason = try Reference.fetchOne(db, id: row.referenceId) == nil ? "reference" : "epoch"
        try storeQuarantine(
            recordName: recordName,
            entityType: SyncEntityType.readingActivity.rawValue,
            reason: reason,
            epochRevision: row.epochRevision,
            generation: row.generation,
            referenceId: row.referenceId,
            data: try JSONEncoder().encode(row),
            db: db
        )
    }

    private static func quarantine(
        _ row: AssistantActivity,
        recordName: String,
        db: Database
    ) throws {
        try storeQuarantine(
            recordName: recordName,
            entityType: SyncEntityType.assistantActivity.rawValue,
            reason: "epoch",
            epochRevision: row.epochRevision,
            generation: row.generation,
            referenceId: nil,
            data: try JSONEncoder().encode(row),
            db: db
        )
    }

    private static func storeQuarantine(
        recordName: String,
        entityType: String,
        reason: String,
        epochRevision: Int,
        generation: String,
        referenceId: Int64?,
        data: Data,
        db: Database
    ) throws {
        guard data.count <= 64 * 1024 else { return }
        try db.execute(
            sql: """
                INSERT INTO activityQuarantine
                    (recordName, entityType, reason, epochRevision, generation,
                     referenceId, recordData, receivedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(recordName) DO UPDATE SET
                    entityType = excluded.entityType,
                    reason = excluded.reason,
                    epochRevision = excluded.epochRevision,
                    generation = excluded.generation,
                    referenceId = excluded.referenceId,
                    recordData = excluded.recordData,
                    receivedAt = excluded.receivedAt
                """,
            arguments: [
                recordName, entityType, reason, epochRevision, generation,
                referenceId, data, Date(),
            ]
        )
    }

    static func replayQuarantinedActivity(
        referenceIds: Set<Int64> = [],
        epochKinds: Set<ActivityKind> = [],
        all: Bool = false,
        db: Database
    ) throws {
        var rows: [Row] = []
        if all {
            rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM activityQuarantine ORDER BY receivedAt"
            )
        } else {
            if !referenceIds.isEmpty {
                let ids = referenceIds.sorted().map(String.init).joined(separator: ",")
                rows += try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM activityQuarantine
                        WHERE entityType = 'readingActivity'
                          AND referenceId IN (\(ids))
                        ORDER BY receivedAt
                        """
                )
            }
            if epochKinds.contains(.reading) {
                rows += try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM activityQuarantine
                        WHERE entityType = 'readingActivity'
                        ORDER BY receivedAt
                        """
                )
            }
            if epochKinds.contains(.assistant) {
                rows += try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM activityQuarantine
                        WHERE entityType = 'assistantActivity'
                        ORDER BY receivedAt
                        """
                )
            }
        }

        let decoder = JSONDecoder()
        var seen = Set<String>()
        for quarantined in rows {
            let recordName: String = quarantined["recordName"]
            guard seen.insert(recordName).inserted else { continue }
            let entityType: String = quarantined["entityType"]
            let data: Data = quarantined["recordData"]
            let didApply: Bool
            switch SyncEntityType(rawValue: entityType) {
            case .readingActivity:
                guard let activity = try? decoder.decode(ReadingActivity.self, from: data)
                else { continue }
                guard try activityFactCanApply(
                        kind: .reading,
                        epochRevision: activity.epochRevision,
                        generation: activity.generation,
                        referenceId: activity.referenceId,
                        db: db
                      ) else {
                    if try Reference.fetchOne(db, id: activity.referenceId) != nil {
                        try db.execute(
                            sql: """
                                UPDATE activityQuarantine SET reason = 'epoch'
                                WHERE recordName = ?
                                """,
                            arguments: [recordName]
                        )
                    }
                    continue
                }
                let localSeconds = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT activeSeconds FROM readingActivity
                        WHERE generation = ? AND installationId = ?
                          AND referenceId = ? AND localDay = ?
                        """,
                    arguments: [
                        activity.generation, activity.installationId,
                        activity.referenceId, activity.localDay,
                    ]
                )
                try upsertReadingActivity(activity, db: db)
                if let localSeconds, localSeconds > activity.activeSeconds,
                   let parsed = SyncEntityType.parseRecordName(recordName)
                {
                    try db.execute(
                        sql: """
                            UPDATE syncState SET isDirty = 1, pushInFlight = 0
                            WHERE entityType = 'readingActivity' AND entityId = ?
                            """,
                        arguments: [parsed.1]
                    )
                }
                didApply = true
            case .assistantActivity:
                guard let activity = try? decoder.decode(AssistantActivity.self, from: data),
                      try activityFactCanApply(
                        kind: .assistant,
                        epochRevision: activity.epochRevision,
                        generation: activity.generation,
                        referenceId: nil,
                        db: db
                      )
                else { continue }
                try upsertAssistantActivity(activity, db: db)
                didApply = true
            default:
                didApply = false
            }
            if didApply {
                try db.execute(
                    sql: "DELETE FROM activityQuarantine WHERE recordName = ?",
                    arguments: [recordName]
                )
            }
        }
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
#endif
