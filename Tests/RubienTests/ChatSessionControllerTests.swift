#if os(macOS)
import XCTest
@testable import Rubien

@MainActor
final class ChatSessionControllerTests: XCTestCase {

    // MARK: Fixtures

    private func makeController(
        provider: MockAgentProvider,
        sink: SpyTranscriptSink,
        gate: AssistantTurnGate = AssistantTurnGate(),
        webAccess: Bool = true
    ) -> ChatSessionController {
        ChatSessionController(
            provider: provider,
            transcript: sink,
            reference: ChatReference(id: 1, title: "Attention", authors: "Vaswani et al."),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            gate: gate,
            webAccess: webAccess)
    }

    /// Drive one full turn: send, wait for the provider stream, feed events, finish.
    private func runTurn(
        _ controller: ChatSessionController,
        provider: MockAgentProvider,
        send prompt: String,
        events: [AgentEvent]
    ) async {
        controller.send(prompt)
        let task = controller.turnTask
        await provider.waitUntilStreaming()
        for event in events { provider.emit(event) }
        provider.finishStream()
        await task?.value
    }

    /// Yield the main actor until `condition` holds — deterministic draining of the
    /// controller's async for-await loop (buffered mock events process one per turn).
    private func waitUntil(_ condition: @escaping () -> Bool, ticks: Int = 200) async {
        var n = 0
        while !condition() && n < ticks { await Task.yield(); n += 1 }
    }

    // MARK: Event mapping (direct)

    func testSessionStartedCapturesAndRotatesID() {
        let controller = makeController(provider: MockAgentProvider(), sink: SpyTranscriptSink())
        let g = controller.generation
        controller.handle(.sessionStarted(sessionID: "s1"), gen: g)
        XCTAssertEqual(controller.liveSessionID, "s1")
        controller.handle(.sessionStarted(sessionID: "s2"), gen: g)
        XCTAssertEqual(controller.liveSessionID, "s2", "the id rotates and the latest wins (D5)")
    }

