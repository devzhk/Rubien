#if os(macOS)
import AppKit
import Combine

@MainActor
final class ProviderUpdateScheduler: ObservableObject {
    private var maintenanceTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var launchedAt: Date?

    func start() {
        guard task == nil else { return }
        launchedAt = Date()
        maintenanceTask = Task {
            while !Task.isCancelled {
                await CodexSharedConnectionRegistry.shared.retireIdleForProviderUpdate()
                await ProviderUpdateActionModel.codex.considerAutomaticUpdate()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.checkDue() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.checkDue() } })
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            while !Task.isCancelled {
                await self?.checkDue()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    private func checkDue() async {
        guard let launchedAt, Date().timeIntervalSince(launchedAt) >= 30 else { return }
        await ProviderUpdateModel.codex.check()
        await ProviderUpdateModel.claude.check()
        for provider: AgentProviderKind in [.codex, .claude] {
            let model = ProviderUpdateModel.shared(provider)
            await ProviderUpdateActionModel.shared(provider).prepare(installation: model.installation, snapshot: model.record.snapshot)
        }
    }

    deinit {
        task?.cancel()
        maintenanceTask?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
#endif
