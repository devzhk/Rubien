#if os(macOS)
import Foundation
import Combine

// MARK: - Renderer seam
//
// The controller drives the transcript through this narrow protocol rather than the
// concrete WebKit `ChatTranscriptController`, so its turn/event logic is unit-tested
// with a spy (no WKWebView). `ChatTranscriptController`'s methods already match.

@MainActor
protocol ChatTranscriptSink: AnyObject {
    func reset()
    func loadTranscript(_ messages: [ChatRenderMessage])
    func addUserMessage(_ markdown: String)
    func beginAssistantMessage()
    func appendDelta(_ text: String)
    func commitAssistantMessage(_ markdown: String)
    func addToolChip(name: String, detail: String?, status: ToolChipStatus)
    func addNotice(_ markdown: String)
    func setTheme(_ mode: ChatTheme)
}

extension ChatTranscriptController: ChatTranscriptSink {}

// MARK: - Conversation defaults

/// A snapshot of the user's Assistant defaults (Settings ▸ Assistant) applied to a
/// FRESH conversation: model / effort / web / approval. A new reader window reads
/// these at construction; `newConversation()` re-reads them (via an injected
/// provider) so a changed default is adopted in an open window without reopening it.
struct AssistantConversationDefaults: Equatable {
    var model: String?
    var effort: String?
    var webAccess: Bool
    var autoApprove: Bool
}

// MARK: - Per-window chat session controller (Phase 2c)
//
// One per reader window. Owns the conversation's in-memory state (nothing is
// persisted — D5), maps a turn's `AgentEvent` stream onto the transcript renderer,
// gates concurrent resume-turns across windows, and surfaces approval + availability
// to the view. The provider (Phase 2a) and the renderer (Phase 1) are injected.

@MainActor
final class ChatSessionController: ObservableObject {

    /// A pending Claude approval (control protocol). When non-nil the view shows a
    /// native approval card above the composer.
    struct PendingApproval: Equatable {
        let id: String
        let toolName: String
        let summary: String
    }

    // MARK: Published UI state
    @Published private(set) var isResponding = false
    @Published private(set) var pendingApproval: PendingApproval?
    @Published var webAccess: Bool
    @Published private(set) var availability: AgentAvailability?
    @Published private(set) var statusText: String?
    /// The requested resume session is busy in another window (§4.1) — the composer
    /// surfaces this instead of forking the session file.
    @Published private(set) var busyElsewhere = false
    /// False until the first message renders — the sidebar shows the quick-start
    /// page while false. A gate-refused turn renders nothing, so it stays false.
    @Published private(set) var hasMessages = false
    /// A quoted selection staged from "Ask" (2c-4), shown as a chip and prepended as
    /// a `> …` block on the next send.
    @Published var stagedSelection: String?
    /// Bumped by `stageSelection` to ask the composer to take focus (Selection→Ask,
    /// §5.4). A monotonic token, not the selection string: re-Asking the *identical*
    /// passage must still re-focus, which an equality-based observer on
    /// `stagedSelection` would miss. Never reset (its absolute value is meaningless).
    @Published private(set) var composerFocusRequest = 0
    /// The conversation's model, applied per turn (`--model`). Claude aliases:
    /// `fable` / `opus` / `sonnet` / `haiku`. The sidebar always shows a concrete
    /// model (no "CLI default" state); `nil` remains valid programmatically and
    /// simply omits the flag.
    @Published var modelOverride: String?
    /// The conversation's reasoning effort, applied per turn (Claude `--effort`
    /// low/medium/high/xhigh/max). `nil` omits the flag.
    @Published var effortOverride: String?
    /// When true, tool-use approval requests are accepted automatically (no card).
    /// Default false — the soft-boundary "Ask" mode where writes prompt via the
    /// control protocol (D6). A per-conversation choice; reads/search stay silent
    /// either way.
    @Published var autoApprove = false

    // MARK: Collaborators (injected)
    private let provider: any AgentProvider
    private let transcript: any ChatTranscriptSink
    private let gate: AssistantTurnGate
    private let reference: ChatReference
    private let workspaceURL: URL
    /// Re-reads the user's Assistant defaults (Settings) when a fresh conversation
    /// starts, so changing a default + hitting "New conversation" adopts it without
    /// reopening the window. nil (tests / DEBUG harness) ⇒ `newConversation` keeps
    /// the current live values.
    private let defaultsProvider: (() -> AssistantConversationDefaults)?

