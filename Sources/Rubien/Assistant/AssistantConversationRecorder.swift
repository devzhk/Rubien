#if os(macOS)
import Foundation
import RubienCore

struct AssistantConversationCapture {
    let recorder: AssistantConversationRecorder
    let identityObserver: AgentIdentityObserver
}

/// The single composition root for one durable provider turn. Keeping the lease,
/// recorder, and identity observer together prevents execution identity from
/// drifting between interactive and scheduled call sites.
enum AssistantConversationService {
    static func makeCapture(
        database: AppDatabase,
        attempt: AssistantAttemptIdentity,
        provider: AssistantProvider,
        workspaceURL: URL,
        conversationID: String,
        turnID: String,
        turnOrdinal: Int,
        mode: AssistantConversationRecorder.Mode,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AssistantConversationCapture {
        let lease = AssistantConversationExecutionLease(attempt: attempt)
        let recorder = AssistantConversationRecorder(
            database: database,
            lease: lease,
            provider: provider,
            workspaceURL: workspaceURL,
            conversationID: conversationID,
            turnID: turnID,
            turnOrdinal: turnOrdinal,
            mode: mode,
            now: now
        )
        let identityObserver = AgentIdentityObserver(
            onSessionStarted: { sessionID, runtimeGeneration in
                try? await recorder.record(AgentEventEnvelope(
                    attempt: AssistantAttemptIdentity(
                        conversationID: attempt.conversationID,
                        conversationEpoch: attempt.conversationEpoch,
                        turnID: attempt.turnID,
                        workID: attempt.workID,
                        runtimeGeneration: runtimeGeneration
                    ),
                    providerItemID: nil,
                    event: .sessionStarted(sessionID: sessionID)
                ))
            },
            onClosed: {
                await recorder.closeIdentity()
            }
        )
        return AssistantConversationCapture(
            recorder: recorder,
            identityObserver: identityObserver
        )
    }
}

fileprivate actor AssistantConversationExecutionLease {
    let attempt: AssistantAttemptIdentity
    private var contentOpen = true
    private var identityOpen = true
    private var runtimeGeneration: Int?

    init(attempt: AssistantAttemptIdentity) {
        self.attempt = attempt
        runtimeGeneration = attempt.runtimeGeneration
    }

    func acceptsContent(_ candidate: AssistantAttemptIdentity) -> Bool {
        contentOpen && acceptsAttempt(candidate)
    }

    func acceptsIdentity(_ candidate: AssistantAttemptIdentity) -> Bool {
        identityOpen && acceptsAttempt(candidate)
    }

    func closeContent() { contentOpen = false }
    func closeIdentity() { identityOpen = false }
    func revoke() {
        contentOpen = false
        identityOpen = false
    }

    private func acceptsAttempt(_ candidate: AssistantAttemptIdentity) -> Bool {
        guard candidate.conversationID == attempt.conversationID,
              candidate.conversationEpoch == attempt.conversationEpoch,
              candidate.turnID == attempt.turnID,
              candidate.workID == attempt.workID else { return false }
        if let runtimeGeneration {
            return candidate.runtimeGeneration == runtimeGeneration
        }
        if let candidateGeneration = candidate.runtimeGeneration {
            runtimeGeneration = candidateGeneration
        }
        return true
    }
}

/// Durable, provider-neutral projection of one Assistant turn. It buffers text
/// deltas to bound SQLite write pressure while persisting semantic events in
/// provider order.
actor AssistantConversationRecorder {
    enum Mode: Sendable, Equatable {
        case interactive
        case scheduled(runID: String)
    }

    private struct OpenTool {
        let entryID: String
        let sequence: Int
        let providerItemID: String?
        let name: String
        let detail: String?
        let createdAt: Date
    }

    private let database: AppDatabase
    private let lease: AssistantConversationExecutionLease
    private let provider: AssistantProvider
    private let workspaceURL: URL
    private let conversationID: String
    private let turnID: String
    private let turnOrdinal: Int
    private let mode: Mode
    private let now: @Sendable () -> Date

    private var nextSequence = 1
    private var identityEventOrdinal = 0
    private struct IdentityFingerprint: Equatable {
        let sessionID: String
        let attempt: AssistantAttemptIdentity
    }
    private var lastIdentityFingerprint: IdentityFingerprint?
    private var assistantEntryID: String?
    private var assistantEntrySequence: Int?
    private var assistantProviderItemID: String?
    private var assistantCreatedAt: Date?
    private var assistantText = ""
    private var assistantPendingText = ""
    private var assistantDirtyUTF8Bytes = 0
    private var assistantRequiresFullRewrite = false
    private var assistantStatus: AssistantTranscriptEntryStatus = .streaming
    private var scheduledFlush: Task<Void, Never>?
    private var openToolsByName: [String: [OpenTool]] = [:]
    private var openToolsByProviderID: [String: OpenTool] = [:]
    private var paperProjectionProviderIDs = Set<String>()
    private var resolvedModel: String?
    private var completion: AgentTurnCompletion?
    private var finished = false
    private var asynchronousStorageFailure: Error?

    fileprivate init(
        database: AppDatabase,
        lease: AssistantConversationExecutionLease,
        provider: AssistantProvider,
        workspaceURL: URL,
        conversationID: String,
        turnID: String,
        turnOrdinal: Int,
        mode: Mode,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.lease = lease
        self.provider = provider
        self.workspaceURL = workspaceURL
        self.conversationID = conversationID
        self.turnID = turnID
        self.turnOrdinal = turnOrdinal
        self.mode = mode
        self.now = now
    }

    func record(_ envelope: AgentEventEnvelope) async throws {
        if let asynchronousStorageFailure { throw asynchronousStorageFailure }
        switch envelope.event {
        case let .sessionStarted(sessionID):
            guard await lease.acceptsIdentity(envelope.attempt) else { return }
            let fingerprint = IdentityFingerprint(
                sessionID: sessionID,
                attempt: envelope.attempt
            )
            // Native providers publish identity through the turn-lifetime observer
            // before yielding the same event to visible content. Coalesce that one
            // transport duplicate without suppressing a later rotated session id.
            guard fingerprint != lastIdentityFingerprint else { return }
            identityEventOrdinal += 1
            let keyHash = AssistantSessionIdentity.aliasKeyHash(
                workspaceURL: workspaceURL,
                provider: provider,
                providerSessionID: sessionID
            )
            switch mode {
            case .interactive:
                _ = try await persist {
                    try database.recordAssistantSessionBinding(
                        keyHash: keyHash,
                        provider: provider,
                        providerSessionID: sessionID,
                        conversationID: conversationID,
                        turnOrdinal: turnOrdinal,
                        identityEventOrdinal: identityEventOrdinal,
                        at: now()
                    )
                }
            case let .scheduled(runID):
                _ = try await persist {
                    try database.recordScheduledAssistantSessionBinding(
                        runID: runID,
                        keyHash: keyHash,
                        provider: provider,
                        providerSessionID: sessionID,
                        conversationID: conversationID,
                        turnOrdinal: turnOrdinal,
                        identityEventOrdinal: identityEventOrdinal,
                        at: now()
                    )
                }
            }
            lastIdentityFingerprint = fingerprint

        case let .modelResolved(model):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            resolvedModel = model

        case let .assistantDelta(text):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            try await prepareAssistantEntry(providerItemID: envelope.providerItemID)
            assistantText += text
            assistantPendingText += text
            assistantDirtyUTF8Bytes += text.utf8.count
            guard assistantDirtyUTF8Bytes <= Self.maximumUnflushedBytes else {
                clearAssistantBuffer()
                throw AssistantConversationRecorderError.unflushedBufferLimitExceeded
            }
            if assistantDirtyUTF8Bytes >= 4 * 1_024 {
                try await flushAssistantIfNeeded()
            } else {
                scheduleTimedFlush()
            }

        case let .assistantMessageCompleted(text):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            try await prepareAssistantEntry(providerItemID: envelope.providerItemID)
            let previousText = assistantText
            assistantText = text
            if text == previousText {
                // Streaming providers commonly repeat the complete answer here.
                // The already-flushed prefix is not unflushed content.
            } else if text.hasPrefix(previousText) {
                let suffix = text.dropFirst(previousText.count)
                assistantPendingText += suffix
                assistantDirtyUTF8Bytes += suffix.utf8.count
            } else {
                // A canonical replacement cannot be represented as a suffix;
                // treat the replacement as the pending payload.
                assistantPendingText = ""
                assistantDirtyUTF8Bytes = text.utf8.count
                assistantRequiresFullRewrite = true
            }
            guard assistantDirtyUTF8Bytes <= Self.maximumUnflushedBytes else {
                clearAssistantBuffer()
                throw AssistantConversationRecorderError.unflushedBufferLimitExceeded
            }
            assistantStatus = .completed
            // Interactive turns can commit now. Scheduled completion is retained
            // for the atomic turn/run terminal transaction in `finish`.
            if case .interactive = mode {
                try await flushAssistantIfNeeded(force: true)
            }

        case let .toolUseStarted(name, detail):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            try await flushAssistantIfNeeded(force: true)
            let open = OpenTool(
                entryID: UUID().uuidString.lowercased(),
                sequence: allocateSequence(),
                providerItemID: envelope.providerItemID,
                name: name,
                detail: detail,
                createdAt: now()
            )
            openToolsByName[name, default: []].append(open)
            if let providerItemID = envelope.providerItemID {
                openToolsByProviderID[providerItemID] = open
            }
            try await persistTool(open, status: .streaming)

        case let .toolUseCompleted(name):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            try await flushAssistantIfNeeded(force: true)
            if let providerItemID = envelope.providerItemID,
               paperProjectionProviderIDs.contains(providerItemID) {
                return
            }
            guard let open = takeOpenTool(
                name: name,
                providerItemID: envelope.providerItemID
            ) else {
                if ChatPaperPresentation.isPresentationTool(name) { return }
                try await persistNotice("A tool completion could not be matched to its start.")
                return
            }
            try await persistTool(open, status: .completed)

        case let .toolDenied(name, reason):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            try await flushAssistantIfNeeded(force: true)
            let open = takeOpenTool(name: name, providerItemID: envelope.providerItemID)
                ?? OpenTool(
                    entryID: UUID().uuidString.lowercased(),
                    sequence: allocateSequence(),
                    providerItemID: envelope.providerItemID,
                    name: name,
                    detail: reason,
                    createdAt: now()
                )
            try await persistTool(
                OpenTool(
                    entryID: open.entryID,
                    sequence: open.sequence,
                    providerItemID: open.providerItemID,
                    name: open.name,
                    detail: reason,
                    createdAt: open.createdAt
                ),
                status: .denied
            )

        case let .paperPresentation(callID, _, group):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            try await flushAssistantIfNeeded(force: true)
            guard let body = ChatPaperPresentation.encodeHistoryGroup(group) else { return }
            let date = now()
            let providerItemID = envelope.providerItemID ?? callID
            let open = takeOpenTool(
                name: ChatPaperPresentation.toolName,
                providerItemID: providerItemID
            )
            paperProjectionProviderIDs.insert(providerItemID)
            let entryID = open?.entryID ?? UUID().uuidString.lowercased()
            let sequence = open?.sequence ?? allocateSequence()
            _ = try await persist {
                try database.upsertAssistantTranscriptEntry(
                    AssistantTranscriptEntry(
                        id: entryID,
                        turnId: turnID,
                        sequence: sequence,
                        providerItemId: Self.projectionItemID(
                            providerItemID,
                            projection: "tool"
                        ),
                        kind: .paper,
                        body: body,
                        payloadJSON: body,
                        searchText: Self.paperSearchText(group),
                        status: .completed,
                        createdAt: date
                    )
                )
            }

        case let .providerNotice(text):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            try await flushAssistantIfNeeded(force: true)
            try await persistNotice(text)

        case let .turnCompleted(value):
            guard await lease.acceptsContent(envelope.attempt) else { return }
            completion = value
            try await flushAssistantIfNeeded(force: true, retainScheduledFinal: true)

        case .approvalRequested:
            // Approval UI is transient. A denial/tool outcome is persisted when
            // the provider emits it; raw request summaries are not transcript data.
            break
        }
    }

    @discardableResult
    func finish(
        fallbackOutcome: AgentTurnOutcome = .failed,
        failureKind: String? = nil,
        scheduledRunStatusOverride: ScheduledJobRunStatus? = nil,
        scheduledRunFailureOverride: ScheduledJobFailureKind? = nil
    ) async throws -> Bool {
        guard !finished else { return false }
        await cancelAndJoinScheduledFlush()
        if asynchronousStorageFailure != nil {
            return try await terminalizeAfterAsynchronousStorageFailure()
        }
        finished = true
        let terminal = completion ?? AgentTurnCompletion(
            outcome: fallbackOutcome,
            usage: nil
        )
        let turnStatus: AssistantTurnStatus
        let runStatus: ScheduledJobRunStatus
        switch terminal.outcome {
        case .succeeded:
            turnStatus = .succeeded
            runStatus = .succeeded
            assistantStatus = .completed
        case .failed:
            turnStatus = .failed
            runStatus = .failed
            assistantStatus = .failed
        case .interrupted:
            turnStatus = .interrupted
            runStatus = .failed
            assistantStatus = .interrupted
        }

        let finalEntry = makeAssistantEntryIfDirty(force: true)
        let usage = terminal.usage
        let accounting = AssistantTurnAccounting(
            resolvedModel: resolvedModel,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            cacheReadTokens: usage?.cacheReadTokens,
            cacheCreationTokens: usage?.cacheCreationTokens,
            totalCostUSD: usage?.totalCostUSD
        )
        switch mode {
        case .interactive:
            if let finalEntry {
                _ = try await persist {
                    try database.upsertAssistantTranscriptEntry(finalEntry)
                }
                clearAssistantBuffer()
            }
            _ = try await persist {
                try database.finishAssistantTurn(
                    id: turnID,
                    status: turnStatus,
                    failureKind: failureKind,
                    resolvedModel: accounting.resolvedModel,
                    inputTokens: accounting.inputTokens,
                    outputTokens: accounting.outputTokens,
                    cacheReadTokens: accounting.cacheReadTokens,
                    cacheCreationTokens: accounting.cacheCreationTokens,
                    totalCostUSD: accounting.totalCostUSD,
                    at: now()
                )
            }
        case let .scheduled(runID):
            _ = try await persist {
                try database.finishScheduledAssistantCapture(
                    runID: runID,
                    turnID: turnID,
                    runStatus: scheduledRunStatusOverride ?? runStatus,
                    runFailureKind: scheduledRunFailureOverride ?? Self.scheduledFailureKind(
                        outcome: terminal.outcome,
                        fallback: failureKind
                    ),
                    turnStatus: turnStatus,
                    turnFailureKind: failureKind,
                    completion: accounting,
                    finalEntry: finalEntry,
                    at: now()
                )
            }
            clearAssistantBuffer()
        }
        await lease.closeContent()
        return false
    }

    func closeIdentity() async {
        await lease.closeIdentity()
    }

    /// Stops durable capture after an interactive write failure without stopping
    /// the provider response. The already-created turn must not remain `running`
    /// until next-launch recovery merely because its later transcript rows could
    /// not be stored.
    func abandonInteractiveCaptureAfterStorageFailure() async {
        guard case .interactive = mode else { return }
        finished = true
        scheduledFlush?.cancel()
        scheduledFlush = nil
        clearAssistantBuffer()
        _ = try? database.finishAssistantTurn(
            id: turnID,
            status: .failed,
            failureKind: "storageFailure",
            at: now()
        )
        await lease.revoke()
    }

    /// A timer flush has no caller waiting to observe its database error. If it
    /// was the last write before provider EOF, `finish` is the only opportunity
    /// to replace the durable running state with an explicit storage failure.
    /// The failed assistant buffer is deliberately discarded: retrying that same
    /// projection would reproduce the error that brought us here.
    private func terminalizeAfterAsynchronousStorageFailure() async throws -> Bool {
        finished = true
        scheduledFlush?.cancel()
        scheduledFlush = nil
        clearAssistantBuffer()
        let usage = completion?.usage
        let accounting = AssistantTurnAccounting(
            resolvedModel: resolvedModel,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            cacheReadTokens: usage?.cacheReadTokens,
            cacheCreationTokens: usage?.cacheCreationTokens,
            totalCostUSD: usage?.totalCostUSD
        )
        do {
            switch mode {
            case .interactive:
                _ = try database.finishAssistantTurn(
                    id: turnID,
                    status: .failed,
                    failureKind: "storageFailure",
                    resolvedModel: accounting.resolvedModel,
                    inputTokens: accounting.inputTokens,
                    outputTokens: accounting.outputTokens,
                    cacheReadTokens: accounting.cacheReadTokens,
                    cacheCreationTokens: accounting.cacheCreationTokens,
                    totalCostUSD: accounting.totalCostUSD,
                    at: now()
                )
            case let .scheduled(runID):
                _ = try await persist {
                    try database.finishScheduledAssistantCapture(
                        runID: runID,
                        turnID: turnID,
                        runStatus: .failed,
                        runFailureKind: .storageFailure,
                        turnStatus: .failed,
                        turnFailureKind: "storageFailure",
                        completion: accounting,
                        finalEntry: nil,
                        at: now()
                    )
                }
            }
        } catch {
            await lease.revoke()
            throw error
        }
        await lease.revoke()
        return true
    }

    func interrupt() async throws {
        assistantStatus = .interrupted
        completion = AgentTurnCompletion(outcome: .interrupted, usage: nil)
        try await finish(fallbackOutcome: .interrupted, failureKind: "interrupted")
    }

    private func allocateAssistantEntry(providerItemID: String?) {
        assistantEntryID = UUID().uuidString.lowercased()
        assistantEntrySequence = allocateSequence()
        assistantProviderItemID = providerItemID
        assistantCreatedAt = now()
        assistantStatus = .streaming
    }

    /// A native provider item boundary is also a durable entry boundary. Without
    /// this check, a second assistant item after tool use could overwrite the first
    /// item while retaining its provider ID and sequence.
    private func prepareAssistantEntry(providerItemID: String?) async throws {
        guard assistantEntryID != nil else {
            allocateAssistantEntry(providerItemID: providerItemID)
            return
        }
        if assistantProviderItemID == nil, let providerItemID {
            assistantProviderItemID = providerItemID
            return
        }
        guard let current = assistantProviderItemID,
              let providerItemID,
              current != providerItemID else { return }
        assistantStatus = .completed
        try await flushAssistantIfNeeded(force: true)
        allocateAssistantEntry(providerItemID: providerItemID)
    }

    private func allocateSequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }

