#if os(macOS)
import Foundation
import Darwin

private final class ProviderRunnerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = [Data(), Data()]
    private var truncated = false
    private var revision = 0

    struct Snapshot {
        let revision: Int
        let text: String
        let truncated: Bool
    }
    var currentRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }
    func append(_ bytes: ArraySlice<UInt8>, stream: Int) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, 512 * 1024 - buffers[stream].count)
        let retained = bytes.prefix(remaining)
        let didTruncate = bytes.count > remaining
        if !retained.isEmpty || (didTruncate && !truncated) { revision += 1 }
        buffers[stream].append(contentsOf: retained)
        truncated = truncated || didTruncate
    }
    func snapshot() -> Snapshot {
        lock.lock()
        let data = buffers
        let version = revision
        let wasTruncated = truncated
        lock.unlock()
        return Snapshot(revision: version,
            text: data.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"),
            truncated: wasTruncated)
    }
}

struct ProviderCommandResult: Sendable {
    let exitCode: Int32?
    let timedOut: Bool
    let output: String
    let truncated: Bool
}

struct ProviderMaintenanceRequest: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let directory: URL
    let timeout: TimeInterval
    var retainOutput = true
    var sanitizeOutput = true
    var inheritedLock: Int32?
    var maintenanceOwner: ProviderUsageOwner?
    var onOutput: (@Sendable (String) -> Void)?
    /// Raw chunks for streaming consumers; never published to the UI or journal.
    var stdoutConsumer: (@Sendable (Data) -> Void)?
}

/// Reads both pipes without unbounded buffers or waiting on an escaped pipe holder.
enum ProviderMaintenanceRunner {
    static func run(_ request: ProviderMaintenanceRequest) async throws -> ProviderCommandResult {
        try await run(executable: request.executable, arguments: request.arguments,
            environment: request.environment, directory: request.directory, timeout: request.timeout,
            retainOutput: request.retainOutput, sanitizeOutput: request.sanitizeOutput, inheritedLock: request.inheritedLock, maintenanceOwner: request.maintenanceOwner, onOutput: request.onOutput, stdoutConsumer: request.stdoutConsumer)
    }
    static func run(executable: String, arguments: [String], environment: [String: String],
                    directory: URL, timeout: TimeInterval, retainOutput: Bool = true, sanitizeOutput: Bool = true,
                    inheritedLock: Int32? = nil, maintenanceOwner: ProviderUsageOwner? = nil,
                    onOutput: (@Sendable (String) -> Void)? = nil,
                    stdoutConsumer: (@Sendable (Data) -> Void)? = nil) async throws -> ProviderCommandResult {
        try Task.checkCancellation()
        let process = try SpawnedAgentProcess.spawn(executablePath: executable, arguments: arguments,
                                                    environment: environment, workingDirectory: directory.path,
                                                    startsNewSession: true, inheritedLock: inheritedLock, maintenanceOwner: maintenanceOwner)
        process.closeStdin()
        let done = LockedBox(false)
        let output = ProviderRunnerOutput()
        let out = Task.detached { drain(process.stdoutHandle, done: done, output: output, stream: 0, retain: retainOutput, consumer: stdoutConsumer) }
        let err = Task.detached { drain(process.stderrHandle, done: done, output: output, stream: 1, retain: retainOutput) }
        let progress = Task { () -> (revision: Int, text: String)? in
            guard retainOutput, let onOutput else { return nil }
            var previous: (revision: Int, text: String)?
            while !Task.isCancelled {
                if output.currentRevision != (previous?.revision ?? 0) {
                    let captured = output.snapshot()
                    let safe = sanitizeOutput ? sanitize(captured.text, environment: environment) : captured.text
                    if safe != previous?.text { onOutput(safe) }
                    previous = (captured.revision, safe)
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
            return previous
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return false }
            process.signalGroup(SIGTERM)
            try? await Task.sleep(for: .seconds(1))
            process.signalGroup(SIGKILL)
            return true
        }
        let status = await withTaskCancellationHandler {
            await process.wait()
        } onCancel: {
            process.signalGroup(SIGKILL)
        }
        watchdog.cancel()
        let timedOut = await watchdog.value
        done.set(true)
        await out.value
        await err.value
        progress.cancel()
        let published = await progress.value
        process.closeOutputHandles()
        try Task.checkCancellation()
        let captured = output.snapshot()
        let safeOutput: String
        if let published, published.revision == captured.revision {
            safeOutput = published.text
        } else {
            safeOutput = sanitizeOutput ? sanitize(captured.text, environment: environment) : captured.text
        }
        if retainOutput, safeOutput != published?.text { onOutput?(safeOutput) }
        return ProviderCommandResult(exitCode: AgentProcessExit.code(fromWaitStatus: status), timedOut: timedOut,
                                     output: safeOutput, truncated: captured.truncated)
    }

    private static func drain(_ handle: FileHandle, done: LockedBox<Bool>, output: ProviderRunnerOutput, stream: Int, retain: Bool, consumer: (@Sendable (Data) -> Void)? = nil) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var finishedReads = 0
        while true {
            // Drain a bounded final tail even if an escaped child keeps writing.
            if done.get() {
                finishedReads += 1
                if finishedReads > 128 { break }
            }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                consumer?(Data(buffer.prefix(n)))
                if retain {
                    output.append(buffer.prefix(n), stream: stream)
                }
                continue
            }
            if n == 0 { break }
            if errno == EINTR { continue }
            if errno != EAGAIN && errno != EWOULDBLOCK { break }
            if done.get() { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = Darwin.poll(&p, 1, 50)
        }
    }

    static func sanitize(_ text: String, environment: [String: String] = [:]) -> String {
        var result = text
        for (key, value) in environment where key.lowercased().contains("proxy") && !value.isEmpty {
            result = result.replacingOccurrences(of: value, with: "[proxy configuration]")
        }
        for pattern in [#"\x1B\[[0-?]*[ -/]*[@-~]"#, #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"https?://[^\s<>]+"#, with: "[URL]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)(bearer\s+\S+|(?:token|password|secret|api[_-]?key|code)\s*[:=]\s*\S+|sk-[a-zA-Z0-9_-]+)"#,
                                            with: "[redacted]", options: .regularExpression)
        return String(String.UnicodeScalarView(result.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }))
    }
}
#endif
