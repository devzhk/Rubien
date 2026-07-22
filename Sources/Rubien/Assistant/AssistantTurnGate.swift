import Foundation

// MARK: - Turn serialization across windows (§4.1)
//
// The PDF reader and the web reader can be open on the SAME reference at once, and
// both sidebars can drive the same provider session. Two turns that `--resume` the
// same session id concurrently **fork the provider's session file** — the classic
// claude-code-chat footgun. Codex has a second constraint: interactive windows share
// one app-server connection, whose notification parser admits one active turn. This
// process-wide actor is the single serialization point: Claude claims its resumed
// session; Codex claims its shared runtime. A conflicting window is told it is busy
// instead of corrupting history or displacing the live turn.
//
// A brand-new Claude conversation (`resumeSessionID == nil`) has no id to fork yet,
// so it remains unkeyed. A fresh Codex conversation still claims the shared runtime.

actor AssistantTurnGate {

    /// The process-wide shared gate. Every provider/window goes through this one
    /// instance; tests instantiate their own.
    static let shared = AssistantTurnGate()

    private struct SessionKey: Hashable, Sendable {
        let provider: AgentProviderKind
        let sessionID: String
    }

    private static let codexRuntimeID = "rubien:shared-interactive-runtime"

    private var busy: Set<SessionKey> = []

    init() {}

    /// Try to claim the turn slot for `(provider, sessionID)`.
    ///
    /// - Returns: `true` when claimed (the caller must `release` when the turn ends),
    ///   `false` when another turn already holds it (busy in another window). A `nil`
    ///   `sessionID` is unkeyed for Claude; Codex still claims its shared runtime.
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
        if provider == .codex {
            return SessionKey(provider: provider, sessionID: Self.codexRuntimeID)
        }
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return SessionKey(provider: provider, sessionID: sessionID)
    }
}
