import Foundation
#if canImport(CoreFoundation)
import CoreFoundation  // CFGetTypeID/CFBooleanGetTypeID: not re-exported by Foundation on Linux
#endif

// MARK: - Agent provider engine (Phase 2a)
//
// The headless subprocess layer behind the Assistant chat sidebar. A later phase's
// `ChatSessionController` drives these types; there is deliberately **no UI here**.
// Everything in this file is pure Foundation (AppKit-free, not `#if os(macOS)`-gated)
// so `swift test --filter RubienTests` exercises it without a running app.
//
// Contract source: design doc §4.1 (protocol / events / process mechanics) and §4.2
// (Claude stream-json + control mapping, verified against `claude` 2.1.201).

/// Which coding-agent runtime a provider wraps. Per-backend static data (display
/// name, model/effort lists, defaults, sandbox support) lives in ONE place —
/// `AgentBackendDescriptor` (see `AssistantModelOptions.swift`) — so adding a
/// backend is a single literal, not a new case across a dozen `switch` sites.
enum AgentProviderKind: String, Codable, Sendable, Equatable, CaseIterable {
    case claude
    case codex
}

/// Codex OS-sandbox mode (D6). Carried on every turn request for a uniform shape
/// across providers; ignored by `ClaudeCodeProvider` (Claude uses the control
/// protocol, not an OS sandbox). The concrete `CodexProvider` lands in Phase 3.
enum CodexSandbox: String, Codable, Sendable, Equatable {
    case readOnly
    case workspaceWrite
}

/// Scheduled turns have no person present to approve tools. Providers use this
/// mode to pin their approval posture and expose Rubien's read-only MCP catalog.
enum AgentExecutionMode: String, Codable, Sendable, Equatable {
    case interactive
    case scheduled
}

/// One user turn to run. Prompt + approval responses ride the process **stdin**;
/// continuity is the runtime's `--resume`.
struct AgentTurnRequest: Sendable, Equatable {
    /// The agent's working directory (cwd). One shared, user-configurable folder
    /// (D4) — not per-reference.
    let workspaceURL: URL
    /// Rubien's stable identity for the surrounding conversation. Unlike the
    /// provider session id, this exists before Claude emits `system/init` and is
    /// replaced immediately by New Conversation/History resume. Providers use it
    /// to distinguish an early same-conversation steer from unrelated nil-id work.
    let conversationID: UUID?
    /// The provider session id to `--resume`, or `nil` to start a new conversation.
    let resumeSessionID: String?
    /// The user's message text. Delivered as a stream-json `user` message on stdin
    /// (never argv — avoids ARG_MAX/quoting; §4.2).
    let prompt: String
    /// Local, staged attachments for this turn. Providers translate these into their
    /// native image/file inputs; the default keeps every text-only call site stable.
    let attachments: [ChatAttachment]
    /// Rubien's trusted instructions for the surrounding conversation (D4).
    /// Claude applies them as `--append-system-prompt` on every per-turn CLI
    /// process because `--resume` does not persist that flag. Codex supplies them
    /// as thread-level developer instructions when starting a new thread.
    let seed: String?
    /// Web toggle. When `false`, Claude gets `--disallowedTools "WebFetch WebSearch"`.
    let webAccess: Bool
    /// Opt in to the provider's normal connected apps, plugins, settings, and
    /// user-configured MCP servers. Default off; Rubien's own MCP server remains
    /// available in either posture.
    let loadUserTools: Bool
    /// Codex sandbox mode (Phase 3). Ignored by the Claude provider.
    let codexSandbox: CodexSandbox
    /// Optional model override (empty/`nil` = CLI default). Passed as `--model`.
    let modelOverride: String?
    /// Optional reasoning-effort override (empty/`nil` = CLI default). Claude:
    /// `--effort <low|medium|high|xhigh|max>` (verified 2.1.201). Codex (Phase 3):
    /// maps to `model_reasoning_effort`.
    let effortOverride: String?
    /// Interactive chat or unattended scheduled execution.
    let executionMode: AgentExecutionMode

