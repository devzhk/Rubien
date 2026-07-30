#if os(macOS)
import XCTest
@testable import RubienSync

final class FetchStatePersistenceGateTests: XCTestCase {

    func testStateOutsideFetchPersistsImmediately() {
        var gate = FetchStatePersistenceGate<Int>()
        XCTAssertEqual(gate.receiveStateUpdate(1), 1)
    }

    func testSuccessfulFetchPersistsOnlyNewestStagedStateAtEnd() {
        var gate = FetchStatePersistenceGate<Int>(
            fullHistoryReplayPending: true
        )

        gate.beginFetch()
        XCTAssertTrue(gate.canFinalizeFetchedZone)
        XCTAssertTrue(gate.shouldReconcileTerminalOrphans)
        XCTAssertNil(gate.receiveStateUpdate(1))
        XCTAssertNil(gate.receiveStateUpdate(2))

        XCTAssertEqual(gate.finishFetch(), 2)
        XCTAssertFalse(gate.canFinalizeFetchedZone)
        gate.markFullHistoryReplayCompleted()
        XCTAssertFalse(gate.fullHistoryReplayPending)
        XCTAssertFalse(gate.requiresEngineRecovery)
        XCTAssertEqual(gate.receiveStateUpdate(3), 3)
    }

    func testFailedFetchDiscardsAdvancedStateUntilEngineRecovery() {
        var gate = FetchStatePersistenceGate<Int>()

        gate.beginFetch()
        XCTAssertTrue(gate.canFinalizeFetchedZone)
        XCTAssertNil(gate.receiveStateUpdate(1))
        gate.markFetchedChangesApplyFailed()
        XCTAssertFalse(gate.canFinalizeFetchedZone)
        XCTAssertNil(gate.receiveStateUpdate(2))
        XCTAssertNil(gate.finishFetch())
        XCTAssertTrue(gate.requiresEngineRecovery)

        // A late state event from the advanced engine must stay blocked.
        XCTAssertNil(gate.receiveStateUpdate(3))

        gate.resetAfterEngineRecovery()
        XCTAssertFalse(gate.requiresEngineRecovery)
        XCTAssertEqual(gate.receiveStateUpdate(4), 4)
    }

    func testIncrementalFetchNeverAuthorizesTerminalOrphanCleanup() {
        var gate = FetchStatePersistenceGate<Int>(
            fullHistoryReplayPending: false
        )

        gate.beginFetch()

        XCTAssertTrue(gate.canFinalizeFetchedZone)
        XCTAssertFalse(gate.shouldReconcileTerminalOrphans)
    }

    func testDurableStateResetAuthorizesNextFullReplayCleanup() {
        var gate = FetchStatePersistenceGate<Int>(
            fullHistoryReplayPending: false
        )

        gate.beginFetch()
        XCTAssertNil(gate.receiveStateUpdate(1))
        gate.markFetchedChangesApplyFailed()
        gate.markDurableStateReset()

        XCTAssertFalse(gate.isFetchInProgress)
        XCTAssertFalse(gate.requiresEngineRecovery)
        gate.beginFetch()

        XCTAssertTrue(gate.shouldReconcileTerminalOrphans)
        XCTAssertNil(gate.finishFetch())
    }
}
#endif
