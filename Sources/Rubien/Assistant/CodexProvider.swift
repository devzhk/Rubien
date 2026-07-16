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
//   • Codex:  one server PER CONVERSATION/WINDOW — spawned lazily on the first send,
//     reused for every follow-up turn (`turn/start` on the live thread), and killed
//     only on `shutdown()` (window close) or its own exit. Dropping a turn's stream
//     or pressing stop sends `turn/interrupt`; the SERVER LIVES (design review #5).
//
// Config posture (§4, user decision): NO managed CODEX_HOME — the user's real
// `~/.codex` provides auth/config exactly as Claude keeps `~/.claude`. Ambient config
// is neutralized per-invocation: `approvalPolicy`/`sandbox` ride `thread/start`,
// `effort` rides `turn/start` (both verified to override the user's defaults), the
// rubien content channel is injected via `-c mcp_servers.rubien.*` KEY overrides
// (verified to replace a user-configured `rubien` entry), and codex's built-in app
// connectors are dropped via `--disable apps` unless the conversation explicitly
// opts into the user's normal connected apps and tools.

final class CodexProvider: AgentProvider {
    let kind: AgentProviderKind = .codex

    private let connection: CodexAppServerConnection
    private let executableOverride: String?

    init(executableOverride: String? = nil, contentChannel: MCPContentChannel? = nil) {
        self.executableOverride = executableOverride
        self.connection = CodexAppServerConnection(
            executableOverride: executableOverride, contentChannel: contentChannel)
    }

    func isAvailable() async -> AgentAvailability {
        await connection.isAvailable()
    }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let token = UUID()
        let connection = self.connection
        return AsyncThrowingStream { continuation in
            // Dropping the consumed stream ends THE TURN (turn/interrupt), never the
            // long-lived server — the semantic divergence from Claude (review #5).
            continuation.onTermination = { _ in
                Task { await connection.interruptIfCurrent(token: token) }
            }
            Task {
                await connection.startTurn(token: token, request: turn, continuation: continuation)
            }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {
        let connection = self.connection
        Task { await connection.respond(id: id, decision: decision) }
    }

    /// Stop button / conversation reset: interrupt the live turn; the server stays.
    func cancel() {
        let connection = self.connection
        Task { await connection.interruptCurrent() }
    }

    /// Window close: kill the server's whole process tree.
    func shutdown() {
        let connection = self.connection
        Task { await connection.shutdown() }
    }

    // History over the wire (`thread/list` / `thread/search` / `thread/read`, 3b-4).
    // Each delegates to the connection, which reads codex's OWN thread store via the
    // app-server (Rubien persists nothing — D5). All degrade to `[]` on failure.

    func recentSessions(workspaceURL: URL, limit: Int, referenceID: Int64?) async -> [AgentSessionSummary] {
        await connection.recentThreads(
            workspaceURL: workspaceURL, limit: limit, referenceID: referenceID)
    }

    func searchSessions(query: String, workspaceURL: URL, limit: Int, referenceID: Int64?) async -> [AgentSessionSummary] {
        await connection.searchThreads(
            searchTerm: query, workspaceURL: workspaceURL, limit: limit, referenceID: referenceID)
    }

    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage] {
        await connection.readTranscript(threadID: sessionID, workspaceURL: workspaceURL)
    }