    func testDeltasAndCompletionDriveRenderer() {
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: MockAgentProvider(), sink: sink)
        let g = controller.generation
        controller.handle(.assistantDelta(text: "He"), gen: g)
        controller.handle(.assistantDelta(text: "llo"), gen: g)
        controller.handle(.assistantMessageCompleted(text: "Hello"), gen: g)
        XCTAssertEqual(sink.calls, [.appendDelta("He"), .appendDelta("llo"), .commitAssistantMessage("Hello")])
    }

    func testStaleEventsAreDroppedByGeneration() {
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: MockAgentProvider(), sink: sink)
        // An event tagged with an old generation is ignored.
        controller.handle(.assistantDelta(text: "stale"), gen: controller.generation - 1)
        XCTAssertTrue(sink.calls.isEmpty)
    }

    func testToolChipEmittedOnceOnCompletionWithRememberedDetail() {
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: MockAgentProvider(), sink: sink)
        let g = controller.generation
        controller.handle(.toolUseStarted(name: "rubien_pdf_text", detail: "pages 1-3"), gen: g)
        XCTAssertTrue(sink.calls.isEmpty, "no chip on start — it waits for the terminal event")
        controller.handle(.toolUseCompleted(name: "rubien_pdf_text"), gen: g)
        XCTAssertEqual(sink.calls, [.addToolChip("rubien_pdf_text", "pages 1-3", .completed)])
    }

    func testConcurrentSameNameToolChipsMatchFIFO() {
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: MockAgentProvider(), sink: sink)
        let g = controller.generation
        controller.handle(.toolUseStarted(name: "rubien_pdf_text", detail: "pages 1-3"), gen: g)
        controller.handle(.toolUseStarted(name: "rubien_pdf_text", detail: "pages 8-9"), gen: g)
        controller.handle(.toolUseCompleted(name: "rubien_pdf_text"), gen: g)
        controller.handle(.toolUseCompleted(name: "rubien_pdf_text"), gen: g)
        XCTAssertEqual(sink.calls, [
            .addToolChip("rubien_pdf_text", "pages 1-3", .completed),
            .addToolChip("rubien_pdf_text", "pages 8-9", .completed),
        ])
    }

    func testToolDeniedEmitsDeniedChip() {
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: MockAgentProvider(), sink: sink)
        controller.handle(.toolDenied(name: "Write", reason: "blocked by sandbox"), gen: controller.generation)
        XCTAssertEqual(sink.calls, [.addToolChip("Write", "blocked by sandbox", .denied)])
    }

    func testApprovalRequestedSetsPendingAndRespondForwardsAndClears() {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        controller.handle(.approvalRequested(id: "req-1", toolName: "Write", summary: "note.txt"), gen: controller.generation)
        let pending = try? XCTUnwrap(controller.pendingApproval)
        XCTAssertEqual(pending, .init(id: "req-1", toolName: "Write", summary: "note.txt"))

        controller.respond(to: pending!, .allowOnce)
        XCTAssertEqual(provider.approvals.map(\.0), ["req-1"])
        XCTAssertEqual(provider.approvals.first?.1, .allowOnce)
        XCTAssertNil(controller.pendingApproval)
    }

    func testStaleApprovalResponseIsNotForwarded() {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        let g = controller.generation
        controller.handle(.approvalRequested(id: "rA", toolName: "Write", summary: "a"), gen: g)
        let approvalA = controller.pendingApproval!
        // A newer approval replaces A.
        controller.handle(.approvalRequested(id: "rB", toolName: "Bash", summary: "b"), gen: g)

        controller.respond(to: approvalA, .deny)  // stale — must be dropped
        XCTAssertTrue(provider.approvals.isEmpty, "a stale approval response must not be forwarded")
        XCTAssertEqual(controller.pendingApproval?.id, "rB", "the current approval is untouched")

        controller.respond(to: controller.pendingApproval!, .allowOnce)
        XCTAssertEqual(provider.approvals.map(\.0), ["rB"])
    }

    func testAutoApproveAcceptsWithoutShowingACard() {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        controller.autoApprove = true

        controller.handle(.approvalRequested(id: "rX", toolName: "Write", summary: "note.txt"), gen: controller.generation)

        XCTAssertNil(controller.pendingApproval, "auto mode never shows an approval card")
        XCTAssertEqual(provider.approvals.map(\.0), ["rX"])
        XCTAssertEqual(provider.approvals.first?.1, .allowForConversation)
    }

    func testProviderNoticeIsRendered() {
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: MockAgentProvider(), sink: sink)
        controller.handle(.providerNotice("Rate limit approaching."), gen: controller.generation)
        XCTAssertEqual(sink.notices, ["Rate limit approaching."])
    }

    // MARK: Turn flow (streamed)

    func testSendBuildsRequestAndDrivesAHappyTurn() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)

        await runTurn(controller, provider: provider, send: "hello", events: [
            .sessionStarted(sessionID: "s1"),
            .assistantDelta(text: "Hi"),
            .assistantMessageCompleted(text: "Hi"),
            .turnCompleted(usage: nil),
        ])

        XCTAssertEqual(sink.calls.first, .addUserMessage("hello"))
        XCTAssertTrue(sink.calls.contains(.beginAssistantMessage))
        XCTAssertTrue(sink.calls.contains(.commitAssistantMessage("Hi")))
        XCTAssertFalse(controller.isResponding)
        XCTAssertNil(controller.statusText)
        XCTAssertEqual(controller.liveSessionID, "s1")

        let request = provider.lastRequest
        XCTAssertEqual(request?.prompt, "hello")
        XCTAssertNil(request?.resumeSessionID, "first turn is a new conversation")
        XCTAssertNotNil(request?.seed, "first turn carries the reference seed")
        XCTAssertEqual(request?.webAccess, true)
    }

    func testSeedIsFirstTurnOnlyAndSessionIDIsRecapturedForResume() async {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())

        await runTurn(controller, provider: provider, send: "q1", events: [.sessionStarted(sessionID: "s1"), .turnCompleted(usage: nil)])
        await runTurn(controller, provider: provider, send: "q2", events: [.sessionStarted(sessionID: "s2"), .turnCompleted(usage: nil)])

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertNotNil(provider.requests[0].seed)
        XCTAssertNil(provider.requests[0].resumeSessionID)
        XCTAssertNil(provider.requests[1].seed, "seed is applied on the first turn only")
        XCTAssertEqual(provider.requests[1].resumeSessionID, "s1", "resume targets the id captured last turn")
    }

    func testWebAccessTogglePropagatesToRequest() async {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink(), webAccess: true)
        controller.webAccess = false
        await runTurn(controller, provider: provider, send: "q", events: [.turnCompleted(usage: nil)])
        XCTAssertEqual(provider.lastRequest?.webAccess, false)
    }

    func testModelAndEffortSelectionPropagateToRequest() async {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())

        // The sidebar always shows/uses a concrete model+effort (defaults).
        await runTurn(controller, provider: provider, send: "q0", events: [.turnCompleted(usage: nil)])
        XCTAssertEqual(provider.lastRequest?.modelOverride, "opus")
        XCTAssertEqual(provider.lastRequest?.effortOverride, "high")

        // A picker change applies to the next turn.
        controller.modelOverride = "sonnet"
        controller.effortOverride = "medium"
        await runTurn(controller, provider: provider, send: "q", events: [.turnCompleted(usage: nil)])
        XCTAssertEqual(provider.lastRequest?.modelOverride, "sonnet")
        XCTAssertEqual(provider.lastRequest?.effortOverride, "medium")

        // nil (programmatic — no UI path) omits both flags.
        controller.modelOverride = nil
        controller.effortOverride = nil
        await runTurn(controller, provider: provider, send: "q2", events: [.turnCompleted(usage: nil)])
        XCTAssertNil(provider.lastRequest?.modelOverride)
        XCTAssertNil(provider.lastRequest?.effortOverride)
    }

    func testStageSelectionStagesTextAndBumpsFocusRequestEachTime() async {
        let controller = makeController(provider: MockAgentProvider(), sink: SpyTranscriptSink())
        XCTAssertNil(controller.stagedSelection)
        let start = controller.composerFocusRequest

        controller.stageSelection("first passage")
        XCTAssertEqual(controller.stagedSelection, "first passage")
        XCTAssertEqual(controller.composerFocusRequest, start + 1)

        // Re-Asking the identical passage still bumps the token (equality-independent
        // focus) even though `stagedSelection` is unchanged.
        controller.stageSelection("first passage")
        XCTAssertEqual(controller.stagedSelection, "first passage")
        XCTAssertEqual(controller.composerFocusRequest, start + 2)
    }

    func testAutoApproveInitParamSeedsTheProperty() {
        // Settings ▸ Assistant seeds a new conversation's approval mode via this param.
        let auto = ChatSessionController(
            provider: MockAgentProvider(), transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            gate: AssistantTurnGate(), autoApprove: true)
        XCTAssertTrue(auto.autoApprove)

        let ask = ChatSessionController(
            provider: MockAgentProvider(), transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            gate: AssistantTurnGate())
        XCTAssertFalse(ask.autoApprove, "defaults to Ask")
    }

    func testStagedSelectionIsQuotedIntoTheMessageThenCleared() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)
        controller.stagedSelection = "the scaled dot-product attention"

        await runTurn(controller, provider: provider, send: "explain this", events: [.turnCompleted(usage: nil)])

        let prompt = provider.lastRequest?.prompt ?? ""
        XCTAssertTrue(prompt.contains("> the scaled dot-product attention"))
        XCTAssertTrue(prompt.contains("explain this"))
        XCTAssertNil(controller.stagedSelection, "the staged selection is consumed by the send")
    }

    func testBusyInAnotherWindowIsSurfacedWithoutSpawning() async {
        let gate = AssistantTurnGate()
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink, gate: gate)

        // Turn 1 establishes session "s1".
        await runTurn(controller, provider: provider, send: "q1", events: [.sessionStarted(sessionID: "s1"), .turnCompleted(usage: nil)])
        XCTAssertEqual(controller.liveSessionID, "s1")

        // Another window holds the resume slot for (claude, s1).
        let held = await gate.tryAcquire(provider: .claude, sessionID: "s1")
        XCTAssertTrue(held)

        // Turn 2 must be refused, and must NOT reach the provider.
        controller.send("q2")
        await controller.turnTask?.value
        XCTAssertTrue(controller.busyElsewhere)
        XCTAssertTrue(sink.notices.contains { $0.lowercased().contains("busy in another window") })
        XCTAssertEqual(provider.requests.count, 1, "the busy turn never spawned a second process")
        XCTAssertFalse(controller.isResponding)
        XCTAssertFalse(sink.calls.contains(.addUserMessage("q2")), "a refused message must not be rendered")
    }

    func testSeedIsResentWhenTheFirstTurnFailsBeforeASession() async {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())

        // First turn errors before any .sessionStarted (e.g. spawn failure).
        struct Boom: Error {}
        controller.send("q1")
        let task1 = controller.turnTask
        await provider.waitUntilStreaming()
        provider.failStream(Boom())
        await task1?.value
        XCTAssertNil(controller.liveSessionID)

        // The retry must re-send the seed (context was never established).
        await runTurn(controller, provider: provider, send: "q1-retry", events: [.sessionStarted(sessionID: "s1"), .turnCompleted(usage: nil)])
        XCTAssertNotNil(provider.requests[0].seed)
        XCTAssertNotNil(provider.requests[1].seed, "the seed is re-sent because the first turn never started a session")
    }

    func testNewConversationDropsLateEventsFromTheDrainingTurn() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)

        controller.send("q1")
        let oldTask = controller.turnTask
        await provider.waitUntilStreaming()
        // A rotated session id is in flight when the user starts a fresh conversation.
        provider.emit(.sessionStarted(sessionID: "s-late"))
        controller.newConversation()
        await oldTask?.value

        XCTAssertNil(controller.liveSessionID, "the late rotated id must not leak into the fresh conversation")
        XCTAssertTrue(sink.calls.contains(.reset))
        XCTAssertFalse(controller.isResponding)
    }

    func testGateSlotIsReleasedBeforeTheTurnTaskCompletes() async {
        let gate = AssistantTurnGate()
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink(), gate: gate)

        await runTurn(controller, provider: provider, send: "q1", events: [.sessionStarted(sessionID: "s1"), .turnCompleted(usage: nil)])
        // Turn 2 resumes s1 (a keyed acquire) and completes.
        await runTurn(controller, provider: provider, send: "q2", events: [.sessionStarted(sessionID: "s1"), .turnCompleted(usage: nil)])

        // Awaiting the turn guaranteed the slot was released — an immediate acquire wins.
        let free = await gate.tryAcquire(provider: .claude, sessionID: "s1")
        XCTAssertTrue(free, "the gate slot must be released before the turn task completes")
    }

    func testStopCancelsTheProviderWhileResponding() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)

        controller.send("q")
        let task = controller.turnTask
        await provider.waitUntilStreaming()
        provider.emit(.sessionStarted(sessionID: "s1"))
        XCTAssertTrue(controller.isResponding)

        controller.stop()  // process-group kill; the mock ends the stream on cancel
        await task?.value

        XCTAssertEqual(provider.cancelCount, 1)
        XCTAssertTrue(sink.notices.contains { $0.contains("Interrupted") })
        XCTAssertFalse(controller.isResponding)
    }

    func testNewConversationResetsTranscriptAndSession() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)
        await runTurn(controller, provider: provider, send: "q1", events: [.sessionStarted(sessionID: "s1"), .turnCompleted(usage: nil)])

        controller.newConversation()
        XCTAssertTrue(sink.calls.contains(.reset))
        XCTAssertNil(controller.liveSessionID)

        // The next turn is a fresh conversation again: seed present, no resume.
        await runTurn(controller, provider: provider, send: "q2", events: [.turnCompleted(usage: nil)])
        XCTAssertNotNil(provider.lastRequest?.seed)
        XCTAssertNil(provider.lastRequest?.resumeSessionID)
    }

    func testHasMessagesDrivesTheQuickStartPageLifecycle() async {
        let gate = AssistantTurnGate()
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink(), gate: gate)
        XCTAssertFalse(controller.hasMessages, "fresh conversation shows the quick-start page")

        await runTurn(controller, provider: provider, send: "q1", events: [.sessionStarted(sessionID: "s1"), .turnCompleted(usage: nil)])
        XCTAssertTrue(controller.hasMessages, "first sent message hides the quick-start page")

        controller.newConversation()
        XCTAssertFalse(controller.hasMessages, "a new conversation shows it again")

        // A gate-refused turn renders nothing — the page must stay up.
        await runTurn(controller, provider: provider, send: "q2", events: [.sessionStarted(sessionID: "s2"), .turnCompleted(usage: nil)])
        _ = await gate.tryAcquire(provider: .claude, sessionID: "s2")
        controller.send("q3")
        await controller.turnTask?.value
        XCTAssertTrue(controller.busyElsewhere)
        XCTAssertTrue(controller.hasMessages, "q2 already rendered — but the refused q3 must not have changed state")
    }

    func testReplayTranscriptRestoresConversationOnPaneRemount() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)

        await runTurn(controller, provider: provider, send: "q1", events: [
            .sessionStarted(sessionID: "s1"),
            .assistantMessageCompleted(text: "answer one"),
            .toolUseStarted(name: "rubien_pdf_text", detail: "pages 1-2"),
            .toolUseCompleted(name: "rubien_pdf_text"),
            .providerNotice("a notice"),
            .turnCompleted(usage: nil),
        ])

        sink.calls.removeAll()  // simulate the pane being dismantled + remounted
        controller.replayTranscript()

        guard case .loadTranscript(let messages)? = sink.calls.last else {
            return XCTFail("replay should end with loadTranscript, got \(sink.calls)")
        }
        XCTAssertEqual(sink.calls.first, .reset, "replay resets the fresh WebView first")
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool, .notice])
        XCTAssertEqual(messages[0].body, "q1")
        XCTAssertEqual(messages[1].body, "answer one")
        XCTAssertTrue(messages[2].body.contains("rubien_pdf_text"), "tool rows restore from the chip JSON")
        XCTAssertEqual(messages.map(\.seq), [0, 1, 2, 3], "stable ordering")
    }

    func testReplayMidStreamReopensTheAssistantBubbleForOrdering() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)

        // Start a turn and stream partway: user rendered, a delta, a tool chip.
        controller.send("q1")
        let task = controller.turnTask
        await provider.waitUntilStreaming()
        provider.emit(.sessionStarted(sessionID: "s1"))
        provider.emit(.assistantDelta(text: "Let me check"))
        provider.emit(.toolUseStarted(name: "rubien_web_get", detail: "the article"))
        provider.emit(.toolUseCompleted(name: "rubien_web_get"))
        // Drain the buffered events (the tool chip is last, so its arrival proves
        // the delta before it processed too).
        await waitUntil { sink.calls.contains { if case .addToolChip = $0 { return true }; return false } }

        XCTAssertTrue(controller.isResponding)
        sink.calls.removeAll()  // pane toggled off then on → fresh WebView
        controller.replayTranscript()

        // Restored: reset, the committed rows (user + tool — NOT the partial delta),
        // then a re-opened bubble for the continuing stream.
        guard case .reset = sink.calls.first else { return XCTFail("expected reset first: \(sink.calls)") }
        guard case .loadTranscript(let msgs) = sink.calls[1] else { return XCTFail("expected loadTranscript: \(sink.calls)") }
        XCTAssertEqual(msgs.map(\.role), [.user, .tool], "partial deltas are not in the log; the open bubble is re-opened, not restored")
        XCTAssertEqual(sink.calls.last, .beginAssistantMessage, "the live bubble is re-opened after the restored rows")

        // The turn finishes: its commit lands in the re-opened bubble.
        provider.emit(.assistantMessageCompleted(text: "Final answer"))
        provider.finishStream()
        await task?.value
        XCTAssertTrue(sink.calls.contains(.commitAssistantMessage("Final answer")))
    }

    func testReplayIsNoOpWhenFreshAndClearedByNewConversation() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)

        controller.replayTranscript()
        XCTAssertTrue(sink.calls.isEmpty, "nothing to replay on a fresh conversation")

        await runTurn(controller, provider: provider, send: "q1", events: [.assistantMessageCompleted(text: "a"), .turnCompleted(usage: nil)])
        controller.newConversation()
        sink.calls.removeAll()
        controller.replayTranscript()
        XCTAssertTrue(sink.calls.isEmpty, "newConversation clears the render log")
    }

    func testRecheckAvailabilityReflectsProvider() async {
        let provider = MockAgentProvider(availability: .notFound(reason: "not logged in"))
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        await controller.recheckAvailability()
        XCTAssertEqual(controller.availability?.isInstalled, false)
        XCTAssertEqual(controller.availability?.unavailableReason, "not logged in")
    }
}

