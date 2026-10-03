#if os(macOS)
import Foundation
import Combine

@MainActor
final class ProviderUpdateModel: ObservableObject {
    static let codex = ProviderUpdateModel(provider: .codex)
    static let claude = ProviderUpdateModel(provider: .claude)
    static func shared(_ provider: AgentProviderKind) -> ProviderUpdateModel { provider == .codex ? codex : claude }

    let provider: AgentProviderKind
    @Published private(set) var isChecking = false
    @Published private(set) var record = ProviderUpdateRecord()
    @Published private(set) var detail: String?
    @Published private(set) var installation: ProviderInstallation?
    @Published private(set) var notice: ProviderReleaseSnapshot?
    private let store: ProviderUpdateStore
    private let discover: @Sendable (AgentProviderKind, String?) async -> ProviderInstallation
    private let version: @Sendable (AgentProviderKind, String) async -> String?
    private let fetch: @Sendable (ProviderReleaseSource) async throws -> ProviderReleaseVersion
    private let override: @MainActor () -> String?
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> TimeInterval
    private var key: String?
    private var checkingOverride: String?
    private var selectionChangedDuringCheck = false
    private var presentedNotices: Set<String> = []

    init(provider: AgentProviderKind, store: ProviderUpdateStore = .standard,
         override: (@MainActor () -> String?)? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         jitter: @escaping @Sendable () -> TimeInterval = { Double.random(in: 0...1800) },
         discover: @escaping @Sendable (AgentProviderKind, String?) async -> ProviderInstallation = {
             await ProviderInstallationDetector.discover(provider: $0, override: $1)
         },
         version: @escaping @Sendable (AgentProviderKind, String) async -> String? = { await ProviderUpdateModel.readVersion(provider: $0, path: $1) },
         fetch: @escaping @Sendable (ProviderReleaseSource) async throws -> ProviderReleaseVersion = { try await ProviderReleaseClient.fetch($0) }) {
        self.provider = provider
        self.store = store
        self.override = override ?? { provider == .codex ? RubienPreferences.assistantCodexBinaryPath : RubienPreferences.assistantBinaryPath }
        self.now = now
        self.jitter = jitter
        self.discover = discover
        self.version = version
        self.fetch = fetch
    }

