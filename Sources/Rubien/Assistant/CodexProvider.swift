#if os(macOS)
import Darwin
import Foundation
import RubienCore

// MARK: - CodexProvider (Phase 3b)
//
// Drives a LONG-LIVED `codex app-server` (stdio JSON-RPC 2.0, the v2 thread → turn →
// item protocol, verified against codex-cli 0.142.5 — Phase-3b design §2) as the Codex
// sibling of `ClaudeCodeProvider`. The process model is the key difference:
//
//   • Claude: one process PER TURN; killing the turn's stream kills its process.
//   • Codex:  one server shared by every production Rubien surface — Home, readers,
//     History, and scheduled jobs. It is spawned lazily and reused across threads.
//     Dropping a turn's stream or pressing stop sends `turn/interrupt`; the SERVER
//     LIVES (design review #5).
//
// Config posture (§4, user decision): NO managed CODEX_HOME — the user's real
// `~/.codex` provides auth/config exactly as Claude keeps `~/.claude`. Ambient config
// is neutralized per-invocation: `approvalPolicy`/`sandbox` ride `thread/start`,
// `effort` rides `turn/start` (both verified to override the user's defaults), the
// rubien content channel is injected via `-c mcp_servers.rubien.*` KEY overrides
// (verified to replace a user-configured `rubien` entry), and codex's built-in app
// connectors are dropped via `--disable apps` unless the conversation explicitly
// opts into the user's normal connected apps and tools.

private struct CodexProviderEvent: Sendable {
    let event: AgentEvent
    let providerItemID: String?
    let runtimeGeneration: Int?
}

final class CodexProvider: AgentProvider {
    let kind: AgentProviderKind = .codex

    private let connection: CodexRuntimeBroker
    private let executableOverride: String?
    private let usesSharedConnection: Bool
    private let turnTokens = CodexProviderTurnTokens()
    private let ownerID = UUID()

    init(
        executableOverride: String? = nil,
        contentChannel: MCPContentChannel? = nil,
        requestTimeout: Double = 30,
        historyTimeout: Double = AgentHistoryPolicy.loadTimeout,
        initializeRetryDelay: Duration = .seconds(5),
        shareAppServer: Bool = false,
        sharedConnectionRegistry: CodexSharedConnectionRegistry? = nil,
        availabilityPreemptionHook: (@Sendable () async -> Void)? = nil
    ) {
        self.executableOverride = executableOverride
        let makeConnection = {
            CodexRuntimeBroker(
                executableOverride: executableOverride,
                contentChannel: contentChannel,
                requestTimeout: requestTimeout,
                historyTimeout: historyTimeout,
                initializeRetryDelay: initializeRetryDelay,
                availabilityPreemptionHook: availabilityPreemptionHook)
        }
        if shareAppServer || sharedConnectionRegistry != nil {
            let registry = sharedConnectionRegistry ?? .shared
            self.connection = registry.acquire(
                key: CodexSharedConnectionKey(
                    executableOverride: executableOverride,
                    contentChannel: contentChannel,
                    requestTimeout: requestTimeout,
                    historyTimeout: historyTimeout,
                    initializeRetryDelay: initializeRetryDelay),
                makeConnection: makeConnection)
            self.usesSharedConnection = true
        } else {
            self.connection = makeConnection()
            self.usesSharedConnection = false
        }
    }

    func isAvailable() async -> AgentAvailability {
        await connection.isAvailable()
    }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = sendProviderEvents(
            turn: turn,
            token: UUID(),
            identityObserver: nil
        )
        return forwardingAgentStream(events) { $0.event }
    }

    func sendEnvelopes(
        turn: AgentTurnRequest,
        attempt: AssistantAttemptIdentity,
        identityObserver: AgentIdentityObserver?
    ) -> AsyncThrowingStream<AgentEventEnvelope, Error> {
        let events = sendProviderEvents(
            turn: turn,
            token: attempt.workID,
            identityObserver: identityObserver
        )
        return forwardingAgentStream(events) { event in
            AgentEventEnvelope(
                attempt: AssistantAttemptIdentity(
                    conversationID: attempt.conversationID,
                    conversationEpoch: attempt.conversationEpoch,
                    turnID: attempt.turnID,
                    workID: attempt.workID,
                    runtimeGeneration: event.runtimeGeneration
                ),
                providerItemID: event.providerItemID,
                event: event.event
            )
        }
    }

    private func sendProviderEvents(
        turn: AgentTurnRequest,
        token: UUID,
        identityObserver: AgentIdentityObserver?
    ) -> AsyncThrowingStream<CodexProviderEvent, Error> {
        guard turnTokens.beginSend(token) else {
            Task { await identityObserver?.close() }
            return AsyncThrowingStream { $0.finish() }
        }
        let connection = self.connection
        let turnTokens = self.turnTokens
        return AsyncThrowingStream { continuation in
            // Dropping the consumed stream ends THE TURN (turn/interrupt), never the
            // long-lived server — the semantic divergence from Claude (review #5).
            continuation.onTermination = { termination in
                turnTokens.clear(ifCurrent: token)
                guard case .cancelled = termination else { return }
                Task { await connection.interruptIfCurrent(token: token) }
            }
            Task {
                await connection.startTurn(
                    token: token, ownerID: ownerID,
                    request: turn, continuation: continuation,
                    identityObserver: identityObserver)
            }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {
        guard let token = turnTokens.current else { return }
        let connection = self.connection
        Task { await connection.respond(id: id, decision: decision, token: token) }
    }

    /// Stop button / conversation reset: interrupt the live turn; the server stays.
    func cancel() {
        guard let token = turnTokens.current else { return }
        let connection = self.connection
        Task { await connection.interruptIfCurrent(token: token) }
    }

    /// Window close: stop this wrapper's turn. A shared interactive server is killed
    /// only with the app; dedicated providers kill now. Keeping the interactive
    /// connection alive avoids a close/reopen race where a replacement server starts
    /// before the prior process has reaped and both contend in Codex's shared home.
    func shutdown() {
        if let token = turnTokens.close() {
            let connection = self.connection
            Task { await connection.interruptIfCurrent(token: token) }
        }
        guard !usesSharedConnection else { return }
        let connection = self.connection
        Task { await connection.shutdown() }
    }

    // Explicit Provider History over the wire (`thread/list` / `thread/search` /
    // `thread/read`). Normal History is served by Rubien's local transcript store.
    // These compatibility reads degrade to `[]` on failure.

    func recentSessionsResult(
        workspaceURL: URL, limit: Int, referenceID: Int64?, deadline: Date?
    ) async -> AgentSessionQueryResult {
        await connection.recentThreads(
            workspaceURL: workspaceURL, limit: limit, referenceID: referenceID,
            deadline: deadline)
    }

    func searchSessionsResult(
        query: String, workspaceURL: URL, limit: Int, referenceID: Int64?,
        deadline: Date?
    ) async -> AgentSessionQueryResult {
        await connection.searchThreads(
            searchTerm: query, workspaceURL: workspaceURL, limit: limit,
            referenceID: referenceID, deadline: deadline)
    }

    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage] {
        (await sessionTranscriptResult(
            sessionID: sessionID,
            workspaceURL: workspaceURL
        )).messages
    }

    func sessionTranscriptResult(
        sessionID: String,
        workspaceURL: URL
    ) async -> AgentTranscriptQueryResult {
        await connection.readTranscriptResult(
            threadID: sessionID,
            workspaceURL: workspaceURL
        )
    }

    /// The installed codex's own model catalog (memoized per binary and fetched over
    /// the process-wide shared runtime; spec §4.1). Feeds pickers only.
    func availableModels() async -> CodexCatalog? {
        await CodexModelCatalog.shared.catalog(executableOverride: executableOverride)
    }

    /// Internal seam for the production catalog bridge and deterministic shared-
    /// connection tests.
    func modelCatalog(workspaceURL: URL, timeout: Double = 10) async -> CodexCatalog {
        await connection.fetchModelCatalog(
            workspaceURL: workspaceURL,
            timeout: timeout)
    }

    /// Production model discovery must use the same process-wide connection as
    /// Home/readers/scheduled work. A standalone metadata app-server racing the
    /// first real turn reproduced the cold-start initialize failures.
    static func sharedModelCatalog(
        executablePath: String,
        workingDirectory: URL,
        timeout: Double
    ) async -> CodexCatalog {
        let provider = CodexProvider(
            executableOverride: executablePath,
            contentChannel: MCPContentChannel.resolveBundled(),
            shareAppServer: true)
        defer { provider.shutdown() }
        return await provider.modelCatalog(
            workspaceURL: workingDirectory, timeout: timeout)
    }

    /// Well-known codex install dirs — shared by the live connection AND
    /// `CodexModelCatalog`'s catalog probe, so a picker asking "what can Codex
    /// run?" resolves the SAME binary a turn will actually spawn (§5.5).
    static func resolveExecutable(override: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentBinaryProbe.resolveExecutable(
            override: override,
            candidates: [
                "\(home)/.npm-global/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.local/bin/codex",
            ],
            binaryName: "codex")
    }
}

/// Token ownership stays on the provider wrapper even when several wrappers share
/// one connection. Stop/teardown can therefore interrupt only the turn that wrapper
/// started, never a newer turn from another window.
private final class CodexProviderTurnTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var isClosed = false

    var current: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func beginSend(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return false }
        self.token = token
        return true
    }

    func clear(ifCurrent candidate: UUID) {
        lock.lock()
        if token == candidate { token = nil }
        lock.unlock()
    }

    func close() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }
        isClosed = true
        let current = token
        token = nil
        return current
    }
}

/// All production providers share one app-lifetime app-server connection. Retaining
/// an idle connection is intentional: final-window teardown followed by an immediate
/// reopen must never overlap a new server with a still-reaping old one in Codex's
/// shared home. A scheduled turn changes the connection's spawn posture only after
/// any interactive turn has ended and the old process has reaped.
private struct CodexSharedConnectionKey: Hashable {
    let executableOverride: String?
    let cliPath: String?
    let libraryRootPath: String?
    let requestTimeout: Double
    let historyTimeout: Double
    let retrySeconds: Int64
    let retryAttoseconds: Int64

    init(
        executableOverride: String?,
        contentChannel: MCPContentChannel?,
        requestTimeout: Double,
        historyTimeout: Double,
        initializeRetryDelay: Duration
    ) {
        self.executableOverride = executableOverride
        self.cliPath = contentChannel?.cliURL.standardizedFileURL.path
        self.libraryRootPath = contentChannel?.libraryRoot.standardizedFileURL.path
        self.requestTimeout = requestTimeout
        self.historyTimeout = historyTimeout
        let retry = initializeRetryDelay.components
        self.retrySeconds = retry.seconds
        self.retryAttoseconds = retry.attoseconds
    }
}

final class CodexSharedConnectionRegistry: @unchecked Sendable {
    static let shared = CodexSharedConnectionRegistry()

    private let lock = NSLock()
    private var entry: (key: CodexSharedConnectionKey, connection: CodexRuntimeBroker)?

