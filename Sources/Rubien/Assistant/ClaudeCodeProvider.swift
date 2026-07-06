#if os(macOS)
import Darwin
import Foundation
import RubienCore

// MARK: - ClaudeCodeProvider (Phase 2a)
//
// Spawns and drives the real `claude` CLI, one process per turn (D3), streaming
// stream-json events out and answering `can_use_tool` control requests on stdin
// (§4.2). Process mechanics are normative (§4.1): a minimal ALLOWLISTED env (never
// the app env), each turn in its OWN process group, process-tree kill on cancel,
// independent stdout/stderr draining, and a stale-process guard.
//
// The public type is a `Sendable` `final class`; all mutable turn state lives on an
// internal `actor` (`ClaudeTurnEngine`) so the synchronous protocol methods
// (`send`/`respondToApproval`/`cancel`) can forward without data races.
//
// **One conversation per instance:** a `ClaudeCodeProvider` runs a single turn at a
// time; cross-window serialization is the process-wide `AssistantTurnGate`'s job. If
// a second turn is ever started while one is still live, the engine cancels and
// finalizes the prior one rather than silently orphaning its process (A2).
//
// Extension points (deliberately NOT wired here — later phases):
//   • MCP content channel (`--mcp-config`/`--strict-mcp-config`) — Phase 2b. See
//     `ClaudeTurnEngine.buildArguments`, where the flag would slot in.
//   • Node ≥20 / MCP health in `isAvailable()` — Phase 2b.

final class ClaudeCodeProvider: AgentProvider {
    let kind: AgentProviderKind = .claude

    private let engine: ClaudeTurnEngine
    /// An explicit binary path that wins over discovery. Injected by tests (the fake
    /// CLI) and, in production, by the Settings "binary path" override (a later
    /// phase wires `RubienPreferences` here).
    private let executableOverride: String?
    /// The read-only MCP content channel (Phase 2b) — the bundled `rubien-cli mcp`
    /// server pointed at the app's library, attached via `--mcp-config`. nil ⇒ the
    /// turn runs without document tools (the channel couldn't be resolved).
    private let contentChannel: MCPContentChannel?

    init(executableOverride: String? = nil, contentChannel: MCPContentChannel? = nil) {
        self.executableOverride = executableOverride
        self.contentChannel = contentChannel
        self.engine = ClaudeTurnEngine()
    }

    func isAvailable() async -> AgentAvailability {
        await engine.isAvailable(override: executableOverride)
    }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let token = UUID()
        let engine = self.engine
        let override = executableOverride
        let mcpConfig = contentChannel?.configArgument()
        return AsyncThrowingStream { continuation in
            // Breaking/cancelling the consumed stream (e.g. window closed mid-turn)
            // kills this turn's process group — turn-scoped so it can't clobber a
            // later turn.
            continuation.onTermination = { _ in
                Task { await engine.cancelIfCurrent(token: token) }
            }
            Task {
                await engine.startTurn(
                    token: token, request: turn,
                    executableOverride: override, mcpConfig: mcpConfig,
                    continuation: continuation)
            }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {
        let engine = self.engine
        Task { await engine.respond(id: id, decision: decision) }
    }

    func cancel() {
        let engine = self.engine
        Task { await engine.cancelCurrent() }
    }

    /// Light read of Claude's own session store for the History picker (§5.3).
    /// Runs the blocking file I/O off the main actor; `workspaceURL`/`limit` are the
    /// only captures (the store + FileManager are created inside the detached task).
    func recentSessions(workspaceURL: URL, limit: Int) async -> [AgentSessionSummary] {
        await Task.detached(priority: .userInitiated) {
            ClaudeSessionStore().recentSessions(workspaceURL: workspaceURL, limit: limit)
        }.value
    }

    /// A picked session's full transcript (resume restores the conversation's
    /// content). Same off-main-actor file I/O pattern as `recentSessions`.
    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage] {
        await Task.detached(priority: .userInitiated) {
            ClaudeSessionStore().fullTranscript(sessionID: sessionID, workspaceURL: workspaceURL)
        }.value
    }

