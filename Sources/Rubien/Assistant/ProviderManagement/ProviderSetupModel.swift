#if os(macOS)
import Foundation
import Combine
import RubienCore

/// One model per provider keeps setup alive when Settings closes and deduplicates windows.
@MainActor
final class ProviderSetupModel: ObservableObject {
    static let claude = ProviderSetupModel(provider: .claude)
    static let codex = ProviderSetupModel(provider: .codex)
    static func shared(_ provider: AgentProviderKind) -> ProviderSetupModel { provider == .codex ? codex : claude }

    enum Activity: Equatable {
        case checking, downloading, installing, verifying, signingIn, observing(String)
        var title: String {
            switch self {
            case .checking: return "Checking…"
            case .downloading: return "Downloading official installer…"
            case .installing: return "Installing…"
            case .verifying: return "Verifying installation…"
            case .signingIn: return "Signing in… Complete sign-in in your browser."
            case .observing(let stage): return "Another setup action is running: \(stage)"
            }
        }
    }
    typealias Run = @Sendable (ProviderMaintenanceRequest) async throws -> ProviderCommandResult
    let provider: AgentProviderKind
    @Published private(set) var installation: ProviderInstallation?
    @Published private(set) var availability: AgentAvailability?
    @Published private(set) var activity: Activity?
    @Published private(set) var message: String?
    @Published private(set) var diagnostics = ""
    @Published private(set) var concreteProcedure: String?
    @Published private(set) var completedChecks = 0
    private let store: ProviderSetupStore
    private let home: URL
    private let run: Run
    private let environment: @Sendable (AgentProviderKind) -> [String: String]
    private let discover: @Sendable (AgentProviderKind, String?) async -> ProviderInstallation
    private let probe: @MainActor (AgentProviderKind, String?) async -> AgentAvailability
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let now: @Sendable () -> Date
    private var lastCheckAt: Date?
    private var lastCheckOverride: String?
    private var lastCheckFingerprint: ProviderBinaryFingerprint?

    init(provider: AgentProviderKind, store: ProviderSetupStore = .standard,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping @Sendable () -> Date = { Date() },
         run: @escaping Run = { try await ProviderMaintenanceRunner.run($0) },
         environment: @escaping @Sendable (AgentProviderKind) -> [String: String] = { ProviderSetupEnvironment.make(provider: $0) },
         discover: @escaping @Sendable (AgentProviderKind, String?) async -> ProviderInstallation = {
             await ProviderInstallationDetector.discover(provider: $0, override: $1)
         },
         probe: @escaping @MainActor (AgentProviderKind, String?) async -> AgentAvailability = ProviderSetupModel.probeAvailability) {
        self.provider = provider
        self.store = store
        self.home = home
        self.run = run
        self.environment = environment
        self.discover = discover
        self.probe = probe
        self.now = now
    }

    var override: String? {
        provider == .codex ? RubienPreferences.assistantCodexBinaryPath : RubienPreferences.assistantBinaryPath
    }
    var canCancel: Bool { activity == .downloading || activity == .signingIn }
    var canInstall: Bool { activity == nil && installation?.canInstall == true }
    var canSignIn: Bool {
        activity == nil && installation?.state == .found && availability?.version != nil && availability?.isAuthenticated == false
    }
    var loginCommand: String {
        let path = installation?.path ?? provider.setupBinary
        return ProviderInstallerPlan.quote(path) + " " + provider.loginArguments.joined(separator: " ")
    }

    /// Automatic activation checks reuse a fresh snapshot; explicit Recheck and
    /// operation completion always probe. Concurrent cards share the in-flight check.
    func refresh(force: Bool = true, notice: String? = nil) async {
        guard task == nil, activity != .checking else { return }
        if !force, let lastCheckAt, now().timeIntervalSince(lastCheckAt) < 60,
           lastCheckOverride == override,
           lastCheckFingerprint == installation?.path.flatMap(ProviderBinaryFingerprint.read),
           store.maintenanceAvailability(provider: provider) == nil { return }
        let token = UUID()
        generation = token
        message = notice
        activity = .checking
        var recoveredActions: [ProviderSetupAction] = []
        for action in ProviderSetupAction.allCases {
            var abandonedID: UUID?
            do {
                guard let lock = try store.acquire(provider: provider, action: action, mode: .shared) else {
                    observe(action: action)
                    return
                }
                if let previous = store.read(provider: provider, action: action), !previous.finished { abandonedID = previous.id }
                withExtendedLifetime(lock) {}
            } catch {
                activity = nil
                message = error.localizedDescription
                return
            }
            // Release the read lock before attempting recovery. Another reader or
            // a new action may win; the record id check prevents rewriting its intent.
            if let abandonedID {
                do {
                    if try store.recoverInterrupted(provider: provider, action: action, expectedID: abandonedID) {
                        recoveredActions.append(action)
                    }
                } catch { message = error.localizedDescription }
            }
        }
        let selected = override
        let found = await discover(provider, selected)
        guard generation == token else { return }
        installation = found
        if found.state == .found {
            let result = await probe(provider, selected)
            guard generation == token else { return }
            availability = result
        } else { availability = nil }
        activity = nil
        lastCheckAt = now()
        lastCheckOverride = selected
        lastCheckFingerprint = found.path.flatMap(ProviderBinaryFingerprint.read)
        completedChecks += 1
        if recoveredActions.contains(where: { $0 == .login ? availability?.isReady != true : availability?.isInstalled != true }) {
            message = ProviderSetupError.interrupted.localizedDescription
        }
    }