    init(
        workspaceURL: URL,
        conversationID: UUID? = nil,
        resumeSessionID: String? = nil,
        prompt: String,
        attachments: [ChatAttachment] = [],
        seed: String? = nil,
        webAccess: Bool = true,
        loadUserTools: Bool = false,
        codexSandbox: CodexSandbox = .readOnly,
        modelOverride: String? = nil,
        effortOverride: String? = nil,
        executionMode: AgentExecutionMode = .interactive
    ) {
        self.workspaceURL = workspaceURL
        self.conversationID = conversationID
        self.resumeSessionID = resumeSessionID
        self.prompt = prompt
        self.attachments = attachments
        self.seed = seed
        self.webAccess = webAccess
        self.loadUserTools = loadUserTools
        self.codexSandbox = codexSandbox
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
        self.executionMode = executionMode
    }
}

/// Token accounting for a completed turn (parsed from the `result` event's `usage`
/// + `total_cost_usd`). All fields optional — a field the runtime omits stays `nil`.
struct AgentUsage: Sendable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheCreationTokens: Int?
    var totalCostUSD: Double?

    init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        totalCostUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalCostUSD = totalCostUSD
    }

    /// `true` when every field is `nil` — the parser returns `nil` instead of an
    /// all-empty value so `turnCompleted(usage:)` reads cleanly.
    var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil && cacheReadTokens == nil
            && cacheCreationTokens == nil && totalCostUSD == nil
    }
}

/// The provider's authoritative terminal disposition for a turn. This is kept
/// separate from process/stream termination: both runtimes can end their event
/// stream normally after reporting a failed or interrupted turn.
enum AgentTurnOutcome: Sendable, Equatable {
    case succeeded
    case failed
    case interrupted
}

/// Terminal turn metadata carried as one associated value so existing consumers
/// that only need to recognize `.turnCompleted` remain source-compatible.
struct AgentTurnCompletion: Sendable, Equatable {
    let outcome: AgentTurnOutcome
    let usage: AgentUsage?
}

/// A single event streamed out of a running turn. The mapping from the runtime's
/// stream-json lines is in `ClaudeStreamParser` (§4.2).
enum AgentEvent: Sendable, Equatable {
    /// The turn's session id. Emitted from `system/init` at turn start **and again**
    /// from every `result` — the id **rotates each resume turn** (D5), so the
    /// controller must treat the latest `sessionStarted` as the id to `--resume`.
    case sessionStarted(sessionID: String)
    /// The model the runtime RESOLVED for this conversation — reported by codex's
    /// `thread/start`/`thread/resume` response, including (especially) when the
    /// request omitted `model` (a transient unseeded turn: codex applies its own
    /// config chain — spec §2.2). Claude never emits this.
    case modelResolved(model: String)
    /// A streamed partial-text chunk (from `--include-partial-messages`).
    case assistantDelta(text: String)
    /// The authoritative text of a completed assistant message.
    case assistantMessageCompleted(text: String)
    /// A tool call began (an `assistant` message `tool_use` block).
    case toolUseStarted(name: String, detail: String?)
    /// A tool call produced a result (a `user` `tool_result` block).
    case toolUseCompleted(name: String)
    /// Successful, bounded result from Rubien's app-private presentation tool.
    case paperPresentation(callID: String, ordinal: Int, group: ChatPaperGroup)
    /// Claude's control protocol wants approval for a tool. `id` is the control
    /// `request_id`; answer with `respondToApproval(id:_:)`.
    case approvalRequested(id: String, toolName: String, summary: String)
    /// A tool was denied — a `result` `permission_denials[]` entry (Claude) or a
    /// Codex sandbox block (Phase 3).
    case toolDenied(name: String, reason: String)
    /// The turn finished (`result` / `turn/completed`). Composer re-enables.
    case turnCompleted(AgentTurnCompletion)
    /// An out-of-band notice surfaced as chat content: a rate-limit warning, a
    /// non-zero exit, an auth problem, etc.
    case providerNotice(String)

