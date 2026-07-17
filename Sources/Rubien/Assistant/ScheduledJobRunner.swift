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
        onStarted: (() -> Void)? = nil
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
        guard (try? database.markScheduledJobRunStarted(
            id: runID,
            at: Date()
        )) == true else {
            return try? database.fetchScheduledJobRun(id: runID)
        }
        onStarted?()

        let workspaceURL = AssistantContext.ensureWorkspace(workspaceProvider())
        let conversationID = UUID()
        let request = AgentTurnRequest(
            workspaceURL: workspaceURL,
            prompt: claim.job.prompt,
            seed: Self.scheduledSeed(jobName: claim.job.name),
            webAccess: claim.job.webAccess,
            loadUserTools: false,
            codexSandbox: .readOnly,
            modelOverride: claim.job.model,
            effortOverride: claim.job.effort,
            executionMode: .scheduled
        )

        var receivedSession = false
        var completion: AgentTurnCompletion?
        var permissionDenied = false
        do {
            for try await event in provider.send(turn: request) {
                if isCancellationRequested(for: runID) {
                    provider.cancel()
                }
                switch event {
                case .sessionStarted(let sessionID):
                    receivedSession = true
                    _ = try? database.setScheduledJobRunProviderSessionID(
                        id: runID,
                        sessionID: sessionID
                    )
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
            logger.error("scheduled run \(runID) failed: \(error.localizedDescription)")
        }

        let status: ScheduledJobRunStatus
        let failure: ScheduledJobFailureKind?
        if isCancellationRequested(for: runID) {
            status = .cancelled
            failure = nil
        } else {
            switch completion?.outcome {
            case .succeeded:
                status = .succeeded
                failure = nil
            case .interrupted:
                status = .failed
                failure = .interrupted
            case .failed:
                status = .failed
                failure = permissionDenied ? .permissionDenied : .providerFailed
            case nil:
                status = .failed
                if permissionDenied {
                    failure = .permissionDenied
                } else {
                    failure = receivedSession ? .providerFailed : .launchFailed
                }
            }
        }
        _ = try? database.finishScheduledJobRun(
            id: runID,
            status: status,
            failureKind: failure
        )
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
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .unknown: nil
        }
    }

    var displayName: String {
        agentProviderKind?.displayName ?? rawValue
    }

    init(_ kind: AgentProviderKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }
}
#endif
