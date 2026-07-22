#if os(macOS)
import Darwin
import Foundation
import RubienCore

// MARK: - Codex model catalog (model/list auto-discovery)
//
// Fetches the installed codex's OWN model list (`model/list`, verified back to codex
// 0.142.5 — spec §2.1) and memoizes it per resolved binary path. Production routes
// through the same app-server connection as Home/readers/scheduled work; isolated
// catalog instances retain the short-lived probe for deterministic tests. The catalog
// feeds PICKERS ONLY: no turn ever waits on it (spec §4.1).
//
// Correctness internals (spec review finding #9): concurrent callers join one
// in-flight Task per path; a generation token invalidates on forceReload / path
// change so a stale completion cannot repopulate an invalidated entry.

actor CodexModelCatalog {
    /// Production singleton — Settings and every reader window share one result
    /// and route discovery through the process-wide Rubien Codex connection.
    static let shared = CodexModelCatalog(usesSharedRuntime: true)

    private let workingDirectory: URL
    private let fetchTimeout: Double
    private let usesSharedRuntime: Bool
    /// `static` (not an instance property) so the free-standing `fetch` probe —
    /// deliberately non-isolated from the actor so a slow probe never blocks other
    /// paths' lookups — can log without threading the logger through as a parameter.
    private static let logger = RubienLogger(subsystem: "com.rubien.assistant", category: "CodexModelCatalog")

    private var cache: [String: CodexCatalog] = [:]
    private struct InflightFetch {
        let token: UUID
        let generation: Int
        let task: Task<CodexCatalog, Never>
    }
    private var inflight: [String: InflightFetch] = [:]
    /// Per-PATH invalidation tokens (spec §4.1): `forceReload` bumps a path's
    /// token so a fetch that started before the bump can't repopulate the entry
    /// it invalidated. Per-path, not global — reloading one binary must not
    /// invalidate another's in-flight fetch (plan-review #2).
    private var generation: [String: Int] = [:]

    /// Bound on the app-server phase (spawn → handshake → model/list), after
    /// the separately bounded five-second MCP-isolation preflight. Local IPC answers
    /// in well under a second; a wedged binary must not hold a picker open forever.
    init(
        workingDirectory: URL = FileManager.default.temporaryDirectory,
        fetchTimeout: Double = 10,
        usesSharedRuntime: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.fetchTimeout = fetchTimeout
        self.usesSharedRuntime = usesSharedRuntime
    }

    /// The catalog for the codex the override resolves to. Memoized; `forceReload`
    /// (Settings ▸ Recheck) drops the memo and refetches. Failure of any kind —
    /// unresolvable binary, spawn error, JSON-RPC error (a codex too old for
    /// `model/list`), timeout — returns `.unavailable`; callers degrade per §4.7.
    func catalog(executableOverride: String?, forceReload: Bool = false) async -> CodexCatalog {
        guard let path = CodexProvider.resolveExecutable(override: executableOverride) else {
            Self.logger.error("codex model/list probe failed: could not resolve a codex binary")
            return .unavailable
        }
        if forceReload {
            cache[path] = nil
            generation[path, default: 0] += 1
            let previous = inflight[path]
            previous?.task.cancel()

            // Publish the replacement before awaiting the superseded probe. Existing
            // callers that were awaiting `previous` can then follow this task instead
            // of briefly receiving its cancellation result as "catalog unavailable".
            // The replacement itself waits for the canceled process to finish its
            // bounded kill/reap cleanup, so app-server probes still never overlap.
            let gen = generation[path, default: 0]
            let directory = workingDirectory
            let timeout = fetchTimeout
            let usesSharedRuntime = usesSharedRuntime
            let replacement = InflightFetch(
                token: UUID(),
                generation: gen,
                task: Task {
                    if let previous { _ = await previous.task.value }
                    guard !Task.isCancelled else { return .unavailable }
                    return await Self.fetch(
                        executablePath: path, workingDirectory: directory,
                        timeout: timeout, usesSharedRuntime: usesSharedRuntime)
                })
            inflight[path] = replacement
            return await finish(replacement, for: path)
        }
        if let cached = cache[path] { return cached }
        if let running = inflight[path] {
            return await finish(running, for: path)
        }

        let gen = generation[path, default: 0]
        let directory = workingDirectory
        let timeout = fetchTimeout
        let usesSharedRuntime = usesSharedRuntime
        let fetch = InflightFetch(
            token: UUID(),
            generation: gen,
            task: Task {
                await Self.fetch(
                    executablePath: path, workingDirectory: directory,
                    timeout: timeout, usesSharedRuntime: usesSharedRuntime)
            })
        inflight[path] = fetch
        return await finish(fetch, for: path)
    }

    /// Complete one generation. If a force reload superseded it while the actor was
    /// suspended, follow the replacement task already published in `inflight`.
    private func finish(_ fetch: InflightFetch, for path: String) async -> CodexCatalog {
        let result = await fetch.task.value
        guard generation[path, default: 0] == fetch.generation,
              inflight[path]?.token == fetch.token
        else {
            if let replacement = inflight[path] {
                return await finish(replacement, for: path)
            }
            return cache[path] ?? .unavailable
        }
        cache[path] = result
        inflight[path] = nil
        return result
    }

    /// One standalone discovery: isolate ambient MCP config, then spawn, handshake,
    /// `model/list`, and kill. Static + isolated from the actor so a slow operation
    /// never blocks other paths' lookups.
    private static func fetch(
        executablePath: String,
        workingDirectory: URL,
        timeout: Double,
        usesSharedRuntime: Bool
    ) async -> CodexCatalog {
        if usesSharedRuntime {
            return await CodexProvider.sharedModelCatalog(
                executablePath: executablePath,
                workingDirectory: workingDirectory,
                timeout: timeout)
        }
        let environment = CodexInvocation.environment(
            binaryDirectory: (executablePath as NSString).deletingLastPathComponent)
        // Model discovery needs no apps, plugins, or MCP tools. Resolve the ambient
        // names under feature isolation, then pin every configured server off before
        // starting this metadata-only app-server.
        guard let disabledMCPServerNames = CodexInvocation.isolatedMCPServerNames(
            executablePath: executablePath,
            environment: environment,
            workingDirectory: workingDirectory.path
        ) else {
            logger.error("codex model/list probe failed: could not isolate ambient MCP servers")
            return .unavailable
        }
        let arguments = CodexInvocation.arguments(
            rubienCLIPath: nil,
            libraryRoot: nil,
            webAccess: true,
            readOnlyLibrary: true,
            disabledMCPServerNames: disabledMCPServerNames)

        let process: SpawnedAgentProcess
        do {
            process = try SpawnedAgentProcess.spawn(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory.path)
        } catch {
            logger.error("codex model/list probe failed: spawn error \(String(describing: error))")
            return .unavailable
        }

        // Drain stderr so a chatty binary can't fill the pipe and block itself.
        let stderrHandle = process.stderrHandle
        DispatchQueue.global(qos: .utility).async {
            while !stderrHandle.availableData.isEmpty {}
        }
        // Watchdog: a wedged probe is killed, which EOFs the read loop below.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            process.signalGroup(SIGKILL)
        }

        process.writeLine(CodexAppServerProtocol.initialize(
            requestID: 1, clientName: "rubien-model-catalog",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
        let models = await withTaskCancellationHandler {
            await readModels(from: process)
        } onCancel: {
            process.closeStdin()
            process.signalGroup(SIGKILL)
        }
        watchdog.cancel()
        process.closeStdin()
        process.signalGroup(SIGKILL)
        _ = await process.wait(timeout: 2)

        guard let models else {
            logger.error("codex model/list probe failed: no model list received (EOF, timeout, or decode failure)")
            return .unavailable
        }
        return CodexCatalog(models: models, fetchedOK: true)
    }

    private static func readModels(from process: SpawnedAgentProcess) async -> [CodexModelInfo]? {
        do {
            for try await line in process.stdoutHandle.bytes.lines {
                guard case let .response(id, result, error)? =
                        CodexAppServerProtocol.decodeInbound(line: line) else { continue }
                if id == .number(1) {
                    guard error == nil else {
                        logger.error("codex model/list probe failed: initialize returned an error: \(String(describing: error))")
                        return nil
                    }
                    process.writeLine(CodexAppServerProtocol.initialized())
                    process.writeLine(CodexAppServerProtocol.modelList(requestID: 2))
                } else if id == .number(2) {
                    guard error == nil, let result else {
                        if error != nil {
                            logger.error("codex model/list probe failed: model/list returned an error: \(String(describing: error))")
                        }
                        return nil
                    }
                    return CodexAppServerProtocol.decodeModelList(result)
                }
            }
        } catch {
            // Early EOF / read error → unavailable below.
        }
        return nil
    }
}
#endif
