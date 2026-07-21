#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class ScheduledJobProgressTests: XCTestCase {
    func testProgressCoalescesStreamingTextAndUpdatesToolState() {
        let run = ScheduledJobRun(
            id: "run-1",
            jobId: "job-1",
            trigger: .manual,
            occurrenceKey: "manual-1",
            scheduledFor: Date(),
            startedAt: nil,
            finishedAt: nil,
            status: .pending,
            provider: .codex,
            providerSessionId: nil,
            failureKind: nil,
            isUnread: false
        )
        var progress = ScheduledJobProgress(run: run)

        progress.markStarted()
        progress.record(.sessionStarted(sessionID: "session-1"))
        progress.record(.modelResolved(model: "gpt-test"))
        progress.record(.assistantDelta(text: "Searching "))
        progress.record(.assistantDelta(text: "the library…"))
        progress.record(.toolUseStarted(name: "rubien_search", detail: "transformers"))
        progress.record(.toolUseCompleted(name: "rubien_search"))
        progress.record(.assistantMessageCompleted(text: "I found three papers."))

        XCTAssertEqual(progress.phase, .running)
        XCTAssertEqual(progress.sessionID, "session-1")
        XCTAssertEqual(progress.model, "gpt-test")
        XCTAssertEqual(progress.entries.count, 2)
        XCTAssertEqual(
            progress.entries[0],
            .init(
                id: progress.entries[0].id,
                kind: .assistant(isStreaming: false),
                detail: "I found three papers."
            )
        )
        XCTAssertEqual(
            progress.entries[1],
            .init(
                id: progress.entries[1].id,
                kind: .tool(name: "rubien_search", status: .completed),
                detail: "transformers"
            )
        )

        progress.record(.turnCompleted(usage: nil))
        XCTAssertEqual(progress.phase, .succeeded)
    }
}
#endif
