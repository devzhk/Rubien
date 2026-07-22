#if os(macOS)
import Darwin
import Foundation

// MARK: - Shared agent subprocess (posix_spawn, own process group + cwd)
//
// The one process wrapper both providers spawn through (extracted from
// `ClaudeCodeProvider` in Phase 3b-2 so `CodexProvider`'s long-lived app-server
// reuses the identical mechanics instead of copying them):
//
//   • Claude: one process PER TURN (spawn → stream → exit).
//   • Codex: one LONG-LIVED `codex app-server` shared by Home, readers, History,
//     and scheduled work.
//
// Either way the child runs in its OWN process group so the whole tree can be
// signalled with `killpg` (Foundation `Process.terminate()` reaches only the
// leader — §4.1 process mechanics).

/// A child spawned via `posix_spawn` in its OWN process group. FileHandles are each
/// accessed from a single domain (stdin: its serial writer queue, stdout: the reader
/// task, stderr: the drain thread); lifecycle flags are lock-guarded, so
/// `@unchecked Sendable` is sound.
final class SpawnedAgentProcess: @unchecked Sendable {
    let pid: pid_t
    let stdinHandle: FileHandle
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle
    private var stdinClosed = false
    private var normalWriteAbortedPartially = false
    private let stdinQueue = DispatchQueue(label: "com.rubien.agent-process.stdin")
    private let stateLock = NSLock()
    private var hasReaped = false
    private var reapedStatus: Int32?

    private init(pid: pid_t, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.pid = pid
        self.stdinHandle = stdin
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    /// The minimal ALLOWLISTED child environment shared by every provider (§4.1) —
    /// never inherit the app env (GUI apps carry `*_API_KEY`, `GITHUB_TOKEN`,
    /// `SSH_AUTH_SOCK`, cloud creds). `HOME` is required so config-dir-relative
    /// auth (`~/.claude`, `~/.codex`) resolves. Provider-specific additions (e.g.
    /// `CLAUDE_CODE_ENTRYPOINT`) layer on top of this.
    static func minimalEnvironment(binaryDirectory: String) -> [String: String] {
        let host = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LANG", "LC_ALL", "TMPDIR"] {
            if let value = host[key] { env[key] = value }
        }
        env["TERM"] = "dumb"
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"                    // stray ANSI must not corrupt the JSON
        // The binary's own dir first, then the standard interpreter/tool locations.
        // Codex is a Node CLI (`#!/usr/bin/env node`), so `node` MUST be resolvable —
        // when codex is npm-global but node came from the nodejs.org installer
        // (/usr/local/bin) or Homebrew (/opt/homebrew/bin), it lives in a different dir
        // than codex, and a bare `<dir>:/usr/bin:/bin` fails to launch codex at all.
        // (An nvm install keeps node + codex in the same dir, covered by `<dir>`.)
        // Harmless for Claude's self-contained native binary.
        let dir = binaryDirectory.isEmpty ? "/usr/local/bin" : binaryDirectory
        let standard = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
        env["PATH"] = ([dir] + standard.filter { $0 != dir }).joined(separator: ":")
        return env
    }

    /// Write one NDJSON line to the child's stdin (prompts / control or JSON-RPC
    /// messages). No-op after `closeStdin`; `SIGPIPE` is globally ignored so a dead
    /// child can't crash the app on write.
    func writeLine(_ string: String) {
        _ = SpawnedAgentProcess.sigpipeIgnored
        let payload = Data((string + "\n").utf8)
        stateLock.lock()
        guard !stdinClosed else {
            stateLock.unlock()
            return
        }
        let descriptor = stdinHandle.fileDescriptor
        stdinQueue.async { [self] in
            writeNormal(payload, to: descriptor)
        }
        stateLock.unlock()
    }