// MARK: - Test doubles

/// A provider whose event stream the test drives explicitly. Thread-safe via a lock
/// (`send` is a nonisolated protocol requirement).
final class MockAgentProvider: AgentProvider, @unchecked Sendable {
    let kind: AgentProviderKind
    private let lock = NSLock()
    private var _requests: [AgentTurnRequest] = []
    private var _cancelCount = 0
    private var _approvals: [(String, ApprovalDecision)] = []
    private var _availability: AgentAvailability
    private var _continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    private var _streamingWaiters: [CheckedContinuation<Void, Never>] = []

    init(kind: AgentProviderKind = .claude,
         availability: AgentAvailability = .installed(version: "test", path: "/fake/claude")) {
        self.kind = kind
        self._availability = availability
    }

    func isAvailable() async -> AgentAvailability {
        lock.lock(); defer { lock.unlock() }; return _availability
    }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            _requests.append(turn)
            _continuation = continuation
            let waiters = _streamingWaiters
            _streamingWaiters = []
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {
        lock.lock(); _approvals.append((id, decision)); lock.unlock()
    }

    func cancel() {
        lock.lock()
        _cancelCount += 1
        let continuation = _continuation
        _continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    // Test controls
    func emit(_ event: AgentEvent) {
        lock.lock(); let c = _continuation; lock.unlock(); c?.yield(event)
    }
    func finishStream() {
        lock.lock(); let c = _continuation; _continuation = nil; lock.unlock(); c?.finish()
    }
    func failStream(_ error: Error) {
        lock.lock(); let c = _continuation; _continuation = nil; lock.unlock(); c?.finish(throwing: error)
    }
    func waitUntilStreaming() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _continuation != nil { lock.unlock(); c.resume(); return }
            _streamingWaiters.append(c); lock.unlock()
        }
    }

    // Observations
    var requests: [AgentTurnRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var lastRequest: AgentTurnRequest? { requests.last }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }
    var approvals: [(String, ApprovalDecision)] { lock.lock(); defer { lock.unlock() }; return _approvals }
}