    func cancel() { if canCancel { task?.cancel() } }

    func install() {
        guard canInstall else { return }
        generation = UUID()
        activity = .downloading
        message = nil
        diagnostics = ""
        task = Task { await performInstall() }
    }

    private func performInstall() async {
        var record = makeRecord(action: .install, stage: "Preparing")
        do {
            guard let lock = try await store.acquireForAction(provider: provider) else {
                task = nil
                observe(action: .install)
                return
            }
            // Retain the lock until verification and the terminal journal write finish.
            defer { withExtendedLifetime(lock) {} }
            do {
                let found = await discover(provider, override)
                installation = found
                guard found.canInstall else { throw ProviderSetupError.existingInstallation }
                try Task.checkCancellation()
                try store.write(record)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rubien-provider-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let plan = ProviderInstallerPlan(provider: provider, directory: directory)
                concreteProcedure = plan.displayedProcedure
                let env = environment(provider)
                record.stage = "Downloading"
                record.scriptPath = plan.script.path
                record.sourceURL = provider.installerURL.absoluteString
                try store.write(record)
                let download = try await run(.init(executable: "/usr/bin/curl", arguments: plan.downloadArguments,
                    environment: env, directory: directory, timeout: 65, inheritedLock: lock.descriptor))
                guard download.exitCode == 0, !download.timedOut else { throw ProviderSetupError.download }
                let downloaded = try plan.inspectDownload()
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.script.path)
                try Task.checkCancellation()
                // Rediscover after the network wait; another tool may have installed meanwhile.
                guard await discover(provider, override).canInstall else { throw ProviderSetupError.existingInstallation }
                guard try plan.inspectDownload() == downloaded else { throw ProviderSetupError.scriptChanged }
                record.scriptHash = downloaded.hash
                record.sourceURL = downloaded.sourceURL.absoluteString
                record.scriptFingerprint = downloaded.fingerprint
                record.stage = "Installing"
                record.updatedAt = Date()
                try store.write(record)
                activity = .installing
                let token = generation
                let result = try await run(.init(executable: provider.installerShell, arguments: [plan.script.path],
                    environment: env, directory: directory, timeout: 15 * 60, inheritedLock: lock.descriptor,
                    onOutput: { [weak self] output in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            if self.diagnostics != output { self.diagnostics = output }
                        }
                    }))
                diagnostics = result.output + (result.truncated ? "\n[Output truncated]" : "")
                guard result.exitCode == 0, !result.timedOut else {
                    throw ProviderSetupError.command(result.timedOut
                        ? "Installation timed out. Recheck before retrying; some files may already be installed."
                        : "The installer did not finish successfully. Review the output, then recheck.")
                }
                activity = .verifying
                record.stage = "Verifying"
                try store.write(record)
                let expected = home.appendingPathComponent(".local/bin/\(provider.setupBinary)").path
                guard FileManager.default.isExecutableFile(atPath: expected),
                      let fingerprint = ProviderBinaryFingerprint.read(expected),
                      fingerprint.target.hasPrefix(nativeRoot.path + "/") else { throw ProviderSetupError.verification }
                let versionResult = try await run(.init(executable: expected, arguments: ["--version"],
                    environment: env, directory: directory, timeout: 10, inheritedLock: lock.descriptor))
                guard versionResult.exitCode == 0, !versionResult.timedOut,
                      let version = Self.version(from: versionResult.output),
                      ProviderBinaryFingerprint.read(expected) == fingerprint else { throw ProviderSetupError.verification }
                record.path = expected
                record.version = version
                record.nativeRoot = nativeRoot.path
                record.fingerprint = fingerprint
                record.finished = true
                record.succeeded = true
                record.stage = "Installed"
                record.updatedAt = Date()
                try store.saveReceipt(record)
                try store.write(record)
                message = nil
            } catch {
                record.finished = true
                record.stage = "Stopped"
                record.updatedAt = Date()
                record.detail = error is CancellationError ? "Download cancelled. No installer was run." : error.localizedDescription
                record.succeeded = false
                try? store.write(record)
                throw error
            }
        } catch {
            message = error is CancellationError ? "Download cancelled." : error.localizedDescription
        }
        task = nil
        activity = nil
        await refresh(notice: message)
    }

    private var nativeRoot: URL {
        home.appendingPathComponent(provider == .codex ? ".codex/packages/standalone" : ".local/share/claude/versions")
    }

    func signIn() {
        guard canSignIn, let path = installation?.path else { return }
        generation = UUID()
        activity = .signingIn
        message = nil
        diagnostics = ""
        task = Task {
            var record = makeRecord(action: .login, stage: "Signing in")
            record.path = path
            record.version = availability?.version
            do {
                guard let lock = try await store.acquireForAction(provider: provider, action: .login) else {
                    task = nil
                    observe(action: .login)
                    return
                }
                defer { withExtendedLifetime(lock) {} }
                do {
                    try store.write(record)
                    var loginEnvironment = environment(provider)
                    loginEnvironment["PATH"] = (path as NSString).deletingLastPathComponent + ":" + (loginEnvironment["PATH"] ?? "")
                    let env = loginEnvironment
                    let execute: @Sendable () async throws -> ProviderCommandResult = { [run, provider, home] in
                        try await run(.init(executable: path, arguments: provider.loginArguments, environment: env,
                            directory: home, timeout: 10 * 60, retainOutput: false, inheritedLock: lock.descriptor))
                    }
                    let result: ProviderCommandResult
                    if provider == .codex {
                        result = try await CodexProvider(executableOverride: override,
                            contentChannel: MCPContentChannel.resolveBundled(), shareAppServer: true).runSetupLogin(execute)
                    } else { result = try await execute() }
                    guard result.exitCode == 0, !result.timedOut else {
                        throw ProviderSetupError.command(result.timedOut
                            ? "Sign-in timed out. Try again or use the Terminal command."
                            : "Sign-in did not finish. Try the Terminal command, then recheck.")
                    }
                    record.succeeded = true
                    message = nil
                } catch {
                    record.detail = error is CancellationError ? "Sign-in cancelled." : error.localizedDescription
                    message = record.detail
                }
                record.finished = true
                record.stage = "Finished"
                record.updatedAt = Date()
                try store.write(record)
            } catch { message = error is CancellationError ? "Sign-in cancelled." : error.localizedDescription }
            task = nil
            activity = nil
            await refresh(notice: message)
        }
    }

    private func observe(action: ProviderSetupAction) {
        activity = .observing(store.read(provider: provider, action: action)?.stage ?? "Starting")
        task = Task {
            while !Task.isCancelled {
                do {
                    if let lock = try store.acquire(provider: provider, action: action, mode: .shared) {
                        withExtendedLifetime(lock) {}
                        let record = store.read(provider: provider, action: action)
                        message = record?.finished == true ? record?.detail : nil
                        break
                    }
                } catch {
                    message = error.localizedDescription
                    break
                }
                activity = .observing(store.read(provider: provider, action: action)?.stage ?? "Starting")
                try? await Task.sleep(for: .seconds(1))
            }
            task = nil
            activity = nil
            await refresh(notice: message)
        }
    }

    private func makeRecord(action: ProviderSetupAction, stage: String) -> ProviderSetupRecord {
        ProviderSetupRecord(id: UUID(), provider: provider, action: action,
                            stage: stage, finished: false, succeeded: false, updatedAt: Date())
    }
    nonisolated static func version(from output: String) -> String? {
        guard let range = output.range(of: #"\b[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\b"#,
                                       options: .regularExpression) else { return nil }
        return String(output[range])
    }
    static func probeAvailability(_ provider: AgentProviderKind, _ override: String?) async -> AgentAvailability {
        guard let database = try? AppDatabase.openShared(),
              await AssistantExecutionOwnership.shared.prepareIfNeededAsync(database: database) else {
            return .notFound(reason: "Assistant execution is owned by another Rubien process, or the library is unavailable.")
        }
        if provider == .codex {
            return await CodexProvider(executableOverride: override, contentChannel: MCPContentChannel.resolveBundled(), shareAppServer: true).isAvailable()
        }
        return await ClaudeCodeProvider(executableOverride: override).isAvailable()
    }
}
#endif
