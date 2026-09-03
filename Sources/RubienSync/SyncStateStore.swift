#if canImport(CloudKit)
import Foundation
import GRDB
import CloudKit
import RubienCore

public struct DurableIntentRepairReport: Equatable, Sendable {
    public var removedLiveTombstoneCount = 0
    public var removedDeleteStateCount = 0
    public var removedCleanOrphanStateCount = 0
    public var preservedOrphanStateCount = 0
    public var clearedPushInFlightCount = 0
    public var repairedPDFIdentityCount = 0
    public var ambiguousPDFIdentityCount = 0
    public var upgradedActivityTombstoneCount = 0

    public var performedRepairCount: Int {
        removedLiveTombstoneCount
            + removedDeleteStateCount
            + removedCleanOrphanStateCount
            + clearedPushInFlightCount
            + repairedPDFIdentityCount
            + upgradedActivityTombstoneCount
    }

    public var isEmpty: Bool {
        performedRepairCount == 0 && preservedOrphanStateCount == 0
            && ambiguousPDFIdentityCount == 0
    }
}

/// Thin DB helpers for the sync-bookkeeping tables. Keeps raw SQL out of the
/// `SyncedLibrary` actor and collects the sync-state schema knowledge in one
/// place. Entity IDs are the stable global identities introduced by v13.
///
/// All methods that mutate must run inside a caller-owned transaction —
/// typically the same transaction that applies the remote record, so a crash
/// after row UPSERT but before we stamp `syncState.systemFields` can't strand
/// the row.
public struct SyncStateStore: Sendable {

    /// Table + column names. Centralised so a future rename surface is grep-able.
    enum SQL {
        static let sessionTable = "syncSession"
        static let stateTable   = "syncState"
        static let tombstoneTable = "tombstone"

        static let applyingRemoteKey = "applyingRemote"
        static let writerUpgradeRequiredKey = "writerUpgradeRequired"
    }

    public init() {}

    // MARK: - applyingRemote session guard