/// Records every renderer call so tests can assert the event→render mapping.
@MainActor
final class SpyTranscriptSink: ChatTranscriptSink {
    enum Call: Equatable {
        case reset
        case loadTranscript([ChatRenderMessage])
        case addUserMessage(String)
        case beginAssistantMessage
        case appendDelta(String)
        case commitAssistantMessage(String)
        case addToolChip(String, String?, ToolChipStatus)
        case addNotice(String)
        case setTheme(ChatTheme)
    }

    var calls: [Call] = []

    func reset() { calls.append(.reset) }
    func loadTranscript(_ messages: [ChatRenderMessage]) { calls.append(.loadTranscript(messages)) }
    func addUserMessage(_ markdown: String) { calls.append(.addUserMessage(markdown)) }
    func beginAssistantMessage() { calls.append(.beginAssistantMessage) }
    func appendDelta(_ text: String) { calls.append(.appendDelta(text)) }
    func commitAssistantMessage(_ markdown: String) { calls.append(.commitAssistantMessage(markdown)) }
    func addToolChip(name: String, detail: String?, status: ToolChipStatus) {
        calls.append(.addToolChip(name, detail, status))
    }
    func addNotice(_ markdown: String) { calls.append(.addNotice(markdown)) }
    func setTheme(_ mode: ChatTheme) { calls.append(.setTheme(mode)) }

    var notices: [String] { calls.compactMap { if case .addNotice(let m) = $0 { return m }; return nil } }
}
#endif
