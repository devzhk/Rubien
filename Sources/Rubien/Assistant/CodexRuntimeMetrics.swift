import Foundation

/// Local aggregate evidence for the residual Codex process-profile decision.
/// This deliberately contains no per-turn identifiers, profile values, paths,
/// prompts, or model output.
struct CodexRuntimeMetricsSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var observationStartedAt: Date
    var turnRequests = 0

    var capacityQueueIncidents = 0
    var capacityQueueWaitMilliseconds: Int64 = 0

    var profileQueueIncidents = 0
    var profileQueueWaitMilliseconds: Int64 = 0
    var profileQueueWebAccessIncidents = 0
    var profileQueuePluginToggleIncidents = 0
    var profileQueuePluginWorkingDirectoryIncidents = 0

    var profileRespawns = 0
    var profileRespawnWebAccessIncidents = 0
    var profileRespawnPluginToggleIncidents = 0
    var profileRespawnPluginWorkingDirectoryIncidents = 0

    init(observationStartedAt: Date) {
        self.observationStartedAt = observationStartedAt
    }
}

struct CodexRuntimeQueueObservation: Sendable {
    fileprivate let observationGeneration: UInt64
    fileprivate var currentReason: CodexTurnQueueReason
    fileprivate var segmentStartedAtNanoseconds: UInt64
    fileprivate var capacityWaitNanoseconds: UInt64 = 0
    fileprivate var profileWaitNanoseconds: UInt64 = 0
    fileprivate var profileDelta: CodexRuntimeProfileDelta = []
    fileprivate var experiencedCapacity = false
    fileprivate var experiencedProfile = false

    /// Capacity waiting ends when the scheduler reserves a slot. A profile wait
    /// remains user-visible until the replacement app-server is handshaked.
    var waitsForRuntimeProfileReadiness: Bool {
        if case .runtimeProfile = currentReason { return true }
        return false
    }
}

/// Process-local evidence that a turn was accepted during one observation
/// period. It deliberately carries no turn or profile identity.
struct CodexRuntimeMetricsTurnTicket: Sendable {
    fileprivate let observationGeneration: UInt64
}

/// Thread-safe because Settings can read/reset while the broker actor records.
/// UserDefaults is local-only; these counters never enter the library database or
/// CloudKit sync.
final class CodexRuntimeMetricsStore: @unchecked Sendable {
    static let shared = CodexRuntimeMetricsStore()

