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

    private var currentProvider: (any AgentProvider)?
    private var cancellationRequested = false

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
        cancellationRequested = false
        guard contentChannelAvailable else {
            _ = try? database.finishScheduledJobRun(
                id: claim.run.id,
                status: .failed,
                failureKind: .libraryChannelUnavailable
            )
            return try? database.fetchScheduledJobRun(id: claim.run.id)
        }
        guard let kind = claim.job.provider.agentProviderKind,
              let provider = providerFactory(kind)
        else {
            _ = try? database.finishScheduledJobRun(
                id: claim.run.id,
                status: .failed,
                failureKind: .providerUnavailable
            )
            return try? database.fetchScheduledJobRun(id: claim.run.id)
        }

        currentProvider = provider
        defer {
            provider.shutdown()
            currentProvider = nil
        }

        let availability = await provider.isAvailable()
        guard !cancellationRequested else {
            _ = try? database.finishScheduledJobRun(id: claim.run.id, status: .cancelled)
            return try? database.fetchScheduledJobRun(id: claim.run.id)
        }
        guard availability.isReady else {
            _ = try? database.finishScheduledJobRun(
                id: claim.run.id,
                status: .failed,
                failureKind: .providerUnavailable
            )
            return try? database.fetchScheduledJobRun(id: claim.run.id)
        }
        guard (try? database.markScheduledJobRunStarted(
            id: claim.run.id,
            at: Date()
        )) == true else {
            return try? database.fetchScheduledJobRun(id: claim.run.id)
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
        var completed = false
        var permissionDenied = false
        do {
            for try await event in provider.send(turn: request) {
                if cancellationRequested {
                    provider.cancel()
                }
                switch event {
                case .sessionStarted(let sessionID):
                    receivedSession = true
                    _ = try? database.setScheduledJobRunProviderSessionID(
                        id: claim.run.id,
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
                    // provider boundary. Any approval request is denied and makes
                    // the run visibly fail, even if the provider later emits result.
                    permissionDenied = true
                    provider.respondToApproval(id: id, .deny)
                case .toolDenied:
                    permissionDenied = true
                case .turnCompleted:
                    completed = true
                case .modelResolved, .assistantDelta, .assistantMessageCompleted,
                     .toolUseStarted, .toolUseCompleted, .paperPresentation,
                     .providerNotice:
                    break
                }
            }
        } catch {
            logger.error("scheduled run \(claim.run.id) failed: \(error.localizedDescription)")
        }

        let status: ScheduledJobRunStatus
        let failure: ScheduledJobFailureKind?
        if cancellationRequested {
            status = .cancelled
            failure = nil
        } else if permissionDenied {
            status = .failed
            failure = .permissionDenied
        } else if completed {
            status = .succeeded
            failure = nil
        } else {
            status = .failed
            failure = receivedSession ? .providerFailed : .launchFailed
        }
        _ = try? database.finishScheduledJobRun(
            id: claim.run.id,
            status: status,
            failureKind: failure
        )
        return try? database.fetchScheduledJobRun(id: claim.run.id)
    }

    func cancel() {
        cancellationRequested = true
        currentProvider?.cancel()
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
