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

    /// Archive the system fields of a freshly-saved record so the next push
    /// can rehydrate it and get optimistic concurrency via the change tag.
    /// Also clears `isDirty` since the push succeeded.
    public func markPushed(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        record: CKRecord
    ) throws {
        let systemFields = Self.archiveSystemFields(of: record)
        try db.execute(sql: """
            INSERT INTO \(SQL.stateTable)
                (entityType, entityId, systemFields, lastPushedAt, isDirty)
                VALUES(?, ?, ?, ?, 0)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET
                        systemFields = excluded.systemFields,
                        lastPushedAt = excluded.lastPushedAt,
                        isDirty = 0
            """, arguments: [
                entityType.rawValue,
                entityId,
                systemFields,
                Date()
            ])
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

    /// All pending tombstones. Used on startup to enqueue deletions that
    /// were written locally but hadn't made it to the engine state yet.
    public func tombstones(_ db: Database) throws -> [(SyncEntityType, String)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT entityType, entityId FROM \(SQL.tombstoneTable)
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
    /// local deletes; the pull handler does this for remote deletes so any
    /// concurrent local push of the same ID short-circuits via
    /// `clearDirty` in the same transaction.
    public func upsertTombstone(
        _ db: Database,
        entityType: SyncEntityType,
        entityId: String,
        deletedAt: Date = Date()
    ) throws {
        try db.execute(sql: """
            INSERT INTO \(SQL.tombstoneTable)(entityType, entityId, deletedAt)
                VALUES(?, ?, ?)
                ON CONFLICT(entityType, entityId)
                    DO UPDATE SET deletedAt = excluded.deletedAt
            """, arguments: [entityType.rawValue, entityId, deletedAt])
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

    /// Compact old tombstones. B12: tombstones are kept long enough to beat
    /// any in-flight push, then garbage-collected so the table doesn't grow
    /// forever. 30 days is the plan default.
    public func compactTombstones(
        _ db: Database,
        olderThan cutoff: Date
    ) throws {
        try db.execute(
            sql: "DELETE FROM \(SQL.tombstoneTable) WHERE deletedAt < ?",
            arguments: [cutoff]
        )
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
