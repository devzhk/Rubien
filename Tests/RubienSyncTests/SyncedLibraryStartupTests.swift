#if os(macOS)
import XCTest
import CloudKit
import GRDB
@testable import RubienCore
@testable import RubienSync

/// Exercises `SyncedLibrary.start()` side effects that don't require a
/// real CKContainer: the baseline one-shot and tombstone compaction. The
/// engine itself isn't contacted in these tests — we read the resulting
/// `syncState` / `syncSession` / `tombstone` rows to verify behavior.
@available(macOS 14.0, iOS 17.0, *)
final class SyncedLibraryStartupTests: XCTestCase {

    private var db: AppDatabase!
    private var stateFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-test-engine-\(UUID().uuidString).bin")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateFile)
        db = nil
        super.tearDown()
    }

    // MARK: - Engine startup safety

    func testUnknownMarkerStateForcesFullReplayEvenWithDurableSidecar() {
        XCTAssertTrue(
            SyncedLibrary.requiresFullHistoryReplay(
                durableStateAvailable: true,
                persistedMarker: nil
            )
        )
        XCTAssertFalse(
            SyncedLibrary.requiresFullHistoryReplay(
                durableStateAvailable: true,
                persistedMarker: false
            )
        )
    }

    func testStartupPreparationPersistsMarkerAndRemovesAmbiguousSidecar() async throws {
        try Data("ambiguous-bootstrap-state".utf8).write(to: stateFile)
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )

        let prepared = await library.prepareForStart()
        let startupPrepared = await library.isEngineStartupPreparedForTest
        let hasEngine = await library.hasEngineForTest

        XCTAssertTrue(prepared)
        XCTAssertTrue(startupPrepared)
        XCTAssertFalse(hasEngine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
        let markerCount = try await db.dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM syncSession
                    WHERE key = 'fullHistoryReplayPending'
                    """
            ) ?? -1
        }
        XCTAssertEqual(markerCount, 1)
    }

    func testEngineForcingCallbackBeforePreparationDoesNotConstructEngine() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        try await db.dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE syncState SET isDirty = 1
                    WHERE entityType = 'propertyDefinition'
                    """
            )
        }

        await library.ingestPendingChanges()
        let startupPrepared = await library.isEngineStartupPreparedForTest
        let hasEngine = await library.hasEngineForTest

        XCTAssertFalse(startupPrepared)
        XCTAssertFalse(hasEngine)
    }

    func testObserverIngestAfterSidecarPreparationWaitsForDurableRepair() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                UPDATE syncState SET isDirty = 1
                WHERE entityType = 'propertyDefinition'
                """)
        }

        let prepared = await library.prepareForStart()
        XCTAssertTrue(prepared)
        await library.ingestPendingChanges()

        let intentReady = await library.isDurableIntentReadyForEngineForTest
        let hasEngine = await library.hasEngineForTest
        XCTAssertFalse(intentReady)
        XCTAssertFalse(
            hasEngine,
            "post-commit ingestion must not construct CKSyncEngine before durable-intent repair"
        )
    }

    func testObserverIngestWaitsForFinalStartupDatabaseStep() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        let prepared = await library.prepareForStart()
        XCTAssertTrue(prepared)
        await library.beginFinalStartupDatabaseStepForTest()

        await library.ingestPendingChanges()

        let hasEngine = await library.hasEngineForTest
        XCTAssertFalse(
            hasEngine,
            "readiness must not permit engine construction before final startup DB work"
        )
        await library.endFinalStartupDatabaseStepForTest()
    }

    func testReentrantStartFailsClosedDuringFinalStartupDatabaseStep() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        await library.beginFinalStartupDatabaseStepForTest()

        let started = await library.start()
        let hasEngine = await library.hasEngineForTest

        XCTAssertFalse(started)
        XCTAssertFalse(hasEngine)
        await library.endFinalStartupDatabaseStepForTest()
    }

    func testStartupPreparationFailureDoesNotConstructEngine() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        try await db.dbWriter.write { db in
            try db.execute(sql: "DROP TABLE syncSession")
        }

        let prepared = await library.prepareForStart()
        XCTAssertFalse(prepared)
        await library.start()
        let hasEngine = await library.hasEngineForTest
        XCTAssertFalse(hasEngine)
    }

    func testDurableRepairFailureDoesNotConstructEngine() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        let prepared = await library.prepareForStart()
        XCTAssertTrue(prepared)
        try await db.dbWriter.write { db in
            try db.execute(sql: "DROP TABLE syncState")
        }

        let started = await library.start()
        let intentReady = await library.isDurableIntentReadyForEngineForTest
        let hasEngine = await library.hasEngineForTest
        XCTAssertFalse(started)
        XCTAssertFalse(intentReady)
        XCTAssertFalse(hasEngine)
    }

    func testFailedAccountSidecarResetBlocksStartupUntilRetrySucceeds() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rubien-account-reset-\(UUID().uuidString)",
                isDirectory: true
            )
        let protectedStateFile = parent.appendingPathComponent("state.bin")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try Data("old-account-state".utf8).write(to: protectedStateFile)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parent.path
            )
            try? FileManager.default.removeItem(at: parent)
        }

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: protectedStateFile
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: parent.path
        )

        let reset = await library.resetForAccountChange()
        let pendingAfterFailure = await library.accountResetPendingForTest
        let replayPendingAfterFailure =
            await library.fullHistoryReplayPendingForTest
        let firstPreparation = await library.prepareForStart()
        let hasEngineAfterFailure = await library.hasEngineForTest
        XCTAssertFalse(reset)
        XCTAssertTrue(pendingAfterFailure)
        XCTAssertTrue(replayPendingAfterFailure)
        XCTAssertFalse(firstPreparation)
        XCTAssertFalse(hasEngineAfterFailure)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        let retriedPreparation = await library.prepareForStart()
        let pendingAfterRetry = await library.accountResetPendingForTest
        XCTAssertTrue(retriedPreparation)
        XCTAssertFalse(pendingAfterRetry)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: protectedStateFile.path)
        )
    }

    func testAccountResetClearsPendingIntentRefreshes() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        let unknownItem = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.unknownItem.rawValue
        ))
        let visibleError = await library.recoverUnknownItemSaveFailure(
            type: .tag,
            entityId: "old-account-record",
            error: unknownItem
        )
        XCTAssertNil(visibleError)
        let refreshesBeforeReset = await library.pendingIntentRefreshesForTest
        XCTAssertFalse(refreshesBeforeReset.isEmpty)

        let reset = await library.resetForAccountChange()
        XCTAssertTrue(reset)

        let refreshesAfterReset = await library.pendingIntentRefreshesForTest
        XCTAssertTrue(refreshesAfterReset.isEmpty)
    }

    // MARK: - Baseline one-shot

    func testBaselineMarksAllSeedRowsDirtyOnFirstRun() async throws {
        // Migration already seeds 28 property definitions and 1 default
        // databaseView. After baseline, every one of those should be
        // dirty.
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )

        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")  // clear migration-time trigger noise
            try db.execute(sql: "DELETE FROM syncSession")
        }

        await library.performInitialBaselineIfNeeded()

        let (propertyCount, viewCount, sessionValue) = try await db.dbWriter.read { db in
            let props = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState WHERE entityType='propertyDefinition' AND isDirty=1
                """) ?? 0
            let views = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState WHERE entityType='databaseView' AND isDirty=1
                """) ?? 0
            let state = try String.fetchOne(db, sql: """
                SELECT value FROM syncSession WHERE key='baselineState'
                """)
            return (props, views, state)
        }

        XCTAssertEqual(propertyCount, 30, "all 30 seeded property definitions (v1: 28 + v5: 2) must be marked dirty")
        XCTAssertEqual(viewCount, 1, "seeded default view must be marked dirty")
        XCTAssertEqual(sessionValue, "complete", "baselineState must be gated after first run")
    }

    func testBaselineReplacesLiveConfirmedTombstoneWithSaveIntent() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: "DELETE FROM syncSession")
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES('baseline-live', 'Baseline live', '#fff', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                DELETE FROM syncState
                WHERE entityType='tag' AND entityId='baseline-live'
                """)
            try SyncStateStore().upsertTombstone(
                db,
                entityType: .tag,
                entityId: "baseline-live",
                confirmedByServer: true
            )
        }

        await library.performInitialBaselineIfNeeded()

        try await db.dbWriter.read { db in
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId='baseline-live'
                """))
            let state = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT isDirty, pushInFlight FROM syncState
                WHERE entityType='tag' AND entityId='baseline-live'
                """))
            XCTAssertEqual(state["isDirty"] as Int?, 1)
            XCTAssertEqual(state["pushInFlight"] as Int?, 0)
        }
    }

    func testBaselineIsOneShot() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )

        await library.performInitialBaselineIfNeeded()

        // Second invocation must be a no-op (no new syncState rows, no
        // INSERT attempts on already-dirty rows). We prove it by manually
        // clearing dirty and re-running — if it weren't gated, baseline
        // would re-dirty everything.
        try await db.dbWriter.write { db in
            try db.execute(sql: "UPDATE syncState SET isDirty = 0")
        }

        await library.performInitialBaselineIfNeeded()

        let stillClean = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE isDirty=1") ?? -1
        }
        XCTAssertEqual(
            stillClean,
            0,
            "second baseline must not re-mark rows — baselineState guard protects against re-runs"
        )
    }

    func testBaselineUsesGlobalAndDerivedIdentities() async throws {
        var reference = Reference(syncId: "reference-global", title: "Paper")
        var tag = Tag(syncId: "tag-global", name: "Topic")
        try db.saveReference(&reference)
        try db.saveTag(&tag)
        let referenceId = try XCTUnwrap(reference.id)
        let tagId = try XCTUnwrap(tag.id)
        let referenceSyncId = reference.syncId
        let tagSyncId = tag.syncId
        try db.setTags(forReference: referenceId, tagIds: [tagId])
        let context = try db.activityCaptureContext(for: .reading)
        let localDay = try XCTUnwrap(LocalDay(rawValue: "2026-08-14"))
        let activity = try db.saveReadingActivityCounter(
            installationId: "baseline-mac",
            referenceId: referenceId,
            localDay: localDay,
            cumulativeActiveSeconds: 10,
            lastActiveAt: Date(),
            context: context
        )
        guard case .saved(let savedActivity) = activity else {
            return XCTFail("expected reading activity to save")
        }
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash,
                    assetVersion, materializedAt, lastOpenedAt
                ) VALUES (?, 'baseline.pdf', 'hash', 1, ?, ?)
                """, arguments: [referenceId, Date(), Date()])
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: "DELETE FROM syncSession")
        }
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )

        await library.performInitialBaselineIfNeeded()

        let pivotIdentity = "\(referenceSyncId)/\(tagSyncId)"
        try await db.dbWriter.read { db in
            for (type, identity) in [
                ("reference", referenceSyncId),
                ("tag", tagSyncId),
                ("referenceTag", pivotIdentity),
                ("readingActivity", savedActivity.syncId),
                ("referencePDF", referenceSyncId),
            ] {
                XCTAssertEqual(try Int.fetchOne(db, sql: """
                    SELECT isDirty FROM syncState
                    WHERE entityType = ? AND entityId = ?
                    """, arguments: [type, identity]), 1)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE (entityType = 'reference' AND entityId = ?)
                   OR (entityType = 'tag' AND entityId = ?)
                   OR (entityType = 'referencePDF' AND entityId = ?)
                """, arguments: [
                    String(referenceId), String(tagId), String(referenceId),
                ]), 0)
        }
    }

    // MARK: - Tombstone compaction

    func testCompactStaleTombstonesDropsOldConfirmedRows() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        let store = SyncStateStore()

        try await db.dbWriter.write { db in
            try store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "ancient-confirmed",
                deletedAt: Date(timeIntervalSince1970: 1_000_000),
                confirmedByServer: true
            )
            try store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "ancient-unconfirmed",
                deletedAt: Date(timeIntervalSince1970: 1_000_000),
                confirmedByServer: false
            )
            try store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "fresh-confirmed",
                deletedAt: Date(),
                confirmedByServer: true
            )
        }

        await library.compactStaleTombstones()

        let surviving = try await db.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT entityId FROM tombstone ORDER BY entityId")
        }
        XCTAssertEqual(
            surviving,
            ["ancient-unconfirmed", "fresh-confirmed"],
            "compaction evicts only server-confirmed deletes past the 30-day window"
        )
    }
}

#endif
