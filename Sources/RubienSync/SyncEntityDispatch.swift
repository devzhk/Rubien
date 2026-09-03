#if canImport(CloudKit)
import Foundation
import GRDB
import CloudKit
import RubienCore

/// Per-entity glue for push and pull. Lives alongside `SyncEntityType` so the
/// actor's delegate methods stay thin — all "how do I decode a Reference
/// CKRecord into a DB row" knowledge is here.
///
/// v13 convention: `entityId` is the stable opaque sync identity, never a
/// device-local SQLite row ID. Integer primary and foreign keys are resolved
/// through each table's unique `syncId` index.
extension SyncEntityType {

    enum RemoteDependencyStatus: Equatable {
        case ready
        case unresolved
        case invalid
    }

    struct FetchOrphanReconciliationOutcome: Sendable, Equatable {
        var reconciledRowCount = 0
        var pdfFilenamesToDelete: [String] = []
    }

    private struct UnresolvedFetchOrphansError: LocalizedError {
        let count: Int

        var errorDescription: String? {
            "fetch reconciliation left \(count) unresolved foreign-key violation(s)"
        }
    }

    func remoteDependencyStatus(
        for record: CKRecord,
        entityId: String,
        db: Database
    ) throws -> RemoteDependencyStatus {
        guard SyncRecordIdentity.validatedSyncId(
            in: record,
            expectedType: self
        ) == entityId else { return .invalid }

        func exists(_ type: SyncEntityType, _ syncId: String) throws -> Bool {
            try Self.resolvedParentIdentity(
                type: type,
                syncId: syncId,
                db: db
            ) != nil
        }

        switch self {
        case .referenceTag:
            guard let row = ReferenceTag(record: record) else { return .invalid }
            guard let reference = try Self.resolvedParentIdentity(
                type: .reference,
                syncId: row.referenceSyncId,
                db: db
            ), let tag = try Self.resolvedParentIdentity(
                type: .tag,
                syncId: row.tagSyncId,
                db: db
            ) else { return .unresolved }
            if let identityOwner = try Row.fetchOne(db, sql: """
                SELECT referenceId, tagId FROM referenceTag
                WHERE syncId = ? LIMIT 1
                """, arguments: [entityId]) {
                let ownerReferenceId: Int64 = identityOwner["referenceId"]
                let ownerTagId: Int64 = identityOwner["tagId"]
                guard ownerReferenceId == reference.id,
                      ownerTagId == tag.id else { return .invalid }
            }
            return .ready
        case .pdfAnnotation:
            guard let row = PDFAnnotationRecord(record: record) else { return .invalid }
            return try exists(.reference, row.referenceSyncId) ? .ready : .unresolved
        case .webAnnotation:
            guard let row = WebAnnotationRecord(record: record) else { return .invalid }
            return try exists(.reference, row.referenceSyncId) ? .ready : .unresolved
        case .metadataIntake:
            let row = MetadataIntake(record: record)
            guard let parent = row.linkedReferenceSyncId else { return .ready }
            return try exists(.reference, parent) ? .ready : .unresolved
        case .metadataEvidence:
            guard let row = MetadataEvidence(record: record) else { return .invalid }
            if let parent = row.intakeSyncId,
               try !exists(.metadataIntake, parent) { return .unresolved }
            if let parent = row.referenceSyncId,
               try !exists(.reference, parent) { return .unresolved }
            return .ready
        case .propertyValue:
            guard let row = PropertyValue(record: record) else { return .invalid }
            guard let reference = try Self.resolvedParentIdentity(
                type: .reference,
                syncId: row.referenceSyncId,
                db: db
            ), let property = try Self.resolvedParentIdentity(
                type: .propertyDefinition,
                syncId: row.propertySyncId,
                db: db
            ) else { return .unresolved }
            let observedDerivedIdentity =
                "\(row.referenceSyncId)/\(row.propertySyncId)"
            let canonicalDerivedIdentity =
                "\(reference.syncId)/\(property.syncId)"
            let incomingIdentity = entityId == observedDerivedIdentity
                ? canonicalDerivedIdentity
                : entityId
            for identity in Set([entityId, incomingIdentity]) {
                guard let identityOwner = try Row.fetchOne(db, sql: """
                    SELECT referenceId, propertyId FROM propertyValue
                    WHERE syncId = ? LIMIT 1
                    """, arguments: [identity]) else { continue }
                let ownerReferenceId: Int64 = identityOwner["referenceId"]
                let ownerPropertyId: Int64 = identityOwner["propertyId"]
                guard ownerReferenceId == reference.id,
                      ownerPropertyId == property.id else { return .invalid }
            }
            return .ready
        case .readingActivity:
            guard let row = ReadingActivity(record: record) else { return .invalid }
            // Epoch mismatches use the specialized activity quarantine; only
            // parent absence belongs in the generic wire-record quarantine.
            return try exists(.reference, row.referenceSyncId) ? .ready : .unresolved
        case .referencePDF:
            guard let row = ReferencePDFRecord(record: record) else { return .invalid }
            return try exists(.reference, row.referenceSyncId) ? .ready : .unresolved
        case .databaseView:
            var row = DatabaseView(record: record)
            switch DatabaseViewPortableCodec.resolve(
                record: record,
                into: &row,
                db: db
            ) {
            case .ready: return .ready
            case .unresolved: return .unresolved
            case .invalid: return .invalid
            }
        case .reference, .tag, .propertyDefinition,
             .assistantActivity, .activityEpoch:
            return .ready
        }
    }

    /// Persist a full wire record until its global dependencies arrive.
    /// Returns the previously-owned staged filename when a newer PDF version
    /// replaces it, so the caller can unlink that file only after commit.
    @discardableResult
    static func quarantineRemoteRecord(
        _ record: CKRecord,
        stagedFilename: String? = nil,
        db: Database
    ) throws -> String? {
        let priorStagedFilename: String? = if stagedFilename != nil {
            try String.fetchOne(
                db,
                sql: "SELECT stagedFilename FROM syncOrphan WHERE recordName = ?",
                arguments: [record.recordID.recordName]
            )
        } else {
            nil
        }
        let data = try SyncRecordIdentity.archive(record)
        try db.execute(
            sql: """
                INSERT INTO syncOrphan
                    (recordName, recordType, recordData, stagedFilename, receivedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(recordName) DO UPDATE SET
                    recordType = excluded.recordType,
                    recordData = excluded.recordData,
                    stagedFilename = COALESCE(
                        excluded.stagedFilename,
                        syncOrphan.stagedFilename
                    ),
                    receivedAt = excluded.receivedAt
                """,
            arguments: [
                record.recordID.recordName, record.recordType, data,
                stagedFilename, Date(),
            ]
        )
        guard let priorStagedFilename,
              priorStagedFilename != stagedFilename else { return nil }
        return priorStagedFilename
    }

    /// Output of `prepareReferencePDFMaterialization`. Carries the bytes
    /// already on disk and the canonical global identity parsed from
    /// `CKRecord.ID.recordName`. The wire payload's legacy `referenceId` is
    /// kept only for backward-compatible decoding.
    struct PreparedReferencePDFMaterialization: Sendable {
        struct ReuseHint: Sendable, Equatable {
            let localFilename: String
            let contentHash: String
            let assetVersion: Int
        }

        let referenceSyncId: String
        let payload: ReferencePDFRecord
        let stagedURL: URL
        let stagedFilename: String
        let reuseHint: ReuseHint?

        func withReuseHint(_ hint: ReuseHint?) -> Self {
            .init(
                referenceSyncId: referenceSyncId,
                payload: payload,
                stagedURL: stagedURL,
                stagedFilename: stagedFilename,
                reuseHint: hint
            )
        }

        func withReferenceSyncId(_ syncId: String) -> Self {
            .init(
                referenceSyncId: syncId,
                payload: payload,
                stagedURL: stagedURL,
                stagedFilename: stagedFilename,
                reuseHint: reuseHint
            )
        }
    }

    struct PreparedReferencePDFApplyOutcome: Sendable, Equatable {
        let displacedFilename: String?
        let reusedExistingFile: Bool
    }

    /// Stage the CKAsset bytes onto disk under `PDFs/<UUID>_<originalFilename>`
    /// and return the metadata the apply step needs to upsert `pdfCache`.
    /// **No DB access.** Caller invokes this *before* opening the
    /// `dbWriter.write` transaction.
    ///
    /// Returns nil for:
    /// - records without an asset (`payload.assetURL == nil`)
    /// - records whose `recordName` and `syncId` don't agree on a valid global
    ///   reference-PDF identity
    ///
    /// On `copyItem` failure the partial staged file is removed before
    /// rethrowing so the PDFs/ dir doesn't accumulate orphans.
    static func prepareReferencePDFMaterialization(
        record: CKRecord
    ) throws -> PreparedReferencePDFMaterialization? {
        guard let referenceSyncId = SyncRecordIdentity.validatedSyncId(
            in: record,
            expectedType: .referencePDF
        ) else {
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
            referenceSyncId: referenceSyncId,
            payload: payload,
            stagedURL: stagedURL,
            stagedFilename: stagedFilename,
            reuseHint: nil
        )
    }

