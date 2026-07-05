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
    /// Bound on awaiting the stderr drain before composing a failure notice (A5).
    private static let stderrDrainGrace: Double = 0.5
    /// Trailing stderr bytes included in a failure notice.
    private static let noticeStderrTailBytes = 500

    /// One running turn's mutable state. Reference type, only ever touched inside
    /// this actor's isolation, so it needs no synchronization of its own (the one
    /// exception, `stderr`, is its own locked box read from the drain thread).
    private final class Turn {
        let token: UUID
        let process: PosixSpawnedProcess
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
            token: UUID, process: PosixSpawnedProcess,
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

        let process: PosixSpawnedProcess
        do {
            process = try PosixSpawnedProcess.spawn(
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
            // A5: the stderr drain may not have appended the final (error) bytes yet
            // — wait briefly for its EOF so the notice carries the real message.
            await turn.stderr.waitForCompletion(timeout: Self.stderrDrainGrace)
            let exit = Self.exitCode(from: status)
            let codeDesc = exit.map { "exit code \($0)" } ?? "terminated by signal"
            var message = "The assistant ended unexpectedly (\(codeDesc))."
            let tail = turn.stderr.tailString()
            if !tail.isEmpty { message += "\n\(String(tail.suffix(Self.noticeStderrTailBytes)))" }
            turn.continuation.yield(.providerNotice(message))
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

    // MARK: Reaping

    /// POSIX wait-status decode: the exit code for a normal exit, `nil` if killed by
    /// a signal. (`WIFEXITED`/`WEXITSTATUS` are C macros not imported into Swift.)
    private static func exitCode(from status: Int32) -> Int32? {
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return nil
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
        guard let version = await Self.probeVersion(executablePath: path) else {
            return .notFound(reason: "Found claude at \(path) but it did not respond to --version.")
        }
        let availability = AgentAvailability.installed(version: version, path: path)
        cachedAvailability = availability
        return availability
    }

    /// Resolution order (§5.5): explicit override → well-known install dirs →
    /// last-resort login-shell `command -v`.
    static func resolveExecutable(override: String?) -> String? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return shellResolve()
    }

    private static func shellResolve() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = runProbe(
            executablePath: shell, arguments: ["-l", "-c", "command -v claude"], timeout: 5)
        else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private static func probeVersion(executablePath: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = runProbe(
                    executablePath: executablePath, arguments: ["--version"], timeout: 5)
                continuation.resume(returning: output.flatMap(parseVersionString))
            }
        }
    }

    /// Extract a `MAJOR.MINOR.PATCH` from a `--version` line, else the first
    /// non-empty trimmed line.
    static func parseVersionString(_ raw: String) -> String? {
        if let range = raw.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
            return String(raw[range])
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Run a short, sanitized, stdin-closed probe with a HARD timeout that holds even
    /// if a login-shell grandchild keeps stdout open (A4): stdout is read on a
    /// background queue; on timeout we `terminate()` + close the read handle to
    /// unblock the read and return. stderr is discarded to `/dev/null` so it can
    /// never fill and stall the child.
    private static func runProbe(
        executablePath: String, arguments: [String], timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ClaudeCLIInvocation.environment(
            binaryDirectory: (executablePath as NSString).deletingLastPathComponent)
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let readHandle = outPipe.fileHandleForReading
        let box = LockedBox<Data>(Data())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(readHandle.readDataToEndOfFile())  // tiny output; unblocked on close
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()          // SIGTERM the direct child…
            try? readHandle.close()      // …and unblock the read even if a grandchild holds stdout
            done.wait()                  // let the reader task finish after the close
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: box.get(), as: UTF8.self)
    }
}

/// A tiny lock-guarded value box so a background reader and the caller can hand off
/// data across threads without a data race.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
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

    /// Minimal ALLOWLISTED environment — never inherit the app env (GUI apps carry
    /// `*_API_KEY`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`, cloud creds). `HOME` is required
    /// so config-dir-relative subscription auth survives `--setting-sources ''`.
    static func environment(binaryDirectory: String) -> [String: String] {
        let host = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LANG", "LC_ALL", "TMPDIR"] {
            if let value = host[key] { env[key] = value }
        }
        env["TERM"] = "dumb"
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"                    // stray ANSI must not corrupt the JSON
        env["CLAUDE_CODE_ENTRYPOINT"] = "rubien-assistant"
        let dir = binaryDirectory.isEmpty ? "/usr/local/bin" : binaryDirectory
        env["PATH"] = "\(dir):/usr/bin:/bin"
        return env
    }
}

// MARK: - Bounded stderr ring buffer (thread-safe)

/// Keeps only the tail of a turn's stderr for the error-notice path; appended from
/// the stderr drain thread, read at finalize. Lock-guarded so it is safely
/// `Sendable` across those two domains. Signals `finish()` at EOF so the failure
/// path can wait for the real (final) error bytes before composing its notice (A5).
private final class StderrRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes = 16 * 1024
    private let doneSemaphore = DispatchSemaphore(value: 0)
    private var finished = false

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        // Only pay the O(n) trim once the tail is well past the cap (nit-fix: avoids
        // a copy on every append when hovering near the boundary).
        if data.count > 2 * maxBytes { data.removeFirst(data.count - maxBytes) }
    }

    /// Called by the drain thread when stderr reaches EOF.
    func finish() {
        lock.lock()
        let wasFinished = finished
        finished = true
        lock.unlock()
        if !wasFinished { doneSemaphore.signal() }
    }

    /// Await the drain's EOF, bounded — returns early if it is slow.
    func waitForCompletion(timeout: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                _ = self.doneSemaphore.wait(timeout: .now() + timeout)
                continuation.resume()
            }
        }
    }

    func tailString() -> String {
        lock.lock(); defer { lock.unlock() }
        // B3: byte-boundary trim can leave a mid-codepoint prefix — decode
        // lossily (replacing invalid bytes) rather than dropping the ENTIRE tail.
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }
}

