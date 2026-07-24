import Foundation

enum CodexMetadataKind: String, Sendable, Equatable {
    case availability
    case history
    case modelCatalog
}

/// Process-level settings fixed when `codex app-server` starts. New-thread Apps
/// and Rubien MCP posture deliberately do not live here; they ride thread config
/// and therefore do not split a process batch. Cwd only remains process-scoped
/// while installed plugins are enabled because their project discovery has not
/// yet been proven thread-local.
struct CodexRuntimeProfile: Sendable, Equatable {
    let webAccess: Bool
    let pluginWorkingDirectory: String?
    var pluginsEnabled: Bool { pluginWorkingDirectory != nil }

    init(webAccess: Bool) {
        self.webAccess = webAccess
        self.pluginWorkingDirectory = nil
    }

    init(webAccess: Bool, pluginWorkingDirectory: String) {
        precondition(
            !pluginWorkingDirectory.isEmpty,
            "plugin-enabled Codex profiles require a workspace"
        )
        self.webAccess = webAccess
        self.pluginWorkingDirectory = URL(
            fileURLWithPath: pluginWorkingDirectory
        ).standardizedFileURL.path
    }

    static let interactiveDefault = CodexRuntimeProfile(
        webAccess: true
    )

    static let metadataDefault = CodexRuntimeProfile(
        webAccess: true
    )

    func delta(from other: CodexRuntimeProfile) -> CodexRuntimeProfileDelta {
        var delta: CodexRuntimeProfileDelta = []
        if webAccess != other.webAccess {
            delta.insert(.webAccess)
        }
        if pluginsEnabled != other.pluginsEnabled {
            delta.insert(.pluginToggle)
        } else if pluginsEnabled,
                  pluginWorkingDirectory != other.pluginWorkingDirectory {
            delta.insert(.pluginWorkingDirectory)
        }
        return delta
    }
}

/// Process-level dimensions that force Codex work into a different app-server
/// batch. Multiple dimensions may differ for one transition.
struct CodexRuntimeProfileDelta: OptionSet, Sendable {
    let rawValue: UInt8

    static let webAccess = Self(rawValue: 1 << 0)
    static let pluginToggle = Self(rawValue: 1 << 1)
    static let pluginWorkingDirectory = Self(rawValue: 1 << 2)
}

enum CodexTurnQueueReason: Sendable, Equatable {
    case capacity
    case runtimeProfile(CodexRuntimeProfileDelta)
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
        case queued(CodexTurnQueueReason)
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
        guard let reason = blockingReason(for: work) else {
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
        return .queued(reason)
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

    /// Current blocker for every queued turn. A full batch is ordinary capacity.
    /// Once a slot opens, an incompatible FIFO head reclassifies the remaining
    /// wait as process-profile serialization until the active batch drains.
    var queuedReasons: [UUID: CodexTurnQueueReason] {
        var reasons: [UUID: CodexTurnQueueReason] = [:]
        reasons.reserveCapacity(turnQueue.count)
        for work in turnQueue {
            reasons[work.workID] = blockingReason(for: work) ?? .capacity
        }
        return reasons
    }

    /// One authoritative decision for admission and metrics classification.
    /// A compatible turn behind an incompatible FIFO head is profile-blocked:
    /// without that pending transition it could join the live batch as soon as
    /// capacity permits.
    private func blockingReason(
        for work: CodexScheduledWork
    ) -> CodexTurnQueueReason? {
        guard let requestedProfile = work.runtimeProfile else {
            return .capacity
        }
        if activeTurns.count + reservedTurns.count >= maxConcurrentTurns {
            return .capacity
        }
        let activeProfile = activeTurns.values.first?.runtimeProfile
            ?? reservedTurns.values.first?.runtimeProfile
        if let activeProfile {
            if let headProfile = turnQueue.first?.runtimeProfile {
                let headDelta = headProfile.delta(from: activeProfile)
                if !headDelta.isEmpty {
                    return .runtimeProfile(headDelta)
                }
                return .capacity
            }
            let requestedDelta = requestedProfile.delta(from: activeProfile)
            if !requestedDelta.isEmpty {
                return .runtimeProfile(requestedDelta)
            }
        } else if let headProfile = turnQueue.first?.runtimeProfile {
            let headDelta = requestedProfile.delta(from: headProfile)
            if !headDelta.isEmpty {
                return .runtimeProfile(headDelta)
            }
            return .capacity
        }
        return nil
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
