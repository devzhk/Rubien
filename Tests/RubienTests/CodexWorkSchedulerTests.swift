#if os(macOS)
import XCTest
@testable import Rubien

final class CodexWorkSchedulerTests: XCTestCase {
    func testClaimedScheduledReservationCannotBeLeapfrogged() {
        var scheduler = CodexWorkScheduler()
        let interactive = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))
        let scheduled = work(.scheduled(
            runID: "run-1", conversationID: UUID(), turnID: UUID()
        ))
        let laterInteractive = work(.interactive(
            ownerID: UUID(), conversationID: UUID(), turnID: UUID()
        ))

        XCTAssertEqual(scheduler.requestTurn(interactive), .admitted)
        XCTAssertEqual(scheduler.requestTurn(scheduled), .queued)
        XCTAssertEqual(scheduler.requestTurn(laterInteractive), .busy)
        XCTAssertEqual(scheduler.finishTurn(workID: interactive.workID), scheduled)
        XCTAssertEqual(scheduler.requestTurn(laterInteractive), .busy)
        XCTAssertEqual(scheduler.requestTurn(scheduled), .admitted)
    }

    func testTurnPreemptsMetadataAndScheduledQueueIsFIFO() {
        var scheduler = CodexWorkScheduler()
        let metadata = work(.metadata(kind: .history, requestID: UUID()))
        let first = work(.scheduled(runID: "one", conversationID: nil, turnID: UUID()))
        let second = work(.scheduled(runID: "two", conversationID: nil, turnID: UUID()))

        XCTAssertEqual(scheduler.beginMetadata(metadata), .admitted)
        XCTAssertEqual(scheduler.requestTurn(first), .preemptMetadataAndAdmit)
        XCTAssertEqual(scheduler.requestTurn(second), .queued)
        XCTAssertEqual(scheduler.finishTurn(workID: first.workID), second)
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
