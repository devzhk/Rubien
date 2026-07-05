import Foundation

// MARK: - Agent provider engine (Phase 2a)
//
// The headless subprocess layer behind the Assistant chat sidebar. A later phase's
// `ChatSessionController` drives these types; there is deliberately **no UI here**.
// Everything in this file is pure Foundation (AppKit-free, not `#if os(macOS)`-gated)
// so `swift test --filter RubienTests` exercises it without a running app.
//
// Contract source: design doc §4.1 (protocol / events / process mechanics) and §4.2
// (Claude stream-json + control mapping, verified against `claude` 2.1.201).

/// Which coding-agent runtime a provider wraps.
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

/// One user turn to run. Prompt + approval responses ride the process **stdin**;
/// continuity is the runtime's `--resume`.
struct AgentTurnRequest: Sendable, Equatable {
    /// The agent's working directory (cwd). One shared, user-configurable folder
    /// (D4) — not per-reference.
    let workspaceURL: URL
    /// The provider session id to `--resume`, or `nil` to start a new conversation.
    let resumeSessionID: String?
    /// The user's message text. Delivered as a stream-json `user` message on stdin
    /// (never argv — avoids ARG_MAX/quoting; §4.2).
    let prompt: String
    /// The one-line reference seed naming the reference id (D4). First turn only
    /// (`nil` on resume — `--resume` carries it forward). Applied as Claude's
    /// `--append-system-prompt`.
    let seed: String?
    /// Web toggle. When `false`, Claude gets `--disallowedTools "WebFetch WebSearch"`.
    let webAccess: Bool
    /// Codex sandbox mode (Phase 3). Ignored by the Claude provider.
    let codexSandbox: CodexSandbox
    /// Optional model override (empty/`nil` = CLI default). Passed as `--model`.
    let modelOverride: String?

    init(
        workspaceURL: URL,
        resumeSessionID: String? = nil,
        prompt: String,
        seed: String? = nil,
        webAccess: Bool = true,
        codexSandbox: CodexSandbox = .readOnly,
        modelOverride: String? = nil
    ) {
        self.workspaceURL = workspaceURL
        self.resumeSessionID = resumeSessionID
        self.prompt = prompt
        self.seed = seed
        self.webAccess = webAccess
        self.codexSandbox = codexSandbox
        self.modelOverride = modelOverride
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

/// A single event streamed out of a running turn. The mapping from the runtime's
/// stream-json lines is in `ClaudeStreamParser` (§4.2).
enum AgentEvent: Sendable, Equatable {
    /// The turn's session id. Emitted from `system/init` at turn start **and again**
    /// from every `result` — the id **rotates each resume turn** (D5), so the
    /// controller must treat the latest `sessionStarted` as the id to `--resume`.
    case sessionStarted(sessionID: String)
    /// A streamed partial-text chunk (from `--include-partial-messages`).
    case assistantDelta(text: String)
    /// The authoritative text of a completed assistant message.
    case assistantMessageCompleted(text: String)
    /// A tool call began (an `assistant` message `tool_use` block).
    case toolUseStarted(name: String, detail: String?)
    /// A tool call produced a result (a `user` `tool_result` block).
    case toolUseCompleted(name: String)
    /// Claude's control protocol wants approval for a tool. `id` is the control
    /// `request_id`; answer with `respondToApproval(id:_:)`.
    case approvalRequested(id: String, toolName: String, summary: String)
    /// A tool was denied — a `result` `permission_denials[]` entry (Claude) or a
    /// Codex sandbox block (Phase 3).
    case toolDenied(name: String, reason: String)
    /// The turn finished (`result`). Composer re-enables.
    case turnCompleted(usage: AgentUsage?)
    /// An out-of-band notice surfaced as chat content: a rate-limit warning, a
    /// non-zero exit, an auth problem, etc.
    case providerNotice(String)
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
}

/// The engine a chat sidebar drives. One instance per provider kind; a turn is one
/// subprocess (D3). Serialization across windows is the caller's job via
/// `AssistantTurnGate`.
protocol AgentProvider: Sendable {
    var kind: AgentProviderKind { get }

    /// Locate the binary + probe version/auth. Cached; safe to call from a UI
    /// refresh. Never blocks indefinitely (bounded internal timeout).
    func isAvailable() async -> AgentAvailability

    /// Spawn one turn and stream its events. Breaking/cancelling the returned
    /// stream terminates the process group (via `onTermination`).
    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error>

    /// Answer a pending `approvalRequested` (Claude control protocol). Writes the
    /// `control_response` to the live turn's stdin so it continues. No-op for
    /// providers without an approval channel (Codex).
    func respondToApproval(id: String, _ decision: ApprovalDecision)

    /// Terminate the current turn's whole process group (SIGTERM → grace → SIGKILL).
    func cancel()
}

/// Errors thrown *into* a turn's event stream (vs. `providerNotice`, which is a
/// surfaced-as-content soft error). A hard failure to even start the process.
enum AgentProviderError: Error, Equatable, Sendable {
    /// No runnable binary at the override/discovered path.
    case executableNotFound(String)
    /// `posix_spawn` itself failed.
    case spawnFailed(code: Int32)
}
