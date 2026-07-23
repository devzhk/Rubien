#if os(macOS)
import Foundation
import RubienCore

/// Executes one already-claimed scheduled job. It deliberately bypasses
/// `ChatSessionController`: scheduled conversations should be provider-owned and
/// resumable, but must not render UI or increment interactive Assistant activity.
@MainActor
final class ScheduledJobRunner {
    typealias ProviderFactory = (AgentProviderKind) -> (any AgentProvider)?

    private let database: AppDatabase
    private let providerFactory: ProviderFactory
    private let workspaceProvider: () -> URL
    private let attributionStore: AssistantSessionAttributionStore?
    private let contentChannelAvailable: Bool
    private let logger = RubienLogger(
        subsystem: "com.rubien.assistant",
        category: "ScheduledJobRunner"
    )

    private var currentRunID: String?
    private var currentProvider: (any AgentProvider)?
    private var cancelledRunIDs: Set<String> = []

    init(
        database: AppDatabase,
        providerFactory: @escaping ProviderFactory,
        workspaceProvider: @escaping () -> URL,
        attributionStore: AssistantSessionAttributionStore? = .shared,
        contentChannelAvailable: Bool = true
    ) {
        self.database = database
        self.providerFactory = providerFactory
        self.workspaceProvider = workspaceProvider
        self.attributionStore = attributionStore
        self.contentChannelAvailable = contentChannelAvailable
    }

