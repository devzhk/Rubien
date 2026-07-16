#if os(macOS)
import Foundation
import Combine
import RubienCore

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
    func addPaperGroup(_ group: ChatPaperGroup)
    func addNotice(_ markdown: String)
    func setTheme(_ mode: ChatTheme)
}

extension ChatTranscriptController: ChatTranscriptSink {}

// MARK: - Conversation defaults

/// A snapshot of the user's Assistant defaults (Settings ▸ Assistant) applied to a
/// FRESH conversation: model / effort / web / approval / tool posture. A new reader window reads
/// these at construction; `newConversation()` re-reads them (via an injected
/// provider) so a changed default is adopted in an open window without reopening it.
struct AssistantConversationDefaults: Equatable {
    var model: String?
    var effort: String?
    var webAccess: Bool
    var autoApprove: Bool
    /// Load the provider's normal connected apps/configured tools for this fresh
    /// conversation. Default off so existing call sites retain the isolated posture.
    var loadUserTools: Bool = false
    /// The Codex OS-sandbox mode to seed (ignored by Claude conversations). Defaulted
    /// so Claude-only call sites and tests stay unchanged.
    var codexSandbox: CodexSandbox = .readOnly
}

/// Structured lifecycle for Home's hidden-turn attention UI. The generation
/// prevents a late terminal event from an older/superseded turn from being
/// mistaken for the current conversation's outcome.
struct AssistantTurnOutcome: Equatable {
    enum Phase: Equatable {
        case idle
        case responding
        case approvalRequired
        case succeeded
        case failed
        case cancelled
        case superseded
    }

    let generation: Int
    let phase: Phase
}

// MARK: - Per-window chat session controller (Phase 2c)
//
// One per reader window. Owns the conversation's in-memory state (nothing is
// persisted — D5), maps a turn's `AgentEvent` stream onto the transcript renderer,
// gates concurrent resume-turns across windows, and surfaces approval + availability
// to the view. The provider (Phase 2a) and the renderer (Phase 1) are injected.

@MainActor
final class ChatSessionController: ObservableObject {

    typealias MentionSearch = @Sendable (_ query: String, _ limit: Int) async -> [ChatReference]

    /// A pending Claude approval (control protocol). The view shows a native card
    /// for the FIRST queued approval above the composer.
    struct PendingApproval: Equatable {
        let id: String
        let toolName: String
        let summary: String
    }

    // MARK: Published UI state
    @Published private(set) var isResponding = false
    @Published private(set) var isResuming = false
    /// True between accepting a send and the global turn gate admitting it. Queueing
    /// is enabled only after admission, so a retained Home draft cannot be submitted
    /// a second time during this short window.
    @Published private(set) var isAwaitingTurnAdmission = false
    /// User messages accepted while a turn is running. They stay off the transcript
    /// until the current response ends, then all messages waiting at that boundary
    /// are merged into one follow-up turn.
    var queuedMessageCount: Int { queuedUserMessages.count }
    var hasQueuedMessages: Bool { !queuedUserMessages.isEmpty }
    var hasActiveQueuedMessageEdit: Bool { queuedMessageEdit != nil }
    @Published private(set) var turnOutcome = AssistantTurnOutcome(
        generation: 0,
        phase: .idle)
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
    /// Tool-environment posture snapshotted for this conversation. Settings changes
    /// are adopted by `newConversation()` rather than mutating a live agent session.
    @Published private(set) var loadUserTools: Bool
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
    /// Default false — provider-emitted requests become cards. In the isolated
    /// posture writes prompt via the control protocol (D6); with user tools loaded,
    /// the agent's ambient permission rules may approve a tool before Rubien receives
    /// a request. A per-conversation choice; reads/search stay silent either way.
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
    private let surfaceDefaultContext: AssistantConversationContext
    private var activeConversationContext: AssistantConversationContext
    private let workspaceURL: URL
    private let attachmentStore: AssistantAttachmentStore
    private let mentionSearch: MentionSearch
    /// Re-reads the user's Assistant defaults (Settings) when a fresh conversation
    /// starts, so changing a default + hitting "New conversation" adopts it without
    /// reopening the window. Takes the CURRENT backend kind so it returns that
    /// backend's model/effort/sandbox defaults. nil (tests / DEBUG harness) ⇒
    /// `newConversation` keeps the current live values.
    private let defaultsProvider: ((AgentProviderKind) -> AssistantConversationDefaults)?
    /// Present only in production composition roots. Tests remain database-free.
    private let activityDatabase: AppDatabase?
    private let attributionStore: AssistantSessionAttributionStore?

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
    /// Synchronously supersedes attribution lookups started by an older History
    /// selection before they are allowed to reset the live conversation.
    private var resumeRequestGeneration = 0
    /// `toolUseStarted` details per tool name, FIFO — the single chip emitted on a
    /// tool's terminal event pops the oldest (the renderer's `addToolChip` is add-only,
    /// and events carry no tool-use id to match started↔completed exactly).
    private var toolDetails: [String: [String?]] = [:]
    private var pendingPaperPresentations: [String: (ordinal: Int, group: ChatPaperGroup)] = [:]
    private var seenPaperPresentationCallIDs = Set<String>()
    private var didPublishPaperPresentationThisTurn = false
    /// A valid typed presentation event is followed immediately by the generic
    /// tool-completed event. Consume one completion per valid result so only
    /// malformed successful results fall back to a visible ordinary tool chip.
    private var paperCompletionSuppressions = 0
    /// The render-only transcript log (D5: in-memory, per-window, never persisted).
    /// Toggling the sidebar pane dismantles its WKWebView — `replayTranscript()`
    /// restores the visible transcript from this log when the pane remounts.
    private var renderLog: [ChatRenderMessage] = []
    private var renderSeq = 0
    /// Bumped by `send` / `newConversation` to invalidate a superseded turn's late
    /// events + finalization (the stale-turn guard, §4.1): a drained old stream must
    /// not corrupt a fresh conversation's state or clobber a newer turn.
    private(set) var generation = 0
    /// The generation for which Stop was explicitly requested. Provider
    /// cancellation may surface as either a clean stream end or an error, so the
    /// UI outcome cannot infer cancellation from the stream alone.
    private var cancelledTurnGeneration: Int?
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
    /// Stable across retries and provider session-ID rotation; replaced only when
    /// Rubien creates a genuinely fresh conversation.
    private var rubienConversationID = UUID()
    private var assistantActivityContext: ActivityCaptureContext?
    /// Consumed on the first successful provider start even when capture is off,
    /// preventing a later preference change from counting the conversation.
    private var assistantActivityStartConsumed = false

