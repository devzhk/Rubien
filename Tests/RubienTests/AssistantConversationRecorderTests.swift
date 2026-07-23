#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class AssistantConversationRecorderTests: XCTestCase {
    func testRecorderPreservesProviderOrderAndRejectsStaleGenerationContent() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversationID = UUID()
        let turnID = UUID()
        let workID = UUID()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let conversation = AssistantConversation(
            id: conversationID.uuidString.lowercased(),
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            createdAt: started
        )
        let turn = AssistantTurn(
            id: turnID.uuidString.lowercased(),
            conversationId: conversation.id,
            ordinal: 0,
            status: .starting,
            dateModified: started
        )
        let user = AssistantTranscriptEntry(
            turnId: turn.id,
            sequence: 0,
            kind: .user,
            body: "Summarize this",
            createdAt: started
        )
        let allocated = try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: user,
            allowConversationCreation: true
        )
        let baseAttempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 7,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: 3
        )
        let captureAttempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 7,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: nil
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-workspace", isDirectory: true)
        let recorder = makeRecorder(
            database: database,
            attempt: captureAttempt,
            provider: .codex,
            workspaceURL: workspace,
            conversationID: conversation.id,
            turnID: turn.id,
            turnOrdinal: allocated.ordinal,
            mode: .interactive,
            now: { started }
        )

        try await recorder.record(envelope(baseAttempt, id: nil, .sessionStarted(sessionID: "TH-1")))
        try await recorder.record(envelope(baseAttempt, id: "answer-1", .assistantDelta(text: "Before tools")))
        try await recorder.record(envelope(baseAttempt, id: "tool-a", .toolUseStarted(name: "search", detail: "first")))
        try await recorder.record(envelope(baseAttempt, id: "tool-b", .toolUseStarted(name: "search", detail: "second")))
        try await recorder.record(envelope(baseAttempt, id: "tool-b", .toolUseCompleted(name: "search")))
        try await recorder.record(envelope(baseAttempt, id: "tool-a", .toolUseCompleted(name: "search")))
        try await recorder.record(envelope(baseAttempt, id: "answer-2", .assistantMessageCompleted(text: "Final answer")))

        let stale = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 7,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: 2
        )
        try await recorder.record(envelope(stale, id: nil, .providerNotice("stale")))
        try await recorder.record(envelope(
            baseAttempt,
            id: nil,
            .turnCompleted(.init(
                outcome: .succeeded,
                usage: .init(inputTokens: 12, outputTokens: 5)
            ))
        ))
        try await recorder.finish()

        // Identity remains open after visible content closes, so a rotating late
        // provider session can preserve continuation without reviving the turn.
        try await recorder.record(envelope(baseAttempt, id: nil, .sessionStarted(sessionID: "TH-2")))
        try await recorder.record(envelope(baseAttempt, id: nil, .providerNotice("late content")))
        await recorder.closeIdentity()

        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(detail.entries.map(\.kind), [
            .user, .assistant, .tool, .tool, .assistant,
        ])
        XCTAssertEqual(detail.entries.map(\.sequence), [0, 1, 2, 3, 4])
        XCTAssertEqual(detail.entries[1].body, "Before tools")
        XCTAssertEqual(detail.entries[4].body, "Final answer")
        XCTAssertFalse(detail.entries.contains { $0.body == "stale" || $0.body == "late content" })
        XCTAssertEqual(detail.turns.first?.status, .succeeded)
        XCTAssertEqual(detail.turns.first?.inputTokens, 12)
        XCTAssertEqual(detail.turns.first?.outputTokens, 5)
        XCTAssertEqual(detail.conversation.latestProviderSessionId, "TH-2")
    }

    func testRecorderRejectsMoreThanOneMiBOfUnflushedContent() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversationID = UUID()
        let turnID = UUID()
        let workID = UUID()
        let conversation = AssistantConversation(
            id: conversationID.uuidString.lowercased(),
            provider: .claude,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        )
        let turn = AssistantTurn(
            id: turnID.uuidString.lowercased(),
            conversationId: conversation.id,
            ordinal: 0
        )
        _ = try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: .init(
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: "Prompt"
            ),
            allowConversationCreation: true
        )
        let attempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 1,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: nil
        )
        let recorder = makeRecorder(
            database: database,
            attempt: attempt,
            provider: .claude,
            workspaceURL: FileManager.default.temporaryDirectory,
            conversationID: conversation.id,
            turnID: turn.id,
            turnOrdinal: 1,
            mode: .interactive
        )

        do {
            try await recorder.record(envelope(
                attempt,
                id: "oversized",
                .assistantMessageCompleted(text: String(repeating: "x", count: 1_048_577))
            ))
            XCTFail("expected the recorder buffer bound")
        } catch let error as AssistantConversationRecorderError {
            guard case .unflushedBufferLimitExceeded = error else {
                return XCTFail("unexpected recorder error: \(error)")
            }
        }
        try await recorder.finish(
            fallbackOutcome: .failed,
            failureKind: "storageFailure"
        )

        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(
            detail.entries.map { $0.kind },
            [AssistantTranscriptEntryKind.user]
        )
        XCTAssertEqual(detail.turns.first?.status, .failed)
    }

    func testRecorderAcceptsLargeAnswerThatWasIncrementallyFlushed() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversationID = UUID()
        let turnID = UUID()
        let workID = UUID()
        let conversation = AssistantConversation(
            id: conversationID.uuidString.lowercased(),
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        )
        let turn = AssistantTurn(
            id: turnID.uuidString.lowercased(),
            conversationId: conversation.id,
            ordinal: 0
        )
        _ = try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: .init(
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: "Prompt"
            ),
            allowConversationCreation: true
        )
        let attempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 1,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: nil
        )
        let recorder = makeRecorder(
            database: database,
            attempt: attempt,
            provider: .codex,
            workspaceURL: FileManager.default.temporaryDirectory,
            conversationID: conversation.id,
            turnID: turn.id,
            turnOrdinal: 1,
            mode: .interactive
        )

        let chunk = String(repeating: "x", count: 4_096)
        var answer = ""
        for _ in 0..<257 {
            answer += chunk
            try await recorder.record(envelope(
                attempt,
                id: "large-streamed-answer",
                .assistantDelta(text: chunk)
            ))
        }
        try await recorder.record(envelope(
            attempt,
            id: "large-streamed-answer",
            .assistantMessageCompleted(text: answer)
        ))
        try await recorder.record(envelope(
            attempt,
            id: nil,
            .turnCompleted(.init(outcome: .succeeded, usage: nil))
        ))
        try await recorder.finish()

        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(detail.entries.last?.body.utf8.count, answer.utf8.count)
        XCTAssertEqual(detail.entries.last?.status, .completed)
        XCTAssertEqual(detail.turns.first?.status, .succeeded)
    }

    func testTimedInteractiveFlushFailureTerminalizesTurn() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversationID = UUID()
        let turnID = UUID()
        let workID = UUID()
        let conversation = AssistantConversation(
            id: conversationID.uuidString.lowercased(),
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        )
        let turn = AssistantTurn(
            id: turnID.uuidString.lowercased(),
            conversationId: conversation.id,
            ordinal: 0
        )
        _ = try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: .init(
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: "Prompt"
            ),
            allowConversationCreation: true
        )
        try installAssistantEntryFailureTrigger(database)
        let attempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 1,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: nil
        )
        let recorder = makeRecorder(
            database: database,
            attempt: attempt,
            provider: .codex,
            workspaceURL: FileManager.default.temporaryDirectory,
            conversationID: conversation.id,
            turnID: turn.id,
            turnOrdinal: 1,
            mode: .interactive
        )

        try await recorder.record(envelope(
            attempt,
            id: "timed-answer",
            .assistantDelta(text: "small buffered answer")
        ))
        try await Task.sleep(for: .milliseconds(350))
        let storageFailed = try await recorder.finish(fallbackOutcome: .succeeded)
        XCTAssertTrue(storageFailed)

        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(detail.turns.first?.status, .failed)
        XCTAssertEqual(detail.turns.first?.failureKind, "storageFailure")
        XCTAssertEqual(detail.entries.map(\.kind), [.user])
    }

    func testTimedScheduledFlushFailureTerminalizesRun() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let job = try database.createScheduledJob(.init(
            name: "Morning papers",
            prompt: "Find papers",
            recurrence: .init(weekdayMask: 127, localMinuteOfDay: 480),
            provider: .codex
        ))
        let claim = try database.claimManualScheduledJob(id: job.id)
        let conversationID = UUID()
        let turnID = UUID()
        let workID = UUID()
        let conversation = AssistantConversation(
            id: conversationID.uuidString.lowercased(),
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            scheduledJobRunId: claim.run.id
        )
        let turn = AssistantTurn(
            id: turnID.uuidString.lowercased(),
            conversationId: conversation.id,
            ordinal: 1,
            status: .running
        )
        try database.beginScheduledAssistantCapture(
            runID: claim.run.id,
            conversation: conversation,
            turn: turn,
            userEntry: .init(
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: job.prompt
            )
        )
        try installAssistantEntryFailureTrigger(database)
        let attempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 1,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: nil
        )
        let recorder = makeRecorder(
            database: database,
            attempt: attempt,
            provider: .codex,
            workspaceURL: FileManager.default.temporaryDirectory,
            conversationID: conversation.id,
            turnID: turn.id,
            turnOrdinal: 1,
            mode: .scheduled(runID: claim.run.id)
        )

        try await recorder.record(envelope(
            attempt,
            id: "timed-answer",
            .assistantDelta(text: "small buffered answer")
        ))
        try await Task.sleep(for: .milliseconds(350))
        let storageFailed = try await recorder.finish(fallbackOutcome: .succeeded)
        XCTAssertTrue(storageFailed)

        let storedRun = try XCTUnwrap(database.fetchScheduledJobRun(id: claim.run.id))
        XCTAssertEqual(storedRun.status, .failed)
        XCTAssertEqual(storedRun.failureKind, .storageFailure)
        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(detail.turns.first?.status, .failed)
        XCTAssertEqual(detail.turns.first?.failureKind, "storageFailure")
    }

    func testPaperPresentationReplacesItsProvisionalToolRow() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversationID = UUID()
        let turnID = UUID()
        let workID = UUID()
        let conversation = AssistantConversation(
            id: conversationID.uuidString.lowercased(),
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        )
        let turn = AssistantTurn(
            id: turnID.uuidString.lowercased(),
            conversationId: conversation.id,
            ordinal: 0
        )
        _ = try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: .init(
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: "Find papers"
            ),
            allowConversationCreation: true
        )
        let attempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 1,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: nil
        )
        let recorder = makeRecorder(
            database: database,
            attempt: attempt,
            provider: .codex,
            workspaceURL: FileManager.default.temporaryDirectory,
            conversationID: conversation.id,
            turnID: turn.id,
            turnOrdinal: 1,
            mode: .interactive
        )
        let itemID = "paper-tool"
        let toolName = "mcp__rubien__\(ChatPaperPresentation.toolName)"
        let group = ChatPaperGroup(items: [
            ChatPaper(
                kind: .library,
                referenceId: 7,
                url: nil,
                title: "Durable paper",
                year: 2026,
                badge: "Library"
            ),
        ])

        try await recorder.record(envelope(
            attempt,
            id: itemID,
            .toolUseStarted(name: toolName, detail: "Presenting papers")
        ))
        try await recorder.record(envelope(
            attempt,
            id: itemID,
            .paperPresentation(callID: itemID, ordinal: 0, group: group)
        ))
        try await recorder.record(envelope(
            attempt,
            id: itemID,
            .toolUseCompleted(name: toolName)
        ))
        try await recorder.record(envelope(
            attempt,
            id: nil,
            .turnCompleted(.init(outcome: .succeeded, usage: nil))
        ))
        try await recorder.finish()

        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(detail.entries.map(\.kind), [.user, .paper])
        XCTAssertEqual(detail.entries.last?.body, ChatPaperPresentation.encodeHistoryGroup(group))
    }

    private func installAssistantEntryFailureTrigger(_ database: AppDatabase) throws {
        try database.dbWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failTimedAssistantFlush
                BEFORE INSERT ON assistantTranscriptEntry
                WHEN NEW.kind = 'assistant'
                BEGIN
                    SELECT RAISE(FAIL, 'injected timed transcript failure');
                END;
                """)
        }
    }

    private func makeRecorder(
        database: AppDatabase,
        attempt: AssistantAttemptIdentity,
        provider: AssistantProvider,
        workspaceURL: URL,
        conversationID: String,
        turnID: String,
        turnOrdinal: Int,
        mode: AssistantConversationRecorder.Mode,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AssistantConversationRecorder {
        AssistantConversationService.makeCapture(
            database: database,
            attempt: attempt,
            provider: provider,
            workspaceURL: workspaceURL,
            conversationID: conversationID,
            turnID: turnID,
            turnOrdinal: turnOrdinal,
            mode: mode,
            now: now
        ).recorder
    }

    private func envelope(
        _ attempt: AssistantAttemptIdentity,
        id: String?,
        _ event: AgentEvent
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(attempt: attempt, providerItemID: id, event: event)
    }
}
#endif
