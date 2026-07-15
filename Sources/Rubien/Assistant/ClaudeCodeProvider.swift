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
// The full native MCP library channel is wired per turn through
// `--mcp-config`/`--strict-mcp-config`; availability still probes only the
// provider binary, while channel resolvability is handled by `MCPContentChannel`.

final class ClaudeCodeProvider: AgentProvider {
    let kind: AgentProviderKind = .claude

    private let engine: ClaudeTurnEngine
    /// An explicit binary path that wins over discovery. Injected by tests (the fake
    /// CLI) and, in production, by the Settings "binary path" override (a later
    /// phase wires `RubienPreferences` here).
    private let executableOverride: String?
    /// The native MCP library channel — the bundled `rubien-cli mcp` server pointed
    /// at the app's library, attached via `--mcp-config`. nil ⇒ the
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
    /// A scoped listing (`referenceID` set) scans file bodies for attribution.
    func recentSessions(workspaceURL: URL, limit: Int, referenceID: Int64?) async -> [AgentSessionSummary] {
        await storeRead {
            ClaudeSessionStore().recentSessions(
                workspaceURL: workspaceURL, limit: limit, referenceID: referenceID)
        }
    }

    /// A picked session's full transcript (resume restores the conversation's
    /// content).
    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage] {
        await storeRead {
            ClaudeSessionStore().fullTranscript(sessionID: sessionID, workspaceURL: workspaceURL)
        }
    }

    /// Content search over the store's sessions (History picker's search field).
    func searchSessions(query: String, workspaceURL: URL, limit: Int, referenceID: Int64?) async -> [AgentSessionSummary] {
        await storeRead {
            ClaudeSessionStore().searchSessions(
                query: query, workspaceURL: workspaceURL, limit: limit, referenceID: referenceID)
        }
    }

    /// Run one blocking session-store read off the main actor. The closure's value
    /// parameters are its only captures (the store + FileManager are created inside
    /// the detached task). Detachment breaks structured cancellation, so the
    /// caller's cancellation is forwarded explicitly — a superseded scan (search
    /// keystroke, History scope flip) stops at its next per-file check instead of
    /// running to completion.
    private func storeRead<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let scan = Task.detached(priority: .userInitiated, operation: body)
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
    /// Only the binary path + --version is cached (expensive to resolve). Auth is NOT
    /// cached — it's re-probed on every isAvailable() so a mid-session sign-out / token
    /// expiry is reflected instead of Recheck being a no-op (#11); a not-found stays
    /// uncached so installing / logging in later still lights up (B6).
    private var cachedResolution: (path: String, version: String)?
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

        let images: [ClaudeImageInput]
        switch Self.imageInputs(from: request.attachments) {
        case .success(let inputs):
            images = inputs
        case .failure(let error):
            continuation.finish(throwing: error)
            return
        }
        let userMessage = ClaudeControlProtocol.userMessage(
            prompt: request.prompt, images: images)

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
        process.writeLine(userMessage)
    }

    /// Materialize all native image blocks before any process is spawned or stdin
    /// bytes are written. Text attachments remain path-backed in Rubien's manifest.
    private static func imageInputs(
        from attachments: [ChatAttachment]
    ) -> Result<[ClaudeImageInput], AgentProviderError> {
        var inputs: [ClaudeImageInput] = []
        for attachment in attachments where attachment.kind == .image {
            guard attachment.mediaType == "image/png" || attachment.mediaType == "image/jpeg",
                  let data = try? Data(contentsOf: attachment.stagedURL)
            else {
                return .failure(.attachmentUnreadable(attachment.displayName))
            }
            inputs.append(ClaudeImageInput(
                mediaType: attachment.mediaType,
                base64Data: data.base64EncodedString()))
        }
        return .success(inputs)
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
            environment = ClaudeCLIInvocation.environment(
                binaryDirectory: (path as NSString).deletingLastPathComponent)
        } else {
            guard let resolved = Self.resolveExecutable(override: override) else {
                return .notFound(
                    reason: "Claude Code CLI wasn’t found. Install Claude Code or set the binary path in Settings → Assistant, then recheck.")
            }
            environment = ClaudeCLIInvocation.environment(
                binaryDirectory: (resolved as NSString).deletingLastPathComponent)
            guard let probedVersion = await AgentBinaryProbe.probeVersion(
                executablePath: resolved, environment: environment)
            else {
                return .notFound(reason: "Found claude at \(resolved) but it did not respond to --version.")
            }
            cachedResolution = (path: resolved, version: probedVersion)
            path = resolved
            version = probedVersion
        }
        if await AgentAuthProbe.probeClaude(executablePath: path, environment: environment) == .unauthenticated {
            return .installedButUnauthenticated(
                version: version,
                path: path,
                reason: "Claude Code is installed but not signed in. Run claude auth login in Terminal, then recheck.")
        }
        return .installed(version: version, path: path)
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
    /// `--mcp-config` JSON for the native Rubien library channel.
    static func arguments(for request: AgentTurnRequest, mcpConfig: String? = nil) -> [String] {
        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
        ]
        if !request.loadUserTools {
            // Default isolation (D6): drops ambient settings/MCP/plugins while
            // subscription auth survives. Opted-in conversations omit this flag so
            // Claude loads its normal user/project/local configuration.
            args += ["--setting-sources", ""]
        }
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
        // The native MCP library channel: an inline `--mcp-config` naming the
        // bundled full `rubien-cli mcp` server. In the default posture,
        // `--strict-mcp-config` means ONLY Rubien loads (and
        // pairs with `--setting-sources ''`). The explicit user-tools opt-in keeps
        // Rubien's config but omits strict mode, merging the user's normal MCP and
        // plugin environment. Absent when the channel couldn't be resolved; the turn
        // still runs, just without Rubien document tools.
        if let mcpConfig, !mcpConfig.isEmpty {
            args += ["--mcp-config", mcpConfig]
            if !request.loadUserTools {
                args.append("--strict-mcp-config")
            }
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