    /// Opening Settings loads policy, but does not bypass opt-out or refresh auth.
    func check(manual: Bool = false) async {
        guard !isChecking else {
            if checkingOverride != override() {
                selectionChangedDuringCheck = true
                clearSelection(detail: nil)
            }
            return
        }
        isChecking = true
        defer {
            isChecking = false
            if selectionChangedDuringCheck {
                selectionChangedDuringCheck = false
                Task { await self.check() }
            }
        }
        let selected = override()
        checkingOverride = selected
        let found = await discover(provider, selected)
        guard selected == override() else { return }
        if let path = found.path, ProviderUsageCoordinator.pending(path: path) { return }
        installation = found
        guard found.state == .found, let path = found.path,
              let fingerprint = ProviderBinaryFingerprint.read(path) else {
            clearSelection(detail: found.canInstall ? nil : "Choose a working executable to check for releases.")
            return
        }
        let currentKey = ProviderUpdateStore.key(provider: provider, path: path)
        if key != currentKey { notice = nil }
        key = currentKey
        record = store.read(currentKey)
        detail = nil
        guard let source = ProviderReleaseSource.source(provider: provider, hint: found.hint) else {
            notice = nil
            record.snapshot = nil
            detail = "Release checks are unavailable for this installation. See the provider’s official instructions."
            return
        }
        // Disk replacement must invalidate stale version comparisons even before
        // the daily network check is due. Keep the shared opt-out and Later policy.
        if let snapshot = record.snapshot, snapshot.fingerprint != fingerprint || snapshot.source != source {
            do {
                record = try store.modify(currentKey) {
                    $0.snapshot = nil
                    $0.nextCheckAt = nil
                }
            } catch {
                detail = "Could not save release-check settings. Try again."
                return
            }
            notice = nil
        }
        if !record.automaticChecks { notice = nil }
        guard record.shouldCheck(manual: manual, now: now()) else {
            if manual, let retryAfter = record.retryAfter {
                detail = ProviderReleaseError.rateLimited(retryAfter).localizedDescription
            }
            offerNotice(key: currentKey)
            return
        }
        do {
            guard let lock = try store.acquireCheck(currentKey) else {
                detail = manual ? "Another Rubien window is checking for releases. Check again shortly." : nil
                return
            }
            defer { withExtendedLifetime(lock) {} }
            // Another process may have completed a check before we got the lock.
            record = store.read(currentKey)
            guard record.shouldCheck(manual: manual, now: now()) else {
                offerNotice(key: currentKey)
                return
            }
            guard let installedRaw = await version(provider, path), let installed = ProviderReleaseVersion(installedRaw) else {
                throw ProviderReleaseError.installedVersionUnavailable
            }
            guard stillSelected(override: selected, path: path, fingerprint: fingerprint) else { return }
            guard !installed.isPrerelease else {
                notice = nil
                detail = "This is a prerelease installation. Check its release channel in the provider’s official instructions."
                return
            }
            let available = try await fetch(source)
            guard stillSelected(override: selected, path: path, fingerprint: fingerprint) else { return }
            let snapshot = ProviderReleaseSnapshot(installedVersion: installed.rawValue,
                availableVersion: available.rawValue, source: source, fingerprint: fingerprint, checkedAt: now())
            record = try store.modify(currentKey) { $0.succeeded(snapshot, jitter: jitter()) }
            offerNotice(key: currentKey)
        } catch is CancellationError {
            return
        } catch {
            guard stillSelected(override: selected, path: path, fingerprint: fingerprint) else { return }
            let retryAfter: Date?
            if case ProviderReleaseError.rateLimited(let date) = error { retryAfter = date } else { retryAfter = nil }
            let message = (error as? ProviderReleaseError)?.localizedDescription
                ?? "Could not check for releases. Check your connection and try again."
            do { record = try store.modify(currentKey) { $0.failed(message: message, now: now(), retryAfter: retryAfter) } }
            catch { detail = "Could not save the release-check result. Try again." }
            notice = nil
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let key else { return }
        do {
            record = try store.modify(key) {
                $0.automaticChecks = enabled
                if enabled { $0.nextCheckAt = nil }
            }
            if !enabled { notice = nil }
        } catch { detail = "Could not save release-check settings. Try again." }
    }

    func later() {
        guard let key, let notice else { return }
        do {
            record = try store.modify(key) {
                $0.deferredVersion = notice.availableVersion
                $0.deferredUntil = now().addingTimeInterval(7 * 86400)
            }
            self.notice = nil
        } catch { detail = "Could not save the reminder. Try again." }
    }

    func dismissNotice() { notice = nil }

    func invalidateSelection() {
        installation = nil
        clearSelection(detail: nil)
        if isChecking { selectionChangedDuringCheck = true }
    }

    private func offerNotice(key: String) {
        guard record.allowsNotice(now: now()), let snapshot = record.snapshot else {
            notice = nil
            return
        }
        let identity = key + ":" + snapshot.availableVersion
        guard !presentedNotices.contains(identity) else { return }
        presentedNotices.insert(identity)
        notice = snapshot
    }

    private func clearSelection(detail: String?) {
        key = nil
        record = .init()
        notice = nil
        self.detail = detail
    }

    private func stillSelected(override selected: String?, path: String, fingerprint: ProviderBinaryFingerprint) -> Bool {
        guard selected == override(), ProviderBinaryFingerprint.read(path) == fingerprint else {
            clearSelection(detail: nil)
            return false
        }
        return true
    }

    nonisolated static func readVersion(provider: AgentProviderKind, path: String) async -> String? {
        guard ProviderSetupStore.standard.maintenanceAvailability(provider: provider) == nil else { return nil }
        var environment = ProviderSetupEnvironment.make(provider: provider)
        environment["PATH"] = (path as NSString).deletingLastPathComponent + ":" + (environment["PATH"] ?? "")
        guard let result = try? await ProviderMaintenanceRunner.run(.init(executable: path, arguments: ["--version"],
            environment: environment, directory: FileManager.default.temporaryDirectory, timeout: 10)),
              result.exitCode == 0, !result.timedOut else { return nil }
        return ProviderSetupModel.version(from: result.output)
    }
}
#endif
