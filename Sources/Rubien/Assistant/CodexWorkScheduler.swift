import Foundation

enum CodexMetadataKind: String, Sendable, Equatable {
    case availability
    case history
    case modelCatalog
}

/// Process-level settings fixed when `codex app-server` starts. Turns can share one
/// server concurrently only when their profiles match.
struct CodexRuntimeProfile: Sendable, Equatable {
    let webAccess: Bool
    let loadUserTools: Bool
    let readOnlyLibrary: Bool
    /// Canonical cwd used to resolve project-scoped Codex configuration and the
    /// scheduled-run MCP isolation catalog.
    let workingDirectory: String?

    init(
        webAccess: Bool,
        loadUserTools: Bool,
        readOnlyLibrary: Bool,
        workingDirectory: String? = nil
    ) {
        self.webAccess = webAccess
        self.loadUserTools = loadUserTools
        self.readOnlyLibrary = readOnlyLibrary
        self.workingDirectory = workingDirectory
    }

    static let interactiveDefault = CodexRuntimeProfile(
        webAccess: true,
        loadUserTools: false,
        readOnlyLibrary: false
    )

    static func historyDefault(workingDirectory: String) -> CodexRuntimeProfile {
        CodexRuntimeProfile(
            webAccess: true,
            loadUserTools: false,
            readOnlyLibrary: false,
            workingDirectory: workingDirectory
        )
    }
}

enum CodexWorkPurpose: Sendable, Equatable {
    case interactive(ownerID: UUID, conversationID: UUID?, turnID: UUID)
    case scheduled(runID: String, conversationID: UUID?, turnID: UUID)
    case metadata(kind: CodexMetadataKind, requestID: UUID)
}

struct CodexScheduledWork: Sendable, Equatable {
    let workID: UUID
    let purpose: CodexWorkPurpose
    let runtimeProfile: CodexRuntimeProfile?

    init(
        workID: UUID,
        purpose: CodexWorkPurpose,
        runtimeProfile: CodexRuntimeProfile? = nil
    ) {
        self.workID = workID
        self.purpose = purpose
        if case .metadata = purpose {
            self.runtimeProfile = nil
        } else {
            self.runtimeProfile = runtimeProfile ?? .interactiveDefault
        }
    }

    var isTurn: Bool {
        switch purpose {
        case .interactive, .scheduled: true
        case .metadata: false
        }
    }
}

/// Pure admission state machine for one broker-controlled Codex runtime.
///
/// Different conversations may run concurrently up to `maxConcurrentTurns`.
/// A process-level runtime-profile change remains a serialization boundary because
/// it requires replacing app-server. Work above the cap, or behind an incompatible
/// profile, queues FIFO instead of failing.
struct CodexWorkScheduler: Sendable {
    enum Admission: Sendable, Equatable {
        case admitted
        case queued
        case metadataUnavailable
        case preemptMetadataAndAdmit
    }

    static let defaultMaxConcurrentTurns = 4

    let maxConcurrentTurns: Int
    private(set) var activeTurns: [UUID: CodexScheduledWork] = [:]
    private(set) var reservedTurns: [UUID: CodexScheduledWork] = [:]
    private(set) var turnQueue: [CodexScheduledWork] = []
    private(set) var metadata: CodexScheduledWork?

    init(maxConcurrentTurns: Int = Self.defaultMaxConcurrentTurns) {
        self.maxConcurrentTurns = max(1, maxConcurrentTurns)
    }

    mutating func requestTurn(_ work: CodexScheduledWork) -> Admission {
        precondition(work.isTurn)
        if let reserved = reservedTurns.removeValue(forKey: work.workID) {
            activeTurns[work.workID] = reserved
            return .admitted
        }
        if activeTurns[work.workID] != nil {
            return .admitted
        }
        if canAdmitImmediately(work) {
            activeTurns[work.workID] = work
            if metadata != nil {
                metadata = nil
                return .preemptMetadataAndAdmit
            }
            return .admitted
        }
        if !turnQueue.contains(where: { $0.workID == work.workID }) {
            turnQueue.append(work)
        }
        return .queued
    }

    mutating func beginMetadata(_ work: CodexScheduledWork) -> Admission {
        precondition(!work.isTurn)
        guard !hasTurnWork else { return .metadataUnavailable }
        // Metadata is best effort. A newer query supersedes the older lease;
        // the broker generation closes its waiters and prevents stale results.
        metadata = work
        return .admitted
    }

    /// Releases one active slot and reserves every newly runnable queued turn. A
    /// profile transition can fill the whole runtime from one queue head.
    @discardableResult
    mutating func finishTurn(workID: UUID) -> [CodexScheduledWork] {
        guard activeTurns.removeValue(forKey: workID) != nil else { return [] }
        return reserveAvailableTurns()
    }

    struct Cancellation: Sendable {
        let didCancel: Bool
        let newlyReserved: [CodexScheduledWork]
    }

    mutating func cancel(workID: UUID) -> Cancellation {
        if reservedTurns.removeValue(forKey: workID) != nil {
            return Cancellation(
                didCancel: true,
                newlyReserved: reserveAvailableTurns()
            )
        }
        if let index = turnQueue.firstIndex(where: { $0.workID == workID }) {
            turnQueue.remove(at: index)
            return Cancellation(
                didCancel: true,
                newlyReserved: reserveAvailableTurns()
            )
        }
        if metadata?.workID == workID {
            metadata = nil
            return Cancellation(didCancel: true, newlyReserved: [])
        }
        return Cancellation(didCancel: false, newlyReserved: [])
    }

    mutating func finishMetadata(workID: UUID) {
        if metadata?.workID == workID { metadata = nil }
    }

    mutating func removeAllPending() -> [CodexScheduledWork] {
        let removed = Array(reservedTurns.values) + turnQueue
        reservedTurns.removeAll()
        turnQueue.removeAll()
        metadata = nil
        return removed
    }

    var hasTurnWork: Bool {
        !activeTurns.isEmpty || !reservedTurns.isEmpty || !turnQueue.isEmpty
    }

    private func canAdmitImmediately(_ work: CodexScheduledWork) -> Bool {
        guard turnQueue.isEmpty,
              activeTurns.count + reservedTurns.count < maxConcurrentTurns,
              let profile = work.runtimeProfile else {
            return false
        }
        let existingProfiles = activeTurns.values.compactMap(\.runtimeProfile)
            + reservedTurns.values.compactMap(\.runtimeProfile)
        return existingProfiles.allSatisfy { $0 == profile }
    }

    private mutating func reserveAvailableTurns() -> [CodexScheduledWork] {
        guard activeTurns.count + reservedTurns.count < maxConcurrentTurns,
              !turnQueue.isEmpty else {
            return []
        }
        let existingProfile = activeTurns.values.first?.runtimeProfile
            ?? reservedTurns.values.first?.runtimeProfile
        let selectedProfile = existingProfile ?? turnQueue[0].runtimeProfile
        guard let selectedProfile else { return [] }

        var newlyReserved: [CodexScheduledWork] = []
        while activeTurns.count + reservedTurns.count < maxConcurrentTurns,
              let next = turnQueue.first,
              next.runtimeProfile == selectedProfile {
            turnQueue.removeFirst()
            reservedTurns[next.workID] = next
            newlyReserved.append(next)
        }
        return newlyReserved
    }
}
