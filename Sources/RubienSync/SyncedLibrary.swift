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
/// Owns engine startup/reconciliation, push/pull dispatch, PDF asset
/// materialization, and account-change handling around the SQLite source of
/// truth.
@available(macOS 14.0, iOS 17.0, *)
public actor SyncedLibrary: CKSyncEngineDelegate {

    private static let fullHistoryReplaySessionKey =
        "fullHistoryReplayPending"

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

    private struct ServerRecordChangedMergeOutcome: Sendable {
        var displacedFilenames: [String] = []
        var stagedPDFConsumed = false
        var conflictResolved = false
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

    /// Stage engine state for the duration of a fetch so the sidecar never
    /// advances beyond records that committed to SQLite.
    private var statePersistenceGate:
        FetchStatePersistenceGate<CKSyncEngine.State.Serialization>

    /// Engine construction is forbidden until any full-replay marker is
    /// durable and an ambiguous sidecar has been removed. Coordinator
    /// subscriptions may call into this actor before `start()`, so every
    /// engine-forcing entry point checks this gate.
    private var isEngineStartupPrepared = false
    /// Separate from sidecar preparation: CKSyncEngine must also stay lazy
    /// until SQLite durable intent has been normalized successfully.
    private var isDurableIntentReadyForEngine = false
    /// Blocks reentrant observer/fetch/PDF entry points during the final
    /// database-only steps of the first `start()` call.
    private var isPreEngineStartupSequenceActive = false
    private var isStartupPreparationInProgress = false
    private var engineStartupGeneration: UInt64 = 0
    private var accountResetPending = false

    /// Terminal cleanup commits before CKSyncEngine emits the final durable
    /// serialization for that fetch. Keep the DB replay marker until that
    /// serialization has reached disk; otherwise a crash could retain only a
    /// bootstrap sidecar and misclassify the next launch as incremental.
    private var fullHistoryReconciliationAwaitingDurableState = false

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
        let engineStateStore = SyncEngineStateStore(fileURL: stateFileURL)
        self.engineStateStore = engineStateStore
        let persistedFullReplayPending: Bool?
        do {
            persistedFullReplayPending = try appDatabase.dbWriter.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM syncSession WHERE key = ?
                        )
                        """,
                    arguments: [Self.fullHistoryReplaySessionKey]
                ) ?? false
            }
        } catch {
            // Unknown marker state must fail closed. `prepareForStart()` will
            // have to persist a fresh marker successfully before any engine
            // can be constructed.
            persistedFullReplayPending = nil
        }
        self.statePersistenceGate = FetchStatePersistenceGate(
            fullHistoryReplayPending: Self.requiresFullHistoryReplay(
                durableStateAvailable: engineStateStore.load() != nil,
                persistedMarker: persistedFullReplayPending
            )
        )
        self.containerProvider = containerProvider
        self.pdfContentHasher = pdfContentHasher
        self.pdfAssetSyncEnabledProvider = pdfAssetSyncEnabledProvider
    }

    static func requiresFullHistoryReplay(
        durableStateAvailable: Bool,
        persistedMarker: Bool?
    ) -> Bool {
        !durableStateAvailable || persistedMarker != false
    }

    private var container: CKContainer {
        if let existing = _container { return existing }
        let built = containerProvider()
        _container = built
        return built
    }

    // MARK: - Engine lifecycle

    /// Establish the crash-safety preconditions for constructing
    /// CKSyncEngine. A persisted replay marker makes any existing sidecar
    /// ambiguous: it might contain only bootstrap pending-change state, or it
    /// might have been written just before a crash prevented marker cleanup.
    /// Reset it and replay from nil in either case.
    @discardableResult
    public func prepareForStart() async -> Bool {
        if isEngineStartupPrepared { return true }
        guard !isStartupPreparationInProgress else { return false }

        isStartupPreparationInProgress = true
        defer { isStartupPreparationInProgress = false }
        let preparationGeneration = engineStartupGeneration

        if accountResetPending {
            guard await completePendingAccountReset(),
                  preparationGeneration == engineStartupGeneration
            else { return false }
            isEngineStartupPrepared = true
            return true
        }

        guard statePersistenceGate.fullHistoryReplayPending else {
            isEngineStartupPrepared = true
            return true
        }

        let key = Self.fullHistoryReplaySessionKey
        do {
            try await appDatabase.dbWriter.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO syncSession(key, value) VALUES(?, '1')
                        ON CONFLICT(key) DO UPDATE SET value = '1'
                        """,
                    arguments: [key]
                )
            }
            guard preparationGeneration == engineStartupGeneration,
                  !accountResetPending
            else { return false }
            try engineStateStore.reset()
            isEngineStartupPrepared = true
            return true
        } catch {
            log.error(
                "sync startup preparation failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func invalidateEngineStartup(retireEngine: Bool) {
        isEngineStartupPrepared = false
        engineStartupGeneration &+= 1
        if retireEngine {
            _engine = nil
        }
    }

    /// Finish the all-or-nothing local half of an account reset. The database
    /// transaction (including its replay marker) commits before the sidecar is
    /// removed. If either phase fails, `accountResetPending` keeps every
    /// engine-forcing entry point blocked and the next preparation retries the
    /// entire idempotent sequence.
    private func completePendingAccountReset() async -> Bool {
        guard accountResetPending else { return true }
        let replayKey = Self.fullHistoryReplaySessionKey
        do {
            try await appDatabase.dbWriter.write { db in
                try db.execute(sql: """
                    UPDATE syncState
                    SET systemFields = NULL, isDirty = 1, pushInFlight = 0
                    """)
                try db.execute(sql: "DELETE FROM tombstone")
                try db.execute(
                    sql: """
                        INSERT INTO syncSession(key, value) VALUES(?, '1')
                        ON CONFLICT(key) DO UPDATE SET value = '1'
                        """,
                    arguments: [replayKey]
                )
            }
            statePersistenceGate.markDurableStateReset()
            try engineStateStore.reset()
            accountResetPending = false
            return true
        } catch {
            log.error(
                "account-change reset failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Start the engine (creates it if needed). Idempotent; safe to call on
    /// every app launch. All database-only normalization runs before the
    /// first engine access because CKSyncEngine may schedule automatically as
    /// soon as it is constructed.
    @discardableResult
    public func start() async -> Bool {
        let protectsFirstEngineConstruction = _engine == nil
        if protectsFirstEngineConstruction {
            // Never report success while another reentrant start still owns
            // the database-only preparation sequence. Callers fail closed
            // and may retry after that original attempt finishes.
            guard !isPreEngineStartupSequenceActive else { return false }
            isPreEngineStartupSequenceActive = true
        }
        defer {
            if protectsFirstEngineConstruction {
                isPreEngineStartupSequenceActive = false
            }
        }
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

        guard await prepareForStart() else { return false }
        await performInitialBaselineIfNeeded()
        _ = await drainPDFUploadQueueIntoSyncState()
        guard await repairDurableIntentForStartup() else { return false }
        await compactStaleTombstones()
        if protectsFirstEngineConstruction {
            isPreEngineStartupSequenceActive = false
        }
        _ = engine
        // Startup reconciliation — idempotent because
        // `engine.state.add(pendingRecordZoneChanges:)` dedups internally,
        // so recalling on every `start()` is cheap and doesn't need a
        // process-lifetime guard.
        await reconcilePendingChanges()
        return true
    }

    private func repairDurableIntentForStartup() async -> Bool {
        guard !isDurableIntentReadyForEngine else { return true }
        do {
            let report = try await appDatabase.dbWriter.write { db in
                try self.stateStore.repairDurableIntent(db)
            }
            if report.performedRepairCount > 0 {
                log.notice(
                    "startup sync repair normalized \(report.removedLiveTombstoneCount, privacy: .public) live overlaps, \(report.removedDeleteStateCount, privacy: .public) delete overlaps, \(report.removedCleanOrphanStateCount, privacy: .public) clean orphans, \(report.clearedPushInFlightCount, privacy: .public) in-flight rows, \(report.repairedPDFIdentityCount, privacy: .public) PDF identities, and \(report.upgradedActivityTombstoneCount, privacy: .public) activity tombstones"
                )
            }
            isDurableIntentReadyForEngine = true
            return true
        } catch {
            isDurableIntentReadyForEngine = false
            log.error(
                "startup durable-intent repair failed: \(error.localizedDescription, privacy: .public)"
            )
            // Never construct CKSyncEngine against state we failed to
            // normalize; automatic scheduling can begin in its initializer.
            return false
        }
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
        guard isEngineStartupPrepared,
              isDurableIntentReadyForEngine,
              !isPreEngineStartupSequenceActive
        else {
            return
        }
        let generation = engineStartupGeneration
        let drained = await drainPDFUploadQueueIntoSyncState()
        guard !drained.isEmpty else { return }
        guard isEngineStartupPrepared,
              generation == engineStartupGeneration,
              !deferEngineMutationIfDelegateCallbackActive()
        else {
            // The DB-side dirty rows remain durable for the replacement
            // engine's next `ingestPendingChanges()` pass.
            return
        }

        // Hand the drained IDs to the engine. Idempotent: CKSyncEngine
        // dedups pendingRecordZoneChanges by recordID, so re-adding an
        // already-pending change is harmless. This is the only step that
        // forces engine construction; XCTest exercises the DB side via
        // `drainPDFUploadQueueIntoSyncState` directly so this path stays
        // out of unentitled test runs.
        let pending: [CKSyncEngine.PendingRecordZoneChange] = drained.map { id in
            .saveRecord(recordID(for: id, type: .referencePDF))
        }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// DB-side half of the drainer. Returns the IDs that were marked dirty
    /// and removed from the queue, so the caller can pass them to the
    /// engine. Split out from `drainPDFUploadQueue` so tests (which run in
    /// an unentitled XCTest process where touching CKSyncEngine raises
    /// `CKException`) can exercise the DB effects without forcing engine
    /// construction.
    func drainPDFUploadQueueIntoSyncState() async -> [String] {
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
        let drainedSyncIds: [String]
        do {
            drainedSyncIds = try await appDatabase.dbWriter.write { db in
                var result: [String] = []
                for id in pendingIds {
                    guard let syncId = try String.fetchOne(
                        db,
                        sql: "SELECT syncId FROM reference WHERE id = ?",
                        arguments: [id]
                    ) else { continue }
                    try self.stateStore.queueSave(
                        db,
                        entityType: .referencePDF,
                        entityId: syncId
                    )
                    try db.execute(
                        sql: "DELETE FROM pdfUploadQueue WHERE referenceId = ?",
                        arguments: [id]
                    )
                    result.append(syncId)
                }
                return result
            }
        } catch {
            log.error("drainPDFUploadQueue: mark-dirty/clear write failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return drainedSyncIds
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

    private func beginSendCycle() {
        sendCycleError = nil
        noteSend(inFlight: true)
    }

    private func finishSendCycle() {
        isSendInFlight = false
        publishIdleIfQuiescent()
    }

    private func publishIdleIfQuiescent() {
        guard !isFetchInFlight, !isSendInFlight else { return }
        if let sendCycleError {
            publishStatus(.error(sendCycleError))
        } else {
            publishStatus(.idle)
        }
    }

    /// Test-only hook. Production callers go through `publishStatus`.
    func publishStatusForTest(_ status: SyncStatus) {
        publishStatus(status)
    }

    func beginSendCycleForTest() {
        beginSendCycle()
    }

    func noteSendFailureForTest(_ error: CKError) {
        sendCycleError = error
        publishStatus(.error(error))
    }

    func finishSendCycleForTest() {
        finishSendCycle()
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
    private var sendCycleError: CKError?

    /// Overlap guard for explicit fetches. `SyncedLibrary` is an actor, so the
    /// read-then-set below has no suspension point and is race-free across
    /// concurrent callers (launch / foreground / idle timer / error recovery).
    private var isExplicitFetchRunning = false

    /// Post-commit bursts are coalesced before the add-only engine handoff.
    /// Full cache enumeration/removal is reserved for startup, failure
    /// recovery, and the external idle/foreground fetch boundary.
    private var pendingIngestTask: Task<Void, Never>?
    private var pendingIngestGeneration: UInt64 = 0
    private var scheduledIngestExecutionCountForTest = 0
    private var deferredPendingReconciliation = false
    private var deferredDurableRepair = false
    private var deferredReconciliationTask: Task<Void, Never>?
    private var pendingIntentRefreshes: Set<PendingSyncIdentity> = []
    private var activeDelegateEventCount = 0
    private var activeSendBatchCallbackCount = 0
    private var reconciliationAwaitingSendBoundary = false
    private var loggedUnrecognizedPendingChanges: Set<String> = []

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
        if let observer = transactionObserver {
            appDatabase.dbWriter.remove(transactionObserver: observer)
        }
        transactionObserver = nil
        pendingIngestTask?.cancel()
        pendingIngestTask = nil
        pendingIngestGeneration &+= 1
        deferredReconciliationTask?.cancel()
        deferredReconciliationTask = nil
        deferredPendingReconciliation = false
        deferredDurableRepair = false
        reconciliationAwaitingSendBoundary = false
    }

    /// Test-only accessor. We can't exercise the engine side of the
    /// observer pipeline without a CloudKit entitlement, but retention
    /// is the bug we're guarding against — a test can prove it by
    /// reading this property after install / remove.
    var hasTransactionObserver: Bool {
        transactionObserver != nil
    }

    var isEngineStartupPreparedForTest: Bool {
        isEngineStartupPrepared
    }

    var isDurableIntentReadyForEngineForTest: Bool {
        isDurableIntentReadyForEngine
    }

    func beginFinalStartupDatabaseStepForTest() {
        isDurableIntentReadyForEngine = true
        isPreEngineStartupSequenceActive = true
    }

    func endFinalStartupDatabaseStepForTest() {
        isPreEngineStartupSequenceActive = false
    }

    var hasEngineForTest: Bool {
        _engine != nil
    }

    var fullHistoryReplayPendingForTest: Bool {
        statePersistenceGate.fullHistoryReplayPending
    }

    var accountResetPendingForTest: Bool {
        accountResetPending
    }

    var scheduledIngestRunsForTest: Int {
        scheduledIngestExecutionCountForTest
    }

    var pendingIngestGenerationForTest: UInt64 {
        pendingIngestGeneration
    }

    var hasPendingIngestTaskForTest: Bool {
        pendingIngestTask != nil
    }

    func runScheduledPendingChangeIngestForTest(generation: UInt64) async {
        await runScheduledPendingChangeIngest(generation: generation)
    }

    var hasDeferredPendingReconciliationForTest: Bool {
        deferredPendingReconciliation
    }

    var pendingIntentRefreshesForTest: Set<PendingSyncIdentity> {
        pendingIntentRefreshes
    }

    var activeDelegateCallbackCountForTest: Int {
        activeDelegateEventCount
    }

    var isReconciliationAwaitingSendBoundaryForTest: Bool {
        reconciliationAwaitingSendBoundary
    }

    func beginDelegateCallbackForTest() {
        beginEngineEventCallback()
    }

    func endDelegateCallbackForTest() {
        endEngineEventCallback()
    }

    func beginSendBatchCallbackForTest() {
        beginEngineSendBatchCallback()
    }

    func endSendBatchCallbackForTest() {
        endEngineSendBatchCallback()
    }

    func reachSendBoundaryForTest() {
        promoteSendBoundaryReconciliation()
    }

    func reachExternalIdleBoundaryForTest() {
        promoteSendBoundaryReconciliation()
    }

    func noteBatchAnomalyForTest() {
        deferredPendingReconciliation = true
    }

    /// Returns true when the caller must leave CKSyncEngine untouched. This
    /// check belongs immediately after the caller's final suspension point;
    /// an entry-time check alone is insufficient under actor reentrancy.
    @discardableResult
    func deferEngineMutationIfDelegateCallbackActive() -> Bool {
        guard activeDelegateEventCount > 0 else { return false }
        deferPendingReconciliationForActiveCallback()
        return true
    }

    private func beginEngineEventCallback() {
        activeDelegateEventCount += 1
    }

    private func endEngineEventCallback() {
        precondition(activeDelegateEventCount > 0)
        activeDelegateEventCount -= 1
        if activeDelegateEventCount == 0 {
            scheduleDeferredReconciliationAfterCallback()
        }
    }

    private func beginEngineSendBatchCallback() {
        activeDelegateEventCount += 1
        activeSendBatchCallbackCount += 1
    }

    private func endEngineSendBatchCallback() {
        precondition(activeDelegateEventCount > 0)
        precondition(activeSendBatchCallbackCount > 0)
        activeSendBatchCallbackCount -= 1
        activeDelegateEventCount -= 1
        // CKSyncEngine still has to consume the returned batch and its record
        // providers. The matching sent/did-send event promotes deferred work.
    }

    private func deferPendingReconciliationForActiveCallback() {
        if activeSendBatchCallbackCount > 0 {
            reconciliationAwaitingSendBoundary = true
        } else {
            deferredPendingReconciliation = true
        }
    }

    private func promoteSendBoundaryReconciliation() {
        guard reconciliationAwaitingSendBoundary else { return }
        reconciliationAwaitingSendBoundary = false
        deferredPendingReconciliation = true
    }

    private func scheduleDeferredReconciliationAfterCallback() {
        guard deferredPendingReconciliation || deferredDurableRepair,
              deferredReconciliationTask == nil
        else { return }
        // This is deliberately the callback's final action. With no later
        // await in either delegate entry point, actor isolation prevents
        // pending-state mutation from beginning until that turn has returned.
        deferredReconciliationTask = Task { [weak self] in
            await Task.yield()
            _ = await self?.consumeDeferredPendingReconciliation()
        }
    }

    @discardableResult
    private func consumeDeferredPendingReconciliation() async -> Bool {
        let needsRepair = deferredDurableRepair
        let needsReconciliation = deferredPendingReconciliation || needsRepair
        deferredDurableRepair = false
        deferredPendingReconciliation = false
        deferredReconciliationTask = nil
        guard needsReconciliation else { return false }

        if needsRepair {
            do {
                _ = try await appDatabase.dbWriter.write { db in
                    try self.stateStore.repairDurableIntent(db)
                }
            } catch {
                log.error(
                    "deferred durable-intent repair failed: \(error.localizedDescription, privacy: .public)"
                )
                // Do not canonicalize CKSyncEngine from state that failed
                // normalization. Keep both requests durable in actor state;
                // the next callback completion or external idle boundary
                // will retry them.
                deferredDurableRepair = true
                deferredPendingReconciliation = true
                return true
            }
        }
        await reconcilePendingChanges()
        return true
    }

    /// Called by the synchronous GRDB observer after commit. Replacing the
    /// prior task makes an import burst pay for one SQLite scan and one
    /// add-only engine update instead of one per inserted row.
    public func schedulePendingChangeIngest() {
        // Recovery writes can notify the transaction observer while an async
        // CKSyncEngine delegate turn is suspended. Defer all engine-state
        // mutation until that turn has actually returned.
        if activeDelegateEventCount > 0 {
            deferPendingReconciliationForActiveCallback()
            return
        }
        pendingIngestTask?.cancel()
        pendingIngestGeneration &+= 1
        let generation = pendingIngestGeneration
        pendingIngestTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.runScheduledPendingChangeIngest(generation: generation)
        }
    }

    private func runScheduledPendingChangeIngest(generation: UInt64) async {
        guard generation == pendingIngestGeneration else { return }
        pendingIngestTask = nil
        scheduledIngestExecutionCountForTest += 1
        await ingestPendingChanges(expectedScheduledGeneration: generation)
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
        await ingestPendingChanges(expectedScheduledGeneration: nil)
    }

    private func ingestPendingChanges(
        expectedScheduledGeneration: UInt64?
    ) async {
        guard isEngineStartupPrepared,
              isDurableIntentReadyForEngine,
              !isPreEngineStartupSequenceActive
        else {
            return
        }
        let generation = engineStartupGeneration
        do {
            let desired = try await appDatabase.dbWriter.read { db in
                try self.stateStore.desiredPendingIntents(db).intents
            }
            let pending = desired.map(pendingChange(for:))

            if !pending.isEmpty {
                if let expectedScheduledGeneration,
                   expectedScheduledGeneration != pendingIngestGeneration
                {
                    return
                }
                guard isEngineStartupPrepared,
                      generation == engineStartupGeneration,
                      !deferEngineMutationIfDelegateCallbackActive()
                else { return }
                engine.state.add(pendingRecordZoneChanges: pending)
            }
        } catch {
            log.error("ingestPendingChanges failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Make CKSyncEngine's derived pending cache exactly match current
    /// SQLite intent for every record type this build understands. Unknown
    /// future record types are left untouched for forward compatibility.
    public func reconcilePendingChanges() async {
        guard isEngineStartupPrepared,
              isDurableIntentReadyForEngine,
              !isPreEngineStartupSequenceActive
        else {
            return
        }
        let generation = engineStartupGeneration
        do {
            let desiredResolution = try await appDatabase.dbWriter.read { db in
                try self.stateStore.desiredPendingIntents(db)
            }
            guard isEngineStartupPrepared,
                  generation == engineStartupGeneration,
                  !deferEngineMutationIfDelegateCallbackActive()
            else { return }

            let syncEngine = engine
            let knownCurrent = recognizedPendingIdentities(
                from: syncEngine.state.pendingRecordZoneChanges
            )
            let plan = SyncPendingIntentPlanner.plan(
                current: knownCurrent,
                desired: desiredResolution.intents,
                refreshing: pendingIntentRefreshes
            )
            if !plan.removals.isEmpty {
                syncEngine.state.remove(
                    pendingRecordZoneChanges: plan.removals.map(pendingChange(for:))
                )
            }
            if !plan.additions.isEmpty {
                syncEngine.state.add(
                    pendingRecordZoneChanges: plan.additions.map(pendingChange(for:))
                )
            }
            pendingIntentRefreshes.removeAll()
            if desiredResolution.anomalyDetected {
                log.error("durable sync intent remained contradictory during pending-cache reconciliation")
            }
        } catch {
            log.error(
                "pending-cache reconciliation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Release the one-time mixed-version writer gate after the user has
    /// confirmed that every older writable Mac is upgraded or offline.
    /// Pending work remains durable in SQLite until this deletion commits.
    public func acknowledgeWriterUpgrade() async throws {
        try await appDatabase.dbWriter.write { db in
            try self.stateStore.acknowledgeWriterUpgrade(db)
        }
        await ingestPendingChanges()
    }

    public func isWriterUpgradeRequired() async throws -> Bool {
        try await appDatabase.dbWriter.read { db in
            try self.stateStore.writerUpgradeRequired(db)
        }
    }

    /// Drive an explicit incremental fetch. The single funnel for every
    /// external fetch trigger (launch, foreground, idle timer), so the overlap
    /// guard is the one concurrency policy. Returns `true` on success or a
    /// no-op skip (another fetch is already in flight); `false` on error, which
    /// the idle timer uses to back off. Never call this as a consequence of a
    /// CKSyncEngine delegate event; CloudKit forbids re-entering the engine
    /// from its callback. Only called once the library is live, so `engine`
    /// already exists.
    @discardableResult
    public func fetchRemoteChanges() async -> Bool {
        // Actor reentrancy can admit an external foreground/idle request while
        // an async delegate handler is awaiting SQLite. Treat it as a benign
        // no-op so neither pending-state mutation nor fetch re-entry occurs
        // before the callback returns.
        guard activeDelegateEventCount == 0,
              !isPreEngineStartupSequenceActive
        else { return true }
        guard !isExplicitFetchRunning else { return true }
        isExplicitFetchRunning = true
        defer { isExplicitFetchRunning = false }

        // The failed engine has already advanced in memory. Recreate it from
        // the last durable sidecar only from a normal external fetch trigger
        // (launch/foreground/idle), never from inside handleEvent.
        if statePersistenceGate.requiresEngineRecovery {
            guard !isFetchInFlight, !isSendInFlight else { return false }
            log.notice("recreating sync engine from last durable state after failed remote apply")
            invalidateEngineStartup(retireEngine: true)
            statePersistenceGate.resetAfterEngineRecovery()
            guard await prepareForStart() else { return false }
            guard await repairDurableIntentForStartup() else { return false }
            _ = engine
            await reconcilePendingChanges()
        } else {
            guard await prepareForStart() else { return false }
            guard await repairDurableIntentForStartup() else { return false }
        }

        guard isEngineStartupPrepared else { return false }
        // A resolver can return no batch after detecting stale engine intent,
        // in which case CKSyncEngine may emit no terminal send event. The
        // normal external fetch boundary is the fallback canonicalization
        // point required to keep that anomaly from becoming permanent.
        promoteSendBoundaryReconciliation()
        let consumedDeferredWork = await consumeDeferredPendingReconciliation()
        // A failed durable repair leaves its retry flag set. Do not fetch or
        // canonicalize from state that could still contain invalid intent.
        guard !deferredDurableRepair else { return false }
        if !consumedDeferredWork {
            await reconcilePendingChanges()
        }
        // The awaits above can admit a delegate callback. Recheck at the
        // actual fetch boundary, where there is no later suspension before
        // entering CKSyncEngine.
        guard activeDelegateEventCount == 0,
              !isPreEngineStartupSequenceActive
        else { return true }
        let fetchGeneration = engineStartupGeneration
        let fetchEngine = engine
        do {
            try await fetchEngine.fetchChanges()
            return fetchGeneration == engineStartupGeneration
                && !statePersistenceGate.requiresEngineRecovery
        } catch {
            log.error("fetchRemoteChanges failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private var engine: CKSyncEngine {
        precondition(
            isEngineStartupPrepared,
            "CKSyncEngine must not be constructed before startup preparation"
        )
        precondition(
            isDurableIntentReadyForEngine,
            "CKSyncEngine must not be constructed before durable-intent repair"
        )
        precondition(
            !isPreEngineStartupSequenceActive,
            "CKSyncEngine must not be constructed before startup DB work finishes"
        )
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

                var totalMarked = 0
                for source in SyncLocalEntityCatalog.current {
                    // Baseline is a real save-intent writer, not merely a
                    // bookkeeping backfill. Establish exclusivity in this
                    // transaction before marking each live identity dirty.
                    try db.execute(sql: """
                        DELETE FROM tombstone
                        WHERE entityType = ?
                          AND EXISTS (
                            SELECT 1 FROM \(source.baselineFromClause)
                            WHERE \(source.baselineIdentityExpression) =
                                  tombstone.entityId
                          )
                        """, arguments: [source.entityType])
                    // SQLite grammar quirk: the INSERT-SELECT form needs
                    // an explicit `WHERE true` before `ON CONFLICT`,
                    // otherwise the parser rejects the upsert clause as
                    // ambiguous with the SELECT's WHERE slot.
                    try db.execute(sql: """
                        INSERT INTO syncState(
                            entityType, entityId, isDirty, pushInFlight
                        )
                            SELECT '\(source.entityType)',
                                   \(source.baselineIdentityExpression), 1, 0
                            FROM \(source.baselineFromClause) WHERE true
                            ON CONFLICT(entityType, entityId) DO UPDATE SET
                                isDirty = 1,
                                pushInFlight = 0
                        """)
                    totalMarked += db.changesCount
                }
                // This write shares the baseline transaction. A failed or
                // interrupted INSERT loop rolls back both the dirty markers
                // and this completion gate, so startup retries safely.
                try db.execute(sql: """
                    INSERT INTO syncSession(key, value)
                    VALUES('baselineState', 'complete')
                    """)
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
        // Recovery replaces an engine whose in-memory cursor advanced past a
        // failed apply. Ignore any callback the retired instance had already
        // queued, especially a late stateUpdate carrying that unsafe cursor.
        guard syncEngine === _engine else {
            log.debug("ignoring callback from retired sync engine")
            return
        }
        beginEngineEventCallback()
        defer { endEngineEventCallback() }

        switch event {
        case .stateUpdate(let event):
            if let durableState = statePersistenceGate.receiveStateUpdate(
                event.stateSerialization
            ) {
                if !(await persistStateSerialization(durableState)) {
                    statePersistenceGate.markFetchedChangesApplyFailed()
                    invalidateEngineStartup(retireEngine: false)
                }
            }

        case .accountChange(let event):
            await handleAccountChange(event)

        case .fetchedRecordZoneChanges(let event):
            let applied = await applyFetchedZoneChanges(event)
            if !applied {
                fullHistoryReconciliationAwaitingDurableState = false
                statePersistenceGate.markFetchedChangesApplyFailed()
                invalidateEngineStartup(retireEngine: false)
            }

        case .sentRecordZoneChanges(let event):
            promoteSendBoundaryReconciliation()
            await handleSentZoneChanges(event, syncEngine: syncEngine)

        case .willFetchChanges:
            fullHistoryReconciliationAwaitingDurableState = false
            statePersistenceGate.beginFetch()
            noteFetch(inFlight: true)
        case .willSendChanges:
            beginSendCycle()
        case .didFetchChanges:
            let durableState = statePersistenceGate.finishFetch()
            if let durableState {
                if await persistStateSerialization(durableState) {
                    if fullHistoryReconciliationAwaitingDurableState {
                        _ = await finalizeFullHistoryReplayAfterDurableState()
                    }
                } else {
                    statePersistenceGate.markFetchedChangesApplyFailed()
                    invalidateEngineStartup(retireEngine: false)
                }
            } else if fullHistoryReconciliationAwaitingDurableState {
                // Do not let this advanced in-memory engine continue from a
                // cleanup boundary for which no durable cursor was emitted.
                statePersistenceGate.markFetchedChangesApplyFailed()
                invalidateEngineStartup(retireEngine: false)
            }
            noteFetch(inFlight: false)
        case .didSendChanges:
            promoteSendBoundaryReconciliation()
            finishSendCycle()

        case .didFetchRecordZoneChanges(let event):
            // A failed batch means later parents may not have committed. Do
            // not classify its surviving children as terminal orphans; the
            // engine will be recreated from the last durable cursor instead.
            guard event.zoneID == SyncConstants.libraryZoneID else { break }
            if let error = event.error {
                log.error(
                    "record-zone fetch ended with error: \(error.localizedDescription, privacy: .public)"
                )
                fullHistoryReconciliationAwaitingDurableState = false
                statePersistenceGate.markFetchedChangesApplyFailed()
                invalidateEngineStartup(retireEngine: false)
                break
            }
            guard statePersistenceGate.canFinalizeFetchedZone else { break }
            let includeTerminalOrphans =
                statePersistenceGate.shouldReconcileTerminalOrphans
            let reconciled = await reconcileFetchedZoneAfterFetch(
                includeTerminalOrphans: includeTerminalOrphans
            )
            if !reconciled {
                fullHistoryReconciliationAwaitingDurableState = false
                statePersistenceGate.markFetchedChangesApplyFailed()
                invalidateEngineStartup(retireEngine: false)
            } else if includeTerminalOrphans {
                fullHistoryReconciliationAwaitingDurableState = true
            }

        case .fetchedDatabaseChanges,
             .sentDatabaseChanges,
             .willFetchRecordZoneChanges:
            // Lifecycle events we currently only observe. UI
            // syncing-indicator updates will hook in here in a later
            // commit.
            break

        @unknown default:
            log.error("unhandled CKSyncEngine.Event case — a newer OS added a variant we don't know about")
        }

    }

    private func reconcileFetchedZoneAfterFetch(
        includeTerminalOrphans: Bool
    ) async -> Bool {
        do {
            let outcome = try await appDatabase.dbWriter.write {
                [stateStore] db in
                try SyncEntityType.reconcileActivityQuarantineAfterFetch(
                    deleteMissingReferenceFacts: includeTerminalOrphans,
                    stateStore: stateStore,
                    db: db
                )
                guard includeTerminalOrphans else {
                    return SyncEntityType.FetchOrphanReconciliationOutcome()
                }
                let outcome = try SyncEntityType.reconcileTerminalOrphansAfterFetch(
                    stateStore: stateStore,
                    db: db
                )
                return outcome
            }
            Self.unlinkStoredPDFFilenames(outcome.pdfFilenamesToDelete)
            if outcome.reconciledRowCount > 0 {
                log.notice(
                    "reconciled \(outcome.reconciledRowCount, privacy: .public) terminal FK orphan rows after zone fetch"
                )
            }
            return true
        } catch {
            log.error("post-fetch reconciliation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Test seam for end-of-zone DB reconciliation without constructing a
    /// CKSyncEngine in an unentitled XCTest process.
    func reconcileFetchedZoneForTest(
        includeTerminalOrphans: Bool = true
    ) async -> Bool {
        await reconcileFetchedZoneAfterFetch(
            includeTerminalOrphans: includeTerminalOrphans
        )
    }

    func finalizeFullHistoryReplayForTest() async -> Bool {
        await finalizeFullHistoryReplayAfterDurableState()
    }

    /// Clear the replay marker only after the corresponding end-of-fetch
    /// CKSyncEngine serialization is safely on disk. Sidecar first, marker
    /// second is intentionally conservative: if the process crashes between
    /// them, the surviving marker makes the next startup discard that
    /// ambiguous sidecar and replay from nil again.
    private func finalizeFullHistoryReplayAfterDurableState() async -> Bool {
        let key = Self.fullHistoryReplaySessionKey
        do {
            try await appDatabase.dbWriter.write { db in
                try db.execute(
                    sql: "DELETE FROM syncSession WHERE key = ?",
                    arguments: [key]
                )
            }
            statePersistenceGate.markFullHistoryReplayCompleted()
            fullHistoryReconciliationAwaitingDurableState = false
            return true
        } catch {
            log.error(
                "failed to finalize full-history replay: \(error.localizedDescription, privacy: .public)"
            )
            // The sidecar may already carry the advanced cursor while the DB
            // marker remains. Retire it; startup preparation will discard the
            // ambiguous sidecar before the next external fetch.
            statePersistenceGate.markFetchedChangesApplyFailed()
            invalidateEngineStartup(retireEngine: false)
            return false
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === _engine else { return nil }
        // This delegate entry point suspends on SQLite below. Count it just
        // like handleEvent so actor reentrancy cannot admit observer ingestion
        // or an explicit fetch that mutates CKSyncEngine mid-send.
        beginEngineSendBatchCallback()
        defer { endEngineSendBatchCallback() }

        let scopedPending = syncEngine.state
            .pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
        let resolution: BatchIntentResolution
        do {
            let identities = recognizedPendingIdentities(from: scopedPending)
            resolution = try await appDatabase.dbWriter.read { db in
                try self.stateStore.resolveBatchIntents(
                    db,
                    pendingIdentities: identities
                )
            }
        } catch {
            log.error(
                "failed to resolve pending sync changes: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        if resolution.anomalyDetected {
            log.error("contradictory or stale sync intent reached batch construction")
            reconciliationAwaitingSendBoundary = true
        }
        let pending = Self.originalPendingChanges(
            selected: resolution.intents,
            scopedPending: scopedPending
        )
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
                    if try stateStore.writerUpgradeRequired(db),
                       entityType.isUnsafeForV12(entityId: entityId)
                    {
                        return nil
                    }
                    guard try entityType.activityFactIsPushEligible(
                        db: db,
                        entityId: entityId
                    ) else { return nil }
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
                    // This predicate is the authoritative last word, not a
                    // duplicate of the resolver's earlier dirty read: the
                    // resolver and provider execute in separate transactions.
                    guard try stateStore.markPushInFlight(
                        db,
                        entityType: entityType,
                        entityId: entityId
                    ) else { return nil }
                    return record
                }
            } catch {
                log.error("buildPushRecord failed for \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private static func pendingIdentity(
        for change: CKSyncEngine.PendingRecordZoneChange
    ) -> PendingSyncIdentity? {
        let operation: SyncPendingOperation
        switch change {
        case .saveRecord:
            operation = .save
        case .deleteRecord:
            operation = .delete
        @unknown default:
            return nil
        }
        guard let recordID = pendingRecordID(for: change) else { return nil }
        guard let (type, entityId) = SyncEntityType.parseRecordName(
            recordID.recordName
        ), recordID.zoneID == SyncConstants.libraryZoneID else { return nil }
        return PendingSyncIdentity(
            type: type,
            entityId: entityId,
            operation: operation
        )
    }

    private static func pendingRecordID(
        for change: CKSyncEngine.PendingRecordZoneChange
    ) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id):
            return id
        @unknown default:
            return nil
        }
    }

    private func recognizedPendingIdentities(
        from changes: [CKSyncEngine.PendingRecordZoneChange]
    ) -> [PendingSyncIdentity] {
        changes.compactMap { change in
            guard let identity = Self.pendingIdentity(for: change) else {
                let recordID = Self.pendingRecordID(for: change)
                let key = recordID.map {
                    "\($0.zoneID.ownerName)/\($0.zoneID.zoneName)/\($0.recordName)"
                } ?? "unknown-enum-case"
                if loggedUnrecognizedPendingChanges.insert(key).inserted {
                    log.error(
                        "preserving unrecognized engine pending change \(key, privacy: .public)"
                    )
                }
                return nil
            }
            return identity
        }
    }

    var loggedUnrecognizedPendingChangeCountForTest: Int {
        loggedUnrecognizedPendingChanges.count
    }

    func recognizedPendingIdentitiesForTest(
        from changes: [CKSyncEngine.PendingRecordZoneChange]
    ) -> [PendingSyncIdentity] {
        recognizedPendingIdentities(from: changes)
    }

    /// Preserve the exact pending values accepted by SendChangesContext.
    /// Rebuilding from recordName would silently move a parseable record from
    /// another zone into Rubien's library zone.
    static func originalPendingChanges(
        selected: [PendingSyncIdentity],
        scopedPending: [CKSyncEngine.PendingRecordZoneChange]
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        var originals: [
            PendingSyncIdentity: CKSyncEngine.PendingRecordZoneChange
        ] = [:]
        for change in scopedPending {
            guard let identity = pendingIdentity(for: change) else { continue }
            originals[identity] = change
        }
        return selected.compactMap { originals[$0] }
    }

    private func pendingChange(
        for identity: PendingSyncIdentity
    ) -> CKSyncEngine.PendingRecordZoneChange {
        let id = recordID(for: identity.entityId, type: identity.type)
        switch identity.operation {
        case .save:
            return .saveRecord(id)
        case .delete:
            return .deleteRecord(id)
        }
    }

    // MARK: - Event handlers

    private func persistStateSerialization(
        _ serialization: CKSyncEngine.State.Serialization
    ) async -> Bool {
        do {
            try engineStateStore.save(serialization)
            return true
        } catch {
            log.error("failed to persist engine state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func resetForAccountChange() async -> Bool {
        accountResetPending = true
        invalidateEngineStartup(retireEngine: true)
        fullHistoryReconciliationAwaitingDurableState = false
        isFetchInFlight = false
        isSendInFlight = false
        sendCycleError = nil
        pendingIngestTask?.cancel()
        pendingIngestTask = nil
        pendingIngestGeneration &+= 1
        deferredReconciliationTask?.cancel()
        deferredReconciliationTask = nil
        deferredPendingReconciliation = false
        deferredDurableRepair = false
        reconciliationAwaitingSendBoundary = false
        isDurableIntentReadyForEngine = false

        // A concurrent startup preparation will observe the generation
        // change and return without enabling its engine. It leaves this
        // durable retry for the next external startup/fetch trigger.
        guard !isStartupPreparationInProgress else { return false }
        isStartupPreparationInProgress = true
        defer { isStartupPreparationInProgress = false }
        return await completePendingAccountReset()
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        // B5 expansion: per-case handling. For now, we preserve local
        // library data on sign-out (clear sync metadata only) and log sign-
        // in so the UI can pick up the change. switchAccounts will require
        // explicit user confirmation before we migrate data; current path
        // freezes the engine.
        switch event.changeType {
        case .signOut, .switchAccounts:
            _ = await resetForAccountChange()

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
    ) async -> Bool {
        let mods = event.modifications.map(\.record)
        let dels: [FetchedDeletionInput] = event.deletions.map {
            FetchedDeletionInput(recordID: $0.recordID, recordType: $0.recordType)
        }
        return await applyFetchedRecordsInternal(
            modifications: mods,
            deletions: dels
        )
    }

    /// Outcome of applying one fetched-changes batch. The write closure is
    /// `@Sendable`, so it RETURNS this value rather than mutating captured
    /// `var`s; the returned filenames drive the Phase-3 post-commit PDF
    /// cleanup. Type-scope so the `static` `applyRemoteRows` can name it.
    private struct BatchOutcome: Sendable {
        var displacedFilenames: [String]
        var deletedFilenames: [String]
        var appliedPDFRecordIDs: Set<CKRecord.ID>

        static var empty: Self {
            Self(
                displacedFilenames: [],
                deletedFilenames: [],
                appliedPDFRecordIDs: []
            )
        }

        mutating func merge(_ other: Self) {
            displacedFilenames.append(contentsOf: other.displacedFilenames)
            deletedFilenames.append(contentsOf: other.deletedFilenames)
            appliedPDFRecordIDs.formUnion(other.appliedPDFRecordIDs)
        }
    }

    /// A fetched event can span two committed SQLite transactions:
    /// modifications first (FK-off, allowing cross-batch orphans), then
    /// deletions (FK-on, preserving cascades). If the second phase fails, its
    /// caller still needs the first phase's outcome for correct staged-PDF
    /// cleanup. The CKSyncEngine state gate keeps the event's cursor
    /// non-durable until both phases succeed, so replay remains idempotent.
    private struct BatchExecutionResult: Sendable {
        var committedOutcome: BatchOutcome
        var errorDescription: String?

        var succeeded: Bool { errorDescription == nil }
    }

    /// Stable identity for one row returned by `PRAGMA foreign_key_check`.
    /// SQLite reports the child table/row, parent table, and FK slot. That is
    /// enough to distinguish violations that pre-date a fetched batch from
    /// violations introduced by the batch itself.
    private struct ForeignKeyViolation: Hashable, Sendable {
        let childTable: String
        let childRowID: Int64?
        let parentTable: String
        let foreignKeyIndex: Int64

        init(row: Row) {
            childTable = row["table"]
            childRowID = row["rowid"]
            parentTable = row["parent"]
            foreignKeyIndex = row["fkid"]
        }
    }

    private enum ForeignKeyViolationPolicy: Sendable {
        /// Modification transactions deliberately run with FK enforcement
        /// disabled; every violation may be a child whose parent arrives in a
        /// later CloudKit event.
        case tolerateAll
        /// Deletion transactions keep FK enforcement enabled for cascades.
        /// They may preserve or resolve an orphan committed by an earlier
        /// transaction, but must not introduce a new violation of their own.
        case tolerateExisting(Set<ForeignKeyViolation>)
    }

    /// Shared implementation used by `applyFetchedZoneChanges` and tests.
    /// Pre-stages every `referencePDF` modification *outside* the write
    /// transaction (file I/O off the writer queue). The transaction body
    /// then runs only the small `pdfCache` upsert plus the existing
    /// non-PDF apply paths. Old filenames returned by `applyPreparedReferencePDF`
    /// and staged files for skipped-or-rolled-back records are unlinked
    /// post-transaction so PDFs/ never accumulates orphans.
    @discardableResult
    private func applyFetchedRecordsInternal(
        modifications: [CKRecord],
        deletions: [FetchedDeletionInput]
    ) async -> Bool {
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
        // `prepare` validates recordName and global identity internally, so a
        // malformed record simply returns nil with no staged file. Frozen into
        // a `let` for safe capture by the @Sendable write closure below.
        var preparedBuilder: [CKRecord.ID: SyncEntityType.PreparedReferencePDFMaterialization] = [:]
        var pdfStagingFailed = false
        for record in sortedMods where record.recordType == SyncConstants.RecordType.referencePDF {
            do {
                if var prepared = try SyncEntityType
                    .prepareReferencePDFMaterialization(record: record)
                {
                    let preparedSnapshot = prepared
                    let hint = try await appDatabase.dbWriter.read { db in
                        try SyncEntityType.referencePDFReuseHint(
                            for: preparedSnapshot,
                            db: db
                        )
                    }
                    if let hint {
                        let liveURL = AppDatabase.pdfStorageURL
                            .appendingPathComponent(hint.localFilename)
                        if FileManager.default.fileExists(atPath: liveURL.path) {
                            prepared = prepared.withReuseHint(hint)
                        }
                    }
                    preparedBuilder[record.recordID] = prepared
                }
            } catch {
                log.error("prepareReferencePDFMaterialization failed for \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                pdfStagingFailed = true
            }
        }
        let preparedPDFs = preparedBuilder

        // Phase 2 — serialize two explicit transactions on the same writer
        // connection. CKSyncEngine groups modifications and deletions into one
        // event, but does not guarantee that a modification's FK parent appears
        // in that event (or an earlier one).
        //
        // Modifications therefore commit with FK enforcement disabled. Then FK
        // enforcement is restored IN-BAND and deletions commit separately with
        // cascades enabled. Keeping modifications before deletions preserves the
        // previous event ordering: a deletion wins when the same event modifies
        // one of its local descendants. No other write can interleave while the
        // `writeWithoutTransaction` closure owns the serialized writer.
        //
        // The closure RETURNS all committed work even if the deletion phase
        // fails. GRDB 7's async write closure is `@Sendable`, so mutating outer
        // state across this boundary would violate Swift-6 strict concurrency.
        let execution: BatchExecutionResult
        do {
            execution = try await appDatabase.dbWriter.writeWithoutTransaction {
                [stateStore] db -> BatchExecutionResult in
                var committed = BatchOutcome.empty

                if !sortedMods.isEmpty {
                    try db.execute(sql: "PRAGMA foreign_keys = OFF")
                    var modificationOutcome = BatchOutcome.empty
                    do {
                        try db.inTransaction {
                            modificationOutcome = try Self.applyRemoteRows(
                                sortedMods: sortedMods,
                                deletions: [],
                                preparedPDFs: preparedPDFs,
                                stateStore: stateStore,
                                violationPolicy: .tolerateAll,
                                db: db
                            )
                            return .commit
                        }
                    } catch {
                        Self.restoreForeignKeysOrAbort(db)
                        return BatchExecutionResult(
                            committedOutcome: committed,
                            errorDescription: "modification phase: \(error.localizedDescription)"
                        )
                    }
                    Self.restoreForeignKeysOrAbort(db)
                    committed.merge(modificationOutcome)
                }

                if !deletions.isEmpty {
                    var deletionOutcome = BatchOutcome.empty
                    do {
                        let existingViolations = try Self.foreignKeyViolations(db)
                        try db.inTransaction {
                            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                            deletionOutcome = try Self.applyRemoteRows(
                                sortedMods: [],
                                deletions: deletions,
                                preparedPDFs: [:],
                                stateStore: stateStore,
                                violationPolicy: .tolerateExisting(existingViolations),
                                db: db
                            )
                            return .commit
                        }
                    } catch {
                        return BatchExecutionResult(
                            committedOutcome: committed,
                            errorDescription: "deletion phase: \(error.localizedDescription)"
                        )
                    }
                    committed.merge(deletionOutcome)
                }

                return BatchExecutionResult(
                    committedOutcome: committed,
                    errorDescription: nil
                )
            }
        } catch {
            execution = BatchExecutionResult(
                committedOutcome: .empty,
                errorDescription: error.localizedDescription
            )
        }

        if let errorDescription = execution.errorDescription {
            log.error("applyFetchedZoneChanges failed: \(errorDescription, privacy: .public)")
        }

        // Phase 3 — post-commit file I/O. Off the writer queue. Three buckets:
        //
        //   a) A modification committed → unlink prior files it displaced.
        //   b) Some prepared rows were skipped or their modification
        //      transaction rolled back (prepared but no apply call — for
        //      example, an unresolved global parent moved it to syncOrphan).
        //      → unlink the staged file we never used.
        //
        // A later deletion-phase failure does not change which PDF
        // modifications committed, so cleanup keys off the committed outcome
        // instead of treating the whole event as all-or-nothing.
        Self.unlinkStoredPDFFilenames(
            execution.committedOutcome.displacedFilenames
                + execution.committedOutcome.deletedFilenames
        )
        for (recordID, prepared) in preparedPDFs
            where !execution.committedOutcome.appliedPDFRecordIDs.contains(recordID)
        {
            try? FileManager.default.removeItem(at: prepared.stagedURL)
        }

        // A copy failure is transient (for example, CKAsset materialization or
        // filesystem availability). Other records may commit idempotently, but
        // the fetch cursor must remain non-durable so the PDF is retried.
        return execution.succeeded && !pdfStagingFailed
    }

    /// Apply one fetched-changes batch's modifications + deletions inside the
    /// caller-opened transaction. Extracted as a `static` (captures no `self`;
    /// the file-scope `log` is usable here) so both the FK-off modification
    /// phase and FK-on deletion phase share one implementation.
    ///
    /// `violationPolicy` distinguishes modification transactions (all
    /// violations can be transient cross-batch orphans) from deletion
    /// transactions (keep FK enforcement enabled for cascades, but do not roll
    /// back merely because an earlier transaction committed an orphan).
    private static func applyRemoteRows(
        sortedMods: [CKRecord],
        deletions: [FetchedDeletionInput],
        preparedPDFs: [CKRecord.ID: SyncEntityType.PreparedReferencePDFMaterialization],
        stateStore: SyncStateStore,
        violationPolicy: ForeignKeyViolationPolicy,
        db: Database
    ) throws -> BatchOutcome {
        var local = BatchOutcome.empty
        var appliedReferenceSyncIDs = Set<String>()
        var changedEpochKinds = Set<ActivityKind>()
        var globalDependenciesChanged = false
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
            if try stateStore.activeDeleteSuppressesRemoteRecord(
                db,
                entityType: type,
                entityId: entityId
            ) {
                // A local delete is newer than this fetched modification.
                // Avoid rematerializing the row while its exact delete is
                // still pending. Prepared PDF files remain outside the
                // applied set and are removed by post-commit cleanup.
                continue
            }

            let dependencyStatus = try type.remoteDependencyStatus(
                for: record,
                entityId: entityId,
                db: db
            )
            if dependencyStatus != .ready {
                let stagedFilename = preparedPDFs[record.recordID]?.stagedFilename
                if let displaced = try SyncEntityType.quarantineRemoteRecord(
                    record,
                    stagedFilename: stagedFilename,
                    db: db
                ) {
                    local.displacedFilenames.append(displaced)
                }
                if stagedFilename != nil {
                    // Ownership of the staged file moved to syncOrphan; keep
                    // the post-transaction cleanup from unlinking it.
                    local.appliedPDFRecordIDs.insert(record.recordID)
                }
                // Quarantine owns the server version until dependencies resolve.
                // Do not acknowledge it yet: `markPulled` clears `isDirty`, which
                // would discard a pending local edit for a row we did not apply.
                continue
            }

            if type == .referencePDF {
                guard let prepared = preparedPDFs[record.recordID] else {
                    // Prepare returned nil (malformed name or no asset).
                    // Copy failures are tracked before the transaction and
                    // make the whole fetched event non-durable. Skip apply so we don't
                    // write a pdfCache row pointing at a missing file.
                    continue
                }
                guard let canonicalPrepared = try SyncEntityType
                    .canonicalizedReferencePDFMaterialization(
                        prepared,
                        db: db
                    ) else { continue }
                let pdfOutcome = try SyncEntityType
                    .applyPreparedReferencePDFPreservingUnchanged(
                        canonicalPrepared,
                        db: db
                    )
                if let prior = pdfOutcome.displacedFilename {
                    local.displacedFilenames.append(prior)
                }
                if pdfOutcome.reusedExistingFile {
                    local.displacedFilenames.append(prepared.stagedFilename)
                }
                local.appliedPDFRecordIDs.insert(record.recordID)
                try SyncEntityType.retireAliasedReferencePDFIdentity(
                    observedEntityId: entityId,
                    canonicalEntityId: canonicalPrepared.referenceSyncId,
                    stateStore: stateStore,
                    db: db
                )
                if try !stateStore.hasActiveDeleteIntent(
                    db,
                    entityType: type,
                    entityId: entityId
                ) {
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
                continue
            }

            let applied = try type.applyRemoteRecord(
                record,
                entityId: entityId,
                db: db,
                stateStore: stateStore
            )
            if applied, type.suppliesGlobalDependencies {
                globalDependenciesChanged = true
            }
            if type == .reference, applied {
                appliedReferenceSyncIDs.insert(entityId)
            } else if type == .activityEpoch, let kind = ActivityKind(rawValue: entityId) {
                changedEpochKinds.insert(kind)
            }
            if applied, try !stateStore.hasActiveDeleteIntent(
                db,
                entityType: type,
                entityId: entityId
            ) {
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
        }

        if globalDependenciesChanged {
            local.displacedFilenames += try SyncEntityType
                .repairResolvableLegacyForeignKeyOrphans(db: db)
            local.displacedFilenames += try SyncEntityType
                .replayQuarantinedRemoteRecords(
                    stateStore: stateStore,
                    db: db
                )
        }

        try SyncEntityType.replayQuarantinedActivity(
            referenceSyncIds: appliedReferenceSyncIDs,
            epochKinds: changedEpochKinds,
            db: db
        )

        for deletion in deletions {
            guard let type = SyncEntityType.forRecordType(deletion.recordType) else { continue }
            guard let parsed = SyncEntityType.parseRecordName(
                deletion.recordID.recordName
            ), parsed.0 == type else {
                log.error("skipping malformed delete recordName \(deletion.recordID.recordName, privacy: .public)")
                continue
            }
            let entityId = parsed.1
            local.deletedFilenames += try type.applyRemoteDelete(
                entityId: entityId,
                db: db
            )
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
        // opaque commit failure. Modification transactions tolerate transient
        // cross-batch orphans (they resolve when the parent arrives); deletion
        // transactions reject only violations introduced while cascades were
        // active.
        let violations = try foreignKeyViolations(db)
        switch violationPolicy {
        case .tolerateAll:
            if !violations.isEmpty {
                log.info("remote apply: \(violations.count, privacy: .public) transient FK orphans tolerated (resolve when parents arrive)")
            }

        case .tolerateExisting(let existingViolations):
            let introducedViolations = violations.subtracting(existingViolations)
            if !introducedViolations.isEmpty {
                log.error("remote apply introduced \(introducedViolations.count, privacy: .public) FK violations — rolling back")
                throw CancellationError()  // trigger rollback
            }
            if !violations.isEmpty {
                log.info("remote apply: \(violations.count, privacy: .public) pre-existing transient FK orphans preserved while deletion batch committed")
            }
        }

        try stateStore.clearApplyingRemote(db)
        return local
    }

    private static func foreignKeyViolations(
        _ db: Database
    ) throws -> Set<ForeignKeyViolation> {
        Set(
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                .map(ForeignKeyViolation.init)
        )
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
    @discardableResult
    func applyFetchedRecordsForTest(
        modifications: [CKRecord],
        deletions: [FetchedDeletionInput]
    ) async -> Bool {
        await applyFetchedRecordsInternal(
            modifications: modifications,
            deletions: deletions
        )
    }

    private func handleSentZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        let sendErrors = event.failedRecordSaves.map { $0.error }
            + event.failedRecordDeletes.map { $0.value }
        if !sendErrors.isEmpty {
            var inputs: [SyncSendFailureInput] = []
            inputs.reserveCapacity(sendErrors.count)
            for failure in event.failedRecordSaves {
                let type = SyncEntityType.forRecordType(
                    failure.record.recordType
                )?.rawValue ?? failure.record.recordType
                inputs.append(.init(error: failure.error, entityType: type))
            }
            for failure in event.failedRecordDeletes {
                let type = SyncEntityType.parseRecordName(
                    failure.key.recordName
                )?.0.rawValue ?? "unknown"
                inputs.append(.init(error: failure.value, entityType: type))
            }
            for summary in SyncSendFailureSummarizer.summarize(inputs) {
                let types = summary.entityTypes.joined(separator: ",")
                log.error(
                    "CloudKit send failure domain=\(summary.error._domain, privacy: .public) code=\(summary.error.errorCode, privacy: .public) affected=\(summary.count, privacy: .public) entityTypes=\(types, privacy: .public): \(summary.error.localizedDescription, privacy: .public)"
                )
            }
        }

        // A failed save no longer owns its in-flight marker. Release every
        // affected row before specialized recovery mutates its fields.
        let failedSaveIdentities: [(SyncEntityType, String)] = event.failedRecordSaves.compactMap {
            guard let type = SyncEntityType.forRecordType($0.record.recordType),
                  let parsed = SyncEntityType.parseRecordName(
                    $0.record.recordID.recordName
                  ), parsed.0 == type
            else { return nil }
            return parsed
        }
        if !failedSaveIdentities.isEmpty {
            do {
                try await appDatabase.dbWriter.write { [stateStore] db in
                    for (type, entityId) in failedSaveIdentities {
                        try stateStore.releasePushInFlight(
                            db,
                            entityType: type,
                            entityId: entityId
                        )
                    }
                }
            } catch {
                log.error(
                    "failed to release save attempts: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

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
                    if type == .activityEpoch,
                       let epoch = ActivityEpoch(record: saved),
                       epoch.kind.rawValue == entityId
                    {
                        // A clear is acknowledged only by the save of this
                        // exact epoch pair. A later/rebased intent remains.
                        try db.execute(
                            sql: """
                                DELETE FROM activityPendingClear
                                WHERE kind = ? AND revision = ? AND generation = ?
                                """,
                            arguments: [epoch.kind.rawValue, epoch.revision, epoch.generation]
                        )
                    }
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
        let confirmedDeletes: [(SyncEntityType, String)] = event.deletedRecordIDs.compactMap { recordID in
            guard let parsed = SyncEntityType.parseRecordName(recordID.recordName) else {
                log.error("skipping malformed deleted recordName \(recordID.recordName, privacy: .public)")
                return nil
            }
            return parsed
        }
        if !confirmedDeletes.isEmpty {
            do {
                let filenames = try await appDatabase.dbWriter.write {
                    [stateStore] db in
                    var filenames: [String] = []
                    for (type, entityId) in confirmedDeletes {
                        filenames += try Self.finalizeDeleteOutcome(
                            db,
                            stateStore: stateStore,
                            entityType: type,
                            entityId: entityId,
                            retainConfirmedTombstone: true
                        )
                    }
                    return filenames
                }
                Self.unlinkStoredPDFFilenames(filenames)
            } catch {
                log.error("finalize acknowledged deletes failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Only failures that remain unresolved after recovery become
        // user-visible. In particular, `.serverRecordChanged` is a normal
        // optimistic-lock race: when its server record is merged successfully,
        // the conflict is durably reconciled and retaining an error here would
        // leave a stale banner until some unrelated future send cycle.
        var unrecoveredSendErrors: [CKError] = []
        for failure in event.failedRecordSaves {
            guard let type = SyncEntityType.forRecordType(failure.record.recordType) else {
                unrecoveredSendErrors.append(failure.error)
                continue
            }
            guard let parsed = SyncEntityType.parseRecordName(
                failure.record.recordID.recordName
            ), parsed.0 == type else {
                log.error("skipping malformed failed-save recordName \(failure.record.recordID.recordName, privacy: .public)")
                unrecoveredSendErrors.append(failure.error)
                continue
            }
            let entityId = parsed.1

            switch failure.error.code {
            case .serverRecordChanged:
                let recovered = await handleServerRecordChanged(
                    type: type,
                    entityId: entityId,
                    error: failure.error
                )
                if !recovered {
                    unrecoveredSendErrors.append(failure.error)
                }
                deferredPendingReconciliation = true

            case .zoneNotFound:
                // Library zone was deleted (or never created for this
                // account). Recreate it — the engine retries the save
                // once we acknowledge the zone creation.
                unrecoveredSendErrors.append(failure.error)
                guard isEngineStartupPrepared,
                      syncEngine === _engine
                else { continue }
                syncEngine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: SyncConstants.libraryZoneID))
                ])
                deferredPendingReconciliation = true

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
                if let unrecoveredError = await recoverUnknownItemSaveFailure(
                    type: type,
                    entityId: entityId,
                    error: failure.error
                ) {
                    unrecoveredSendErrors.append(unrecoveredError)
                }

            case .invalidArguments:
                unrecoveredSendErrors.append(failure.error)
                deferredDurableRepair = true
                deferredPendingReconciliation = true

            default:
                unrecoveredSendErrors.append(failure.error)
                deferredPendingReconciliation = true
            }
        }

        // Failed deletes — typically .unknownItem (already gone server-
        // side). Purge the tombstone so we don't keep retrying.
        for failure in event.failedRecordDeletes {
            unrecoveredSendErrors.append(failure.value)
            if failure.value.code == .unknownItem {
                await removeUnknownItemDeleteTombstone(recordID: failure.key)
            }
            if failure.value.code == .invalidArguments {
                deferredDurableRepair = true
            }
            deferredPendingReconciliation = true
        }

        if let firstError = unrecoveredSendErrors.first {
            sendCycleError = firstError
            publishStatus(.error(firstError))
        }
    }

    /// Turn an update rejected with `.unknownItem` into a fresh create. The DB
    /// mutation is safe inside the delegate callback; the engine refresh is
    /// only recorded here and consumed by post-callback reconciliation. Return
    /// an error only when preparing that retry failed—a recovered missing-record
    /// conflict is normal sync work and must not leave a persistent banner.
    func recoverUnknownItemSaveFailure(
        type: SyncEntityType,
        entityId: String,
        error cloudError: CKError
    ) async -> CKError? {
        defer { deferredPendingReconciliation = true }
        do {
            try await appDatabase.dbWriter.write { [stateStore] db in
                try stateStore.clearSystemFields(
                    db,
                    entityType: type,
                    entityId: entityId
                )
                try stateStore.releasePushInFlight(
                    db,
                    entityType: type,
                    entityId: entityId
                )
            }
            pendingIntentRefreshes.insert(.init(
                type: type,
                entityId: entityId,
                operation: .save
            ))
            return nil
        } catch {
            log.error(
                "unknownItem recovery failed: \(error.localizedDescription, privacy: .public)"
            )
            return cloudError
        }
    }

    private func removeUnknownItemDeleteTombstone(
        recordID: CKRecord.ID
    ) async {
        guard let (type, entityId) = SyncEntityType.parseRecordName(
            recordID.recordName
        ) else {
            log.error(
                "skipping malformed failed-delete recordName \(recordID.recordName, privacy: .public)"
            )
            return
        }
        do {
            let filenames = try await appDatabase.dbWriter.write {
                [stateStore] db in
                try Self.finalizeDeleteOutcome(
                    db,
                    stateStore: stateStore,
                    entityType: type,
                    entityId: entityId,
                    retainConfirmedTombstone: false
                )
            }
            Self.unlinkStoredPDFFilenames(filenames)
        } catch {
            log.error(
                "failed to finalize unknown-item delete: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Complete a server-confirmed delete without clobbering a newer local
    /// recreation. The exact active tombstone is the ownership token for the
    /// original request; v14 insert/update triggers remove it when the user
    /// recreates the entity and queue a dirty save instead.
    private static func finalizeDeleteOutcome(
        _ db: Database,
        stateStore: SyncStateStore,
        entityType: SyncEntityType,
        entityId: String,
        retainConfirmedTombstone: Bool
    ) throws -> [String] {
        guard try stateStore.hasActiveDeleteIntent(
            db,
            entityType: entityType,
            entityId: entityId
        ) else { return [] }
        let hasNewerDirtyState = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM syncState
                WHERE entityType = ? AND entityId = ? AND isDirty = 1
            )
            """, arguments: [entityType.rawValue, entityId]) ?? true
        let hasLiveEntity = try SyncLocalEntityCatalog.contains(
            entityType: entityType.rawValue,
            entityId: entityId,
            in: db
        )
        if hasNewerDirtyState && hasLiveEntity {
            // The delete request was superseded while in flight. Its server
            // success means the recreation must now be sent as a create.
            try stateStore.queueSave(
                db,
                entityType: entityType,
                entityId: entityId
            )
            return []
        }

        try stateStore.setApplyingRemote(db)
        let filenames = try entityType.applyRemoteDelete(
            entityId: entityId,
            db: db
        )
        try stateStore.removeState(
            db,
            entityType: entityType,
            entityId: entityId
        )
        if retainConfirmedTombstone {
            try stateStore.markTombstoneConfirmed(
                db,
                entityType: entityType,
                entityId: entityId
            )
        } else {
            try stateStore.removeTombstone(
                db,
                entityType: entityType,
                entityId: entityId
            )
        }
        try stateStore.clearApplyingRemote(db)
        return filenames
    }

    func finalizeDeleteOutcomeForTest(
        entityType: SyncEntityType,
        entityId: String,
        retainConfirmedTombstone: Bool
    ) async throws {
        let filenames = try await appDatabase.dbWriter.write { [stateStore] db in
            try Self.finalizeDeleteOutcome(
                db,
                stateStore: stateStore,
                entityType: entityType,
                entityId: entityId,
                retainConfirmedTombstone: retainConfirmedTombstone
            )
        }
        Self.unlinkStoredPDFFilenames(filenames)
    }

    func removeUnknownItemDeleteTombstoneForTest(
        recordID: CKRecord.ID
    ) async {
        await removeUnknownItemDeleteTombstone(recordID: recordID)
    }

    /// Conflict resolution on `.serverRecordChanged`. CloudKit returns the
    /// server's current version in the error payload; we apply it and store
    /// its system fields as the new clean baseline. An exact active local
    /// delete still wins and suppresses the stale server version entirely.
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
    ) async -> Bool {
        guard let serverRecord = error.serverRecord else {
            log.error("serverRecordChanged without serverRecord — awaiting next external fetch")
            return false
        }
        return await mergeServerRecordChanged(
            type: type,
            entityId: entityId,
            serverRecord: serverRecord
        )
    }

    private func mergeServerRecordChanged(
        type: SyncEntityType,
        entityId: String,
        serverRecord: CKRecord
    ) async -> Bool {

        // referencePDF: pre-stage bytes outside the transaction so the writer
        // queue isn't held by a large copyItem during conflict resolution.
        // `prepare` returns nil for malformed names; we drop the merge then.
        let preparedPDF: SyncEntityType.PreparedReferencePDFMaterialization?
        if type == .referencePDF {
            do {
                preparedPDF = try SyncEntityType.prepareReferencePDFMaterialization(record: serverRecord)
            } catch {
                log.error("serverRecordChanged prepare failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
            guard preparedPDF != nil else { return false }
        } else {
            preparedPDF = nil
        }

        var mergeOutcome: ServerRecordChangedMergeOutcome?

        do {
            mergeOutcome = try await appDatabase.dbWriter.write {
                [stateStore] db -> ServerRecordChangedMergeOutcome in
                if try stateStore.activeDeleteSuppressesRemoteRecord(
                    db,
                    entityType: type,
                    entityId: entityId
                ) {
                    // The save was superseded by a local delete while in
                    // flight. Do not apply or quarantine the stale server
                    // version; its exact tombstone remains the durable intent.
                    return ServerRecordChangedMergeOutcome(conflictResolved: true)
                }
                try stateStore.setApplyingRemote(db)
                var outcome = ServerRecordChangedMergeOutcome()
                let dependencyStatus = try type.remoteDependencyStatus(
                    for: serverRecord,
                    entityId: entityId,
                    db: db
                )
                if dependencyStatus != .ready {
                    let displaced = try SyncEntityType.quarantineRemoteRecord(
                        serverRecord,
                        stagedFilename: preparedPDF?.stagedFilename,
                        db: db
                    )
                    try stateStore.clearApplyingRemote(db)
                    if let displaced {
                        outcome.displacedFilenames.append(displaced)
                    }
                    outcome.stagedPDFConsumed = preparedPDF != nil
                    return outcome
                }
                let applied: Bool
                if type == .referencePDF, let prepared = preparedPDF {
                    guard let canonicalPrepared = try SyncEntityType
                        .canonicalizedReferencePDFMaterialization(
                            prepared,
                            db: db
                        ) else {
                        try stateStore.clearApplyingRemote(db)
                        return outcome
                    }
                    if let displaced = try SyncEntityType.applyPreparedReferencePDF(
                        canonicalPrepared,
                        db: db
                    ) {
                        outcome.displacedFilenames.append(displaced)
                    }
                    outcome.stagedPDFConsumed = true
                    try SyncEntityType.retireAliasedReferencePDFIdentity(
                        observedEntityId: entityId,
                        canonicalEntityId: canonicalPrepared.referenceSyncId,
                        stateStore: stateStore,
                        db: db
                    )
                    applied = true
                } else {
                    applied = try type.applyRemoteRecord(
                        serverRecord,
                        entityId: entityId,
                        db: db,
                        stateStore: stateStore
                    )
                }
                if applied, try !stateStore.hasActiveDeleteIntent(
                    db,
                    entityType: type,
                    entityId: entityId
                ) {
                    try stateStore.removeTombstone(
                        db,
                        entityType: type,
                        entityId: entityId
                    )
                    try stateStore.markPulled(
                        db,
                        entityType: type,
                        entityId: entityId,
                        record: serverRecord
                    )
                    outcome.conflictResolved = true
                }
                if type == .activityEpoch, let kind = ActivityKind(rawValue: entityId) {
                    try SyncEntityType.replayQuarantinedActivity(
                        epochKinds: Set([kind]),
                        db: db
                    )
                }
                if applied, type.suppliesGlobalDependencies {
                    outcome.displacedFilenames += try SyncEntityType
                        .repairResolvableLegacyForeignKeyOrphans(db: db)
                    outcome.displacedFilenames += try SyncEntityType
                        .replayQuarantinedRemoteRecords(
                            stateStore: stateStore,
                            db: db
                        )
                }
                try stateStore.clearApplyingRemote(db)
                return outcome
            }
        } catch {
            log.error("serverRecordChanged merge failed: \(error.localizedDescription, privacy: .public)")
        }

        // Post-commit file I/O (off the writer queue). A staged file consumed
        // by `pdfCache` or `syncOrphan` is retained. A skipped, invalid, or
        // failed merge never promotes it, so it is safe to unlink here.
        if preparedPDF != nil, mergeOutcome?.stagedPDFConsumed != true,
           let staged = preparedPDF?.stagedURL
        {
            try? FileManager.default.removeItem(at: staged)
        }
        if let mergeOutcome {
            Self.unlinkStoredPDFFilenames(mergeOutcome.displacedFilenames)
        }
        return mergeOutcome?.conflictResolved == true
    }

    private static func unlinkStoredPDFFilenames(_ filenames: [String]) {
        for filename in filenames {
            let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func mergeServerRecordChangedForTest(
        type: SyncEntityType,
        entityId: String,
        serverRecord: CKRecord
    ) async -> Bool {
        await mergeServerRecordChanged(
            type: type,
            entityId: entityId,
            serverRecord: serverRecord
        )
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
