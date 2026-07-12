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
    func addUserMessage(_ payload: ChatUserMessagePayload)
    // Deliberately NO beginAssistantMessage: the renderer opens the bubble
    // lazily on the first delta/commit, so rows land in true chronological
    // order (an eagerly pre-opened bubble rendered the answer ABOVE the tool
    // chips that preceded it).
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
    /// The Codex OS-sandbox mode to seed (ignored by Claude conversations). Defaulted
    /// so Claude-only call sites and tests stay unchanged.
    var codexSandbox: CodexSandbox = .readOnly
}

// MARK: - Per-window chat session controller (Phase 2c)
//
// One per reader window. Owns the conversation's in-memory state (nothing is
// persisted — D5), maps a turn's `AgentEvent` stream onto the transcript renderer,
// gates concurrent resume-turns across windows, and surfaces approval + availability
// to the view. The provider (Phase 2a) and the renderer (Phase 1) are injected.

@MainActor
final class ChatSessionController: ObservableObject {

    /// A pending Claude approval (control protocol). The view shows a native card
    /// for the FIRST queued approval above the composer.
    struct PendingApproval: Equatable {
        let id: String
        let toolName: String
        let summary: String
    }

    // MARK: Published UI state
    @Published private(set) var isResponding = false
    /// Outstanding approval requests, arrival order. A single-slot design lost
    /// requests: two parallel prompting tools each raise a `can_use_tool`, the second
    /// card overwrote the first, and the first request was never answered — wedging
    /// the turn (claude blocks until every request is answered). The card shows
    /// `.first`; answering it surfaces the next. Claude answers are keyed by id, so
    /// queued requests wait indefinitely without timing out.
    @Published private(set) var pendingApprovals: [PendingApproval] = []
    /// The approval the card currently shows (the queue head).
    var pendingApproval: PendingApproval? { pendingApprovals.first }
    @Published var webAccess: Bool
    @Published private(set) var availability: AgentAvailability?
    @Published private(set) var statusText: String?
    /// The requested resume session is busy in another window (§4.1) — the composer
    /// surfaces this instead of forking the session file.
    @Published private(set) var busyElsewhere = false
    /// False until the first message renders — the sidebar shows the quick-start
    /// page while false. A gate-refused turn renders nothing, so it stays false.
    @Published private(set) var hasMessages = false
    /// A reader passage staged from "Ask" (§5.4), shown as a chip and prepended as
    /// a `> …` block on the next send. `pageNumber` (1-based, PDF selections only)
    /// is rendered as "(p. N)" on both the chip and the sent block.
    struct StagedSelection {
        var text: String
        var pageNumber: Int? = nil
    }

    @Published var stagedSelection: StagedSelection?
    /// Bumped by `stageSelection` to ask the composer to take focus (Selection→Ask,
    /// §5.4). A monotonic token, not the selection string: re-Asking the *identical*
    /// passage must still re-focus, which an equality-based observer on
    /// `stagedSelection` would miss. Never reset (its absolute value is meaningless).
    @Published private(set) var composerFocusRequest = 0
    /// The model codex reports the live thread actually runs (`.modelResolved`,
    /// spec §4.5). Now that a fresh conversation seeds a concrete `modelOverride`,
    /// this is a fallback signal only — it still backstops `governingCodexModel`
    /// when no model is pinned. Cleared with the conversation.
    @Published private(set) var resolvedModel: String?
    /// The installed codex's discovered models (non-hidden), feeding the model
    /// picker AND the fresh-conversation seed (`refreshCodexCatalog` adopts
    /// `.first` when no model is pinned). Empty until `refreshCodexCatalog()`
    /// resolves — the picker then shows only a pin, if any, until discovery lands
    /// (spec §4.7). Claude conversations keep this empty (static lists).
    @Published private(set) var codexModels: [CodexModelInfo] = []
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
    /// The Codex OS-sandbox mode carried on every turn (D6). Ignored by Claude
    /// (which uses the control protocol, not an OS sandbox). A per-conversation
    /// choice, seeded from the Codex sandbox default and reset on a provider switch.
    @Published var codexSandbox: CodexSandbox
    /// The active backend, published so the composer picker + provider-aware model
    /// list re-render when a switch swaps the underlying provider (Phase 3b-3).
    @Published private(set) var providerKind: AgentProviderKind
    /// Ready, managed copies waiting for the next successfully-admitted turn.
    @Published private(set) var pendingAttachments: [ChatAttachment] = []
    /// Rows published synchronously while their source files are validated/copied.
    @Published private(set) var stagingAttachments: [StagingChatAttachment] = []
    /// Non-fatal, filename-specific staging failures. Valid siblings remain ready.
    @Published private(set) var attachmentIssues: [ChatAttachmentIssue] = []
    @Published private(set) var isRehomingAttachments = false
    @Published private(set) var hasAttachmentRehomeFailure = false

