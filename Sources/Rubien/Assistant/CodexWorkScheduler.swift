import Foundation

enum CodexMetadataKind: String, Sendable, Equatable {
    case availability
    case history
    case modelCatalog
}

enum CodexWorkPurpose: Sendable, Equatable {
    case interactive(ownerID: UUID, conversationID: UUID?, turnID: UUID)
    case scheduled(runID: String, conversationID: UUID?, turnID: UUID)
    case metadata(kind: CodexMetadataKind, requestID: UUID)
}

struct CodexScheduledWork: Sendable, Equatable {
    let workID: UUID
    let purpose: CodexWorkPurpose

    var isScheduledTurn: Bool {
        if case .scheduled = purpose { return true }
        return false
    }

    var isTurn: Bool {
        switch purpose {
        case .interactive, .scheduled: true
        case .metadata: false
        }
    }
}

/// Pure admission state machine for one broker-controlled Codex runtime. It
/// keeps a claimed scheduled run non-starvable without coupling the policy to
/// JSON-RPC, process, or transcript code.
struct CodexWorkScheduler: Sendable {
    enum Admission: Sendable, Equatable {
        case admitted
        case queued
        case busy
        case metadataUnavailable
        case preemptMetadataAndAdmit
    }

    private(set) var activeTurn: CodexScheduledWork?
    private(set) var reservedTurn: CodexScheduledWork?
    private(set) var scheduledQueue: [CodexScheduledWork] = []
    private(set) var metadata: CodexScheduledWork?

    mutating func requestTurn(_ work: CodexScheduledWork) -> Admission {
        precondition(work.isTurn)
        if reservedTurn?.workID == work.workID {
            reservedTurn = nil
            activeTurn = work
            return .admitted
        }
        if activeTurn != nil || reservedTurn != nil {
            guard work.isScheduledTurn else { return .busy }
            if !scheduledQueue.contains(where: { $0.workID == work.workID }) {
                scheduledQueue.append(work)
            }
            return .queued
        }
        activeTurn = work
        if metadata != nil {
            metadata = nil
            return .preemptMetadataAndAdmit
        }
        return .admitted
    }

    mutating func beginMetadata(_ work: CodexScheduledWork) -> Admission {
        precondition(!work.isTurn)
        guard activeTurn == nil, reservedTurn == nil, scheduledQueue.isEmpty else {
            return .metadataUnavailable
        }
        // Metadata is best effort. A newer query supersedes the older lease;
        // the broker generation closes its waiters and prevents stale results.
        metadata = work
        return .admitted
    }

    @discardableResult
    mutating func finishTurn(workID: UUID) -> CodexScheduledWork? {
        guard activeTurn?.workID == workID else { return nil }
        activeTurn = nil
        guard reservedTurn == nil, !scheduledQueue.isEmpty else { return nil }
        let next = scheduledQueue.removeFirst()
        reservedTurn = next
        return next
    }

    mutating func finishMetadata(workID: UUID) {
        if metadata?.workID == workID { metadata = nil }
    }

    @discardableResult
    mutating func cancel(workID: UUID) -> Bool {
        if reservedTurn?.workID == workID {
            reservedTurn = nil
            reserveNextIfPossible()
            return true
        }
        if let index = scheduledQueue.firstIndex(where: { $0.workID == workID }) {
            scheduledQueue.remove(at: index)
            return true
        }
        if metadata?.workID == workID {
            metadata = nil
            return true
        }
        return false
    }

    mutating func removeAllPending() -> [CodexScheduledWork] {
        var removed = scheduledQueue
        if let reservedTurn { removed.insert(reservedTurn, at: 0) }
        scheduledQueue.removeAll()
        reservedTurn = nil
        metadata = nil
        return removed
    }

    var hasTurnWork: Bool {
        activeTurn != nil || reservedTurn != nil || !scheduledQueue.isEmpty
    }

    private mutating func reserveNextIfPossible() {
        guard activeTurn == nil, reservedTurn == nil, !scheduledQueue.isEmpty else { return }
        reservedTurn = scheduledQueue.removeFirst()
    }
}