    struct QueuedMessagePreview: Identifiable, Equatable {
        let id: UUID
        let text: String
    }

    private struct QueuedUserMessage {
        let id: UUID
        var rawText: String
        var mentionSelections: [PaperMentionSelection]
        let stagedSelection: StagedSelection?
    }

    /// A controller-owned edit transaction keeps the queued item unchanged until
    /// Save, while mention ranges are reconciled incrementally as the field changes.
    /// Automatic follow-up dispatch pauses for the lifetime of this transaction.
    private struct QueuedMessageEdit {
        let id: UUID
        var rawText: String
        var mentionSelections: [PaperMentionSelection]
    }

    @Published private var queuedUserMessages: [QueuedUserMessage] = []
    private var queuedMessageEdit: QueuedMessageEdit?
    /// True only when turn finalization wanted to dispatch the queue but an open
    /// edit transaction intentionally paused it. Gate refusal is a distinct idle
    /// state and must still require an explicit Send retry.
    private var queuedDispatchDeferredByEdit = false

    var queuedMessages: [QueuedMessagePreview] {
        queuedUserMessages.map {
            QueuedMessagePreview(
                id: $0.id,
                text: $0.rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

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
            case .file(let url): return AssistantAttachmentStore.sourceIdentity(for: url)
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
        reference: ChatReference? = nil,
        conversationContext: AssistantConversationContext? = nil,
        workspaceURL: URL,
        gate: AssistantTurnGate = .shared,
        webAccess: Bool = true,
        loadUserTools: Bool = false,
        modelOverride: String? = "opus",
        effortOverride: String? = "high",
        autoApprove: Bool = false,
        codexSandbox: CodexSandbox = .readOnly,
        providerFactory: ((AgentProviderKind) -> any AgentProvider)? = nil,
        defaultsProvider: ((AgentProviderKind) -> AssistantConversationDefaults)? = nil,
        initialAvailability: AgentAvailability? = nil,
        attachmentStore: AssistantAttachmentStore? = nil,
        mentionSearch: @escaping MentionSearch = { _, _ in [] },
        activityDatabase: AppDatabase? = nil,
        attributionStore: AssistantSessionAttributionStore? = nil
    ) {
        self.provider = provider
        self.providerKind = provider.kind
        self.transcript = transcript
        let initialContext = conversationContext
            ?? reference.map(AssistantConversationContext.reference)
            ?? .library
        self.surfaceDefaultContext = initialContext
        self.activeConversationContext = initialContext
        self.workspaceURL = workspaceURL
        self.attachmentStore = attachmentStore ?? AssistantAttachmentStore(workspaceURL: workspaceURL)
        self.mentionSearch = mentionSearch
        self.gate = gate
        self.webAccess = webAccess
        self.loadUserTools = loadUserTools
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
        self.autoApprove = autoApprove
        self.codexSandbox = codexSandbox
        self.providerFactory = providerFactory
        self.defaultsProvider = defaultsProvider
        self.availability = initialAvailability
        self.activityDatabase = activityDatabase
        self.attributionStore = attributionStore
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
        guard canSendWithCurrentAvailability,
              !isResuming,
              !isStagingAttachments,
              !hasAttachmentRehomeFailure,
              !hasActiveQueuedMessageEdit
        else { return false }

        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Attachments cannot be staged while a turn is live, and an attachment from
        // the current turn must never be silently reused by a queued follow-up.
        if isResponding { return !isAwaitingTurnAdmission && hasText }
        return hasText || hasReadyAttachments || hasQueuedMessages
    }

    static func acceptsImageBytes(existing: Int64, adding: Int64) -> Bool {
        let limit = AssistantAttachmentPolicy.maximumTotalImageBytes
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
            guard pendingAttachments.count + stagingAttachments.count
                    < AssistantAttachmentPolicy.maximumAttachmentCount else {
                attachmentIssues.append(ChatAttachmentIssue(
                    displayName: displayName,
                    message: "You can attach up to \(AssistantAttachmentPolicy.maximumAttachmentCount) files per turn."
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

    /// Send a user turn. While the assistant is responding, a text message is queued
    /// instead; every message waiting when that response ends is merged into the next
    /// provider turn. No-ops when there is no sendable or already-queued content.
    func send(
        _ rawText: String,
        mentionedReferences: [PaperMentionSelection] = [],
        onCommitted: (() -> Void)? = nil
    ) {
        // Ranges belong to the composer snapshot, before user-facing whitespace
        // normalization. Validate identity first; trimming can shift every token.
        let mentionSelections = PaperMentions.selectionsStillPresent(
            in: rawText,
            from: mentionedReferences
        )
        let mentions = mentionSelections.map(\.reference)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(draft: text) else { return }

        if isResponding {
            enqueueUserMessage(
                rawText: rawText,
                mentionSelections: mentionSelections,
                stagedSelection: stagedSelection)
            // Queue admission is durable for this in-memory conversation, so the
            // composer can clear immediately instead of waiting for the next turn's
            // gate acquisition. Any staged quote is captured with the queued item.
            stagedSelection = nil
            onCommitted?()
            return
        }

        // A rare cross-window gate refusal leaves its automatic follow-up queued.
        // Pressing Send retries it; any newly-entered text joins that same batch.
        if hasQueuedMessages {
            if !text.isEmpty {
                enqueueUserMessage(
                    rawText: rawText,
                    mentionSelections: mentionSelections,
                    stagedSelection: stagedSelection)
                stagedSelection = nil
                onCommitted?()
            }
            startQueuedTurnIfNeeded()
            return
        }

        startTurn(
            visibleText: composeUserMessage(text),
            mentionedReferences: mentions,
            consumeStagedSelectionOnAdmission: true,
            onCommitted: onCommitted)
    }

    private func startTurn(
        visibleText visible: String,
        mentionedReferences mentions: [ChatReference],
        consumeStagedSelectionOnAdmission: Bool,
        queuedBatchCount: Int = 0,
        onCommitted: (() -> Void)? = nil
    ) {

        generation += 1
        let gen = generation
        cancelledTurnGeneration = nil
        isResponding = true
        isAwaitingTurnAdmission = true
        turnOutcome = AssistantTurnOutcome(generation: gen, phase: .responding)
        statusText = "Responding…"
        busyElsewhere = false

        // The pre-turn id is both the `--resume` target and the gate key; nil for a
        // fresh conversation (unkeyed, always admitted).
        let resumeID = liveSessionID
        let attachments = pendingAttachments
        let providerPrompt = AssistantAttachmentManifest.providerPrompt(
            visibleText: visible,
            attachments: attachments,
            mentionedReferences: mentions)
        let request = AgentTurnRequest(
            workspaceURL: workspaceURL,
            resumeSessionID: resumeID,
            prompt: providerPrompt,
            attachments: attachments,
            seed: seedSent ? nil : AssistantContext.seed(for: activeConversationContext),
            webAccess: webAccess,
            loadUserTools: loadUserTools,
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
            self.isAwaitingTurnAdmission = false
            if queuedBatchCount > 0 {
                let consumed = min(queuedBatchCount, self.queuedUserMessages.count)
                self.queuedUserMessages.removeFirst(consumed)
            }
            self.hasMessages = true
            self.pendingPaperPresentations.removeAll()
            self.seenPaperPresentationCallIDs.removeAll()
            self.didPublishPaperPresentationThisTurn = false
            self.paperCompletionSuppressions = 0
            self.prepareAssistantActivityCaptureIfNeeded()
            let payload = ChatUserMessagePayload(
                body: visible,
                attachments: attachments.map(\.presentation))
            self.renderUserMessage(payload)
            self.pendingAttachments.removeAll()
            self.attachmentIssues.removeAll()
            if consumeStagedSelectionOnAdmission {
                self.stagedSelection = nil
            }
            // The UI may keep a fresh Home draft until this exact point so a
            // gate-refused attempt remains retryable. Notify only after admission
            // and the user row are committed — never merely when `send` is called.
            onCommitted?()
            // NO eager assistant bubble here: the renderer opens one lazily on
            // the first delta. Pre-opening pinned the bubble ABOVE tool chips
            // when claude ran tools before its first text, so the answer
            // rendered above the chips that produced it (wrong chronology).
            var terminalPhase = AssistantTurnOutcome.Phase.succeeded
            do {
                // `turnProvider`, not `self.provider`: the latter may have been swapped
                // by a switchProvider that raced this turn (see the pin comment above).
                for try await event in turnProvider.send(turn: request) {
                    self.handle(event, gen: gen)
                }
            } catch {
                if gen == self.generation {
                    self.renderNotice("The assistant turn failed: \(error.localizedDescription)")
                    terminalPhase = .failed
                }
            }
            // Release BEFORE the task completes, so awaiting `turnTask` guarantees the
            // slot is free (a fire-and-forget release could race the next acquire).
            await self.gate.release(provider: kind, sessionID: resumeID)
            self.finalize(gen: gen, terminalPhase: terminalPhase)
        }
    }

    private func enqueueUserMessage(
        rawText: String,
        mentionSelections: [PaperMentionSelection],
        stagedSelection: StagedSelection?
    ) {
        queuedUserMessages.append(QueuedUserMessage(
            id: UUID(),
            rawText: rawText,
            mentionSelections: mentionSelections,
            stagedSelection: stagedSelection))
    }

    /// Start an edit transaction and return the exact untrimmed composer text. The
    /// queued item remains authoritative until the transaction is committed.
    func beginQueuedMessageEdit(id: UUID) -> String? {
        guard !isAwaitingTurnAdmission,
              queuedMessageEdit == nil,
              let message = queuedUserMessages.first(where: { $0.id == id })
        else { return nil }

        queuedMessageEdit = QueuedMessageEdit(
            id: id,
            rawText: message.rawText,
            mentionSelections: message.mentionSelections)
        return message.rawText
    }

    /// Reconcile one editor snapshot into the active transaction. Calling this for
    /// every field change preserves mention identities across edits on both sides of
    /// a token; edits through the token still remove that structured identity.
    @discardableResult
    func updateQueuedMessageEdit(id: UUID, text rawText: String) -> Bool {
        guard !isAwaitingTurnAdmission,
              var edit = queuedMessageEdit,
              edit.id == id
        else { return false }

        edit.mentionSelections = PaperMentions.reconciling(
            edit.mentionSelections,
            from: edit.rawText,
            to: rawText)
        edit.rawText = rawText
        queuedMessageEdit = edit
        return true
    }

    @discardableResult
    func commitQueuedMessageEdit(id: UUID) -> Bool {
        guard !isAwaitingTurnAdmission,
              let edit = queuedMessageEdit,
              edit.id == id,
              let index = queuedUserMessages.firstIndex(where: { $0.id == id })
        else { return false }

        let text = edit.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var message = queuedUserMessages[index]
        let mentions = PaperMentions.selectionsStillPresent(
            in: edit.rawText,
            from: edit.mentionSelections)
        message.rawText = edit.rawText
        message.mentionSelections = mentions
        queuedUserMessages[index] = message
        let shouldResumeDeferredDispatch = queuedDispatchDeferredByEdit
        queuedMessageEdit = nil
        if shouldResumeDeferredDispatch { startQueuedTurnIfNeeded() }
        return true
    }

    func cancelQueuedMessageEdit(id: UUID) {
        guard queuedMessageEdit?.id == id else { return }
        let shouldResumeDeferredDispatch = queuedDispatchDeferredByEdit
        queuedMessageEdit = nil
        if shouldResumeDeferredDispatch { startQueuedTurnIfNeeded() }
    }

    func removeQueuedMessage(id: UUID) {
        guard !isAwaitingTurnAdmission else { return }
        let endedEdit = queuedMessageEdit?.id == id
        if endedEdit { queuedMessageEdit = nil }
        queuedUserMessages.removeAll { $0.id == id }
        if queuedUserMessages.isEmpty {
            queuedDispatchDeferredByEdit = false
        } else if endedEdit, queuedDispatchDeferredByEdit {
            startQueuedTurnIfNeeded()
        }
    }

    /// Snapshot the messages waiting at this response boundary. They remain in the
    /// queue until the global resume gate admits the turn, so a cross-window refusal
    /// is retryable instead of dropping user input. New sends are intentionally
    /// disabled during the tiny admission window; once admitted, later messages
    /// queue for the following round. An open edit transaction also pauses dispatch.
    private func startQueuedTurnIfNeeded() {
        guard !isResponding,
              !isResuming,
              !queuedUserMessages.isEmpty
        else { return }
        guard queuedMessageEdit == nil else {
            queuedDispatchDeferredByEdit = true
            return
        }
        queuedDispatchDeferredByEdit = false
        let batch = queuedUserMessages
        startTurn(
            visibleText: batch.map {
                composeUserMessage(
                    $0.rawText.trimmingCharacters(in: .whitespacesAndNewlines),
                    stagedSelection: $0.stagedSelection)
            }.joined(separator: "\n\n"),
            // The manifest boundary owns validation, de-duplication, and the
            // per-turn cap for both immediate and merged sends.
            mentionedReferences: batch.flatMap {
                PaperMentions.selectionsStillPresent(
                    in: $0.rawText,
                    from: $0.mentionSelections
                ).map(\.reference)
            },
            consumeStagedSelectionOnAdmission: false,
            queuedBatchCount: batch.count)
    }

    /// Searches the user's library for the composer's `@paper` popover. The
    /// injected production closure performs SQLite work off-main; keeping the
    /// controller database-agnostic preserves the test/debug composition roots.
    func searchMentionableReferences(_ rawQuery: String, limit: Int = 8) async -> [ChatReference] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = await mentionSearch(query, limit + 1)
        var seen = Set<Int64>()
        let currentReferenceID = activeConversationContext.referenceID
        return candidates.filter {
            $0.id > 0 && $0.id != currentReferenceID && seen.insert($0.id).inserted
        }.prefix(limit).map { $0 }
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
        cancelledTurnGeneration = generation
        provider.cancel()
        renderNotice("_Interrupted._")
    }

    /// Escape-key action for a live turn with queued input. The normal finalization
    /// path releases the current turn's gate and immediately starts the queued batch.
    @discardableResult
    func interruptAndSendQueued() -> Bool {
        guard isResponding,
              !isAwaitingTurnAdmission,
              !hasActiveQueuedMessageEdit,
              hasQueuedMessages
        else { return false }
        stop()
        return true
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
        queuedUserMessages.removeAll()
        queuedMessageEdit = nil
        queuedDispatchDeferredByEdit = false
        isAwaitingTurnAdmission = false
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
        let supersededActiveWork = isResponding || isResuming
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentTaskToken = nil
        attachmentQueue.removeAll()
        attachmentGeneration += 1
        attachmentConversationID = UUID()
        provider.cancel()
        generation += 1
        cancelledTurnGeneration = nil
        turnOutcome = AssistantTurnOutcome(
            generation: generation,
            phase: supersededActiveWork ? .superseded : .idle)
        conversationEpoch += 1
        resumeRequestGeneration += 1
        transcript.reset()
        toolDetails.removeAll()
        renderLog.removeAll()
        renderSeq = 0
        isResponding = false
        isResuming = false
        isAwaitingTurnAdmission = false
        statusText = nil
        busyElsewhere = false
        pendingApprovals.removeAll()
        queuedUserMessages.removeAll()
        queuedMessageEdit = nil
        queuedDispatchDeferredByEdit = false
        stagedSelection = nil
        resolvedModel = nil
        pendingPaperPresentations.removeAll()
        seenPaperPresentationCallIDs.removeAll()
        didPublishPaperPresentationThisTurn = false
        paperCompletionSuppressions = 0

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
                let recovered: [ChatAttachment]?
                if case .rehomeRecovered(let attachments) = error as? AssistantAttachmentStoreError {
                    recovered = attachments
                } else {
                    recovered = nil
                }
                if generation == self.attachmentGeneration {
                    if let recovered {
                        self.pendingAttachments = recovered
                    }
                    self.hasAttachmentRehomeFailure = true
                    self.attachmentIssues = [ChatAttachmentIssue(
                        displayName: "Attachments",
                        message: "Could not move attachments. Remove them or retry. \(error.localizedDescription)")]
                } else if let recovered {
                    await self.attachmentStore.removePending(recovered)
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
        beginFreshRubienConversation()
        if let defaults = defaultsProvider?(providerKind) {
            applyConversationDefaults(defaults)
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
        beginFreshRubienConversation()
        if let defaults = defaultsProvider?(providerKind) {
            applyConversationDefaults(defaults)
        }
        seedCodexModelIfUnset()
        refreshCodexCatalog()
        Task { await recheckAvailability() }
    }

    /// Keep every fresh-conversation entry point in lockstep when Settings gains a
    /// new default. Provider switches and the New conversation button both call it.
    private func applyConversationDefaults(_ defaults: AssistantConversationDefaults) {
        modelOverride = defaults.model
        effortOverride = defaults.effort
        webAccess = defaults.webAccess
        autoApprove = defaults.autoApprove
        loadUserTools = defaults.loadUserTools
        codexSandbox = defaults.codexSandbox
    }

    /// The runtime's own recent sessions for this conversation's working folder, for
    /// the History picker (§5.3). A light read of the provider's store; Rubien keeps
    /// nothing. Off-main inside the provider. `scopedToReference` keeps only sessions
    /// attributed to THIS document (the popover's default scope) — attribution is the
    /// rubien tool calls in the session, since neither runtime persists the seed.
    func listRecentSessions(limit: Int = 25, scopedToReference: Bool = false) async -> [AgentSessionSummary] {
        guard surfaceDefaultContext == .library, let attributionStore else {
            return await provider.recentSessions(
                workspaceURL: workspaceURL,
                limit: limit,
                referenceID: scopedToReference ? activeConversationContext.referenceID : nil)
        }
        return await attributedLibrarySessions(limit: limit, store: attributionStore) { requested in
            await provider.recentSessions(
                workspaceURL: workspaceURL, limit: requested, referenceID: nil)
        }
    }

    /// Content search over the provider's sessions for this conversation's working
    /// folder (History picker's search field, §5.3). `scopedToReference` as above.
    func searchSessions(
        _ query: String, limit: Int = 25, scopedToReference: Bool = false
    ) async -> [AgentSessionSummary] {
        guard surfaceDefaultContext == .library, let attributionStore else {
            return await provider.searchSessions(
                query: query,
                workspaceURL: workspaceURL,
                limit: limit,
                referenceID: scopedToReference ? activeConversationContext.referenceID : nil)
        }
        return await attributedLibrarySessions(limit: limit, store: attributionStore) { requested in
            await provider.searchSessions(
                query: query, workspaceURL: workspaceURL, limit: requested, referenceID: nil)
        }
    }

    /// Provider History cannot filter on Rubien's local Home attribution, so fetch
    /// progressively wider pages until enough attributed sessions survive or the
    /// provider is exhausted. Shared by recent and searched History to keep their
    /// caps and termination conditions identical.
    private func attributedLibrarySessions(
        limit: Int,
        store: AssistantSessionAttributionStore,
        fetch: (Int) async -> [AgentSessionSummary]
    ) async -> [AgentSessionSummary] {
        var requested = 50
        while true {
            let results = await fetch(requested)
            let ids = await store.librarySessionIDs(
                results.map(\.id), provider: providerKind, workspaceURL: workspaceURL)
            let matches = results.filter { ids.contains($0.id) }
            if matches.count >= limit || results.count < requested || requested == 500 {
                return Array(matches.prefix(limit))
            }
            requested = min(requested * 2, 500)
        }
    }

    /// Resume a past conversation from History: point the next turn at its session id
    /// (`--resume`) and start with a clean pane (Rubien has no stored transcript — D5).
    /// The provider stores no Rubien conversation-default snapshot, so the pane's
    /// current web/approval/tool posture intentionally carries into the resume. The
    /// resumed session already carries its seed/context, so `seedSent` is set to avoid
    /// re-seeding. A notice with the preview gives the user their bearings.
    func resume(_ summary: AgentSessionSummary) {
        resumeRequestGeneration += 1
        let requestGeneration = resumeRequestGeneration
        if let attributionStore {
            isResuming = true
            let providerKind = providerKind
            let workspaceURL = workspaceURL
            Task { [weak self] in
                guard let self else { return }
                let attribution = await attributionStore.attribution(
                    sessionID: summary.id,
                    provider: providerKind,
                    workspaceURL: workspaceURL)
                guard requestGeneration == self.resumeRequestGeneration,
                      providerKind == self.providerKind,
                      workspaceURL == self.workspaceURL
                else { return }
                self.resume(summary, attribution: attribution)
            }
            return
        }
        guard requestGeneration == resumeRequestGeneration else { return }
        resume(summary, attribution: nil)
    }

    private func resume(
        _ summary: AgentSessionSummary,
        attribution: AssistantSessionAttributionStore.Attribution?
    ) {
        resetConversationState(attachments: .discard)
        rubienConversationID = attribution?.conversationId ?? UUID()
        assistantActivityContext = nil
        assistantActivityStartConsumed = true
        switch attribution?.context {
        case .library?: activeConversationContext = .library
        case .reference(let id)?:
            activeConversationContext = .reference(ChatReference(
                id: id, title: "Reference \(id)", authors: ""))
        case nil: activeConversationContext = .unclassifiedResume
        }
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
        if isResponding {
            turnOutcome = AssistantTurnOutcome(
                generation: generation,
                phase: pendingApprovals.isEmpty ? .responding : .approvalRequired)
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
    /// the `resume()` notice precedent). Pending attachments are preserved and
    /// rehomed exactly like `switchProvider` — the reset is implicit, and only an
    /// explicit "New conversation" (or resume, which also clears the draft)
    /// discards them — and, also like `switchProvider`, a pick is ignored while
    /// staging/rehome is unsettled. Claude switches live (per-turn `--model`)
    /// and is NOT remembered here (its default lives in Settings). An explicit pick
    /// snaps effort to the model's own default when the catalog knows it (spec §3);
    /// a nil id (transient pre-seed / programmatic only) leaves effort alone.
    func selectModel(_ id: String?) {
        guard id != modelOverride else { return }
        if providerKind == .codex, hasMessages {
            guard !isStagingAttachments, !hasAttachmentRehomeFailure else { return }
            RubienPreferences.assistantCodexModel = id  // remember the pick as the default
            resetConversationState(attachments: .preserveAndRehome)
            liveSessionID = nil
            seedSent = false
            modelOverride = id
            snapEffortToModelDefault(id)
            beginFreshRubienConversation()
            hasMessages = true
            renderNotice("_New conversation — Codex applies a model change to a fresh conversation._")
            return
        }
        if providerKind == .codex {
            RubienPreferences.assistantCodexModel = id  // remember the pick as the default
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

    private func beginFreshRubienConversation() {
        rubienConversationID = UUID()
        assistantActivityContext = nil
        assistantActivityStartConsumed = false
        activeConversationContext = surfaceDefaultContext
    }

    /// Snapshot the Assistant epoch only after the global turn gate admits the
    /// first turn. A rejected send remains an empty, non-counting conversation.
    private func prepareAssistantActivityCaptureIfNeeded() {
        guard !assistantActivityStartConsumed,
              assistantActivityContext == nil,
              let activityDatabase
        else { return }
        assistantActivityContext = try? activityDatabase.activityCaptureContext(for: .assistant)
    }

    private func recordAssistantActivityStartIfNeeded() {
        guard !assistantActivityStartConsumed else { return }
        assistantActivityStartConsumed = true
        guard RubienPreferences.recordAssistantActivity,
              let activityDatabase,
              let context = assistantActivityContext
        else { return }

        let startedAt = Date()
        let localDay = LocalDay(
            date: startedAt,
            calendar: AppDatabase.activityCalendar())
        let conversationID = rubienConversationID.uuidString.lowercased()
        let provider = providerKind.rawValue
        Task.detached(priority: .utility) {
            let result = try? activityDatabase.recordAssistantActivity(
                conversationId: conversationID,
                provider: provider,
                startedAt: startedAt,
                localDay: localDay,
                context: context)
            if result != nil {
                await MainActor.run {
                    NotificationCenter.default.post(name: .rubienActivityDidChange, object: nil)
                }
            }
        }
    }

    // MARK: Event mapping (internal for testing)

    func handle(_ event: AgentEvent, gen: Int) {
        guard gen == generation else { return }  // drop a superseded turn's late events
        switch event {
        case .sessionStarted(let id):
            liveSessionID = id
            seedSent = true  // the seed-bearing process started → the seed was delivered
            if let attributionStore {
                let providerKind = providerKind
                let workspaceURL = workspaceURL
                let conversationID = rubienConversationID
                let context = activeConversationContext
                Task {
                    await attributionStore.record(
                        sessionID: id,
                        provider: providerKind,
                        workspaceURL: workspaceURL,
                        conversationId: conversationID,
                        context: context)
                }
            }
            recordAssistantActivityStartIfNeeded()
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
            if ChatPaperPresentation.isPresentationTool(name) {
                let detail = popToolDetail(name)
                if paperCompletionSuppressions > 0 {
                    paperCompletionSuppressions -= 1
                    break
                }
                // A successful private-tool completion without a corresponding
                // typed presentation means the result was malformed. Keep that
                // failure visible instead of silently swallowing the tool row.
                renderToolChip(ToolChipPayload(
                    name: name,
                    detail: detail ?? "Paper presentation result was invalid",
                    status: .completed))
                break
            }
            renderToolChip(ToolChipPayload(name: name, detail: popToolDetail(name), status: .completed))
        case .paperPresentation(let callID, let ordinal, let group):
            guard !didPublishPaperPresentationThisTurn,
                  seenPaperPresentationCallIDs.insert(callID).inserted
            else { break }
            pendingPaperPresentations[callID] = (ordinal, group)
            paperCompletionSuppressions += 1
        case .approvalRequested(let id, let toolName, let summary):
            // The Rubien catalog is exact-name classified. Known reads stay
            // silent; known writes card in Ask and auto-accept in Auto. Any
            // future/unclassified Rubien tool is denied even in Auto so a newly
            // added mutation can never inherit a permissive prefix rule.
            if Self.isUnknownRubienTool(toolName) {
                provider.respondToApproval(id: id, .deny)
            } else if autoApprove || Self.isSilentReadTool(toolName) {
                provider.respondToApproval(id: id, .allowForConversation)  // no card
            } else {
                pendingApprovals.append(PendingApproval(id: id, toolName: toolName, summary: summary))
                turnOutcome = AssistantTurnOutcome(
                    generation: gen,
                    phase: .approvalRequired)
            }
        case .toolDenied(let name, let reason):
            _ = popToolDetail(name)
            renderToolChip(ToolChipPayload(name: name, detail: reason, status: .denied))
        case .turnCompleted:
            publishPendingPaperPresentationsIfNeeded()
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

    private func publishPendingPaperPresentationsIfNeeded() {
        guard !didPublishPaperPresentationThisTurn,
              !pendingPaperPresentations.isEmpty
        else { return }

        let calls = pendingPaperPresentations.map {
            (callID: $0.key, ordinal: $0.value.ordinal, group: $0.value.group)
        }

        pendingPaperPresentations.removeAll()
        didPublishPaperPresentationThisTurn = true
        guard let group = ChatPaperPresentation.merge(calls) else { return }
        transcript.addPaperGroup(group)
        if let body = ChatPaperPresentation.encodeHistoryGroup(group) {
            appendToLog(.paper, body)
        }
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
    private func finalize(gen: Int, terminalPhase: AssistantTurnOutcome.Phase) {
        guard gen == generation else { return }
        publishPendingPaperPresentationsIfNeeded()
        let phase: AssistantTurnOutcome.Phase = cancelledTurnGeneration == gen
            ? .cancelled
            : terminalPhase
        turnOutcome = AssistantTurnOutcome(generation: gen, phase: phase)
        cancelledTurnGeneration = nil
        isResponding = false
        isAwaitingTurnAdmission = false
        statusText = nil
        pendingApprovals.removeAll()
        toolDetails.removeAll()
        turnTask = nil
        startQueuedTurnIfNeeded()
    }

    /// A turn refused by the gate (busy in another window): surface it and re-enable the
    /// composer without having rendered the user message.
    private func refuseTurn(gen: Int) {
        guard gen == generation else { return }
        busyElsewhere = true
        renderNotice("This conversation is busy in another window. Try again in a moment.")
        turnOutcome = AssistantTurnOutcome(generation: gen, phase: .idle)
        isResponding = false
        isAwaitingTurnAdmission = false
        statusText = nil
        turnTask = nil
    }

    /// Claude's read/search builtins that are safe to run without a prompt.
    private static let silentReadBuiltins: Set<String> = [
        "ToolSearch", "Read", "Glob", "Grep", "LS", "NotebookRead", "WebFetch", "WebSearch",
    ]

    /// Whether a tool may run without an approval card even in "Ask" mode.
    static func isSilentReadTool(_ toolName: String) -> Bool {
        if let rubienName = bareRubienToolName(toolName) {
            return rubienName == ChatPaperPresentation.toolName
                || RubienMCPToolPolicy.access(for: rubienName) == .read
        }
        return silentReadBuiltins.contains(toolName)
    }

    /// A qualified Rubien tool that is absent from the canonical policy. This is
    /// deliberately separate from `isSilentReadTool`: Auto mode must deny it,
    /// not merely turn it into a card or auto-approve it.
    static func isUnknownRubienTool(_ toolName: String) -> Bool {
        guard let bare = bareRubienToolName(toolName) else { return false }
        return bare != ChatPaperPresentation.toolName
            && RubienMCPToolPolicy.access(for: bare) == nil
    }

    /// Normalize Claude (`mcp__rubien__tool`) and Codex (`rubien/tool`) display
    /// names. Bare canonical names are accepted for protocol compatibility.
    private static func bareRubienToolName(_ toolName: String) -> String? {
        if toolName.hasPrefix(ReferenceAttribution.claudeToolPrefix) {
            return String(toolName.dropFirst(ReferenceAttribution.claudeToolPrefix.count))
        }
        let codexPrefix = "\(ReferenceAttribution.serverName)/"
        if toolName.hasPrefix(codexPrefix) {
            return String(toolName.dropFirst(codexPrefix.count))
        }
        if toolName.hasPrefix("rubien_") { return toolName }
        return nil
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
        composeUserMessage(text, stagedSelection: stagedSelection)
    }

    private func composeUserMessage(
        _ text: String,
        stagedSelection staged: StagedSelection?
    ) -> String {
        guard let staged else { return text }
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
