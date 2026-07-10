#if os(macOS)
import Darwin
import Foundation
import RubienCore

// MARK: - Codex model catalog (model/list auto-discovery)
//
// Fetches the installed codex's OWN model list via a short-lived `codex app-server`
// (`initialize → initialized → model/list`; verified back to codex 0.142.5 — spec
// §2.1) and memoizes it per resolved binary path. The catalog feeds PICKERS ONLY:
// no turn ever waits on it (spec §4.1) — "Codex default" sends no model at all, and
// a pinned slug is sent verbatim, so a turn racing this fetch is already correct.
//
// Correctness internals (spec review finding #9): concurrent callers join one
// in-flight Task per path; a generation token invalidates on forceReload / path
// change so a stale completion cannot repopulate an invalidated entry.

actor CodexModelCatalog {
    /// Production singleton — Settings and every reader window share one result
    /// (one probe spawn per launch per binary path).
    static let shared = CodexModelCatalog()

    private let workingDirectory: URL
    private let logger = RubienLogger(subsystem: "com.rubien.assistant", category: "CodexModelCatalog")

    private var cache: [String: CodexCatalog] = [:]
    private var inflight: [String: Task<CodexCatalog, Never>] = [:]
    /// Per-PATH invalidation tokens (spec §4.1): `forceReload` bumps a path's
    /// token so a fetch that started before the bump can't repopulate the entry
    /// it invalidated. Per-path, not global — reloading one binary must not
    /// invalidate another's in-flight fetch (plan-review #2).
    private var generation: [String: Int] = [:]

    /// Bound on the whole probe (spawn → handshake → model/list). Local IPC answers
    /// in well under a second; a wedged binary must not hold a picker open forever.
    private static let fetchTimeout: Double = 10

    init(workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.workingDirectory = workingDirectory
    }

    /// The catalog for the codex the override resolves to. Memoized; `forceReload`
    /// (Settings ▸ Recheck) drops the memo and refetches. Failure of any kind —
    /// unresolvable binary, spawn error, JSON-RPC error (a codex too old for
    /// `model/list`), timeout — returns `.unavailable`; callers degrade per §4.7.
    func catalog(executableOverride: String?, forceReload: Bool = false) async -> CodexCatalog {
        guard let path = Self.resolveExecutable(override: executableOverride) else {
            return .unavailable
        }
        if forceReload {
            cache[path] = nil
            inflight[path] = nil
            generation[path, default: 0] += 1
        }
        if let cached = cache[path] { return cached }
        if let running = inflight[path] { return await running.value }

        let gen = generation[path, default: 0]
        let directory = workingDirectory
        let task = Task { await Self.fetch(executablePath: path, workingDirectory: directory) }
        inflight[path] = task
        let result = await task.value
        // A forceReload that raced this fetch bumped the path's generation: the
        // stale completion must not repopulate the entry it invalidated. When the
        // generation still matches, the inflight entry is necessarily THIS task
        // (only forceReload replaces it, and that bumps the generation), so it is
        // safe to clear without comparing Task identities (plan-review #1).
        if generation[path, default: 0] == gen {
            cache[path] = result
            inflight[path] = nil
        }
        return result
    }

    /// Well-known codex install dirs; mirrors `CodexAppServerConnection.resolveExecutable`
    /// (file-private inside `CodexProvider.swift`, so not reusable from here) so both
    /// call sites resolve the SAME binary via the SAME candidate list — a picker asking
    /// "what can Codex run?" must agree with what a turn will actually spawn.
    private static func resolveExecutable(override: String?) -> String? {
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

    /// One standalone probe: spawn, handshake, `model/list`, kill. Static + isolated
    /// from the actor so a slow probe never blocks other paths' lookups.
    private static func fetch(executablePath: String, workingDirectory: URL) async -> CodexCatalog {
        let arguments = CodexInvocation.arguments(
            rubienCLIPath: nil, libraryRoot: nil, webAccess: true)
        let environment = CodexInvocation.environment(
            binaryDirectory: (executablePath as NSString).deletingLastPathComponent)

        let process: SpawnedAgentProcess
        do {
            process = try SpawnedAgentProcess.spawn(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory.path)
        } catch {
            return .unavailable
        }

        // Drain stderr so a chatty binary can't fill the pipe and block itself.
        let stderrHandle = process.stderrHandle
        DispatchQueue.global(qos: .utility).async {
            while !stderrHandle.availableData.isEmpty {}
        }
        // Watchdog: a wedged probe is killed, which EOFs the read loop below.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(fetchTimeout))
            process.signalGroup(SIGKILL)
        }

        var models: [CodexModelInfo]?
        process.writeLine(CodexAppServerProtocol.initialize(
            requestID: 1, clientName: "rubien-model-catalog",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
        do {
            for try await line in process.stdoutHandle.bytes.lines {
                guard case let .response(id, result, error)? =
                        CodexAppServerProtocol.decodeInbound(line: line) else { continue }
                if id == .number(1) {
                    guard error == nil else { break }
                    process.writeLine(CodexAppServerProtocol.initialized())
                    process.writeLine(CodexAppServerProtocol.modelList(requestID: 2))
                } else if id == .number(2) {
                    if error == nil, let result {
                        models = CodexAppServerProtocol.decodeModelList(result)
                    }
                    break
                }
            }
        } catch {
            // Early EOF / read error → unavailable below.
        }
        watchdog.cancel()
        process.closeStdin()
        process.signalGroup(SIGKILL)
        Task { _ = await process.wait() }   // reap off-path

        guard let models else { return .unavailable }
        return CodexCatalog(models: models, fetchedOK: true)
    }
}
#endif