    // MARK: Collaborators (injected)
    /// The live runtime. Mutable so `switchProvider` can swap it in place (the
    /// controller is a `@StateObject`, so rebuilding it wholesale would fight
    /// SwiftUI identity); rebuilt from `providerFactory`.
    private var provider: any AgentProvider
    /// Builds a provider of a given kind for `switchProvider`. nil (tests / DEBUG
    /// harness) ⇒ the backend can't be switched (the picker no-ops).
    private let providerFactory: ((AgentProviderKind) -> any AgentProvider)?
    private let transcript: any ChatTranscriptSink
    private let gate: AssistantTurnGate
    private let reference: ChatReference
    private let workspaceURL: URL
    private let attachmentStore: AssistantAttachmentStore
    /// Re-reads the user's Assistant defaults (Settings) when a fresh conversation
    /// starts, so changing a default + hitting "New conversation" adopts it without
    /// reopening the window. Takes the CURRENT backend kind so it returns that
    /// backend's model/effort/sandbox defaults. nil (tests / DEBUG harness) ⇒
    /// `newConversation` keeps the current live values.
    private let defaultsProvider: ((AgentProviderKind) -> AssistantConversationDefaults)?

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
    /// The in-flight resume transcript restore (exposed read-only so tests can
    /// await it). Stale loads are dropped by the `conversationEpoch` guard, not
    /// cancelled.
    private(set) var resumeTask: Task<Void, Never>?
    /// Bumped ONLY when the conversation identity changes (the reset shared by
    /// `newConversation`/`resume`) — unlike `generation`, which also advances on
    /// every send. The resume restore keys on THIS: a quick follow-up send must
    /// not drop the history load, while a new conversation or another resume must.
    private var conversationEpoch = 0
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
    /// Supersession token for `recheckAvailability`, mirroring the Settings pane's
    /// `probeGeneration` (`RubienSettingsView`). A probe applies its result only if no
    /// newer probe or `switchProvider` advanced the token across the `await`, so a slow
    /// probe of a previously-selected backend can't overwrite the current one's state.
    private var availabilityProbeToken = 0
    /// Supersession token for `refreshCodexCatalog` (same pattern as
    /// `availabilityProbeToken`): a slow fetch kicked before a provider switch
    /// must not repopulate the new backend's (cleared) model list.
    private var catalogFetchToken = 0
    private var attachmentConversationID = UUID()
    private var attachmentGeneration = 0
    private var attachmentTask: Task<Void, Never>?
    private var attachmentTaskToken: UUID?
    private var cancelledAttachmentIDs: Set<UUID> = []
    private var stagingSourceIdentities: [UUID: String] = [:]
    private var attachmentQueue: [AttachmentStagingRequest] = []

    private enum AttachmentStagingInput: Sendable {
        case file(URL)
        case imageData(Data, suggestedName: String)

        var displayName: String {
            switch self {
            case .file(let url): return url.lastPathComponent
            case .imageData(_, let suggestedName): return suggestedName
            }
        }

        var admissionIdentity: String {
            switch self {
            case .file(let url): return url.standardizedFileURL.path
            case .imageData: return "clipboard:\(UUID().uuidString)"
            }
        }
    }

