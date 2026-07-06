import Foundation

// MARK: - Turn serialization across windows (§4.1)
//
// The PDF reader and the web reader can be open on the SAME reference at once, and
// both sidebars can drive the same provider session. Two turns that `--resume` the
// same session id concurrently **fork the provider's session file** — the classic
// claude-code-chat footgun. This process-wide actor is the single serialization
// point: a turn claims `(provider, sessionID)` for its duration; a second window
// asking for the same key is told it is busy so the UI can show "busy in another
// window" instead of silently corrupting history.
//
// A brand-new conversation (`resumeSessionID == nil`) has no id to fork yet, so it
// is never keyed and always admitted — two fresh conversations simply diverge into
// two independent sessions, which is fine (design D4/§4.1).

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
    ///   `sessionID` (new conversation) is unkeyed and always admitted.
    func tryAcquire(provider: AgentProviderKind, sessionID: String?) -> Bool {
        guard let sessionID, !sessionID.isEmpty else { return true }
        let key = SessionKey(provider: provider, sessionID: sessionID)
        if busy.contains(key) { return false }
        busy.insert(key)
        return true
    }

    /// Release a slot claimed by `tryAcquire`. Safe to call for an unkeyed (`nil`)
    /// session or a slot that was never held.
    func release(provider: AgentProviderKind, sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        busy.remove(SessionKey(provider: provider, sessionID: sessionID))
    }

    /// Whether a turn currently holds `(provider, sessionID)` — the "busy in another
    /// window" signal for the composer status line.
    func isBusy(provider: AgentProviderKind, sessionID: String) -> Bool {
        busy.contains(SessionKey(provider: provider, sessionID: sessionID))
    }
}
