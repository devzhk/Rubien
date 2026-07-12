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
        webAccess: Bool = true,
        initialAvailability: AgentAvailability? = .installed(version: "test", path: "/fake/claude")
    ) -> ChatSessionController {
        ChatSessionController(
            provider: provider,
            transcript: sink,
            reference: ChatReference(id: 1, title: "Attention", authors: "Vaswani et al."),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            gate: gate,
            webAccess: webAccess,
            initialAvailability: initialAvailability)
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

    /// Snapshot the two Codex default-pref keys and return a restorer, so a test
    /// exercising `selectModel`/`selectEffort` persistence can't leak into others
    /// (matches the inline save/restore idiom the switchProvider tests use for
    /// `assistantProviderKey`). Call as `let restore = …; defer { restore() }`.
    private func restoreCodexPrefsAfter() -> () -> Void {
        let d = UserDefaults.standard
        let mKey = RubienPreferences.assistantCodexModelKey
        let eKey = RubienPreferences.assistantCodexEffortKey
        let m = d.object(forKey: mKey)
        let e = d.object(forKey: eKey)
        return {
            if let m { d.set(m, forKey: mKey) } else { d.removeObject(forKey: mKey) }
            if let e { d.set(e, forKey: eKey) } else { d.removeObject(forKey: eKey) }
        }
    }

    /// A fresh Codex controller with the given model/effort seed and no catalog —
    /// tests that need a catalog call `setCatalog` on the returned provider first.
    private func makeCodexControllerRaw(
        modelOverride: String?, effortOverride: String?
    ) -> (ChatSessionController, MockAgentProvider) {
        let codex = MockAgentProvider(
            kind: .codex, availability: .installed(version: "t", path: "/fake/codex"))
        let controller = ChatSessionController(
            provider: codex, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: modelOverride, effortOverride: effortOverride,
            autoApprove: false, codexSandbox: .readOnly)
        return (controller, codex)
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

        controller.respond(to: approvalA, .allowOnce)
        XCTAssertEqual(provider.approvals.map(\.0), ["rA"])

        // Responding again to the SAME (already-answered, no-longer-queued) approval
        // — e.g. a double-click racing the state change — must be dropped.
        controller.respond(to: approvalA, .deny)
        XCTAssertEqual(provider.approvals.count, 1, "an already-answered approval must not be re-forwarded")
    }

    func testParallelApprovalsQueueInOrderAndSurfaceSequentially() {
        // The single-slot regression: two parallel prompting tools each raise a
        // request; the second must QUEUE behind the first, not overwrite it (an
        // overwritten request is never answered → claude blocks forever).
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        let g = controller.generation
        controller.handle(.approvalRequested(id: "rA", toolName: "Write", summary: "a"), gen: g)
        controller.handle(.approvalRequested(id: "rB", toolName: "Bash", summary: "b"), gen: g)

        XCTAssertEqual(controller.pendingApprovals.map(\.id), ["rA", "rB"], "both queued, arrival order")
        XCTAssertEqual(controller.pendingApproval?.id, "rA", "the card shows the head")

        controller.respond(to: controller.pendingApproval!, .allowOnce)
        XCTAssertEqual(controller.pendingApproval?.id, "rB", "answering the head surfaces the next")

        controller.respond(to: controller.pendingApproval!, .deny)
        XCTAssertTrue(controller.pendingApprovals.isEmpty)
        XCTAssertEqual(provider.approvals.map(\.0), ["rA", "rB"], "every request got exactly one answer")
    }

    func testTurnEndClearsUnansweredQueuedApprovals() async {
        // The stream ending (turn done/killed) invalidates the queued requests —
        // their process is gone, so they're dropped, not answered.
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        await runTurn(controller, provider: provider, send: "go", events: [
            .approvalRequested(id: "w1", toolName: "Write", summary: "a"),
            .approvalRequested(id: "w2", toolName: "Write", summary: "b"),
        ])
        XCTAssertTrue(controller.pendingApprovals.isEmpty, "finalize clears the queue")
        XCTAssertTrue(provider.approvals.isEmpty, "dropped, not answered")
    }

    func testNewConversationClearsQueuedApprovals() {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        let g = controller.generation
        controller.handle(.approvalRequested(id: "w1", toolName: "Write", summary: "a"), gen: g)
        controller.handle(.approvalRequested(id: "b1", toolName: "Bash", summary: "b"), gen: g)
        controller.newConversation()
        XCTAssertTrue(controller.pendingApprovals.isEmpty)
    }

    func testAllowForConversationSweepsQueuedRequestsForTheSameTool() {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        let g = controller.generation
        controller.handle(.approvalRequested(id: "w1", toolName: "Write", summary: "a.md"), gen: g)
        controller.handle(.approvalRequested(id: "w2", toolName: "Write", summary: "b.md"), gen: g)
        controller.handle(.approvalRequested(id: "b1", toolName: "Bash", summary: "ls"), gen: g)

        // Granting Write for the conversation answers the queued Write too…
        controller.respond(to: controller.pendingApproval!, .allowForConversation)
        XCTAssertEqual(provider.approvals.map(\.0), ["w1", "w2"])
        XCTAssertTrue(provider.approvals.allSatisfy { $0.1 == .allowForConversation })
        // …but the different tool still prompts.
        XCTAssertEqual(controller.pendingApproval?.id, "b1", "a different tool is NOT swept")
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
        XCTAssertTrue(sink.calls.contains(.appendDelta("Hi")))
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

    func testToolChipsRenderBeforeTheAnswerWhenToolsRunFirst() async {
        // The reader bug: claude ran its document tools BEFORE the first text,
        // but an eagerly pre-opened bubble pinned the answer ABOVE the chips.
        // Chronological order in the sink calls is the contract now.
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)

        await runTurn(controller, provider: provider, send: "summarize", events: [
            .toolUseStarted(name: "mcp__rubien__rubien_get", detail: nil),
            .toolUseCompleted(name: "mcp__rubien__rubien_get"),
            .assistantDelta(text: "The paper"),
            .assistantMessageCompleted(text: "The paper…"),
            .turnCompleted(usage: nil),
        ])

        let chipIndex = sink.calls.firstIndex { if case .addToolChip = $0 { return true }; return false }
        let deltaIndex = sink.calls.firstIndex { if case .appendDelta = $0 { return true }; return false }
        guard let chipIndex, let deltaIndex else {
            return XCTFail("expected both a chip and a delta: \(sink.calls)")
        }
        XCTAssertLessThan(chipIndex, deltaIndex, "the chip precedes the answer that used it")
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
        XCTAssertEqual(controller.stagedSelection?.text, "first passage")
        XCTAssertNil(controller.stagedSelection?.pageNumber, "a web selection carries no page")
        XCTAssertEqual(controller.composerFocusRequest, start + 1)

        // Re-Asking the identical passage still bumps the token (equality-independent
        // focus) even though `stagedSelection` is unchanged.
        controller.stageSelection("first passage")
        XCTAssertEqual(controller.stagedSelection?.text, "first passage")
        XCTAssertEqual(controller.composerFocusRequest, start + 2)

        // A PDF selection carries its 1-based page number (§5.4).
        controller.stageSelection("figure caption", pageNumber: 7)
        XCTAssertEqual(controller.stagedSelection?.pageNumber, 7)
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

    func testNewConversationAdoptsLatestSettingsDefaults() {
        // A reader stays open while the user changes Settings ▸ Assistant; "New
        // conversation" should adopt the new defaults (the reader can't be reopened
        // to pick them up because window reuse keeps the same session).
        var current = AssistantConversationDefaults(model: "opus", effort: "high", webAccess: true, autoApprove: false)
        let controller = ChatSessionController(
            provider: MockAgentProvider(), transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            gate: AssistantTurnGate(),
            webAccess: current.webAccess, modelOverride: current.model,
            effortOverride: current.effort, autoApprove: current.autoApprove,
            defaultsProvider: { _ in current })

        current = AssistantConversationDefaults(model: "sonnet", effort: "medium", webAccess: false, autoApprove: true)
        controller.newConversation()

        XCTAssertEqual(controller.modelOverride, "sonnet")
        XCTAssertEqual(controller.effortOverride, "medium")
        XCTAssertFalse(controller.webAccess)
        XCTAssertTrue(controller.autoApprove)
    }

    // MARK: Provider switch (Phase 3b-3)

    /// Switching the backend is a hard cut: it shuts down the outgoing runtime,
    /// builds the new one from the factory, starts a fresh conversation, and adopts
    /// the NEW backend's model/effort/sandbox defaults (Claude/Codex slugs differ).
    func testSwitchProviderTearsDownOldRuntimeAndAdoptsNewBackendDefaults() async {
        let savedProvider = UserDefaults.standard.object(forKey: RubienPreferences.assistantProviderKey)
        defer {
            if let savedProvider {
                UserDefaults.standard.set(savedProvider, forKey: RubienPreferences.assistantProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RubienPreferences.assistantProviderKey)
            }
        }
        RubienPreferences.assistantProvider = .claude

        let claude = MockAgentProvider(kind: .claude)
        let codex = MockAgentProvider(kind: .codex)
        let factory: (AgentProviderKind) -> any AgentProvider = { $0 == .claude ? claude : codex }
        let defaults: (AgentProviderKind) -> AssistantConversationDefaults = { kind in
            switch kind {
            case .claude:
                return AssistantConversationDefaults(model: "opus", effort: "high", webAccess: true, autoApprove: false)
            case .codex:
                return AssistantConversationDefaults(model: "gpt-5.5", effort: "medium", webAccess: false,
                                                     autoApprove: true, codexSandbox: .workspaceWrite)
            }
        }
        let controller = ChatSessionController(
            provider: claude, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: "opus", effortOverride: "high",
            autoApprove: false, codexSandbox: .readOnly,
            providerFactory: factory, defaultsProvider: defaults)
        XCTAssertEqual(controller.providerKind, .claude)
        let genBefore = controller.generation

        controller.switchProvider(to: .codex)

        XCTAssertEqual(controller.providerKind, .codex)
        XCTAssertEqual(RubienPreferences.assistantProvider, .codex)
        XCTAssertEqual(controller.modelOverride, "gpt-5.5")
        XCTAssertEqual(controller.effortOverride, "medium")
        XCTAssertFalse(controller.webAccess)
        XCTAssertTrue(controller.autoApprove)
        XCTAssertEqual(controller.codexSandbox, .workspaceWrite)
        XCTAssertEqual(claude.cancelCount, 1, "the outgoing runtime is shut down (shutdown → cancel)")
        XCTAssertGreaterThan(controller.generation, genBefore, "a fresh conversation started")
        // A turn now sends to the NEW provider, carrying the new backend's sandbox.
        await waitUntil { controller.canSendWithCurrentAvailability }
        XCTAssertTrue(controller.canSendWithCurrentAvailability)
        controller.send("hi")
        await codex.waitUntilStreaming()
        XCTAssertEqual(codex.requests.count, 1)
        XCTAssertEqual(codex.lastRequest?.codexSandbox, .workspaceWrite)
        XCTAssertTrue(claude.requests.isEmpty, "the old provider gets no turns")
        codex.finishStream()
        await controller.turnTask?.value
    }

    /// Switching to the already-active backend does nothing (no teardown, no rebuild).
    func testSwitchProviderToSameKindIsNoOp() {
        let savedProvider = UserDefaults.standard.object(forKey: RubienPreferences.assistantProviderKey)
        defer {
            if let savedProvider {
                UserDefaults.standard.set(savedProvider, forKey: RubienPreferences.assistantProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RubienPreferences.assistantProviderKey)
            }
        }
        RubienPreferences.assistantProvider = .codex

        let claude = MockAgentProvider(kind: .claude)
        var built: [AgentProviderKind] = []
        let factory: (AgentProviderKind) -> any AgentProvider = { built.append($0); return claude }
        let controller = ChatSessionController(
            provider: claude, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            providerFactory: factory)

        controller.switchProvider(to: .claude)

        XCTAssertTrue(built.isEmpty, "the factory is not invoked for a same-kind switch")
        XCTAssertEqual(claude.cancelCount, 0, "the live runtime is not torn down")
        XCTAssertEqual(controller.providerKind, .claude)
        XCTAssertEqual(RubienPreferences.assistantProvider, .codex, "same-kind no-op must not rewrite the remembered default")
    }

    /// Without a factory (tests / DEBUG harness) the backend can't be switched.
    func testSwitchProviderWithoutFactoryIsNoOp() {
        let claude = MockAgentProvider(kind: .claude)
        let controller = makeController(provider: claude, sink: SpyTranscriptSink())

        controller.switchProvider(to: .codex)

        XCTAssertEqual(controller.providerKind, .claude)
        XCTAssertEqual(claude.cancelCount, 0)
    }

    func testResumePointsNextTurnAtSessionWithoutReseeding() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)
        let summary = AgentSessionSummary(id: "sess-123", preview: "Prior chat", date: Date(timeIntervalSince1970: 0))

        controller.resume(summary)
        await controller.resumeTask?.value
        XCTAssertEqual(controller.liveSessionID, "sess-123")
        XCTAssertTrue(controller.hasMessages, "resume shows the transcript, not the start page")
        // The mock has no readable store (empty transcript) → the preview notice
        // fallback still orients the user.
        XCTAssertTrue(
            sink.calls.contains { if case .addNotice(let md) = $0 { return md.contains("Prior chat") } else { return false } },
            "a notice with the preview orients the user when the store is unreadable")

        // The resumed session already carries its seed → the next turn resumes that id
        // and does NOT re-send a seed.
        await runTurn(controller, provider: provider, send: "continue", events: [.turnCompleted(usage: nil)])
        XCTAssertEqual(provider.lastRequest?.resumeSessionID, "sess-123")
        XCTAssertNil(provider.lastRequest?.seed, "a resumed conversation must not re-seed")
    }

    func testResumeRestoresTheConversationTranscript() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)
        let history = [
            ChatRenderMessage(role: .user, body: "What is attention?", seq: 0),
            ChatRenderMessage(role: .tool, body: #"{"name":"rubien_get","status":"completed"}"#, seq: 1),
            ChatRenderMessage(role: .assistant, body: "A weighted sum.", seq: 2),
        ]
        provider.setTranscript(history, for: "sess-777")

        controller.resume(AgentSessionSummary(id: "sess-777", preview: "What is attention?", date: Date(timeIntervalSince1970: 0)))
        await controller.resumeTask?.value

        // The pane is re-rendered from the restored rows — content, not a notice.
        guard case .loadTranscript(let msgs)? = sink.calls.last else {
            return XCTFail("expected a transcript load: \(sink.calls)")
        }
        XCTAssertEqual(msgs.map(\.role), [.user, .tool, .assistant])
        XCTAssertEqual(msgs.map(\.body), history.map(\.body))
        XCTAssertFalse(sink.calls.contains { if case .addNotice = $0 { return true }; return false },
                       "no notice when the real content is restored")

        // The restored rows seed the render log, so a pane toggle replays them.
        sink.calls.removeAll()
        controller.replayTranscript()
        guard case .loadTranscript(let replayed)? = sink.calls.last else {
            return XCTFail("expected replay: \(sink.calls)")
        }
        XCTAssertEqual(replayed.map(\.body), history.map(\.body))
    }

    func testSearchSessionsForwardsToTheProviderWithTheWorkspace() async {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        let hit = AgentSessionSummary(
            id: "s1", preview: "Q", date: Date(timeIntervalSince1970: 0), matchSnippet: "…the match…")
        provider.setSearchResults([hit])

        let results = await controller.searchSessions("attention")
        XCTAssertEqual(results, [hit])
        XCTAssertEqual(provider.searches.map(\.query), ["attention"])
        XCTAssertEqual(provider.searches.map(\.limit), [25])
    }

    func testHistoryScopingPassesTheConversationsReferenceID() async {
        // "This document" scope → the provider gets THIS conversation's reference
        // id (makeController seeds id 1); unscoped → nil. Both listing and search.
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())

        _ = await controller.listRecentSessions(scopedToReference: true)
        _ = await controller.listRecentSessions()
        XCTAssertEqual(provider.recentsCalls.map(\.referenceID), [1, nil])

        _ = await controller.searchSessions("q", scopedToReference: true)
        _ = await controller.searchSessions("q")
        XCTAssertEqual(provider.searches.map(\.referenceID), [1, nil])
    }

    func testQuickSendAfterResumeStillPrependsTheRestoredHistory() async {
        // The race codex flagged: a follow-up send bumps `generation` before the
        // restore lands — the history must still prepend (same conversation),
        // keyed on `conversationEpoch`, not `generation`.
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)
        let history = [
            ChatRenderMessage(role: .user, body: "Old question", seq: 0),
            ChatRenderMessage(role: .assistant, body: "Old answer", seq: 1),
        ]
        provider.setTranscript(history, for: "sess-9")
        provider.holdTranscripts()

        controller.resume(AgentSessionSummary(id: "sess-9", preview: "Old question", date: Date(timeIntervalSince1970: 0)))
        controller.send("follow-up")
        await provider.waitUntilStreaming()  // the send's user row is rendered

        provider.releaseTranscripts()
        await controller.resumeTask?.value

        guard case .loadTranscript(let msgs)? = sink.calls.last else {
            return XCTFail("expected the merged transcript load: \(sink.calls)")
        }
        XCTAssertEqual(msgs.map(\.body), ["Old question", "Old answer", "follow-up"],
                       "history prepends the quick send's user row")

        // The still-streaming turn completes into the merged transcript.
        provider.emit(.assistantMessageCompleted(text: "Continued"))
        provider.finishStream()
        await controller.turnTask?.value
        XCTAssertTrue(sink.calls.contains(.commitAssistantMessage("Continued")))
    }

    func testRestoreIsDroppedWhenANewConversationSupersedesIt() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)
        provider.setTranscript([ChatRenderMessage(role: .user, body: "Old", seq: 0)], for: "sess-9")
        provider.holdTranscripts()

        controller.resume(AgentSessionSummary(id: "sess-9", preview: "Old", date: Date(timeIntervalSince1970: 0)))
        controller.newConversation()  // supersedes the pending restore
        sink.calls.removeAll()
        provider.releaseTranscripts()
        await controller.resumeTask?.value

        XCTAssertTrue(sink.calls.isEmpty, "a superseded restore renders nothing: \(sink.calls)")
        XCTAssertFalse(controller.hasMessages)
    }

    func testNewConversationKeepsLiveValuesWithoutADefaultsProvider() {
        let controller = ChatSessionController(
            provider: MockAgentProvider(), transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            gate: AssistantTurnGate(),
            modelOverride: "sonnet")
        controller.modelOverride = "fable"  // a per-conversation override
        controller.newConversation()
        XCTAssertEqual(controller.modelOverride, "fable", "no provider ⇒ keep the live values")
    }

    func testSilentReadToolClassification() {
        XCTAssertTrue(ChatSessionController.isSilentReadTool("mcp__rubien__rubien_get"))
        XCTAssertTrue(ChatSessionController.isSilentReadTool("mcp__rubien__rubien_pdf_info"))
        XCTAssertTrue(ChatSessionController.isSilentReadTool("ToolSearch"))
        XCTAssertTrue(ChatSessionController.isSilentReadTool("Read"))
        XCTAssertFalse(ChatSessionController.isSilentReadTool("Write"))
        XCTAssertFalse(ChatSessionController.isSilentReadTool("Edit"))
        XCTAssertFalse(ChatSessionController.isSilentReadTool("Bash"))
        XCTAssertFalse(ChatSessionController.isSilentReadTool("mcp__other__thing"),
                       "only OUR read-only content channel is auto-silent")
    }

    func testAskModeAutoApprovesReadsButStillPromptsForWrites() {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        let g = controller.generation  // Ask mode (autoApprove defaults false)

        // A read-only content-channel tool auto-runs — no card, even in Ask.
        controller.handle(.approvalRequested(id: "r1", toolName: "mcp__rubien__rubien_get", summary: ""), gen: g)
        XCTAssertNil(controller.pendingApproval, "reads must not prompt in Ask mode")
        XCTAssertEqual(provider.approvals.map(\.0), ["r1"], "the read was auto-answered")

        // A write still prompts.
        controller.handle(.approvalRequested(id: "w1", toolName: "Write", summary: "note.md"), gen: g)
        XCTAssertEqual(controller.pendingApproval?.id, "w1", "writes still show the card in Ask mode")
    }

    func testStagedSelectionIsQuotedIntoTheMessageThenCleared() async {
        let provider = MockAgentProvider()
        let sink = SpyTranscriptSink()
        let controller = makeController(provider: provider, sink: sink)
        controller.stagedSelection = .init(text: "the scaled dot-product attention")

        await runTurn(controller, provider: provider, send: "explain this", events: [.turnCompleted(usage: nil)])

        let prompt = provider.lastRequest?.prompt ?? ""
        XCTAssertTrue(prompt.contains("> the scaled dot-product attention"))
        XCTAssertTrue(prompt.contains("explain this"))
        XCTAssertFalse(prompt.contains("(p. "), "no page label without a page number")
        XCTAssertNil(controller.stagedSelection, "the staged selection is consumed by the send")
    }

    func testPDFStagedSelectionCarriesItsPageLabelIntoTheQuote() async {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())
        controller.stageSelection("multi-head attention", pageNumber: 4)

        await runTurn(controller, provider: provider, send: "what is this?", events: [.turnCompleted(usage: nil)])

        let prompt = provider.lastRequest?.prompt ?? ""
        XCTAssertTrue(prompt.contains("> multi-head attention"), "the passage is quoted")
        XCTAssertTrue(prompt.contains("> (p. 4)"), "the page label rides inside the blockquote")
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

        // Restored: reset, then the committed rows (user + tool — NOT the partial
        // delta). No pre-opened bubble: the continuing stream's next delta/commit
        // lazily opens one after the restored rows (chronological order).
        guard case .reset = sink.calls.first else { return XCTFail("expected reset first: \(sink.calls)") }
        guard case .loadTranscript(let msgs) = sink.calls[1] else { return XCTFail("expected loadTranscript: \(sink.calls)") }
        XCTAssertEqual(msgs.map(\.role), [.user, .tool], "partial deltas are not in the log")
        XCTAssertEqual(sink.calls.count, 2, "replay restores rows only — no eager bubble")

        // The turn finishes: its commit lazily opens the bubble and renders there.
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

    func testCanSendAllowsWhileCheckingButBlocksKnownUnreadyBackend() {
        let ready = makeController(provider: MockAgentProvider(), sink: SpyTranscriptSink())
        XCTAssertTrue(ready.canSendWithCurrentAvailability)

        // Unknown (probe still in flight) is allowed optimistically so the composer is
        // usable immediately; a doomed send degrades to a turn-failure notice.
        let checking = makeController(
            provider: MockAgentProvider(),
            sink: SpyTranscriptSink(),
            initialAvailability: nil)
        XCTAssertTrue(checking.canSendWithCurrentAvailability)

        // A KNOWN not-ready state still blocks send.
        let signedOut = makeController(
            provider: MockAgentProvider(),
            sink: SpyTranscriptSink(),
            initialAvailability: AgentAvailability(
                isInstalled: true,
                isAuthenticated: false,
                version: "test",
                resolvedPath: "/fake/claude",
                unavailableReason: "not signed in"))
        XCTAssertFalse(signedOut.canSendWithCurrentAvailability)
    }

    func testSendCallsProviderOptimisticallyWhileAvailabilityIsChecking() async {
        let provider = MockAgentProvider()
        let controller = makeController(
            provider: provider,
            sink: SpyTranscriptSink(),
            initialAvailability: nil)

        controller.send("hello")
        await provider.waitUntilStreaming()

        XCTAssertEqual(provider.requests.count, 1, "unknown availability sends optimistically")
        XCTAssertTrue(controller.isResponding)
        XCTAssertTrue(controller.hasMessages)

        provider.finishStream()
        await controller.turnTask?.value
    }

    func testSwitchProviderDropsStaleProbeFromOutgoingBackend() async {
        let savedProvider = UserDefaults.standard.object(forKey: RubienPreferences.assistantProviderKey)
        defer {
            if let savedProvider {
                UserDefaults.standard.set(savedProvider, forKey: RubienPreferences.assistantProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RubienPreferences.assistantProviderKey)
            }
        }
        let claude = MockAgentProvider(
            kind: .claude, availability: .installed(version: "c", path: "/fake/claude"))
        let codex = MockAgentProvider(
            kind: .codex, availability: .notFound(reason: "Codex not installed"))
        claude.holdAvailability()  // the outgoing backend's probe will land late
        let controller = ChatSessionController(
            provider: claude,
            transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "Attention", authors: "Vaswani et al."),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            gate: AssistantTurnGate(),
            providerFactory: { (kind: AgentProviderKind) in kind == .codex ? codex : claude },
            initialAvailability: nil)

        // Start the slow Claude probe and park it mid-flight.
        let staleProbe = Task { await controller.recheckAvailability() }
        await claude.waitUntilAvailabilityProbing()

        // Switch to Codex; its fast probe lands notFound.
        controller.switchProvider(to: .codex)
        await waitUntil { controller.availability?.isInstalled == false }
        XCTAssertEqual(controller.providerKind, .codex)

        // Let the stale Claude "ready" probe finally return — it must be dropped, not
        // overwrite Codex's notFound.
        claude.releaseAvailability()
        await staleProbe.value

        XCTAssertEqual(controller.providerKind, .codex)
        XCTAssertFalse(
            controller.availability?.isReady ?? true,
            "a stale probe of the outgoing backend must not clobber the new backend's availability")
    }

    func testSupersededTurnBailsAfterGateAcquireWithoutRenderingOrDispatching() async {
        let provider = MockAgentProvider()
        let controller = makeController(provider: provider, sink: SpyTranscriptSink())

        controller.send("hello")       // schedules the turn at the current generation
        controller.newConversation()   // supersedes it (bumps generation) before its body runs
        await controller.turnTask?.value

        XCTAssertTrue(provider.requests.isEmpty, "a superseded turn must not dispatch to the provider")
        XCTAssertFalse(controller.hasMessages, "a superseded turn must not render into the fresh conversation")
        XCTAssertFalse(controller.isResponding)
    }

    func testSendDoesNotCallProviderWhenBackendIsSignedOut() {
        let provider = MockAgentProvider()
        let controller = makeController(
            provider: provider,
            sink: SpyTranscriptSink(),
            initialAvailability: AgentAvailability(
                isInstalled: true,
                isAuthenticated: false,
                version: "test",
                resolvedPath: "/fake/claude",
                unavailableReason: "not signed in"))

        controller.send("hello")

        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertFalse(controller.isResponding)
        XCTAssertFalse(controller.hasMessages)
    }

    // MARK: Model auto-discovery (catalog + selection)

    private func makeCodexController(
        catalog: CodexCatalog?,
        defaults: ((AgentProviderKind) -> AssistantConversationDefaults)? = nil
    ) -> (ChatSessionController, MockAgentProvider) {
        let codex = MockAgentProvider(
            kind: .codex, availability: .installed(version: "t", path: "/fake/codex"))
        codex.setCatalog(catalog)
        let controller = ChatSessionController(
            provider: codex, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: nil, effortOverride: "medium",
            autoApprove: false, codexSandbox: .readOnly,
            defaultsProvider: defaults)
        return (controller, codex)
    }

    func testRefreshCodexCatalogPopulatesVisibleModels() async {
        let terra = CodexModelInfo(
            id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                      CodexEffortInfo(value: "ultra", label: "Ultra", description: nil)],
            defaultEffort: "medium", isDefault: false, hidden: false)
        let ghost = CodexModelInfo(
            id: "ghost", displayName: "Ghost", description: nil,
            efforts: [], defaultEffort: nil, isDefault: false, hidden: true)
        let (controller, _) = makeCodexController(
            catalog: CodexCatalog(models: [terra, ghost], fetchedOK: true))

        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }

        XCTAssertEqual(controller.codexModels.map(\.id), ["gpt-5.6-terra"], "hidden models dropped")
        // The unset conversation seeds onto the first discovered model, which then
        // governs the effort list (no separate `.modelResolved` needed anymore).
        XCTAssertEqual(controller.modelOverride, "gpt-5.6-terra",
                       "discovery seeds the first model when none is pinned")
        XCTAssertEqual(controller.governingCodexModel?.id, "gpt-5.6-terra",
                       "the seeded model governs the effort list")
    }

    func testCatalogFailureLeavesModelsEmpty() async {
        let (controller, _) = makeCodexController(catalog: .unavailable)
        controller.refreshCodexCatalog()
        // Degrades to the empty list — the picker then shows only a pin (if any) and
        // nothing is seeded, which works on ANY codex (spec §4.7).
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.codexModels.isEmpty)
        XCTAssertNil(controller.modelOverride, "no catalog ⇒ nothing to seed")
    }

    // MARK: Seed + remember (concrete-model default UX)

    /// Discovery seeds a pref-less conversation onto the first concrete model and
    /// its default effort once the catalog lands (the "First available" behavior).
    func testCatalogLoadSeedsFirstModelWhenUnset() async {
        let first = CodexModelInfo(
            id: "gpt-5.6-terra", displayName: "Terra", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                      CodexEffortInfo(value: "medium", label: "Medium", description: nil)],
            defaultEffort: "medium", isDefault: false, hidden: false)
        let second = CodexModelInfo(
            id: "gpt-5.6-sol", displayName: "Sol", description: nil,
            efforts: [], defaultEffort: "low", isDefault: true, hidden: false)
        let (controller, codex) = makeCodexControllerRaw(modelOverride: nil, effortOverride: nil)
        codex.setCatalog(CodexCatalog(models: [first, second], fetchedOK: true))

        controller.refreshCodexCatalog()
        await waitUntil { controller.modelOverride != nil }

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-terra",
                       "an unset conversation seeds to the first discovered model")
        XCTAssertEqual(controller.effortOverride, "medium",
                       "effort seeds to the seeded model's default")
    }

    /// A set pin (a remembered pick already loaded into the conversation) is NOT
    /// clobbered by the first-model seed when the catalog lands.
    func testCatalogLoadDoesNotOverrideAPinnedModel() async {
        let first = CodexModelInfo(
            id: "gpt-5.6-terra", displayName: "Terra", description: nil,
            efforts: [], defaultEffort: "medium", isDefault: false, hidden: false)
        let sol = CodexModelInfo(
            id: "gpt-5.6-sol", displayName: "Sol", description: nil,
            efforts: [], defaultEffort: "low", isDefault: true, hidden: false)
        let (controller, codex) = makeCodexControllerRaw(
            modelOverride: "gpt-5.6-sol", effortOverride: "low")
        codex.setCatalog(CodexCatalog(models: [first, sol], fetchedOK: true))

        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-sol",
                       "a set pin (remembered pick) is not overwritten by the first-model seed")
    }

    /// The gap the "New conversation" button left: a never-picked user (nil model
    /// default) who clicks New conversation once the catalog is ALREADY loaded must be
    /// re-seeded onto a concrete model synchronously — not dropped to a blank picker
    /// until some later fetch. `newConversation` re-reads a nil-model default, so the
    /// tail `seedCodexModelIfUnset()` is what closes it.
    func testNewConversationSeedsFirstModelWhenCatalogLoaded() async {
        let first = CodexModelInfo(
            id: "gpt-5.6-terra", displayName: "Terra", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                      CodexEffortInfo(value: "medium", label: "Medium", description: nil)],
            defaultEffort: "medium", isDefault: false, hidden: false)
        let second = CodexModelInfo(
            id: "gpt-5.6-sol", displayName: "Sol", description: nil,
            efforts: [], defaultEffort: "low", isDefault: true, hidden: false)
        // A never-picked user: Settings hands back a nil model (no remembered pick).
        let nilModelDefaults: (AgentProviderKind) -> AssistantConversationDefaults = { _ in
            AssistantConversationDefaults(model: nil, effort: nil, webAccess: true, autoApprove: false)
        }
        let (controller, _) = makeCodexController(
            catalog: CodexCatalog(models: [first, second], fetchedOK: true),
            defaults: nilModelDefaults)

        // The catalog lands and seeds the first model (the existing fetch behavior).
        controller.refreshCodexCatalog()
        await waitUntil { controller.modelOverride != nil }
        XCTAssertEqual(controller.modelOverride, "gpt-5.6-terra", "the initial catalog fetch seeds")

        // Simulate the never-picked New-conversation state: the catalog is already
        // loaded but nothing is pinned. Without the tail seed in `newConversation` this
        // would stay nil (a blank picker) — the discriminator for this fix.
        controller.modelOverride = nil
        controller.newConversation()

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-terra",
                       "New conversation re-seeds the first model synchronously when the catalog is loaded")
        XCTAssertEqual(controller.effortOverride, "medium",
                       "effort seeds to the seeded model's default too")
    }

    /// Picking a Codex model persists it as the remembered default; a Claude pick
    /// is a live per-conversation choice and must NOT touch the Codex pref.
    func testSelectModelPersistsPick() {
        let restore = restoreCodexPrefsAfter()
        defer { restore() }
        let (controller, _) = makeCodexControllerRaw(modelOverride: nil, effortOverride: "medium")

        controller.selectModel("gpt-5.6-sol")

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-sol")
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-5.6-sol",
                       "picking a Codex model remembers it as the default")

        // Claude model picks are live per-conversation — not remembered in the Codex pref.
        let before = RubienPreferences.assistantCodexModel
        let claude = ChatSessionController(
            provider: MockAgentProvider(kind: .claude), transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate())
        claude.selectModel("sonnet")
        XCTAssertEqual(claude.modelOverride, "sonnet")
        XCTAssertEqual(RubienPreferences.assistantCodexModel, before,
                       "a Claude model pick must not touch the Codex default")
    }

    /// Picking a Codex effort persists it; a Claude effort pick must not.
    func testSelectEffortPersistsPick() {
        let restore = restoreCodexPrefsAfter()
        defer { restore() }
        let (controller, _) = makeCodexControllerRaw(modelOverride: nil, effortOverride: "medium")

        controller.selectEffort("high")

        XCTAssertEqual(controller.effortOverride, "high")
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "high",
                       "picking a Codex effort remembers it as the default")

        // Claude effort is a live per-conversation choice — not remembered here.
        let before = RubienPreferences.assistantCodexEffort
        let claude = ChatSessionController(
            provider: MockAgentProvider(kind: .claude), transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate())
        claude.selectEffort("low")
        XCTAssertEqual(claude.effortOverride, "low")
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, before,
                       "a Claude effort pick must not touch the Codex default")
    }

    func testSelectModelSnapsEffortToModelDefault() async {
        let restore = restoreCodexPrefsAfter()
        defer { restore() }
        let alpha = CodexModelInfo(
            id: "gpt-5.6-alpha", displayName: "Alpha", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                      CodexEffortInfo(value: "xhigh", label: "xHigh", description: nil)],
            defaultEffort: "xhigh", isDefault: false, hidden: false)
        let sol = CodexModelInfo(
            id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil)],
            defaultEffort: "low", isDefault: false, hidden: false)
        let (controller, _) = makeCodexController(
            catalog: CodexCatalog(models: [alpha, sol], fetchedOK: true))
        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }
        // Discovery seeded the first model (alpha); pick the OTHER model and confirm
        // effort snaps to ITS default.
        controller.effortOverride = "xhigh"

        controller.selectModel("gpt-5.6-sol")

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-sol")
        XCTAssertEqual(controller.effortOverride, "low",
                       "an explicit pick snaps effort to the model's defaultReasoningEffort (spec §3)")
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-5.6-sol", "the pick is remembered")
    }

    /// A model offering the full effort ladder EXCEPT `ultra` — the shape that makes
    /// a persisted `ultra` (valid for sol/terra) unsupported once luna governs.
    private func makeLuna() -> CodexModelInfo {
        CodexModelInfo(
            id: "luna", displayName: "Luna", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                      CodexEffortInfo(value: "medium", label: "Medium", description: nil),
                      CodexEffortInfo(value: "high", label: "High", description: nil),
                      CodexEffortInfo(value: "xhigh", label: "xHigh", description: nil),
                      CodexEffortInfo(value: "max", label: "Max", description: nil)],
            defaultEffort: "medium", isDefault: false, hidden: false)
    }

    /// When the resolved codex-default model becomes known (`.modelResolved`), an
    /// effort the model can't accept is snapped to its default — codex's app-server
    /// rejects an unsupported effort on turn/start. A still-valid effort is untouched.
    func testModelResolvedSnapsUnsupportedEffort() async {
        let luna = makeLuna()
        let (controller, _) = makeCodexController(
            catalog: CodexCatalog(models: [luna], fetchedOK: true))
        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }

        // `ultra` persisted for another model; luna lacks it → snap to luna's default.
        controller.effortOverride = "ultra"
        controller.handle(.modelResolved(model: "luna"), gen: controller.generation)
        XCTAssertEqual(controller.effortOverride, "medium",
                       "an unsupported effort snaps to the resolved model's default")

        // A supported effort is NOT overridden.
        controller.effortOverride = "high"
        controller.handle(.modelResolved(model: "luna"), gen: controller.generation)
        XCTAssertEqual(controller.effortOverride, "high", "a valid effort is left alone")
    }

    /// The other entry point: a PINNED model whose efforts are unknown until the
    /// catalog loads. Once it does, an unsupported persisted effort is snapped.
    func testCatalogLoadSnapsUnsupportedEffortForPinnedModel() async {
        let luna = makeLuna()
        let (controller, _) = makeCodexController(
            catalog: CodexCatalog(models: [luna], fetchedOK: true))
        controller.modelOverride = "luna"    // pinned — governs the effort list
        controller.effortOverride = "ultra"  // persisted for another model; luna lacks it

        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }

        XCTAssertEqual(controller.effortOverride, "medium",
                       "the catalog load snaps a pinned model's unsupported effort to its default")
    }

    /// The Codex model is THREAD-scoped (spec §2.3): changing it once the
    /// conversation has content starts a fresh conversation — preserving the pick
    /// AND the live conversation's own settings. A `defaultsProvider` with
    /// CONFLICTING values proves the reset does not re-apply Settings defaults
    /// the way `newConversation()` would (plan-review #3).
    func testCodexModelChangeMidConversationStartsNewConversationPreservingSettings() async {
        let restore = restoreCodexPrefsAfter()
        defer { restore() }
        let conflictingDefaults: (AgentProviderKind) -> AssistantConversationDefaults = { _ in
            AssistantConversationDefaults(model: nil, effort: "medium",
                                          webAccess: true, autoApprove: false)
        }
        let (controller, codex) = makeCodexController(
            catalog: .unavailable, defaults: conflictingDefaults)
        controller.webAccess = false
        controller.autoApprove = true
        controller.effortOverride = "xhigh"
        await waitUntil { controller.canSendWithCurrentAvailability }
        controller.send("hi")
        await codex.waitUntilStreaming()
        codex.emit(.sessionStarted(sessionID: "TH-1"))
        codex.finishStream()
        await controller.turnTask?.value
        XCTAssertTrue(controller.hasMessages)
        XCTAssertEqual(controller.liveSessionID, "TH-1")
        let genBefore = controller.generation

        controller.selectModel("gpt-5.6-sol")

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-sol", "the pick survives the reset")
        XCTAssertNil(controller.liveSessionID, "a fresh conversation — the old thread's model was fixed")
        XCTAssertGreaterThan(controller.generation, genBefore)
        XCTAssertTrue(controller.hasMessages, "the pane shows the reset notice, not the quick-start page")
        // The LIVE conversation's choices survive — this is NOT a provider switch,
        // so the conflicting Settings defaults must NOT have been re-applied.
        XCTAssertFalse(controller.webAccess)
        XCTAssertTrue(controller.autoApprove)
        XCTAssertEqual(controller.effortOverride, "xhigh",
                       "catalog empty ⇒ no defaultEffort known ⇒ effort preserved")
        // Re-selecting the SAME model is a no-op (no gratuitous reset).
        let genAfter = controller.generation
        controller.selectModel("gpt-5.6-sol")
        XCTAssertEqual(controller.generation, genAfter)
    }

    func testClaudeModelChangeMidConversationKeepsConversation() async {
        let claude = MockAgentProvider(kind: .claude)
        let controller = ChatSessionController(
            provider: claude, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: "opus", effortOverride: "high",
            autoApprove: false, codexSandbox: .readOnly)
        await waitUntil { controller.canSendWithCurrentAvailability }
        controller.send("hi")
        await claude.waitUntilStreaming()
        claude.emit(.sessionStarted(sessionID: "S-1"))
        claude.finishStream()
        await controller.turnTask?.value

        controller.selectModel("sonnet")

        XCTAssertEqual(controller.modelOverride, "sonnet")
        XCTAssertEqual(controller.liveSessionID, "S-1", "Claude models switch per turn — same conversation")
        XCTAssertTrue(controller.hasMessages)
    }

    func testResolvedModelClearedOnNewConversationAndCatalogClearedOnSwitchToClaude() async {
        let claude = MockAgentProvider(kind: .claude)
        let (controller, _) = makeCodexControllerWithFactory(claude: claude)
        controller.handle(.modelResolved(model: "gpt-5.6-terra"), gen: controller.generation)
        XCTAssertEqual(controller.resolvedModel, "gpt-5.6-terra")

        controller.newConversation()
        XCTAssertNil(controller.resolvedModel, "a fresh thread's resolution is unknown until thread/start")

        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }
        controller.switchProvider(to: .claude)
        XCTAssertTrue(controller.codexModels.isEmpty, "the catalog is Codex state; cleared on switch")
    }

    /// The `catalogFetchToken` analog of `testSwitchProviderDropsStaleProbeFromOutgoingBackend`:
    /// a codex model-list fetch parked mid-flight when a switch to Claude bumps the
    /// token must be dropped on return, not repopulate `codexModels` once Claude is
    /// the live backend.
    func testRefreshCodexCatalogDropsStaleFetchAfterProviderSwitch() async {
        let savedProvider = UserDefaults.standard.object(forKey: RubienPreferences.assistantProviderKey)
        defer {
            if let savedProvider {
                UserDefaults.standard.set(savedProvider, forKey: RubienPreferences.assistantProviderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RubienPreferences.assistantProviderKey)
            }
        }
        let claude = MockAgentProvider(kind: .claude)
        let (controller, codex) = makeCodexControllerWithFactory(claude: claude)
        codex.holdCatalog()  // the pre-switch codex fetch will land late

        // Start the slow codex catalog fetch and park it mid-flight, holding the
        // pre-switch token.
        controller.refreshCodexCatalog()
        await codex.waitUntilCatalogProbing()

        // Switch to Claude: catalogFetchToken bumps, and refreshCodexCatalog's
        // Claude-side call synchronously clears codexModels (Claude has no catalog).
        controller.switchProvider(to: .claude)
        XCTAssertEqual(controller.providerKind, .claude)

        // Let the stale codex fetch finally return — it must be dropped by the
        // token guard, not overwrite codexModels now that Claude is live.
        codex.releaseCatalog()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(
            controller.codexModels.isEmpty,
            "a stale catalog fetch from the outgoing codex backend must not repopulate codexModels")
    }

    /// Controller wired with a factory so switchProvider works (mirrors the
    /// existing switch test's shape at line ~392).
    private func makeCodexControllerWithFactory(
        claude: MockAgentProvider
    ) -> (ChatSessionController, MockAgentProvider) {
        let codex = MockAgentProvider(kind: .codex)
        codex.setCatalog(CodexCatalog(
            models: [CodexModelInfo(id: "m", displayName: "M", description: nil,
                                    efforts: [], defaultEffort: nil, isDefault: false, hidden: false)],
            fetchedOK: true))
        let controller = ChatSessionController(
            provider: codex, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: nil, effortOverride: "medium",
            autoApprove: false, codexSandbox: .readOnly,
            providerFactory: { kind in kind == .claude ? claude : codex })
        return (controller, codex)
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
    private var _availabilityHold = false
    private var _availabilityReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var _availabilityProbeWaiters: [CheckedContinuation<Void, Never>] = []
    private var _continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    private var _streamingWaiters: [CheckedContinuation<Void, Never>] = []
    private var _transcripts: [String: [ChatRenderMessage]] = [:]
    private var _transcriptHold = false
    private var _transcriptWaiters: [CheckedContinuation<Void, Never>] = []
    private var _searches: [(query: String, limit: Int, referenceID: Int64?)] = []
    private var _searchResults: [AgentSessionSummary] = []
    private var _recentsCalls: [(limit: Int, referenceID: Int64?)] = []
    private var _catalog: CodexCatalog?
    private var _catalogHold = false
    private var _catalogReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var _catalogProbeWaiters: [CheckedContinuation<Void, Never>] = []

    func setCatalog(_ catalog: CodexCatalog?) {
        lock.lock(); defer { lock.unlock() }; _catalog = catalog
    }

    func availableModels() async -> CodexCatalog? {
        // Park when held so a test can interleave a provider switch before this
        // fetch returns (mirrors the availability-hold pattern below).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _catalogHold {
                _catalogReleaseWaiters.append(cont)
                let probeWaiters = _catalogProbeWaiters
                _catalogProbeWaiters = []
                lock.unlock()
                for waiter in probeWaiters { waiter.resume() }
            } else {
                lock.unlock()
                cont.resume()
            }
        }
        lock.lock(); defer { lock.unlock() }; return _catalog
    }

    /// Make `availableModels` block until `releaseCatalog()`.
    func holdCatalog() {
        lock.lock(); defer { lock.unlock() }; _catalogHold = true
    }

    func releaseCatalog() {
        lock.lock()
        _catalogHold = false
        let waiters = _catalogReleaseWaiters
        _catalogReleaseWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Await until a held `availableModels()` call has entered and parked.
    func waitUntilCatalogProbing() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !_catalogReleaseWaiters.isEmpty {
                lock.unlock(); c.resume(); return
            }
            _catalogProbeWaiters.append(c); lock.unlock()
        }
    }

    init(kind: AgentProviderKind = .claude,
         availability: AgentAvailability = .installed(version: "test", path: "/fake/claude")) {
        self.kind = kind
        self._availability = availability
    }

    func isAvailable() async -> AgentAvailability {
        // Park when held so a test can interleave a switch before this probe returns
        // (mirrors the transcript-hold pattern below).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _availabilityHold {
                _availabilityReleaseWaiters.append(cont)
                let probeWaiters = _availabilityProbeWaiters
                _availabilityProbeWaiters = []
                lock.unlock()
                for waiter in probeWaiters { waiter.resume() }
            } else {
                lock.unlock()
                cont.resume()
            }
        }
        lock.lock(); defer { lock.unlock() }; return _availability
    }

    /// Make `isAvailable` block until `releaseAvailability()`.
    func holdAvailability() {
        lock.lock(); defer { lock.unlock() }; _availabilityHold = true
    }

    func releaseAvailability() {
        lock.lock()
        _availabilityHold = false
        let waiters = _availabilityReleaseWaiters
        _availabilityReleaseWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Await until a held `isAvailable()` call has entered and parked.
    func waitUntilAvailabilityProbing() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !_availabilityReleaseWaiters.isEmpty {
                lock.unlock(); c.resume(); return
            }
            _availabilityProbeWaiters.append(c); lock.unlock()
        }
    }

    func setTranscript(_ rows: [ChatRenderMessage], for sessionID: String) {
        lock.lock(); defer { lock.unlock() }; _transcripts[sessionID] = rows
    }

    /// Make `sessionTranscript` block until `releaseTranscripts()` — lets tests
    /// interleave a send with an in-flight resume restore.
    func holdTranscripts() {
        lock.lock(); defer { lock.unlock() }; _transcriptHold = true
    }

    func releaseTranscripts() {
        lock.lock()
        _transcriptHold = false
        let waiters = _transcriptWaiters
        _transcriptWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage] {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _transcriptHold {
                _transcriptWaiters.append(cont)
                lock.unlock()
            } else {
                lock.unlock()
                cont.resume()
            }
        }
        lock.lock(); defer { lock.unlock() }; return _transcripts[sessionID] ?? []
    }

    func setSearchResults(_ results: [AgentSessionSummary]) {
        lock.lock(); defer { lock.unlock() }; _searchResults = results
    }

    func searchSessions(query: String, workspaceURL: URL, limit: Int, referenceID: Int64?) async -> [AgentSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        _searches.append((query, limit, referenceID))
        return _searchResults
    }

    var searches: [(query: String, limit: Int, referenceID: Int64?)] {
        lock.lock(); defer { lock.unlock() }; return _searches
    }

    func recentSessions(workspaceURL: URL, limit: Int, referenceID: Int64?) async -> [AgentSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        _recentsCalls.append((limit, referenceID))
        return []
    }

    var recentsCalls: [(limit: Int, referenceID: Int64?)] {
        lock.lock(); defer { lock.unlock() }; return _recentsCalls
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
        case addUserPayload(ChatUserMessagePayload)
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
    func addUserMessage(_ payload: ChatUserMessagePayload) { calls.append(.addUserPayload(payload)) }
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
