#if os(macOS)
import Foundation
import Combine
import AppKit

struct ProviderAutomaticUpdatePolicy: Codable, Equatable {
    var schema = 1
    var enabled = false
    var failures = 0
    var retryAt: Date?
    var suspended = false
}

@MainActor
final class ProviderUpdateActionModel: ObservableObject {
    static let codex = ProviderUpdateActionModel(provider: .codex)
    static let claude = ProviderUpdateActionModel(provider: .claude)
    static func shared(_ provider: AgentProviderKind) -> ProviderUpdateActionModel { provider == .codex ? codex : claude }
    let provider: AgentProviderKind
    @Published private(set) var plan: ProviderMaintenancePlan?
    @Published private(set) var explanation: String?
    @Published private(set) var stage: String?
    @Published private(set) var output = ""
    @Published private(set) var policy = ProviderAutomaticUpdatePolicy()
    @Published private(set) var canCancel = false
    @Published private(set) var presentedPlan: ProviderMaintenancePlan?
    private var task: Task<Void, Never>?
    private var isTerminating = false
    private struct PreparationInput: Equatable {
        let installation: ProviderInstallation
        let snapshot: ProviderReleaseSnapshot
        let selection: String?
    }
    private var preparation: (input: PreparationInput, id: UUID, task: Task<ProviderMaintenancePlan, Error>)?
    private var planSelection: String?
    private var quietSince: Date?
    private var automaticPreflightID: UUID?
    private var automaticDeferral: (identity: String, count: Int, retryAt: Date)?
    private var needsRefresh = false
    private let root: URL
    private let run: ProviderMaintenancePlanner.Run
    private let refreshed: (@MainActor () async -> Void)?
    private let home: URL
    private let idleSeconds: @Sendable () -> TimeInterval
    private let override: @MainActor () -> String?
    private let discover: @Sendable (AgentProviderKind, String?, URL) async -> ProviderInstallation
    init(provider: AgentProviderKind, root: URL = ProviderSetupStore.standard.root.appendingPathComponent("UpdateActions"),
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         override: (@MainActor () -> String?)? = nil,
         discover: @escaping @Sendable (AgentProviderKind, String?, URL) async -> ProviderInstallation = {
             await ProviderInstallationDetector.discover(provider: $0, override: $1, home: $2, respectPendingUpdates: false)
         },
         refreshed: (@MainActor () async -> Void)? = nil,
         idleSeconds: @escaping @Sendable () -> TimeInterval = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) },
         run: @escaping ProviderMaintenancePlanner.Run = { try await ProviderMaintenanceRunner.run($0) }) {
        self.provider = provider
        self.root = root
        self.run = run
        self.home = home
        self.refreshed = refreshed
        self.idleSeconds = idleSeconds
        self.override = override ?? { provider == .codex ? RubienPreferences.assistantCodexBinaryPath : RubienPreferences.assistantBinaryPath }
        self.discover = discover
    }
    private var selection: String? {
        let value = override()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == true ? nil : value
    }
    var isRunning: Bool { task != nil }
    var canUpdate: Bool {
        guard let plan, let old = ProviderReleaseVersion(plan.previousVersion), let next = ProviderReleaseVersion(plan.targetVersion) else { return false }
        return !isTerminating && !isRunning && planSelection == selection && old < next
    }
    func invalidateSelection() {
        clearPreparation()
        if !isRunning { presentedPlan = nil }
    }
    private func clearPreparation() {
        preparation?.task.cancel()
        preparation = nil
        plan = nil
        planSelection = nil
        quietSince = nil
        automaticPreflightID = nil
        automaticDeferral = nil
        explanation = nil
    }
    func dismissProgress() {
        if !isRunning { presentedPlan = nil }
    }
    func prepare(installation: ProviderInstallation?, snapshot: ProviderReleaseSnapshot?) async {
        guard !isTerminating, !isRunning else { return }
        let selected = selection
        guard let installation, let snapshot,
              selected == nil || selected == installation.path else { clearPreparation(); return }
        guard (0...25 * 3600).contains(Date().timeIntervalSince(snapshot.checkedAt)) else {
            clearPreparation()
            explanation = "Check for updates to refresh the available version before updating."
            return
        }
        if let plan, planSelection == selected, plan.launcher == installation.path,
           plan.unchanged(), plan.fingerprint == snapshot.fingerprint, plan.targetVersion == snapshot.availableVersion {
            publishPolicy(readPolicy(plan.identity))
            if policy.schema != 1 {
                self.plan = nil
                explanation = "This installation’s update settings are unreadable or require a newer Rubien version."
            }
            return
        }
        let input = PreparationInput(installation: installation, snapshot: snapshot, selection: selected)
        let pending: (input: PreparationInput, id: UUID, task: Task<ProviderMaintenancePlan, Error>)
        if let preparation, preparation.input == input {
            pending = preparation
        } else {
            preparation?.task.cancel()
            plan = nil
            let provider = provider, home = home, run = run
            pending = (input, UUID(), Task {
                try await ProviderMaintenancePlanner.make(provider: provider, installation: installation, snapshot: snapshot, home: home, run: run)
            })
            preparation = pending
        }
        do {
            let proposed = try await pending.task.value
            guard preparation?.id == pending.id, selection == selected else { return }
            guard proposed.unchanged() else { throw ProviderMutationError.changed }
            plan = proposed
            planSelection = selected
            publishPolicy(readPolicy(proposed.identity))
            guard policy.schema == 1 else {
                throw ProviderMutationError.unsupported("This installation’s update settings are unreadable or require a newer Rubien version.")
            }
            try recoverInterrupted(proposed)
            preparation = nil
            explanation = nil
        } catch {
            guard preparation?.id == pending.id else { return }
            preparation = nil
            plan = nil
            explanation = error.localizedDescription
        }
    }
    func setAutomatic(_ enabled: Bool) {
        guard let plan, plan.allowsAutomaticInstall, !isRunning else { return }
        do {
            policy = try changePolicy(plan.identity) {
                $0.enabled = enabled
                $0.suspended = false
                $0.failures = 0
                $0.retryAt = nil
            }
            quietSince = nil
            automaticPreflightID = nil
            automaticDeferral = nil
        } catch { explanation = "Could not save the automatic-update preference. Try again." }
    }
    func cancel() { if canCancel { task?.cancel() } }
    func beginTermination() {
        isTerminating = true
        automaticPreflightID = nil
        preparation?.task.cancel()
        cancel()
    }
    func finishForTermination() async {
        await task?.value
    }
    func update(automatic: Bool = false) {
        guard canUpdate, let plan else { return }
        let selected = planSelection
        needsRefresh = false
        presentedPlan = plan
        stage = "Preparing update…"
        output = ""
        canCancel = true
        task = Task {
            await perform(plan, selection: selected, automatic: automatic)
            canCancel = false
            if needsRefresh, !isTerminating {
                if let refreshed { await refreshed() }
                else {
                    await ProviderUpdateModel.shared(provider).check(manual: true)
                    await ProviderSetupModel.shared(provider).refresh()
                }
            }
            task = nil
            if refreshed == nil, !isTerminating {
                let model = ProviderUpdateModel.shared(provider)
                await prepare(installation: model.installation, snapshot: model.record.snapshot)
            }
        }
    }
    /// Preflight stays observational: external usage must not publish progress,
    /// retire a server, or acquire action/usage locks just to defer an update.
    func considerAutomaticUpdate(now: Date = Date()) async {
        guard automaticPreflightID == nil else { return }
        guard !isRunning, let plan, plan.allowsAutomaticInstall, canUpdate else { quietSince = nil; return }
        publishPolicy(readPolicy(plan.identity))
        let deferred = automaticDeferral.map { $0.identity == plan.identity && $0.retryAt > now } ?? false
        guard !deferred, policy.enabled, !policy.suspended, policy.retryAt.map({ $0 <= now }) ?? true,
              idleSeconds() >= 30, !ProviderUsageCoordinator.pending(root: plan.root) else {
            quietSince = nil
            return
        }
        guard let since = quietSince, now.timeIntervalSince(since) >= 30 else {
            if quietSince == nil { quietSince = now }
            return
        }
        quietSince = nil
        let id = UUID()
        let selected = selection
        automaticPreflightID = id
        defer { if automaticPreflightID == id { automaticPreflightID = nil } }
        // Rubien's own children are coordinated by usage leases during perform.
        // The final inventory still checks every holder after those leases drain.
        let holders = try? await externalHolders(plan, ignoringOwnChildren: true)
        guard automaticPreflightID == id, !Task.isCancelled, canUpdate,
              self.plan == plan, selection == selected else { return }
        publishPolicy(readPolicy(plan.identity))
        guard policy.schema == 1, policy.enabled, !policy.suspended,
              policy.retryAt.map({ $0 <= now }) ?? true, idleSeconds() >= 30,
              !ProviderUsageCoordinator.pending(root: plan.root) else { return }
        guard holders?.isEmpty == true else {
            let previous = automaticDeferral.flatMap { $0.identity == plan.identity ? $0.count : nil } ?? 0
            let count = min(previous + 1, 3)
            let delay: TimeInterval = count == 1 ? 60 : count == 2 ? 300 : 900
            automaticDeferral = (plan.identity, count, now.addingTimeInterval(delay))
            return
        }
        automaticDeferral = nil
        update(automatic: true)
    }
    private func perform(_ plan: ProviderMaintenancePlan, selection selected: String?, automatic: Bool) async {
        var mutationStarted = false
        let intentStartedAt = Date()
        var ownsAction = false
        var heldAction: ProviderSetupLock?
        defer { withExtendedLifetime(heldAction) {} }
        do {
            guard selection == selected else { throw ProviderMutationError.changed }
            let directory = try operationDirectory(plan.identity)
            guard let action = try ProviderSetupLock(url: directory.appendingPathComponent("action.lock")) else {
                canCancel = true
                stage = "Another Rubien window is updating this installation."
                let deadline = Date().addingTimeInterval(900)
                while Date() < deadline {
                    try Task.checkCancellation()
                    if let available = try ProviderSetupLock(url: directory.appendingPathComponent("action.lock"), mode: .shared) {
                        withExtendedLifetime(available) {}
                        stage = operationStatus(in: directory) ?? "The other update finished. Recheck the installation."
                        needsRefresh = true
                        return
                    }
                    stage = operationStatus(in: directory) ?? "Another Rubien window is updating this installation."
                    try await Task.sleep(for: .seconds(1))
                }
                throw ProviderMutationError.timeout
            }
            defer { withExtendedLifetime(action) {} }
            ownsAction = true
            heldAction = action
            guard plan.unchanged(), readPolicy(plan.identity).schema == 1 else { throw ProviderMutationError.changed }
            if automatic {
                let current = readPolicy(plan.identity)
                guard current.enabled, !current.suspended else { throw CancellationError() }
            }
            var owner: ProviderUsageOwner?
            if plan.needsUsageExclusion {
                let usageDirectory = try ProviderUsageCoordinator.directory(plan.root)
                guard let intent = try ProviderSetupLock(url: usageDirectory.appendingPathComponent("intent.lock")) else { throw ProviderMutationError.busy }
                stage = "Waiting for conversations to finish…"
                try journal(plan, stage: stage!, finished: false)
                let deadline = Date().addingTimeInterval(120)
                while owner == nil {
                    try Task.checkCancellation()
                    await CodexSharedConnectionRegistry.shared.retireIdleForProviderUpdate(path: plan.launcher)
                    if let lease = try ProviderSetupLock(url: usageDirectory.appendingPathComponent("usage.lock")) {
                        owner = ProviderUsageOwner(root: plan.root, usage: lease, intent: intent)
                    } else {
                        if automatic { throw ProviderMutationError.busy }
                        guard Date() < deadline else { throw ProviderMutationError.timeout }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
                let holders = try await externalHolders(plan)
                guard holders.isEmpty else {
                    throw ProviderMutationError.deferred("Close the other CLI sessions using this installation (process \(holders.map(String.init).joined(separator: ", "))) and retry. Rubien did not stop them.")
                }
            }
            // The owner stays alive through verification and every exit path.
            defer { withExtendedLifetime(owner) {} }
            guard plan.unchanged() else { throw ProviderMutationError.changed }
            try Task.checkCancellation()
            let found = ProviderInstallation(state: .found, path: plan.launcher,
                hint: plan.method == .npm ? .npm : .native, detail: nil)
            let snapshot = ProviderReleaseSnapshot(installedVersion: plan.previousVersion, availableVersion: plan.targetVersion,
                source: ProviderReleaseSource.source(provider: provider, hint: found.hint)!, fingerprint: plan.fingerprint, checkedAt: Date())
            let revalidated = try await ProviderMaintenancePlanner.make(provider: provider, installation: found,
                snapshot: snapshot, home: home, run: run)
            guard revalidated == plan else { throw ProviderMutationError.changed }
            let environment = plan.environment
            var executable = plan.executable
            var arguments = plan.arguments
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            if plan.method == .codexNative {
                stage = "Downloading the official updater…"
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rubien-provider-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                temporary = folder
                let installer = ProviderInstallerPlan(provider: provider, directory: folder)
                let download = try await run(.init(executable: "/usr/bin/curl", arguments: installer.downloadArguments,
                    environment: environment, directory: folder, timeout: 90, inheritedLock: action.descriptor))
                guard download.exitCode == 0, !download.timedOut else { throw ProviderSetupError.download }
                let script = try installer.inspectDownload()
                guard script.hash == ProviderMaintenancePlanner.reviewedCodexScriptHash else {
                    throw ProviderMutationError.unsupported("The official updater changed. This Rubien version needs a compatibility check; use the official update instructions meanwhile.")
                }
                guard plan.unchanged(), try installer.inspectDownload() == script else { throw ProviderMutationError.changed }
                executable = provider.installerShell
                arguments = [installer.script.path]
            }
            let currentInstallation = await discover(provider, selected, home)
            guard currentInstallation.path == plan.launcher, selection == selected,
                  plan.unchanged() else { throw ProviderMutationError.changed }
            if automatic {
                guard readPolicy(plan.identity).enabled,
                      !ProviderUsageCoordinator.demandSince(intentStartedAt, root: plan.root),
                      idleSeconds() >= 30 else { throw CancellationError() }
            }
            try Task.checkCancellation()
            canCancel = false
            stage = "Updating \(provider.setupName)…"
            try journal(plan, stage: stage!, finished: false)
            mutationStarted = true
            needsRefresh = true
            let result = try await run(.init(executable: executable, arguments: arguments,
                environment: environment, directory: FileManager.default.temporaryDirectory, timeout: 900,
                inheritedLock: action.descriptor, maintenanceOwner: owner,
                onOutput: { [weak self] text in Task { @MainActor in self?.output = text } }))
            output = result.output
            stage = "Verifying the installed version…"
            let verification = try await run(.init(executable: plan.launcher, arguments: ["--version"],
                environment: environment, directory: FileManager.default.temporaryDirectory, timeout: 15,
                inheritedLock: action.descriptor, maintenanceOwner: owner))
            guard verification.exitCode == 0, !verification.timedOut,
                  let raw = ProviderSetupModel.version(from: verification.output),
                  let installed = ProviderReleaseVersion(raw), let previous = ProviderReleaseVersion(plan.previousVersion),
                  installed >= previous, !installed.isPrerelease else { throw ProviderSetupError.verification }
            let sameOwner = plan.needsUsageExclusion
                ? ProviderUsageCoordinator.packageRoot(plan.launcher) == plan.root
                : ProviderBinaryFingerprint.read(plan.launcher)?.target.hasPrefix(plan.root + "/") == true
            guard sameOwner else { throw ProviderSetupError.verification }
            if installed > previous, plan.method != .claudeNative,
               let target = ProviderReleaseVersion(plan.targetVersion), installed < target {
                throw ProviderMutationError.failed("The updater installed \(raw), which is older than the requested release. Recheck before retrying.")
            }
            guard result.exitCode == 0, !result.timedOut else {
                throw ProviderMutationError.failed("The updater did not finish successfully. Installed version: \(raw). Recheck before retrying.")
            }
            if installed == previous {
                stage = "No update applied. Installed: \(raw). The provider may be following a different channel or policy."
            } else {
                stage = "Updated to \(raw). New conversations will use this version."
            }
            try journal(plan, stage: stage!, finished: true)
            policy = try changePolicy(plan.identity) {
                $0.failures = 0
                $0.retryAt = nil
            }
            self.plan = nil
            // Ordinary probes run after the action returns and releases exclusion.
            owner = nil
        } catch is CancellationError {
            if mutationStarted { self.plan = nil }
            stage = !ownsAction ? "Stopped watching. The other Rubien window continues its update."
                : mutationStarted ? "Update interrupted. Recheck the installation." : "Update cancelled."
            if ownsAction { try? journal(plan, stage: stage!, finished: true) }
        } catch {
            if mutationStarted { self.plan = nil }
            stage = error.localizedDescription
            if ownsAction { try? journal(plan, stage: stage!, finished: true) }
            if automatic, ownsAction {
                policy = (try? changePolicy(plan.identity) {
                    switch error {
                    case ProviderMutationError.busy, ProviderMutationError.deferred:
                        $0.retryAt = Date().addingTimeInterval(60)
                        return
                    default: break
                    }
                    $0.failures += 1
                    $0.retryAt = Date().addingTimeInterval($0.failures == 1 ? 3600 : 86400)
                    if $0.failures >= 3 { $0.suspended = true }
                    if case ProviderMutationError.unsupported = error { $0.suspended = true }
                    if case ProviderMutationError.changed = error { $0.suspended = true }
                }) ?? policy
            }
        }
    }
    private func externalHolders(_ plan: ProviderMaintenancePlan, ignoringOwnChildren: Bool = false) async throws -> [Int] {
        let inventory = ProviderProcessInventory(root: plan.root, launcher: plan.launcher,
            ignoringDescendantsOf: ignoringOwnChildren ? Int(ProcessInfo.processInfo.processIdentifier) : nil)
        let result: ProviderCommandResult
        do {
            result = try await run(.init(executable: "/bin/ps", arguments: ["-ww", "-axo", "pid=,ppid=,command="],
                environment: plan.environment, directory: FileManager.default.temporaryDirectory, timeout: 5,
                retainOutput: false, stdoutConsumer: { inventory.append($0) }))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderMutationError.deferred("Rubien could not check active CLI sessions. Try again shortly.")
        }
        guard result.exitCode == 0, !result.timedOut else {
            throw ProviderMutationError.deferred("Rubien could not check whether another CLI session is using this installation. Try again shortly.")
        }
        return inventory.finish()
    }
    private func recoverInterrupted(_ plan: ProviderMaintenancePlan) throws {
        let directory = root.appendingPathComponent(plan.identity)
        let file = directory.appendingPathComponent("operation.json")
        guard FileManager.default.fileExists(atPath: file.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024,
              let lock = try ProviderSetupLock(url: directory.appendingPathComponent("action.lock")) else { return }
        defer { withExtendedLifetime(lock) {} }
        guard let data = try? Data(contentsOf: file),
              var record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["finished"] as? Bool == false, record["path"] as? String == plan.launcher else { return }
        let message = "The previous update was interrupted. Current version: \(plan.previousVersion). Recheck before retrying."
        record["finished"] = true
        record["stage"] = message
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
        policy = try changePolicy(plan.identity) { if $0.enabled { $0.suspended = true } }
        stage = message
    }
    private func operationStatus(in directory: URL) -> String? {
        let file = directory.appendingPathComponent("operation.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["stage"] as? String
    }
    private func operationDirectory(_ key: String) throws -> URL {
        let directory = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func readPolicy(_ key: String) -> ProviderAutomaticUpdatePolicy {
        let file = root.appendingPathComponent(key).appendingPathComponent("policy.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        guard let data = try? Data(contentsOf: file), data.count < 16384,
              let policy = try? JSONDecoder().decode(ProviderAutomaticUpdatePolicy.self, from: data), policy.schema == 1 else {
            var blocked = ProviderAutomaticUpdatePolicy()
            blocked.suspended = true
            blocked.schema = 0
            return blocked
        }
        return policy
    }
    private func publishPolicy(_ value: ProviderAutomaticUpdatePolicy) {
        if policy != value { policy = value }
    }
    private func changePolicy(_ key: String, change: (inout ProviderAutomaticUpdatePolicy) -> Void) throws -> ProviderAutomaticUpdatePolicy {
        let directory = try operationDirectory(key)
        guard let lock = try ProviderSetupLock(url: directory.appendingPathComponent("policy.lock")) else { throw CocoaError(.fileLocking) }
        defer { withExtendedLifetime(lock) {} }
        let file = directory.appendingPathComponent("policy.json")
        var policy = readPolicy(key)
        guard policy.schema == 1 else { throw ProviderMutationError.changed }
        change(&policy)
        try JSONEncoder().encode(policy).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return policy
    }
    private func journal(_ plan: ProviderMaintenancePlan, stage: String, finished: Bool) throws {
        let file = try operationDirectory(plan.identity).appendingPathComponent("operation.json")
        let data = try JSONSerialization.data(withJSONObject: ["provider": provider.rawValue, "path": plan.launcher,
            "previousVersion": plan.previousVersion, "targetVersion": plan.targetVersion,
            "stage": stage, "finished": finished, "updatedAt": Date().timeIntervalSince1970, "output": output,
            "scriptSHA256": plan.method == .codexNative ? ProviderMaintenancePlanner.reviewedCodexScriptHash : "",
            "scriptSource": plan.method == .codexNative ? provider.installerURL.absoluteString : ""])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
#endif