    // MARK: In-memory conversation state (never persisted — D5)
    /// The live provider session id. Captured from EVERY `.sessionStarted` because it
    /// **rotates each resume turn** (D5 / Risk #5); always resume the latest.
    private(set) var liveSessionID: String?
    /// The seed is applied on the first turn only. Set once a `.sessionStarted` proves
    /// the seed-bearing process actually started (NOT at send time — else a first turn
    /// that fails before spawning would drop the reference context on the retry).
    private var seedSent = false
    /// The in-flight turn (exposed read-only so tests can await it).
    private(set) var turnTask: Task<Void, Never>?
    /// `toolUseStarted` details per tool name, FIFO — the single chip emitted on a
    /// tool's terminal event pops the oldest (the renderer's `addToolChip` is add-only,
    /// and events carry no tool-use id to match started↔completed exactly).
    private var toolDetails: [String: [String?]] = [:]
    /// The render-only transcript log (D5: in-memory, per-window, never persisted).
    /// Toggling the sidebar pane dismantles its WKWebView — `replayTranscript()`
    /// restores the visible transcript from this log when the pane remounts.
    private var renderLog: [ChatRenderMessage] = []
    private var renderSeq = 0
    /// Bumped by `send` / `newConversation` to invalidate a superseded turn's late
    /// events + finalization (the stale-turn guard, §4.1): a drained old stream must
    /// not corrupt a fresh conversation's state or clobber a newer turn.
    private(set) var generation = 0

    var providerKind: AgentProviderKind { provider.kind }

    init(
        provider: any AgentProvider,
        transcript: any ChatTranscriptSink,
        reference: ChatReference,
        workspaceURL: URL,
        gate: AssistantTurnGate = .shared,
        webAccess: Bool = true,
        modelOverride: String? = "opus",
        effortOverride: String? = "high",
        autoApprove: Bool = false,
        defaultsProvider: (() -> AssistantConversationDefaults)? = nil
    ) {
        self.provider = provider
        self.transcript = transcript
        self.reference = reference
        self.workspaceURL = workspaceURL
        self.gate = gate
        self.webAccess = webAccess
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
        self.autoApprove = autoApprove
        self.defaultsProvider = defaultsProvider
    }

    // MARK: Turn lifecycle

