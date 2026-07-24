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
        XCTAssertEqual(scheduler.requestTurn(second), .queued(.capacity))
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
        XCTAssertEqual(scheduler.requestTurn(third), .queued(.capacity))
        XCTAssertEqual(scheduler.finishTurn(workID: first.workID), [third])
        XCTAssertEqual(scheduler.requestTurn(third), .admitted)
    }

    func testDifferentWebProfileWaitsForTheWholeActiveBatch() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 4)
        let interactive = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let secondInteractive = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let webOffProfile = CodexRuntimeProfile(
            webAccess: false
        )
        let scheduled = CodexScheduledWork(
            workID: UUID(),
            purpose: .scheduled(
                runID: "scheduled",
                conversationID: nil,
                turnID: UUID()
            ),
            runtimeProfile: webOffProfile
        )

        XCTAssertEqual(scheduler.requestTurn(interactive), .admitted)
        XCTAssertEqual(scheduler.requestTurn(secondInteractive), .admitted)
        XCTAssertEqual(
            scheduler.requestTurn(scheduled),
            .queued(.runtimeProfile(.webAccess))
        )
        XCTAssertEqual(scheduler.finishTurn(workID: interactive.workID), [])
        XCTAssertEqual(
            scheduler.finishTurn(workID: secondInteractive.workID),
            [scheduled]
        )
    }

    func testFullBatchReclassifiesFromCapacityToProfileWhenASlotOpens() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 2)
        let first = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let second = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let webOff = CodexScheduledWork(
            workID: UUID(),
            purpose: .scheduled(
                runID: "web-off",
                conversationID: nil,
                turnID: UUID()
            ),
            runtimeProfile: CodexRuntimeProfile(webAccess: false)
        )

        XCTAssertEqual(scheduler.requestTurn(first), .admitted)
        XCTAssertEqual(scheduler.requestTurn(second), .admitted)
        XCTAssertEqual(scheduler.requestTurn(webOff), .queued(.capacity))
        XCTAssertEqual(scheduler.queuedReasons[webOff.workID], .capacity)

        XCTAssertEqual(scheduler.finishTurn(workID: first.workID), [])
        XCTAssertEqual(
            scheduler.queuedReasons[webOff.workID],
            .runtimeProfile(.webAccess)
        )
        XCTAssertEqual(scheduler.finishTurn(workID: second.workID), [webOff])
    }

    func testDifferentThreadWorkspacesShareAProcessBatch() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 4)
        let first = CodexScheduledWork(
            workID: UUID(),
            purpose: .interactive(
                ownerID: UUID(),
                conversationID: UUID(),
                turnID: UUID()
            ),
            runtimeProfile: CodexRuntimeProfile(
                webAccess: true
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
                webAccess: true
            )
        )

        XCTAssertEqual(scheduler.requestTurn(first), .admitted)
        XCTAssertEqual(scheduler.requestTurn(second), .admitted)
    }

    func testPluginEnabledDifferentWorkspacesDoNotShareAProcessBatch() {
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
                pluginWorkingDirectory: "/first"
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
                pluginWorkingDirectory: "/second"
            )
        )

        XCTAssertEqual(scheduler.requestTurn(first), .admitted)
        XCTAssertEqual(
            scheduler.requestTurn(second),
            .queued(.runtimeProfile(.pluginWorkingDirectory))
        )
        XCTAssertEqual(scheduler.finishTurn(workID: first.workID), [second])
    }

    func testReadOnlyThreadPostureSharesTheInteractiveProcessBatch() {
        var scheduler = CodexWorkScheduler(maxConcurrentTurns: 4)
        let interactive = CodexScheduledWork(
            workID: UUID(),
            purpose: .interactive(
                ownerID: UUID(),
                conversationID: UUID(),
                turnID: UUID()
            ),
            runtimeProfile: CodexRuntimeProfile(
                webAccess: true
            )
        )
        let scheduled = CodexScheduledWork(
            workID: UUID(),
            purpose: .scheduled(
                runID: "scheduled",
                conversationID: nil,
                turnID: UUID()
            ),
            runtimeProfile: CodexRuntimeProfile(
                webAccess: true
            )
        )

        XCTAssertEqual(scheduler.requestTurn(interactive), .admitted)
        XCTAssertEqual(scheduler.requestTurn(scheduled), .admitted)
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
        XCTAssertEqual(scheduler.requestTurn(cancelled), .queued(.capacity))
        XCTAssertEqual(scheduler.requestTurn(next), .queued(.capacity))
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
        XCTAssertEqual(scheduler.requestTurn(reserved), .queued(.capacity))
        XCTAssertEqual(scheduler.requestTurn(next), .queued(.capacity))
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
                pluginWorkingDirectory: "/incompatible"
            )
        )
        let compatible = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))

        XCTAssertEqual(scheduler.requestTurn(active), .admitted)
        XCTAssertEqual(
            scheduler.requestTurn(incompatible),
            .queued(.runtimeProfile(.pluginToggle))
        )
        XCTAssertEqual(
            scheduler.requestTurn(compatible),
            .queued(.runtimeProfile(.pluginToggle)),
            "a compatible turn behind an incompatible FIFO head is profile-blocked"
        )
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
