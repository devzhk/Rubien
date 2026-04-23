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

    /// Lazy container factory. Deferring construction means unit tests can
    /// exercise the actor's DB-touching side effects (baseline, tombstone
    /// compaction, startup reconciliation) without triggering the CloudKit
    /// runtime — which raises `CKException` in a process that has no
    /// CloudKit entitlement (the case for XCTest without an app signing
    /// context).
    private let containerProvider: @Sendable () -> CKContainer
    private var _container: CKContainer?

    /// Lazy engine — built on demand so the delegate (`self`) is fully
    /// initialized before the CKSyncEngine starts issuing async callbacks.
    private var _engine: CKSyncEngine?

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        stateFileURL: URL = AppDatabase.syncEngineStateURL,
        containerProvider: @escaping @Sendable () -> CKContainer = {
            CKContainer(identifier: SyncConstants.containerIdentifier)
        }
    ) {
        self.appDatabase = appDatabase
        self.stateStore = SyncStateStore()
        self.engineStateStore = SyncEngineStateStore(fileURL: stateFileURL)
        self.containerProvider = containerProvider
    }

    private var container: CKContainer {
        if let existing = _container { return existing }
        let built = containerProvider()
        _container = built
        return built
    }

    // MARK: - Engine lifecycle

    /// Start the engine (creates it if needed). Idempotent; safe to call on
    /// every app launch. Runs (in order): baseline-if-pending → tombstone
    /// compaction → startup reconciliation. Each step short-circuits if
    /// nothing to do.
    public func start() async {
        _ = engine
        await performInitialBaselineIfNeeded()
        await compactStaleTombstones()
        // Startup reconciliation — idempotent because
        // `engine.state.add(pendingRecordZoneChanges:)` dedups internally,
        // so recalling on every `start()` is cheap and doesn't need a
        // process-lifetime guard.
        await ingestPendingChanges()
    }

    /// The post-commit observer that feeds mutations to the engine.
    /// Retained here because GRDB's `.observerLifetime` extent keeps
    /// only a **weak** reference to the observer; without this, the
    /// local var would deallocate immediately after the `add(...)`
    /// call and commits would never reach the engine.
    private var transactionObserver: SyncTransactionObserver?

    /// Install a GRDB `TransactionObserver` that forwards post-commit
    /// activity into the engine automatically. One call at app startup,
    /// after `start()`, is enough — app code doesn't have to manually
    /// call `ingestPendingChanges` after each write.
    ///
    /// The observer only watches `syncState` / `tombstone` mutations
    /// (which the per-entity triggers write to) so it's cheap — we don't
    /// fire on every reference save that happens to touch a scalar.
    public func installTransactionObserver() async {
        let observer = SyncTransactionObserver(library: self)
        transactionObserver = observer  // hold strong; GRDB's .observerLifetime is weak
        appDatabase.dbWriter.add(transactionObserver: observer, extent: .observerLifetime)
    }

    /// Stop receiving post-commit notifications. Used when the user
    /// toggles sync off — we need both GRDB's explicit `remove` call
    /// (to drop the registration synchronously) and to nil our own
    /// retention (so the observer can deallocate).
    public func removeTransactionObserver() async {
        guard let observer = transactionObserver else { return }
        appDatabase.dbWriter.remove(transactionObserver: observer)
        transactionObserver = nil
    }

    /// Test-only accessor. We can't exercise the engine side of the
    /// observer pipeline without a CloudKit entitlement, but retention
    /// is the bug we're guarding against — a test can prove it by
    /// reading this property after install / remove.
    var hasTransactionObserver: Bool {
        transactionObserver != nil
    }

    /// Call from the app after any write transaction that might have left
    /// rows dirty. Forwards freshly-dirty entity IDs and tombstones into the
    /// engine's pending queue. Idempotent: CKSyncEngine dedups by recordID
    /// across add calls.
    ///
    /// The natural caller is a GRDB `TransactionObserver.databaseDidCommit`
    /// hook that dispatches into the actor — safe because it fires
    /// post-commit (no mid-transaction mutation).
    public func ingestPendingChanges() async {
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
            }
        } catch {
            log.error("ingestPendingChanges failed: \(error.localizedDescription, privacy: .public)")
        }
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

    // MARK: - Initial baseline (plan B9)

    /// Upload-existing-library one-shot. If the `baselineState` row in
    /// `syncSession` is missing (fresh install with sync just enabled),
    /// mark every row in every synced table as dirty so the startup
    /// reconciliation pass later in `start()` can enqueue them.
    ///
    /// Gated by `baselineState=complete` afterwards so a restart doesn't
    /// re-mark rows that are already in the engine's pending queue.
    func performInitialBaselineIfNeeded() async {
        do {
            try await appDatabase.dbWriter.write { db in
                let state = try String.fetchOne(db, sql: """
                    SELECT value FROM syncSession WHERE key = 'baselineState' LIMIT 1
                    """)
                guard state == nil else { return }

                // Marking the session row as done first means a crash
                // between here and the INSERT loop leaves us with no
                // baseline run on the next launch — acceptable because the
                // user can re-enable sync or run `rubien-cli sync reset`.
                // The alternative (marking after all INSERTs) would risk
                // an infinite re-baseline loop if the loop itself crashed
                // mid-way.
                try db.execute(sql: """
                    INSERT INTO syncSession(key, value) VALUES('baselineState', 'complete')
                    """)

                var totalMarked = 0
                for type in SyncEntityType.allCases {
                    let tableName = type.rawValue
                    // Pivot has no surrogate id; composite key string is
                    // what we insert instead.
                    let idExpression: String
                    switch type {
                    case .referenceTag:
                        idExpression = "referenceId || '\(SyncConstants.pivotSeparator)' || tagId"
                    default:
                        idExpression = "id"
                    }
                    // SQLite grammar quirk: the INSERT-SELECT form needs
                    // an explicit `WHERE true` before `ON CONFLICT`,
                    // otherwise the parser rejects the upsert clause as
                    // ambiguous with the SELECT's WHERE slot.
                    try db.execute(sql: """
                        INSERT INTO syncState(entityType, entityId, isDirty)
                            SELECT '\(tableName)', \(idExpression), 1 FROM \(tableName) WHERE true
                            ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty = 1
                        """)
                    totalMarked += db.changesCount
                }
                log.info("initial baseline marked \(totalMarked, privacy: .public) rows dirty")
            }
        } catch {
            log.error("initial baseline failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Tombstone compaction (plan B12)

    /// Prune server-confirmed tombstones past the retention window.
    /// Unconfirmed (pending-ack) tombstones are kept indefinitely; see
    /// `SyncStateStore.compactTombstones`.
    func compactStaleTombstones() async {
        let cutoff = Date().addingTimeInterval(-SyncConstants.tombstoneRetention)
        do {
            try await appDatabase.dbWriter.write { db in
                try self.stateStore.compactTombstones(db, olderThan: cutoff)
            }
        } catch {
            log.error("tombstone compaction failed: \(error.localizedDescription, privacy: .public)")
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
            //
            // We use `.write` (not `.read`) so the same transaction that
            // reads the row also stamps `pushInFlight=1` — closing the
            // TOCTOU window on `isDirty`. A local edit that lands after
            // this transaction commits will trigger the syncState upsert
            // and clear pushInFlight, making the eventual save-ack leave
            // `isDirty=1` for re-push.
            do {
                return try await appDatabase.dbWriter.write { db in
                    let entityId = recordID.recordName
                    guard let entityType = Self.classifyEntityId(entityId, db: db) else {
                        return nil
                    }
                    let systemFields = try stateStore.loadSystemFields(
                        db,
                        entityType: entityType,
                        entityId: entityId
                    )
                    guard let record = try entityType.buildPushRecord(
                        db: db,
                        entityId: entityId,
                        systemFields: systemFields
                    ) else { return nil }
                    try stateStore.markPushInFlight(
                        db,
                        entityType: entityType,
                        entityId: entityId
                    )
                    return record
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

        // Successful deletes: promote the tombstone from unconfirmed to
        // confirmed. Compaction now sees it as eligible for 30-day GC.
        // We don't purge immediately — keeping the tombstone live a while
        // longer lets any in-flight duplicate edit for the same record
        // lose at `.unknownItem` rather than resurrecting the row.
        for deletedID in event.deletedRecordIDs {
            let entityId = deletedID.recordName
            do {
                try await appDatabase.dbWriter.write { [stateStore] db in
                    try stateStore.markTombstoneConfirmed(db, entityId: entityId)
                }
            } catch {
                log.error("removeTombstone failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Failed saves: handle the three error classes we recover from
        // automatically. Others (quota exceeded, etc.) are left to the
        // engine's own retry policy.
        for failure in event.failedRecordSaves {
            guard let type = SyncEntityType.forRecordType(failure.record.recordType) else { continue }
            let entityId = failure.record.recordID.recordName

            switch failure.error.code {
            case .serverRecordChanged:
                await handleServerRecordChanged(
                    type: type,
                    entityId: entityId,
                    error: failure.error
                )

            case .zoneNotFound:
                // Library zone was deleted (or never created for this
                // account). Recreate it — the engine retries the save
                // once we acknowledge the zone creation.
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: SyncConstants.libraryZoneID))
                ])

            case .unknownItem:
                // Server says this record doesn't exist. Either (a) the
                // server has a tombstone and our pending push lost the
                // race, or (b) our cached systemFields reference a record
                // that was never persisted (partial push / abandoned
                // account). Either way the cached system fields are
                // stale — drop them so the next push creates a fresh
                // record. Leave isDirty=1 so the retry actually happens:
                // if the server has a tombstone a subsequent fetch will
                // deliver the deletion (pull path sets isDirty=0); if
                // not, the fresh re-push succeeds.
                do {
                    try await appDatabase.dbWriter.write { [stateStore] db in
                        try stateStore.clearSystemFields(db, entityType: type, entityId: entityId)
                    }
                    // Schedule outside the delegate callback (Apple's docs:
                    // don't call fetchChanges synchronously from handleEvent).
                    Task { [engine] in
                        _ = try? await engine.fetchChanges()
                    }
                } catch {
                    log.error("unknownItem recovery failed: \(error.localizedDescription, privacy: .public)")
                }

            default:
                log.error(
                    "unhandled record-save failure \(failure.error.code.rawValue, privacy: .public) for \(entityId, privacy: .public)"
                )
            }
        }

        // Failed deletes — typically .unknownItem (already gone server-
        // side). Purge the tombstone so we don't keep retrying.
        for failure in event.failedRecordDeletes {
            if failure.value.code == .unknownItem {
                let entityId = failure.key.recordName
                do {
                    try await appDatabase.dbWriter.write { [stateStore] db in
                        for type in SyncEntityType.allCases {
                            try stateStore.removeTombstone(db, entityType: type, entityId: entityId)
                        }
                    }
                } catch {
                    log.error("failed-delete tombstone purge failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Conflict resolution on `.serverRecordChanged`. CloudKit returns the
    /// server's current version in the error payload; we rehydrate it as
    /// the new systemFields baseline so the next push carries a valid
    /// change tag, then leave the row dirty for that next push.
    ///
    /// Merge policy for v1: **server wins**. The pull path will overwrite
    /// our local row with the server's scalars, and our local edits get
    /// dropped. This matches the plan's LWW policy when the server's
    /// `modificationDate` is newer (the common case — server's version is
    /// only returned when ours lost the race). A future refinement can
    /// compare local vs server `dateModified` for Reference and merge
    /// field-by-field.
    private func handleServerRecordChanged(
        type: SyncEntityType,
        entityId: String,
        error: CKError
    ) async {
        guard let serverRecord = error.serverRecord else {
            log.error("serverRecordChanged without serverRecord — re-fetch to recover")
            Task { [engine] in
                _ = try? await engine.fetchChanges()
            }
            return
        }

        do {
            try await appDatabase.dbWriter.write { [stateStore] db in
                try stateStore.setApplyingRemote(db)
                try type.applyRemoteRecord(serverRecord, db: db)
                try stateStore.markPulled(
                    db,
                    entityType: type,
                    entityId: entityId,
                    record: serverRecord
                )
                try stateStore.clearApplyingRemote(db)
            }
        } catch {
            log.error("serverRecordChanged merge failed: \(error.localizedDescription, privacy: .public)")
        }
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
