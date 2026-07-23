#if os(macOS)
import XCTest
@testable import Rubien

final class CodexWorkSchedulerTests: XCTestCase {
    func testIndependentInteractiveTurnsAreAdmittedConcurrently() {
        var scheduler = CodexWorkScheduler()
        let first = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let second = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))

        XCTAssertEqual(scheduler.requestTurn(first), .admitted)
        XCTAssertEqual(scheduler.requestTurn(second), .admitted)
    }

    func testTurnPreemptsMetadataAndScheduledQueueIsFIFO() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 1)
        let metadata = work(.metadata(kind: .history, requestID: UUID()))
        let first = work(.scheduled(runID: "one", conversationID: nil, turnID: UUID()))
        let second = work(.scheduled(runID: "two", conversationID: nil, turnID: UUID()))

        XCTAssertEqual(scheduler.beginMetadata(metadata), .admitted)
        XCTAssertEqual(scheduler.requestTurn(first), .preemptMetadataAndAdmit)
        XCTAssertEqual(scheduler.requestTurn(second), .queued)
        XCTAssertEqual(scheduler.finishTurn(workID: first.workID), [second])
    }

    func testCapacityQueuesAndReservesTheNextTurn() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 2)
        let first = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let second = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let third = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))

        XCTAssertEqual(scheduler.requestTurn(first), .admitted)
        XCTAssertEqual(scheduler.requestTurn(second), .admitted)
        XCTAssertEqual(scheduler.requestTurn(third), .queued)
        XCTAssertEqual(scheduler.finishTurn(workID: first.workID), [third])
        XCTAssertEqual(scheduler.requestTurn(third), .admitted)
    }

    func testIncompatibleRuntimeProfileWaitsForTheWholeActiveBatch() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 4)
        let interactive = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let secondInteractive = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let readOnlyProfile = CodexRuntimeProfile(
            webAccess: false,
            loadUserTools: false,
            readOnlyLibrary: true
        )
        let scheduled = CodexScheduledWork(
            workID: UUID(),
            purpose: .scheduled(
                runID: "scheduled",
                conversationID: nil,
                turnID: UUID()
            ),
            runtimeProfile: readOnlyProfile
        )

        XCTAssertEqual(scheduler.requestTurn(interactive), .admitted)
        XCTAssertEqual(scheduler.requestTurn(secondInteractive), .admitted)
        XCTAssertEqual(scheduler.requestTurn(scheduled), .queued)
        XCTAssertEqual(scheduler.finishTurn(workID: interactive.workID), [])
        XCTAssertEqual(
            scheduler.finishTurn(workID: secondInteractive.workID),
            [scheduled]
        )
    }

    func testDifferentConfigurationWorkspacesDoNotShareAProcessBatch() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 4)
        let first = CodexScheduledWork(
            workID: UUID(),
            purpose: .interactive(
                ownerID: UUID(),
                conversationID: UUID(),
                turnID: UUID()
            ),
            runtimeProfile: CodexRuntimeProfile(
                webAccess: true,
                loadUserTools: false,
                readOnlyLibrary: false,
                workingDirectory: "/tmp/first"
            )
        )
        let second = CodexScheduledWork(
            workID: UUID(),
            purpose: .interactive(
                ownerID: UUID(),
                conversationID: UUID(),
                turnID: UUID()
            ),
            runtimeProfile: CodexRuntimeProfile(
                webAccess: true,
                loadUserTools: false,
                readOnlyLibrary: false,
                workingDirectory: "/tmp/second"
            )
        )

        XCTAssertEqual(scheduler.requestTurn(first), .admitted)
        XCTAssertEqual(scheduler.requestTurn(second), .queued)
        XCTAssertEqual(scheduler.finishTurn(workID: first.workID), [second])
    }

    func testCancellingQueuedHeadPreservesTheNextFIFOEntry() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 1)
        let active = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let cancelled = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let next = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))

        XCTAssertEqual(scheduler.requestTurn(active), .admitted)
        XCTAssertEqual(scheduler.requestTurn(cancelled), .queued)
        XCTAssertEqual(scheduler.requestTurn(next), .queued)
        let cancellation = scheduler.cancel(workID: cancelled.workID)
        XCTAssertTrue(cancellation.didCancel)
        XCTAssertTrue(cancellation.newlyReserved.isEmpty)
        XCTAssertEqual(scheduler.finishTurn(workID: active.workID), [next])
    }

    func testCancellingReservationImmediatelyFillsItsSlot() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 1)
        let active = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let reserved = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let next = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))

        XCTAssertEqual(scheduler.requestTurn(active), .admitted)
        XCTAssertEqual(scheduler.requestTurn(reserved), .queued)
        XCTAssertEqual(scheduler.requestTurn(next), .queued)
        XCTAssertEqual(scheduler.finishTurn(workID: active.workID), [reserved])
        let cancellation = scheduler.cancel(workID: reserved.workID)
        XCTAssertTrue(cancellation.didCancel)
        XCTAssertEqual(cancellation.newlyReserved, [next])
        XCTAssertEqual(scheduler.requestTurn(next), .admitted)
    }

    func testCancellingIncompatibleHeadAdmitsWaitingActiveProfile() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 2)
        let active = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let incompatible = CodexScheduledWork(
            workID: UUID(),
            purpose: .scheduled(
                runID: "read-only",
                conversationID: nil,
                turnID: UUID()
            ),
            runtimeProfile: CodexRuntimeProfile(
                webAccess: true,
                loadUserTools: false,
                readOnlyLibrary: true
            )
        )
        let compatible = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))

        XCTAssertEqual(scheduler.requestTurn(active), .admitted)
        XCTAssertEqual(scheduler.requestTurn(incompatible), .queued)
        XCTAssertEqual(scheduler.requestTurn(compatible), .queued)
        let cancellation = scheduler.cancel(workID: incompatible.workID)
        XCTAssertTrue(cancellation.didCancel)
        XCTAssertEqual(cancellation.newlyReserved, [compatible])
    }

    func testNewMetadataSupersedesOlderLeaseWithoutOldFinishClearingIt() {
        var scheduler = CodexWorkScheduler()
        let first = work(.metadata(kind: .availability, requestID: UUID()))
        let second = work(.metadata(kind: .history, requestID: UUID()))

        XCTAssertEqual(scheduler.beginMetadata(first), .admitted)
        XCTAssertEqual(scheduler.beginMetadata(second), .admitted)
        XCTAssertEqual(scheduler.metadata, second)
        scheduler.finishMetadata(workID: first.workID)
        XCTAssertEqual(scheduler.metadata, second)
    }

    private func work(_ purpose: CodexWorkPurpose) -> CodexScheduledWork {
        CodexScheduledWork(workID: UUID(), purpose: purpose)
    }
}
#endif