    /// Compatibility constructor for callers and test doubles whose completed
    /// turn is successful by definition.
    static func turnCompleted(usage: AgentUsage?) -> AgentEvent {
        .turnCompleted(AgentTurnCompletion(outcome: .succeeded, usage: usage))
    }

    /// Constructor used by provider parsers, where terminal status is explicit.
    static func turnCompleted(outcome: AgentTurnOutcome, usage: AgentUsage?) -> AgentEvent {
        .turnCompleted(AgentTurnCompletion(outcome: outcome, usage: usage))
    }
}

/// The user's answer to a Claude `approvalRequested`.
///
/// Wire mapping (§4.2): `allowOnce`/`allowForConversation` both send
/// `behavior:"allow"` with the original `updatedInput`; the *remembering* of an
/// "allow for this conversation" grant is the controller's job (kept in-app —
/// Risk #12), so at the wire level the two allow cases are identical. `deny` sends
/// `behavior:"deny", interrupt:true`.
enum ApprovalDecision: Sendable, Equatable {
    case allowOnce
    case allowForConversation
    case deny

    /// The `behavior` string written in the `control_response`.
    var behavior: String {
        switch self {
        case .allowOnce, .allowForConversation: return "allow"
        case .deny: return "deny"
        }
    }

    var isAllow: Bool { behavior == "allow" }
}

/// Structured result of an availability probe, so the (future) empty-state UI can
/// explain exactly what is missing rather than just hiding the feature.
struct AgentAvailability: Sendable, Equatable {
    /// The binary was located and answered a `--version` probe.
    var isInstalled: Bool
    /// Best-effort auth signal. Phase 2a captures install + version reliably; a
    /// hard non-interactive auth probe isn't part of the verified 2.1.201 surface,
    /// so this defaults to `isInstalled` and a real auth failure is surfaced
    /// per-turn as a `providerNotice` (§4.5). A later phase can tighten it.
    var isAuthenticated: Bool
    /// The reported CLI version (e.g. `2.1.201`), when the probe succeeded.
    var version: String?
    /// The absolute path the binary resolved to.
    var resolvedPath: String?
    /// A human-readable reason when `!isInstalled` (or auth is known-bad).
    var unavailableReason: String?

    var isReady: Bool { isInstalled && isAuthenticated }

    static func notFound(reason: String) -> AgentAvailability {
        AgentAvailability(
            isInstalled: false, isAuthenticated: false, version: nil,
            resolvedPath: nil, unavailableReason: reason)
    }

    static func installed(version: String?, path: String) -> AgentAvailability {
        AgentAvailability(
            isInstalled: true, isAuthenticated: true, version: version,
            resolvedPath: path, unavailableReason: nil)
    }

    static func installedButUnauthenticated(version: String?, path: String, reason: String) -> AgentAvailability {
        AgentAvailability(
            isInstalled: true, isAuthenticated: false, version: version,
            resolvedPath: path, unavailableReason: reason)
    }
}

/// One past conversation the provider owns, surfaced in the History picker (§5.3).
/// Rubien stores no transcripts (D5) — this is a light read of the runtime's OWN
/// session store (Claude: `~/.claude/projects/<cwd>/<id>.jsonl`), just enough to
/// pick one to `--resume`. `id` is the runtime session id (the resume target).
struct AgentSessionSummary: Identifiable, Sendable, Equatable {
    /// The runtime session id — the `--resume <id>` target and the picker identity.
    let id: String
    /// First user-message preview (whitespace-collapsed, truncated).
    let preview: String
    /// Last-activity time (the session file's modification date), for sort + display.
    let date: Date
    /// For a content-search hit: a whitespace-collapsed snippet around the first
    /// match (with "…" where clipped). nil for plain recents listings.
    var matchSnippet: String? = nil
}