    private func scheduleTimedFlush() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.flushFromTimer()
        }
    }

    private func flushFromTimer() async {
        do {
            try await flushAssistantIfNeeded(fromScheduledTimer: true)
        } catch {
            asynchronousStorageFailure = error
            await lease.closeContent()
        }
        scheduledFlush = nil
    }

    private func flushAssistantIfNeeded(
        force: Bool = false,
        retainScheduledFinal: Bool = false,
        fromScheduledTimer: Bool = false
    ) async throws {
        if !fromScheduledTimer {
            await cancelAndJoinScheduledFlush()
            if let asynchronousStorageFailure { throw asynchronousStorageFailure }
        }
        if retainScheduledFinal, case .scheduled = mode, assistantStatus == .completed {
            return
        }
        if assistantStatus != .streaming || assistantRequiresFullRewrite {
            guard let entry = makeAssistantEntryIfDirty(force: force) else { return }
            _ = try await persist {
                try database.upsertAssistantTranscriptEntry(entry)
            }
        } else {
            guard !assistantPendingText.isEmpty,
                  let entry = makeAssistantEntryIfDirty(force: false) else {
                return
            }
            let delta = assistantPendingText
            _ = try await persist {
                try database.appendAssistantTranscriptEntryDelta(
                    entry,
                    delta: delta
                )
            }
        }
        assistantPendingText = ""
        assistantDirtyUTF8Bytes = 0
        assistantRequiresFullRewrite = false
        if assistantStatus == .completed { clearAssistantBuffer() }
    }

    /// Joining matters in addition to cancellation: the timer task can already
    /// be inside scheduled SQLite retry sleeps, and actor reentrancy otherwise
    /// lets finalization pass it before `asynchronousStorageFailure` is set.
    private func cancelAndJoinScheduledFlush() async {
        guard let flush = scheduledFlush else { return }
        flush.cancel()
        await flush.value
        scheduledFlush = nil
    }

    private func makeAssistantEntryIfDirty(force: Bool) -> AssistantTranscriptEntry? {
        guard let entryID = assistantEntryID,
              let sequence = assistantEntrySequence,
              let createdAt = assistantCreatedAt,
              force || assistantDirtyUTF8Bytes > 0 else { return nil }
        return AssistantTranscriptEntry(
            id: entryID,
            turnId: turnID,
            sequence: sequence,
            providerItemId: assistantProviderItemID,
            kind: .assistant,
            body: assistantText,
            status: assistantStatus,
            createdAt: createdAt,
            dateModified: now()
        )
    }

    private func clearAssistantBuffer() {
        assistantEntryID = nil
        assistantEntrySequence = nil
        assistantProviderItemID = nil
        assistantCreatedAt = nil
        assistantText = ""
        assistantPendingText = ""
        assistantDirtyUTF8Bytes = 0
        assistantRequiresFullRewrite = false
        assistantStatus = .streaming
    }

    private func persistTool(
        _ tool: OpenTool,
        status: AssistantTranscriptEntryStatus
    ) async throws {
        let chipStatus: ToolChipStatus
        switch status {
        case .streaming: chipStatus = .started
        case .denied: chipStatus = .denied
        default: chipStatus = .completed
        }
        let payload = ToolChipPayload(
            name: tool.name,
            detail: tool.detail,
            status: chipStatus
        )
        let body = ChatTranscriptJS.encodeArg(payload)
        _ = try await persist {
            try database.upsertAssistantTranscriptEntry(
                AssistantTranscriptEntry(
                    id: tool.entryID,
                    turnId: turnID,
                    sequence: tool.sequence,
                    providerItemId: Self.projectionItemID(
                        tool.providerItemID,
                        projection: "tool"
                    ),
                    kind: .tool,
                    body: body,
                    payloadJSON: body,
                    searchText: "",
                    status: status,
                    createdAt: tool.createdAt,
                    dateModified: now()
                )
            )
        }
    }

    private func persistNotice(_ text: String) async throws {
        let date = now()
        let sequence = allocateSequence()
        _ = try await persist {
            try database.upsertAssistantTranscriptEntry(
                AssistantTranscriptEntry(
                    turnId: turnID,
                    sequence: sequence,
                    kind: .notice,
                    body: text,
                    searchText: "",
                    status: .completed,
                    createdAt: date
                )
            )
        }
    }

    private static let maximumUnflushedBytes = 1 * 1_024 * 1_024
    private static let scheduledRetryDelays: [Duration] = [
        .milliseconds(100), .milliseconds(200), .milliseconds(400),
        .milliseconds(500), .milliseconds(800),
    ]

    /// Interactive panes fail fast and show their durable warning. Scheduled
    /// results promise inspectability, so transient SQLite failures receive a
    /// bounded two-second retry budget before the runner cancels provider work.
    private func persist<Value>(
        _ operation: () throws -> Value
    ) async throws -> Value {
        guard case .scheduled = mode else { return try operation() }
        var lastError: Error?
        for attempt in 0...Self.scheduledRetryDelays.count {
            do {
                return try operation()
            } catch {
                lastError = error
                guard attempt < Self.scheduledRetryDelays.count else { break }
                try await Task.sleep(for: Self.scheduledRetryDelays[attempt])
            }
        }
        throw lastError ?? AssistantConversationRecorderError.storageUnavailable
    }

    private func takeOpenTool(name: String, providerItemID: String?) -> OpenTool? {
        if let providerItemID,
           let tool = openToolsByProviderID.removeValue(forKey: providerItemID) {
            if var queue = openToolsByName[tool.name] {
                queue.removeAll { $0.entryID == tool.entryID }
                openToolsByName[tool.name] = queue.isEmpty ? nil : queue
            }
            return tool
        }
        guard var queue = openToolsByName[name], !queue.isEmpty else { return nil }
        let tool = queue.removeFirst()
        openToolsByName[name] = queue.isEmpty ? nil : queue
        if let providerItemID = tool.providerItemID {
            openToolsByProviderID[providerItemID] = nil
        }
        return tool
    }

    private static func paperSearchText(_ group: ChatPaperGroup) -> String {
        group.items.map(\.title).joined(separator: " ")
    }

    private static func projectionItemID(
        _ providerItemID: String?,
        projection: String
    ) -> String? {
        providerItemID.map { "\($0):\(projection)" }
    }

    private static func scheduledFailureKind(
        outcome: AgentTurnOutcome,
        fallback: String?
    ) -> ScheduledJobFailureKind? {
        switch outcome {
        case .succeeded: nil
        case .interrupted: .interrupted
        case .failed:
            switch fallback {
            case ScheduledJobFailureKind.permissionDenied.rawValue:
                .permissionDenied
            case ScheduledJobFailureKind.storageFailure.rawValue:
                .storageFailure
            case ScheduledJobFailureKind.launchFailed.rawValue:
                .launchFailed
            default:
                .providerFailed
            }
        }
    }
}

enum AssistantConversationRecorderError: Error, LocalizedError {
    case unflushedBufferLimitExceeded
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .unflushedBufferLimitExceeded:
            "The Assistant transcript exceeded Rubien’s durability buffer."
        case .storageUnavailable:
            "Rubien could not persist the Assistant transcript."
        }
    }
}
#endif