    fileprivate func acquire(
        key: CodexSharedConnectionKey,
        makeConnection: () -> CodexRuntimeBroker
    ) -> CodexRuntimeBroker {
        lock.lock()
        defer { lock.unlock() }
        if let entry {
            // Immutable launch inputs are pinned by the first production provider
            // for this app launch. Most importantly, a settings-path change must not
            // create a second live app-server beside the first one; the newly selected
            // path is adopted on the next app launch.
            return entry.connection
        }
        let connection = makeConnection()
        entry = (key, connection)
        return connection
    }

    /// Test/support cleanup. Production retains the registry for the app lifetime;
    /// process termination closes its inherited stdin descriptors and Codex exits on
    /// EOF without creating an in-app close/reopen race.
    func shutdownAll() async {
        let connections = removeAllConnections()
        for connection in connections {
            await connection.shutdown()
        }
    }

    private func removeAllConnections() -> [CodexRuntimeBroker] {
        lock.lock()
        defer { lock.unlock() }
        defer { entry = nil }
        return entry.map { [$0.connection] } ?? []
    }
}

// MARK: - CodexInvocation (pure argv + env construction; unit-tested)

/// The exact `codex` argv and minimal child environment for one app-server spawn.
/// Extracted from the connection so it can be verified without spawning anything
/// (mirrors `ClaudeCLIInvocation`).
enum CodexInvocation {

    /// Query the effective ambient MCP catalog after applying the same feature
    /// isolation as a scheduled app-server. Plugin-provided servers disappear at
    /// the source instead of being rediscovered and then recreated as invalid,
    /// transport-less `enabled=false` overrides.
    static let scheduledMCPListArguments = [
        "--disable", "apps",
        "--disable", "plugins",
        "mcp", "list", "--json",
    ]

    /// Arguments for the long-lived `codex app-server` process.
    ///
    /// - `loadUserTools` (the "use my other MCP servers" opt-in lever, default OFF):
    ///   when off, `--disable apps` drops codex's BUILT-IN app connectors (the one
    ///   net-new silent-read surface vs Claude — §4). In interactive runs, the
    ///   user's configured `~/.codex` servers still load either way; scheduled
    ///   runs separately disable them because codex has no `--strict-mcp-config`.
    /// - `webAccess=false` disables codex's built-in web search for this server.
    /// - The rubien `-c` KEY overrides replace any user-configured `rubien` entry
    ///   field-by-field (command/args/env all set), so exactly one rubien loads.
    static func arguments(
        rubienCLIPath: String?,
        libraryRoot: String?,
        webAccess: Bool,
        loadUserTools: Bool = false,
        readOnlyLibrary: Bool = false,
        disabledMCPServerNames: [String] = []
    ) -> [String] {
        var args = ["app-server"]
        if !loadUserTools {
            args += ["--disable", "apps"]
        }
        if !webAccess {
            args += ["-c", "tools.web_search=false"]
        }
        if readOnlyLibrary {
            // Unlike Claude, app-server has no strict MCP-config flag. Resolve
            // the effective catalog before launch, disable plugins/connectors,
            // and pin every remaining ambient server off by name. When supplied,
            // the injected canonical Rubien server is re-enabled below.
            args += ["--disable", "plugins"]
            for name in disabledMCPServerNames
            where name != MCPContentChannel.serverName || rubienCLIPath == nil {
                args += ["-c", "mcp_servers.\(name).enabled=false"]
            }
        }
        if let cli = rubienCLIPath, !cli.isEmpty {
            // Values are parsed as TOML with a raw-string fallback, so bare paths are
            // safe; the args array must stay valid TOML. The key is the canonical
            // server name — the same one History attribution matches against.
            let server = "mcp_servers.\(MCPContentChannel.serverName)"
            args += ["-c", "\(server).enabled=true"]
            args += ["-c", "\(server).command=\(cli)"]
            args += [
                "-c",
                readOnlyLibrary
                    ? #"\#(server).args=["mcp","--read-only"]"#
                    : #"\#(server).args=["mcp"]"#,
            ]
            // The native catalog annotates all 14 reads and 13 writes. Prompt
            // for every non-read tool, and allow the two long intake routes to
            // use their own five-minute child timeout without Codex cutting the
            // outer MCP call off at its 60-second default.
            if !readOnlyLibrary {
                args += ["-c", "\(server).default_tools_approval_mode=writes"]
            }
            args += ["-c", "\(server).tool_timeout_sec=310"]
            // Keep the app-private paper-card tool in lockstep with Claude's
            // inline MCP configuration. Without this flag Codex sees only the
            // public catalog and can fall back only to Markdown paper links.
            args += [
                "-c",
                #"\#(server).env.\#(MCPContentChannel.appPresentationEnvironmentKey)="\#(MCPContentChannel.appPresentationEnvironmentValue)""#,
            ]
            if !readOnlyLibrary {
                args += [
                    "-c",
                    #"\#(server).env.\#(RubienAppSchedulingContract.environmentKey)="\#(RubienAppSchedulingContract.environmentValue)""#,
                ]
            }
            if let root = libraryRoot, !root.isEmpty {
                args += ["-c", "\(server).env.RUBIEN_LIBRARY_ROOT=\(root)"]
            }
        }
        return args
    }

    static func configuredEnabledMCPServerNames(from json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        let validName = try? NSRegularExpression(pattern: "^[A-Za-z0-9_-]+$")
        var names = Set<String>()
        for row in rows {
            // `codex mcp list --json` includes disabled entries. Do not add a
            // redundant override for them: touching an already-disabled legacy
            // entry can make newer Codex versions validate its stale transport
            // and reject the whole app-server configuration. A missing/non-Boolean
            // status remains conservative and is treated as enabled.
            if let enabled = row["enabled"] as? Bool, !enabled { continue }
            guard let name = row["name"] as? String,
                  !name.isEmpty,
                  validName?.firstMatch(
                      in: name,
                      range: NSRange(name.startIndex..., in: name)
                  ) != nil
            else { return nil }
            names.insert(name)
        }
        return names.sorted()
    }

    /// Resolve the ambient MCP names under the same Apps/plugins isolation used
    /// by unattended and metadata-only servers. Callers then pin those remaining
    /// configured servers off with per-name overrides.
    static func isolatedMCPServerNames(
        executablePath: String,
        environment: [String: String],
        workingDirectory: String
    ) -> [String]? {
        guard let catalog = AgentBinaryProbe.run(
            executablePath: executablePath,
            arguments: scheduledMCPListArguments,
            environment: environment,
            timeout: 5,
            workingDirectory: workingDirectory
        ) else { return nil }
        return configuredEnabledMCPServerNames(from: catalog)
    }

    /// Production variant used by the runtime broker. Unlike the synchronous
    /// parser-test seam above, this root process is cancellable, group-owned, and
    /// fully reaped before the broker can spawn app-server.
    static func isolatedMCPServerNamesAsync(
        executablePath: String,
        environment: [String: String],
        workingDirectory: String
    ) async -> [String]? {
        guard let result = await AgentBinaryProbe.runSpawnedCommand(
            executablePath: executablePath,
            arguments: scheduledMCPListArguments,
            environment: environment,
            timeout: 5,
            workingDirectory: workingDirectory
        ), result.exitCode == 0, !result.timedOut else { return nil }
        return configuredEnabledMCPServerNames(from: result.stdout)
    }

    /// The shared minimal ALLOWLISTED environment. `HOME` (in the shared allowlist)
    /// is required so `~/.codex` auth/config resolve (§4 — no CODEX_HOME override).
    static func environment(binaryDirectory: String) -> [String: String] {
        SpawnedAgentProcess.minimalEnvironment(binaryDirectory: binaryDirectory)
    }

    /// `CodexSandbox` → the `thread/start` wire value.
    static func sandboxWire(_ sandbox: CodexSandbox) -> String {
        switch sandbox {
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        }
    }
}

// MARK: - Connection (all mutable state is actor-isolated)