    /// Content search over the store's sessions (History picker's search field).
    /// Unlike the one-shot reads above, searches are re-issued per keystroke —
    /// forward the caller's cancellation into the detached task (detachment
    /// breaks structured propagation) so a superseded scan stops at its next
    /// per-file check instead of running to completion.
    func searchSessions(query: String, workspaceURL: URL, limit: Int) async -> [AgentSessionSummary] {
        let scan = Task.detached(priority: .userInitiated) {
            ClaudeSessionStore().searchSessions(query: query, workspaceURL: workspaceURL, limit: limit)
        }
        return await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }
}

// MARK: - Turn engine (all mutable state is actor-isolated)

private actor ClaudeTurnEngine {
    /// The single in-flight turn (the `AssistantTurnGate` guarantees one at a time
    /// per session; this is the low-level current-process guard).
    private var current: Turn?
    /// Tokens cancelled BEFORE their `startTurn` ran (the consumer dropped the stream
    /// in the window between `send()` arming `onTermination` and the `startTurn` task
    /// executing). `startTurn` checks this and bails without spawning (A1).
    private var cancelledTokens: Set<UUID> = []
    /// Cached only on SUCCESS — a negative probe is never cached, so a UI refresh can
    /// re-probe after the user installs/logs in (B6).
    private var cachedAvailability: AgentAvailability?
    private let logger = RubienLogger(subsystem: "com.rubien.assistant", category: "ClaudeProvider")

    // Escalation timers (seconds). Named for single-point tuning (B5).
    /// After a `result`, close stdin and, if the child lingers on stdout, SIGTERM…
    private static let settleSoftKillDelay: Double = 3.0
    /// …then SIGKILL.
    private static let settleHardKillDelay: Double = 5.0
    /// After an explicit cancel (SIGTERM already sent), SIGKILL if not yet dead.
    private static let cancelHardKillDelay: Double = 2.0
    // The crash-notice drain grace + tail size are shared (`AgentProcessExit`).

    /// One running turn's mutable state. Reference type, only ever touched inside
    /// this actor's isolation, so it needs no synchronization of its own (the one
    /// exception, `stderr`, is its own locked box read from the drain thread).
    private final class Turn {
        let token: UUID
        let process: SpawnedAgentProcess
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        var parser = ClaudeStreamParser()
        /// requestID → the bookkeeping needed to answer a `can_use_tool`.
        var pendingApprovals: [String: ClaudeControlProtocol.PendingApproval] = [:]
        let stderr = StderrRingBuffer()
        var sawResult = false
        var cancelled = false
        var finished = false
        /// The scheduled soft/hard-kill escalation, cancelled on finalize so no late
        /// signal fires after normal completion (A3).
        var terminationTask: Task<Void, Never>?

        init(
            token: UUID, process: SpawnedAgentProcess,
            continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        ) {
            self.token = token
            self.process = process
            self.continuation = continuation
        }
    }

    // MARK: Turn lifecycle

    func startTurn(
        token: UUID,
        request: AgentTurnRequest,
        executableOverride: String?,
        mcpConfig: String?,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        // A1: the consumer may have cancelled the stream in the window before this
        // task ran. `cancelIfCurrent` recorded the token; honor it and never spawn.
        if cancelledTokens.remove(token) != nil {
            continuation.finish()
            return
        }

        // A2: one conversation per instance. A still-live prior turn means a
        // serialization violation upstream — cancel + finalize it (kill its group,
        // finish its stream) rather than silently orphaning its process.
        if let existing = current, !existing.finished {
            logger.error("startTurn entered with an unfinished turn active — finalizing the prior turn")
            abandon(existing)
        }

        guard let executable = Self.resolveExecutable(override: executableOverride) else {
            continuation.finish(throwing: AgentProviderError.executableNotFound(
                executableOverride ?? "claude"))
            return
        }

        let arguments = ClaudeCLIInvocation.arguments(for: request, mcpConfig: mcpConfig)
        let environment = ClaudeCLIInvocation.environment(
            binaryDirectory: (executable as NSString).deletingLastPathComponent)

        let process: SpawnedAgentProcess
        do {
            process = try SpawnedAgentProcess.spawn(
                executablePath: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: request.workspaceURL.path)
        } catch let error as AgentProviderError {
            continuation.finish(throwing: error)
            return
        } catch {
            continuation.finish(throwing: AgentProviderError.spawnFailed(code: -1))
            return
        }

        logger.info("claude turn spawned pid=\(process.pid) resume=\(request.resumeSessionID != nil)")

        let turn = Turn(token: token, process: process, continuation: continuation)
        current = turn
        startReaders(turn: turn)

        // The control protocol handshake, then the prompt — both on stdin, which
        // stays open (it is also the approval bus) until the result / cancel.
        process.writeLine(ClaudeControlProtocol.initializeRequest(requestID: UUID().uuidString))
        process.writeLine(ClaudeControlProtocol.userMessage(prompt: request.prompt))
    }

    /// Feed one stdout line into the turn. Stale lines (from a superseded/killed
    /// process) are dropped — the stale-process guard (§4.1).
    func ingest(token: UUID, line: String) {
        guard let turn = current, turn.token == token, !turn.finished else { return }

        // Record approval bookkeeping BEFORE emitting the event, so a caller that
        // answers immediately finds the pending entry. (Actor serialization means
        // `respond` can't interleave until we suspend/return anyway.) B2: only the
        // rare control-request lines carry the "can_use_tool" token, so skip the
        // second full JSON parse on every frequent `stream_event` delta.
        if line.contains("can_use_tool"),
           let pending = ClaudeControlProtocol.decodeCanUseTool(line: line) {
            turn.pendingApprovals[pending.requestID] = pending
        }

        for event in turn.parser.parse(line: line) {
            turn.continuation.yield(event)
            if case .turnCompleted = event { onResult(turn) }
        }
    }

    /// stdout reached EOF: reap the process group leader and finalize.
    func stdoutClosed(token: UUID) async {
        guard let turn = current, turn.token == token else { return }
        // Lazy reap (no separate reaper thread): the child closed stdout so it is
        // exiting; `wait()` returns promptly. A child that lingers on the pipe is
        // force-killed by the settle/cancel watchdog, which unblocks this. `wait()`
        // flags `hasExited` under the lock BEFORE reaping, so a late watchdog
        // `killpg` can never signal a recycled pid (A3).
        let status = await turn.process.wait()
        guard let cur = current, cur.token == token else { return }
        await finalize(cur, status: status)
    }

    // MARK: External controls

    func respond(id: String, decision: ApprovalDecision) {
        guard let turn = current, !turn.finished,
              let pending = turn.pendingApprovals[id]
        else { return }
        turn.pendingApprovals[id] = nil
        turn.process.writeLine(ClaudeControlProtocol.controlResponse(for: pending, decision: decision))
    }

    func cancelCurrent() {
        guard let turn = current else { return }
        cancel(turn)
    }

    func cancelIfCurrent(token: UUID) {
        if let turn = current, turn.token == token {
            cancel(turn)
        } else {
            // A1: the turn hasn't registered yet (cancel raced ahead of `startTurn`).
            // Record it so `startTurn` bails without spawning.
            cancelledTokens.insert(token)
        }
    }

    // MARK: Internals

    private func onResult(_ turn: Turn) {
        turn.sawResult = true
        // End the stream-json session so claude exits, then insure against a helper
        // that lingers on stdout by escalating a kill if EOF doesn't arrive.
        turn.process.closeStdin()
        scheduleTermination(
            turn, softAfter: Self.settleSoftKillDelay, hardAfter: Self.settleHardKillDelay)
    }

    private func cancel(_ turn: Turn) {
        guard !turn.finished else { return }
        turn.cancelled = true
        turn.process.closeStdin()
        turn.process.signalGroup(SIGTERM)      // whole tree (claude spawns children)
        scheduleTermination(turn, softAfter: nil, hardAfter: Self.cancelHardKillDelay)
        // stdout will EOF once the group dies → stdoutClosed → finalize.
    }

    /// A2 helper: force a still-live turn to end synchronously (used when a new turn
    /// starts while this one is unfinished). Kills the group, reaps in the background,
    /// finishes the stream.
    private func abandon(_ turn: Turn) {
        guard !turn.finished else { return }
        turn.finished = true
        turn.terminationTask?.cancel()
        turn.process.signalGroup(SIGKILL)
        turn.continuation.finish()
        cancelledTokens.remove(turn.token)
        if current?.token == turn.token { current = nil }
        // Reap so the killed leader doesn't linger as a zombie (its own reader's
        // `stdoutClosed` will early-return now that it is no longer `current`).
        let process = turn.process
        Task { _ = await process.wait() }
    }

    private func finalize(_ turn: Turn, status: Int32) async {
        guard !turn.finished else { return }
        turn.finished = true
        turn.terminationTask?.cancel()   // A3: no late kill after normal completion
        turn.process.closeStdin()

        // A process that ended WITHOUT a result and WITHOUT being cancelled failed
        // (crash / non-zero exit / auth error) → surface a clean notice (§4.5), not
        // a thrown error, so it renders as chat content.
        if !turn.cancelled && !turn.sawResult {
            // A5: the shared crash notice waits briefly for stderr's final (error)
            // bytes so the message carries the real error, then composes it.
            turn.continuation.yield(.providerNotice(
                await AgentProcessExit.crashNotice(waitStatus: status, stderr: turn.stderr)))
        }

        turn.continuation.finish()
        cancelledTokens.remove(turn.token)   // A1: prune so the set can't grow unbounded
        if current?.token == turn.token { current = nil }
    }

    /// Independent stdout (line → event) and stderr (bounded ring buffer) drains, so
    /// a full stderr pipe can never deadlock stdout parsing (§4.1).
    private func startReaders(turn: Turn) {
        let token = turn.token
        let process = turn.process

        Task { [weak self] in
            do {
                for try await line in process.stdoutHandle.bytes.lines {
                    await self?.ingest(token: token, line: line)
                }
            } catch {
                // A read error is just an early EOF for our purposes.
            }
            await self?.stdoutClosed(token: token)
        }

        // stderr on a background thread doing bounded blocking reads (NOT per-byte
        // actor hops — a flood must stay cheap).
        let ring = turn.stderr
        let handle = process.stderrHandle
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                ring.append(chunk)
            }
            ring.finish()   // A5: signal EOF so the failure path can read the final bytes
        }
    }

    private func scheduleTermination(_ turn: Turn, softAfter: Double?, hardAfter: Double) {
        let token = turn.token
        turn.terminationTask?.cancel()
        turn.terminationTask = Task { [weak self] in
            if let softAfter {
                try? await Task.sleep(nanoseconds: UInt64(softAfter * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.softKill(token: token)
            }
            try? await Task.sleep(nanoseconds: UInt64(hardAfter * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.hardKill(token: token)
        }
    }

    private func softKill(token: UUID) {
        guard let turn = current, turn.token == token, !turn.finished else { return }
        turn.process.signalGroup(SIGTERM)
    }

    private func hardKill(token: UUID) {
        guard let turn = current, turn.token == token, !turn.finished else { return }
        turn.process.signalGroup(SIGKILL)
    }

    // MARK: Availability

    func isAvailable(override: String?) async -> AgentAvailability {
        // B6: only a SUCCESS is cached — a negative must be re-probed on the next UI
        // refresh so the feature can light up after the user installs / logs in.
        if let cached = cachedAvailability { return cached }
        guard let path = Self.resolveExecutable(override: override) else {
            return .notFound(
                reason: "Claude Code CLI not found. Install it or set its path in Settings → Assistant.")
        }
        let environment = ClaudeCLIInvocation.environment(
            binaryDirectory: (path as NSString).deletingLastPathComponent)
        guard let version = await AgentBinaryProbe.probeVersion(
            executablePath: path, environment: environment)
        else {
            return .notFound(reason: "Found claude at \(path) but it did not respond to --version.")
        }
        let availability = AgentAvailability.installed(version: version, path: path)
        cachedAvailability = availability
        return availability
    }

    /// Well-known claude install dirs; resolution control flow is shared (§5.5).
    static func resolveExecutable(override: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentBinaryProbe.resolveExecutable(
            override: override,
            candidates: [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.npm-global/bin/claude",
            ],
            binaryName: "claude")
    }
}

// MARK: - CLI invocation (pure argv + env construction; unit-tested)

/// The exact `claude` argv and the minimal allowlisted child environment (D3/§4.1).
/// Extracted from the engine so it can be verified without spawning anything.
enum ClaudeCLIInvocation {

    /// The per-turn argv (D3/§4.2). `mcpConfig`, when present, is the inline
    /// `--mcp-config` JSON for the read-only content channel (Phase 2b).
    static func arguments(for request: AgentTurnRequest, mcpConfig: String? = nil) -> [String] {
        var args = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            // Config isolation (mandatory, D6): drops ambient settings/MCP/plugins
            // while subscription auth survives. The value is an empty string.
            "--setting-sources", "",
        ]
        if let resume = request.resumeSessionID, !resume.isEmpty {
            args += ["--resume", resume]
        }
        if let seed = request.seed, !seed.isEmpty {
            args += ["--append-system-prompt", seed]
        }
        if let model = request.modelOverride, !model.isEmpty {
            args += ["--model", model]
        }
        // `--effort` needs the same modern CLI surface the rest of this argv already
        // requires (--permission-prompt-tool stdio / --setting-sources, verified on
        // 2.1.201) — an older CLI never ran these turns at all, so no capability
        // probe. Like --model, the value passes through raw (Settings may send
        // future levels); an invalid one fails the turn visibly via the §4.5 notice.
        if let effort = request.effortOverride, !effort.isEmpty {
            args += ["--effort", effort]
        }
        if !request.webAccess {
            // Bash `curl` still prompts (control protocol), so this is not a silent
            // bypass (D6).
            args += ["--disallowedTools", "WebFetch WebSearch"]
        }
        // The read-only MCP content channel (Phase 2b): an inline `--mcp-config`
        // naming the bundled `rubien-cli mcp --read-only` server, plus
        // `--strict-mcp-config` so ONLY Rubien's server loads (no ambient MCP —
        // pairs with `--setting-sources ''`). Absent when the channel couldn't be
        // resolved; the turn still runs, just without document tools.
        if let mcpConfig, !mcpConfig.isEmpty {
            args += ["--mcp-config", mcpConfig, "--strict-mcp-config"]
        }
        return args
    }

    /// The shared minimal ALLOWLISTED environment (`SpawnedAgentProcess`) + Claude's
    /// entrypoint marker. `HOME` (in the shared allowlist) is required so config-dir-
    /// relative subscription auth survives `--setting-sources ''`.
    static func environment(binaryDirectory: String) -> [String: String] {
        var env = SpawnedAgentProcess.minimalEnvironment(binaryDirectory: binaryDirectory)
        env["CLAUDE_CODE_ENTRYPOINT"] = "rubien-assistant"
        return env
    }
}

#endif