// MARK: - posix_spawn wrapper (own process group + cwd)

/// A child spawned via `posix_spawn` in its OWN process group so the whole tree can
/// be signalled with `killpg` (Foundation `Process.terminate()` reaches only the
/// leader). FileHandles are each accessed from a single domain (stdin: the actor,
/// stdout: the reader task, stderr: the drain thread), so `@unchecked Sendable` is
/// sound.
private final class PosixSpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    let stdinHandle: FileHandle
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle
    private var stdinClosed = false
    private let stateLock = NSLock()
    private var hasExited = false

    private init(pid: pid_t, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.pid = pid
        self.stdinHandle = stdin
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    /// Write one NDJSON line to the child's stdin (the prompt / control responses).
    /// No-op after `closeStdin`; `SIGPIPE` is globally ignored so a dead child can't
    /// crash the app on write.
    func writeLine(_ string: String) {
        guard !stdinClosed else { return }
        _ = PosixSpawnedProcess.sigpipeIgnored
        try? stdinHandle.write(contentsOf: Data((string + "\n").utf8))
    }

    /// Close stdin → the child sees EOF on the stream-json input and exits the turn.
    func closeStdin() {
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinHandle.close()
    }

    /// Reap the process-group leader. A3: wait for exit WITHOUT reaping first
    /// (`waitid` + `WNOWAIT`), then — inside the lock — flag `hasExited` and only
    /// THEN reap (`waitpid`). Because `signalGroup` checks-and-signals inside the
    /// same lock, no `killpg` can ever fire after the pid is reaped (and thus
    /// possibly recycled).
    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Block until the child has exited, but leave it reapable.
                var info = siginfo_t()
                _ = waitid(P_PID, id_t(self.pid), &info, WEXITED | WNOWAIT)
                self.stateLock.lock()
                self.hasExited = true          // set BEFORE reaping → no signal past here
                var status: Int32 = 0
                _ = waitpid(self.pid, &status, 0)  // immediate; the child already exited
                self.stateLock.unlock()
                continuation.resume(returning: status)
            }
        }
    }

    /// Signal the whole process group (leader pgid == pid, since we set pgroup 0).
    /// The check + `killpg` are one critical section, mutually exclusive with the
    /// reap in `wait()`, so a signal can never target a reaped/recycled pid (A3).
    func signalGroup(_ signal: Int32) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard pid > 0, !hasExited else { return }
        _ = killpg(pid, signal)
    }

    private static let sigpipeIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
        return ()
    }()

    static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> PosixSpawnedProcess {
        _ = sigpipeIgnored

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // cwd = the workspace folder (D4).
        workingDirectory.withCString { _ = posix_spawn_file_actions_addchdir_np(&fileActions, $0) }

        let childStdin = stdinPipe.fileHandleForReading.fileDescriptor
        let parentStdinWrite = stdinPipe.fileHandleForWriting.fileDescriptor
        let childStdout = stdoutPipe.fileHandleForWriting.fileDescriptor
        let parentStdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let childStderr = stderrPipe.fileHandleForWriting.fileDescriptor
        let parentStderrRead = stderrPipe.fileHandleForReading.fileDescriptor

        posix_spawn_file_actions_adddup2(&fileActions, childStdin, 0)
        posix_spawn_file_actions_adddup2(&fileActions, childStdout, 1)
        posix_spawn_file_actions_adddup2(&fileActions, childStderr, 2)
        // Close the duplicated originals and the parent ends inside the child.
        posix_spawn_file_actions_addclose(&fileActions, childStdin)
        posix_spawn_file_actions_addclose(&fileActions, childStdout)
        posix_spawn_file_actions_addclose(&fileActions, childStderr)
        posix_spawn_file_actions_addclose(&fileActions, parentStdinWrite)
        posix_spawn_file_actions_addclose(&fileActions, parentStdoutRead)
        posix_spawn_file_actions_addclose(&fileActions, parentStderrRead)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)   // new group, pgid == child pid

        let argv = [executablePath] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let spawnResult: Int32 = executablePath.withCString { pathPtr in
            withCStringArray(argv) { argvPtr in
                withCStringArray(envp) { envpPtr in
                    posix_spawn(&pid, pathPtr, &fileActions, &attributes, argvPtr, envpPtr)
                }
            }
        }
        guard spawnResult == 0 else {
            throw AgentProviderError.spawnFailed(code: spawnResult)
        }

        // Parent: close the child ends so EOF propagates when the child exits.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        return PosixSpawnedProcess(
            pid: pid,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading)
    }
}

/// Build a NULL-terminated C string array for `posix_spawn` argv/envp, freeing every
/// `strdup` after `body` returns.
private func withCStringArray<Result>(
    _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    cStrings.append(nil)
    defer { for pointer in cStrings where pointer != nil { free(pointer) } }
    return cStrings.withUnsafeBufferPointer { body($0.baseAddress!) }
}
#endif