    /// The installed codex's own model catalog (memoized per binary — one probe
    /// spawn per launch; spec §4.1). Feeds pickers only.
    func availableModels() async -> CodexCatalog? {
        await CodexModelCatalog.shared.catalog(executableOverride: executableOverride)
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

// MARK: - CodexInvocation (pure argv + env construction; unit-tested)

/// The exact `codex` argv and minimal child environment for one app-server spawn.
/// Extracted from the connection so it can be verified without spawning anything
/// (mirrors `ClaudeCLIInvocation`).
enum CodexInvocation {

    /// Arguments for the long-lived `codex app-server` process.
    ///
    /// - `loadUserTools` (the "use my other MCP servers" opt-in lever, default OFF):
    ///   when off, `--disable apps` drops codex's BUILT-IN app connectors (the one
    ///   net-new silent-read surface vs Claude — §4). The user's own configured
    ///   `~/.codex` servers still load either way (codex has no `--strict-mcp-config`
    ///   analogue — accepted posture).
    /// - `webAccess=false` disables codex's built-in web search for this server.
    /// - The rubien `-c` KEY overrides replace any user-configured `rubien` entry
    ///   field-by-field (command/args/env all set), so exactly one rubien loads.
    static func arguments(
        rubienCLIPath: String?,
        libraryRoot: String?,
        webAccess: Bool,
        loadUserTools: Bool = false
    ) -> [String] {
        var args = ["app-server"]
        if !loadUserTools {
            args += ["--disable", "apps"]
        }
        if !webAccess {
            args += ["-c", "tools.web_search=false"]
        }
        if let cli = rubienCLIPath, !cli.isEmpty {
            // Values are parsed as TOML with a raw-string fallback, so bare paths are
            // safe; the args array must stay valid TOML. The key is the canonical
            // server name — the same one History attribution matches against.
            let server = "mcp_servers.\(MCPContentChannel.serverName)"
            args += ["-c", "\(server).command=\(cli)"]
            args += ["-c", #"\#(server).args=["mcp"]"#]
            // The native catalog annotates all 14 reads and 13 writes. Prompt
            // for every non-read tool, and allow the two long intake routes to
            // use their own five-minute child timeout without Codex cutting the
            // outer MCP call off at its 60-second default.
            args += ["-c", "\(server).default_tools_approval_mode=writes"]
            args += ["-c", "\(server).tool_timeout_sec=310"]
            // Keep the app-private paper-card tool in lockstep with Claude's
            // inline MCP configuration. Without this flag Codex sees only the
            // public catalog and can fall back only to Markdown paper links.
            args += [
                "-c",
                #"\#(server).env.\#(MCPContentChannel.appPresentationEnvironmentKey)="\#(MCPContentChannel.appPresentationEnvironmentValue)""#,
            ]
            if let root = libraryRoot, !root.isEmpty {
                args += ["-c", "\(server).env.RUBIEN_LIBRARY_ROOT=\(root)"]
            }
        }
        return args
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

private actor CodexAppServerConnection {
    private let executableOverride: String?
    private let contentChannel: MCPContentChannel?
    private let logger = RubienLogger(subsystem: "com.rubien.assistant", category: "CodexProvider")

    init(executableOverride: String?, contentChannel: MCPContentChannel?) {
        self.executableOverride = executableOverride
        self.contentChannel = contentChannel
    }

    // Tunables (single point — mirrors ClaudeTurnEngine's named timers).
    /// Bound on any single JSON-RPC request (initialize / thread ops / turn/start).
    private static let requestTimeout: Double = 30
    /// After `turn/interrupt`, force-finish the turn stream if the server never
    /// delivers the interrupted `turn/completed` (the server itself stays alive).
    private static let interruptGrace: Double = 5
    /// After `shutdown`'s SIGTERM, escalate to SIGKILL.
    private static let shutdownHardKillDelay: Double = 2
    // The crash-notice drain grace + tail size are shared (`AgentProcessExit`).

    /// A JSON-RPC request failure (soft — surfaced as a §4.5 notice, never thrown).
    private enum RequestFailure: Error {
        case timeout(method: String)
        case serverError(message: String)
        case serverExited

        var noticeText: String {
            switch self {
            case .timeout(let method):
                return "The assistant did not respond (\(method) timed out)."
            case .serverError(let message):
                return message
            case .serverExited:
                return "The assistant ended unexpectedly."
            }
        }
    }

    // MARK: Long-lived server state

    /// Every option fixed when `codex app-server` starts. Turns can reuse a server
    /// only when this snapshot matches; History may explicitly reuse any live one.
    private struct SpawnConfiguration: Equatable {
        let webAccess: Bool
        let loadUserTools: Bool

        /// A fresh History-only server uses the normal web default and isolated Apps
        /// posture. If a turn follows with different settings it will respawn once.
        static let historyDefault = SpawnConfiguration(
            webAccess: true, loadUserTools: false)
    }

    /// One spawned `codex app-server` + its JSON-RPC bookkeeping. Reference type,
    /// only touched inside this actor's isolation.
    private final class Server {
        let process: SpawnedAgentProcess
        let generation: Int
        let spawnConfiguration: SpawnConfiguration
        let stderr = StderrRingBuffer()
        var nextRequestID = 1
        var pending: [Int: CheckedContinuation<Result<[String: Any], RequestFailure>, Never>] = [:]
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
        var handshakeWaiters: [CheckedContinuation<Result<Void, RequestFailure>, Never>] = []

        init(
            process: SpawnedAgentProcess, generation: Int,
            spawnConfiguration: SpawnConfiguration
        ) {
            self.process = process
            self.generation = generation
            self.spawnConfiguration = spawnConfiguration
        }
    }

    private var server: Server?
    private var serverGeneration = 0
    /// Set during a deliberate `shutdown()` so the reader's EOF path doesn't compose
    /// a scary crash notice for an intentional kill.
    private var shuttingDown = false

    // MARK: Per-turn state

    private final class ActiveTurn {
        let token: UUID
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        var parser = CodexAppServerParser()
        var threadID: String?
        var turnID: String?
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

        init(token: UUID, continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) {
            self.token = token
            self.continuation = continuation
        }
    }

    private var turn: ActiveTurn?
    /// Tokens interrupted BEFORE their `startTurn` ran (A1 — the consumer dropped the
    /// stream in the window between `send()` arming `onTermination` and the task).
    private var cancelledTokens: Set<UUID> = []
    /// Only the binary path + --version is cached (expensive to resolve). Auth is NOT
    /// cached — re-probed on every isAvailable() so a mid-session sign-out is reflected
    /// instead of Recheck being a no-op (#11); a not-found stays uncached (B6).
    private var cachedResolution: (path: String, version: String)?

    // MARK: Turn lifecycle

    func startTurn(
        token: UUID,
        request: AgentTurnRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        if cancelledTokens.remove(token) != nil {
            continuation.finish()
            return
        }
        // A2: one turn at a time per connection. A still-live prior turn means a
        // serialization violation upstream — interrupt + finish it, not orphan it.
        if let existing = turn, !existing.finished {
            logger.error("startTurn entered with an unfinished turn active — finishing the prior turn")
            requestInterrupt(existing)
            finishTurn(existing)
        }

        let active = ActiveTurn(token: token, continuation: continuation)
        turn = active

        // 1. Server (lazy spawn + handshake; reused across turns).
        let srv: Server
        do {
            srv = try await ensureServer(
                configuration: SpawnConfiguration(
                    webAccess: request.webAccess,
                    loadUserTools: request.loadUserTools),
                workspaceURL: request.workspaceURL)
        } catch let error as AgentProviderError {
            turn = nil
            continuation.finish(throwing: error)   // hard start failure — mirrors Claude
            return
        } catch let failure as RequestFailure {
            failTurn(active, failure)
            return
        } catch {
            failTurn(active, .serverExited)
            return
        }
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
            // The controller re-captures the session id from every turn (D5); codex's
            // thread id is stable, so re-emitting is an idempotent no-op there.
            continuation.yield(.sessionStarted(sessionID: threadID))
            // The RESOLVED model (spec §2.2): what this thread actually runs —
            // codex's own config resolution when the request omitted `model`.
            if let resolvedModel {
                continuation.yield(.modelResolved(model: resolvedModel))
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
    private func failTurn(_ active: ActiveTurn, _ failure: RequestFailure) {
        guard !active.finished else { return }
        active.continuation.yield(.providerNotice(failure.noticeText))
        finishTurn(active)
    }

    private func finishTurn(_ active: ActiveTurn) {
        guard !active.finished else { return }
        active.finished = true
        active.continuation.finish()
        cancelledTokens.remove(active.token)
        if turn === active { turn = nil }
        // A straggler notification for this now-finished turn can't reach a LATER turn:
        // the positive turn-id filter in `route` accepts only the current turn's id
        // (review #2) — no stale-id set to accumulate.
    }

    // MARK: External controls

    func respond(id: String, decision: ApprovalDecision) {
        guard let active = turn, !active.finished,
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
        } else {
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

    /// Window close: kill the server's whole tree. The turn stream (if any) is
    /// finished FIRST so the reader's EOF path sees a deliberate shutdown.
    func shutdown() {
        if let active = turn { finishTurn(active) }
        guard let srv = server else { return }
        shuttingDown = true
        server = nil
        failAllPending(srv, with: .serverExited)
        srv.process.closeStdin()
        srv.process.signalGroup(SIGTERM)
        let process = srv.process
        Task {
            try? await Task.sleep(for: .seconds(Self.shutdownHardKillDelay))
            process.signalGroup(SIGKILL)
        }
        // The reader task's EOF → serverClosed(generation:) reaps; it early-returns
        // for bookkeeping because `server` is already nil.
        Task { _ = await process.wait() }
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
        reuseAnySpawnConfiguration: Bool = false
    ) async throws -> Server {
        if let srv = server {
            if reuseAnySpawnConfiguration || srv.spawnConfiguration == configuration {
                try await joinHandshake(srv)   // fast path still waits for initialize
                return srv
            }
            logger.info("spawn configuration changed — respawning codex app-server")
            killServer(srv)
        }

        guard let executable = CodexProvider.resolveExecutable(override: executableOverride) else {
            throw AgentProviderError.executableNotFound(executableOverride ?? "codex")
        }
        let arguments = CodexInvocation.arguments(
            rubienCLIPath: contentChannel?.cliURL.path,
            libraryRoot: contentChannel?.libraryRoot.path,
            webAccess: configuration.webAccess,
            loadUserTools: configuration.loadUserTools)
        let environment = CodexInvocation.environment(
            binaryDirectory: (executable as NSString).deletingLastPathComponent)

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
            _ = try await sendRequest(srv, method: "initialize") { id in
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
            throw failure
        } catch {
            completeHandshake(srv, .failure(.serverExited))
            throw RequestFailure.serverExited
        }
    }

    /// Await `srv`'s handshake: return immediately if done, throw its stored failure,
    /// or suspend until the spawner completes it.
    private func joinHandshake(_ srv: Server) async throws {
        if srv.handshaked { return }
        if let failure = srv.handshakeFailure { throw failure }
        let outcome: Result<Void, RequestFailure> = await withCheckedContinuation { continuation in
            srv.handshakeWaiters.append(continuation)
        }
        try outcome.get()
    }

    /// Resolve the handshake for the spawner + every waiter (exactly once).
    private func completeHandshake(_ srv: Server, _ outcome: Result<Void, RequestFailure>) {
        if case .failure(let failure) = outcome { srv.handshakeFailure = failure } else { srv.handshaked = true }
        let waiters = srv.handshakeWaiters
        srv.handshakeWaiters = []
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// Kill a server deliberately (respawn path) — turn-independent.
    private func killServer(_ srv: Server) {
        if server === srv { server = nil }
        failAllPending(srv, with: .serverExited)
        srv.process.closeStdin()
        srv.process.signalGroup(SIGKILL)
        let process = srv.process
        Task { _ = await process.wait() }
    }

    /// Fail every awaiter of `srv` — pending JSON-RPC requests AND handshake joiners
    /// (so a server death during initialize doesn't hang a fast-path reuser).
    private func failAllPending(_ srv: Server, with failure: RequestFailure) {
        let waiting = srv.pending
        srv.pending = [:]
        for (_, continuation) in waiting {
            continuation.resume(returning: .failure(failure))
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
            guard case .number(let requestID) = id,
                  let waiter = srv.pending.removeValue(forKey: requestID)
            else { return }  // a response we never asked for / already timed out
            if let error {
                let message = (error["message"] as? String) ?? "The assistant reported an error."
                waiter.resume(returning: .failure(.serverError(message: message)))
            } else {
                // Learn the turn id from the AUTHORITATIVE turn/start response, HERE,
                // before the following notification lines are routed — so the positive
                // filter below accepts exactly this turn (review #2).
                if let active = turn, active.turnStartRequestID == requestID,
                   let turnID = (result?["turn"] as? [String: Any])?["id"] as? String {
                    active.turnID = turnID
                }
                waiter.resume(returning: .success(result ?? [:]))
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
            for event in active.parser.map(.notification(method: method, params: params)) {
                active.continuation.yield(event)
                if case .turnCompleted = event {
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
        for event in active.parser.map(.serverRequest(id: id, method: method, params: params)) {
            active.continuation.yield(event)
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
        srv.process.signalGroup(SIGKILL)
        let status = await srv.process.wait()
        failAllPending(srv, with: .serverExited)

        if let active = turn, !active.finished, !shuttingDown {
            active.continuation.yield(.providerNotice(
                await AgentProcessExit.crashNotice(waitStatus: status, stderr: srv.stderr)))
            finishTurn(active)
        }
    }

    // MARK: JSON-RPC request/response correlation

    /// Send one client request and await its response, bounded by `requestTimeout`.
    /// The continuation is resolved exactly once: by `route` (response), by a failure
    /// sweep (server exit), or by the timeout task — all actor-isolated.
    private func sendRequest(
        _ srv: Server, method: String, build: (Int) -> String
    ) async throws -> [String: Any] {
        let requestID = srv.nextRequestID
        srv.nextRequestID += 1
        let line = build(requestID)
        let generation = srv.generation

        let outcome: Result<[String: Any], RequestFailure> = await withCheckedContinuation { continuation in
            srv.pending[requestID] = continuation
            srv.process.writeLine(line)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.requestTimeout))
                await self?.timeoutRequest(generation: generation, requestID: requestID, method: method)
            }
        }
        return try outcome.get()
    }

    private func timeoutRequest(generation: Int, requestID: Int, method: String) {
        guard let srv = server, srv.generation == generation,
              let waiter = srv.pending.removeValue(forKey: requestID)
        else { return }
        logger.error("codex request \(method) timed out after \(Self.requestTimeout)s")
        waiter.resume(returning: .failure(.timeout(method: method)))
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

    /// Recent conversations for `workspaceURL`, newest first (History picker).
    /// `thread/list` returns summaries with `turns: []` (verified 0.142), so candidates
    /// are projected through bounded-concurrent `thread/read` calls. This is the only
    /// reliable way to hide complete or truncated private manifests. A non-nil
    /// `referenceID` also inspects rubien tool attribution from the same reads.
    func recentThreads(workspaceURL: URL, limit: Int, referenceID: Int64? = nil) async -> [AgentSessionSummary] {
        guard limit > 0 else { return [] }
        let fetch = limit * Self.filterOverfetch
        let candidates = await query(
            workspaceURL: workspaceURL, method: "thread/list",
            build: { CodexAppServerProtocol.threadList(requestID: $0, cwd: workspaceURL.path, limit: fetch) },
            decode: CodexAppServerProtocol.decodeThreadList)
        return await visibleSummaries(
            candidates,
            matching: nil,
            referenceID: referenceID,
            workspaceURL: workspaceURL,
            limit: limit
        )
    }

    /// Content search over `workspaceURL`'s threads (History search field). Search is
    /// global on codex, so over-fetch and filter to this workspace in `decode`, then
    /// re-apply the query to safely decoded visible rows before capping at `limit`.
    /// A non-nil `referenceID` additionally scopes hits like `recentThreads`.
    func searchThreads(
        searchTerm: String, workspaceURL: URL, limit: Int, referenceID: Int64? = nil
    ) async -> [AgentSessionSummary] {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, limit > 0 else { return [] }
        let hits = await query(
            workspaceURL: workspaceURL, method: "thread/search",
            build: { CodexAppServerProtocol.threadSearch(
                requestID: $0, searchTerm: term, limit: limit * Self.filterOverfetch, cwd: workspaceURL.path) },
            decode: { CodexAppServerProtocol.decodeThreadSearch($0, cwd: workspaceURL.path) })
        return await visibleSummaries(
            hits,
            matching: term,
            referenceID: referenceID,
            workspaceURL: workspaceURL,
            limit: limit
        )
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
        limit: Int
    ) async -> [AgentSessionSummary] {
        var visited: Set<String> = []
        let uniqueCandidates = candidates.filter { visited.insert($0.id).inserted }
        var kept: [AgentSessionSummary] = []

        var batchStart = 0
        while batchStart < uniqueCandidates.count {
            if kept.count >= limit || Task.isCancelled { break }
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

            await withTaskGroup(of: (Int, HistoryCacheEntry?).self) { group in
                for (index, candidate) in batch.enumerated() {
                    group.addTask { [weak self] in
                        guard let self else { return (index, nil) }
                        return (
                            index,
                            await self.threadHistory(
                                for: candidate,
                                workspaceURL: workspaceURL
                            )
                        )
                    }
                }
                for await (index, history) in group {
                    if let history { histories[index] = history }
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
        }
        return kept
    }

    private func threadHistory(
        for candidate: AgentSessionSummary,
        workspaceURL: URL
    ) async -> HistoryCacheEntry? {
        let cacheKey = workspaceURL.standardizedFileURL.path + "\0" + candidate.id
        if let cached = historyCache[cacheKey], cached.date == candidate.date {
            touchHistoryCache(cacheKey)
            return cached
        }
        do {
            let srv = try await ensureServer(
                configuration: .historyDefault,
                workspaceURL: workspaceURL,
                reuseAnySpawnConfiguration: true)
            let result = try await sendRequest(srv, method: "thread/read") {
                CodexAppServerProtocol.threadRead(requestID: $0, threadId: candidate.id)
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
            return entry
        } catch {
            logger.error("codex history read failed: \(String(describing: error))")
            return nil
        }
    }

    /// A picked thread's renderable transcript, so a resume restores its content.
    /// `thread/read` is a read-only preview — NOT `thread/resume` (which would load +
    /// subscribe the thread); the actual continuation resumes on the next turn.
    func readTranscript(threadID: String, workspaceURL: URL) async -> [ChatRenderMessage] {
        let cacheKey = workspaceURL.standardizedFileURL.path + "\0" + threadID
        if let cached = historyCache[cacheKey] {
            touchHistoryCache(cacheKey)
            return cached.rows
        }
        return await query(
            workspaceURL: workspaceURL, method: "thread/read",
            build: { CodexAppServerProtocol.threadRead(requestID: $0, threadId: threadID) },
            decode: {
                CodexAppServerProtocol.decodeThreadTranscript(
                    $0,
                    managedAttachmentsRoot: AssistantAttachmentStore.managedRootURL(
                        for: workspaceURL
                    )
                )
            })
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

    /// One-shot read: ensure a live server (reuse ANY running one because History does
    /// not depend on turn configuration; `historyDefault` only matters for a fresh
    /// spawn), send the request, and decode. Any failure degrades to `[]`, never
    /// throwing into the UI. `build`/`decode` are synchronous, so neither escapes.
    private func query<T>(
        workspaceURL: URL, method: String,
        build: (Int) -> String, decode: ([String: Any]) -> [T]
    ) async -> [T] {
        do {
            let srv = try await ensureServer(
                configuration: .historyDefault,
                workspaceURL: workspaceURL,
                reuseAnySpawnConfiguration: true)
            return decode(try await sendRequest(srv, method: method, build: build))
        } catch {
            logger.error("codex \(method) query failed: \(String(describing: error))")
            return []
        }
    }

    // MARK: Availability

    func isAvailable() async -> AgentAvailability {
        // Resolve the binary + --version once and cache THAT (expensive: candidate walk,
        // possibly a login-shell `command -v`, plus the version subprocess). Auth is
        // re-probed on EVERY call so a mid-session sign-out / token expiry is reflected —
        // caching the ready result made Recheck a no-op after logout (#11).
        let path: String
        let version: String
        let environment: [String: String]
        if let cached = cachedResolution {
            path = cached.path
            version = cached.version
            environment = CodexInvocation.environment(
                binaryDirectory: (path as NSString).deletingLastPathComponent)
        } else {
            guard let resolved = CodexProvider.resolveExecutable(override: executableOverride) else {
                return .notFound(
                    reason: "Codex CLI wasn’t found. Install Codex or set the binary path in Settings → Assistant, then recheck.")
            }
            environment = CodexInvocation.environment(
                binaryDirectory: (resolved as NSString).deletingLastPathComponent)
            guard let probedVersion = await AgentBinaryProbe.probeVersion(
                executablePath: resolved,
                environment: environment)
            else {
                return .notFound(reason: "Found codex at \(resolved) but it did not respond to --version.")
            }
            cachedResolution = (path: resolved, version: probedVersion)
            path = resolved
            version = probedVersion
        }
        if await AgentAuthProbe.probeCodex(executablePath: path, environment: environment) == .unauthenticated {
            return .installedButUnauthenticated(
                version: version,
                path: path,
                reason: "Codex is installed but not signed in. Run codex login in Terminal, then recheck.")
        }
        return .installed(version: version, path: path)
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