/// The single app-lifetime owner of Codex admission, root-process lifecycle,
/// JSON-RPC correlation, and metadata preemption. Provider wrappers are only
/// owner-scoped client handles; they never launch Codex independently.
private actor CodexRuntimeBroker {
    private let executableOverride: String?
    private let contentChannel: MCPContentChannel?
    private let initializeRetryDelay: Duration
    private let availabilityPreemptionHook: (@Sendable () async -> Void)?
    private let logger = RubienLogger(subsystem: "com.rubien.assistant", category: "CodexProvider")

    init(
        executableOverride: String?,
        contentChannel: MCPContentChannel?,
        requestTimeout: Double,
        historyTimeout: Double,
        initializeRetryDelay: Duration,
        availabilityPreemptionHook: (@Sendable () async -> Void)?
    ) {
        self.executableOverride = executableOverride
        self.contentChannel = contentChannel
        self.requestTimeout = requestTimeout
        self.historyTimeout = historyTimeout
        self.initializeRetryDelay = initializeRetryDelay
        self.availabilityPreemptionHook = availabilityPreemptionHook
    }

    // Tunables (single point — mirrors ClaudeTurnEngine's named timers).
    /// Bound on any single JSON-RPC request (initialize / thread ops / turn/start).
    private let requestTimeout: Double
    /// One overall budget for a History list/search and all transcript projections.
    private let historyTimeout: Double
    /// After `turn/interrupt`, force-finish the turn stream if the server never
    /// delivers the interrupted `turn/completed` (the server itself stays alive).
    private static let interruptGrace: Double = 5
    /// After `shutdown`'s SIGTERM, escalate to SIGKILL.
    private static let shutdownHardKillDelay: Double = 2
    /// A SIGKILLed initialize process should reap immediately; bound the wait so
    /// recovery itself can never monopolize the connection actor.
    private static let initializeCleanupWait: Double = 2
    // The crash-notice drain grace + tail size are shared (`AgentProcessExit`).

    /// A JSON-RPC request failure (soft — surfaced as a §4.5 notice, never thrown).
    private enum RequestFailure: Error {
        case timeout(method: String)
        case handshakeWaitTimeout
        case historySuperseded
        case serverError(message: String)
        case serverExited

        var noticeText: String {
            switch self {
            case .timeout(let method):
                return "The assistant did not respond (\(method) timed out)."
            case .handshakeWaitTimeout:
                return "The assistant did not respond (initialize timed out)."
            case .historySuperseded:
                return "The History request was superseded."
            case .serverError(let message):
                return message
            case .serverExited:
                return "The assistant ended unexpectedly."
            }
        }

        var isInitializeTimeout: Bool {
            if case .timeout(method: "initialize") = self { return true }
            return false
        }

        /// A concurrent History request can be swept as `serverExited` when the
        /// request that actually timed out resets their shared idle server.
        var makesHistoryIncomplete: Bool {
            switch self {
            case .timeout, .handshakeWaitTimeout, .serverExited: return true
            case .historySuperseded, .serverError: return false
            }
        }
    }

    // MARK: Long-lived server state

    /// Every option fixed when `codex app-server` starts. Turns can reuse a server
    /// only when this snapshot matches; History may explicitly reuse any live one.
    private struct SpawnConfiguration: Equatable {
        let webAccess: Bool
        let loadUserTools: Bool
        let readOnlyLibrary: Bool

        /// A fresh History-only server uses the normal web default and isolated Apps
        /// posture. If a turn follows with different settings it will respawn once.
        static let historyDefault = SpawnConfiguration(
            webAccess: true, loadUserTools: false, readOnlyLibrary: false)
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<
            Result<[String: Any], RequestFailure>, Never
        >
        let timeoutTask: Task<Void, Never>
        let method: String
        let isHistory: Bool
    }

    /// One spawned `codex app-server` + its JSON-RPC bookkeeping. Reference type,
    /// only touched inside this actor's isolation.
    private final class Server {
        let process: SpawnedAgentProcess
        let generation: Int
        let spawnConfiguration: SpawnConfiguration
        let stderr = StderrRingBuffer()
        var nextRequestID = 1
        var pending: [Int: PendingRequest] = [:]
        /// History waiters Rubien superseded while their RPCs may still be executing
        /// inside Codex. The response clears the marker; an interactive turn replaces
        /// the server while any marker remains because JSON-RPC offers no cancellation.
        var supersededHistoryRequestIDs: Set<Int> = []
        /// The thread the CURRENT conversation runs on — lets an in-sitting follow-up
        /// skip `thread/resume` (the thread is already live in this server).
        var activeThreadID: String?
        /// The initialize/initialized handshake gate. Every caller — the spawner AND a
        /// fast-path reuser — awaits this before any thread/turn request, so a second
        /// turn entering during the spawner's `await initialize` can't send `thread/start`
        /// on an un-initialized server (review #1). `nil` result = success; a stored
        /// failure or a waiter list carries the outcome to late joiners.
        var handshaked = false
        var handshakeFailure: RequestFailure?
        var handshakeWaiters: [
            UUID: CheckedContinuation<Result<Void, RequestFailure>, Never>
        ] = [:]

        init(
            process: SpawnedAgentProcess, generation: Int,
            spawnConfiguration: SpawnConfiguration
        ) {
            self.process = process
            self.generation = generation
            self.spawnConfiguration = spawnConfiguration
        }
    }

    /// One connection-wide initialize recovery gate. Actor methods are reentrant:
    /// while the owner awaits process reaping/backoff, every new sender must join
    /// this task instead of observing `server == nil` and spawning into the same
    /// failing cold-start window.
    private struct InitializeRecovery {
        let token: UUID
        let task: Task<Bool, Never>
    }

    private var server: Server?
    private var serverGeneration = 0
    private var initializeRecovery: InitializeRecovery?
    /// A SIGKILLed leader that did not reap within the hard bound makes this
    /// connection unsafe to reuse: spawning another server could overlap it.
    private var initializeRecoveryBlocked = false
    /// Set during a deliberate `shutdown()` so the reader's EOF path doesn't compose
    /// a scary crash notice for an intentional kill.
    private var shuttingDown = false
    /// Terminal provider teardown. Unlike `shuttingDown`, this also covers the
    /// initialize-recovery interval where no `server` is currently installed.
    private var shutdownRequested = false

    // MARK: Per-turn state

    private final class ActiveTurn {
        let token: UUID
        let ownerID: UUID
        let continuation: AsyncThrowingStream<CodexProviderEvent, Error>.Continuation
        var parser = CodexAppServerParser()
        var threadID: String?
        var turnID: String?
        var runtimeGeneration: Int?
        /// The `turn/start` request id — so `route` can set `turnID` from the
        /// AUTHORITATIVE response the moment it arrives (before the following
        /// notification lines), which the positive turn-id filter relies on (review #2).
        var turnStartRequestID: Int?
        /// UI id (`CodexRPCID.uiString`) → the raw approval bookkeeping.
        var pendingApprovals: [String: PendingCodexApproval] = [:]
        var finished = false
        /// An interrupt arrived (stop / stream drop) — possibly before `turn/start`
        /// was even sent; the start path checks this after every await.
        var interruptRequested = false
        /// Identity remains open until the async start path has returned, even if
        /// visible content was force-finished by the interrupt watchdog.
        let identityObserver: AgentIdentityObserver?
        var startPathFinished = false
        var retirementScheduled = false
        var finishError: Error?

        init(
            token: UUID,
            ownerID: UUID,
            continuation: AsyncThrowingStream<CodexProviderEvent, Error>.Continuation,
            identityObserver: AgentIdentityObserver?
        ) {
            self.token = token
            self.ownerID = ownerID
            self.continuation = continuation
            self.identityObserver = identityObserver
        }
    }

    private struct QueuedTurn {
        let token: UUID
        let ownerID: UUID
        let request: AgentTurnRequest
        let continuation: AsyncThrowingStream<CodexProviderEvent, Error>.Continuation
        let identityObserver: AgentIdentityObserver?
    }

    private var turn: ActiveTurn?
    /// Admission policy is intentionally separate from process and JSON-RPC state.
    /// Payloads stay here while the pure scheduler owns only stable work identities.
    private var workScheduler = CodexWorkScheduler()
    private var scheduledPayloads: [UUID: QueuedTurn] = [:]
    /// A same-wrapper send can supersede its own still-starting turn. It waits
    /// outside the scheduled queue until the outgoing identity gate closes.
    private var sameOwnerSuccessorToken: UUID?
    private struct IdentityRetirement {
        let token: UUID
        let task: Task<Void, Never>
    }
    /// Admission may reopen before a completed stream's consumer submits its next
    /// turn, but no new provider work starts until this identity close has drained.
    private var identityRetirement: IdentityRetirement?
    /// Tokens interrupted BEFORE their `startTurn` ran (A1 — the consumer dropped the
    /// stream in the window between `send()` arming `onTermination` and the task).
    private var cancelledTokens: Set<UUID> = []
    private var retiredTokens: Set<UUID> = []
    private var retiredTokenOrder: [UUID] = []
    private static let retiredTokenLimit = 64
    /// Only the binary path + --version is cached (expensive to resolve). Auth is NOT
    /// cached — re-probed on every isAvailable() so a mid-session sign-out is reflected
    /// instead of Recheck being a no-op (#11); a not-found stays uncached (B6).
    private var cachedResolution: (path: String, version: String?)?
    private struct AvailabilityProbe {
        let token: UUID
        let path: String
        let metadataWorkID: UUID
        let task: Task<AgentAvailability, Never>
    }
    private var availabilityProbe: AvailabilityProbe?

    // MARK: Turn lifecycle

    func startTurn(
        token: UUID,
        ownerID: UUID,
        request: AgentTurnRequest,
        continuation: AsyncThrowingStream<CodexProviderEvent, Error>.Continuation,
        identityObserver: AgentIdentityObserver?
    ) async {
        if retiredTokens.contains(token) {
            continuation.finish()
            await identityObserver?.close()
            return
        }
        if cancelledTokens.remove(token) != nil {
            retire(token)
            continuation.finish()
            await identityObserver?.close()
            return
        }
        // A2: one turn at a time per connection. A second send from the SAME wrapper
        // preserves the provider's supersession contract. A different production
        // surface must never displace another window or scheduled run.
        if let existing = turn, !existing.finished, existing.ownerID == ownerID {
            logger.error("startTurn entered with an unfinished turn active — finishing the prior turn")
            requestInterrupt(existing)
            finishTurn(existing)
            if workScheduler.activeTurn != nil {
                if let replacedToken = sameOwnerSuccessorToken,
                   let replaced = scheduledPayloads.removeValue(forKey: replacedToken) {
                    replaced.continuation.finish()
                    retire(replacedToken)
                    await replaced.identityObserver?.close()
                }
                scheduledPayloads[token] = QueuedTurn(
                    token: token,
                    ownerID: ownerID,
                    request: request,
                    continuation: continuation,
                    identityObserver: identityObserver
                )
                sameOwnerSuccessorToken = token
                return
            }
        }
        let work = CodexScheduledWork(
            workID: token,
            purpose: request.executionMode == .scheduled
                ? .scheduled(
                    runID: request.scheduledRunID ?? token.uuidString,
                    conversationID: request.conversationID,
                    turnID: token)
                : .interactive(
                    ownerID: ownerID,
                    conversationID: request.conversationID,
                    turnID: token)
        )
        switch workScheduler.requestTurn(work) {
        case .admitted:
            scheduledPayloads.removeValue(forKey: token)
        case .preemptMetadataAndAdmit:
            scheduledPayloads.removeValue(forKey: token)
        case .queued:
            scheduledPayloads[token] = QueuedTurn(
                token: token, ownerID: ownerID,
                request: request, continuation: continuation,
                identityObserver: identityObserver)
            continuation.yield(CodexProviderEvent(
                event: .providerNotice(
                    "Waiting for the active Codex conversation to finish."),
                providerItemID: nil,
                runtimeGeneration: nil
            ))
            return
        case .busy:
            continuation.yield(CodexProviderEvent(
                event: .providerNotice(
                    "Codex is busy with another Rubien conversation. Try again when it finishes."),
                providerItemID: nil,
                runtimeGeneration: nil
            ))
            continuation.yield(CodexProviderEvent(
                event: .turnCompleted(outcome: .failed, usage: nil),
                providerItemID: nil,
                runtimeGeneration: nil
            ))
            retire(token)
            continuation.finish()
            await identityObserver?.close()
            return
        case .metadataUnavailable:
            assertionFailure("turn admission returned metadata-only result")
            continuation.finish()
            await identityObserver?.close()
            return
        }

        // A cold Settings/version/auth probe is disposable metadata. Admission
        // above reserves this turn first; cancellation then kills and reaps that
        // standalone process group before app-server can spawn.
        await joinIdentityRetirementIfNeeded()
        await preemptAvailabilityProbeIfNeeded()

        // Cancellation can arrive while the actor is suspended above waiting for
        // the standalone probe process group to reap. Do not spawn or send a prompt
        // after the consumer has already gone away; release this admitted slot so a
        // reserved scheduled turn can proceed.
        if cancelledTokens.remove(token) != nil || retiredTokens.contains(token) {
            retire(token)
            continuation.finish()
            await identityObserver?.close()
            dispatchReservedTurn(workScheduler.finishTurn(workID: token))
            return
        }

        // History is best-effort metadata; an explicit user turn always wins. Codex
        // app-server can serialize a thread/read ahead of thread/start/resume, so a
        // wedged transcript restore otherwise leaves the composer on “Responding…”
        // until both requests time out. There is no request-cancel RPC: supersede the
        // lookup and replace its idle server before marking this turn active.
        prioritizeInteractiveTurn()

        let active = ActiveTurn(
            token: token,
            ownerID: ownerID,
            continuation: continuation,
            identityObserver: identityObserver)
        turn = active
        defer { markStartPathFinished(active) }

        // 1. Server (lazy spawn + handshake; reused across turns).
        let srv: Server
        do {
            srv = try await ensureServer(
                configuration: SpawnConfiguration(
                    webAccess: request.webAccess,
                    loadUserTools: request.loadUserTools,
                    readOnlyLibrary: request.executionMode == .scheduled),
                workspaceURL: request.workspaceURL)
        } catch let error as AgentProviderError {
            finishTurn(active, throwing: error)   // hard start failure — mirrors Claude
            return
        } catch let failure as RequestFailure {
            failTurn(active, failure)
            return
        } catch {
            failTurn(active, .serverExited)
            return
        }
        active.runtimeGeneration = srv.generation
        guard stillCurrent(active) else { return }

        // 2. Thread: reuse the live one for in-sitting follow-ups; `thread/resume` a
        //    History pick; `thread/start` a fresh conversation.
        do {
            let threadID: String
            var resolvedModel: String?
            if let resume = request.resumeSessionID, !resume.isEmpty {
                if srv.activeThreadID == resume {
                    threadID = resume   // already live in this server — just turn/start
                } else {
                    let result = try await sendRequest(srv, method: "thread/resume") { id in
                        CodexAppServerProtocol.threadResume(requestID: id, threadId: resume)
                    }
                    threadID = Self.threadID(fromThreadResponse: result) ?? resume
                    resolvedModel = CodexAppServerProtocol.resolvedModel(fromThreadResponse: result)
                }
            } else {
                let result = try await sendRequest(srv, method: "thread/start") { id in
                    CodexAppServerProtocol.threadStart(
                        requestID: id,
                        cwd: request.workspaceURL.path,
                        sandbox: CodexInvocation.sandboxWire(request.codexSandbox),
                        approvalPolicy: "on-request",
                        developerInstructions: request.seed,
                        model: request.modelOverride)
                }
                guard let id = Self.threadID(fromThreadResponse: result) else {
                    failTurn(active, .serverError(message: "thread/start returned no thread id."))
                    return
                }
                threadID = id
                resolvedModel = CodexAppServerProtocol.resolvedModel(fromThreadResponse: result)
            }
            guard stillCurrent(active) else { return }
            srv.activeThreadID = threadID
            active.threadID = threadID
            await active.identityObserver?.sessionStarted(
                threadID,
                runtimeGeneration: srv.generation
            )
            guard stillCurrent(active) else { return }
            // The controller re-captures the session id from every turn; codex's
            // thread id is stable, so re-emitting is an idempotent no-op there.
            emit(active, .sessionStarted(sessionID: threadID))
            // The RESOLVED model (spec §2.2): what this thread actually runs —
            // codex's own config resolution when the request omitted `model`.
            if let resolvedModel {
                emit(active, .modelResolved(model: resolvedModel))
            }

            // 3. The turn itself. Events stream via route(); `turnID` is set by route
            //    from the AUTHORITATIVE response (keyed on `turnStartRequestID`) before
            //    the following notification lines, so the positive turn-id filter
            //    (review #2) accepts exactly this turn's notifications.
            let result = try await sendRequest(srv, method: "turn/start") { id in
                active.turnStartRequestID = id
                let inputs: [CodexUserInput] = [.text(request.prompt)]
                    + request.attachments.compactMap {
                        $0.kind == .image ? .localImage(path: $0.stagedURL.path) : nil
                    }
                return CodexAppServerProtocol.turnStart(
                    requestID: id,
                    threadId: threadID,
                    inputs: inputs,
                    effort: request.effortOverride)
            }
            // `turn/start` HAS been sent — a turn now runs server-side whatever happened
            // to the stream meanwhile. `route` set `turnID` already; fall back to the
            // response in case the response was resolved without the route fast-path.
            let turnID = active.turnID ?? (result["turn"] as? [String: Any])?["id"] as? String
            active.turnID = turnID
            logger.info("codex turn started thread=\(threadID) turn=\(turnID ?? "?")")
            if active.finished || turn !== active {
                // The stream ended / was superseded while starting (stop watchdog, A2) —
                // don't leave the server-side turn running headless. A straggler
                // `turn/completed` for it can't leak into the next turn: its `turnID`
                // won't match the next turn's (positive filter, review #2).
                if let turnID { writeInterrupt(srv, threadID: threadID, turnID: turnID) }
                return
            }
            if active.interruptRequested {
                // Stop arrived while the turn was starting — interrupt it now that
                // the turn id exists (the watchdog was already armed).
                if let turnID { writeInterrupt(srv, threadID: threadID, turnID: turnID) }
            }
        } catch let failure as RequestFailure {
            failTurn(active, failure)
        } catch {
            failTurn(active, .serverExited)
        }
    }

    /// Pre-send guard (server/thread phases — nothing turn-shaped exists server-side
    /// yet): a superseded turn just stops; an interrupt-before-send ends the stream.
    private func stillCurrent(_ active: ActiveTurn) -> Bool {
        guard let current = turn, current === active, !active.finished else { return false }
        if active.interruptRequested {
            finishTurn(active)
            return false
        }
        return true
    }

    /// Soft failure → §4.5 notice + finish (renders as chat content, not a throw).
    private func emit(
        _ active: ActiveTurn,
        _ event: AgentEvent,
        providerItemID: String? = nil
    ) {
        active.continuation.yield(CodexProviderEvent(
            event: event,
            providerItemID: providerItemID,
            runtimeGeneration: active.runtimeGeneration
        ))
    }

    private func failTurn(_ active: ActiveTurn, _ failure: RequestFailure) {
        guard !active.finished else { return }
        emit(active, .providerNotice(failure.noticeText))
        finishTurn(active)
    }

    private func finishTurn(_ active: ActiveTurn) {
        guard !active.finished else { return }
        active.finished = true
        cancelledTokens.remove(active.token)
        retire(active.token)
        if turn === active { turn = nil }
        finalizeFinishedTurnIfReady(active)
        // A straggler notification for this now-finished turn can't reach a LATER turn:
        // the positive turn-id filter in `route` accepts only the current turn's id
        // (review #2) — no stale-id set to accumulate.
    }

    private func finishTurn(_ active: ActiveTurn, throwing error: Error) {
        guard !active.finished else { return }
        active.finished = true
        active.finishError = error
        cancelledTokens.remove(active.token)
        retire(active.token)
        if turn === active { turn = nil }
        finalizeFinishedTurnIfReady(active)
    }

    private func markStartPathFinished(_ active: ActiveTurn) {
        active.startPathFinished = true
        finalizeFinishedTurnIfReady(active)
    }

    /// Scheduler ownership and identity ownership end together. In particular, an
    /// interrupt watchdog may close visible content while `thread/start` is still
    /// resolving; a queued turn cannot dispatch until that start path has returned
    /// and no later session id can arrive.
    private func finalizeFinishedTurnIfReady(_ active: ActiveTurn) {
        guard active.finished,
              active.startPathFinished,
              !active.retirementScheduled else { return }
        active.retirementScheduled = true
        let reserved = workScheduler.finishTurn(workID: active.token)
        let retirementTask = Task<Void, Never> {
            if let identityObserver = active.identityObserver {
                await identityObserver.close()
            }
        }
        identityRetirement = IdentityRetirement(
            token: active.token,
            task: retirementTask
        )
        if let error = active.finishError {
            active.continuation.finish(throwing: error)
        } else {
            active.continuation.finish()
        }
        Task { [weak self] in
            await retirementTask.value
            await self?.completeTurnRetirement(
                token: active.token,
                reserved: reserved
            )
        }
    }

    private func joinIdentityRetirementIfNeeded() async {
        while let retirement = identityRetirement {
            await retirement.task.value
            if identityRetirement?.token == retirement.token {
                identityRetirement = nil
            }
        }
    }

    private func completeTurnRetirement(
        token: UUID,
        reserved: CodexScheduledWork?
    ) {
        if identityRetirement?.token == token {
            identityRetirement = nil
        }
        dispatchReservedTurn(reserved)
        if reserved == nil {
            dispatchSameOwnerSuccessorIfNeeded()
        }
    }

    private func dispatchSameOwnerSuccessorIfNeeded() {
        guard let token = sameOwnerSuccessorToken,
              let next = scheduledPayloads[token] else { return }
        sameOwnerSuccessorToken = nil
        Task { [weak self] in
            await self?.startTurn(
                token: next.token,
                ownerID: next.ownerID,
                request: next.request,
                continuation: next.continuation,
                identityObserver: next.identityObserver
            )
        }
    }

    // MARK: External controls

    func respond(id: String, decision: ApprovalDecision, token: UUID) {
        guard let active = turn, active.token == token, !active.finished,
              let pendingApproval = active.pendingApprovals.removeValue(forKey: id),
              let srv = server
        else { return }
        srv.process.writeLine(CodexAppServerProtocol.approvalResponse(
            id: pendingApproval.id,
            decision,
            method: pendingApproval.method,
            available: pendingApproval.availableDecisions
        ))
    }

    func interruptCurrent() {
        guard let active = turn, !active.finished else { return }
        requestInterrupt(active)
    }

    func interruptIfCurrent(token: UUID) {
        if let active = turn, active.token == token {
            guard !active.finished else { return }
            requestInterrupt(active)
        } else if sameOwnerSuccessorToken == token,
                  let pending = scheduledPayloads.removeValue(forKey: token) {
            sameOwnerSuccessorToken = nil
            pending.continuation.finish()
            retire(token)
            Task { await pending.identityObserver?.close() }
        } else if let pending = scheduledPayloads.removeValue(forKey: token) {
            let priorReservation = workScheduler.reservedTurn?.workID
            guard workScheduler.cancel(workID: token) else { return }
            pending.continuation.finish()
            retire(token)
            Task { await pending.identityObserver?.close() }
            if workScheduler.reservedTurn?.workID != priorReservation {
                dispatchReservedTurn(workScheduler.reservedTurn)
            }
        } else if !retiredTokens.contains(token) {
            // A1: the turn hasn't registered yet (drop raced ahead of startTurn).
            cancelledTokens.insert(token)
        }
    }

    /// Send `turn/interrupt` for the active turn (the server stays alive) and arm a
    /// watchdog: if the interrupted `turn/completed` never arrives, force-finish the
    /// stream so the composer can't wedge. When the turn id isn't known yet (stop
    /// raced the start), the start path sends the interrupt once the id exists — the
    /// watchdog is still armed HERE so the stream ends promptly either way.
    private func requestInterrupt(_ active: ActiveTurn) {
        active.interruptRequested = true
        let token = active.token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.interruptGrace))
            await self?.forceFinishIfStuck(token: token)
        }
        guard let srv = server, let threadID = active.threadID, let turnID = active.turnID else {
            return   // mid-start: the startTurn tail delivers the interrupt
        }
        writeInterrupt(srv, threadID: threadID, turnID: turnID)
    }

    /// The raw fire-and-forget `turn/interrupt` write: the response carries nothing
    /// we need; the turn ends via the interrupted `turn/completed` notification.
    private func writeInterrupt(_ srv: Server, threadID: String, turnID: String) {
        let requestID = srv.nextRequestID
        srv.nextRequestID += 1
        srv.process.writeLine(CodexAppServerProtocol.turnInterrupt(
            requestID: requestID, threadId: threadID, turnId: turnID))
    }

    private func forceFinishIfStuck(token: UUID) {
        guard let active = turn, active.token == token, !active.finished else { return }
        logger.error("turn/interrupt was not acknowledged — force-finishing the turn stream")
        finishTurn(active)
    }

    private func retire(_ token: UUID) {
        guard retiredTokens.insert(token).inserted else { return }
        retiredTokenOrder.append(token)
        if retiredTokenOrder.count > Self.retiredTokenLimit {
            retiredTokens.remove(retiredTokenOrder.removeFirst())
        }
    }

    private func dispatchReservedTurn(_ work: CodexScheduledWork?) {
        guard !shutdownRequested, let work,
              let next = scheduledPayloads[work.workID] else { return }
        Task { [weak self] in
            await self?.startTurn(
                token: next.token, ownerID: next.ownerID,
                request: next.request,
                continuation: next.continuation,
                identityObserver: next.identityObserver)
        }
    }

    /// Window close: kill the server's whole tree. The turn stream (if any) is
    /// finished FIRST so the reader's EOF path sees a deliberate shutdown.
    func shutdown() async {
        shutdownRequested = true
        if let token = sameOwnerSuccessorToken,
           let pending = scheduledPayloads.removeValue(forKey: token) {
            sameOwnerSuccessorToken = nil
            pending.continuation.finish()
            retire(token)
            await pending.identityObserver?.close()
        }
        if let probe = availabilityProbe {
            probe.task.cancel()
            _ = await probe.task.value
            if availabilityProbe?.token == probe.token {
                availabilityProbe = nil
                workScheduler.finishMetadata(workID: probe.metadataWorkID)
            }
        }
        let abandoned = workScheduler.removeAllPending()
        for work in abandoned {
            guard let pending = scheduledPayloads.removeValue(forKey: work.workID) else {
                continue
            }
            pending.continuation.finish()
            retire(pending.token)
            await pending.identityObserver?.close()
        }
        if let active = turn { finishTurn(active) }
        initializeRecovery?.task.cancel()
        shuttingDown = true
        guard let srv = server else { return }
        server = nil
        failAllPending(srv, with: .serverExited)
        srv.process.closeStdin()
        srv.process.signalGroup(SIGTERM)
        let process = srv.process
        let hardKill = Task {
            try? await Task.sleep(for: .seconds(Self.shutdownHardKillDelay))
            guard !Task.isCancelled else { return }
            process.signalGroup(SIGKILL)
        }
        // `serverClosed` deliberately returns after `server` is cleared, so the
        // shutdown owner itself must not return until the exact process group has
        // disappeared and its retained leader is reaped. This keeps registry
        // shutdown and configuration replacement from reporting completion while
        // a prior generation can still contend in Codex's shared home.
        let shutdownWait = Self.shutdownHardKillDelay + Self.initializeCleanupWait
        let status = await process.wait(timeout: shutdownWait)
        hardKill.cancel()
        if status == nil {
            process.signalGroup(SIGKILL)
            if await process.wait(timeout: Self.initializeCleanupWait) == nil {
                initializeRecoveryBlocked = true
                logger.error("codex app-server shutdown could not prove complete process-group cleanup")
            }
        }
    }

    // MARK: Server lifecycle

    /// The live server, spawning + handshaking one if needed. A changed spawn
    /// configuration forces a respawn because these flags are fixed for the process's
    /// lifetime — UNLESS `reuseAnySpawnConfiguration` is set for a History query,
    /// which can use whatever server is already live. EVERY caller — the spawner and
    /// a fast-path reuser — awaits the handshake before returning, so a request can
    /// never hit an un-initialized server (review #1).
    private func ensureServer(
        configuration: SpawnConfiguration,
        workspaceURL: URL,
        reuseAnySpawnConfiguration: Bool = false,
        allowInitializeRetry: Bool = true,
        requestTimeoutOverride: Double? = nil
    ) async throws -> Server {
        guard await joinInitializeRecoveryIfNeeded() else {
            throw RequestFailure.serverExited
        }
        guard !shutdownRequested else { throw RequestFailure.serverExited }

        if let srv = server {
            if reuseAnySpawnConfiguration || srv.spawnConfiguration == configuration {
                do {
                    try await joinHandshake(
                        srv, timeoutOverride: requestTimeoutOverride
                    )   // fast path still waits for initialize
                    return srv
                } catch let failure as RequestFailure {
                    // A bounded History join expiring says nothing about the
                    // in-flight interactive initialize. Leave its server alone.
                    if case .handshakeWaitTimeout = failure { throw failure }
                    // A failed handshake can never become usable. In particular, keeping
                    // an initialize timeout cached on a still-live process made every
                    // later send in this window fail immediately with the same notice.
                    let recovered = await recoverInitializeServer(
                        srv,
                        applyBackoff: failure.isInitializeTimeout && allowInitializeRetry)
                    guard failure.isInitializeTimeout, allowInitializeRetry else {
                        throw failure
                    }
                    guard recovered else { throw failure }
                    logger.info("codex initialize timed out — retrying once after cleanup backoff")
                    return try await ensureServer(
                        configuration: configuration,
                        workspaceURL: workspaceURL,
                        reuseAnySpawnConfiguration: reuseAnySpawnConfiguration,
                        allowInitializeRetry: false,
                        requestTimeoutOverride: requestTimeoutOverride)
                }
            }
            logger.info("spawn configuration changed — respawning codex app-server")
            killServer(srv)
            guard await joinInitializeRecoveryIfNeeded() else {
                throw RequestFailure.serverExited
            }
            guard !shutdownRequested else { throw RequestFailure.serverExited }
        }

        guard let executable = CodexProvider.resolveExecutable(override: executableOverride) else {
            throw AgentProviderError.executableNotFound(executableOverride ?? "codex")
        }
        let environment = CodexInvocation.environment(
            binaryDirectory: (executable as NSString).deletingLastPathComponent)
        if cachedResolution == nil {
            cachedResolution = (path: executable, version: nil)
        }
        let disabledMCPServerNames: [String]
        if configuration.readOnlyLibrary {
            guard let names = await CodexInvocation.isolatedMCPServerNamesAsync(
                executablePath: executable,
                environment: environment,
                workingDirectory: workspaceURL.path
            ) else {
                throw AgentProviderError.isolationUnavailable
            }
            disabledMCPServerNames = names
        } else {
            disabledMCPServerNames = []
        }
        guard !shutdownRequested else { throw RequestFailure.serverExited }
        let arguments = CodexInvocation.arguments(
            rubienCLIPath: contentChannel?.cliURL.path,
            libraryRoot: contentChannel?.libraryRoot.path,
            webAccess: configuration.webAccess,
            loadUserTools: configuration.loadUserTools,
            readOnlyLibrary: configuration.readOnlyLibrary,
            disabledMCPServerNames: disabledMCPServerNames)

        serverGeneration += 1
        let process = try SpawnedAgentProcess.spawn(
            executablePath: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workspaceURL.path)
        let srv = Server(
            process: process, generation: serverGeneration,
            spawnConfiguration: configuration)
        server = srv
        shuttingDown = false
        startReaders(srv)
        logger.info("codex app-server spawned pid=\(process.pid)")

        // The SPAWNER runs the handshake once; concurrent joiners await its outcome.
        do {
            _ = try await sendRequest(
                srv,
                method: "initialize",
                timeoutOverride: requestTimeoutOverride,
                isHistoryRequest: requestTimeoutOverride != nil
            ) { id in
                CodexAppServerProtocol.initialize(
                    requestID: id, clientName: "rubien-assistant",
                    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            }
            guard server === srv else { throw RequestFailure.serverExited }  // killed mid-handshake
            srv.process.writeLine(CodexAppServerProtocol.initialized())
            completeHandshake(srv, .success(()))
            return srv
        } catch let failure as RequestFailure {
            completeHandshake(srv, .failure(failure))
            let recovered = await recoverInitializeServer(
                srv,
                applyBackoff: failure.isInitializeTimeout && allowInitializeRetry)
            if failure.isInitializeTimeout, allowInitializeRetry {
                guard recovered else { throw failure }
                logger.info("codex initialize timed out — retrying once after cleanup backoff")
                return try await ensureServer(
                    configuration: configuration,
                    workspaceURL: workspaceURL,
                    reuseAnySpawnConfiguration: reuseAnySpawnConfiguration,
                    allowInitializeRetry: false,
                    requestTimeoutOverride: requestTimeoutOverride)
            }
            throw failure
        } catch {
            completeHandshake(srv, .failure(.serverExited))
            if server === srv { killServer(srv) }
            throw RequestFailure.serverExited
        }
    }

    /// Await `srv`'s handshake: return immediately if done, throw its stored failure,
    /// or suspend until the spawner completes it.
    private func joinHandshake(
        _ srv: Server, timeoutOverride: Double? = nil
    ) async throws {
        if srv.handshaked { return }
        if let failure = srv.handshakeFailure { throw failure }
        let waiterID = UUID()
        let timeout = timeoutOverride.map { max(0.001, min(requestTimeout, $0)) }
        let generation = srv.generation
        let outcome: Result<Void, RequestFailure> = await withCheckedContinuation { continuation in
            srv.handshakeWaiters[waiterID] = continuation
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.timeoutHandshakeWaiter(
                        generation: generation, waiterID: waiterID)
                }
            }
        }
        try outcome.get()
    }

    private func timeoutHandshakeWaiter(generation: Int, waiterID: UUID) {
        guard let srv = server, srv.generation == generation,
              let waiter = srv.handshakeWaiters.removeValue(forKey: waiterID)
        else { return }
        logger.error("codex History timed out waiting for initialize")
        waiter.resume(returning: .failure(.handshakeWaitTimeout))
    }

    /// Resolve the handshake for the spawner + every waiter (exactly once).
    private func completeHandshake(_ srv: Server, _ outcome: Result<Void, RequestFailure>) {
        if case .failure(let failure) = outcome { srv.handshakeFailure = failure } else { srv.handshaked = true }
        let waiters = Array(srv.handshakeWaiters.values)
        srv.handshakeWaiters = [:]
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// Kill a server deliberately (respawn path) — turn-independent. Installation
    /// into the recovery gate is what prevents a replacement app-server from starting
    /// before this process has actually reaped.
    private func killServer(_ srv: Server) {
        if server === srv { server = nil }
        failAllPending(srv, with: .serverExited)
        srv.process.closeStdin()
        srv.process.signalGroup(SIGKILL)
        let process = srv.process
        let cleanupWait = Self.initializeCleanupWait
        let task = Task { [logger] in
            guard await process.wait(timeout: cleanupWait) != nil else {
                logger.error("codex app-server replacement did not reap within the bounded wait")
                return false
            }
            return true
        }
        initializeRecovery = InitializeRecovery(token: UUID(), task: task)
    }

    /// Join the recovery owner across actor suspension points. The token prevents a
    /// late waiter from clearing a newer recovery installed after its task completed.
    private func joinInitializeRecoveryIfNeeded() async -> Bool {
        while let recovery = initializeRecovery {
            let recovered = await recovery.task.value
            if !recovered { initializeRecoveryBlocked = true }
            if initializeRecovery?.token == recovery.token {
                initializeRecovery = nil
            }
        }
        return !initializeRecoveryBlocked
    }

    /// Initialization can wedge while Codex is refreshing its runtime or shared
    /// state. Kill/reap the failed process tree and, for the one allowed timeout
    /// retry, hold a connection-wide backoff gate. A concurrent handshake waiter
    /// joins the same recovery; it never starts another cleanup or an early server.
    private func recoverInitializeServer(_ srv: Server, applyBackoff: Bool) async -> Bool {
        if initializeRecovery != nil {
            return await joinInitializeRecoveryIfNeeded()
        }
        guard !initializeRecoveryBlocked else { return false }
        // Another waiter may reach this catch after the owner already recovered and
        // installed a fresh server. The owner was responsible for the old process.
        guard server === srv else { return true }

        server = nil
        failAllPending(srv, with: .serverExited)
        srv.process.closeStdin()
        srv.process.signalGroup(SIGKILL)
        let process = srv.process
        let cleanupWait = Self.initializeCleanupWait
        let retryDelay = initializeRetryDelay
        let task = Task { [logger] in
            if await process.wait(timeout: cleanupWait) == nil {
                logger.error("codex initialize cleanup did not reap within the bounded wait")
                return false
            }
            if applyBackoff {
                try? await Task.sleep(for: retryDelay)
            }
            return true
        }
        let recovery = InitializeRecovery(token: UUID(), task: task)
        initializeRecovery = recovery
        let recovered = await task.value
        if !recovered { initializeRecoveryBlocked = true }
        if initializeRecovery?.token == recovery.token {
            initializeRecovery = nil
        }
        return recovered
    }

    /// Fail every awaiter of `srv` — pending JSON-RPC requests AND handshake joiners
    /// (so a server death during initialize doesn't hang a fast-path reuser).
    private func failAllPending(_ srv: Server, with failure: RequestFailure) {
        let waiting = srv.pending
        srv.pending = [:]
        for (_, request) in waiting {
            request.timeoutTask.cancel()
            request.continuation.resume(returning: .failure(failure))
        }
        if !srv.handshaked && srv.handshakeFailure == nil {
            completeHandshake(srv, .failure(failure))
        }
    }

    /// Independent stdout (JSON-RPC lines) and stderr (bounded ring) drains — a full
    /// stderr pipe must never deadlock stdout parsing (§4.1).
    private func startReaders(_ srv: Server) {
        let generation = srv.generation
        let process = srv.process

        Task { [weak self] in
            do {
                for try await line in process.stdoutHandle.bytes.lines {
                    await self?.route(generation: generation, line: line)
                }
            } catch {
                // A read error is just an early EOF for our purposes.
            }
            await self?.serverClosed(generation: generation)
        }

        let ring = srv.stderr
        let handle = process.stderrHandle
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                ring.append(chunk)
            }
            ring.finish()
        }
    }

    /// The single inbound demux: decode ONCE, then route by frame kind (responses →
    /// pending continuations; server requests → approvals or a conservative reply;
    /// notifications → the active turn's parser/stream).
    private func route(generation: Int, line: String) {
        guard let srv = server, srv.generation == generation else { return }  // stale reader
        guard let inbound = CodexAppServerProtocol.decodeInbound(line: line) else { return }

        switch inbound {
        case .response(let id, let result, let error):
            guard case .number(let requestID) = id else { return }
            if srv.supersededHistoryRequestIDs.remove(requestID) != nil {
                return
            }
            guard let waiter = srv.pending.removeValue(forKey: requestID)
            else { return }  // a response we never asked for / already timed out
            waiter.timeoutTask.cancel()
            if let error {
                let message = (error["message"] as? String) ?? "The assistant reported an error."
                waiter.continuation.resume(returning: .failure(.serverError(message: message)))
            } else {
                // Learn the turn id from the AUTHORITATIVE turn/start response, HERE,
                // before the following notification lines are routed — so the positive
                // filter below accepts exactly this turn (review #2).
                if let active = turn, active.turnStartRequestID == requestID,
                   let turnID = (result?["turn"] as? [String: Any])?["id"] as? String {
                    active.turnID = turnID
                }
                waiter.continuation.resume(returning: .success(result ?? [:]))
            }

        case .serverRequest(let id, let method, let params):
            handleServerRequest(srv, id: id, method: method, params: params)

        case .notification(let method, let params):
            guard let active = turn, !active.finished else { return }
            // POSITIVE turn-id match (review #2): a notification tied to a turn is ours
            // ONLY if its turnId equals the current turn's. A straggler from an old or
            // abandoned turn (including one whose id we never learned, so `turnID` is
            // still nil) is dropped — it can never finish or pollute the current stream.
            // Thread-level notifications (no turnId, e.g. thread/started) pass through.
            if let notificationTurnID = Self.turnID(inNotificationParams: params),
               active.turnID != notificationTurnID {
                return
            }
            for parsed in active.parser.mapEnriched(
                .notification(method: method, params: params)
            ) {
                emit(active, parsed.event, providerItemID: parsed.providerItemID)
                if case .turnCompleted = parsed.event {
                    finishTurn(active)   // the STREAM ends; the server lives (review #5)
                }
            }
        }
    }

    /// The turn id a notification refers to: item/* carry `turnId`; `turn/started` /
    /// `turn/completed` carry `turn.id`.
    private static func turnID(inNotificationParams params: [String: Any]) -> String? {
        if let id = params["turnId"] as? String, !id.isEmpty { return id }
        if let turn = params["turn"] as? [String: Any],
           let id = turn["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    private func handleServerRequest(
        _ srv: Server, id: CodexRPCID, method: String, params: [String: Any]
    ) {
        guard CodexAppServerParser.approvalMethods.contains(method) else {
            // Design #6: an unanswered JSON-RPC request wedges the server — reply
            // conservatively and keep going.
            logger.info("unsupported codex server request \(method) — answered with method-not-found")
            srv.process.writeLine(CodexAppServerProtocol.unsupportedRequestResponse(id: id, method: method))
            return
        }
        let pendingApproval = CodexAppServerProtocol.pendingApproval(id: id, method: method, params: params)
        guard let active = turn, !active.finished else {
            // No live turn to ask (late/stray approval) — decline so nothing runs
            // un-reviewed and the server isn't left waiting.
            srv.process.writeLine(CodexAppServerProtocol.approvalResponse(
                id: id,
                .deny,
                method: pendingApproval.method,
                available: pendingApproval.availableDecisions
            ))
            return
        }
        active.pendingApprovals[id.uiString] = pendingApproval
        for parsed in active.parser.mapEnriched(
            .serverRequest(id: id, method: method, params: params)
        ) {
            emit(active, parsed.event, providerItemID: parsed.providerItemID)
        }
    }

    /// stdout EOF: the server died (crash) or was deliberately killed. Reap, fail
    /// pending requests, and surface a crash notice on any live turn.
    private func serverClosed(generation: Int) async {
        guard let srv = server, srv.generation == generation else {
            // Already replaced/cleared (shutdown or respawn reaps separately).
            return
        }
        server = nil
        // Sweep any surviving group children — codex spawns MCP/helper processes that
        // would orphan on a bare-leader crash (review #3) — and force a process that
        // closed stdout WITHOUT exiting to die, so `wait()` returns promptly instead of
        // hanging every pending request (review #4). Runs BEFORE `wait()` sets
        // `hasExited`, so the A3 no-signal-after-reap invariant holds.
        failAllPending(srv, with: .serverExited)
        let process = srv.process
        // A normal crash closes stdout just before exit. Give that tiny handoff a
        // chance to publish its real status, then always sweep the process group:
        // an already-exited leader can still have live MCP/helper children. Signal
        // before the nonblocking reap so the stable group id cannot be recycled.
        try? await Task.sleep(for: .milliseconds(10))
        process.signalGroup(SIGKILL)
        let cleanupWait = Self.initializeCleanupWait
        let recovery = InitializeRecovery(token: UUID(), task: Task { [logger] in
            guard await process.wait(timeout: cleanupWait) != nil else {
                logger.error("crashed codex app-server group did not disappear and reap within the bounded wait")
                return false
            }
            return true
        })
        initializeRecovery = recovery
        let recovered = await recovery.task.value
        if !recovered { initializeRecoveryBlocked = true }
        if initializeRecovery?.token == recovery.token {
            initializeRecovery = nil
        }
        // `wait(timeout:)` cached the real wait status when recovery succeeded.
        // A failed bounded group proof is reported as unknown and permanently
        // blocks this connection from spawning over a possibly-live predecessor.
        let status = recovered ? await process.wait() : -1

        if let active = turn, !active.finished, !shuttingDown {
            emit(active, .providerNotice(
                await AgentProcessExit.crashNotice(waitStatus: status, stderr: srv.stderr)))
            finishTurn(active)
        }
    }

    // MARK: JSON-RPC request/response correlation

    /// Send one client request and await its response, bounded by `requestTimeout`.
    /// The continuation is resolved exactly once: by `route` (response), by a failure
    /// sweep (server exit), or by the timeout task — all actor-isolated.
    private func sendRequest(
        _ srv: Server,
        method: String,
        timeoutOverride: Double? = nil,
        resetServerOnTimeout: Bool = false,
        isHistoryRequest: Bool = false,
        build: (Int) -> String
    ) async throws -> [String: Any] {
        let requestID = srv.nextRequestID
        srv.nextRequestID += 1
        let line = build(requestID)
        let generation = srv.generation
        let timeout = max(0.001, min(requestTimeout, timeoutOverride ?? requestTimeout))

        let outcome: Result<[String: Any], RequestFailure> = await withCheckedContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(
                    generation: generation,
                    requestID: requestID,
                    method: method,
                    timeout: timeout,
                    resetServerOnTimeout: resetServerOnTimeout)
            }
            srv.pending[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask,
                method: method,
                isHistory: isHistoryRequest)
            srv.process.writeLine(line)
        }
        return try outcome.get()
    }

    private func timeoutRequest(
        generation: Int,
        requestID: Int,
        method: String,
        timeout: Double,
        resetServerOnTimeout: Bool
    ) {
        guard let srv = server, srv.generation == generation,
              let waiter = srv.pending.removeValue(forKey: requestID)
        else { return }
        logger.error("codex request \(method) timed out after \(timeout)s")
        waiter.continuation.resume(returning: .failure(.timeout(method: method)))
        // A timed-out metadata request has proven this stdio server unhealthy.
        // Reset it so Retry gets a clean process instead of writing to the same
        // poisoned pipe. Never kill a server carrying a live interactive turn.
        if resetServerOnTimeout, turn == nil {
            logger.error("resetting wedged codex History app-server")
            killServer(srv)
        }
    }

    // MARK: History over the wire (thread/list · thread/search · thread/read — 3b-4)

    /// Extra rows fetched before a client-side filter (the `cwd` filter on search —
    /// global on codex, the param is ignored; and the reference filter on a scoped
    /// listing), so a workspace with few local hits among many isn't underfilled.
    /// KNOWN BOUND: this is one page, not pagination — a document whose threads
    /// are ALL older than the newest `limit × 5` candidates lists empty under
    /// "This document" (the toggle and search still reach them; the claude store,
    /// which scans its whole folder, has no such bound). If that bites, the fix
    /// is a `thread/list` continuation loop inside the scoped path.
    private static let filterOverfetch = 5
    private static let historyReadConcurrency = 4
    private static let historyCacheLimit = 64
    private var historyLookupGeneration = 0

    /// Supersede best-effort History work before admitting an interactive turn. A
    /// History RPC cannot be cancelled server-side, so its stdio process must be
    /// replaced while it is pending OR while Codex is still executing a request whose
    /// Rubien waiter was superseded. Completed queries retain normal server reuse.
    private func prioritizeInteractiveTurn() {
        historyLookupGeneration &+= 1
        guard let srv = server,
              srv.pending.values.contains(where: \.isHistory)
                || !srv.supersededHistoryRequestIDs.isEmpty
        else { return }
        logger.info("interactive turn is replacing a codex server with unfinished History work")
        killServer(srv)
    }

    /// Only one History lookup owns this connection at a time. A new recents/search
    /// request supersedes hidden work from a prior scope/query and resolves its IPC
    /// waiters without resetting the healthy server.
    private struct MetadataLease {
        let generation: Int
        let workID: UUID
    }

    private func beginMetadataWork(kind: CodexMetadataKind) async -> MetadataLease? {
        // Availability uses standalone `codex --version` / auth processes. Reap
        // that group before metadata is allowed to spawn/reuse app-server so the
        // broker never owns two Codex roots at once.
        await preemptAvailabilityProbeIfNeeded()
        historyLookupGeneration &+= 1
        let workID = UUID()
        let work = CodexScheduledWork(
            workID: workID,
            purpose: .metadata(kind: kind, requestID: workID)
        )
        guard workScheduler.beginMetadata(work) == .admitted else { return nil }
        if let srv = server {
            let requestIDs = srv.pending.compactMap { id, request in
                // A newer History lookup can join the same cold handshake. Removing
                // `initialize` here would discard its eventual response without any
                // protocol-level cancellation, poisoning the server for both lookups.
                request.isHistory && request.method != "initialize" ? id : nil
            }
            for requestID in requestIDs {
                guard let request = srv.pending.removeValue(forKey: requestID) else { continue }
                srv.supersededHistoryRequestIDs.insert(requestID)
                request.timeoutTask.cancel()
                request.continuation.resume(returning: .failure(.historySuperseded))
            }
        }
        return MetadataLease(generation: historyLookupGeneration, workID: workID)
    }

    private func finishMetadataWork(_ lease: MetadataLease) {
        workScheduler.finishMetadata(workID: lease.workID)
    }

    /// Recent conversations for `workspaceURL`, newest first (History picker).
    /// `thread/list` returns summaries with `turns: []` (verified 0.142), so candidates
    /// are projected through bounded-concurrent `thread/read` calls. This is the only
    /// reliable way to hide complete or truncated private manifests. A non-nil
    /// `referenceID` also inspects rubien tool attribution from the same reads.
    func recentThreads(
        workspaceURL: URL, limit: Int, referenceID: Int64? = nil,
        deadline requestedDeadline: Date? = nil
    ) async -> AgentSessionQueryResult {
        guard limit > 0 else { return .completed([]) }
        guard let lease = await beginMetadataWork(kind: .history) else {
            return AgentSessionQueryResult(sessions: [], didTimeOut: true)
        }
        defer { finishMetadataWork(lease) }
        let lookupGeneration = lease.generation
        let deadline = historyDeadline(notAfter: requestedDeadline)
        let fetch = limit * Self.filterOverfetch
        let candidates = await historyQuery(
            workspaceURL: workspaceURL, method: "thread/list",
            deadline: deadline,
            lookupGeneration: lookupGeneration,
            build: { CodexAppServerProtocol.threadList(requestID: $0, cwd: workspaceURL.path, limit: fetch) },
            decode: CodexAppServerProtocol.decodeThreadList)
        guard !candidates.didTimeOut else {
            return AgentSessionQueryResult(sessions: [], didTimeOut: true)
        }
        guard lookupGeneration == historyLookupGeneration else { return .completed([]) }
        let visible = await visibleSummaries(
            candidates.value,
            matching: nil,
            referenceID: referenceID,
            workspaceURL: workspaceURL,
            limit: limit,
            deadline: deadline,
            lookupGeneration: lookupGeneration
        )
        return AgentSessionQueryResult(
            sessions: visible.value, didTimeOut: visible.didTimeOut)
    }

    /// Content search over `workspaceURL`'s threads (History search field). Search is
    /// global on codex, so over-fetch and filter to this workspace in `decode`, then
    /// re-apply the query to safely decoded visible rows before capping at `limit`.
    /// A non-nil `referenceID` additionally scopes hits like `recentThreads`.
    func searchThreads(
        searchTerm: String, workspaceURL: URL, limit: Int,
        referenceID: Int64? = nil, deadline requestedDeadline: Date? = nil
    ) async -> AgentSessionQueryResult {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, limit > 0 else { return .completed([]) }
        guard let lease = await beginMetadataWork(kind: .history) else {
            return AgentSessionQueryResult(sessions: [], didTimeOut: true)
        }
        defer { finishMetadataWork(lease) }
        let lookupGeneration = lease.generation
        let deadline = historyDeadline(notAfter: requestedDeadline)
        let hits = await historyQuery(
            workspaceURL: workspaceURL, method: "thread/search",
            deadline: deadline,
            lookupGeneration: lookupGeneration,
            build: { CodexAppServerProtocol.threadSearch(
                requestID: $0, searchTerm: term, limit: limit * Self.filterOverfetch, cwd: workspaceURL.path) },
            decode: { CodexAppServerProtocol.decodeThreadSearch($0, cwd: workspaceURL.path) })
        guard !hits.didTimeOut else {
            return AgentSessionQueryResult(sessions: [], didTimeOut: true)
        }
        guard lookupGeneration == historyLookupGeneration else { return .completed([]) }
        let visible = await visibleSummaries(
            hits.value,
            matching: term,
            referenceID: referenceID,
            workspaceURL: workspaceURL,
            limit: limit,
            deadline: deadline,
            lookupGeneration: lookupGeneration
        )
        return AgentSessionQueryResult(
            sessions: visible.value, didTimeOut: visible.didTimeOut)
    }

    private struct HistoryLookup<Value> {
        let value: Value
        let didTimeOut: Bool
    }

    private struct HistoryCacheEntry: Sendable {
        let date: Date
        let rows: [ChatRenderMessage]
        let referencedIDs: Set<Int64>
    }

    /// Thread reads feed History rows and reference attribution:
    /// the server's preview/snippet can contain Rubien's synthetic prompt and
    /// private attachment manifest. Cache the safely decoded visible rows and IDs
    /// together so listings, searches, and selection reuse the same local IPC read
    /// until `updatedAt` changes. Attachment-bearing rows are deliberately not cached
    /// because local file availability can change independently of the thread date;
    /// the LRU bound prevents unbounded retention of all other transcripts.
    private var historyCache: [String: HistoryCacheEntry] = [:]
    private var historyCacheOrder: [String] = []

    /// Project server candidates onto visible transcript history, preserving their
    /// server order and stopping once `limit` qualifying rows are collected.
    /// Duplicate source-kind hits are read once. A read failure is skipped and not
    /// cached, so transient failures cannot pin a thread until its next update.
    private func visibleSummaries(
        _ candidates: [AgentSessionSummary],
        matching searchTerm: String?,
        referenceID: Int64?,
        workspaceURL: URL,
        limit: Int,
        deadline: Date,
        lookupGeneration: Int
    ) async -> HistoryLookup<[AgentSessionSummary]> {
        var visited: Set<String> = []
        let uniqueCandidates = candidates.filter { visited.insert($0.id).inserted }
        var kept: [AgentSessionSummary] = []

        var batchStart = 0
        while batchStart < uniqueCandidates.count {
            if kept.count >= limit || Task.isCancelled
                || lookupGeneration != historyLookupGeneration { break }
            let batchSize = min(
                Self.historyReadConcurrency,
                max(1, limit - kept.count)
            )
            let batchEnd = min(
                batchStart + batchSize,
                uniqueCandidates.count
            )
            let batch = Array(uniqueCandidates[batchStart..<batchEnd])
            batchStart = batchEnd
            var histories: [Int: HistoryCacheEntry] = [:]
            var didTimeOut = false

            await withTaskGroup(of: (Int, HistoryLookup<HistoryCacheEntry?>).self) { group in
                for (index, candidate) in batch.enumerated() {
                    group.addTask { [weak self] in
                        guard let self else {
                            return (index, HistoryLookup(value: nil, didTimeOut: false))
                        }
                        return (
                            index,
                            await self.threadHistory(
                                for: candidate,
                                workspaceURL: workspaceURL,
                                deadline: deadline,
                                lookupGeneration: lookupGeneration
                            )
                        )
                    }
                }
                for await (index, history) in group {
                    didTimeOut = didTimeOut || history.didTimeOut
                    if let entry = history.value { histories[index] = entry }
                }
            }

            for (index, candidate) in batch.enumerated() {
                if kept.count >= limit || Task.isCancelled { break }
                guard let history = histories[index] else { continue }
                if let referenceID, !history.referencedIDs.contains(referenceID) { continue }
                guard let visible = CodexAppServerProtocol.visibleSessionSummary(
                    from: candidate,
                    rows: history.rows,
                    matching: searchTerm
                ) else { continue }
                kept.append(visible)
            }
            // One failed batch is enough evidence of contention. Preserve any rows
            // that completed in that batch and stop instead of spending another
            // full timeout on progressively older candidates.
            if didTimeOut {
                return HistoryLookup(value: kept, didTimeOut: true)
            }
        }
        return HistoryLookup(value: kept, didTimeOut: false)
    }

    private func threadHistory(
        for candidate: AgentSessionSummary,
        workspaceURL: URL,
        deadline: Date,
        lookupGeneration: Int
    ) async -> HistoryLookup<HistoryCacheEntry?> {
        let cacheKey = workspaceURL.standardizedFileURL.path + "\0" + candidate.id
        if let cached = historyCache[cacheKey], cached.date == candidate.date {
            touchHistoryCache(cacheKey)
            return HistoryLookup(value: cached, didTimeOut: false)
        }
        let request = await historyRequest(
            workspaceURL: workspaceURL,
            method: "thread/read",
            deadline: deadline,
            lookupGeneration: lookupGeneration,
            build: {
                CodexAppServerProtocol.threadRead(requestID: $0, threadId: candidate.id)
            })
        guard let result = request.value else {
            return HistoryLookup(value: nil, didTimeOut: request.didTimeOut)
        }
        let managedRoot = AssistantAttachmentStore.managedRootURL(for: workspaceURL)
        let entry = HistoryCacheEntry(
            date: candidate.date,
            rows: CodexAppServerProtocol.decodeThreadTranscript(
                result, managedAttachmentsRoot: managedRoot
            ),
            referencedIDs: CodexAppServerProtocol.threadReferencedIDs(result)
        )
        if entry.rows.allSatisfy({ $0.attachments.isEmpty }) {
            storeHistoryCache(entry, forKey: cacheKey)
        } else {
            historyCache.removeValue(forKey: cacheKey)
            historyCacheOrder.removeAll { $0 == cacheKey }
        }
        return HistoryLookup(value: entry, didTimeOut: false)
    }

    /// A picked thread's renderable transcript, so a resume restores its content.
    /// `thread/read` is a read-only preview — NOT `thread/resume` (which would load +
    /// subscribe the thread); the actual continuation resumes on the next turn.
    func readTranscriptResult(
        threadID: String,
        workspaceURL: URL
    ) async -> AgentTranscriptQueryResult {
        guard let lease = await beginMetadataWork(kind: .history) else {
            return .unavailable
        }
        defer { finishMetadataWork(lease) }
        let lookupGeneration = lease.generation
        let cacheKey = workspaceURL.standardizedFileURL.path + "\0" + threadID
        if let cached = historyCache[cacheKey] {
            touchHistoryCache(cacheKey)
            return .completed(cached.rows)
        }
        let result = await historyQuery(
            workspaceURL: workspaceURL, method: "thread/read",
            deadline: Date().addingTimeInterval(historyTimeout),
            lookupGeneration: lookupGeneration,
            build: { CodexAppServerProtocol.threadRead(requestID: $0, threadId: threadID) },
            decode: {
                CodexAppServerProtocol.decodeThreadTranscript(
                    $0,
                    managedAttachmentsRoot: AssistantAttachmentStore.managedRootURL(
                        for: workspaceURL
                    )
                )
            })
        guard lookupGeneration == historyLookupGeneration else {
            return .completed([])
        }
        return .completed(result.value)
    }

    private func storeHistoryCache(_ entry: HistoryCacheEntry, forKey key: String) {
        historyCache[key] = entry
        touchHistoryCache(key)
        while historyCacheOrder.count > Self.historyCacheLimit {
            historyCache.removeValue(forKey: historyCacheOrder.removeFirst())
        }
    }

    private func touchHistoryCache(_ key: String) {
        historyCacheOrder.removeAll { $0 == key }
        historyCacheOrder.append(key)
    }

    private func remainingHistoryTimeout(until deadline: Date) -> Double? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return min(historyTimeout, remaining)
    }

    private func historyDeadline(notAfter requested: Date?) -> Date {
        let own = Date().addingTimeInterval(historyTimeout)
        guard let requested else { return own }
        return min(own, requested)
    }

    /// One bounded metadata request within the caller's overall History deadline.
    /// A timeout resets an idle server so the next user-initiated Retry starts clean.
    private func historyQuery<T>(
        workspaceURL: URL,
        method: String,
        deadline: Date,
        lookupGeneration: Int,
        build: (Int) -> String,
        decode: ([String: Any]) -> [T]
    ) async -> HistoryLookup<[T]> {
        let request = await historyRequest(
            workspaceURL: workspaceURL,
            method: method,
            deadline: deadline,
            lookupGeneration: lookupGeneration,
            build: build)
        guard let response = request.value else {
            return HistoryLookup(value: [], didTimeOut: request.didTimeOut)
        }
        return HistoryLookup(value: decode(response), didTimeOut: false)
    }

    /// Shared bounded IPC path for list/search/read. The generation check prevents
    /// a superseded load that was awaiting initialize from sending new work later.
    private func historyRequest(
        workspaceURL: URL,
        method: String,
        deadline: Date,
        lookupGeneration: Int,
        build: (Int) -> String
    ) async -> HistoryLookup<[String: Any]?> {
        // A live/queued turn owns the single Codex runtime. Metadata is optional;
        // fail fast so opening Home/History during a scheduled job shows Retry
        // instead of competing for app-server initialization for 30 seconds.
        guard !workScheduler.hasTurnWork else {
            return HistoryLookup(value: nil, didTimeOut: true)
        }
        guard let timeout = remainingHistoryTimeout(until: deadline) else {
            return HistoryLookup(value: nil, didTimeOut: true)
        }
        guard lookupGeneration == historyLookupGeneration, !Task.isCancelled else {
            return HistoryLookup(value: nil, didTimeOut: false)
        }
        do {
            let srv = try await ensureServer(
                configuration: .historyDefault,
                workspaceURL: workspaceURL,
                reuseAnySpawnConfiguration: true,
                allowInitializeRetry: false,
                requestTimeoutOverride: timeout)
            guard lookupGeneration == historyLookupGeneration, !Task.isCancelled else {
                return HistoryLookup(value: nil, didTimeOut: false)
            }
            guard let requestTimeout = remainingHistoryTimeout(until: deadline) else {
                return HistoryLookup(value: nil, didTimeOut: true)
            }
            let response = try await sendRequest(
                srv,
                method: method,
                timeoutOverride: requestTimeout,
                resetServerOnTimeout: true,
                isHistoryRequest: true,
                build: build)
            return HistoryLookup(value: response, didTimeOut: false)
        } catch let failure as RequestFailure {
            logger.error("codex \(method) query failed: \(String(describing: failure))")
            return HistoryLookup(
                value: nil, didTimeOut: failure.makesHistoryIncomplete)
        } catch {
            logger.error("codex \(method) query failed: \(String(describing: error))")
            return HistoryLookup(value: nil, didTimeOut: false)
        }
    }

    /// Model metadata over the same app-server used by every production Codex
    /// surface. It is best effort: a live/queued turn wins immediately, and callers
    /// can retry without ever creating a second runtime.
    func fetchModelCatalog(
        workspaceURL: URL,
        timeout: Double
    ) async -> CodexCatalog {
        guard let lease = await beginMetadataWork(kind: .modelCatalog) else { return .unavailable }
        defer { finishMetadataWork(lease) }
        do {
            let srv = try await ensureServer(
                configuration: .historyDefault,
                workspaceURL: workspaceURL,
                reuseAnySpawnConfiguration: true,
                allowInitializeRetry: false,
                requestTimeoutOverride: timeout)
            guard workScheduler.metadata?.workID == lease.workID else {
                return .unavailable
            }
            let result = try await sendRequest(
                srv,
                method: "model/list",
                timeoutOverride: timeout,
                resetServerOnTimeout: true,
                isHistoryRequest: true,
                build: { CodexAppServerProtocol.modelList(requestID: $0) })
            return CodexCatalog(
                models: CodexAppServerProtocol.decodeModelList(result),
                fetchedOK: true)
        } catch {
            logger.error("codex model/list query failed: \(String(describing: error))")
            return .unavailable
        }
    }

    // MARK: Availability

    func isAvailable() async -> AgentAvailability {
        // Recheck is observational while turn work is active/reserved/queued. A
        // standalone `login status` process must never overlap the broker's root.
        if workScheduler.hasTurnWork {
            if let cachedResolution {
                return .installed(
                    version: cachedResolution.version,
                    path: cachedResolution.path
                )
            }
            guard let path = CodexProvider.resolveExecutable(
                override: executableOverride
            ) else {
                return Self.codexNotFound()
            }
            cachedResolution = (path: path, version: nil)
            return .installed(version: nil, path: path)
        }

        if let probe = availabilityProbe {
            return await finishAvailabilityProbe(probe)
        }
        guard let path = cachedResolution?.path
            ?? CodexProvider.resolveExecutable(override: executableOverride) else {
            return Self.codexNotFound()
        }
        guard let lease = await beginMetadataWork(kind: .availability) else {
            return .installed(version: cachedResolution?.version, path: path)
        }

        // An idle app-server proves installation, not current authentication. Codex
        // exposes no equivalent bounded auth RPC, so retire and reap that idle root
        // before starting the standalone version/login probe. A turn admitted while
        // reaping clears this metadata lease and wins before any probe can spawn.
        if let idleServer = server {
            killServer(idleServer)
            let recovered = await joinInitializeRecoveryIfNeeded()
            guard workScheduler.metadata?.workID == lease.workID else {
                return .installed(version: cachedResolution?.version, path: path)
            }
            guard recovered else {
                workScheduler.finishMetadata(workID: lease.workID)
                return .installedButUnauthenticated(
                    version: cachedResolution?.version,
                    path: path,
                    reason: "Codex is installed, but Rubien could not safely restart its idle runtime to recheck sign-in. Restart Rubien, then recheck."
                )
            }
        }
        guard workScheduler.metadata?.workID == lease.workID else {
            return .installed(version: cachedResolution?.version, path: path)
        }
        let environment = CodexInvocation.environment(
            binaryDirectory: (path as NSString).deletingLastPathComponent)
        let token = UUID()
        let task = Task.detached { () -> AgentAvailability in
            guard let version = await AgentBinaryProbe.probeVersion(
                executablePath: path,
                environment: environment,
                retryOnce: true
            ) else {
                if Task.isCancelled {
                    return .installed(version: nil, path: path)
                }
                return .notFound(
                    reason: "Found codex at \(path) but it did not respond to --version."
                )
            }
            guard !Task.isCancelled else {
                return .installed(version: version, path: path)
            }
            if await AgentAuthProbe.probeCodex(
                executablePath: path,
                environment: environment
            ) == .unauthenticated {
                return .installedButUnauthenticated(
                    version: version,
                    path: path,
                    reason: "Codex is installed but not signed in. Run codex login in Terminal, then recheck."
                )
            }
            return .installed(version: version, path: path)
        }
        let probe = AvailabilityProbe(
            token: token,
            path: path,
            metadataWorkID: lease.workID,
            task: task
        )
        availabilityProbe = probe
        return await finishAvailabilityProbe(probe)
    }

    private func finishAvailabilityProbe(
        _ probe: AvailabilityProbe
    ) async -> AgentAvailability {
        let result = await probe.task.value
        guard availabilityProbe?.token == probe.token else { return result }
        availabilityProbe = nil
        workScheduler.finishMetadata(workID: probe.metadataWorkID)
        if result.isInstalled {
            cachedResolution = (path: probe.path, version: result.version)
        }
        return result
    }

    private func preemptAvailabilityProbeIfNeeded() async {
        guard let probe = availabilityProbe else { return }
        probe.task.cancel()
        await availabilityPreemptionHook?()
        _ = await probe.task.value
        if availabilityProbe?.token == probe.token {
            availabilityProbe = nil
            workScheduler.finishMetadata(workID: probe.metadataWorkID)
        }
    }

    private static func codexNotFound() -> AgentAvailability {
        .notFound(
            reason: "Codex CLI wasn’t found. Install Codex or set the binary path in Settings → Assistant, then recheck."
        )
    }

    // MARK: Response helpers

    /// `thread/start` / `thread/resume` responses both carry `{thread: {id: …}}`.
    private static func threadID(fromThreadResponse result: [String: Any]) -> String? {
        guard let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }
}
#endif