    /// Insert the `applyingRemote=1` row so the per-table triggers skip
    /// firing during the remote-apply transaction. Caller must pair this
    /// with `clearApplyingRemote` at the end of the same transaction.
    public func setApplyingRemote(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO \(SQL.sessionTable)(key, value) VALUES(?, '1')
                ON CONFLICT(key) DO UPDATE SET value='1'
            """, arguments: [SQL.applyingRemoteKey])
    }

    public func clearApplyingRemote(_ db: Database) throws {
        try db.execute(
            sql: "DELETE FROM \(SQL.sessionTable) WHERE key = ?",
            arguments: [SQL.applyingRemoteKey]
        )
    }

    public func writerUpgradeRequired(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM \(SQL.sessionTable)
                WHERE key = ? AND value = '1'
            )
            """, arguments: [SQL.writerUpgradeRequiredKey]) ?? true
    }

    public func acknowledgeWriterUpgrade(_ db: Database) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try db.execute(
            sql: "DELETE FROM \(SQL.sessionTable) WHERE key = ?",
            arguments: [SQL.writerUpgradeRequiredKey]
        )
        try db.execute(sql: """
            INSERT INTO \(SQL.sessionTable)(key, value)
                VALUES('writerUpgradeAcknowledgedAt', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [formatter.string(from: Date())])
        try db.execute(sql: """
            INSERT INTO \(SQL.sessionTable)(key, value)
                VALUES('writerUpgradeAcknowledgedSchemaVersion', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [AppDatabase.currentSchemaVersion])
    }

    // MARK: - syncState rows

    /// Mark rows as in-flight for a push attempt. Called from the batch
    /// builder before handing CKRecords to the engine. The per-table
    /// trigger clears `pushInFlight` on any local mutation, so a
    /// subsequent `markPushed` can detect "a fresh edit landed between
    /// build and ack" and refuse to clear isDirty in that case.
    @discardableResult
    public func markPushInFlight(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws -> Bool {
        try db.execute(sql: """
            UPDATE \(SQL.stateTable) SET pushInFlight = 1
                WHERE entityType = ? AND entityId = ? AND isDirty = 1
            """, arguments: [entityType.rawValue, entityId])
        return db.changesCount > 0
    }

    /// Release an attempted save without conceding its durable dirty intent.
    /// Every failed save path calls this so a later reconciliation can retry.
    public func releasePushInFlight(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try db.execute(sql: """
            UPDATE \(SQL.stateTable) SET pushInFlight = 0
            WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
    }

    /// Establish exactly one durable save intent inside the caller's
    /// transaction. This is the only non-trigger primitive for dirtying an
    /// entity: it also retires any stale delete for the same identity.
    public func queueSave(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try removeTombstone(db, entityType: entityType, entityId: entityId)
        try db.execute(sql: """
            INSERT INTO \(SQL.stateTable)(
                entityType, entityId, isDirty, pushInFlight
            ) VALUES(?, ?, 1, 0)
            ON CONFLICT(entityType, entityId) DO UPDATE SET
                isDirty = 1,
                pushInFlight = 0
            """, arguments: [entityType.rawValue, entityId])
    }

    /// Establish exactly one durable delete intent inside the caller's
    /// transaction. Removing an older tombstone first intentionally lets a
    /// local delete replace a retained, server-confirmed tombstone.
    public func queueDelete(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        deletedAt: Date = Date(),
        isPushEligible: Bool = true
    ) throws {
        try removeTombstone(db, entityType: entityType, entityId: entityId)
        try upsertTombstone(
            db,
            entityType: entityType,
            entityId: entityId,
            deletedAt: deletedAt,
            confirmedByServer: false,
            isPushEligible: isPushEligible
        )
        try removeState(db, entityType: entityType, entityId: entityId)
    }

    /// Archive the system fields of a freshly-saved record so the next push
    /// can rehydrate it and get optimistic concurrency via the change tag.
    /// Only clears `isDirty` when `pushInFlight` is still 1 — meaning no
    /// local edit fired a trigger between `markPushInFlight` and this ack.
    /// If a racing edit cleared pushInFlight (trigger path), isDirty stays
    /// 1 and the engine re-pushes on the next cycle.
    public func markPushed(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        record: CKRecord
    ) throws {
        // A local delete can land after the save batch is built and remove
        // syncState while leaving its tombstone. In that race the delete is
        // newer intent, so the save acknowledgement must not recreate state.
        guard try !hasTombstone(
            db,
            entityType: entityType,
            entityId: entityId
        ) else { return }
        let systemFields = Self.archiveSystemFields(of: record)
        try db.execute(sql: """
            INSERT INTO \(SQL.stateTable)
                (entityType, entityId, systemFields, lastPushedAt, isDirty, pushInFlight)
                VALUES(?, ?, ?, ?, 0, 0)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET
                        systemFields = excluded.systemFields,
                        lastPushedAt = excluded.lastPushedAt,
                        isDirty = CASE WHEN pushInFlight = 1 THEN 0 ELSE 1 END,
                        pushInFlight = 0
            """, arguments: [
                entityType.rawValue,
                entityId,
                systemFields,
                Date()
            ])
    }

    /// Drop the cached system fields without touching dirty / pushInFlight.
    /// Used on `.unknownItem`: the server says this record doesn't exist,
    /// so our cached change tag is stale — on next push we must create a
    /// fresh record rather than rehydrating. Dirty stays 1 so the retry
    /// actually happens; the server either confirms a tombstone (pull
    /// handles it) or accepts the fresh insert.
    public func clearSystemFields(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try db.execute(sql: """
            UPDATE \(SQL.stateTable) SET systemFields = NULL
                WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
    }

    /// Archive system fields on pull too — we'll need the server's change
    /// tag if we ever push our own edits to this row. `isDirty` is left at
    /// 0 (or inserted as 0) since we just synced the server's version.
    public func markPulled(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        record: CKRecord
    ) throws {
        let systemFields = Self.archiveSystemFields(of: record)
        try db.execute(sql: """
            INSERT INTO \(SQL.stateTable)
                (entityType, entityId, systemFields, isDirty, pushInFlight)
                VALUES(?, ?, ?, 0, 0)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET
                        systemFields = excluded.systemFields,
                        isDirty = 0,
                        pushInFlight = 0
            """, arguments: [
                entityType.rawValue,
                entityId,
                systemFields
            ])
    }

    /// Fetch the archived system fields blob for an entity, if any. Returns
    /// nil when we've never successfully synced this row (first-push case).
    public func loadSystemFields(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws -> Data? {
        try Data.fetchOne(db, sql: """
            SELECT systemFields FROM \(SQL.stateTable)
                WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
    }

    /// Drop the dirty flag for `entityId` — used when a remote delete races
    /// with a local pending push (remote delete wins, local push is moot).
    public func clearDirty(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try db.execute(sql: """
            UPDATE \(SQL.stateTable) SET isDirty = 0, pushInFlight = 0
                WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
    }

    /// Drop a syncState row entirely. Use for remote-delete apply, so we
    /// don't leave an orphan with stale systemFields after the DB row is
    /// gone.
    public func removeState(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try db.execute(sql: """
            DELETE FROM \(SQL.stateTable)
                WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
    }

    // MARK: - Durable intent repair

    /// Normalize SQLite's durable send intent before CKSyncEngine is first
    /// constructed. This runtime implementation intentionally does not share
    /// mutable behavior with the frozen v14 migration body.
    public func repairDurableIntent(
        _ db: Database
    ) throws -> DurableIntentRepairReport {
        var report = DurableIntentRepairReport()

        let pdfRepair = try repairSafePDFStateIdentities(db)
        report.repairedPDFIdentityCount = pdfRepair.repaired
        report.ambiguousPDFIdentityCount = pdfRepair.ambiguous

        // V7 activity tombstones were ineligible by construction. If a
        // remote modification later rematerialized the row, markPulled wrote
        // clean state because the tombstone was not active. Resolve that
        // historical live shape as a save before upgrading the remaining
        // absent-row markers into active deletes.
        let legacyActivitySources: [
            (entityType: String, from: String, identity: String)
        ] = [
            ("assistantActivity", "assistantActivity e", "e.id"),
            ("activityEpoch", "activityEpoch e", "e.kind"),
        ]
        for source in legacyActivitySources {
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                )
                SELECT ?, \(source.identity), 1, 0
                FROM \(source.from)
                WHERE EXISTS (
                    SELECT 1 FROM tombstone legacy
                    WHERE legacy.entityType = ?
                      AND legacy.entityId = \(source.identity)
                      AND legacy.confirmedByServer = 0
                      AND legacy.isPushEligible = 0
                )
                ON CONFLICT(entityType, entityId) DO UPDATE SET
                    isDirty = 1,
                    pushInFlight = 0
                """, arguments: [source.entityType, source.entityType])
            try db.execute(sql: """
                DELETE FROM tombstone
                WHERE entityType = ?
                  AND confirmedByServer = 0
                  AND isPushEligible = 0
                  AND EXISTS (
                    SELECT 1 FROM \(source.from)
                    WHERE \(source.identity) = tombstone.entityId
                  )
                """, arguments: [source.entityType])
            report.removedLiveTombstoneCount += db.changesCount
        }

        try db.execute(sql: """
            UPDATE tombstone SET isPushEligible = 1
            WHERE confirmedByServer = 0
              AND isPushEligible = 0
              AND entityType IN ('assistantActivity', 'activityEpoch')
            """)
        report.upgradedActivityTombstoneCount = db.changesCount

        try db.execute(sql: "UPDATE syncState SET pushInFlight = 0 WHERE pushInFlight = 1")
        report.clearedPushInFlightCount = db.changesCount

        for source in SyncLocalEntityCatalog.current {
            let type = source.entityType

            // A dirty live row is an explicit local recreation and wins over
            // a retained delete. A non-active historical tombstone also
            // yields to live data. By contrast, a live row with an active
            // tombstone and no dirty state can be a stale server modification
            // materialized after a local delete; that delete must survive.
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                SELECT ?, \(source.baselineIdentityExpression), 1, 0
                FROM \(source.baselineFromClause)
                WHERE EXISTS (
                    SELECT 1 FROM tombstone ts
                    WHERE ts.entityType = ?
                      AND ts.entityId = \(source.baselineIdentityExpression)
                )
                  AND (
                    EXISTS (
                        SELECT 1 FROM syncState ss
                        WHERE ss.entityType = ?
                          AND ss.entityId = \(source.baselineIdentityExpression)
                          AND ss.isDirty = 1
                    )
                    OR NOT EXISTS (
                        SELECT 1 FROM tombstone active
                        WHERE active.entityType = ?
                          AND active.entityId = \(source.baselineIdentityExpression)
                          AND active.confirmedByServer = 0
                          AND active.isPushEligible = 1
                    )
                  )
                ON CONFLICT(entityType, entityId) DO UPDATE SET
                    isDirty = 1,
                    pushInFlight = 0
                """, arguments: [type, type, type, type])
            try db.execute(sql: """
                DELETE FROM tombstone
                WHERE entityType = ?
                  AND EXISTS (
                    SELECT 1 FROM \(source.baselineFromClause)
                    WHERE \(source.baselineIdentityExpression) = tombstone.entityId
                  )
                  AND EXISTS (
                    SELECT 1 FROM syncState ss
                    WHERE ss.entityType = tombstone.entityType
                      AND ss.entityId = tombstone.entityId
                      AND ss.isDirty = 1
                  )
                """, arguments: [type])
            report.removedLiveTombstoneCount += db.changesCount

            // With no local row, or with an active local delete and no newer
            // dirty recreation, the tombstone is the durable intent. Drop
            // contradictory state but never invent a tombstone for an orphan.
            try db.execute(sql: """
                DELETE FROM syncState
                WHERE entityType = ?
                  AND EXISTS (
                    SELECT 1 FROM tombstone ts
                    WHERE ts.entityType = syncState.entityType
                      AND ts.entityId = syncState.entityId
                  )
                  AND (
                    NOT EXISTS (
                        SELECT 1 FROM \(source.baselineFromClause)
                        WHERE \(source.baselineIdentityExpression) = syncState.entityId
                    )
                    OR EXISTS (
                        SELECT 1 FROM tombstone active
                        WHERE active.entityType = syncState.entityType
                          AND active.entityId = syncState.entityId
                          AND active.confirmedByServer = 0
                          AND active.isPushEligible = 1
                    )
                  )
                """, arguments: [type])
            report.removedDeleteStateCount += db.changesCount

            // lastPushedAt IS NULL is not redundant with systemFields IS
            // NULL: clearSystemFields() deliberately drops the archive on an
            // unknownItem response while retaining the prior push timestamp.
            try db.execute(sql: """
                DELETE FROM syncState
                WHERE entityType = ?
                  AND isDirty = 0
                  AND systemFields IS NULL
                  AND lastPushedAt IS NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM tombstone ts
                    WHERE ts.entityType = syncState.entityType
                      AND ts.entityId = syncState.entityId
                      AND ts.confirmedByServer = 0
                      AND ts.isPushEligible = 1
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM \(source.baselineFromClause)
                    WHERE \(source.baselineIdentityExpression) = syncState.entityId
                  )
                """, arguments: [type])
            report.removedCleanOrphanStateCount += db.changesCount

            report.preservedOrphanStateCount += try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE entityType = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM \(source.baselineFromClause)
                    WHERE \(source.baselineIdentityExpression) = syncState.entityId
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM tombstone ts
                    WHERE ts.entityType = syncState.entityType
                      AND ts.entityId = syncState.entityId
                      AND ts.confirmedByServer = 0
                      AND ts.isPushEligible = 1
                  )
                """, arguments: [type]) ?? 0
        }
        return report
    }

    private func repairSafePDFStateIdentities(
        _ db: Database
    ) throws -> (repaired: Int, ambiguous: Int) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT entityId, systemFields, lastPushedAt
            FROM syncState
            WHERE entityType = 'referencePDF'
            ORDER BY entityId
            """)
        var repaired = 0
        var ambiguous = 0
        for row in rows {
            let oldId: String = row["entityId"]
            let systemFields: Data? = row["systemFields"]
            let lastPushedAt: Date? = row["lastPushedAt"]
            guard let classification = try PDFSyncStateIdentityClassifier
                .classify(
                    entityId: oldId,
                    systemFields: systemFields,
                    lastPushedAt: lastPushedAt,
                    db: db
                )
            else { continue }
            guard !classification.isAmbiguous else {
                ambiguous += 1
                continue
            }
            guard let newId = classification.repairTargetEntityId else {
                continue
            }

            let targetExists = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM syncState
                    WHERE entityType='referencePDF' AND entityId=?
                )
                """, arguments: [newId]) ?? true
            if targetExists {
                // Preserve target system fields and push timestamp; only
                // merge the stale row's outstanding save intent.
                try queueSave(db, entityType: .referencePDF, entityId: newId)
                try removeState(db, entityType: .referencePDF, entityId: oldId)
            } else {
                try db.execute(sql: """
                    UPDATE syncState
                    SET entityId = ?, isDirty = 1, pushInFlight = 0
                    WHERE entityType='referencePDF' AND entityId=?
                    """, arguments: [newId, oldId])
                try removeTombstone(
                    db,
                    entityType: .referencePDF,
                    entityId: newId
                )
            }
            repaired += 1
        }
        return (repaired, ambiguous)
    }

    // MARK: - Dirty + tombstone scans (startup reconciliation)

    /// All (entityType, entityId) pairs that need pushing. Used on startup
    /// to prime `CKSyncEngine.state` with pending changes — idempotent
    /// because `engine.state.add(...)` deduplicates.
    public func dirtyEntities(_ db: Database) throws -> [(SyncEntityType, String)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT entityType, entityId FROM \(SQL.stateTable) WHERE isDirty = 1
            """)
        return rows.compactMap { row in
            guard
                let raw: String = row["entityType"],
                let type = SyncEntityType(rawValue: raw),
                let id:  String = row["entityId"]
            else {
                return nil
            }
            return (type, id)
        }
    }

    /// Adopt the server's current change tag without conceding a local merge.
    /// Grow-only counters and rebased reset intents use this after consuming a
    /// `.serverRecordChanged` payload: the next retry must mutate the server's
    /// record, while `isDirty` remains set for that retry.
    public func adoptSystemFieldsKeepingDirty(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        record: CKRecord
    ) throws {
        // This is a specialized save-intent writer used by activity conflict
        // resolution, so it must obey the same exclusivity rule as queueSave.
        try removeTombstone(db, entityType: entityType, entityId: entityId)
        let systemFields = Self.archiveSystemFields(of: record)
        try db.execute(sql: """
            INSERT INTO \(SQL.stateTable)
                (entityType, entityId, systemFields, isDirty, pushInFlight)
                VALUES(?, ?, ?, 1, 0)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET
                        systemFields = excluded.systemFields,
                        isDirty = 1,
                        pushInFlight = 0
            """, arguments: [
                entityType.rawValue,
                entityId,
                systemFields,
            ])
    }

    /// All pending tombstones. Used on startup to enqueue deletions that
    /// were written locally but hadn't made it to the engine state yet.
    public func tombstones(_ db: Database) throws -> [(SyncEntityType, String)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT entityType, entityId FROM \(SQL.tombstoneTable)
            WHERE confirmedByServer = 0 AND isPushEligible = 1
            """)
        return rows.compactMap { row in
            guard
                let raw: String = row["entityType"],
                let type = SyncEntityType(rawValue: raw),
                let id:  String = row["entityId"]
            else {
                return nil
            }
            return (type, id)
        }
    }

    /// Whether the exact identity has an unacknowledged, sendable local
    /// delete. Confirmed and legacy-ineligible tombstones are historical
    /// markers, not active intent.
    public func hasActiveDeleteIntent(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT isPushEligible FROM \(SQL.tombstoneTable)
            WHERE entityType = ? AND entityId = ? AND confirmedByServer = 0
            """, arguments: [entityType.rawValue, entityId]) ?? false
    }

    /// Active local deletes suppress stale server modifications. A tombstone
    /// on a retired alias is different: late records for that server identity
    /// must still flow through reconciliation so their payload can update the
    /// canonical winner while the alias delete remains queued.
    public func activeDeleteSuppressesRemoteRecord(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws -> Bool {
        guard try hasActiveDeleteIntent(
            db,
            entityType: entityType,
            entityId: entityId
        ) else { return false }
        return try SyncIdentityAliasStore.resolve(
            entityType: entityType,
            identity: entityId,
            db: db
        ) == entityId
    }

    /// Insert (or refresh) a tombstone. The delete trigger does this for
    /// local deletes (unconfirmed); the pull handler does this for remote
    /// deletes with `confirmedByServer=true` (the server already decided).
    /// Unconfirmed tombstones are kept indefinitely by compaction until a
    /// delete acknowledgement promotes them via `markTombstoneConfirmed`.
    public func upsertTombstone(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        deletedAt: Date = Date(),
        confirmedByServer: Bool = false,
        isPushEligible: Bool = true
    ) throws {
        try db.execute(sql: """
            INSERT INTO \(SQL.tombstoneTable)
                (entityType, entityId, deletedAt, confirmedByServer, isPushEligible)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET
                        deletedAt = excluded.deletedAt,
                        confirmedByServer = CASE
                            WHEN \(SQL.tombstoneTable).confirmedByServer = 1 THEN 1
                            ELSE excluded.confirmedByServer
                        END,
                        isPushEligible = MAX(
                            \(SQL.tombstoneTable).isPushEligible,
                            excluded.isPushEligible
                        )
            """, arguments: [
                entityType.rawValue,
                entityId,
                deletedAt,
                confirmedByServer ? 1 : 0,
                isPushEligible ? 1 : 0,
            ])
    }

    /// Promote a tombstone from unconfirmed (pending server ack) to
    /// confirmed. Called from the sent-zone-changes success path for
    /// deletions. Confirmed tombstones are eligible for GC.
    public func markTombstoneConfirmed(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try db.execute(sql: """
            UPDATE \(SQL.tombstoneTable) SET confirmedByServer = 1
                WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
    }

    public func hasTombstone(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM \(SQL.tombstoneTable)
                WHERE entityType = ? AND entityId = ?
            )
            """, arguments: [entityType.rawValue, entityId]) ?? false
    }

    /// Purge a tombstone after the server has confirmed the delete (or has
    /// independently confirmed the row no longer exists on the server).
    public func removeTombstone(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try db.execute(sql: """
            DELETE FROM \(SQL.tombstoneTable)
                WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
    }

    /// Compact server-confirmed tombstones older than `cutoff`. Unconfirmed
    /// tombstones (local delete not yet ack'd) are kept regardless of age —
    /// evicting one can let a later server modification of the same
    /// recordID resurrect the deleted row, breaking the "delete beats edit"
    /// invariant.
    public func compactTombstones(
        _ db: Database,
        olderThan cutoff: Date
    ) throws {
        try db.execute(sql: """
            DELETE FROM \(SQL.tombstoneTable)
                WHERE deletedAt < ? AND confirmedByServer = 1
            """, arguments: [cutoff])
    }

    // MARK: - System-fields codec

    /// Archive a CKRecord's system fields (change tag, record ID, etc.) to
    /// `Data`. This is the canonical pattern — per Apple's sample
    /// `SyncedDatabase` and Selig 2026 — because `CKRecord.recordChangeTag`
    /// is read-only on a fresh record. To push an update with optimistic
    /// concurrency we must first rehydrate a record from its archived
    /// system fields, then overwrite scalars.
    public static func archiveSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        return archiver.encodedData
    }

    /// Rehydrate a CKRecord from archived system fields. Returns nil if the
    /// blob is corrupt (e.g. written by an older CloudKit version whose
    /// archive format changed). Caller should treat nil as "push as new"
    /// — we'll lose one change-tag optimistic-concurrency round and pick
    /// the server's record up on the next pull.
    public static func rehydrateRecord(from data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }
}
#endif