    func execute(
        _ claim: ScheduledJobExecutionClaim,
        onStarted: (() -> Void)? = nil,
        onEvent: ((AgentEvent) -> Void)? = nil
    ) async -> ScheduledJobRun? {
        let runID = claim.run.id
        defer { cancelledRunIDs.remove(runID) }
        guard !isCancellationRequested(for: runID) else {
            _ = try? database.finishScheduledJobRun(id: runID, status: .cancelled)
            return try? database.fetchScheduledJobRun(id: runID)
        }
        guard contentChannelAvailable else {
            _ = try? database.finishScheduledJobRun(
                id: runID,
                status: .failed,
                failureKind: .libraryChannelUnavailable
            )
            return try? database.fetchScheduledJobRun(id: runID)
        }
        guard let kind = claim.job.provider.agentProviderKind,
              let provider = providerFactory(kind)
        else {
            _ = try? database.finishScheduledJobRun(
                id: runID,
                status: .failed,
                failureKind: .providerUnavailable
            )
            return try? database.fetchScheduledJobRun(id: runID)
        }

        currentRunID = runID
        currentProvider = provider
        defer {
            provider.shutdown()
            if currentRunID == runID {
                currentRunID = nil
                currentProvider = nil
            }
        }

        let availability = await provider.isAvailable()
        guard !isCancellationRequested(for: runID) else {
            _ = try? database.finishScheduledJobRun(id: runID, status: .cancelled)
            return try? database.fetchScheduledJobRun(id: runID)
        }
        guard availability.isReady else {
            _ = try? database.finishScheduledJobRun(
                id: runID,
                status: .failed,
                failureKind: .providerUnavailable
            )
            return try? database.fetchScheduledJobRun(id: runID)
        }
        let workspaceURL = AssistantContext.ensureWorkspace(workspaceProvider())
        let conversationID = UUID()
        let turnID = UUID()
        let workID = UUID()
        let startedAt = Date()
        let conversation = AssistantConversation(
            id: conversationID.uuidString.lowercased(),
            provider: claim.job.provider,
            workspaceIdentityHash: AssistantSessionIdentity.workspaceHash(workspaceURL),
            contextKind: .library,
            scheduledJobRunId: runID,
            createdAt: startedAt
        )
        let turn = AssistantTurn(
            id: turnID.uuidString.lowercased(),
            conversationId: conversation.id,
            ordinal: 1,
            status: .running,
            requestedModel: claim.job.model,
            requestedEffort: claim.job.effort,
            startedAt: startedAt,
            dateModified: startedAt
        )
        let userEntry = AssistantTranscriptEntry(
            turnId: turn.id,
            sequence: 0,
            kind: .user,
            body: claim.job.prompt,
            status: .completed,
            createdAt: startedAt
        )
        do {
            try database.beginScheduledAssistantCapture(
                runID: runID,
                conversation: conversation,
                turn: turn,
                userEntry: userEntry,
                at: startedAt
            )
        } catch {
            logger.error("scheduled run \(runID) could not create its transcript: \(error.localizedDescription)")
            _ = try? database.finishScheduledJobRun(
                id: runID,
                status: .failed,
                failureKind: .storageFailure
            )
            return try? database.fetchScheduledJobRun(id: runID)
        }
        onStarted?()

        let attempt = AssistantAttemptIdentity(
            conversationID: conversationID,
            conversationEpoch: 0,
            turnID: turnID,
            workID: workID,
            runtimeGeneration: nil
        )
        let capture = AssistantConversationService.makeCapture(
            database: database,
            attempt: attempt,
            provider: claim.job.provider,
            workspaceURL: workspaceURL,
            conversationID: conversation.id,
            turnID: turn.id,
            turnOrdinal: 1,
            mode: .scheduled(runID: runID)
        )
        let recorder = capture.recorder
        let identityObserver = capture.identityObserver
        let request = AgentTurnRequest(
            workspaceURL: workspaceURL,
            conversationID: conversationID,
            prompt: claim.job.prompt,
            seed: Self.scheduledSeed(jobName: claim.job.name),
            webAccess: claim.job.webAccess,
            loadUserTools: false,
            codexSandbox: .readOnly,
            modelOverride: claim.job.model,
            effortOverride: claim.job.effort,
            executionMode: .scheduled,
            scheduledRunID: runID
        )

        var receivedSession = false
        var completion: AgentTurnCompletion?
        var permissionDenied = false
        var storageFailed = false
        var providerStreamFailed = false
        do {
            eventLoop: for try await envelope in provider.sendEnvelopes(
                turn: request,
                attempt: attempt,
                identityObserver: identityObserver
            ) {
                if isCancellationRequested(for: runID) {
                    provider.cancel()
                }
                do {
                    try await recorder.record(envelope)
                } catch {
                    storageFailed = true
                    logger.error("scheduled run \(runID) lost transcript durability: \(error.localizedDescription)")
                    provider.cancel()
                    break eventLoop
                }
                let event = envelope.event
                onEvent?(event)
                switch event {
                case .sessionStarted(let sessionID):
                    receivedSession = true
                    if let attributionStore {
                        await attributionStore.record(
                            sessionID: sessionID,
                            provider: kind,
                            workspaceURL: workspaceURL,
                            conversationId: conversationID,
                            context: .library
                        )
                    }
                case .approvalRequested(let id, _, _):
                    // Scheduled runs never wait for a person and never bypass the
                    // provider boundary. The provider's terminal outcome decides
                    // whether this denied tool was required or merely optional.
                    permissionDenied = true
                    provider.respondToApproval(id: id, .deny)
                case .toolDenied:
                    permissionDenied = true
                case .turnCompleted(let terminal):
                    completion = terminal
                case .modelResolved, .assistantDelta, .assistantMessageCompleted,
                     .toolUseStarted, .toolUseCompleted, .paperPresentation,
                     .providerNotice:
                    break
                }
            }
        } catch {
            providerStreamFailed = true
            logger.error("scheduled run \(runID) failed: \(error.localizedDescription)")
        }

        let status: ScheduledJobRunStatus
        let failure: ScheduledJobFailureKind?
        let fallbackOutcome: AgentTurnOutcome
        if storageFailed {
            status = .failed
            failure = .storageFailure
            fallbackOutcome = .failed
        } else if isCancellationRequested(for: runID) {
            status = .cancelled
            failure = nil
            fallbackOutcome = .interrupted
        } else {
            switch completion?.outcome {
            case .succeeded:
                status = .succeeded
                failure = nil
                fallbackOutcome = .succeeded
            case .interrupted:
                status = .failed
                failure = .interrupted
                fallbackOutcome = .interrupted
            case .failed:
                status = .failed
                failure = permissionDenied ? .permissionDenied : .providerFailed
                fallbackOutcome = .failed
            case nil:
                status = .failed
                if permissionDenied {
                    failure = .permissionDenied
                } else {
                    failure = receivedSession ? .providerFailed : .launchFailed
                }
                fallbackOutcome = providerStreamFailed ? .failed : .interrupted
            }
        }
        do {
            _ = try await recorder.finish(
                fallbackOutcome: fallbackOutcome,
                failureKind: failure?.rawValue,
                scheduledRunStatusOverride: status,
                scheduledRunFailureOverride: failure
            )
            await identityObserver.waitUntilClosed()
            _ = try database.finishScheduledAssistantIdentity(runID: runID)
        } catch {
            // Keep the run/turn preterminal: startup recovery can classify the
            // last durable partial without ever advertising provider success.
            logger.error("scheduled run \(runID) final transcript transaction failed: \(error.localizedDescription)")
            return nil
        }
        return try? database.fetchScheduledJobRun(id: runID)
    }

    func cancel(runID: String) {
        cancelledRunIDs.insert(runID)
        guard currentRunID == runID else { return }
        currentProvider?.cancel()
    }

    private func isCancellationRequested(for runID: String) -> Bool {
        cancelledRunIDs.contains(runID)
    }

    private static func scheduledSeed(jobName: String) -> String {
        """
        \(AssistantContext.seed(for: .library)) You are running the unattended scheduled job \
        “\(AssistantContext.sanitizeSeedField(jobName, fallback: "Scheduled job"))”. Rubien's \
        library tools are read-only for this run. Do not attempt mutations or request permission; \
        complete the user's task using read-only research and library access.
        """
    }
}

extension ScheduledJobProvider {
    var agentProviderKind: AgentProviderKind? {
        AgentProviderKind(self)
    }

    var displayName: String {
        agentProviderKind?.displayName ?? rawValue
    }

    init(_ kind: AgentProviderKind) {
        self = kind.storedProvider
    }
}
#endif
