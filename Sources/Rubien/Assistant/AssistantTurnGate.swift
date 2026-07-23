import Foundation

// MARK: - Turn serialization across windows (§4.1)
//
// The PDF reader and the web reader can be open on the SAME reference at once, and
// both sidebars can drive the same provider session. Two turns that resume the same
// session concurrently can fork or reorder its history. This process-wide actor
// serializes each resumed provider session while allowing independent conversations
// to run concurrently.
//
// A brand-new conversation (`resumeSessionID == nil`) has no provider id to conflict
// with yet, so it remains unkeyed. Each provider wrapper still serializes its own
// early sends before the provider publishes that id.

actor AssistantTurnGate {

    /// The process-wide shared gate. Every provider/window goes through this one
    /// instance; tests instantiate their own.
    static let shared = AssistantTurnGate()

    private struct SessionKey: Hashable, Sendable {
        let provider: AgentProviderKind
        let sessionID: String
    }

    private var busy: Set<SessionKey> = []

    init() {}

    /// Try to claim the turn slot for `(provider, sessionID)`.
    ///
    /// - Returns: `true` when claimed (the caller must `release` when the turn ends),
    ///   `false` when another turn already holds it (busy in another window). A `nil`
    ///   `sessionID` is unkeyed for either provider.
    func tryAcquire(provider: AgentProviderKind, sessionID: String?) -> Bool {
        guard let key = key(provider: provider, sessionID: sessionID) else { return true }
        if busy.contains(key) { return false }
        busy.insert(key)
        return true
    }

    /// Release a slot claimed by `tryAcquire`. Safe to call for an unkeyed (`nil`)
    /// session or a slot that was never held.
    func release(provider: AgentProviderKind, sessionID: String?) {
        guard let key = key(provider: provider, sessionID: sessionID) else { return }
        busy.remove(key)
    }

    /// Whether a turn currently holds `(provider, sessionID)` — the "busy in another
    /// window" signal for the composer status line.
    func isBusy(provider: AgentProviderKind, sessionID: String) -> Bool {
        guard let key = key(provider: provider, sessionID: sessionID) else { return false }
        return busy.contains(key)
    }

    private func key(
        provider: AgentProviderKind,
        sessionID: String?
    ) -> SessionKey? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return SessionKey(provider: provider, sessionID: sessionID)
    }
}