    /// Close stdin → the child sees EOF on its input stream.
    func closeStdin() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinHandle.close()
    }

    /// Atomically take a close-on-exec duplicate of stdin for one final bounded
    /// control write, then close the ordinary writer. `F_DUPFD_CLOEXEC` is
    /// load-bearing: a plain `dup()` can leak this old turn's pipe into another
    /// provider's concurrent `posix_spawn` before a separate CLOEXEC update.
    func writeFinalLine(_ string: String, timeout: TimeInterval = 0.25) {
        stateLock.lock()
        guard !stdinClosed else {
            stateLock.unlock()
            return
        }
        let duplicate = Self.duplicateCloseOnExec(stdinHandle.fileDescriptor)
        stdinClosed = true
        try? stdinHandle.close()
        stateLock.unlock()
        guard duplicate >= 0 else { return }

        guard Self.setNonblocking(duplicate) else {
            _ = Darwin.close(duplicate)
            return
        }
        let payload = Data((string + "\n").utf8)
        stdinQueue.async { [self] in
            defer { _ = Darwin.close(duplicate) }
            stateLock.lock()
            let canWrite = !normalWriteAbortedPartially
            stateLock.unlock()
            guard canWrite else { return }
            let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            let started = DispatchTime.now().uptimeNanoseconds
            let deadline = started.addingReportingOverflow(timeoutNanoseconds)
            let deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue
            payload.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count,
                      DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds {
                    let count = Darwin.write(
                        duplicate, base.advanced(by: offset), rawBuffer.count - offset)
                    if count > 0 {
                        offset += count
                        continue
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return }
                    var writable = pollfd(fd: duplicate, events: Int16(POLLOUT), revents: 0)
                    let now = DispatchTime.now().uptimeNanoseconds
                    let remainingMilliseconds = now < deadlineNanoseconds
                        ? (deadlineNanoseconds - now) / 1_000_000 : 0
                    var pollResult: Int32
                    repeat {
                        pollResult = Darwin.poll(
                            &writable, 1, Int32(min(remainingMilliseconds, 50)))
                    } while pollResult < 0 && errno == EINTR
                }
            }
        }
    }

    /// Drain an ordinary queued message without ever blocking the provider actor.
    /// A final close makes the nonblocking write/poll loop notice `stdinClosed` and
    /// yield the serial queue to the final interrupt. If cancellation caught a
    /// partially written NDJSON line, the final writer deliberately sends nothing
    /// (appending JSON would only corrupt the stream); signal fallback still runs.
    private func writeNormal(_ payload: Data, to descriptor: Int32) {
        payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                stateLock.lock()
                if stdinClosed {
                    if offset > 0 { normalWriteAbortedPartially = true }
                    stateLock.unlock()
                    return
                }
                let count = Darwin.write(
                    descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                stateLock.unlock()
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&writable, 1, 50)
                    continue
                }
                stateLock.lock()
                if offset > 0 { normalWriteAbortedPartially = true }
                stateLock.unlock()
                return
            }
        }
    }

    private static func duplicateCloseOnExec(_ descriptor: Int32) -> Int32 {
        var duplicate: Int32
        repeat {
            duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        } while duplicate < 0 && errno == EINTR
        return duplicate
    }

    private static func setNonblocking(_ descriptor: Int32) -> Bool {
        var flags: Int32
        repeat {
            flags = fcntl(descriptor, F_GETFL)
        } while flags < 0 && errno == EINTR
        guard flags >= 0 else { return false }

        var result: Int32
        repeat {
            result = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        } while result < 0 && errno == EINTR
        return result == 0
    }

    /// Close the parent-side output readers when a provider must finish without
    /// waiting for EOF (for example, a detached helper inherited the write ends).
    /// Active readers then terminate with EOF or a caught read error instead of
    /// retaining tasks, threads, and descriptors for the helper's lifetime.
    func closeOutputHandles() {
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    /// Observe leader exit without reaping it. Keeping the exited leader reserved
    /// prevents PID reuse while the provider classifies normal vs retiring cleanup
    /// and signals any residual children in the still-stable process group.
    func observeExit() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var info = siginfo_t()
                var result: Int32
                repeat {
                    result = waitid(P_PID, id_t(self.pid), &info, WEXITED | WNOWAIT)
                } while result != 0 && errno == EINTR
                continuation.resume(returning: result == 0)
            }
        }
    }

    /// Reap exactly once. Call after `observeExit()` when residual group signalling
    /// is complete. The reaped flag is published under the same lock used by
    /// `signalGroup`, before `waitpid`, so no signal can target a recycled pid.
    func reap() async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.stateLock.lock()
                if let status = self.reapedStatus {
                    self.stateLock.unlock()
                    continuation.resume(returning: status)
                    return
                }
                var status: Int32 = 0
                var result: pid_t
                repeat {
                    result = waitpid(self.pid, &status, 0)
                } while result < 0 && errno == EINTR
                guard result == self.pid else {
                    self.stateLock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                self.hasReaped = true
                self.reapedStatus = status
                self.stateLock.unlock()
                continuation.resume(returning: status)
            }
        }
    }

    /// Compatibility helper for the Codex app-server path.
    func wait() async -> Int32 {
        if let status = cachedReapedStatus() { return status }
        guard await observeExit() else {
            return cachedReapedStatus() ?? -1
        }
        return await reap() ?? -1
    }

    private func cachedReapedStatus() -> Int32? {
        stateLock.lock(); defer { stateLock.unlock() }
        return reapedStatus
    }

    /// Reap within a bounded interval, polling with `WNOHANG` so a child whose
    /// process state is unexpectedly wedged cannot pin a provider actor forever.
    /// A timed-out or cancelled wait leaves one background reaper responsible for
    /// eventually collecting the child.
    func wait(timeout: TimeInterval) async -> Int32? {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            if let status = pollReapedStatus() { return status }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                break
            }
        } while true

        Task { _ = await self.wait() }
        return nil
    }

    /// Nonblocking exit-status probe. Providers use this immediately after stdout
    /// EOF to preserve a natural crash code before escalating a process that closed
    /// its pipe without actually exiting.
    func pollReapedStatus() -> Int32? {
        stateLock.lock(); defer { stateLock.unlock() }
        if let reapedStatus { return reapedStatus }

        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        guard result == pid else { return nil }
        hasReaped = true
        reapedStatus = status
        return status
    }

    /// Signal the whole process group (leader pgid == pid, since we set pgroup 0).
    /// The check + `killpg` are one critical section, mutually exclusive with the
    /// reap in `wait()`, so a signal can never target a reaped/recycled pid (A3).
    func signalGroup(_ signal: Int32) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard pid > 0, !hasReaped else { return }
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
    ) throws -> SpawnedAgentProcess {
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

        guard setNonblocking(parentStdinWrite) else {
            throw AgentProviderError.spawnFailed(code: errno)
        }

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

        return SpawnedAgentProcess(
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

// MARK: - Bounded stderr ring buffer (thread-safe, shared)

/// Keeps only the tail of a child's stderr for the error-notice path; appended from
/// the stderr drain thread, read at finalize. Lock-guarded so it is safely
/// `Sendable` across those two domains. Signals `finish()` at EOF so the failure
/// path can wait for the real (final) error bytes before composing its notice (A5).
final class StderrRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes = 16 * 1024
    private let doneSemaphore = DispatchSemaphore(value: 0)
    private var finished = false

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        // Only pay the O(n) trim once the tail is well past the cap (avoids a copy on
        // every append when hovering near the boundary).
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

// MARK: - Shared crash-notice composition

/// The "assistant ended unexpectedly" notice both providers surface when their child
/// dies without a clean result (§4.5). Extracted so the wording, the POSIX exit
/// decode, and the stderr-tail size stay identical across providers.
enum AgentProcessExit {
    static let stderrDrainGrace: TimeInterval = 0.5
    static let noticeTailBytes = 500

    /// The exit code for a normal exit, `nil` if terminated by a signal.
    /// (`WIFEXITED`/`WEXITSTATUS` are C macros not imported into Swift.)
    static func code(fromWaitStatus status: Int32) -> Int32? {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
    }

    /// Compose the crash notice: wait briefly for stderr's final (error) bytes (A5),
    /// then exit-code + a trailing stderr excerpt.
    static func crashNotice(waitStatus status: Int32, stderr: StderrRingBuffer) async -> String {
        await stderr.waitForCompletion(timeout: stderrDrainGrace)
        let codeDescription = code(fromWaitStatus: status).map { "exit code \($0)" } ?? "terminated by signal"
        var message = "The assistant ended unexpectedly (\(codeDescription))."
        let tail = stderr.tailString()
        if !tail.isEmpty { message += "\n\(String(tail.suffix(noticeTailBytes)))" }
        return message
    }
}

// MARK: - Binary probe (shared availability machinery)

/// Short, sanitized, stdin-closed probes for locating agent binaries and reading
/// their `--version` — shared by both providers' `isAvailable()` paths.
enum AgentBinaryProbe {
    struct CommandResult: Sendable, Equatable {
        let stdout: String
        let stderr: String
        let exitCode: Int32?
        let timedOut: Bool

        var combinedOutput: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
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

    /// Resolution order (§5.5): explicit override → well-known install dirs →
    /// last-resort login-shell `command -v <binaryName>`. Each provider supplies its
    /// own `candidates` + `binaryName`; the control flow is shared.
    static func resolveExecutable(override: String?, candidates: [String], binaryName: String) -> String? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return shellResolve(binaryName: binaryName)
    }

    /// Probe `--version` in its own process group, bounded and fully reaped before
    /// returning. Codex opts into one retry because npm's wrapper can lose its first
    /// cold start while another app-server is initializing; cleanup completes before
    /// the retry, so the retry never overlaps the failed tree.
    static func probeVersion(
        executablePath: String,
        environment: [String: String],
        retryOnce: Bool = false
    ) async -> String? {
        let attempts = retryOnce ? 2 : 1
        for attempt in 0..<attempts {
            if let result = await runSpawnedCommand(
                executablePath: executablePath,
                arguments: ["--version"],
                environment: environment,
                timeout: 5),
               result.exitCode == 0,
               !result.timedOut,
               let version = parseVersionString(result.stdout) {
                return version
            }
            if attempt + 1 < attempts {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        return nil
    }

    private static func runSpawnedCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> CommandResult? {
        let process: SpawnedAgentProcess
        do {
            process = try SpawnedAgentProcess.spawn(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                workingDirectory: FileManager.default.temporaryDirectory.path)
        } catch {
            return nil
        }
        process.closeStdin()
        let stdoutTask = Task.detached(priority: .userInitiated) {
            process.stdoutHandle.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .utility) {
            process.stderrHandle.readDataToEndOfFile()
        }
        let watchdog = Task<Bool, Never> {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return false
            }
            process.signalGroup(SIGKILL)
            return true
        }
        let waitStatus = await process.wait()
        watchdog.cancel()
        let timedOut = await watchdog.value
        return CommandResult(
            stdout: String(decoding: await stdoutTask.value, as: UTF8.self),
            stderr: String(decoding: await stderrTask.value, as: UTF8.self),
            exitCode: AgentProcessExit.code(fromWaitStatus: waitStatus),
            timedOut: timedOut)
    }

    /// Last-resort discovery: ask the user's login shell where `binaryName` lives
    /// (login shells run startup scripts, so this is bounded + sanitized).
    static func shellResolve(binaryName: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = run(
            executablePath: shell,
            arguments: ["-l", "-c", "command -v \(binaryName)"],
            environment: SpawnedAgentProcess.minimalEnvironment(binaryDirectory: ""),
            timeout: 5)
        else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Run a short probe with a HARD timeout that holds even if a login-shell
    /// grandchild keeps stdout open (A4): stdout is read on a background queue; on
    /// timeout we `terminate()` + close the read handle to unblock the read and
    /// return. stderr is discarded to `/dev/null` so it can never fill and stall
    /// the child.
    static func run(
        executablePath: String, arguments: [String],
        environment: [String: String], timeout: TimeInterval,
        workingDirectory: String? = nil
    ) -> String? {
        guard let result = runCommand(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            captureStderr: false,
            workingDirectory: workingDirectory),
              result.exitCode == 0,
              !result.timedOut
        else { return nil }
        return result.stdout
    }

    /// Run a short probe and return stdout/stderr even for nonzero exits. Auth
    /// status probes use nonzero as a meaningful "signed out" signal, unlike
    /// `--version` where only exit 0 is usable.
    static func runCommand(
        executablePath: String, arguments: [String],
        environment: [String: String], timeout: TimeInterval,
        captureStderr: Bool = true,
        workingDirectory: String? = nil
    ) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Only pipe stderr when the caller needs it (auth probes read it). Otherwise send
        // it to /dev/null: a login-shell grandchild that inherits ONLY stderr would else
        // hold that pipe open and force the timeout, making run() discard a perfectly good
        // stdout path — the bug that broke version discovery on some setups (A4/#3).
        let errPipe: Pipe? = captureStderr ? Pipe() : nil
        process.standardError = errPipe ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let stdoutHandle = outPipe.fileHandleForReading
        let stderrHandle = errPipe?.fileHandleForReading
        let stdoutBox = LockedBox<Data>(Data())
        let stderrBox = LockedBox<Data>(Data())
        let done = DispatchGroup()
        var readers: [(FileHandle, LockedBox<Data>)] = [(stdoutHandle, stdoutBox)]
        if let stderrHandle { readers.append((stderrHandle, stderrBox)) }
        for (handle, box) in readers {
            done.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.set(handle.readDataToEndOfFile())  // tiny output; unblocked on close
                done.leave()
            }
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()          // SIGTERM the direct child…
            try? stdoutHandle.close()    // …and unblock reads even if a grandchild holds pipes
            try? stderrHandle?.close()
            done.wait()                  // let the reader tasks finish after the close
            return CommandResult(
                stdout: String(decoding: stdoutBox.get(), as: UTF8.self),
                stderr: String(decoding: stderrBox.get(), as: UTF8.self),
                exitCode: nil,
                timedOut: true)
        }
        process.waitUntilExit()
        return CommandResult(
            stdout: String(decoding: stdoutBox.get(), as: UTF8.self),
            stderr: String(decoding: stderrBox.get(), as: UTF8.self),
            exitCode: process.terminationStatus,
            timedOut: false)
    }
}

enum AgentAuthStatus: Equatable {
    case authenticated
    case unauthenticated
    case unknown
}

enum AgentAuthProbe {
    static func claudeStatus(from result: AgentBinaryProbe.CommandResult) -> AgentAuthStatus {
        guard !result.timedOut else { return .unknown }
        if let data = result.stdout.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let loggedIn = object["loggedIn"] as? Bool {
            return loggedIn ? .authenticated : .unauthenticated
        }
        let output = result.combinedOutput.lowercased()
        if output.contains("not logged in") || output.contains("not signed in") {
            return .unauthenticated
        }
        return .unknown
    }

    static func codexStatus(from result: AgentBinaryProbe.CommandResult) -> AgentAuthStatus {
        guard !result.timedOut else { return .unknown }
        let output = result.combinedOutput.lowercased()
        // Negatives are checked FIRST and the ordering is load-bearing: "not logged in"
        // CONTAINS "logged in", so a positive-first check would misread a signed-out CLI
        // as authenticated. Anything neither clearly negative nor a clean exit-0 "logged
        // in" stays .unknown — fail open (treated ready), never a false sign-out block.
        if output.contains("not logged in")
            || output.contains("not signed in")
            || output.contains("not authenticated") {
            return .unauthenticated
        }
        if result.exitCode == 0, output.contains("logged in") {
            return .authenticated
        }
        return .unknown
    }

    static func probeClaude(executablePath: String, environment: [String: String]) async -> AgentAuthStatus {
        await probe(
            executablePath: executablePath,
            arguments: ["auth", "status", "--json"],
            environment: environment,
            parser: { AgentAuthProbe.claudeStatus(from: $0) })
    }

    static func probeCodex(executablePath: String, environment: [String: String]) async -> AgentAuthStatus {
        await probe(
            executablePath: executablePath,
            arguments: ["login", "status"],
            environment: environment,
            parser: { AgentAuthProbe.codexStatus(from: $0) })
    }

    private static func probe(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        parser: @escaping @Sendable (AgentBinaryProbe.CommandResult) -> AgentAuthStatus
    ) async -> AgentAuthStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let result = AgentBinaryProbe.runCommand(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment,
                    timeout: 5)
                else {
                    continuation.resume(returning: .unknown)
                    return
                }
                continuation.resume(returning: parser(result))
            }
        }
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
#endif