    private struct AttachmentStagingRequest: Sendable {
        let id: UUID
        let input: AttachmentStagingInput
        let sourceIdentity: String
        let generation: Int
        let conversationID: UUID
    }

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
        codexSandbox: CodexSandbox = .readOnly,
        providerFactory: ((AgentProviderKind) -> any AgentProvider)? = nil,
        defaultsProvider: ((AgentProviderKind) -> AssistantConversationDefaults)? = nil,
        initialAvailability: AgentAvailability? = nil,
        attachmentStore: AssistantAttachmentStore? = nil
    ) {
        self.provider = provider
        self.providerKind = provider.kind
        self.transcript = transcript
        self.reference = reference
        self.workspaceURL = workspaceURL
        self.attachmentStore = attachmentStore ?? AssistantAttachmentStore(workspaceURL: workspaceURL)
        self.gate = gate
        self.webAccess = webAccess
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
        self.autoApprove = autoApprove
        self.codexSandbox = codexSandbox
        self.providerFactory = providerFactory
        self.defaultsProvider = defaultsProvider
        self.availability = initialAvailability
    }

    // MARK: Turn lifecycle

    /// Whether a send is permitted given the latest availability probe. An UNKNOWN
    /// result (`nil` — the probe is still in flight on a freshly-opened window) is
    /// treated as allowed, so the composer is usable immediately instead of dead for
    /// the ~1–2s the probe runs; a send to a genuinely-missing backend then degrades
    /// to a turn-failure notice (the pre-gate behavior). Only a KNOWN not-ready state
    /// (`.notFound` / `.installedButUnauthenticated`) blocks send.
    var canSendWithCurrentAvailability: Bool {
        availability?.isReady ?? true
    }

    var hasReadyAttachments: Bool { !pendingAttachments.isEmpty }

    var isStagingAttachments: Bool {
        !stagingAttachments.isEmpty || isRehomingAttachments
    }

    func canSend(draft: String) -> Bool {
        canSendWithCurrentAvailability
            && !isResponding
            && !isStagingAttachments
            && !hasAttachmentRehomeFailure
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasReadyAttachments)
    }

    static func acceptsImageBytes(existing: Int64, adding: Int64) -> Bool {
        let limit: Int64 = 20 * 1_024 * 1_024
        return existing >= 0 && adding >= 0 && adding <= limit && existing <= limit - adding
    }

    func stageAttachments(_ urls: [URL]) {
        guard !isResponding, !isRehomingAttachments, !hasAttachmentRehomeFailure else { return }
        enqueueAttachments(urls.map { .file($0) })
    }

    func stagePastedImage(_ data: Data, suggestedName: String) {
        guard !isResponding, !isRehomingAttachments, !hasAttachmentRehomeFailure else { return }
        enqueueAttachments([.imageData(data, suggestedName: suggestedName)])
    }

    func removePendingAttachment(id: UUID) {
        guard !isResponding, !isRehomingAttachments else { return }
        if let attachment = pendingAttachments.first(where: { $0.id == id }) {
            pendingAttachments.removeAll { $0.id == id }
            Task { await attachmentStore.removePending([attachment]) }
            if pendingAttachments.isEmpty, hasAttachmentRehomeFailure {
                hasAttachmentRehomeFailure = false
                attachmentIssues.removeAll { $0.displayName == "Attachments" }
            }
        }
        if stagingAttachments.contains(where: { $0.id == id }) {
            stagingAttachments.removeAll { $0.id == id }
            stagingSourceIdentities[id] = nil
            let wasQueued = attachmentQueue.contains { $0.id == id }
            attachmentQueue.removeAll { $0.id == id }
            if !wasQueued {
                cancelledAttachmentIDs.insert(id)
            }
        }
    }

    func clearAttachmentIssues() {
        if hasAttachmentRehomeFailure {
            retryPendingAttachmentRehome()
            return
        }
        attachmentIssues.removeAll()
    }

    func retryPendingAttachmentRehome() {
        guard hasAttachmentRehomeFailure,
              !pendingAttachments.isEmpty,
              !isResponding,
              !isRehomingAttachments else { return }
        startAttachmentRehome(
            pendingAttachments,
            destination: attachmentConversationID,
            generation: attachmentGeneration)
    }

    private func enqueueAttachments(_ inputs: [AttachmentStagingInput]) {
        var identities = Set(pendingAttachments.map(\.sourceIdentity))
        identities.formUnion(stagingSourceIdentities.values)

        for input in inputs {
            let displayName = input.displayName
            guard pendingAttachments.count + stagingAttachments.count < 10 else {
                attachmentIssues.append(ChatAttachmentIssue(
                    displayName: displayName,
                    message: "You can attach up to 10 files per turn."
                ))
                continue
            }
            let identity = input.admissionIdentity
            guard identities.insert(identity).inserted else {
                attachmentIssues.append(ChatAttachmentIssue(
                    displayName: displayName,
                    message: "This file is already attached."
                ))
                continue
            }

            let id = UUID()
            stagingAttachments.append(StagingChatAttachment(id: id, displayName: displayName))
            stagingSourceIdentities[id] = identity
            attachmentQueue.append(AttachmentStagingRequest(
                id: id,
                input: input,
                sourceIdentity: identity,
                generation: attachmentGeneration,
                conversationID: attachmentConversationID
            ))
        }
        startAttachmentWorkerIfNeeded()
    }

    private func startAttachmentWorkerIfNeeded() {
        guard attachmentTask == nil, !attachmentQueue.isEmpty else { return }
        let token = UUID()
        attachmentTaskToken = token
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.attachmentQueue.isEmpty {
                let request = self.attachmentQueue.removeFirst()
                await self.stageAttachment(request)
            }
            if self.attachmentTaskToken == token {
                self.attachmentTask = nil
                self.attachmentTaskToken = nil
            }
        }
    }

    private func stageAttachment(_ request: AttachmentStagingRequest) async {
        do {
            let attachment: ChatAttachment
            switch request.input {
            case .file(let url):
                attachment = try await attachmentStore.stageFile(
                    url, id: request.id, conversationID: request.conversationID)
            case .imageData(let data, let suggestedName):
                attachment = try await attachmentStore.stageImageData(
                    data, suggestedName: suggestedName, id: request.id,
                    conversationID: request.conversationID)
            }

            stagingAttachments.removeAll { $0.id == request.id }
            stagingSourceIdentities[request.id] = nil
            let wasCancelled = cancelledAttachmentIDs.remove(request.id) != nil
            guard request.generation == attachmentGeneration, !wasCancelled else {
                await attachmentStore.removePending([attachment])
                return
            }

            if attachment.kind == .image {
                let existing = pendingAttachments
                    .filter { $0.kind == .image }
                    .reduce(Int64(0)) { $0 + $1.byteCount }
                guard Self.acceptsImageBytes(existing: existing, adding: attachment.byteCount) else {
                    await attachmentStore.removePending([attachment])
                    guard request.generation == attachmentGeneration else { return }
                    attachmentIssues.append(ChatAttachmentIssue(
                        displayName: attachment.displayName,
                        message: "Images can total up to 20 MB per turn."
                    ))
                    return
                }
            }
            pendingAttachments.append(attachment)
        } catch {
            stagingAttachments.removeAll { $0.id == request.id }
            stagingSourceIdentities[request.id] = nil
            let wasCancelled = cancelledAttachmentIDs.remove(request.id) != nil
            guard request.generation == attachmentGeneration, !wasCancelled else { return }
            attachmentIssues.append(ChatAttachmentIssue(
                displayName: request.input.displayName,
                message: error.localizedDescription
            ))
        }
    }

    /// Send a user turn. No-ops when neither text nor a ready attachment is present.
    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(draft: text) else { return }

        generation += 1
        let gen = generation
        isResponding = true
        statusText = "Responding…"
        busyElsewhere = false

        // The pre-turn id is both the `--resume` target and the gate key; nil for a
        // fresh conversation (unkeyed, always admitted).
        let resumeID = liveSessionID
        let attachments = pendingAttachments
        let visible = composeUserMessage(text)
        let base = visible.isEmpty ? "Inspect the attached files." : visible
        let providerPrompt = AssistantAttachmentManifest.providerPrompt(
            base: base, visibleText: visible, attachments: attachments)
        let request = AgentTurnRequest(
            workspaceURL: workspaceURL,
            resumeSessionID: resumeID,
            prompt: providerPrompt,
            attachments: attachments,
            seed: seedSent ? nil : AssistantContext.seed(for: reference),
            webAccess: webAccess,
            codexSandbox: codexSandbox,
            modelOverride: modelOverride,
            effortOverride: effortOverride)
        // Pin THIS turn to the provider live at send-time. `switchProvider` can swap
        // `self.provider` after the task is scheduled but before it reaches `send`; the
        // captured `turnProvider` keeps the turn (and its gate key) on one backend, so a
        // stale turn can never be dispatched to the newly-swapped-in runtime.
        let turnProvider = provider
        let kind = turnProvider.kind

        turnTask = Task { [weak self] in
            guard let self else { return }
            // Serialize resume-turns across windows (§4.1). On refusal, DON'T render
            // the user message — the turn never happened (keep the staged selection so
            // a retry still carries it).
            guard await self.gate.tryAcquire(provider: kind, sessionID: resumeID) else {
                self.refuseTurn(gen: gen)
                return
            }
            // A switchProvider / newConversation / newer send can supersede this turn
            // while it waited on the gate (now reachable because send is admitted while
            // availability is still unknown). Bail before mutating the — possibly now
            // fresh — conversation's UI or spawning the turn, releasing the slot we just
            // acquired so it doesn't leak.
            guard gen == self.generation else {
                await self.gate.release(provider: kind, sessionID: resumeID)
                return
            }
            self.hasMessages = true
            let payload = ChatUserMessagePayload(
                body: visible,
                attachments: attachments.map(\.presentation))
            self.renderUserMessage(payload)
            self.pendingAttachments.removeAll()
            self.attachmentIssues.removeAll()
            self.stagedSelection = nil
            // NO eager assistant bubble here: the renderer opens one lazily on
            // the first delta. Pre-opening pinned the bubble ABOVE tool chips
            // when claude ran tools before its first text, so the answer
            // rendered above the chips that produced it (wrong chronology).
            do {
                // `turnProvider`, not `self.provider`: the latter may have been swapped
                // by a switchProvider that raced this turn (see the pin comment above).
                for try await event in turnProvider.send(turn: request) {
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
    func stageSelection(_ text: String, pageNumber: Int? = nil) {
        stagedSelection = StagedSelection(text: text, pageNumber: pageNumber)
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
        // Window close: end the provider entirely (kills a long-lived Codex server;
        // for Claude the default forwards to cancel()).
        provider.shutdown()
        let capturedAttachments = pendingAttachments
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentTaskToken = nil
        attachmentQueue.removeAll()
        attachmentGeneration += 1
        attachmentConversationID = UUID()
        pendingAttachments.removeAll()
        stagingAttachments.removeAll()
        stagingSourceIdentities.removeAll()
        cancelledAttachmentIDs.removeAll()
        attachmentIssues.removeAll()
        isRehomingAttachments = false
        hasAttachmentRehomeFailure = false
        Task { await attachmentStore.removePending(capturedAttachments) }
    }

    /// Re-render the conversation into a freshly-(re)mounted transcript pane from
    /// the in-memory log (toggling the pane dismantles + recreates its WebView).
    /// No-op for a fresh, idle conversation. If a turn was streaming when the
    /// pane was toggled, its partial deltas lived only in the dismantled WebView
    /// (deltas aren't logged — only the commit is); the continuing stream's next
    /// delta lazily opens a fresh bubble after the restored rows, and the turn's
    /// final `assistantMessageCompleted` renders the full authoritative text.
    func replayTranscript() {
        guard !renderLog.isEmpty || isResponding else { return }
        transcript.reset()
        transcript.loadTranscript(renderLog)
    }

    /// The reset shared by `newConversation` and `resume` (§4.1): cancel any live turn,
    /// bump the stale-turn `generation` so the old turn's still-draining events +
    /// finalization can't corrupt the fresh state (its awaited gate release still runs
    /// — no slot leak), and clear all transcript + turn UI state. Callers then set the
    /// session-identity fields (`liveSessionID` / `seedSent` / `hasMessages`) and their
    /// own tail (adopt defaults, or render a notice).
    private enum PendingAttachmentReset {
        case discard
        case preserveAndRehome
    }

    private func resetConversationState(attachments policy: PendingAttachmentReset) {
        let capturedAttachments = pendingAttachments
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentTaskToken = nil
        attachmentQueue.removeAll()
        attachmentGeneration += 1
        attachmentConversationID = UUID()
        provider.cancel()
        generation += 1
        conversationEpoch += 1
        transcript.reset()
        toolDetails.removeAll()
        renderLog.removeAll()
        renderSeq = 0
        isResponding = false
        statusText = nil
        busyElsewhere = false
        pendingApprovals.removeAll()
        stagedSelection = nil
        resolvedModel = nil

        stagingAttachments.removeAll()
        stagingSourceIdentities.removeAll()
        cancelledAttachmentIDs.removeAll()

        switch policy {
        case .discard:
            pendingAttachments.removeAll()
            attachmentIssues.removeAll()
            isRehomingAttachments = false
            hasAttachmentRehomeFailure = false
            Task { await attachmentStore.removePending(capturedAttachments) }
        case .preserveAndRehome:
            guard !capturedAttachments.isEmpty else {
                isRehomingAttachments = false
                hasAttachmentRehomeFailure = false
                return
            }
            startAttachmentRehome(
                capturedAttachments,
                destination: attachmentConversationID,
                generation: attachmentGeneration)
        }
    }

    private func startAttachmentRehome(
        _ attachments: [ChatAttachment],
        destination: UUID,
        generation: Int
    ) {
        isRehomingAttachments = true
        hasAttachmentRehomeFailure = false
        attachmentIssues.removeAll { $0.displayName == "Attachments" }
        let token = UUID()
        attachmentTaskToken = token
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let moved = try await self.attachmentStore.rehomePending(
                    attachments, to: destination)
                guard generation == self.attachmentGeneration else {
                    await self.attachmentStore.removePending(moved)
                    return
                }
                self.pendingAttachments = moved
            } catch {
                if generation == self.attachmentGeneration {
                    self.hasAttachmentRehomeFailure = true
                    self.attachmentIssues = [ChatAttachmentIssue(
                        displayName: "Attachments",
                        message: "Could not move attachments. Remove them or retry. \(error.localizedDescription)")]
                }
            }
            if generation == self.attachmentGeneration {
                self.isRehomingAttachments = false
            }
            if self.attachmentTaskToken == token {
                self.attachmentTask = nil
                self.attachmentTaskToken = nil
                self.startAttachmentWorkerIfNeeded()
            }
        }
    }

    /// Start a fresh conversation: reset, drop the session identity, and adopt the
    /// latest Settings ▸ Assistant defaults (so a default changed while a reader is
    /// open takes effect here; a live conversation keeps its own values). Defaults
    /// re-read is a no-op when the provider is unset (tests / DEBUG harness).
    func newConversation() {
        resetConversationState(attachments: .discard)
        liveSessionID = nil
        seedSent = false
        hasMessages = false
        if let defaults = defaultsProvider?(providerKind) {
            modelOverride = defaults.model
            effortOverride = defaults.effort
            webAccess = defaults.webAccess
            autoApprove = defaults.autoApprove
            codexSandbox = defaults.codexSandbox
        }
        // A never-picked Codex user (nil model default) would otherwise drop to a
        // blank picker here; seed a concrete model when the catalog is already loaded.
        // No-op when it isn't — the in-flight fetch seeds later, same as today.
        seedCodexModelIfUnset()
    }

    /// Switch this conversation's backend runtime (composer picker, Phase 3b-3).
    /// A switch is a hard cut: the OLD runtime is torn down — its long-lived Codex
    /// server is killed (not just interrupted like `cancel()`), the new provider is
    /// built from the factory, and a FRESH conversation starts adopting the new
    /// backend's defaults (model/effort/sandbox are backend-specific — Claude's
    /// `opus` is meaningless to Codex). No-op if the kind is unchanged or the
    /// factory is absent (tests / DEBUG harness). The prior transcript is dropped
    /// (nothing persisted — D5); History can resume a Codex thread later. A real
    /// switch also becomes the default backend for future conversations.
    func switchProvider(to kind: AgentProviderKind) {
        guard !isStagingAttachments,
              !hasAttachmentRehomeFailure,
              let providerFactory,
              kind != providerKind else { return }
        // Request teardown of the outgoing runtime. `shutdown()` may reap the server
        // asynchronously, but the old runtime is a separate process on its own pipes —
        // it can't touch the freshly-built provider below, and any in-flight turn's
        // still-draining stream is invalidated by the `generation` bump in
        // `newConversation`. The captured `turnProvider` in `send` keeps that stale
        // turn pinned to the outgoing runtime, never the new one.
        provider.shutdown()
        provider = providerFactory(kind)
        providerKind = kind
        availability = nil
        // Supersede any in-flight probe of the outgoing backend synchronously — a
        // stale result landing in the gap before the recheck below runs must not write
        // the wrong backend's availability. The scheduled recheck bumps this again.
        availabilityProbeToken += 1
        RubienPreferences.assistantProvider = kind
        resetConversationState(attachments: .preserveAndRehome)
        liveSessionID = nil
        seedSent = false
        hasMessages = false
        if let defaults = defaultsProvider?(providerKind) {
            modelOverride = defaults.model
            effortOverride = defaults.effort
            webAccess = defaults.webAccess
            autoApprove = defaults.autoApprove
            codexSandbox = defaults.codexSandbox
        }
        seedCodexModelIfUnset()
        refreshCodexCatalog()
        Task { await recheckAvailability() }
    }

    /// The runtime's own recent sessions for this conversation's working folder, for
    /// the History picker (§5.3). A light read of the provider's store; Rubien keeps
    /// nothing. Off-main inside the provider. `scopedToReference` keeps only sessions
    /// attributed to THIS document (the popover's default scope) — attribution is the
    /// rubien tool calls in the session, since neither runtime persists the seed.
    func listRecentSessions(limit: Int = 25, scopedToReference: Bool = false) async -> [AgentSessionSummary] {
        await provider.recentSessions(
            workspaceURL: workspaceURL, limit: limit,
            referenceID: scopedToReference ? reference.id : nil)
    }

    /// Content search over the provider's sessions for this conversation's working
    /// folder (History picker's search field, §5.3). `scopedToReference` as above.
    func searchSessions(
        _ query: String, limit: Int = 25, scopedToReference: Bool = false
    ) async -> [AgentSessionSummary] {
        await provider.searchSessions(
            query: query, workspaceURL: workspaceURL, limit: limit,
            referenceID: scopedToReference ? reference.id : nil)
    }

    /// Resume a past conversation from History: point the next turn at its session id
    /// (`--resume`) and start with a clean pane (Rubien has no stored transcript — D5).
    /// The resumed session already carries its seed/context, so `seedSent` is set to
    /// avoid re-seeding. A notice with the preview gives the user their bearings.
    func resume(_ summary: AgentSessionSummary) {
        resetConversationState(attachments: .discard)
        liveSessionID = summary.id
        seedSent = true
        hasMessages = true
        // Restore the conversation's content from the provider's own store (D5 —
        // Rubien still persists nothing). The read is asynchronous but fast (one
        // file); the epoch drops a stale load when another resume/newConversation
        // won — but NOT when a quick follow-up send did (same conversation; the
        // history must still prepend).
        let epoch = conversationEpoch
        resumeTask = Task { [weak self] in
            guard let self else { return }
            let history = await self.provider.sessionTranscript(
                sessionID: summary.id, workspaceURL: self.workspaceURL)
            guard epoch == self.conversationEpoch else { return }
            guard !history.isEmpty else {
                // Unreadable/empty store (or a provider without one): keep the
                // old notice-only behavior so the resume is still explained.
                self.renderNotice("_Resumed a previous conversation:_ “\(summary.preview)”")
                return
            }
            // Prepend the history to anything rendered while it loaded (a quick
            // follow-up send's user row and stream), re-sequenced, and re-render
            // the pane from the merged log. If a turn is streaming, its partial
            // deltas are lost to the reset and the bubble re-opens lazily on the
            // next delta — the same accepted tradeoff as a mid-stream pane toggle.
            let tail = self.renderLog
            self.renderLog = []
            self.renderSeq = 0
            for row in history + tail {
                self.appendToLog(row.role, row.body, attachments: row.attachments)
            }
            self.transcript.reset()
            self.transcript.loadTranscript(self.renderLog)
        }
    }

    /// Answer a pending Claude approval; the turn continues on the same stream and the
    /// next queued approval (if any) surfaces on the card. A stale response (the
    /// request is no longer queued — the turn ended or it was already answered) is
    /// dropped. "Allow for Conversation" also sweeps queued requests for the SAME
    /// tool: the user just granted the tool for this conversation, so making them
    /// re-approve an already-queued call of it would be noise. Deny stays per-request.
    func respond(to approval: PendingApproval, _ decision: ApprovalDecision) {
        guard pendingApprovals.contains(approval) else { return }
        provider.respondToApproval(id: approval.id, decision)
        pendingApprovals.removeAll { $0.id == approval.id }
        if decision == .allowForConversation {
            let sameTool = pendingApprovals.filter { $0.toolName == approval.toolName }
            for queued in sameTool {
                provider.respondToApproval(id: queued.id, .allowForConversation)
            }
            pendingApprovals.removeAll { $0.toolName == approval.toolName }
        }
    }

    /// Re-probe provider availability (drives the setup card / Recheck). Guarded by
    /// `availabilityProbeToken` so a stale in-flight probe — e.g. of the backend that
    /// was active before a `switchProvider`, or an earlier mount-time probe racing a
    /// switch — is dropped instead of overwriting the current backend's result.
    func recheckAvailability() async {
        availabilityProbeToken += 1
        let token = availabilityProbeToken
        let result = await provider.isAvailable()
        guard token == availabilityProbeToken else { return }
        availability = result
    }

    /// The model whose effort list governs the picker (spec §4.6): the pinned
    /// model, else the resolved codex-default model once a thread reported it.
    var governingCodexModel: CodexModelInfo? {
        guard let id = modelOverride ?? resolvedModel else { return nil }
        return codexModels.first { $0.id == id }
    }

    /// Kick (or re-kick) the model-catalog fetch for the live backend. Codex only —
    /// for Claude this clears the list. Never blocks a turn (spec §4.1); a result
    /// arriving after a provider switch is dropped by the token.
    func refreshCodexCatalog() {
        catalogFetchToken += 1
        let token = catalogFetchToken
        guard providerKind == .codex else {
            codexModels = []
            return
        }
        let catalogProvider = provider
        Task { [weak self] in
            let catalog = await catalogProvider.availableModels()
            guard let self, token == self.catalogFetchToken else { return }
            self.codexModels = catalog?.visibleModels ?? []
            self.seedCodexModelIfUnset()  // seed an unset conversation onto a concrete model
            self.ensureEffortSupported()  // a pinned/seeded model's efforts are now known
        }
    }

    /// The model picker's setter. On Codex a pick is REMEMBERED as the default for
    /// the next conversation (`assistantCodexModel`), and the model is THREAD-scoped
    /// (`thread/start` only — spec §2.3): changing it once the conversation has
    /// content starts a FRESH conversation that PRESERVES the live web/approval/
    /// effort/sandbox choices — deliberately NOT `newConversation()`, which
    /// re-applies Settings defaults and would silently flip the user's live
    /// toggles (plan-review #3) — and notes the reset in the pane (spec §4.6,
    /// the `resume()` notice precedent). Claude switches live (per-turn `--model`)
    /// and is NOT remembered here (its default lives in Settings). An explicit pick
    /// snaps effort to the model's own default when the catalog knows it (spec §3);
    /// a nil id (transient pre-seed / programmatic only) leaves effort alone.
    func selectModel(_ id: String?) {
        guard id != modelOverride else { return }
        if providerKind == .codex {
            RubienPreferences.assistantCodexModel = id  // remember the pick as the default
        }
        if providerKind == .codex, hasMessages {
            resetConversationState(attachments: .discard)
            liveSessionID = nil
            seedSent = false
            modelOverride = id
            snapEffortToModelDefault(id)
            hasMessages = true
            renderNotice("_New conversation — Codex applies a model change to a fresh conversation._")
            return
        }
        modelOverride = id
        snapEffortToModelDefault(id)
    }

    /// The effort picker's setter. Sets the conversation's effort and, on Codex,
    /// REMEMBERS it as the default for the next conversation (`assistantCodexEffort`;
    /// an empty string is the pref's `medium` fallback, so a nil/empty pick is fine).
    /// Claude effort is a live per-conversation choice (its default lives in
    /// Settings), so it is not persisted here. Minimal by design — no reset, no snap
    /// (effort rides per-turn).
    func selectEffort(_ value: String?) {
        effortOverride = value
        if providerKind == .codex {
            RubienPreferences.assistantCodexEffort = value ?? ""
        }
    }

    /// Seed a fresh/never-picked Codex conversation onto a concrete model (the first
    /// discovered one) + its default effort, once the catalog is known. No-op if a
    /// model is already chosen (a remembered pick or an in-flight pin) or the catalog
    /// hasn't loaded. The seed is NOT persisted — only an explicit pick writes
    /// `assistantCodexModel`. Called from the catalog fetch AND from `newConversation`
    /// so the "New conversation" button doesn't drop a never-picked user to a blank
    /// picker (spec §4.6).
    private func seedCodexModelIfUnset() {
        guard providerKind == .codex, modelOverride == nil, let first = codexModels.first else { return }
        modelOverride = first.id
        if effortOverride == nil { effortOverride = first.defaultEffort }
    }

    /// An explicit model pick adopts that model's `defaultReasoningEffort` when
    /// the catalog knows it (spec §3); an unknown model or a nil id (transient
    /// pre-seed / programmatic) leaves the effort alone.
    private func snapEffortToModelDefault(_ id: String?) {
        guard providerKind == .codex, let id,
              let model = codexModels.first(where: { $0.id == id }),
              let defaultEffort = model.defaultEffort else { return }
        effortOverride = defaultEffort
    }

    /// Snap the conversation's effort to one the GOVERNING codex model supports, but
    /// ONLY when the current value is unsupported — never overriding a still-valid
    /// choice. codex's app-server REJECTS an unsupported `effort` on turn/start with a
    /// JSON-RPC error before the turn runs, so an effort persisted for one model
    /// (e.g. `ultra`) must not ride into one that lacks it. No-op for Claude, an
    /// unknown/absent governing model, or a model advertising no efforts.
    private func ensureEffortSupported() {
        guard providerKind == .codex,
              let governing = governingCodexModel,
              !governing.efforts.isEmpty,
              let current = effortOverride,
              !governing.efforts.contains(where: { $0.value == current })
        else { return }
        effortOverride = governing.defaultEffort ?? governing.efforts.first?.value
    }

    // MARK: Event mapping (internal for testing)

    func handle(_ event: AgentEvent, gen: Int) {
        guard gen == generation else { return }  // drop a superseded turn's late events
        switch event {
        case .sessionStarted(let id):
            liveSessionID = id
            seedSent = true  // the seed-bearing process started → the seed was delivered
        case .modelResolved(let model):
            resolvedModel = model
            ensureEffortSupported()  // the governing model is now known — snap a stale effort
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
            // Reads/search run silently even in "Ask" — the D6 soft boundary (§3)
            // only prompts for writes/shell. Auto (autoApprove) accepts everything.
            if autoApprove || Self.isSilentReadTool(toolName) {
                provider.respondToApproval(id: id, .allowForConversation)  // no card
            } else {
                pendingApprovals.append(PendingApproval(id: id, toolName: toolName, summary: summary))
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

    private func renderUserMessage(_ payload: ChatUserMessagePayload) {
        if payload.attachments.isEmpty {
            // Preserve the established text-only bridge byte-for-byte.
            transcript.addUserMessage(payload.body)
        } else {
            transcript.addUserMessage(payload)
        }
        appendToLog(.user, payload.body, attachments: payload.attachments)
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

    private func appendToLog(
        _ role: ChatRole,
        _ body: String,
        attachments: [ChatAttachmentPresentation] = []
    ) {
        renderLog.append(ChatRenderMessage(
            role: role,
            body: body,
            seq: renderSeq,
            attachments: attachments))
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
        pendingApprovals.removeAll()
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

    /// Claude's read/search builtins that are safe to run without a prompt (the D6
    /// soft boundary, §3). Every `mcp__rubien__*` tool is also silent — the content
    /// channel is a `--read-only` server — handled by the prefix check below.
    private static let silentReadBuiltins: Set<String> = [
        "ToolSearch", "Read", "Glob", "Grep", "LS", "NotebookRead", "WebFetch", "WebSearch",
    ]

    /// Whether a tool may run without an approval card even in "Ask" mode: the Rubien
    /// read-only content channel (`mcp__rubien__*`) and Claude's read/search builtins.
    /// Writes / shell (`Write`, `Edit`, `Bash`, …) are absent, so they still prompt.
    static func isSilentReadTool(_ toolName: String) -> Bool {
        toolName.hasPrefix(ReferenceAttribution.claudeToolPrefix)
            || silentReadBuiltins.contains(toolName)
    }

    /// Pop the oldest remembered detail for a tool name (FIFO — events carry no id).
    private func popToolDetail(_ name: String) -> String? {
        guard var queue = toolDetails[name], !queue.isEmpty else { return nil }
        let detail = queue.removeFirst()
        toolDetails[name] = queue.isEmpty ? nil : queue
        return detail
    }

    /// Prepend any staged selection as a markdown blockquote so both the transcript
    /// and the agent see the quoted passage above the question, with its page
    /// number when the passage came from a PDF (§5.4).
    private func composeUserMessage(_ text: String) -> String {
        guard let staged = stagedSelection else { return text }
        let selection = staged.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return text }
        var quoted = selection
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        if let page = staged.pageNumber {
            quoted += "\n>\n> (p. \(page))"
        }
        return "\(quoted)\n\n\(text)"
    }
}
#endif