/// A bounded History lookup. Providers may return rows decoded before a timeout;
/// callers should show those partial results together with a retry affordance.
struct AgentSessionQueryResult: Sendable, Equatable {
    let sessions: [AgentSessionSummary]
    let didTimeOut: Bool

    static func completed(_ sessions: [AgentSessionSummary]) -> Self {
        Self(sessions: sessions, didTimeOut: false)
    }
}

enum AgentHistoryPolicy {
    /// One user-visible recents/search load, including Home attribution widening.
    static let loadTimeout: TimeInterval = 8
}

/// How a stored conversation is attributed to a reference — the History popover's
/// "This document" scope. Neither provider's history surface exposes Rubien's
/// instructions (Claude omits `--append-system-prompt` from JSONL; Codex omits
/// `developerInstructions` from `thread/read`), so the recoverable signal is the
/// rubien MCP TOOL CALLS a conversation contains: the seeded agent reads the
/// document through them, and their arguments carry the reference id. ONE shared
/// policy — which tools, which argument keys, how values coerce — so the Claude
/// (JSONL `tool_use`) and Codex (`thread/read` `mcpToolCall`) scanners cannot drift.
enum ReferenceAttribution {
    /// Our server's registration key, as codex reports it in `mcpToolCall.server`.
    static var serverName: String { MCPContentChannel.serverName }

    /// Claude's fully-qualified tool-name prefix for our server (claude names MCP
    /// tools `mcp__<server>__<tool>`). Also the silent-read-tool gate's prefix.
    static var claudeToolPrefix: String { "mcp__\(serverName)__" }

    /// The reference ids one rubien tool call addresses. `tool` is the BARE tool
    /// name (codex's `tool` field; claude callers strip `claudeToolPrefix` first).
    /// Handles scalar and array-shaped keys (`ids`).
    static func referencedIDs(tool: String, arguments: [String: Any]) -> Set<Int64> {
        var ids: Set<Int64> = []
        for key in referenceKeys(for: tool) {
            switch arguments[key] {
            case let array as [Any]:
                ids.formUnion(array.compactMap(referenceArgument))
            case let value?:
                if let id = referenceArgument(value) { ids.insert(id) }
            default:
                break
            }
        }
        return ids
    }

    /// Which argument keys carry REFERENCE ids, per tool — tool-aware because the
    /// keys are not uniform and `id` is not always a reference. Sources of truth:
    /// `mcp-server/src/tools/*.ts` / `Sources/RubienCLI/MCPToolCatalog.swift`.
    /// The Assistant's full native server includes reads and approval-gated
    /// writes. Unknown tools fall back to
    /// `id`/`referenceId` so a future read tool still attributes (over-inclusion
    /// beats a miss in a display filter).
    static func referenceKeys(for tool: String) -> [String] {
        // The trap: on the OLD-generation properties tools `id`/`ids` are
        // PROPERTY rowids — a colliding id namespace (`rubien_properties_set
        // {reference: 900, id: "29"}` addresses reference 900, property 29).
        // The reference, where one exists, is always the `reference` argument.
        // These rules are correct for historical sessions and must not change.
        if neverAttribute.contains(tool) { return [] }
        if tool.hasPrefix("rubien_properties_") { return ["reference"] }
        return toolKeys[tool] ?? ["id", "referenceId"]
    }

    /// Tools whose id-shaped arguments are NEVER reference ids. The new
    /// {op}_{target} definition/option/view tools carry property/option/view
    /// ids (`id` / `propertyId`), which the default rule would mis-attribute.
    /// Old-generation fix in passing: `rubien_views_query`'s scalar `id` is a
    /// VIEW id — a pre-existing latent mis-attribution for historical sessions
    /// (the other old views_* write tools were never registered in the earlier
    /// read-only channel, so no historical session contains them). New-gen
    /// `list_properties`/`list_views` and `create_reference` carry no
    /// default-rule key, safe without entries; `update_reference` attributes
    /// its top-level `id` via the default rule and never its payload keys.
    private static let neverAttribute: Set<String> = [
        "rubien_create_property", "rubien_update_property", "rubien_delete_property",
        "rubien_create_option", "rubien_update_option", "rubien_delete_option",
        "rubien_create_view", "rubien_update_view", "rubien_delete_view",
        "rubien_views_query",
    ]

