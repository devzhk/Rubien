/// Orders CKSyncEngine state persistence behind durable application of the
/// fetched records represented by that state.
///
/// CKSyncEngine advances its in-memory change tokens even when application
/// persistence fails. Apple requires state serialization to be persisted
/// alongside the fetched changes that precede it. During a fetch, this gate
/// stages the newest serialization until every fetched batch commits. A local
/// apply failure discards the staged state and blocks later serializations
/// until the engine is recreated from the last known-good state on disk.
struct FetchStatePersistenceGate<Value: Sendable>: Sendable {
    private(set) var isFetchInProgress = false
    private(set) var requiresEngineRecovery = false
    private(set) var fullHistoryReplayPending: Bool
    private var stagedValue: Value?

    init(fullHistoryReplayPending: Bool = false) {
        self.fullHistoryReplayPending = fullHistoryReplayPending
    }

    var canFinalizeFetchedZone: Bool {
        isFetchInProgress && !requiresEngineRecovery
    }

    var shouldReconcileTerminalOrphans: Bool {
        canFinalizeFetchedZone && fullHistoryReplayPending
    }

    mutating func beginFetch() {
        guard !isFetchInProgress else { return }
        isFetchInProgress = true
        if !requiresEngineRecovery {
            stagedValue = nil
        }
    }

    /// Returns a value only when it is safe to persist immediately. Values
    /// received during a fetch are staged until `finishFetch()`.
    mutating func receiveStateUpdate(_ value: Value) -> Value? {
        if isFetchInProgress || requiresEngineRecovery {
            stagedValue = value
            return nil
        }
        return value
    }

    mutating func markFetchedChangesApplyFailed() {
        requiresEngineRecovery = true
        stagedValue = nil
    }

    /// Returns the newest staged value after a successful fetch. When any
    /// fetched batch failed, no advanced serialization is allowed to escape.
    mutating func finishFetch() -> Value? {
        isFetchInProgress = false
        guard !requiresEngineRecovery else {
            stagedValue = nil
            return nil
        }
        defer { stagedValue = nil }
        return stagedValue
    }

    /// Call only after discarding the advanced in-memory engine and before
    /// recreating it from the last durable serialization.
    mutating func resetAfterEngineRecovery() {
        isFetchInProgress = false
        requiresEngineRecovery = false
        stagedValue = nil
    }

    mutating func markFullHistoryReplayCompleted() {
        fullHistoryReplayPending = false
    }

    mutating func markDurableStateReset() {
        isFetchInProgress = false
        requiresEngineRecovery = false
        fullHistoryReplayPending = true
        stagedValue = nil
    }
}
