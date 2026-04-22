import Foundation
import GRDB
import CloudKit
import RubienCore
import os.log

private let log = Logger(subsystem: "Rubien", category: "SyncedLibrary")

/// Actor that owns the single `CKSyncEngine` for the app. Mirrors Apple's
/// `SyncedDatabase` sample: one engine per process, DB is source of truth,
/// engine state is a derived cache in a sidecar file.
///
/// Scope of the current commit (B4): engine wiring, startup reconciliation,
/// push/pull dispatch via `SyncEntityDispatch`. Not yet wired: PDF
/// `CKAsset` handling (B8), `.serverRecordChanged` merge policy (B7 scalars),
/// account-change UX (sign-out preservation).
@available(macOS 14.0, iOS 17.0, *)
public actor SyncedLibrary: CKSyncEngineDelegate {

    // MARK: - Collaborators

    private let appDatabase: AppDatabase
    private let stateStore: SyncStateStore
    private let engineStateStore: SyncEngineStateStore
    private let container: CKContainer

    /// Lazy — we only build the engine after init so the delegate (`self`)
    /// is fully initialized. The CKSyncEngine API hands us back an async
    /// callback chain; it must be safe to call the delegate immediately.
    private var _engine: CKSyncEngine?

    /// Set to true on the first successful startup reconciliation. Further
    /// passes during the same process lifetime are no-ops (the engine state
    /// is now the source of pending changes).
    private var didRunStartupReconciliation = false

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        container: CKContainer = CKContainer(identifier: SyncConstants.containerIdentifier),
        stateFileURL: URL = AppDatabase.syncEngineStateURL
    ) {
        self.appDatabase = appDatabase
        self.container = container
        self.stateStore = SyncStateStore()
        self.engineStateStore = SyncEngineStateStore(fileURL: stateFileURL)
    }

    // MARK: - Engine lifecycle

    /// Start the engine (creates it if needed). Idempotent; safe to call on
    /// every app launch. The startup reconciliation pass runs once per
    /// process lifetime and is safe even on a cold install (finds 0 dirty
    /// rows, returns quickly).
    public func start() async {
        _ = engine
        await reconcilePendingChangesFromDatabase()
    }

    private var engine: CKSyncEngine {
        if let engine = _engine { return engine }

        let state = engineStateStore.load()
        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: state,
            delegate: self
        )
        #if DEBUG
        // Tests and CLI one-shots opt out of automatic scheduling so they
        // can drive the engine explicitly.
        if ProcessInfo.processInfo.environment["RUBIEN_DISABLE_AUTO_SYNC"] != nil {
            config.automaticallySync = false
        }
        #endif

        let engine = CKSyncEngine(config)
        _engine = engine
        return engine
    }

    // MARK: - Startup reconciliation (plan B4)

    /// On process start: walk `syncState.isDirty=1` and `tombstone` rows and
    /// enqueue them in the engine. Recovers from crashes between the trigger
    /// commit (which set isDirty=1) and the post-commit observer's
    /// `engine.state.add(...)` call. Idempotent: `engine.state.add` dedups.
    ///
    /// Runs at most once per process lifetime — subsequent mutations flow
    /// through the post-commit observer (wired in a later commit) and the
    /// engine's own pending queue.
    private func reconcilePendingChangesFromDatabase() async {
        guard !didRunStartupReconciliation else { return }
        didRunStartupReconciliation = true

        do {
            let dirty: [(SyncEntityType, String)]
            let deleted: [(SyncEntityType, String)]

            (dirty, deleted) = try await appDatabase.dbWriter.read { db in
                (try self.stateStore.dirtyEntities(db),
                 try self.stateStore.tombstones(db))
            }

            var pending: [CKSyncEngine.PendingRecordZoneChange] = []
            pending.reserveCapacity(dirty.count + deleted.count)
            for (_, id) in dirty {
                pending.append(.saveRecord(recordID(for: id)))
            }
            for (_, id) in deleted {
                pending.append(.deleteRecord(recordID(for: id)))
            }

            if !pending.isEmpty {
                engine.state.add(pendingRecordZoneChanges: pending)
                log.info("reconciled \(pending.count, privacy: .public) pending changes from DB")
            }
        } catch {
            log.error("startup reconciliation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {
        case .stateUpdate(let event):
            await persistStateSerialization(event.stateSerialization)

        case .accountChange(let event):
            await handleAccountChange(event)

        case .fetchedRecordZoneChanges(let event):
            await applyFetchedZoneChanges(event)

        case .sentRecordZoneChanges(let event):
            await handleSentZoneChanges(event)

        case .fetchedDatabaseChanges,
             .sentDatabaseChanges,
             .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges:
            // Lifecycle events we currently only observe. UI
            // syncing-indicator updates will hook in here in a later
            // commit.
            break

        @unknown default:
            log.error("unhandled CKSyncEngine.Event case — a newer OS added a variant we don't know about")
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state
            .pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending
        ) { [appDatabase, stateStore] recordID in
            // The closure is called once per recordID. Returning nil drops
            // it from the batch (e.g. row deleted locally between dirty-
            // flag and batch-build — tombstone will handle it instead).
            do {
                return try await appDatabase.dbWriter.read { db in
                    let entityId = recordID.recordName
                    guard let entityType = Self.classifyEntityId(entityId, db: db) else {
                        return nil
                    }
                    let systemFields = try stateStore.loadSystemFields(
                        db,
                        entityType: entityType,
                        entityId: entityId
                    )
                    return try entityType.buildPushRecord(
                        db: db,
                        entityId: entityId,
                        systemFields: systemFields
                    )
                }
            } catch {
                log.error("buildPushRecord failed for \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    // MARK: - Event handlers

    private func persistStateSerialization(
        _ serialization: CKSyncEngine.State.Serialization
    ) async {
        do {
            try engineStateStore.save(serialization)
        } catch {
            log.error("failed to persist engine state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        // B5 expansion: per-case handling. For now, we preserve local
        // library data on sign-out (clear sync metadata only) and log sign-
        // in so the UI can pick up the change. switchAccounts will require
        // explicit user confirmation before we migrate data; current path
        // freezes the engine.
        switch event.changeType {
        case .signOut, .switchAccounts:
            do {
                try await appDatabase.dbWriter.write { db in
                    try db.execute(sql: "UPDATE syncState SET systemFields = NULL, isDirty = 1")
                    try db.execute(sql: "DELETE FROM tombstone")
                }
                try engineStateStore.reset()
                _engine = nil
            } catch {
                log.error("account-change reset failed: \(error.localizedDescription, privacy: .public)")
            }

        case .signIn:
            // Engine will emit .stateUpdate events as it discovers the new
            // account; startup reconciliation already primed any dirty rows.
            break

        @unknown default:
            log.error("unhandled account-change type")
        }
    }

    private func applyFetchedZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async {
        // Sort modifications into FK-dependency order so intermediate reads
        // inside the transaction see consistent parent rows even while
        // defer_foreign_keys lets constraint enforcement slide until commit.
        let sortedMods = event.modifications.sorted { lhs, rhs in
            let lhsRank = SyncEntityType
                .forRecordType(lhs.record.recordType)?.fkDependencyRank ?? Int.max
            let rhsRank = SyncEntityType
                .forRecordType(rhs.record.recordType)?.fkDependencyRank ?? Int.max
            return lhsRank < rhsRank
        }

        do {
            try await appDatabase.dbWriter.write { [stateStore] db in
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try stateStore.setApplyingRemote(db)

                for mod in sortedMods {
                    guard let type = SyncEntityType.forRecordType(mod.record.recordType) else {
                        log.error("unknown recordType \(mod.record.recordType, privacy: .public); skipping")
                        continue
                    }
                    try type.applyRemoteRecord(mod.record, db: db)
                    try stateStore.markPulled(
                        db,
                        entityType: type,
                        entityId: mod.record.recordID.recordName,
                        record: mod.record
                    )
                }

                for deletion in event.deletions {
                    guard let type = SyncEntityType.forRecordType(deletion.recordType) else { continue }
                    let entityId = deletion.recordID.recordName
                    try type.applyRemoteDelete(entityId: entityId, db: db)
                    try stateStore.removeState(db, entityType: type, entityId: entityId)
                    try stateStore.upsertTombstone(
                        db,
                        entityType: type,
                        entityId: entityId
                    )
                    try stateStore.clearDirty(db, entityType: type, entityId: entityId)
                }

                // Surface any lingering FK violations explicitly so they
                // end up in the log, not as an opaque commit failure.
                let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                if !violations.isEmpty {
                    log.error("FK violations after remote apply: \(violations.count, privacy: .public) rows — rolling back")
                    throw CancellationError()  // trigger rollback
                }

                try stateStore.clearApplyingRemote(db)
            }
        } catch {
            log.error("applyFetchedZoneChanges failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleSentZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges
    ) async {
        // Successful saves: archive system fields so the next push can
        // rehydrate with a valid change tag.
        for saved in event.savedRecords {
            guard let type = SyncEntityType.forRecordType(saved.recordType) else { continue }
            do {
                try await appDatabase.dbWriter.write { [stateStore] db in
                    try stateStore.markPushed(
                        db,
                        entityType: type,
                        entityId: saved.recordID.recordName,
                        record: saved
                    )
                }
            } catch {
                log.error("markPushed failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Successful deletes: purge the tombstone the server has now
        // confirmed.
        for deletedID in event.deletedRecordIDs {
            // We don't know recordType from CKRecord.ID alone; try every
            // tombstone row for this entityId. There won't be many — this
            // is O(syncedTables.count) at most.
            let entityId = deletedID.recordName
            do {
                try await appDatabase.dbWriter.write { [stateStore] db in
                    for type in SyncEntityType.allCases {
                        try stateStore.removeTombstone(db, entityType: type, entityId: entityId)
                    }
                }
            } catch {
                log.error("removeTombstone failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // TODO(B7): failedRecordSaves / failedRecordDeletes with
        // .serverRecordChanged, .zoneNotFound, .unknownItem branches. These
        // wire conflict resolution + recovery paths; implementing them
        // properly needs the LWW merge policy in place.
    }

    // MARK: - Helpers

    /// Build a `CKRecord.ID` from our `entityId` convention. Zone is always
    /// the library zone.
    private func recordID(for entityId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: entityId, zoneID: SyncConstants.libraryZoneID)
    }

    /// Best-effort classification of an `entityId` back to its entity type
    /// by joining on `syncState`. Used when the engine hands us a recordID
    /// without a type hint (the pending-changes queue doesn't carry the
    /// record type because CloudKit doesn't know it yet for new records).
    private static func classifyEntityId(_ entityId: String, db: Database) -> SyncEntityType? {
        guard let raw = try? String.fetchOne(db, sql: """
            SELECT entityType FROM syncState WHERE entityId = ? LIMIT 1
            """, arguments: [entityId]) else {
            return nil
        }
        return SyncEntityType(rawValue: raw)
    }
}
