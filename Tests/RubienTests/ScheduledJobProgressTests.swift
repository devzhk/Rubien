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

    func testProgressProjectsIntoHomeTranscriptWithoutDuplicatingProviderStorage() throws {
        let run = ScheduledJobRun(
            id: "run-1",
            jobId: "job-1",
            trigger: .manual,
            occurrenceKey: "manual-1",
            scheduledFor: Date(),
            startedAt: Date(),
            finishedAt: nil,
            status: .running,
            provider: .codex,
            providerSessionId: "session-1",
            failureKind: nil,
            isUnread: false
        )
        var progress = ScheduledJobProgress(run: run, prompt: "Find morning papers")
        progress.record(.assistantMessageCompleted(text: "I found a candidate."))
        progress.record(.toolUseStarted(name: "rubien_search", detail: "agents"))
        progress.record(.toolUseCompleted(name: "rubien_search"))
        progress.record(.providerNotice("Read-only run"))

        let rows = ScheduledRunTranscript.messages(
            run: run,
            fallbackPrompt: "Edited prompt that was not executed",
            progress: progress
        )

        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .tool, .notice])
        XCTAssertEqual(rows[0].body, "Find morning papers")
        XCTAssertEqual(rows[1].body, "I found a candidate.")
        let toolData = try XCTUnwrap(rows[2].body.data(using: .utf8))
        let tool = try JSONDecoder().decode(ToolChipPayload.self, from: toolData)
        XCTAssertEqual(tool.name, "rubien_search")
        XCTAssertEqual(tool.detail, "agents")
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(rows[3].body, "Read-only run")
    }

    func testSuccessfulRunWithoutEntriesUsesTerminalNotice() {
        let run = ScheduledJobRun(
            id: "run-1",
            jobId: "job-1",
            trigger: .manual,
            occurrenceKey: "manual-1",
            scheduledFor: Date(),
            startedAt: Date(),
            finishedAt: Date(),
            status: .succeeded,
            provider: .codex,
            providerSessionId: "session-1",
            failureKind: nil,
            isUnread: false
        )

        let rows = ScheduledRunTranscript.messages(
            run: run,
            fallbackPrompt: "Find papers",
            progress: nil
        )

        XCTAssertEqual(rows.map(\.role), [.user, .notice])
        XCTAssertEqual(
            rows[1].body,
            ScheduledJobFormatting.localized("scheduled.progress.completedWithoutOutput")
        )
    }

    func testTranscriptIncrementalPlanAppendsOnlyNewAssistantDelta() {
        let run = runningRun()
        var previous = ScheduledJobProgress(run: run)
        previous.record(.assistantDelta(text: "Finding"))
        var current = previous
        current.record(.assistantDelta(text: " papers"))

        XCTAssertEqual(
            ScheduledRunTranscript.incrementalActions(from: previous, to: current),
            [.appendAssistantDelta(" papers")]
        )
    }

    func testTranscriptIncrementalPlanCommitsAndAppendsFollowingRows() {
        let run = runningRun()
        var previous = ScheduledJobProgress(run: run)
        previous.record(.assistantDelta(text: "Draft"))
        var current = previous
        current.record(.assistantMessageCompleted(text: "Final answer"))
        current.record(.toolUseCompleted(name: "rubien_search"))

        XCTAssertEqual(
            ScheduledRunTranscript.incrementalActions(from: previous, to: current),
            [
                .commitAssistant("Final answer"),
                .addTool(name: "rubien_search", detail: nil, status: .completed),
            ]
        )
    }

    func testTranscriptIncrementalPlanRequestsResyncForInPlaceToolUpdate() {
        let run = runningRun()
        var previous = ScheduledJobProgress(run: run)
        previous.record(.toolUseStarted(name: "rubien_search", detail: "agents"))
        var current = previous
        current.record(.toolUseCompleted(name: "rubien_search"))

        XCTAssertNil(ScheduledRunTranscript.incrementalActions(from: previous, to: current))
    }

    func testProgressBoundsEveryEntryKindAndAggregateCharacters() {
        let run = ScheduledJobRun(
            id: "run-1",
            jobId: "job-1",
            trigger: .manual,
            occurrenceKey: "manual-1",
            scheduledFor: Date(),
            startedAt: Date(),
            finishedAt: nil,
            status: .running,
            provider: .codex,
            providerSessionId: nil,
            failureKind: nil,
            isUnread: false
        )
        var progress = ScheduledJobProgress(run: run)
        let oversized = String(repeating: "x", count: 40_000)

        progress.record(.providerNotice(oversized))
        progress.record(.toolUseStarted(name: "read", detail: oversized))
        for _ in 0..<4 {
            progress.record(.assistantMessageCompleted(text: oversized))
        }

        XCTAssertEqual(progress.entries.count, 3)
        XCTAssertTrue(progress.entries.allSatisfy { $0.detail.count <= 32_001 })
        XCTAssertLessThanOrEqual(
            progress.entries.reduce(0, { $0 + $1.detail.count }),
            128_000
        )
    }

    private func runningRun() -> ScheduledJobRun {
        ScheduledJobRun(
            id: "run-incremental",
            jobId: "job-1",
            trigger: .manual,
            occurrenceKey: "manual-incremental",
            scheduledFor: Date(),
            startedAt: Date(),
            finishedAt: nil,
            status: .running,
            provider: .codex,
            providerSessionId: nil,
            failureKind: nil,
            isUnread: false
        )
    }
}
#endif
