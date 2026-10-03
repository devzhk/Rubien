#if os(macOS)
import AppKit

/// AppKit keeps the termination request pending while mutations finish. Waiting
/// actions are cancelled, and no action can restart during this handoff.
@MainActor
final class ProviderUpdateTermination {
    private var waiting = false

    func request(actions: [ProviderUpdateActionModel], reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        if waiting { return .terminateLater }
        for action in actions { action.beginTermination() }
        guard actions.contains(where: { $0.isRunning }) else { return .terminateNow }
        waiting = true
        Task {
            for action in actions { await action.finishForTermination() }
            reply()
        }
        return .terminateLater
    }
}
#endif