    /// Only the tools whose keys the default can't cover: array-shaped `ids`
    /// (delete/cite/export address MANY references; both delete generations).
    /// `rubien_get_reference`/`get_pdf_info`/`render_pdf_page` (`id`) and the
    /// old `annotations_list`/`web_*` (`referenceId`) ride the default.
    private static let toolKeys: [String: [String]] = [
        "rubien_delete": ["ids"],
        "rubien_delete_reference": ["ids"],
        "rubien_cite": ["ids"],
        "rubien_export": ["ids"],
    ]

    /// A tool argument as a reference id. Numbers and digit strings both count
    /// (a mistyped `"id":"42"` call fails the tool but was still ADDRESSING that
    /// reference) — but a boolean (`{"id":true}` must not attribute reference 1;
    /// JSON booleans are NSNumber-backed, CFBoolean check per `MCPToolCatalog`
    /// precedent) or a fractional number (42.9 is not reference 42) never does.
    static func referenceArgument(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            guard double == double.rounded(.towardZero) else { return nil }
            return number.int64Value
        }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}

/// The engine a chat sidebar drives. One instance per provider kind; a turn is one
/// subprocess (D3). Serialization across windows is the caller's job via
/// `AssistantTurnGate`.
protocol AgentProvider: Sendable {
    var kind: AgentProviderKind { get }

    /// Locate the binary + probe version/auth. Cached; safe to call from a UI
    /// refresh. Never blocks indefinitely (bounded internal timeout).
    func isAvailable() async -> AgentAvailability

    /// Spawn one turn and stream its events. Breaking/cancelling the returned stream
    /// ends THE TURN (via `onTermination`): Claude kills the turn's process group
    /// (its process is the turn); Codex sends `turn/interrupt` and its long-lived
    /// app-server stays alive (Phase 3b).
    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error>

    /// Answer a pending `approvalRequested`. Claude: writes the `control_response`
    /// to the live turn's stdin. Codex: answers the server-initiated JSON-RPC
    /// approval request (Phase 3b).
    func respondToApproval(id: String, _ decision: ApprovalDecision)

    /// Stop the CURRENT TURN. Claude: native stream-json `interrupt`, then bounded
    /// SIGTERM/SIGKILL fallback. Codex: `turn/interrupt` — the server lives on so
    /// the conversation can continue.
    func cancel()

    /// End this provider wrapper (window close). A dedicated live process tree is
    /// terminated; the shared Codex app-server remains available for the app lifetime.
    /// Distinct from `cancel()` for providers whose process outlives a turn. Default: `cancel()`
    /// Claude overrides this too: teardown is terminal and rejects delayed sends,
    /// while graceful Stop may hand the rotated session to a queued successor.
    func shutdown()

    /// The runtime's own recent sessions for `workspaceURL`, newest first, for the
    /// History picker (§5.3). A light read of the runtime's session store — Rubien
    /// stores nothing. A non-nil `referenceID` keeps only sessions attributed to
    /// that reference (the popover's "This document" scope): neither provider's
    /// history surface exposes the instructions, so attribution is the rubien MCP
    /// tool calls whose arguments carry the reference id. `deadline` lets a caller
    /// keep progressive filtering inside one UI budget. Default: completed `[]`.
    func recentSessionsResult(
        workspaceURL: URL, limit: Int, referenceID: Int64?, deadline: Date?
    ) async -> AgentSessionQueryResult

