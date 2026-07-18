#if os(macOS)
import Foundation

/// Process-wide ownership for Claude sessions. The UI gate protects only the
/// visible turn; this lease remains held until the old process leader is reaped,
/// so another window cannot resume the same session during cancellation cleanup.
actor ClaudeSessionLeaseCoordinator {
    static let shared = ClaudeSessionLeaseCoordinator()

    struct Grant: Sendable, Equatable {
        fileprivate let canonicalID: UUID
        fileprivate let ownershipID: UUID
        let latestSessionID: String?
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Grant?, Never>
    }

    private final class Session {
        let canonicalID: UUID
        var conversationIDs: Set<UUID> = []
        var aliases: Set<String> = []
        var latestSessionID: String?
        var owner: UUID?
        var waiters: [Waiter] = []
        var lastUsed = Date()

        init(canonicalID: UUID) { self.canonicalID = canonicalID }
    }

    private var sessions: [UUID: Session] = [:]
    private var conversationIndex: [UUID: UUID] = [:]
    private var aliasIndex: [String: UUID] = [:]
    private let retainedSessionLimit = 256

    func acquire(
        waiterID: UUID,
        conversationID: UUID?,
        resumeSessionID: String?
    ) async -> Grant? {
        await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { continuation in
                // The cancellation handler can run before this actor gets to
                // register the waiter. Recheck while isolated so either we resume
                // here or the queued cancellation removes the registered waiter.
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let session = session(
                    conversationID: conversationID,
                    resumeSessionID: resumeSessionID)
                session.lastUsed = Date()
                if session.owner == nil {
                    let ownershipID = UUID()
                    session.owner = ownershipID
                    continuation.resume(returning: Grant(
                        canonicalID: session.canonicalID,
                        ownershipID: ownershipID,
                        latestSessionID: session.latestSessionID ?? resumeSessionID))
                } else {
                    session.waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func cancel(waiterID: UUID) {
        for session in sessions.values {
            guard let index = session.waiters.firstIndex(where: { $0.id == waiterID }) else {
                continue
            }
            let waiter = session.waiters.remove(at: index)
            waiter.continuation.resume(returning: nil)
            return
        }
    }

    func update(_ grant: Grant, latestSessionID: String?) {
        guard let session = sessions[grant.canonicalID],
              session.owner == grant.ownershipID
        else { return }
        record(latestSessionID, on: session)
    }

    func release(_ grant: Grant, latestSessionID: String?) {
        guard let session = sessions[grant.canonicalID],
              session.owner == grant.ownershipID
        else { return }
        record(latestSessionID, on: session)
        session.lastUsed = Date()
        if session.waiters.isEmpty {
            session.owner = nil
            pruneInactiveSessionsIfNeeded()
            return
        }
        let waiter = session.waiters.removeFirst()
        let nextOwnershipID = UUID()
        session.owner = nextOwnershipID
        waiter.continuation.resume(returning: Grant(
            canonicalID: session.canonicalID,
            ownershipID: nextOwnershipID,
            latestSessionID: session.latestSessionID))
    }

    private func session(
        conversationID: UUID?, resumeSessionID: String?
    ) -> Session {
        let canonicalID = conversationID.flatMap { conversationIndex[$0] }
            ?? resumeSessionID.flatMap { aliasIndex[$0] }
            ?? UUID()
        let value: Session
        if let existing = sessions[canonicalID] {
            value = existing
        } else {
            value = Session(canonicalID: canonicalID)
            sessions[canonicalID] = value
        }
        if let conversationID {
            value.conversationIDs.insert(conversationID)
            conversationIndex[conversationID] = canonicalID
        }
        if let resumeSessionID, !resumeSessionID.isEmpty {
            value.aliases.insert(resumeSessionID)
            value.latestSessionID = value.latestSessionID ?? resumeSessionID
            aliasIndex[resumeSessionID] = canonicalID
        }
        return value
    }

    private func record(_ sessionID: String?, on session: Session) {
        guard let sessionID, !sessionID.isEmpty else { return }
        session.latestSessionID = sessionID
        session.aliases.insert(sessionID)
        aliasIndex[sessionID] = session.canonicalID
    }

    private func pruneInactiveSessionsIfNeeded() {
        guard sessions.count > retainedSessionLimit else { return }
        let removable = sessions.values
            .filter { $0.owner == nil && $0.waiters.isEmpty }
            .sorted { $0.lastUsed < $1.lastUsed }
        for session in removable.prefix(sessions.count - retainedSessionLimit) {
            sessions[session.canonicalID] = nil
            for conversationID in session.conversationIDs {
                if conversationIndex[conversationID] == session.canonicalID {
                    conversationIndex[conversationID] = nil
                }
            }
            for alias in session.aliases where aliasIndex[alias] == session.canonicalID {
                aliasIndex[alias] = nil
            }
        }
    }
}
#endif