    static func referencePDFReuseHint(
        for prepared: PreparedReferencePDFMaterialization,
        db: Database
    ) throws -> PreparedReferencePDFMaterialization.ReuseHint? {
        let canonicalReferenceSyncId = try SyncIdentityAliasStore.resolve(
            entityType: .reference,
            identity: prepared.referenceSyncId,
            db: db
        )
        guard let row = try Row.fetchOne(db, sql: """
            SELECT pc.localFilename, pc.contentHash, pc.assetVersion
            FROM pdfCache pc
            JOIN reference r ON r.id = pc.referenceId
            WHERE r.syncId = ? AND pc.materializedAt IS NOT NULL
            LIMIT 1
            """, arguments: [canonicalReferenceSyncId]) else { return nil }
        return .init(
            localFilename: row["localFilename"],
            contentHash: row["contentHash"],
            assetVersion: row["assetVersion"]
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
        guard let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM reference WHERE syncId = ? LIMIT 1",
            arguments: [prepared.referenceSyncId]
        ) else { return nil }
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

    /// Transaction-only full-replay fast path. The Phase-1 hint is accepted
    /// only when the current row still matches every fingerprint component;
    /// otherwise the already-staged asset follows the normal upsert path.
    static func applyPreparedReferencePDFPreservingUnchanged(
        _ prepared: PreparedReferencePDFMaterialization,
        db: Database
    ) throws -> PreparedReferencePDFApplyOutcome {
        if let hint = prepared.reuseHint,
           hint.contentHash == prepared.payload.contentHash,
           hint.assetVersion == prepared.payload.assetVersion,
           let current = try Row.fetchOne(db, sql: """
                SELECT pc.localFilename, pc.contentHash, pc.assetVersion
                FROM pdfCache pc
                JOIN reference r ON r.id = pc.referenceId
                WHERE r.syncId = ? AND pc.materializedAt IS NOT NULL
                LIMIT 1
                """, arguments: [prepared.referenceSyncId]),
           (current["localFilename"] as String) == hint.localFilename,
           (current["contentHash"] as String) == hint.contentHash,
           (current["assetVersion"] as Int) == hint.assetVersion
        {
            return .init(
                displacedFilename: nil,
                reusedExistingFile: true
            )
        }
        return .init(
            displacedFilename: try applyPreparedReferencePDF(prepared, db: db),
            reusedExistingFile: false
        )
    }

    /// Resolve a retired owning-Reference identity before materializing an
    /// incoming PDF. The caller applies the returned value first, then calls
    /// `retireAliasedReferencePDFIdentity` in the same transaction.
    static func canonicalizedReferencePDFMaterialization(
        _ prepared: PreparedReferencePDFMaterialization,
        db: Database
    ) throws -> PreparedReferencePDFMaterialization? {
        guard let parent = try resolvedParentIdentity(
            type: .reference,
            syncId: prepared.referenceSyncId,
            db: db
        ) else { return nil }
        return prepared.withReferenceSyncId(parent.syncId)
    }

    /// A PDF whose observed record name names a retired parent must be
    /// recreated under the canonical parent identity and the exact observed
    /// record must be deleted. Never attach the loser's system fields to the
    /// winner: they belong to different CKRecord.ID values.
    static func retireAliasedReferencePDFIdentity(
        observedEntityId: String,
        canonicalEntityId: String,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        guard observedEntityId != canonicalEntityId else { return }
        try markDirty(
            type: .referencePDF,
            entityId: canonicalEntityId,
            db: db
        )
        try retireLosingIdentity(
            type: .referencePDF,
            entityId: observedEntityId,
            serverObserved: true,
            stateStore: stateStore,
            db: db
        )
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
            guard let row = try Reference
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .tag:
            guard let row = try Tag
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .referenceTag:
            guard let row = try ReferenceTag
                .filter(Column("syncId") == entityId)
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
            guard let row = try PDFAnnotationRecord
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .webAnnotation:
            guard let row = try WebAnnotationRecord
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .metadataIntake:
            guard let row = try MetadataIntake
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .metadataEvidence:
            guard let row = try MetadataEvidence
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .propertyDefinition:
            guard let row = try PropertyDefinition
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .propertyValue:
            guard let row = try PropertyValue
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            row.populate(record: record)
            return record

        case .databaseView:
            guard let row = try DatabaseView
                .filter(Column("syncId") == entityId)
                .fetchOne(db) else { return nil }
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            try row.populateForSync(record: record, db: db)
            return record

        case .readingActivity:
            guard let row = try ReadingActivity.fetchOne(
                db,
                sql: "SELECT * FROM readingActivity WHERE syncId = ? LIMIT 1",
                arguments: [entityId]
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
            let row: Row? = try Row.fetchOne(db,
                sql: """
                    SELECT pc.*, r.syncId AS referenceSyncId
                    FROM pdfCache pc
                    JOIN reference r ON r.id = pc.referenceId
                    WHERE r.syncId = ? AND pc.materializedAt IS NOT NULL
                    """,
                arguments: [entityId])
            guard let row else { return nil }
            let id: Int64 = row["referenceId"]
            let referenceSyncId: String = row["referenceSyncId"]
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
                referenceSyncId: referenceSyncId,
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
        guard SyncRecordIdentity.validatedSyncId(
            in: record,
            expectedType: self
        ) == entityId else {
            return false
        }

        switch self {
        case .reference:
            var row = Reference(record: record)
            row.syncId = entityId
            row.id = try Self.localID(
                tableName: rawValue,
                syncId: entityId,
                db: db
            )
            // Reference no longer carries a PDF filename (B8). Per-device PDF
            // state lives in the local-only `pdfCache` table — never written
            // to a CKRecord, never touched by this apply path. The pdfCache
            // row for `id` (if any) survives unchanged because we only write
            // to `reference` here.
            if row.id == nil { try row.insert(db) } else { try row.update(db) }

        case .tag:
            var row = Tag(record: record)
            let materializationIdentity = try SyncIdentityAliasStore.resolve(
                entityType: .tag,
                identity: entityId,
                db: db
            )
            row.syncId = materializationIdentity
            row.id = try Self.localID(
                tableName: rawValue,
                syncId: materializationIdentity,
                db: db
            )
            if entityId != materializationIdentity, row.id == nil {
                // The alias is durable even if its canonical row was later
                // deleted locally. This fetched loser still exists on the
                // server, so retire its exact record name again without
                // resurrecting a physical row or dirtying the absent winner.
                try Self.retireLosingIdentity(
                    type: .tag,
                    entityId: entityId,
                    serverObserved: true,
                    stateStore: stateStore,
                    db: db
                )
                return true
            }
            // Defense-in-depth: a missing/blank name decodes to "" (TagRecord) —
            // a malformed/forward-incompat record. Skip persistence (return false
            // → the caller skips markPulled, so we don't stamp server state on a
            // row we didn't apply) rather than upsert a "" that would itself trip
            // UNIQUE(name) and wedge a later batch.
            guard !row.name.isEmpty else { return false }
            if let local = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, syncId FROM tag
                    WHERE name = ? AND syncId <> ? LIMIT 1
                    """,
                arguments: [row.name, materializationIdentity]
            ) {
                let localId: Int64 = local["id"]
                let localSyncId: String = local["syncId"]
                let winner = SyncIdentifier.preferred(
                    localSyncId,
                    materializationIdentity
                )
                let identityLocalId = row.id
                let winnerLocalId = winner == materializationIdentity
                    ? (identityLocalId ?? localId)
                    : localId
                let losingId = winner == materializationIdentity
                    ? localSyncId : materializationIdentity

                if let identityLocalId, identityLocalId != localId {
                    let losingLocalId = winnerLocalId == identityLocalId
                        ? localId : identityLocalId
                    try Self.mergeTagRows(
                        winnerId: winnerLocalId,
                        loserId: losingLocalId,
                        winnerSyncId: winner,
                        stateStore: stateStore,
                        db: db
                    )
                } else if winner != localSyncId {
                    // The incoming identity has no row yet, so the role owner
                    // can adopt it in place.
                    row.id = localId
                    row.syncId = materializationIdentity
                    try row.update(db)
                    try Self.rekeyTagPivots(
                        tagId: localId,
                        from: localSyncId,
                        to: materializationIdentity,
                        stateStore: stateStore,
                        db: db
                    )
                }

                row.id = winnerLocalId
                row.syncId = winner
                try row.update(db)
                if winner == localSyncId {
                    try Self.markDirty(
                        type: .tag,
                        entityId: winner,
                        db: db
                    )
                }
                try Self.recordParentAlias(
                    type: .tag,
                    losingId: losingId,
                    winningId: winner,
                    db: db
                )
                try Self.retireLosingIdentity(
                    type: .tag,
                    entityId: losingId,
                    serverObserved: losingId == entityId,
                    stateStore: stateStore,
                    db: db
                )
                try Self.finishObservedParentAlias(
                    type: .tag,
                    observedId: entityId,
                    winnerId: winner,
                    stateStore: stateStore,
                    db: db
                )
                return true
            }
            if row.id == nil { try row.insert(db) } else { try row.update(db) }
            try Self.finishObservedParentAlias(
                type: .tag,
                observedId: entityId,
                winnerId: materializationIdentity,
                stateStore: stateStore,
                db: db
            )

        case .referenceTag:
            guard var pivot = ReferenceTag(record: record),
                  let reference = try Self.resolvedParentIdentity(
                    type: .reference,
                    syncId: pivot.referenceSyncId,
                    db: db
                  ),
                  let tag = try Self.resolvedParentIdentity(
                    type: .tag,
                    syncId: pivot.tagSyncId,
                    db: db
                  ) else { return false }
            let canonicalIdentity = "\(reference.syncId)/\(tag.syncId)"
            pivot.syncId = canonicalIdentity
            pivot.referenceId = reference.id
            pivot.referenceSyncId = reference.syncId
            pivot.tagId = tag.id
            pivot.tagSyncId = tag.syncId

            // An identity already attached to a different endpoint pair is
            // malformed. Do not update the requested pair and then tombstone
            // an identity that still names another live local row.
            if let identityOwner = try Row.fetchOne(db, sql: """
                SELECT referenceId, tagId FROM referenceTag
                WHERE syncId = ? LIMIT 1
                """, arguments: [entityId]) {
                let ownerReferenceId: Int64 = identityOwner["referenceId"]
                let ownerTagId: Int64 = identityOwner["tagId"]
                guard ownerReferenceId == reference.id,
                      ownerTagId == tag.id else { return false }
            }

            if let existing = try Row.fetchOne(db, sql: """
                SELECT syncId FROM referenceTag
                WHERE referenceId = ? AND tagId = ? LIMIT 1
                """, arguments: [pivot.referenceId, pivot.tagId]) {
                let existingIdentity: String = existing["syncId"]
                if existingIdentity != canonicalIdentity {
                    try Self.retireLosingIdentity(
                        type: .referenceTag,
                        entityId: existingIdentity,
                        stateStore: stateStore,
                        db: db
                    )
                    try db.execute(sql: """
                        UPDATE referenceTag
                        SET syncId = ?, referenceSyncId = ?, tagSyncId = ?
                        WHERE referenceId = ? AND tagId = ?
                        """, arguments: [
                            canonicalIdentity, reference.syncId, tag.syncId,
                            reference.id, tag.id,
                        ])
                }
            } else {
                try pivot.insert(db)
            }
            if entityId != canonicalIdentity {
                try Self.markDirty(
                    type: .referenceTag,
                    entityId: canonicalIdentity,
                    db: db
                )
                try Self.retireLosingIdentity(
                    type: .referenceTag,
                    entityId: entityId,
                    serverObserved: true,
                    stateStore: stateStore,
                    db: db
                )
            }

        case .pdfAnnotation:
            guard var row = PDFAnnotationRecord(record: record),
                  let reference = try Self.resolvedParentIdentity(
                    type: .reference,
                    syncId: row.referenceSyncId,
                    db: db
                  ) else { return false }
            row.syncId = entityId
            row.referenceId = reference.id
            row.referenceSyncId = reference.syncId
            row.id = try Self.localID(tableName: rawValue, syncId: entityId, db: db)
            if row.id == nil { try row.insert(db) } else { try row.update(db) }

        case .webAnnotation:
            guard var row = WebAnnotationRecord(record: record),
                  let reference = try Self.resolvedParentIdentity(
                    type: .reference,
                    syncId: row.referenceSyncId,
                    db: db
                  ) else { return false }
            row.syncId = entityId
            row.referenceId = reference.id
            row.referenceSyncId = reference.syncId
            row.id = try Self.localID(tableName: rawValue, syncId: entityId, db: db)
            if row.id == nil { try row.insert(db) } else { try row.update(db) }

        case .metadataIntake:
            var row = MetadataIntake(record: record)
            row.syncId = entityId
            if let parentSyncId = row.linkedReferenceSyncId {
                guard let parent = try Self.resolvedParentIdentity(
                    type: .reference,
                    syncId: parentSyncId,
                    db: db
                ) else { return false }
                row.linkedReferenceId = parent.id
                row.linkedReferenceSyncId = parent.syncId
            } else {
                row.linkedReferenceId = nil
            }
            row.id = try Self.localID(tableName: rawValue, syncId: entityId, db: db)
            if row.id == nil { try row.insert(db) } else { try row.update(db) }

        case .metadataEvidence:
            guard var row = MetadataEvidence(record: record) else { return false }
            row.syncId = entityId
            if let intakeSyncId = row.intakeSyncId {
                guard let intake = try Self.resolvedParentIdentity(
                    type: .metadataIntake,
                    syncId: intakeSyncId,
                    db: db
                ) else { return false }
                row.intakeId = intake.id
                row.intakeSyncId = intake.syncId
            } else {
                row.intakeId = nil
            }
            if let referenceSyncId = row.referenceSyncId {
                guard let reference = try Self.resolvedParentIdentity(
                    type: .reference,
                    syncId: referenceSyncId,
                    db: db
                ) else { return false }
                row.referenceId = reference.id
                row.referenceSyncId = reference.syncId
            } else {
                row.referenceId = nil
            }
            row.id = try Self.localID(tableName: rawValue, syncId: entityId, db: db)
            if row.id == nil { try row.insert(db) } else { try row.update(db) }

        case .propertyDefinition:
            var row = PropertyDefinition(record: record)
            let materializationIdentity = try SyncIdentityAliasStore.resolve(
                entityType: .propertyDefinition,
                identity: entityId,
                db: db
            )
            row.syncId = materializationIdentity
            row.id = try Self.localID(
                tableName: rawValue,
                syncId: materializationIdentity,
                db: db
            )
            if entityId != materializationIdentity, row.id == nil {
                try Self.retireLosingIdentity(
                    type: .propertyDefinition,
                    entityId: entityId,
                    serverObserved: true,
                    stateStore: stateStore,
                    db: db
                )
                return true
            }
            let roleCollision: Row?
            if let fieldKey = row.defaultFieldKey {
                roleCollision = try Row.fetchOne(db, sql: """
                    SELECT id, syncId, isDefault, defaultFieldKey
                    FROM propertyDefinition
                    WHERE defaultFieldKey = ? AND syncId <> ? LIMIT 1
                    """, arguments: [fieldKey, materializationIdentity])
            } else {
                // Custom definitions still need an explicit UNIQUE(name)
                // resolution so one duplicate cannot roll back every future
                // fetch. A built-in occupying the name is protected below.
                roleCollision = try Row.fetchOne(db, sql: """
                    SELECT id, syncId, isDefault, defaultFieldKey
                    FROM propertyDefinition
                    WHERE name = ? AND syncId <> ? LIMIT 1
                    """, arguments: [row.name, materializationIdentity])
            }

            if let local = roleCollision {
                let localId: Int64 = local["id"]
                let localSyncId: String = local["syncId"]
                let localFieldKey: String? = local["defaultFieldKey"]
                let incomingIsBuiltin = row.defaultFieldKey != nil
                let localIsBuiltin = localFieldKey != nil

                if localIsBuiltin && !incomingIsBuiltin {
                    // A malformed/custom peer row cannot steal a protected
                    // built-in's unique name.
                    if entityId != materializationIdentity {
                        try Self.finishObservedParentAlias(
                            type: .propertyDefinition,
                            observedId: entityId,
                            winnerId: materializationIdentity,
                            stateStore: stateStore,
                            db: db
                        )
                        return true
                    }
                    if let identityLocalId = row.id {
                        try db.execute(
                            sql: "DELETE FROM propertyDefinition WHERE id = ?",
                            arguments: [identityLocalId]
                        )
                    }
                    try Self.retireLosingIdentity(
                        type: .propertyDefinition,
                        entityId: entityId,
                        serverObserved: true,
                        stateStore: stateStore,
                        db: db
                    )
                    return true
                }

                let winner = SyncIdentifier.preferred(
                    localSyncId,
                    materializationIdentity
                )
                let identityLocalId = row.id
                let winnerLocalId = winner == materializationIdentity
                    ? (identityLocalId ?? localId)
                    : localId
                let losingId = winner == materializationIdentity
                    ? localSyncId : materializationIdentity

                if let identityLocalId, identityLocalId != localId {
                    let losingLocalId = winnerLocalId == identityLocalId
                        ? localId : identityLocalId
                    try Self.mergePropertyDefinitionRows(
                        winnerId: winnerLocalId,
                        loserId: losingLocalId,
                        winnerSyncId: winner,
                        loserSyncId: losingId,
                        stateStore: stateStore,
                        db: db
                    )
                } else if winner != localSyncId {
                    row.id = localId
                    row.syncId = materializationIdentity
                    try row.update(db)
                    try Self.rekeyPropertyValues(
                        propertyId: localId,
                        from: localSyncId,
                        to: materializationIdentity,
                        stateStore: stateStore,
                        db: db
                    )
                }

                row.id = winnerLocalId
                try Self.preparePropertyDefinitionForApply(
                    &row,
                    localId: winnerLocalId,
                    db: db
                )
                row.syncId = winner
                try row.update(db)
                if winner == localSyncId {
                    try Self.markDirty(
                        type: .propertyDefinition,
                        entityId: winner,
                        db: db
                    )
                }
                try Self.recordParentAlias(
                    type: .propertyDefinition,
                    losingId: losingId,
                    winningId: winner,
                    db: db
                )
                try Self.retireLosingIdentity(
                    type: .propertyDefinition,
                    entityId: losingId,
                    serverObserved: losingId == entityId,
                    stateStore: stateStore,
                    db: db
                )
                try Self.finishObservedParentAlias(
                    type: .propertyDefinition,
                    observedId: entityId,
                    winnerId: winner,
                    stateStore: stateStore,
                    db: db
                )
                return true
            }

            if let localId = row.id {
                try Self.preparePropertyDefinitionForApply(
                    &row,
                    localId: localId,
                    db: db
                )
                try row.update(db)
            } else {
                try Self.preparePropertyDefinitionForApply(
                    &row,
                    localId: nil,
                    db: db
                )
                try row.insert(db)
            }
            try Self.finishObservedParentAlias(
                type: .propertyDefinition,
                observedId: entityId,
                winnerId: materializationIdentity,
                stateStore: stateStore,
                db: db
            )

        case .propertyValue:
            guard var row = PropertyValue(record: record),
                  let reference = try Self.resolvedParentIdentity(
                    type: .reference,
                    syncId: row.referenceSyncId,
                    db: db
                  ),
                  let property = try Self.resolvedParentIdentity(
                    type: .propertyDefinition,
                    syncId: row.propertySyncId,
                    db: db
                  ) else { return false }
            let observedDerivedIdentity =
                "\(row.referenceSyncId)/\(row.propertySyncId)"
            let canonicalDerivedIdentity =
                "\(reference.syncId)/\(property.syncId)"
            let incomingIdentity = entityId == observedDerivedIdentity
                ? canonicalDerivedIdentity
                : entityId
            row.syncId = incomingIdentity
            row.referenceId = reference.id
            row.referenceSyncId = reference.syncId
            row.propertyId = property.id
            row.propertySyncId = property.syncId
            let observedIdentityLocalId = try Self.localID(
                tableName: rawValue,
                syncId: entityId,
                db: db
            )
            let incomingIdentityLocalId = try Self.localID(
                tableName: rawValue,
                syncId: incomingIdentity,
                db: db
            )
            for identity in Set([entityId, incomingIdentity]) {
                guard let identityOwner = try Row.fetchOne(db, sql: """
                    SELECT referenceId, propertyId FROM propertyValue
                    WHERE syncId = ? LIMIT 1
                    """, arguments: [identity]) else { continue }
                let ownerReferenceId: Int64 = identityOwner["referenceId"]
                let ownerPropertyId: Int64 = identityOwner["propertyId"]
                guard ownerReferenceId == reference.id,
                      ownerPropertyId == property.id else { return false }
            }
            let pairOwner = try Row.fetchOne(db, sql: """
                SELECT id, syncId FROM propertyValue
                WHERE referenceId = ? AND propertyId = ? LIMIT 1
                """, arguments: [reference.id, property.id])

            if let pairOwner {
                let pairId: Int64 = pairOwner["id"]
                let localSyncId: String = pairOwner["syncId"]
                guard observedIdentityLocalId == nil
                        || observedIdentityLocalId == pairId,
                      incomingIdentityLocalId == nil
                        || incomingIdentityLocalId == pairId else {
                    // One global identity naming two endpoint pairs is invalid;
                    // do not delete either local row to guess at intent.
                    return false
                }
                row.id = pairId
                if localSyncId == incomingIdentity {
                    try row.update(db)
                } else {
                    let winner = Self.preferredPropertyValueIdentity(
                        localSyncId,
                        incomingIdentity,
                        derivedIdentity: canonicalDerivedIdentity
                    )
                    if winner == localSyncId {
                        row.syncId = localSyncId
                        try row.update(db)
                        try Self.markDirty(
                            type: .propertyValue,
                            entityId: localSyncId,
                            db: db
                        )
                        try Self.retireLosingIdentity(
                            type: .propertyValue,
                            entityId: incomingIdentity,
                            serverObserved: incomingIdentity == entityId,
                            stateStore: stateStore,
                            db: db
                        )
                    } else {
                        try Self.retireLosingIdentity(
                            type: .propertyValue,
                            entityId: localSyncId,
                            serverObserved: localSyncId == entityId,
                            stateStore: stateStore,
                            db: db
                        )
                        row.syncId = incomingIdentity
                        try row.update(db)
                    }
                }
            } else if let incomingIdentityLocalId {
                row.id = incomingIdentityLocalId
                try row.update(db)
            } else {
                try row.insert(db)
            }
            if entityId != incomingIdentity {
                let canonicalChildIdentity = try String.fetchOne(db, sql: """
                    SELECT syncId FROM propertyValue
                    WHERE referenceId = ? AND propertyId = ? LIMIT 1
                    """, arguments: [reference.id, property.id])
                    ?? incomingIdentity
                try Self.markDirty(
                    type: .propertyValue,
                    entityId: canonicalChildIdentity,
                    db: db
                )
                try Self.retireLosingIdentity(
                    type: .propertyValue,
                    entityId: entityId,
                    serverObserved: true,
                    stateStore: stateStore,
                    db: db
                )
            }

        case .databaseView:
            var row = DatabaseView(record: record)
            guard DatabaseViewPortableCodec.resolve(
                record: record,
                into: &row,
                db: db
            ) == .ready else { return false }
            row.syncId = entityId
            row.id = try Self.localID(
                tableName: rawValue,
                syncId: entityId,
                db: db
            )
            let existingIdentityWasDefault: Bool
            if let id = row.id {
                existingIdentityWasDefault = try Bool.fetchOne(
                    db,
                    sql: "SELECT isDefault FROM databaseView WHERE id = ?",
                    arguments: [id]
                ) ?? false
            } else {
                existingIdentityWasDefault = false
            }
            if row.isDefault || existingIdentityWasDefault,
               let local = try Row.fetchOne(db, sql: """
                    SELECT id, syncId FROM databaseView
                    WHERE isDefault = 1 AND syncId <> ? LIMIT 1
                    """, arguments: [entityId])
            {
                let localId: Int64 = local["id"]
                let localSyncId: String = local["syncId"]
                let winner = SyncIdentifier.preferred(localSyncId, entityId)
                row.id = localId
                row.isDefault = true
                if winner == localSyncId {
                    row.syncId = localSyncId
                    try row.update(db)
                    try Self.markDirty(
                        type: .databaseView,
                        entityId: localSyncId,
                        db: db
                    )
                    try Self.retireLosingIdentity(
                        type: .databaseView,
                        entityId: entityId,
                        serverObserved: true,
                        stateStore: stateStore,
                        db: db
                    )
                } else {
                    row.syncId = entityId
                    try row.update(db)
                    try Self.retireLosingIdentity(
                        type: .databaseView,
                        entityId: localSyncId,
                        stateStore: stateStore,
                        db: db
                    )
                }
            } else if row.id == nil {
                try row.insert(db)
            } else {
                if existingIdentityWasDefault { row.isDefault = true }
                try row.update(db)
            }

        case .readingActivity:
            guard var row = ReadingActivity(record: record),
                  row.entityId == entityId
            else { return false }
            let observedReferenceSyncId = row.referenceSyncId
            if let reference = try Self.resolvedParentIdentity(
                type: .reference,
                syncId: row.referenceSyncId,
                db: db
            ) {
                row.referenceId = reference.id
                row.referenceSyncId = reference.syncId
            } else if
               try stateStore.hasTombstone(
                    db,
                    entityType: .reference,
                    entityId: row.referenceSyncId
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
            } else {
                try Self.quarantine(
                    row,
                    recordName: record.recordID.recordName,
                    db: db
                )
                return true
            }
            let observedDerivedIdentity =
                "\(row.generation)/\(row.installationId)/\(observedReferenceSyncId)/\(row.localDay.rawValue)"
            let canonicalDerivedIdentity =
                "\(row.generation)/\(row.installationId)/\(row.referenceSyncId)/\(row.localDay.rawValue)"
            let incomingIdentity = entityId == observedDerivedIdentity
                ? canonicalDerivedIdentity
                : entityId
            row.syncId = incomingIdentity

            for identity in Set([entityId, incomingIdentity]) {
                guard let owner = try Row.fetchOne(db, sql: """
                    SELECT generation, installationId, referenceId, localDay
                    FROM readingActivity WHERE syncId = ? LIMIT 1
                    """, arguments: [identity]) else { continue }
                let ownerGeneration: String = owner["generation"]
                let ownerInstallationId: String = owner["installationId"]
                let ownerReferenceId: Int64 = owner["referenceId"]
                let ownerLocalDay: String = owner["localDay"]
                guard ownerGeneration == row.generation,
                      ownerInstallationId == row.installationId,
                      ownerReferenceId == row.referenceId,
                      ownerLocalDay == row.localDay.rawValue else { return false }
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
            let priorIdentity = try String.fetchOne(db, sql: """
                SELECT syncId FROM readingActivity
                WHERE generation = ? AND installationId = ?
                  AND referenceId = ? AND localDay = ?
                """, arguments: [
                    row.generation, row.installationId,
                    row.referenceId, row.localDay,
                ])
            try Self.upsertReadingActivity(row, db: db)
            if let priorIdentity, priorIdentity != incomingIdentity {
                try Self.retireLosingIdentity(
                    type: .readingActivity,
                    entityId: priorIdentity,
                    serverObserved: priorIdentity == entityId,
                    stateStore: stateStore,
                    db: db
                )
            }
            if entityId != incomingIdentity {
                try Self.markDirty(
                    type: .readingActivity,
                    entityId: incomingIdentity,
                    db: db
                )
                try Self.retireLosingIdentity(
                    type: .readingActivity,
                    entityId: entityId,
                    serverObserved: true,
                    stateStore: stateStore,
                    db: db
                )
            }
            if let localSeconds, localSeconds > row.activeSeconds {
                if entityId == incomingIdentity {
                    try stateStore.adoptSystemFieldsKeepingDirty(
                        db,
                        entityType: .readingActivity,
                        entityId: incomingIdentity,
                        record: record
                    )
                }
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
            guard let canonicalPrepared = try Self
                .canonicalizedReferencePDFMaterialization(prepared, db: db)
            else { return false }
            let previousFilename = try Self.applyPreparedReferencePDF(
                canonicalPrepared,
                db: db
            )
            try Self.retireAliasedReferencePDFIdentity(
                observedEntityId: entityId,
                canonicalEntityId: canonicalPrepared.referenceSyncId,
                stateStore: stateStore,
                db: db
            )
            if let previousFilename {
                let oldURL = AppDatabase.pdfStorageURL.appendingPathComponent(previousFilename)
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        return true
    }

    /// Apply a pulled deletion. Calls `DELETE` by key; FK cascades handle
    /// children. Safe if the row is already gone (no-op).
    ///
    /// Returns on-disk PDF filenames that became unreferenced by the delete.
    /// The caller must unlink them only after the surrounding SQLite transaction
    /// commits; deleting them here would make a later rollback restore DB rows
    /// without restoring the files.
    @discardableResult
    public func applyRemoteDelete(
        entityId: String,
        db: Database
    ) throws -> [String] {
        let recordName = qualifiedRecordName(entityId: entityId)
        var filenamesToUnlinkAfterCommit = Set<String>()
        if let stagedFilename = try String.fetchOne(
            db,
            sql: "SELECT stagedFilename FROM syncOrphan WHERE recordName = ?",
            arguments: [recordName]
        ) {
            filenamesToUnlinkAfterCommit.insert(stagedFilename)
        }
        try db.execute(
            sql: "DELETE FROM syncOrphan WHERE recordName = ?",
            arguments: [recordName]
        )

        switch self {
        case .reference:
            filenamesToUnlinkAfterCommit.formUnion(
                try Self.consumeLegacyReferenceQuarantine(
                    referenceSyncId: entityId,
                    includeWebContent: true,
                    db: db
                )
            )
            if let id = try Self.localID(
                tableName: "reference",
                syncId: entityId,
                db: db
            ) {
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
                        WHERE entityType = 'readingActivity' AND referenceSyncId = ?
                        """,
                    arguments: [entityId]
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
                    try stateStore.queueDelete(
                        db,
                        entityType: .readingActivity,
                        entityId: childID
                    )
                }
                try db.execute(
                    sql: """
                        DELETE FROM activityQuarantine
                        WHERE entityType = 'readingActivity' AND referenceSyncId = ?
                        """,
                    arguments: [entityId]
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
                let queuedFilename = try String.fetchOne(db,
                    sql: "SELECT localFilename FROM pdfUploadQueue WHERE referenceId = ?",
                    arguments: [id])
                _ = try Reference.deleteOne(db, key: id)
                if let pdfFilename {
                    filenamesToUnlinkAfterCommit.insert(pdfFilename)
                }
                if let queuedFilename {
                    filenamesToUnlinkAfterCommit.insert(queuedFilename)
                }
                try db.execute(sql: """
                    DELETE FROM syncState WHERE entityType='referencePDF' AND entityId=?
                    """, arguments: [entityId])
                try db.execute(sql: """
                    DELETE FROM tombstone WHERE entityType='referencePDF' AND entityId=?
                    """, arguments: [entityId])
            }
        case .tag:
            if let id = try Self.localID(tableName: "tag", syncId: entityId, db: db) {
                _ = try Tag.deleteOne(db, key: id)
            }
        case .referenceTag:
            try db.execute(
                sql: "DELETE FROM referenceTag WHERE syncId = ?",
                arguments: [entityId]
            )
        case .pdfAnnotation:
            try Self.deleteBySyncId(tableName: rawValue, syncId: entityId, db: db)
        case .webAnnotation:
            try Self.deleteBySyncId(tableName: rawValue, syncId: entityId, db: db)
        case .metadataIntake:
            try Self.deleteBySyncId(tableName: rawValue, syncId: entityId, db: db)
        case .metadataEvidence:
            try Self.deleteBySyncId(tableName: rawValue, syncId: entityId, db: db)
        case .propertyDefinition:
            if let id = try Self.localID(
                tableName: "propertyDefinition",
                syncId: entityId,
                db: db
            ) {
                // Never honor a remote delete against a local built-in.
                // Built-ins are seeded and delete-protected on every device;
                // reconciliation may preserve a different local surrogate ID,
                // but deletion resolves solely through the shared sync ID.
                // Custom properties (isDefault=0) delete normally.
                let isLocalDefault = try Bool.fetchOne(
                    db,
                    sql: "SELECT isDefault FROM propertyDefinition WHERE id = ? LIMIT 1",
                    arguments: [id]
                ) ?? false
                guard !isLocalDefault else { return [] }
                _ = try PropertyDefinition.deleteOne(db, key: id)
            }
        case .propertyValue:
            try Self.deleteBySyncId(tableName: rawValue, syncId: entityId, db: db)
        case .databaseView:
            try Self.deleteBySyncId(tableName: rawValue, syncId: entityId, db: db)
        case .readingActivity:
            try db.execute(
                sql: "DELETE FROM readingActivity WHERE syncId = ?",
                arguments: [entityId]
            )
            try db.execute(
                sql: "DELETE FROM activityQuarantine WHERE recordName = ?",
                arguments: [qualifiedRecordName(entityId: entityId)]
            )
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
            filenamesToUnlinkAfterCommit.formUnion(
                try Self.consumeLegacyReferenceQuarantine(
                    referenceSyncId: entityId,
                    includeWebContent: false,
                    db: db
                )
            )
            if let id = try Self.localID(
                tableName: "reference",
                syncId: entityId,
                db: db
            ) {
                // A server PDF deletion also supersedes a pending local upload;
                // otherwise the drainer would immediately dirty and recreate
                // the deleted sibling record.
                let cacheFilename = try String.fetchOne(db,
                    sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                    arguments: [id])
                let queuedFilename = try String.fetchOne(db,
                    sql: "SELECT localFilename FROM pdfUploadQueue WHERE referenceId = ?",
                    arguments: [id])
                try db.execute(sql: "DELETE FROM pdfCache WHERE referenceId = ?", arguments: [id])
                try db.execute(
                    sql: "DELETE FROM pdfUploadQueue WHERE referenceId = ?",
                    arguments: [id]
                )
                if let cacheFilename {
                    filenamesToUnlinkAfterCommit.insert(cacheFilename)
                }
                if let queuedFilename {
                    filenamesToUnlinkAfterCommit.insert(queuedFilename)
                }
            }
        }

        return try Self.unreferencedPDFFilenames(
            filenamesToUnlinkAfterCommit,
            db: db
        )
    }

    // MARK: - Helpers

    private struct ResolvedParentIdentity {
        let id: Int64
        let syncId: String
    }

    private static func resolvedParentIdentity(
        type: SyncEntityType,
        syncId: String,
        db: Database
    ) throws -> ResolvedParentIdentity? {
        let canonical = try SyncIdentityAliasStore.resolve(
            entityType: type,
            identity: syncId,
            db: db
        )
        guard let id = try localID(
            tableName: type.rawValue,
            syncId: canonical,
            db: db
        ) else { return nil }
        return .init(id: id, syncId: canonical)
    }

    private static func recordParentAlias(
        type: SyncEntityType,
        losingId: String,
        winningId: String,
        db: Database
    ) throws {
        try SyncIdentityAliasStore.record(
            entityType: type,
            losingId: losingId,
            winningId: winningId,
            db: db
        )
        if type == .tag || type == .propertyDefinition {
            // A view may embed either identity in several JSON fields. Its
            // portable projection is generated only on push, so conservatively
            // republish all views after a parent identity changes. Keep this
            // set-based: one replay can resolve several aliases and libraries
            // may contain many saved views.
            try db.execute(sql: """
                DELETE FROM tombstone
                WHERE entityType = 'databaseView'
                  AND entityId IN (SELECT syncId FROM databaseView)
                """)
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                )
                SELECT 'databaseView', syncId, 1, 0 FROM databaseView
                WHERE true
                ON CONFLICT(entityType, entityId) DO UPDATE SET
                    isDirty = 1,
                    pushInFlight = 0
                """)
        }
    }

    /// Finish applying a server update whose record name is already a retired
    /// parent identity. The scalar data was materialized on `winnerId`; push
    /// that canonical row and delete only the exact observed loser.
    private static func finishObservedParentAlias(
        type: SyncEntityType,
        observedId: String,
        winnerId: String,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        guard observedId != winnerId else { return }
        try markDirty(type: type, entityId: winnerId, db: db)
        try recordParentAlias(
            type: type,
            losingId: observedId,
            winningId: winnerId,
            db: db
        )
        try retireLosingIdentity(
            type: type,
            entityId: observedId,
            serverObserved: true,
            stateStore: stateStore,
            db: db
        )
    }

    /// Return rows whose local integer FK is missing or names a parent whose
    /// global identity disagrees with the durable shadow identity. The latter
    /// case matters when a new UUID parent happens to reuse the row ID of a
    /// missing v12 decimal parent: SQLite considers that FK valid even though
    /// it points at the wrong logical record.
    private static func legacyForeignKeyCandidateRowIDs(
        db: Database
    ) throws -> [String: Set<Int64>] {
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        var result: [String: Set<Int64>] = [:]
        for violation in violations {
            let table: String = violation["table"]
            guard let rowID: Int64 = violation["rowid"] else { continue }
            result[table, default: []].insert(rowID)
        }

        let mismatchQueries: [(table: String, sql: String)] = [
            ("referenceTag", """
                SELECT rt.rowid
                FROM referenceTag rt
                LEFT JOIN reference r ON r.id = rt.referenceId
                LEFT JOIN tag t ON t.id = rt.tagId
                WHERE (rt.referenceSyncId IS NOT NULL AND
                       (r.id IS NULL OR r.syncId <> rt.referenceSyncId))
                   OR (rt.tagSyncId IS NOT NULL AND
                       (t.id IS NULL OR t.syncId <> rt.tagSyncId))
                """),
            ("pdfAnnotation", """
                SELECT c.rowid FROM pdfAnnotation c
                LEFT JOIN reference r ON r.id = c.referenceId
                WHERE c.referenceSyncId IS NOT NULL
                  AND (r.id IS NULL OR r.syncId <> c.referenceSyncId)
                """),
            ("webAnnotation", """
                SELECT c.rowid FROM webAnnotation c
                LEFT JOIN reference r ON r.id = c.referenceId
                WHERE c.referenceSyncId IS NOT NULL
                  AND (r.id IS NULL OR r.syncId <> c.referenceSyncId)
                """),
            ("readingActivity", """
                SELECT c.rowid FROM readingActivity c
                LEFT JOIN reference r ON r.id = c.referenceId
                WHERE c.referenceSyncId IS NOT NULL
                  AND (r.id IS NULL OR r.syncId <> c.referenceSyncId)
                """),
            ("propertyValue", """
                SELECT pv.rowid
                FROM propertyValue pv
                LEFT JOIN reference r ON r.id = pv.referenceId
                LEFT JOIN propertyDefinition p ON p.id = pv.propertyId
                WHERE (pv.referenceSyncId IS NOT NULL AND
                       (r.id IS NULL OR r.syncId <> pv.referenceSyncId))
                   OR (pv.propertySyncId IS NOT NULL AND
                       (p.id IS NULL OR p.syncId <> pv.propertySyncId))
                """),
            ("metadataIntake", """
                SELECT mi.rowid FROM metadataIntake mi
                LEFT JOIN reference r ON r.id = mi.linkedReferenceId
                WHERE mi.linkedReferenceSyncId IS NOT NULL
                  AND (r.id IS NULL OR r.syncId <> mi.linkedReferenceSyncId)
                """),
            ("metadataEvidence", """
                SELECT me.rowid
                FROM metadataEvidence me
                LEFT JOIN metadataIntake mi ON mi.id = me.intakeId
                LEFT JOIN reference r ON r.id = me.referenceId
                WHERE (me.intakeSyncId IS NOT NULL AND
                       (mi.id IS NULL OR mi.syncId <> me.intakeSyncId))
                   OR (me.referenceSyncId IS NOT NULL AND
                       (r.id IS NULL OR r.syncId <> me.referenceSyncId))
                """),
            ("syncLegacyPDFCacheOrphan", """
                SELECT rowid FROM syncLegacyPDFCacheOrphan
                """),
            ("syncLegacyPDFUploadQueueOrphan", """
                SELECT rowid FROM syncLegacyPDFUploadQueueOrphan
                """),
            ("syncLegacyWebContentCacheOrphan", """
                SELECT rowid FROM syncLegacyWebContentCacheOrphan
                """),
        ]
        for query in mismatchQueries {
            let rowIDs = try Int64.fetchAll(db, sql: query.sql)
            result[query.table, default: []].formUnion(rowIDs)
        }
        return result
    }

    /// v12 fetches intentionally allowed a child batch to commit before its
    /// parent. v13 preserves those rare rows with decimal shadow identities;
    /// whenever any parent arrives, repair every candidate whose complete
    /// parent set is now resolvable.
    @discardableResult
    static func repairResolvableLegacyForeignKeyOrphans(
        db: Database
    ) throws -> [String] {
        let rowIDs = try legacyForeignKeyCandidateRowIDs(db: db)
        var displacedPDFCandidates = Set<String>()
        var restoredLegacyPDFIdentities = Set<String>()

        for rowID in rowIDs["referenceTag", default: []] {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM referenceTag WHERE rowid = ?",
                arguments: [rowID]
            ),
            let reference = try resolvedParentIdentity(
                type: .reference,
                syncId: row["referenceSyncId"],
                db: db
            ),
            let tag = try resolvedParentIdentity(
                type: .tag,
                syncId: row["tagSyncId"],
                db: db
            ) else { continue }
            try db.execute(sql: """
                UPDATE referenceTag
                SET referenceId = ?, referenceSyncId = ?,
                    tagId = ?, tagSyncId = ?
                WHERE rowid = ?
                """, arguments: [
                    reference.id, reference.syncId, tag.id, tag.syncId, rowID,
                ])
        }

        for table in ["pdfAnnotation", "webAnnotation", "readingActivity"] {
            for rowID in rowIDs[table, default: []] {
                guard let shadow = try String.fetchOne(
                    db,
                    sql: "SELECT referenceSyncId FROM \(table) WHERE rowid = ?",
                    arguments: [rowID]
                ), let reference = try resolvedParentIdentity(
                    type: .reference,
                    syncId: shadow,
                    db: db
                ) else { continue }
                try db.execute(sql: """
                    UPDATE \(table)
                    SET referenceId = ?, referenceSyncId = ?
                    WHERE rowid = ?
                    """, arguments: [reference.id, reference.syncId, rowID])
            }
        }

        for rowID in rowIDs["propertyValue", default: []] {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM propertyValue WHERE rowid = ?",
                arguments: [rowID]
            ),
            let reference = try resolvedParentIdentity(
                type: .reference,
                syncId: row["referenceSyncId"],
                db: db
            ),
            let property = try resolvedParentIdentity(
                type: .propertyDefinition,
                syncId: row["propertySyncId"],
                db: db
            ) else { continue }
            try db.execute(sql: """
                UPDATE propertyValue
                SET referenceId = ?, referenceSyncId = ?,
                    propertyId = ?, propertySyncId = ?
                WHERE rowid = ?
                """, arguments: [
                    reference.id, reference.syncId,
                    property.id, property.syncId, rowID,
                ])
        }

        for rowID in rowIDs["metadataIntake", default: []] {
            guard let shadow = try String.fetchOne(
                db,
                sql: "SELECT linkedReferenceSyncId FROM metadataIntake WHERE rowid = ?",
                arguments: [rowID]
            ), let reference = try resolvedParentIdentity(
                type: .reference,
                syncId: shadow,
                db: db
            ) else { continue }
            try db.execute(sql: """
                UPDATE metadataIntake
                SET linkedReferenceId = ?, linkedReferenceSyncId = ?
                WHERE rowid = ?
                """, arguments: [reference.id, reference.syncId, rowID])
        }

        for rowID in rowIDs["metadataEvidence", default: []] {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM metadataEvidence WHERE rowid = ?",
                arguments: [rowID]
            ) else { continue }
            let intakeSyncId: String? = row["intakeSyncId"]
            let referenceSyncId: String? = row["referenceSyncId"]
            let intake: ResolvedParentIdentity? = if let intakeSyncId {
                try resolvedParentIdentity(
                    type: .metadataIntake,
                    syncId: intakeSyncId,
                    db: db
                )
            } else {
                nil
            }
            let reference: ResolvedParentIdentity? = if let referenceSyncId {
                try resolvedParentIdentity(
                    type: .reference,
                    syncId: referenceSyncId,
                    db: db
                )
            } else {
                nil
            }
            guard (intakeSyncId == nil || intake != nil),
                  (referenceSyncId == nil || reference != nil) else { continue }
            try db.execute(sql: """
                UPDATE metadataEvidence
                SET intakeId = ?, intakeSyncId = ?,
                    referenceId = ?, referenceSyncId = ?
                WHERE rowid = ?
                """, arguments: [
                    intake?.id, intake?.syncId,
                    reference?.id, reference?.syncId, rowID,
                ])
        }

        for rowID in rowIDs["syncLegacyPDFCacheOrphan", default: []] {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM syncLegacyPDFCacheOrphan WHERE rowid = ?",
                arguments: [rowID]
            ), let reference = try resolvedParentIdentity(
                type: .reference,
                syncId: row["legacyReferenceSyncId"],
                db: db
            ) else { continue }
            let legacyReferenceSyncId: String = row["legacyReferenceSyncId"]
            let legacyFilename: String = row["localFilename"]
            let liveFilename = try String.fetchOne(
                db,
                sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                arguments: [reference.id]
            )
            if let liveFilename {
                if liveFilename != legacyFilename {
                    displacedPDFCandidates.insert(legacyFilename)
                }
            } else {
                try db.execute(sql: """
                    INSERT INTO pdfCache(
                        referenceId, localFilename, contentHash,
                        assetVersion, materializedAt, lastOpenedAt
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        reference.id,
                        legacyFilename,
                        row["contentHash"] as String,
                        row["assetVersion"] as Int64,
                        row["materializedAt"] as Date?,
                        row["lastOpenedAt"] as Date,
                    ])
                restoredLegacyPDFIdentities.insert(legacyReferenceSyncId)
            }
            try db.execute(
                sql: "DELETE FROM syncLegacyPDFCacheOrphan WHERE rowid = ?",
                arguments: [rowID]
            )
        }

        for rowID in rowIDs["syncLegacyPDFUploadQueueOrphan", default: []] {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM syncLegacyPDFUploadQueueOrphan WHERE rowid = ?",
                arguments: [rowID]
            ), let reference = try resolvedParentIdentity(
                type: .reference,
                syncId: row["legacyReferenceSyncId"],
                db: db
            ) else { continue }
            let legacyReferenceSyncId: String = row["legacyReferenceSyncId"]
            let legacyFilename: String = row["localFilename"]
            if restoredLegacyPDFIdentities.contains(legacyReferenceSyncId) {
                let liveFilename = try String.fetchOne(
                    db,
                    sql: "SELECT localFilename FROM pdfUploadQueue WHERE referenceId = ?",
                    arguments: [reference.id]
                )
                if let liveFilename {
                    if liveFilename != legacyFilename {
                        displacedPDFCandidates.insert(legacyFilename)
                    }
                } else {
                    try db.execute(sql: """
                        INSERT INTO pdfUploadQueue(
                            referenceId, localFilename, queuedAt
                        ) VALUES (?, ?, ?)
                        """, arguments: [
                        reference.id,
                        legacyFilename,
                        row["queuedAt"] as Date,
                    ])
                }
            } else {
                // A live cache row already won (for example, a server PDF in
                // this same batch), or there was no matching legacy cache to
                // upload. Never revive the stale queue under the new parent.
                displacedPDFCandidates.insert(legacyFilename)
            }
            try db.execute(
                sql: "DELETE FROM syncLegacyPDFUploadQueueOrphan WHERE rowid = ?",
                arguments: [rowID]
            )
        }

        for rowID in rowIDs["syncLegacyWebContentCacheOrphan", default: []] {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM syncLegacyWebContentCacheOrphan WHERE rowid = ?",
                arguments: [rowID]
            ), let reference = try resolvedParentIdentity(
                type: .reference,
                syncId: row["legacyReferenceSyncId"],
                db: db
            ) else { continue }
            try db.execute(sql: """
                INSERT OR IGNORE INTO webContentMarkdownCache(
                    referenceId, sourceHash, converterVersion, markdown
                ) VALUES (?, ?, ?, ?)
                """, arguments: [
                    reference.id,
                    row["sourceHash"] as String,
                    row["converterVersion"] as Int,
                    row["markdown"] as String,
                ])
            try db.execute(
                sql: "DELETE FROM syncLegacyWebContentCacheOrphan WHERE rowid = ?",
                arguments: [rowID]
            )
        }

        let quarantined = try Row.fetchAll(db, sql: """
            SELECT recordName, referenceSyncId FROM activityQuarantine
            WHERE referenceSyncId IS NOT NULL
            """)
        for row in quarantined {
            let recordName: String = row["recordName"]
            let shadow: String = row["referenceSyncId"]
            guard let reference = try resolvedParentIdentity(
                type: .reference,
                syncId: shadow,
                db: db
            ) else { continue }
            try db.execute(sql: """
                UPDATE activityQuarantine
                SET referenceId = ?, referenceSyncId = ?
                WHERE recordName = ?
                """, arguments: [reference.id, reference.syncId, recordName])
        }

        return try unreferencedPDFFilenames(displacedPDFCandidates, db: db)
    }

    /// Consume v12 local-only rows tied to an authoritative server deletion.
    /// Alias resolution matters when reconciliation retired the decimal parent
    /// identity before the delete arrived.
    private static func consumeLegacyReferenceQuarantine(
        referenceSyncId: String,
        includeWebContent: Bool,
        db: Database
    ) throws -> Set<String> {
        let canonicalTarget = try SyncIdentityAliasStore.resolve(
            entityType: .reference,
            identity: referenceSyncId,
            db: db
        )
        var filenames = Set<String>()
        for table in [
            "syncLegacyPDFCacheOrphan",
            "syncLegacyPDFUploadQueueOrphan",
        ] {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT legacyReferenceSyncId, localFilename FROM \(table)"
            )
            for row in rows {
                let legacyReferenceSyncId: String = row["legacyReferenceSyncId"]
                let canonicalLegacy = try SyncIdentityAliasStore.resolve(
                    entityType: .reference,
                    identity: legacyReferenceSyncId,
                    db: db
                )
                guard canonicalLegacy == canonicalTarget else { continue }
                filenames.insert(row["localFilename"] as String)
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE legacyReferenceSyncId = ?",
                    arguments: [legacyReferenceSyncId]
                )
            }
        }

        if includeWebContent {
            let identities = try String.fetchAll(
                db,
                sql: "SELECT legacyReferenceSyncId FROM syncLegacyWebContentCacheOrphan"
            )
            for legacyReferenceSyncId in identities {
                let canonicalLegacy = try SyncIdentityAliasStore.resolve(
                    entityType: .reference,
                    identity: legacyReferenceSyncId,
                    db: db
                )
                guard canonicalLegacy == canonicalTarget else { continue }
                try db.execute(
                    sql: """
                        DELETE FROM syncLegacyWebContentCacheOrphan
                        WHERE legacyReferenceSyncId = ?
                        """,
                    arguments: [legacyReferenceSyncId]
                )
            }
        }
        return filenames
    }

    /// A losing quarantine row can name the same file as the winning live
    /// cache (or another still-quarantined row). Only return filenames that no
    /// durable row owns after the transaction's database changes.
    private static func unreferencedPDFFilenames(
        _ candidates: Set<String>,
        db: Database
    ) throws -> [String] {
        try candidates.filter { filename in
            let isReferenced = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM pdfCache WHERE localFilename = ?
                    UNION ALL
                    SELECT 1 FROM pdfUploadQueue WHERE localFilename = ?
                    UNION ALL
                    SELECT 1 FROM syncOrphan WHERE stagedFilename = ?
                    UNION ALL
                    SELECT 1 FROM syncLegacyPDFCacheOrphan WHERE localFilename = ?
                    UNION ALL
                    SELECT 1 FROM syncLegacyPDFUploadQueueOrphan WHERE localFilename = ?
                )
                """, arguments: [
                    filename, filename, filename, filename, filename,
                ]) ?? false
            return !isReferenced
        }.sorted()
    }

    private static func localID(
        tableName: String,
        syncId: String,
        db: Database
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT id FROM \(tableName) WHERE syncId = ? LIMIT 1",
            arguments: [syncId]
        )
    }

    private static func markDirty(
        type: SyncEntityType,
        entityId: String,
        db: Database
    ) throws {
        try SyncStateStore().queueSave(
            db,
            entityType: type,
            entityId: entityId
        )
    }

    /// Retire a reconciliation loser without ever guessing that a local-only
    /// identity existed in CloudKit. Archived system fields (or an already
    /// eligible tombstone) prove server observation; the currently fetched
    /// contender supplies the same proof explicitly.
    private static func retireLosingIdentity(
        type: SyncEntityType,
        entityId: String,
        serverObserved: Bool = false,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        let archivedOnServer = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM syncState
                WHERE entityType = ? AND entityId = ?
                  AND systemFields IS NOT NULL
            )
            """, arguments: [type.rawValue, entityId]) ?? false
        let alreadyEligible = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM tombstone
                WHERE entityType = ? AND entityId = ?
                  AND isPushEligible = 1
            )
            """, arguments: [type.rawValue, entityId]) ?? false
        let canDeleteFromServer = serverObserved || archivedOnServer || alreadyEligible

        if canDeleteFromServer {
            // Replace any retained confirmed tombstone: proof of an earlier
            // deletion must not suppress this new, server-evidenced delete.
            try stateStore.queueDelete(
                db,
                entityType: type,
                entityId: entityId,
                isPushEligible: true
            )
        } else {
            try stateStore.removeState(
                db,
                entityType: type,
                entityId: entityId
            )
            try db.execute(sql: """
                DELETE FROM tombstone
                WHERE entityType = ? AND entityId = ?
                  AND confirmedByServer = 0
                """, arguments: [type.rawValue, entityId])
        }
    }

    private static func rekeyTagPivots(
        tagId: Int64,
        from oldTagSyncId: String,
        to newTagSyncId: String,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        let pivots = try Row.fetchAll(db, sql: """
            SELECT syncId, referenceSyncId
            FROM referenceTag WHERE tagId = ? AND tagSyncId = ?
            """, arguments: [tagId, oldTagSyncId])
        for pivot in pivots {
            let oldSyncId: String = pivot["syncId"]
            let referenceSyncId: String = pivot["referenceSyncId"]
            let newSyncId = "\(referenceSyncId)/\(newTagSyncId)"
            if oldSyncId != newSyncId {
                try Self.retireLosingIdentity(
                    type: .referenceTag,
                    entityId: oldSyncId,
                    stateStore: stateStore,
                    db: db
                )
            }
            try db.execute(sql: """
                UPDATE referenceTag
                SET syncId = ?, tagSyncId = ?
                WHERE tagId = ? AND syncId = ?
                """, arguments: [newSyncId, newTagSyncId, tagId, oldSyncId])
            try Self.markDirty(
                type: .referenceTag,
                entityId: newSyncId,
                db: db
            )
        }
    }

    /// Merge two already-materialized tag rows after a remote rename creates a
    /// unique-name collision. Pivots move before the loser row is deleted so
    /// its FK cascade cannot discard associations.
    private static func mergeTagRows(
        winnerId: Int64,
        loserId: Int64,
        winnerSyncId: String,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        let pivots = try Row.fetchAll(db, sql: """
            SELECT syncId, referenceId, referenceSyncId
            FROM referenceTag WHERE tagId = ?
            """, arguments: [loserId])
        for pivot in pivots {
            let oldIdentity: String = pivot["syncId"]
            let referenceId: Int64 = pivot["referenceId"]
            let referenceSyncId: String = pivot["referenceSyncId"]
            let newIdentity = "\(referenceSyncId)/\(winnerSyncId)"
            if let existingIdentity = try String.fetchOne(db, sql: """
                SELECT syncId FROM referenceTag
                WHERE referenceId = ? AND tagId = ? LIMIT 1
                """, arguments: [referenceId, winnerId]) {
                try Self.retireLosingIdentity(
                    type: .referenceTag,
                    entityId: oldIdentity,
                    stateStore: stateStore,
                    db: db
                )
                try db.execute(sql: """
                    DELETE FROM referenceTag
                    WHERE referenceId = ? AND tagId = ?
                    """, arguments: [referenceId, loserId])
                if existingIdentity != newIdentity {
                    try Self.retireLosingIdentity(
                        type: .referenceTag,
                        entityId: existingIdentity,
                        stateStore: stateStore,
                        db: db
                    )
                    try db.execute(sql: """
                        UPDATE referenceTag
                        SET syncId = ?, tagSyncId = ?
                        WHERE referenceId = ? AND tagId = ?
                        """, arguments: [
                            newIdentity, winnerSyncId, referenceId, winnerId,
                        ])
                }
            } else {
                if oldIdentity != newIdentity {
                    try Self.retireLosingIdentity(
                        type: .referenceTag,
                        entityId: oldIdentity,
                        stateStore: stateStore,
                        db: db
                    )
                }
                try db.execute(sql: """
                    UPDATE referenceTag
                    SET syncId = ?, tagId = ?, tagSyncId = ?
                    WHERE referenceId = ? AND tagId = ?
                    """, arguments: [
                        newIdentity, winnerId, winnerSyncId,
                        referenceId, loserId,
                    ])
            }
            try Self.markDirty(
                type: .referenceTag,
                entityId: newIdentity,
                db: db
            )
        }
        try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [loserId])
    }

    private static func preparePropertyDefinitionForApply(
        _ row: inout PropertyDefinition,
        localId: Int64?,
        db: Database
    ) throws {
        guard let fieldKey = row.defaultFieldKey else { return }
        // A defaultFieldKey-bearing definition is a built-in regardless of a
        // peer's mutable isDefault payload.
        row.isDefault = true
        guard fieldKey == "referenceType" else { return }
        if let healed = TypeOptionsReconciler
            .appendingMissingTypeOptions(toOptionsJSON: row.optionsJSON)
        {
            row.optionsJSON = healed
        } else if let localId,
                  let localOptions = try String.fetchOne(
                    db,
                    sql: "SELECT optionsJSON FROM propertyDefinition WHERE id = ?",
                    arguments: [localId]
                  )
        {
            row.optionsJSON = localOptions
        }
    }

    private static func rekeyPropertyValues(
        propertyId: Int64,
        from oldPropertySyncId: String,
        to newPropertySyncId: String,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        let values = try Row.fetchAll(db, sql: """
            SELECT id, syncId, referenceSyncId
            FROM propertyValue
            WHERE propertyId = ? AND propertySyncId = ?
            """, arguments: [propertyId, oldPropertySyncId])
        for value in values {
            let id: Int64 = value["id"]
            let oldSyncId: String = value["syncId"]
            let referenceSyncId: String = value["referenceSyncId"]
            let oldDerived = "\(referenceSyncId)/\(oldPropertySyncId)"
            let newSyncId = oldSyncId == oldDerived
                ? "\(referenceSyncId)/\(newPropertySyncId)"
                : oldSyncId

            if oldSyncId != newSyncId {
                try Self.retireLosingIdentity(
                    type: .propertyValue,
                    entityId: oldSyncId,
                    stateStore: stateStore,
                    db: db
                )
            }
            try db.execute(sql: """
                UPDATE propertyValue
                SET syncId = ?, propertySyncId = ?
                WHERE id = ?
                """, arguments: [newSyncId, newPropertySyncId, id])
            try Self.markDirty(
                type: .propertyValue,
                entityId: newSyncId,
                db: db
            )
        }
    }

    /// Move values off a duplicate definition before deleting it. Endpoint
    /// collisions use the same permanent PropertyValue identity order as the
    /// ordinary pull path, so every peer keeps the same row.
    private static func mergePropertyDefinitionRows(
        winnerId: Int64,
        loserId: Int64,
        winnerSyncId: String,
        loserSyncId: String,
        stateStore: SyncStateStore,
        db: Database
    ) throws {
        let values = try Row.fetchAll(db, sql: """
            SELECT id, syncId, referenceId, referenceSyncId, value, dateModified
            FROM propertyValue WHERE propertyId = ?
            """, arguments: [loserId])
        for value in values {
            let loserValueId: Int64 = value["id"]
            let oldIdentity: String = value["syncId"]
            let referenceId: Int64 = value["referenceId"]
            let referenceSyncId: String = value["referenceSyncId"]
            let derivedIdentity = "\(referenceSyncId)/\(winnerSyncId)"
            if let existing = try Row.fetchOne(db, sql: """
                SELECT id, syncId FROM propertyValue
                WHERE referenceId = ? AND propertyId = ? LIMIT 1
                """, arguments: [referenceId, winnerId]) {
                let existingId: Int64 = existing["id"]
                let existingIdentity: String = existing["syncId"]
                let preferred = Self.preferredPropertyValueIdentity(
                    existingIdentity,
                    oldIdentity,
                    derivedIdentity: derivedIdentity
                )
                try db.execute(
                    sql: "DELETE FROM propertyValue WHERE id = ?",
                    arguments: [loserValueId]
                )
                if preferred == oldIdentity {
                    if existingIdentity != preferred {
                        try Self.retireLosingIdentity(
                            type: .propertyValue,
                            entityId: existingIdentity,
                            stateStore: stateStore,
                            db: db
                        )
                    }
                    let scalar: String? = value["value"]
                    let modified: Date = value["dateModified"]
                    try db.execute(sql: """
                        UPDATE propertyValue
                        SET syncId = ?, propertySyncId = ?,
                            value = ?, dateModified = ?
                        WHERE id = ?
                        """, arguments: [
                            preferred, winnerSyncId, scalar, modified, existingId,
                        ])
                } else {
                    try Self.retireLosingIdentity(
                        type: .propertyValue,
                        entityId: oldIdentity,
                        stateStore: stateStore,
                        db: db
                    )
                }
                try Self.markDirty(
                    type: .propertyValue,
                    entityId: preferred,
                    db: db
                )
            } else {
                let oldDerived = "\(referenceSyncId)/\(loserSyncId)"
                let newIdentity = oldIdentity == oldDerived
                    ? derivedIdentity : oldIdentity
                if newIdentity != oldIdentity {
                    try Self.retireLosingIdentity(
                        type: .propertyValue,
                        entityId: oldIdentity,
                        stateStore: stateStore,
                        db: db
                    )
                }
                try db.execute(sql: """
                    UPDATE propertyValue
                    SET syncId = ?, propertyId = ?, propertySyncId = ?
                    WHERE id = ?
                    """, arguments: [
                        newIdentity, winnerId, winnerSyncId, loserValueId,
                    ])
                try Self.markDirty(
                    type: .propertyValue,
                    entityId: newIdentity,
                    db: db
                )
            }
        }
        try db.execute(
            sql: "DELETE FROM propertyDefinition WHERE id = ?",
            arguments: [loserId]
        )
    }

    private static func preferredPropertyValueIdentity(
        _ lhs: String,
        _ rhs: String,
        derivedIdentity: String
    ) -> String {
        let lhsDecimal = SyncIdentifier.isCanonicalDecimal(lhs)
        let rhsDecimal = SyncIdentifier.isCanonicalDecimal(rhs)
        if lhsDecimal || rhsDecimal {
            return SyncIdentifier.preferred(lhs, rhs)
        }
        if lhs == derivedIdentity { return lhs }
        if rhs == derivedIdentity { return rhs }
        return min(lhs, rhs)
    }

    private static func deleteBySyncId(
        tableName: String,
        syncId: String,
        db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM \(tableName) WHERE syncId = ?",
            arguments: [syncId]
        )
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
            guard let row = try ReadingActivity.fetchOne(
                db,
                sql: "SELECT * FROM readingActivity WHERE syncId = ? LIMIT 1",
                arguments: [entityId]
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
            for row in rows {
                let oldID = row.entityId
                let newID = "\(nextGeneration)/\(row.installationId)/\(row.referenceSyncId)/\(row.localDay.rawValue)"
                try db.execute(
                    sql: """
                        UPDATE readingActivity
                        SET syncId = ?, epochRevision = ?, generation = ?,
                            dateModified = ?
                        WHERE syncId = ?
                        """,
                    arguments: [newID, nextRevision, nextGeneration, now, oldID]
                )
                try stateStore.removeState(db, entityType: .readingActivity, entityId: oldID)
                try stateStore.removeTombstone(db, entityType: .readingActivity, entityId: oldID)
                try stateStore.queueSave(
                    db,
                    entityType: .readingActivity,
                    entityId: newID
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
                try stateStore.queueSave(
                    db,
                    entityType: .assistantActivity,
                    entityId: id
                )
            }
        }

        let rebasedEpoch = ActivityEpoch(
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
        // The record was just observed on the server. Queue a fresh local
        // delete even if an older confirmed tombstone still exists.
        try stateStore.queueDelete(
            db,
            entityType: type,
            entityId: entityId
        )
    }

    /// Resolve FK violations that remain at the successful end of a known
    /// full-history zone fetch. Never call this for an incremental fetch:
    /// its delta is not a complete server snapshot, so a locally missing
    /// parent may still predate the saved cursor. Full-history pull batches
    /// deliberately tolerate children whose parents may arrive later, but
    /// their successful end-of-zone boundary proves there is no later batch.
    /// Any child still orphaned is stale server debris.
    ///
    /// Synced child rows are deleted with normal triggers enabled so an
    /// unconfirmed tombstone removes the stale CKRecord from the server.
    /// `metadataIntake.linkedReferenceId` is nullable (`ON DELETE SET NULL`),
    /// so preserve that row and push a repaired nil link instead. `pdfCache`
    /// and `pdfUploadQueue` are local-only; the former represents a
    /// `CDReferencePDF` sibling and therefore receives an explicit
    /// `referencePDF` tombstone.
    ///
    /// The caller owns the transaction and removes returned PDF filenames
    /// only after commit. If a future table introduces an unhandled FK shape,
    /// throw rather than make the CKSyncEngine cursor durable over a database
    /// that still violates its schema.
    static func reconcileTerminalOrphansAfterFetch(
        stateStore: SyncStateStore,
        db: Database
    ) throws -> FetchOrphanReconciliationOutcome {
        let rowIDsByTable = try legacyForeignKeyCandidateRowIDs(db: db)

        var outcome = FetchOrphanReconciliationOutcome()

        // Preserve metadata intake history: its optional reference link is
        // explicitly ON DELETE SET NULL in the schema.
        for rowID in rowIDsByTable["metadataIntake", default: []].sorted() {
            try db.execute(
                sql: """
                    UPDATE metadataIntake
                    SET linkedReferenceId = NULL, linkedReferenceSyncId = NULL
                    WHERE rowid = ?
                    """,
                arguments: [rowID]
            )
            outcome.reconciledRowCount += db.changesCount
        }

        // Every table here syncs directly and has a normal delete trigger.
        // Remove any old confirmed tombstone first: the record was just
        // observed on the server, so this deletion must be queued again.
        let syncedDeleteTables: [(table: String, type: SyncEntityType)] = [
            ("referenceTag", .referenceTag),
            ("pdfAnnotation", .pdfAnnotation),
            ("webAnnotation", .webAnnotation),
            ("metadataEvidence", .metadataEvidence),
            ("propertyValue", .propertyValue),
            ("readingActivity", .readingActivity),
        ]
        for entry in syncedDeleteTables {
            for rowID in rowIDsByTable[entry.table, default: []].sorted() {
                guard let entityId = try orphanEntityID(
                    table: entry.table,
                    rowID: rowID,
                    db: db
                ) else { continue }
                try stateStore.removeTombstone(
                    db,
                    entityType: entry.type,
                    entityId: entityId
                )
                try db.execute(
                    sql: "DELETE FROM \(entry.table) WHERE rowid = ?",
                    arguments: [rowID]
                )
                outcome.reconciledRowCount += db.changesCount
            }
        }

        // A pulled CDReferencePDF materializes into local-only pdfCache.
        // Queue the sibling server record's deletion explicitly, then return
        // the filename for post-commit unlink.
        for rowID in rowIDsByTable["pdfCache", default: []].sorted() {
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT pc.referenceId, pc.localFilename, r.syncId
                    FROM pdfCache pc
                    LEFT JOIN reference r ON r.id = pc.referenceId
                    WHERE pc.rowid = ?
                    """,
                arguments: [rowID]
            ) else { continue }
            let filename: String = row["localFilename"]
            guard let entityId: String = row["syncId"] else {
                try db.execute(
                    sql: "DELETE FROM pdfCache WHERE rowid = ?",
                    arguments: [rowID]
                )
                outcome.reconciledRowCount += db.changesCount
                outcome.pdfFilenamesToDelete.append(filename)
                continue
            }
            try stateStore.queueDelete(
                db,
                entityType: .referencePDF,
                entityId: entityId
            )
            try db.execute(
                sql: "DELETE FROM pdfCache WHERE rowid = ?",
                arguments: [rowID]
            )
            outcome.reconciledRowCount += db.changesCount
            outcome.pdfFilenamesToDelete.append(filename)
        }

        // Migrated v12 cache orphans are physically outside the live cache,
        // so their decimal identity cannot be captured by an unrelated local
        // row while replay is pending.
        for rowID in rowIDsByTable["syncLegacyPDFCacheOrphan", default: []].sorted() {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM syncLegacyPDFCacheOrphan WHERE rowid = ?",
                arguments: [rowID]
            ) else { continue }
            let entityId: String = row["legacyReferenceSyncId"]
            let filename: String = row["localFilename"]
            try stateStore.queueDelete(
                db,
                entityType: .referencePDF,
                entityId: entityId
            )
            try db.execute(
                sql: "DELETE FROM syncLegacyPDFCacheOrphan WHERE rowid = ?",
                arguments: [rowID]
            )
            outcome.reconciledRowCount += db.changesCount
            outcome.pdfFilenamesToDelete.append(filename)
        }

        // A queue row has never become a server PDF record by itself.
        for rowID in rowIDsByTable["pdfUploadQueue", default: []].sorted() {
            try db.execute(
                sql: "DELETE FROM pdfUploadQueue WHERE rowid = ?",
                arguments: [rowID]
            )
            outcome.reconciledRowCount += db.changesCount
        }
        for rowID in rowIDsByTable["syncLegacyPDFUploadQueueOrphan", default: []].sorted() {
            try db.execute(
                sql: "DELETE FROM syncLegacyPDFUploadQueueOrphan WHERE rowid = ?",
                arguments: [rowID]
            )
            outcome.reconciledRowCount += db.changesCount
        }

        // This representation cache is local-only and can be regenerated.
        for rowID in rowIDsByTable["webContentMarkdownCache", default: []].sorted() {
            try db.execute(
                sql: "DELETE FROM webContentMarkdownCache WHERE rowid = ?",
                arguments: [rowID]
            )
            outcome.reconciledRowCount += db.changesCount
        }
        for rowID in rowIDsByTable["syncLegacyWebContentCacheOrphan", default: []].sorted() {
            try db.execute(
                sql: "DELETE FROM syncLegacyWebContentCacheOrphan WHERE rowid = ?",
                arguments: [rowID]
            )
            outcome.reconciledRowCount += db.changesCount
        }

        // Global-FK children cannot be represented as transient SQLite FK
        // violations before their UUID parent exists, so v13 retains their
        // complete wire records in syncOrphan. At the successful end of a
        // full-history fetch, an unresolved parent is proven absent from the
        // zone and the stale child can be retired safely.
        let wireOrphans = try Row.fetchAll(
            db,
            sql: "SELECT * FROM syncOrphan ORDER BY receivedAt, recordName"
        )
        for orphan in wireOrphans {
            let data: Data = orphan["recordData"]
            guard let record = try SyncRecordIdentity.unarchive(data),
                  let type = SyncEntityType.forRecordType(record.recordType),
                  let parsed = SyncEntityType.parseRecordName(
                    record.recordID.recordName
                  ), parsed.0 == type,
                  try type.remoteDependencyStatus(
                    for: record,
                    entityId: parsed.1,
                    db: db
                  ) == .unresolved
            else { continue }
            try stateStore.queueDelete(
                db,
                entityType: type,
                entityId: parsed.1,
                isPushEligible: true
            )
            if let filename: String = orphan["stagedFilename"] {
                outcome.pdfFilenamesToDelete.append(filename)
            }
            try db.execute(
                sql: "DELETE FROM syncOrphan WHERE recordName = ?",
                arguments: [record.recordID.recordName]
            )
            outcome.reconciledRowCount += 1
        }

        let remaining = try legacyForeignKeyCandidateRowIDs(db: db)
            .values.reduce(0) { $0 + $1.count }
        guard remaining == 0 else {
            throw UnresolvedFetchOrphansError(count: remaining)
        }

        return outcome
    }

    private static func orphanEntityID(
        table: String,
        rowID: Int64,
        db: Database
    ) throws -> String? {
        switch table {
        case "referenceTag":
            return try String.fetchOne(
                db,
                sql: "SELECT syncId FROM referenceTag WHERE rowid = ?",
                arguments: [rowID]
            )

        case "readingActivity":
            return try String.fetchOne(
                db,
                sql: "SELECT syncId FROM readingActivity WHERE rowid = ?",
                arguments: [rowID]
            )

        default:
            return try String.fetchOne(
                db,
                sql: "SELECT syncId FROM \(table) WHERE rowid = ?",
                arguments: [rowID]
            )
        }
    }

    static func reconcileActivityQuarantineAfterFetch(
        deleteMissingReferenceFacts: Bool,
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
                let referenceSyncId: String? = row["referenceSyncId"]
                guard let activity = try decodeQuarantinedReadingActivity(
                    data: data,
                    fallbackReferenceSyncId: referenceSyncId,
                    db: db
                ) else {
                    try queueActivityDeletion(
                        type: type,
                        entityId: entityId,
                        recordName: recordName,
                        stateStore: stateStore,
                        db: db
                    )
                    continue
                }
                if try localID(
                    tableName: "reference",
                    syncId: activity.referenceSyncId,
                    db: db
                ) == nil {
                    // An incremental delta is not a complete server snapshot:
                    // the unchanged parent may predate this device's cursor.
                    // Only a completed full-history replay proves the remote
                    // activity is permanently orphaned.
                    if deleteMissingReferenceFacts {
                        try queueActivityDeletion(
                            type: type,
                            entityId: entityId,
                            recordName: recordName,
                            stateStore: stateStore,
                            db: db
                        )
                    }
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

    /// Retry full CKRecord payloads that arrived before one of their global
    /// FK parents. Returns displaced PDF filenames for post-commit unlink.
    /// The bounded fixed-point loop also handles an orphan parent and child
    /// becoming resolvable in the same fetched event.
    static func replayQuarantinedRemoteRecords(
        stateStore: SyncStateStore,
        db: Database
    ) throws -> [String] {
        var displacedFilenames: [String] = []
        var madeProgress = true

        while madeProgress {
            madeProgress = false
            var legacyOrphanRepairNeeded = false
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM syncOrphan ORDER BY receivedAt, recordName"
            )
            for row in rows {
                let data: Data = row["recordData"]
                guard let record = try SyncRecordIdentity.unarchive(data),
                      let type = SyncEntityType.forRecordType(record.recordType),
                      let parsed = SyncEntityType.parseRecordName(
                        record.recordID.recordName
                      ), parsed.0 == type
                else { continue }
                let entityId = parsed.1
                guard try type.remoteDependencyStatus(
                    for: record,
                    entityId: entityId,
                    db: db
                ) == .ready else { continue }

                if try stateStore.activeDeleteSuppressesRemoteRecord(
                    db,
                    entityType: type,
                    entityId: entityId
                ) {
                    // The dependency arrived after this server record was
                    // quarantined, but a newer local delete still owns the
                    // identity. Retire the stale wire copy without ever
                    // rematerializing it.
                    let stagedFilename: String? = row["stagedFilename"]
                    try db.execute(
                        sql: "DELETE FROM syncOrphan WHERE recordName = ?",
                        arguments: [record.recordID.recordName]
                    )
                    if let stagedFilename {
                        displacedFilenames += try unreferencedPDFFilenames(
                            Set([stagedFilename]),
                            db: db
                        )
                    }
                    madeProgress = true
                    continue
                }

                let applied: Bool
                if type == .referencePDF {
                    guard let payload = ReferencePDFRecord(record: record),
                          let stagedFilename: String = row["stagedFilename"]
                    else { continue }
                    let prepared = PreparedReferencePDFMaterialization(
                        referenceSyncId: entityId,
                        payload: payload,
                        stagedURL: AppDatabase.pdfStorageURL
                            .appendingPathComponent(stagedFilename),
                        stagedFilename: stagedFilename,
                        reuseHint: nil
                    )
                    guard let canonicalPrepared = try
                        canonicalizedReferencePDFMaterialization(prepared, db: db)
                    else { continue }
                    if let prior = try applyPreparedReferencePDF(
                        canonicalPrepared,
                        db: db
                    ) {
                        displacedFilenames.append(prior)
                    }
                    try retireAliasedReferencePDFIdentity(
                        observedEntityId: entityId,
                        canonicalEntityId: canonicalPrepared.referenceSyncId,
                        stateStore: stateStore,
                        db: db
                    )
                    applied = true
                } else {
                    applied = try type.applyRemoteRecord(
                        record,
                        entityId: entityId,
                        db: db,
                        stateStore: stateStore
                    )
                }
                guard applied else { continue }
                legacyOrphanRepairNeeded = legacyOrphanRepairNeeded
                    || type.suppliesGlobalDependencies

                if try !stateStore.hasActiveDeleteIntent(
                    db,
                    entityType: type,
                    entityId: entityId
                ) {
                    // Confirmed and legacy-ineligible tombstones are
                    // historical. A replayed server row supersedes them.
                    try stateStore.removeTombstone(
                        db,
                        entityType: type,
                        entityId: entityId
                    )
                    try stateStore.markPulled(
                        db,
                        entityType: type,
                        entityId: entityId,
                        record: record
                    )
                }
                try db.execute(
                    sql: "DELETE FROM syncOrphan WHERE recordName = ?",
                    arguments: [record.recordID.recordName]
                )
                madeProgress = true
            }
            if legacyOrphanRepairNeeded {
                displacedFilenames += try Self
                    .repairResolvableLegacyForeignKeyOrphans(db: db)
            }
        }
        return displacedFilenames
    }

    private static func upsertReadingActivity(_ row: ReadingActivity, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO readingActivity
                    (syncId, installationId, referenceId, referenceSyncId,
                     localDay, epochRevision, generation, activeSeconds,
                     lastActiveAt, dateModified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(generation, installationId, referenceId, localDay)
                DO UPDATE SET
                    syncId = excluded.syncId,
                    referenceSyncId = excluded.referenceSyncId,
                    epochRevision = MAX(readingActivity.epochRevision, excluded.epochRevision),
                    activeSeconds = MAX(readingActivity.activeSeconds, excluded.activeSeconds),
                    lastActiveAt = MAX(readingActivity.lastActiveAt, excluded.lastActiveAt),
                    dateModified = MAX(readingActivity.dateModified, excluded.dateModified)
                """,
            arguments: [
                row.syncId, row.installationId, row.referenceId,
                row.referenceSyncId, row.localDay, row.epochRevision,
                row.generation, row.activeSeconds, row.lastActiveAt,
                row.dateModified,
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

    private struct ReadingActivityQuarantinePayload: Codable {
        let version: Int
        let syncId: String
        let installationId: String
        let referenceSyncId: String
        let localDay: LocalDay
        let epochRevision: Int
        let generation: String
        let activeSeconds: Int64
        let lastActiveAt: Date
        let dateModified: Date

        init(_ row: ReadingActivity) {
            version = 1
            syncId = row.syncId
            installationId = row.installationId
            referenceSyncId = row.referenceSyncId
            localDay = row.localDay
            epochRevision = row.epochRevision
            generation = row.generation
            activeSeconds = row.activeSeconds
            lastActiveAt = row.lastActiveAt
            dateModified = row.dateModified
        }

        func materialized(referenceId: Int64) -> ReadingActivity {
            ReadingActivity(
                syncId: syncId,
                installationId: installationId,
                referenceId: referenceId,
                referenceSyncId: referenceSyncId,
                localDay: localDay,
                epochRevision: epochRevision,
                generation: generation,
                activeSeconds: activeSeconds,
                lastActiveAt: lastActiveAt,
                dateModified: dateModified
            )
        }
    }

    private static func decodeQuarantinedReadingActivity(
        data: Data,
        fallbackReferenceSyncId: String?,
        db: Database
    ) throws -> ReadingActivity? {
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(
            ReadingActivityQuarantinePayload.self,
            from: data
        ), let referenceId = try localID(
            tableName: "reference",
            syncId: payload.referenceSyncId,
            db: db
        ) {
            return payload.materialized(referenceId: referenceId)
        }

        // v12/v13 migration compatibility: old quarantine rows encoded the
        // local model directly. Resolve their migrated global identity before
        // replay and never trust the serialized local referenceId as a wire
        // address.
        guard var legacy = try? decoder.decode(ReadingActivity.self, from: data),
              let referenceSyncId = fallbackReferenceSyncId ?? (
                legacy.referenceSyncId.isEmpty ? nil : legacy.referenceSyncId
              ),
              let referenceId = try localID(
                tableName: "reference",
                syncId: referenceSyncId,
                db: db
              ) else { return nil }
        legacy.referenceId = referenceId
        legacy.referenceSyncId = referenceSyncId
        if legacy.syncId.isEmpty {
            legacy.syncId = "\(legacy.generation)/\(legacy.installationId)/\(referenceSyncId)/\(legacy.localDay.rawValue)"
        }
        return legacy
    }

    private static func quarantine(
        _ row: ReadingActivity,
        recordName: String,
        db: Database
    ) throws {
        let reason = try localID(
            tableName: "reference",
            syncId: row.referenceSyncId,
            db: db
        ) == nil ? "reference" : "epoch"
        try storeQuarantine(
            recordName: recordName,
            entityType: SyncEntityType.readingActivity.rawValue,
            reason: reason,
            epochRevision: row.epochRevision,
            generation: row.generation,
            referenceId: row.referenceId,
            referenceSyncId: row.referenceSyncId,
            data: try JSONEncoder().encode(ReadingActivityQuarantinePayload(row)),
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
            referenceSyncId: nil,
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
        referenceSyncId: String?,
        data: Data,
        db: Database
    ) throws {
        guard data.count <= 64 * 1024 else { return }
        try db.execute(
            sql: """
                INSERT INTO activityQuarantine
                    (recordName, entityType, reason, epochRevision, generation,
                     referenceId, referenceSyncId, recordData, receivedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(recordName) DO UPDATE SET
                    entityType = excluded.entityType,
                    reason = excluded.reason,
                    epochRevision = excluded.epochRevision,
                    generation = excluded.generation,
                    referenceId = excluded.referenceId,
                    referenceSyncId = excluded.referenceSyncId,
                    recordData = excluded.recordData,
                    receivedAt = excluded.receivedAt
                """,
            arguments: [
                recordName, entityType, reason, epochRevision, generation,
                referenceId, referenceSyncId, data, Date(),
            ]
        )
    }

    static func replayQuarantinedActivity(
        referenceSyncIds: Set<String> = [],
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
            if !referenceSyncIds.isEmpty {
                let placeholders = Array(
                    repeating: "?",
                    count: referenceSyncIds.count
                ).joined(separator: ",")
                rows += try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM activityQuarantine
                        WHERE entityType = 'readingActivity'
                          AND referenceSyncId IN (\(placeholders))
                        ORDER BY receivedAt
                        """,
                    arguments: StatementArguments(referenceSyncIds.sorted())
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
                let referenceSyncId: String? = quarantined["referenceSyncId"]
                guard let activity = try decodeQuarantinedReadingActivity(
                    data: data,
                    fallbackReferenceSyncId: referenceSyncId,
                    db: db
                ) else { continue }
                guard try activityFactCanApply(
                        kind: .reading,
                        epochRevision: activity.epochRevision,
                        generation: activity.generation,
                        referenceId: activity.referenceId,
                        db: db
                      ) else {
                    if try localID(
                        tableName: "reference",
                        syncId: activity.referenceSyncId,
                        db: db
                    ) != nil {
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
                    try SyncStateStore().queueSave(
                        db,
                        entityType: .readingActivity,
                        entityId: parsed.1
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
