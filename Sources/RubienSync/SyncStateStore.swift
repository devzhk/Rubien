#if canImport(CloudKit)
import Foundation
import GRDB
import CloudKit
import RubienCore

/// Thin DB helpers for the sync-bookkeeping tables. Keeps raw SQL out of the
/// `SyncedLibrary` actor and collects the schema knowledge in one place so a
/// future A-pks migration only has to update this file's queries.
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

    // MARK: - syncState rows

    /// Mark rows as in-flight for a push attempt. Called from the batch
    /// builder before handing CKRecords to the engine. The per-table
    /// trigger clears `pushInFlight` on any local mutation, so a
    /// subsequent `markPushed` can detect "a fresh edit landed between
    /// build and ack" and refuse to clear isDirty in that case.
    public func markPushInFlight(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String
    ) throws {
        try db.execute(sql: """
            UPDATE \(SQL.stateTable) SET pushInFlight = 1
                WHERE entityType = ? AND entityId = ?
            """, arguments: [entityType.rawValue, entityId])
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
                (entityType, entityId, systemFields, isDirty)
                VALUES(?, ?, ?, 0)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET
                        systemFields = excluded.systemFields,
                        isDirty = 0
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
            UPDATE \(SQL.stateTable) SET isDirty = 0
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
            WHERE confirmedByServer = 0
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

    /// Insert (or refresh) a tombstone. The delete trigger does this for
    /// local deletes (unconfirmed); the pull handler does this for remote
    /// deletes with `confirmedByServer=true` (the server already decided).
    /// Unconfirmed tombstones are kept indefinitely by compaction until a
    /// save-ack promotes them via `markTombstoneConfirmed`.
    public func upsertTombstone(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        deletedAt: Date = Date(),
        confirmedByServer: Bool = false
    ) throws {
        try db.execute(sql: """
            INSERT INTO \(SQL.tombstoneTable)(entityType, entityId, deletedAt, confirmedByServer)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET
                        deletedAt = excluded.deletedAt,
                        confirmedByServer = CASE
                            WHEN \(SQL.tombstoneTable).confirmedByServer = 1 THEN 1
                            ELSE excluded.confirmedByServer
                        END
            """, arguments: [
                entityType.rawValue,
                entityId,
                deletedAt,
                confirmedByServer ? 1 : 0
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