    /// Send a user turn. No-ops on empty input or while a turn is already running.
    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }

        generation += 1
        let gen = generation
        isResponding = true
        statusText = "Responding…"
        busyElsewhere = false

        // The pre-turn id is both the `--resume` target and the gate key; nil for a
        // fresh conversation (unkeyed, always admitted).
        let resumeID = liveSessionID
        let composed = composeUserMessage(text)
        let request = AgentTurnRequest(
            workspaceURL: workspaceURL,
            resumeSessionID: resumeID,
            prompt: composed,
            seed: seedSent ? nil : AssistantContext.seed(for: reference),
            webAccess: webAccess,
            codexSandbox: .readOnly,
            modelOverride: modelOverride,
            effortOverride: effortOverride)
        let kind = provider.kind

        turnTask = Task { [weak self] in
            guard let self else { return }
            // Serialize resume-turns across windows (§4.1). On refusal, DON'T render
            // the user message — the turn never happened (keep the staged selection so
            // a retry still carries it).
            guard await self.gate.tryAcquire(provider: kind, sessionID: resumeID) else {
                self.refuseTurn(gen: gen)
                return
            }
            self.hasMessages = true
            self.renderUserMessage(composed)
            self.stagedSelection = nil
            self.transcript.beginAssistantMessage()
            do {
                for try await event in self.provider.send(turn: request) {
                    self.handle(event, gen: gen)
                }
            } catch {
                if gen == self.generation {
                    self.renderNotice("The assistant turn failed: \(error.localizedDescription)")
                }
            }
            // Release BEFORE the task completes, so awaiting `turnTask` guarantees the
            // slot is free (a fire-and-forget release could race the next acquire).
            await self.gate.release(provider: kind, sessionID: resumeID)
            self.finalize(gen: gen)
        }
    }

    /// Stage a reader selection as a quoted chip and ask the composer to focus
    /// (Selection→Ask, §5.4). The text is consumed as a `> …` block on the next
    /// send; no auto-send. Bumps `composerFocusRequest` so focus is requested on
    /// every Ask, even when the same passage is re-selected.
    func stageSelection(_ text: String) {
        stagedSelection = text
        composerFocusRequest += 1
    }

    /// Stop the running turn (process-group kill via the provider); the stream ends,
    /// which finalizes the turn. Stays in the same conversation.
    func stop() {
        guard isResponding else { return }
        provider.cancel()
        renderNotice("_Interrupted._")
    }

    /// Window teardown (reader closing): kill any in-flight turn's process group
    /// without touching the (about-to-vanish) transcript. The running turn task
    /// holds `self` strongly until its stream ends, so this must be called
    /// explicitly — deinit would fire too late.
    func teardown() {
        provider.cancel()
    }

    /// Re-render the conversation into a freshly-(re)mounted transcript pane from
    /// the in-memory log (toggling the pane dismantles + recreates its WebView).
    /// No-op for a fresh, idle conversation.
    func replayTranscript() {
        guard !renderLog.isEmpty || isResponding else { return }
        transcript.reset()
        transcript.loadTranscript(renderLog)
        // If a turn was streaming when the pane was toggled, its open assistant
        // bubble + partial deltas lived only in the dismantled WebView, not the log
        // (deltas aren't logged — only the commit is). Re-open a bubble so the
        // continuing stream lands AFTER the restored rows (the correct position);
        // the turn's final `assistantMessageCompleted` replaces it with the full
        // authoritative text.
        if isResponding {
            transcript.beginAssistantMessage()
        }
    }

    /// The reset shared by `newConversation` and `resume` (§4.1): cancel any live turn,
    /// bump the stale-turn `generation` so the old turn's still-draining events +
    /// finalization can't corrupt the fresh state (its awaited gate release still runs
    /// — no slot leak), and clear all transcript + turn UI state. Callers then set the
    /// session-identity fields (`liveSessionID` / `seedSent` / `hasMessages`) and their
    /// own tail (adopt defaults, or render a notice).
    private func resetConversationState() {
        provider.cancel()
        generation += 1
        transcript.reset()
        toolDetails.removeAll()
        renderLog.removeAll()
        renderSeq = 0
        isResponding = false
        statusText = nil
        busyElsewhere = false
        pendingApproval = nil
        stagedSelection = nil
    }

    /// Start a fresh conversation: reset, drop the session identity, and adopt the
    /// latest Settings ▸ Assistant defaults (so a default changed while a reader is
    /// open takes effect here; a live conversation keeps its own values). Defaults
    /// re-read is a no-op when the provider is unset (tests / DEBUG harness).
    func newConversation() {
        resetConversationState()
        liveSessionID = nil
        seedSent = false
        hasMessages = false
        if let defaults = defaultsProvider?() {
            modelOverride = defaults.model
            effortOverride = defaults.effort
            webAccess = defaults.webAccess
            autoApprove = defaults.autoApprove
        }
    }

    /// The runtime's own recent sessions for this conversation's working folder, for
    /// the History picker (§5.3). A light read of the provider's store; Rubien keeps
    /// nothing. Off-main inside the provider.
    func listRecentSessions(limit: Int = 25) async -> [AgentSessionSummary] {
        await provider.recentSessions(workspaceURL: workspaceURL, limit: limit)
    }

    /// Resume a past conversation from History: point the next turn at its session id
    /// (`--resume`) and start with a clean pane (Rubien has no stored transcript — D5).
    /// The resumed session already carries its seed/context, so `seedSent` is set to
    /// avoid re-seeding. A notice with the preview gives the user their bearings.
    func resume(_ summary: AgentSessionSummary) {
        resetConversationState()
        liveSessionID = summary.id
        seedSent = true
        hasMessages = true
        renderNotice("_Resumed a previous conversation:_ “\(summary.preview)”")
    }

    /// Answer a pending Claude approval; the turn continues on the same stream. A stale
    /// response (the approval was replaced or the turn ended) is dropped.
    func respond(to approval: PendingApproval, _ decision: ApprovalDecision) {
        guard pendingApproval == approval else { return }
        provider.respondToApproval(id: approval.id, decision)
        pendingApproval = nil
    }

    /// Re-probe provider availability (drives the empty-state / Recheck).
    func recheckAvailability() async {
        availability = await provider.isAvailable()
    }

    // MARK: Event mapping (internal for testing)

    func handle(_ event: AgentEvent, gen: Int) {
        guard gen == generation else { return }  // drop a superseded turn's late events
        switch event {
        case .sessionStarted(let id):
            liveSessionID = id
            seedSent = true  // the seed-bearing process started → the seed was delivered
        case .assistantDelta(let text):
            transcript.appendDelta(text)  // streaming-only; the commit is what's logged
        case .assistantMessageCompleted(let text):
            transcript.commitAssistantMessage(text)
            appendToLog(.assistant, text)
        case .toolUseStarted(let name, let detail):
            toolDetails[name, default: []].append(detail)
        case .toolUseCompleted(let name):
            renderToolChip(ToolChipPayload(name: name, detail: popToolDetail(name), status: .completed))
        case .approvalRequested(let id, let toolName, let summary):
            if autoApprove {
                provider.respondToApproval(id: id, .allowForConversation)  // no card
            } else {
                pendingApproval = PendingApproval(id: id, toolName: toolName, summary: summary)
            }
        case .toolDenied(let name, let reason):
            _ = popToolDetail(name)
            renderToolChip(ToolChipPayload(name: name, detail: reason, status: .denied))
        case .turnCompleted:
            break  // finalization happens once the stream ends (finalize)
        case .providerNotice(let text):
            renderNotice(text)
        }
    }

    // MARK: Render + log (the log feeds replayTranscript on pane remount)

    private func renderUserMessage(_ markdown: String) {
        transcript.addUserMessage(markdown)
        appendToLog(.user, markdown)
    }

    private func renderNotice(_ markdown: String) {
        transcript.addNotice(markdown)
        appendToLog(.notice, markdown)
    }

    private func renderToolChip(_ chip: ToolChipPayload) {
        transcript.addToolChip(name: chip.name, detail: chip.detail, status: chip.status)
        // Tool rows restore from a JSON body, mirroring the JS contract.
        appendToLog(.tool, ChatTranscriptJS.encodeArg(chip))
    }

    private func appendToLog(_ role: ChatRole, _ body: String) {
        renderLog.append(ChatRenderMessage(role: role, body: body, seq: renderSeq))
        renderSeq += 1
    }

    // MARK: Private

    /// Finalize a completed turn's state. Guarded by `gen` so a superseded turn (a newer
    /// `send` or `newConversation`) is not clobbered. The gate is released by the caller
    /// (awaited) before this runs.
    private func finalize(gen: Int) {
        guard gen == generation else { return }
        isResponding = false
        statusText = nil
        pendingApproval = nil
        toolDetails.removeAll()
        turnTask = nil
    }

    /// A turn refused by the gate (busy in another window): surface it and re-enable the
    /// composer without having rendered the user message.
    private func refuseTurn(gen: Int) {
        guard gen == generation else { return }
        busyElsewhere = true
        renderNotice("This conversation is busy in another window. Try again in a moment.")
        isResponding = false
        statusText = nil
        turnTask = nil
    }

    /// Pop the oldest remembered detail for a tool name (FIFO — events carry no id).
    private func popToolDetail(_ name: String) -> String? {
        guard var queue = toolDetails[name], !queue.isEmpty else { return nil }
        let detail = queue.removeFirst()
        toolDetails[name] = queue.isEmpty ? nil : queue
        return detail
    }

    /// Prepend any staged selection as a markdown blockquote so both the transcript
    /// and the agent see the quoted passage above the question.
    private func composeUserMessage(_ text: String) -> String {
        guard let selection = stagedSelection?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selection.isEmpty else { return text }
        let quoted = selection
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\(quoted)\n\n\(text)"
    }
}
#endif