    /// A picked session's full renderable transcript, so a resume restores the
    /// conversation's content (still read from the runtime's own store — Rubien
    /// stores nothing). Default `[]` → the caller shows a preview notice instead.
    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage]

    /// Content search over the runtime's sessions for `workspaceURL` (the visible
    /// user/assistant text, not tool payloads), newest first, each hit carrying a
    /// `matchSnippet`. `referenceID` scopes hits like `recentSessions`. Default
    /// `deadline` has the same progressive-load semantics as recents. Default:
    /// completed `[]` (a provider without a readable store).
    func searchSessionsResult(
        query: String, workspaceURL: URL, limit: Int, referenceID: Int64?,
        deadline: Date?
    ) async -> AgentSessionQueryResult

    /// The models the installed runtime reports it supports, for the model picker.
    /// Three states (spec §4.3): `nil` — this backend has no discovery surface
    /// (Claude → static list); `.fetchedOK == false` — discovery attempted and
    /// failed (→ degraded picker); otherwise the live list. Never blocks a turn.
    func availableModels() async -> CodexCatalog?
}

extension AgentProvider {
    func shutdown() { cancel() }
    func recentSessionsResult(
        workspaceURL: URL, limit: Int, referenceID: Int64?, deadline: Date?
    ) async -> AgentSessionQueryResult {
        .completed([])
    }
    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage] { [] }
    func searchSessionsResult(
        query: String, workspaceURL: URL, limit: Int, referenceID: Int64?,
        deadline: Date?
    ) async -> AgentSessionQueryResult {
        .completed([])
    }
    func availableModels() async -> CodexCatalog? { nil }

    /// Array-only and no-deadline conveniences for existing callers/tests. The
    /// status-preserving result methods above are the provider implementation seam.
    func recentSessions(
        workspaceURL: URL, limit: Int, referenceID: Int64?
    ) async -> [AgentSessionSummary] {
        await recentSessionsResult(
            workspaceURL: workspaceURL, limit: limit,
            referenceID: referenceID, deadline: nil).sessions
    }
    func recentSessionsResult(
        workspaceURL: URL, limit: Int, referenceID: Int64?
    ) async -> AgentSessionQueryResult {
        await recentSessionsResult(
            workspaceURL: workspaceURL, limit: limit,
            referenceID: referenceID, deadline: nil)
    }
    func searchSessions(
        query: String, workspaceURL: URL, limit: Int, referenceID: Int64?
    ) async -> [AgentSessionSummary] {
        await searchSessionsResult(
            query: query, workspaceURL: workspaceURL, limit: limit,
            referenceID: referenceID, deadline: nil).sessions
    }
    func searchSessionsResult(
        query: String, workspaceURL: URL, limit: Int, referenceID: Int64?
    ) async -> AgentSessionQueryResult {
        await searchSessionsResult(
            query: query, workspaceURL: workspaceURL, limit: limit,
            referenceID: referenceID, deadline: nil)
    }
    func recentSessions(workspaceURL: URL, limit: Int) async -> [AgentSessionSummary] {
        await recentSessions(workspaceURL: workspaceURL, limit: limit, referenceID: nil)
    }
    func searchSessions(query: String, workspaceURL: URL, limit: Int) async -> [AgentSessionSummary] {
        await searchSessions(query: query, workspaceURL: workspaceURL, limit: limit, referenceID: nil)
    }
}

/// Errors thrown *into* a turn's event stream (vs. `providerNotice`, which is a
/// surfaced-as-content soft error). A hard failure to even start the process.
enum AgentProviderError: LocalizedError, Equatable, Sendable {
    /// No runnable binary at the override/discovered path.
    case executableNotFound(String)
    /// `posix_spawn` itself failed.
    case spawnFailed(code: Int32)
    /// A staged attachment vanished, became unreadable, or no longer has a
    /// provider-supported representation before the turn could start.
    case attachmentUnreadable(String)
    /// Scheduled Codex could not enumerate and disable ambient MCP servers.
    case isolationUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "The assistant executable \(path) could not be found."
        case .spawnFailed(let code):
            return "The assistant process could not be started (error \(code))."
        case .attachmentUnreadable(let name):
            return "The attachment \(name) could not be read before sending."
        case .isolationUnavailable:
            return "Codex's configured tools could not be isolated for this scheduled run."
        }
    }
}
