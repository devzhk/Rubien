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

    /// Per-device upload queue drained by `drainPDFUploadQueue()`.
    /// Lazy because it's only used on the PDF push path; unrelated tests
    /// (status stream, transaction observer retention) shouldn't pay the
    /// actor-allocation cost.
    private lazy var pdfUploadQueue: PDFUploadQueue = PDFUploadQueue(db: appDatabase)

    /// Cross-target feature-flag accessor. `RubienPreferences.pdfAssetSyncEnabled`
    /// lives in the `Rubien` app target which `RubienSync` cannot import
    /// (would create a target cycle), so we inject the read as a closure
    /// at construction. Production binding is `{ RubienPreferences.pdfAssetSyncEnabled }`
    /// in `SyncCoordinator`; tests inject `{ true }` or `{ false }` directly.
    private let pdfAssetSyncEnabledProvider: @Sendable () -> Bool

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

    // MARK: - Status stream

    /// Observable state changes the coordinator republishes to SwiftUI.
    /// One stream per actor lifetime; the actor calls `publishStatus(_:)`
    /// from inside its delegate methods.
    public nonisolated let statusStream: AsyncStream<SyncStatus>

    private let statusContinuation: AsyncStream<SyncStatus>.Continuation

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        stateFileURL: URL = AppDatabase.syncEngineStateURL,
        containerProvider: @escaping @Sendable () -> CKContainer = {
            CKContainer(identifier: SyncConstants.containerIdentifier)
        },
        // Tests default to `false` so the existing startup / observer /
        // status-stream tests (which don't seed pdfUploadQueue rows) keep
        // their behavior unchanged. Production callers in `SyncCoordinator`
        // pass `{ RubienPreferences.pdfAssetSyncEnabled }`; the
        // `PDFUploadDrainerTests` pass `{ true }` / `{ false }` explicitly
        // to exercise the on/off branches.
        pdfAssetSyncEnabledProvider: @escaping @Sendable () -> Bool = { false }
    ) {
        var continuation: AsyncStream<SyncStatus>.Continuation!
        self.statusStream = AsyncStream { cont in continuation = cont }
        self.statusContinuation = continuation
        self.appDatabase = appDatabase
        self.stateStore = SyncStateStore()
        self.engineStateStore = SyncEngineStateStore(fileURL: stateFileURL)
        self.containerProvider = containerProvider
        self.pdfAssetSyncEnabledProvider = pdfAssetSyncEnabledProvider
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
    /// compaction → startup reconciliation → PDF-upload-queue drain. Each
    /// step short-circuits if nothing to do.
    public func start() async {
        _ = engine
        await performInitialBaselineIfNeeded()
        await compactStaleTombstones()
        // Startup reconciliation — idempotent because
        // `engine.state.add(pendingRecordZoneChanges:)` dedups internally,
        // so recalling on every `start()` is cheap and doesn't need a
        // process-lifetime guard.
        await ingestPendingChanges()
        // Drain any PDF rows queued by previous sessions (or by the v2
        // migration backfill of the existing library). The drainer self-
        // gates on the feature flag.
        await drainPDFUploadQueue()
    }

    // MARK: - PDF upload queue drainer (B8 / Task 14)

    /// Move queued PDF rows into the engine's pending-changes pipeline.
    ///
    /// Design — mark-dirty + eager-remove:
    /// 1. Read pending reference IDs from `pdfUploadQueue` (FIFO order).
    /// 2. UPSERT a `syncState(entityType='referencePDF', isDirty=1)` row
    ///    per pending ID. This piggybacks on the existing dirty-row
    ///    machinery: if the engine forgets the in-flight push (process
    ///    crash, account churn, etc.), the next `start()` call's
    ///    `ingestPendingChanges` will rediscover the dirty row and re-
    ///    enqueue. Without this safety net an eager `pdfUploadQueue.remove`
    ///    would silently drop the upload on engine error.
    /// 3. Add `.saveRecord` pending-changes to the engine state. The
    ///    engine then drives `nextRecordZoneChangeBatch` →
    ///    `SyncEntityType.referencePDF.buildPushRecord` → CloudKit save.
    ///    On save-ack, `markPushed` clears `isDirty`.
    /// 4. Remove the row from `pdfUploadQueue`. The mark-dirty insert is
    ///    now the durable record of "PDF needs pushing"; the queue table
    ///    is a per-device "yet to be drained into syncState" buffer.
    ///
    /// Re-entrant safe: a second call sees an empty queue and no-ops; the
    /// engine deduplicates pendingRecordZoneChanges by recordID. The
    /// drainer self-gates on `pdfAssetSyncEnabledProvider()` so it stays a
    /// no-op until Phase E flips the flag on by default.
    public func drainPDFUploadQueue() async {
        let drained = await drainPDFUploadQueueIntoSyncState()
        guard !drained.isEmpty else { return }

        // Hand the drained IDs to the engine. Idempotent: CKSyncEngine
        // dedups pendingRecordZoneChanges by recordID, so re-adding an
        // already-pending change is harmless. This is the only step that
        // forces engine construction; XCTest exercises the DB side via
        // `drainPDFUploadQueueIntoSyncState` directly so this path stays
        // out of unentitled test runs.
        let pending: [CKSyncEngine.PendingRecordZoneChange] = drained.map { id in
            .saveRecord(recordID(for: String(id), type: .referencePDF))
        }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// DB-side half of the drainer. Returns the IDs that were marked dirty
    /// and removed from the queue, so the caller can pass them to the
    /// engine. Split out from `drainPDFUploadQueue` so tests (which run in
    /// an unentitled XCTest process where touching CKSyncEngine raises
    /// `CKException`) can exercise the DB effects without forcing engine
    /// construction.
    func drainPDFUploadQueueIntoSyncState() async -> [Int64] {
        guard pdfAssetSyncEnabledProvider() else { return [] }

        let pendingIds: [Int64]
        do {
            pendingIds = try await pdfUploadQueue.pendingReferenceIds()
        } catch {
            log.error("drainPDFUploadQueue: failed to read queue: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard !pendingIds.isEmpty else { return [] }

        // Mark each pending ID as dirty in syncState AND clear the queue
        // row in one transaction. Atomicity here matters: if mark-dirty
        // succeeded but queue-remove failed, the next drain pass would
        // re-process the same IDs (harmless — UPSERT — but wasteful).
        // Conversely if remove succeeded but mark-dirty failed, we'd lose
        // the upload entirely (no syncState entry, no queue row). One
        // transaction sidesteps both.
        do {
            try await appDatabase.dbWriter.write { db in
                for id in pendingIds {
                    try db.execute(sql: """
                        INSERT INTO syncState(entityType, entityId, isDirty)
                            VALUES(?, ?, 1)
                            ON CONFLICT(entityType, entityId)
                                DO UPDATE SET isDirty = 1
                    """, arguments: [SyncEntityType.referencePDF.rawValue, String(id)])
                    try db.execute(
                        sql: "DELETE FROM pdfUploadQueue WHERE referenceId = ?",
                        arguments: [id]
                    )
                }
            }
        } catch {
            log.error("drainPDFUploadQueue: mark-dirty/clear write failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return pendingIds
    }

    // MARK: - Status publishing

    func publishStatus(_ status: SyncStatus) {
        statusContinuation.yield(status)
        switch status {
        case .error(let error):
            log.error("sync status → error: \(error.localizedDescription, privacy: .public)")
        case .unavailable(let reason):
            log.info("sync status → unavailable: \(reason, privacy: .public)")
        default:
            log.debug("sync status → \(String(describing: status), privacy: .public)")
        }
    }

    /// Test-only hook. Production callers go through `publishStatus`.
    func publishStatusForTest(_ status: SyncStatus) {
        publishStatus(status)
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
            for (type, id) in dirty {
                pending.append(.saveRecord(recordID(for: id, type: type)))
            }
            for (type, id) in deleted {
                pending.append(.deleteRecord(recordID(for: id, type: type)))
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
                    // Each entity type baselines from a source SQLite table
                    // and an id expression. For most entities the table name
                    // matches the rawValue and id is the surrogate PK;
                    // referenceTag uses a composite key, and referencePDF
                    // (a virtual sibling-record entity) reads from the
                    // local-only `pdfCache` table keyed by referenceId.
                    let sourceTable: String
                    let idExpression: String
                    switch type {
                    case .referenceTag:
                        sourceTable = type.rawValue
                        idExpression = "referenceId || '\(SyncConstants.pivotSeparator)' || tagId"
                    case .referencePDF:
                        // No `referencePDF` SQLite table exists — the wire
                        // format is synthesized from `pdfCache` rows.
                        // entityId for syncState matches the dispatch path
                        // (Int64(referenceId) stringified).
                        //
                        // Future synthesized/sibling-record entities (records
                        // that don't 1:1 with a SQLite table) should add their
                        // own case here following this shape: pick the local
                        // source table, pick the column whose value the
                        // dispatch path expects to parse from entityId.
                        sourceTable = "pdfCache"
                        idExpression = "referenceId"
                    default:
                        sourceTable = type.rawValue
                        idExpression = "id"
                    }
                    // SQLite grammar quirk: the INSERT-SELECT form needs
                    // an explicit `WHERE true` before `ON CONFLICT`,
                    // otherwise the parser rejects the upsert clause as
                    // ambiguous with the SELECT's WHERE slot.
                    try db.execute(sql: """
                        INSERT INTO syncState(entityType, entityId, isDirty)
                            SELECT '\(type.rawValue)', \(idExpression), 1 FROM \(sourceTable) WHERE true
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

        case .willFetchChanges, .willSendChanges:
            publishStatus(.syncing)

        case .didFetchChanges, .didSendChanges:
            publishStatus(.idle)

        case .fetchedDatabaseChanges,
             .sentDatabaseChanges,
             .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges:
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
                    guard let (entityType, entityId) = SyncEntityType.parseRecordName(recordID.recordName) else {
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
                    guard let entityId = SyncEntityType.parseRecordName(mod.record.recordID.recordName)?.1 else {
                        log.error("skipping malformed recordName \(mod.record.recordID.recordName, privacy: .public)")
                        continue
                    }
                    try type.applyRemoteRecord(mod.record, entityId: entityId, db: db)
                    try stateStore.markPulled(
                        db,
                        entityType: type,
                        entityId: entityId,
                        record: mod.record
                    )
                }

                for deletion in event.deletions {
                    guard let type = SyncEntityType.forRecordType(deletion.recordType) else { continue }
                    guard let entityId = SyncEntityType.parseRecordName(deletion.recordID.recordName)?.1 else {
                        log.error("skipping malformed delete recordName \(deletion.recordID.recordName, privacy: .public)")
                        continue
                    }
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
            guard let entityId = SyncEntityType.parseRecordName(saved.recordID.recordName)?.1 else {
                log.error("skipping malformed saved recordName \(saved.recordID.recordName, privacy: .public)")
                continue
            }
            do {
                try await appDatabase.dbWriter.write { [stateStore] db in
                    try stateStore.markPushed(
                        db,
                        entityType: type,
                        entityId: entityId,
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
            guard let entityId = SyncEntityType.parseRecordName(deletedID.recordName)?.1 else {
                log.error("skipping malformed deleted recordName \(deletedID.recordName, privacy: .public)")
                continue
            }
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
            guard let entityId = SyncEntityType.parseRecordName(failure.record.recordID.recordName)?.1 else {
                log.error("skipping malformed failed-save recordName \(failure.record.recordID.recordName, privacy: .public)")
                continue
            }

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
                    "unhandled record-save failure code=\(failure.error.code.rawValue, privacy: .public) type=\(failure.record.recordType, privacy: .public) id=\(entityId, privacy: .public): \(failure.error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Failed deletes — typically .unknownItem (already gone server-
        // side). Purge the tombstone so we don't keep retrying.
        for failure in event.failedRecordDeletes {
            if failure.value.code == .unknownItem {
                guard let entityId = SyncEntityType.parseRecordName(failure.key.recordName)?.1 else {
                    log.error("skipping malformed failed-delete recordName \(failure.key.recordName, privacy: .public)")
                    continue
                }
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
                try type.applyRemoteRecord(serverRecord, entityId: entityId, db: db)
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

    /// Build a `CKRecord.ID` for a row of `type` with local `entityId`.
    /// Uses `SyncEntityType.qualifiedRecordName` so compose/parse stay a
    /// matched pair; see `SyncConstants.typeSeparator` for the separator.
    private func recordID(for entityId: String, type: SyncEntityType) -> CKRecord.ID {
        CKRecord.ID(
            recordName: type.qualifiedRecordName(entityId: entityId),
            zoneID: SyncConstants.libraryZoneID
        )
    }
}
