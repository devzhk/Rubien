#if canImport(CloudKit)
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

    /// Injectable so tests can deterministically replace a cache row between
    /// the resolver's read and write without holding the SQLite writer during
    /// the potentially-expensive hash computation.
    private let pdfContentHasher: @Sendable (URL) throws -> String

    /// Internal shape for deletions threaded into `applyFetchedRecordsInternal`.
    /// `CKSyncEngine.Event.FetchedRecordZoneChanges.Deletion` is not publicly
    /// constructible, so the production adapter unpacks it into this struct
    /// before handing off — and tests can synthesize values directly.
    struct FetchedDeletionInput: Sendable {
        let recordID: CKRecord.ID
        let recordType: String
    }

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
        pdfContentHasher: @escaping @Sendable (URL) throws -> String = {
            try PDFContentHasher.sha256(of: $0)
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
        self.pdfContentHasher = pdfContentHasher
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
        // Step 1 — resolve any 'pending' contentHash rows BEFORE the engine
        // is constructed. Auto-scheduling means the engine can request a
        // push batch immediately after `_ = engine`; doing the resolver
        // first guarantees no in-flight push ever sees a pending row at
        // start. Self-gated on the feature flag — when PDF asset sync is
        // disabled, leaving rows 'pending' is harmless since no push code
        // reads them.
        if pdfAssetSyncEnabledProvider() {
            await resolvePendingPDFContentHashes()
        }

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
    /// Re-entrant safe by *idempotency*, not by serialization: actor
    /// suspensions at `await pendingReferenceIds()` and `await dbWriter.write`
    /// let a second concurrent caller read the same pendingIds before the
    /// first transaction commits. The safety net is three-layered: (a) the
    /// `syncState` UPSERT is idempotent (re-marking dirty is a no-op);
    /// (b) DELETE-WHERE on already-removed rows is a no-op; (c) CKSyncEngine
    /// dedups `pendingRecordZoneChanges` by recordID. Net effect: two
    /// concurrent drains are equivalent to one. The drainer self-gates on
    /// `pdfAssetSyncEnabledProvider()` so it stays a no-op until Phase E
    /// flips the flag on by default.
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

        // Resolve each row's pending hash *outside* the upcoming mark-dirty
        // transaction. By the time the engine is told the row is dirty, its
        // pdfCache.contentHash is a real SHA-256 — the inline hash branch
        // in buildPushRecord(.referencePDF) is no longer the routine path
        // for fresh imports.
        for id in pendingIds {
            await resolvePendingHashForReference(id)
        }

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

    // MARK: - Pending PDF content-hash resolver

    /// Walk `pdfCache` for rows still tagged with the migration sentinel
    /// `contentHash = 'pending'` and replace each with the real SHA-256 of
    /// the on-disk file. Runs as the FIRST step of `start()` so the engine
    /// is never constructed (and thus never auto-scheduled) while pending
    /// rows still exist.
    ///
    /// **No transaction wraps the SHA-256 compute.** Each row gets two tiny
    /// `dbWriter.read` / `dbWriter.write` hops: one to read the filename and
    /// asset version, one to write the resolved hash. Between them,
    /// `PDFContentHasher.sha256` streams the file with the writer queue free.
    /// The update matches that snapshot so replacing the PDF mid-hash cannot
    /// assign the old file's hash to the new attachment.
    ///
    /// Missing files are tolerated (logged + skipped). Leaving such a row
    /// at `contentHash='pending'` is safe: `buildPushRecord(.referencePDF)`
    /// returns nil for missing-file rows via an earlier `fileExists` guard,
    /// so no inline-hash branch is ever reached for them.
    func resolvePendingPDFContentHashes() async {
        let pending: [(id: Int64, filename: String, assetVersion: Int64)]
        do {
            pending = try await appDatabase.dbWriter.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT referenceId, localFilename, assetVersion FROM pdfCache
                    WHERE contentHash = 'pending' AND materializedAt IS NOT NULL
                """).map {
                    (
                        id: $0["referenceId"],
                        filename: $0["localFilename"],
                        assetVersion: $0["assetVersion"]
                    )
                }
            }
        } catch {
            log.error("resolvePendingPDFContentHashes: failed to read pending list: \(error.localizedDescription, privacy: .public)")
            return
        }
        for row in pending {
            await resolvePendingHashFor(
                referenceId: row.id,
                filename: row.filename,
                assetVersion: row.assetVersion
            )
        }
    }

    /// Resolve a single pdfCache row's pending hash. The drainer's per-
    /// import path passes its own filename; the startup walker batches the
    /// lookup. Idempotent for non-pending rows (WHERE contentHash =
    /// 'pending' guard on the UPDATE).
    func resolvePendingHashForReference(_ referenceId: Int64) async {
        let pending: (filename: String, assetVersion: Int64)?
        do {
            pending = try await appDatabase.dbWriter.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT localFilename, assetVersion FROM pdfCache
                        WHERE referenceId = ? AND contentHash = 'pending'
                    """,
                    arguments: [referenceId]
                ).map {
                    (filename: $0["localFilename"], assetVersion: $0["assetVersion"])
                }
            }
        } catch {
            log.error("resolvePendingHashForReference: read failed for \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let pending else { return }
        await resolvePendingHashFor(
            referenceId: referenceId,
            filename: pending.filename,
            assetVersion: pending.assetVersion
        )
    }

    private func resolvePendingHashFor(
        referenceId: Int64,
        filename: String,
        assetVersion: Int64
    ) async {
        let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        let hash: String
        do {
            hash = try pdfContentHasher(url)
        } catch {
            // Missing-file or unreadable-file case lands here. Leave the
            // row at 'pending'; safe because buildPushRecord(.referencePDF)
            // also short-circuits for missing files via its own fileExists
            // guard, so no inline-hash branch can fire for them.
            log.info("resolvePendingHashFor: hash skipped for \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try await appDatabase.dbWriter.write { db in
                try db.execute(
                    sql: """
                        UPDATE pdfCache SET contentHash = ?
                        WHERE referenceId = ? AND localFilename = ?
                            AND assetVersion = ? AND contentHash = 'pending'
                    """,
                    arguments: [hash, referenceId, filename, assetVersion]
                )
            }
        } catch {
            log.error("resolvePendingHashFor: write failed for \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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

    /// Update fetch in-flight state and publish status. `internal` so
    /// `SyncStatusFlickerTests` can drive the transitions without standing up
    /// a real `CKSyncEngine` (unentitled XCTest raises `CKException`).
    func noteFetch(inFlight: Bool) {
        isFetchInFlight = inFlight
        if inFlight { publishStatus(.syncing) } else { publishIdleIfQuiescent() }
    }

    func noteSend(inFlight: Bool) {
        isSendInFlight = inFlight
        if inFlight { publishStatus(.syncing) } else { publishIdleIfQuiescent() }
    }

    private func publishIdleIfQuiescent() {
        guard !isFetchInFlight, !isSendInFlight else { return }
        publishStatus(.idle)
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

    /// Independent in-flight flags so a manual fetch completing mid-send (or
    /// vice-versa) doesn't publish `.idle` while the other operation is still
    /// running. Without this, Layer A polling makes a brief banner flicker
    /// visible whenever a poll's fetch overlaps an automatic send.
    private var isFetchInFlight = false
    private var isSendInFlight  = false

    /// Overlap guard for explicit fetches. `SyncedLibrary` is an actor, so the
    /// read-then-set below has no suspension point and is race-free across
    /// concurrent callers (launch / foreground / idle timer / error recovery).
    private var isExplicitFetchRunning = false

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

    /// Drive an explicit incremental fetch. The single funnel for every
    /// fetch trigger (launch, foreground, idle timer) and the two reactive
    /// error-recovery paths, so the overlap guard is the one concurrency
    /// policy. Returns `true` on success or a no-op skip (another fetch is
    /// already in flight); `false` on error, which the idle timer uses to back
    /// off. Only called once the library is live, so `engine` already exists.
    @discardableResult
    public func fetchRemoteChanges() async -> Bool {
        guard !isExplicitFetchRunning else { return true }
        isExplicitFetchRunning = true
        defer { isExplicitFetchRunning = false }
        do {
            try await engine.fetchChanges()
            return true
        } catch {
            log.error("fetchRemoteChanges failed: \(error.localizedDescription, privacy: .public)")
            return false
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

        case .willFetchChanges:
            noteFetch(inFlight: true)
        case .willSendChanges:
            noteSend(inFlight: true)
        case .didFetchChanges:
            noteFetch(inFlight: false)
        case .didSendChanges:
            noteSend(inFlight: false)

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
        let mods = event.modifications.map(\.record)
        let dels: [FetchedDeletionInput] = event.deletions.map {
            FetchedDeletionInput(recordID: $0.recordID, recordType: $0.recordType)
        }
        await applyFetchedRecordsInternal(modifications: mods, deletions: dels)
    }

    /// Outcome of applying one fetched-changes batch. The write closure is
    /// `@Sendable`, so it RETURNS this value rather than mutating captured
    /// `var`s; the returned filenames drive the Phase-3 post-commit PDF
    /// cleanup. Type-scope so the `static` `applyRemoteRows` can name it.
    private struct BatchOutcome: Sendable {
        var displacedFilenames: [String]
        var appliedPDFRecordIDs: Set<CKRecord.ID>
    }

    /// Shared implementation used by `applyFetchedZoneChanges` and tests.
    /// Pre-stages every `referencePDF` modification *outside* the write
    /// transaction (file I/O off the writer queue). The transaction body
    /// then runs only the small `pdfCache` upsert plus the existing
    /// non-PDF apply paths. Old filenames returned by `applyPreparedReferencePDF`
    /// and staged files for skipped-or-rolled-back records are unlinked
    /// post-transaction so PDFs/ never accumulates orphans.
    private func applyFetchedRecordsInternal(
        modifications: [CKRecord],
        deletions: [FetchedDeletionInput]
    ) async {
        // FK-dependency-ordered modifications. PDFs are FK-children of
        // Reference and have rank Int.max in practice — they sort last.
        let sortedMods = modifications.sorted { lhs, rhs in
            let lhsRank = SyncEntityType
                .forRecordType(lhs.recordType)?.fkDependencyRank ?? Int.max
            let rhsRank = SyncEntityType
                .forRecordType(rhs.recordType)?.fkDependencyRank ?? Int.max
            return lhsRank < rhsRank
        }

        // Phase 1 — pre-stage referencePDF assets outside any DB transaction.
        // `prepare` validates recordName and Int64 entityId internally, so a
        // malformed name simply returns nil with no staged file. Frozen into
        // a `let` for safe capture by the @Sendable write closure below.
        var preparedBuilder: [CKRecord.ID: SyncEntityType.PreparedReferencePDFMaterialization] = [:]
        for record in sortedMods where record.recordType == SyncConstants.RecordType.referencePDF {
            do {
                if let prepared = try SyncEntityType.prepareReferencePDFMaterialization(record: record) {
                    preparedBuilder[record.recordID] = prepared
                }
            } catch {
                log.error("prepareReferencePDFMaterialization failed for \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let preparedPDFs = preparedBuilder

        // Phase 2 — write transaction. The closure RETURNS its outcome
        // rather than mutating captured `var` locals — GRDB 7's async
        // `write`/`writeWithoutTransaction` closures are `@Sendable`, so
        // mutating outer state across the boundary is a Swift-6
        // strict-concurrency compile error. The apply body lives in the
        // `static` `applyRemoteRows` so the FK-on (with-deletions) and the
        // FK-off (delete-free) call paths share one implementation.
        var rollbackTriggered = false
        var outcome = BatchOutcome(displacedFilenames: [], appliedPDFRecordIDs: [])

        do {
            if deletions.isEmpty {
                // Delete-free batch (every initial-pull batch, most incremental
                // "added rows" batches): tolerate transient cross-batch FK
                // orphans — a child can commit before its parent and becomes
                // valid once the parent arrives in a later batch. `foreign_keys`
                // can't be toggled inside a transaction, so flip it on the
                // serialized writer connection around an explicit transaction
                // and restore it IN-BAND (before the closure returns) so no
                // other write ever sees FK=OFF.
                outcome = try await appDatabase.dbWriter.writeWithoutTransaction { [stateStore] db -> BatchOutcome in
                    try db.execute(sql: "PRAGMA foreign_keys = OFF")
                    var local = BatchOutcome(displacedFilenames: [], appliedPDFRecordIDs: [])
                    do {
                        try db.inTransaction {
                            local = try Self.applyRemoteRows(
                                sortedMods: sortedMods,
                                deletions: [],
                                preparedPDFs: preparedPDFs,
                                stateStore: stateStore,
                                tolerateOrphans: true,
                                db: db
                            )
                            return .commit
                        }
                    } catch {
                        Self.restoreForeignKeysOrAbort(db)   // restore, THEN surface the apply failure
                        throw error
                    }
                    Self.restoreForeignKeysOrAbort(db)        // success: restore before returning
                    return local
                }
            } else {
                // Batch carries deletions → keep FK ON so ON DELETE CASCADE
                // drops children locally (unchanged from before this fix;
                // strict foreign_key_check rolls back genuine violations).
                outcome = try await appDatabase.dbWriter.write { [stateStore] db -> BatchOutcome in
                    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                    return try Self.applyRemoteRows(
                        sortedMods: sortedMods,
                        deletions: deletions,
                        preparedPDFs: preparedPDFs,
                        stateStore: stateStore,
                        tolerateOrphans: false,
                        db: db
                    )
                }
            }
        } catch {
            log.error("applyFetchedZoneChanges failed: \(error.localizedDescription, privacy: .public)")
            rollbackTriggered = true
        }

        // Phase 3 — post-commit file I/O. Off the writer queue. Three buckets:
        //
        //   a) Commit succeeded → unlink prior files we displaced.
        //   b) Commit succeeded but some prepared rows were skipped inside
        //      the transaction (prepared but no apply call — defensive,
        //      should not occur given the pre-stage validates Int64(entityId)).
        //      → unlink the staged file we never used.
        //   c) Commit failed → unlink every freshly-staged file so PDFs/
        //      doesn't reference rows that don't exist.
        if rollbackTriggered {
            for prepared in preparedPDFs.values {
                try? FileManager.default.removeItem(at: prepared.stagedURL)
            }
        } else {
            for filename in outcome.displacedFilenames {
                let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: url)
            }
            for (recordID, prepared) in preparedPDFs where !outcome.appliedPDFRecordIDs.contains(recordID) {
                try? FileManager.default.removeItem(at: prepared.stagedURL)
            }
        }
    }

    /// Apply one fetched-changes batch's modifications + deletions inside the
    /// caller-opened transaction. Extracted as a `static` (captures no `self`;
    /// the file-scope `log` is usable here) so both the FK-on `write` path
    /// (batches with deletions → `ON DELETE CASCADE` must fire) and the FK-off
    /// `writeWithoutTransaction` path (delete-free batches → tolerate transient
    /// cross-batch orphans) share one implementation.
    ///
    /// `tolerateOrphans`: when true, a non-empty `PRAGMA foreign_key_check`
    /// (a child whose parent is in a not-yet-applied batch) is logged and
    /// allowed to commit — it resolves when the parent arrives in a later
    /// batch. When false, it throws `CancellationError` to roll the batch back
    /// (today's strict behavior, kept for any batch carrying deletions).
    private static func applyRemoteRows(
        sortedMods: [CKRecord],
        deletions: [FetchedDeletionInput],
        preparedPDFs: [CKRecord.ID: SyncEntityType.PreparedReferencePDFMaterialization],
        stateStore: SyncStateStore,
        tolerateOrphans: Bool,
        db: Database
    ) throws -> BatchOutcome {
        var local = BatchOutcome(displacedFilenames: [], appliedPDFRecordIDs: [])
        try stateStore.setApplyingRemote(db)

        for record in sortedMods {
            guard let type = SyncEntityType.forRecordType(record.recordType) else {
                log.error("unknown recordType \(record.recordType, privacy: .public); skipping")
                continue
            }
            guard let entityId = SyncEntityType.parseRecordName(record.recordID.recordName)?.1 else {
                log.error("skipping malformed recordName \(record.recordID.recordName, privacy: .public)")
                continue
            }

            if type == .referencePDF {
                guard let prepared = preparedPDFs[record.recordID] else {
                    // Prepare returned nil (malformed name, no asset,
                    // or copyItem failed). Skip apply so we don't
                    // write a pdfCache row pointing at a missing file.
                    // Dirty flag untouched; a later refetch retries.
                    continue
                }
                if let prior = try SyncEntityType.applyPreparedReferencePDF(prepared, db: db) {
                    local.displacedFilenames.append(prior)
                }
                local.appliedPDFRecordIDs.insert(record.recordID)
                try stateStore.markPulled(
                    db,
                    entityType: type,
                    entityId: entityId,
                    record: record
                )
                continue
            }

            let applied = try type.applyRemoteRecord(record, entityId: entityId, db: db)
            if applied {
                try stateStore.markPulled(
                    db,
                    entityType: type,
                    entityId: entityId,
                    record: record
                )
            }
        }

        for deletion in deletions {
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
                entityId: entityId,
                confirmedByServer: true
            )
            try stateStore.clearDirty(db, entityType: type, entityId: entityId)
        }

        // Surface FK state explicitly so it lands in the log rather than as an
        // opaque commit failure. Delete-free batches tolerate transient
        // cross-batch orphans (they resolve when the parent arrives); batches
        // with deletions keep the strict rollback so ON DELETE CASCADE
        // integrity is never silently bypassed.
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        if !violations.isEmpty {
            if tolerateOrphans {
                log.info("remote apply: \(violations.count, privacy: .public) transient FK orphans tolerated (resolve when parents arrive)")
            } else {
                log.error("FK violations after remote apply: \(violations.count, privacy: .public) rows — rolling back")
                throw CancellationError()  // trigger rollback
            }
        }

        try stateStore.clearApplyingRemote(db)
        return local
    }

    /// Restore FK enforcement on the writer connection IN-BAND. The serialized
    /// writer (`DatabasePool` in production, `DatabaseQueue` for the in-memory
    /// fallback + tests) runs writes one at a time on one connection, so
    /// restoring before the `writeWithoutTransaction` closure returns
    /// guarantees the next write sees `foreign_keys = ON` — there is no
    /// interleaving window. A restore that
    /// won't take means a corrupt connection; abort rather than (a) throwing,
    /// which would flow to the outer catch and make Phase 3 unlink committed
    /// PDFs, or (b) swallowing it, which would leave the pooled writer FK-off
    /// for every subsequent local write. Unreachable in practice —
    /// `PRAGMA foreign_keys = ON` is an in-memory flag toggle on a healthy
    /// connection.
    private static func restoreForeignKeysOrAbort(_ db: Database) {
        do {
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                log.fault("foreign_keys would not re-enable on the sync writer — aborting")
                fatalError("Rubien: failed to restore foreign_keys on the database writer")
            }
        } catch {
            log.fault("foreign_keys restore threw: \(error.localizedDescription, privacy: .public)")
            fatalError("Rubien: failed to restore foreign_keys on the database writer")
        }
    }

    /// Test-only entry point. Drives the production
    /// `applyFetchedRecordsInternal` pipeline directly so PDF-materialization
    /// tests can verify the end-to-end actor behavior without standing up a
    /// CKContainer (which would raise CKException in an unentitled XCTest
    /// process).
    func applyFetchedRecordsForTest(
        modifications: [CKRecord],
        deletions: [FetchedDeletionInput]
    ) async {
        await applyFetchedRecordsInternal(modifications: modifications, deletions: deletions)
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
                    // Route through fetchRemoteChanges so every fetch shares
                    // one overlap-guard policy.
                    Task { await self.fetchRemoteChanges() }
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
            Task { await self.fetchRemoteChanges() }
            return
        }

        // referencePDF: pre-stage bytes outside the transaction so the writer
        // queue isn't held by a large copyItem during conflict resolution.
        // `prepare` returns nil for malformed names; we drop the merge then.
        let preparedPDF: SyncEntityType.PreparedReferencePDFMaterialization?
        if type == .referencePDF {
            do {
                preparedPDF = try SyncEntityType.prepareReferencePDFMaterialization(record: serverRecord)
            } catch {
                log.error("serverRecordChanged prepare failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard preparedPDF != nil else { return }
        } else {
            preparedPDF = nil
        }

        // Closure returns `displacedFilename` to avoid mutating captures
        // across the @Sendable boundary. `commitFailed` is only set in the
        // catch block, outside the closure, so it can stay a `var`.
        var commitFailed = false
        var displacedFilename: String? = nil

        do {
            displacedFilename = try await appDatabase.dbWriter.write { [stateStore] db -> String? in
                try stateStore.setApplyingRemote(db)
                let displaced: String?
                let applied: Bool
                if type == .referencePDF, let prepared = preparedPDF {
                    displaced = try SyncEntityType.applyPreparedReferencePDF(prepared, db: db)
                    applied = true
                } else {
                    applied = try type.applyRemoteRecord(serverRecord, entityId: entityId, db: db)
                    displaced = nil
                }
                if applied {
                    try stateStore.markPulled(
                        db,
                        entityType: type,
                        entityId: entityId,
                        record: serverRecord
                    )
                }
                try stateStore.clearApplyingRemote(db)
                return displaced
            }
        } catch {
            log.error("serverRecordChanged merge failed: \(error.localizedDescription, privacy: .public)")
            commitFailed = true
        }

        // Post-commit file I/O (off the writer queue). On commit success
        // the staged file is now owned by `pdfCache` (the apply call
        // succeeded because pre-stage validated the entityId), so we
        // only need to unlink the displaced prior file (if any). On commit
        // failure we unlink the staged file we never promoted.
        if commitFailed {
            if let staged = preparedPDF?.stagedURL {
                try? FileManager.default.removeItem(at: staged)
            }
        } else if let displaced = displacedFilename {
            let url = AppDatabase.pdfStorageURL.appendingPathComponent(displaced)
            try? FileManager.default.removeItem(at: url)
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
#endif
