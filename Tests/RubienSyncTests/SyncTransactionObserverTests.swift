#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

/// Regression tests for the observer-retention bug: GRDB's
/// `.observerLifetime` extent holds only a **weak** reference, so if
/// `SyncedLibrary` doesn't retain the observer strongly, it deallocates
/// immediately after `installTransactionObserver` returns. Commits then
/// silently stop reaching the engine and only the startup-reconciliation
/// pass ever syncs.
@available(macOS 14.0, iOS 17.0, *)
final class SyncTransactionObserverRetentionTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testInstallRetainsObserverBeyondTheInstallCall() async throws {
        let library = SyncedLibrary(appDatabase: db)

        let hadObserverBeforeInstall = await library.hasTransactionObserver
        XCTAssertFalse(hadObserverBeforeInstall, "precondition: no observer before install")

        await library.installTransactionObserver()

        let hasObserverAfterInstall = await library.hasTransactionObserver
        XCTAssertTrue(
            hasObserverAfterInstall,
            "SyncedLibrary must hold a strong reference to the observer; GRDB's `.observerLifetime` extent is weak, so a local-var-only install would deallocate immediately and commits would never reach the engine"
        )
    }

    func testRemoveDropsTheObserver() async throws {
        let library = SyncedLibrary(appDatabase: db)
        await library.installTransactionObserver()
        await library.removeTransactionObserver()

        let stillThere = await library.hasTransactionObserver
        XCTAssertFalse(
            stillThere,
            "sync-off must release the observer so subsequent commits stop forwarding to the engine"
        )
    }

    func testRemoveWithoutInstallIsNoOp() async throws {
        let library = SyncedLibrary(appDatabase: db)
        // Defensive: lifecycle code may pair install/remove under error
        // paths where install never happened. Must not throw or crash.
        await library.removeTransactionObserver()
        let hasObserver = await library.hasTransactionObserver
        XCTAssertFalse(hasObserver)
    }

    func testCommitBurstCoalescesToOneAddOnlyIngestionPass() async throws {
        let library = SyncedLibrary(appDatabase: db)

        for _ in 0 ..< 8 {
            await library.schedulePendingChangeIngest()
        }
        try await Task.sleep(for: .milliseconds(250))

        let runCount = await library.scheduledIngestRunsForTest
        XCTAssertEqual(runCount, 1)
    }

    func testCommitDuringAnyDelegateCallbackDefersEngineMutation() async throws {
        let library = SyncedLibrary(appDatabase: db)

        await library.beginDelegateCallbackForTest()
        await library.schedulePendingChangeIngest()

        let activeCount = await library.activeDelegateCallbackCountForTest
        let mutationWasDeferred = await library
            .deferEngineMutationIfDelegateCallbackActive()
        let isDeferred = await library.hasDeferredPendingReconciliationForTest
        let runCount = await library.scheduledIngestRunsForTest
        XCTAssertEqual(activeCount, 1)
        XCTAssertTrue(mutationWasDeferred)
        XCTAssertTrue(isDeferred)
        XCTAssertEqual(runCount, 0)

        await library.endDelegateCallbackForTest()
        let activeAfterReturn = await library.activeDelegateCallbackCountForTest
        XCTAssertEqual(activeAfterReturn, 0)
    }

    func testBatchCallbackDefersUntilTerminalSendBoundary() async throws {
        let library = SyncedLibrary(appDatabase: db)

        await library.beginSendBatchCallbackForTest()
        let mutationWasDeferred = await library
            .deferEngineMutationIfDelegateCallbackActive()
        await library.endSendBatchCallbackForTest()

        XCTAssertTrue(mutationWasDeferred)
        let awaitingBoundary = await library
            .isReconciliationAwaitingSendBoundaryForTest
        let deferredBeforeBoundary = await library
            .hasDeferredPendingReconciliationForTest
        XCTAssertTrue(awaitingBoundary)
        XCTAssertFalse(deferredBeforeBoundary)

        await library.reachSendBoundaryForTest()
        let awaitingAfterBoundary = await library
            .isReconciliationAwaitingSendBoundaryForTest
        let deferredAfterBoundary = await library
            .hasDeferredPendingReconciliationForTest
        XCTAssertFalse(awaitingAfterBoundary)
        XCTAssertTrue(deferredAfterBoundary)
    }

    func testBatchCallbackCanDeferUntilExternalIdleWithoutTerminalEvent() async throws {
        let library = SyncedLibrary(appDatabase: db)

        await library.beginSendBatchCallbackForTest()
        _ = await library.deferEngineMutationIfDelegateCallbackActive()
        await library.endSendBatchCallbackForTest()

        // Model a resolver that returned nil, so no sent/did-send event arrives.
        await library.reachExternalIdleBoundaryForTest()
        let awaitingBoundary = await library
            .isReconciliationAwaitingSendBoundaryForTest
        let isDeferred = await library
            .hasDeferredPendingReconciliationForTest
        XCTAssertFalse(awaitingBoundary)
        XCTAssertTrue(isDeferred)
    }

    func testStaleDebounceTaskCannotClearOrRunReplacement() async throws {
        let library = SyncedLibrary(appDatabase: db)

        await library.schedulePendingChangeIngest()
        let firstGeneration = await library.pendingIngestGenerationForTest
        await library.schedulePendingChangeIngest()
        let secondGeneration = await library.pendingIngestGenerationForTest
        XCTAssertNotEqual(firstGeneration, secondGeneration)

        await library.runScheduledPendingChangeIngestForTest(
            generation: firstGeneration
        )
        let hasReplacementTask = await library.hasPendingIngestTaskForTest
        let runCountBeforeRemoval = await library.scheduledIngestRunsForTest
        XCTAssertTrue(hasReplacementTask)
        XCTAssertEqual(runCountBeforeRemoval, 0)

        await library.removeTransactionObserver()
        await library.runScheduledPendingChangeIngestForTest(
            generation: secondGeneration
        )
        let hasTaskAfterRemoval = await library.hasPendingIngestTaskForTest
        let runCountAfterRemoval = await library.scheduledIngestRunsForTest
        XCTAssertFalse(hasTaskAfterRemoval)
        XCTAssertEqual(runCountAfterRemoval, 0)
    }
}
#endif