    static let defaultStorageKey = "Rubien.assistant.codex.runtimeMetrics.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let wallClockNow: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> UInt64
    private var storedSnapshot: CodexRuntimeMetricsSnapshot
    /// In-flight queue observations are process-local, so a transient generation
    /// is sufficient to prevent a pre-reset timer from contaminating a new period.
    private var observationGeneration: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = CodexRuntimeMetricsStore.defaultStorageKey,
        wallClockNow: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.wallClockNow = wallClockNow
        self.monotonicNow = monotonicNow
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
            CodexRuntimeMetricsSnapshot.self,
            from: data
           ),
           decoded.schemaVersion == CodexRuntimeMetricsSnapshot.currentSchemaVersion {
            self.storedSnapshot = decoded
        } else {
            self.storedSnapshot = CodexRuntimeMetricsSnapshot(
                observationStartedAt: wallClockNow()
            )
        }
    }

    func snapshot() -> CodexRuntimeMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    @discardableResult
    func recordTurnRequest() -> CodexRuntimeMetricsTurnTicket {
        lock.lock()
        defer { lock.unlock() }
        Self.increment(&storedSnapshot.turnRequests)
        let ticket = CodexRuntimeMetricsTurnTicket(
            observationGeneration: observationGeneration
        )
        persistLocked()
        return ticket
    }

    func beginQueue(
        reason: CodexTurnQueueReason,
        ticket: CodexRuntimeMetricsTurnTicket? = nil
    ) -> CodexRuntimeQueueObservation {
        lock.lock()
        defer { lock.unlock() }
        return CodexRuntimeQueueObservation(
            observationGeneration: ticket?.observationGeneration
                ?? observationGeneration,
            currentReason: reason,
            segmentStartedAtNanoseconds: monotonicNow()
        )
    }

    func transitionQueue(
        _ observation: CodexRuntimeQueueObservation,
        to reason: CodexTurnQueueReason
    ) -> CodexRuntimeQueueObservation {
        guard observation.currentReason != reason else { return observation }
        var transitioned = observation
        let transitionedAt = monotonicNow()
        Self.closeCurrentSegment(
            &transitioned,
            atNanoseconds: transitionedAt
        )
        transitioned.currentReason = reason
        transitioned.segmentStartedAtNanoseconds = transitionedAt
        return transitioned
    }

    func finishQueue(_ observation: CodexRuntimeQueueObservation?) {
        guard let observation else { return }
        var finished = observation
        Self.closeCurrentSegment(
            &finished,
            atNanoseconds: monotonicNow()
        )
        lock.lock()
        defer { lock.unlock() }
        guard finished.observationGeneration == observationGeneration else {
            return
        }
        if finished.experiencedCapacity {
            Self.increment(&storedSnapshot.capacityQueueIncidents)
            Self.add(
                Self.milliseconds(fromNanoseconds: finished.capacityWaitNanoseconds),
                to: &storedSnapshot.capacityQueueWaitMilliseconds
            )
        }
        if finished.experiencedProfile {
            Self.increment(&storedSnapshot.profileQueueIncidents)
            Self.add(
                Self.milliseconds(fromNanoseconds: finished.profileWaitNanoseconds),
                to: &storedSnapshot.profileQueueWaitMilliseconds
            )
            Self.recordProfileDelta(
                finished.profileDelta,
                in: &storedSnapshot,
                kind: .queue
            )
        }
        persistLocked()
    }

    func recordProfileRespawn(
        _ delta: CodexRuntimeProfileDelta,
        ticket: CodexRuntimeMetricsTurnTicket? = nil
    ) {
        guard !delta.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let ticket,
           ticket.observationGeneration != observationGeneration {
            return
        }
        Self.increment(&storedSnapshot.profileRespawns)
        Self.recordProfileDelta(
            delta,
            in: &storedSnapshot,
            kind: .respawn
        )
        persistLocked()
    }

    @discardableResult
    func reset() -> CodexRuntimeMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        observationGeneration &+= 1
        storedSnapshot = CodexRuntimeMetricsSnapshot(
            observationStartedAt: wallClockNow()
        )
        persistLocked()
        return storedSnapshot
    }

    func exportJSON() -> String {
        let value = snapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(storedSnapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func increment(_ value: inout Int) {
        if value < Int.max {
            value += 1
        }
    }

    private static func add(_ addition: Int64, to value: inout Int64) {
        if addition >= Int64.max - value {
            value = Int64.max
        } else {
            value += addition
        }
    }

    private static func closeCurrentSegment(
        _ observation: inout CodexRuntimeQueueObservation,
        atNanoseconds end: UInt64
    ) {
        let elapsed = end >= observation.segmentStartedAtNanoseconds
            ? end - observation.segmentStartedAtNanoseconds
            : 0
        switch observation.currentReason {
        case .capacity:
            observation.experiencedCapacity = true
            observation.capacityWaitNanoseconds = adding(
                elapsed,
                to: observation.capacityWaitNanoseconds
            )
        case .runtimeProfile(let delta):
            observation.experiencedProfile = true
            observation.profileWaitNanoseconds = adding(
                elapsed,
                to: observation.profileWaitNanoseconds
            )
            observation.profileDelta.formUnion(delta)
        }
    }

    private static func adding(_ addition: UInt64, to value: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(addition)
        return overflow ? UInt64.max : sum
    }

    private static func milliseconds(fromNanoseconds value: UInt64) -> Int64 {
        let milliseconds = value / 1_000_000
        return milliseconds > UInt64(Int64.max)
            ? Int64.max
            : Int64(milliseconds)
    }

    private enum ProfileMetricKind {
        case queue
        case respawn
    }

    private static func recordProfileDelta(
        _ delta: CodexRuntimeProfileDelta,
        in snapshot: inout CodexRuntimeMetricsSnapshot,
        kind: ProfileMetricKind
    ) {
        if delta.contains(.webAccess) {
            switch kind {
            case .queue:
                increment(&snapshot.profileQueueWebAccessIncidents)
            case .respawn:
                increment(&snapshot.profileRespawnWebAccessIncidents)
            }
        }
        if delta.contains(.pluginToggle) {
            switch kind {
            case .queue:
                increment(&snapshot.profileQueuePluginToggleIncidents)
            case .respawn:
                increment(&snapshot.profileRespawnPluginToggleIncidents)
            }
        }
        if delta.contains(.pluginWorkingDirectory) {
            switch kind {
            case .queue:
                increment(
                    &snapshot.profileQueuePluginWorkingDirectoryIncidents
                )
            case .respawn:
                increment(
                    &snapshot.profileRespawnPluginWorkingDirectoryIncidents
                )
            }
        }
    }

}

enum CodexRuntimeMetricsFormatting {
    static func duration(milliseconds: Int64) -> String {
        let bounded = max(0, milliseconds)
        if bounded < 1_000 {
            return "\(bounded) ms"
        }
        let seconds = Double(bounded) / 1_000
        if seconds < 60 {
            return String(
                format: "%.1f s",
                locale: Locale(identifier: "en_US_POSIX"),
                seconds
            )
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(
                format: "%.1f min",
                locale: Locale(identifier: "en_US_POSIX"),
                minutes
            )
        }
        return String(
            format: "%.1f h",
            locale: Locale(identifier: "en_US_POSIX"),
            minutes / 60
        )
    }
}
