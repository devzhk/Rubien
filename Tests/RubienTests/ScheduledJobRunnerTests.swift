#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class ScheduledJobRunnerTests: XCTestCase {
    @MainActor
    func testSuccessfulRunPersistsSessionWithoutAssistantActivity() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "scheduled-session"),
            .assistantMessageCompleted(text: "Done"),
            .turnCompleted(usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        var statusAtStart: ScheduledJobRunStatus?
        var receivedEvents: [AgentEvent] = []
        let possibleResult = await runner.execute(
            claim,
            onStarted: {
                statusAtStart = try? database.fetchScheduledJobRun(id: claim.run.id)?.status
            },
            onEvent: { receivedEvents.append($0) }
        )
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(statusAtStart, .running)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.providerSessionId, "scheduled-session")
        XCTAssertEqual(receivedEvents, provider.events)
        XCTAssertTrue(result.isUnread)
        let request = try XCTUnwrap(provider.lastRequest)
        XCTAssertEqual(request.executionMode, .scheduled)
        XCTAssertEqual(request.codexSandbox, .readOnly)
        XCTAssertFalse(request.loadUserTools)
        XCTAssertTrue(request.seed?.contains("read-only") == true)
        let activityCount = try await database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assistantActivity")
        }
        XCTAssertEqual(activityCount, 0, "scheduled runs are not interactive Assistant activity")
    }

    @MainActor
    func testSuccessfulRunStaysFinishingUntilLateIdentityChannelCloses() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let identityGate = ScheduledIdentityCloseGate()
        let provider = ScheduledProviderStub(
            events: [
                .sessionStarted(sessionID: "scheduled-session"),
                .assistantMessageCompleted(text: "Done"),
                .turnCompleted(usage: nil),
            ],
            identityCloseGate: identityGate
        )
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let execution = Task { await runner.execute(claim) }
        await identityGate.waitUntilBlocked()
        try await waitUntil {
            try database.fetchScheduledJobRun(id: claim.run.id)?
                .assistantTranscriptState == .finishingIdentity
        }
        XCTAssertFalse(try database.canContinueScheduledAssistantConversation(
            runID: claim.run.id
        ))

        await identityGate.release()
        let executionResult = await execution.value
        let result = try XCTUnwrap(executionResult)
        XCTAssertEqual(result.assistantTranscriptState, .available)
        XCTAssertTrue(try database.canContinueScheduledAssistantConversation(
            runID: claim.run.id
        ))
    }

    @MainActor
    func testDeniedOptionalApprovalCanRecoverAndSucceed() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "scheduled-session"),
            .approvalRequested(id: "approval-1", toolName: "Bash", summary: "write"),
            .turnCompleted(usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let possibleResult = await runner.execute(claim)
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertNil(result.failureKind)
        XCTAssertEqual(provider.decisions, ["approval-1": .deny])
    }

    @MainActor
    func testDeniedRequiredApprovalUsesPermissionFailureWhenProviderFails() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "scheduled-session"),
            .approvalRequested(id: "approval-1", toolName: "Bash", summary: "write"),
            .turnCompleted(outcome: .failed, usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let possibleResult = await runner.execute(claim)
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .permissionDenied)
        XCTAssertEqual(provider.decisions, ["approval-1": .deny])
    }

    @MainActor
    func testProviderTerminalFailureCannotBeRecordedAsSuccess() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "scheduled-session"),
            .turnCompleted(outcome: .failed, usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let possibleResult = await runner.execute(claim)
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .providerFailed)
    }

    @MainActor
    func testProviderTerminalInterruptionPersistsInterruptedFailure() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "scheduled-session"),
            .turnCompleted(outcome: .interrupted, usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let possibleResult = await runner.execute(claim)
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .interrupted)
    }

    @MainActor
    func testFinalTranscriptFailureDoesNotReturnPreterminalRunAsCompleted() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failScheduledTerminalUpdate
                BEFORE UPDATE OF status ON scheduledJobRun
                WHEN NEW.status IN ('succeeded', 'failed', 'cancelled')
                BEGIN
                    SELECT RAISE(FAIL, 'injected finalization failure');
                END
                """)
        }
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "scheduled-session"),
            .assistantMessageCompleted(text: "Durable partial"),
            .turnCompleted(usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let result = await runner.execute(claim)

        XCTAssertNil(result)
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: claim.run.id)?.status,
            .running
        )
    }

    @MainActor
    func testUnavailableProviderFailsBeforeStart() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [], ready: false)
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let possibleResult = await runner.execute(claim)
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .providerUnavailable)
        XCTAssertNil(result.startedAt)
        XCTAssertNil(provider.lastRequest)
    }

    @MainActor
    func testMissingLibraryChannelFailsBeforeProviderLaunch() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "must-not-start"),
            .turnCompleted(usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil,
            contentChannelAvailable: false
        )

        let possibleResult = await runner.execute(claim)
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .libraryChannelUnavailable)
        XCTAssertNil(result.startedAt)
        XCTAssertNil(provider.lastRequest)
    }

    @MainActor
    func testCancellationDuringAvailabilityProbeWinsOverUnavailableResult() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let claim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [], ready: false, availabilityDelay: .milliseconds(100))
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        let execution = Task { await runner.execute(claim) }
        try await Task.sleep(for: .milliseconds(10))
        runner.cancel(runID: claim.run.id)
        let possibleResult = await execution.value
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.failureKind)
    }

    @MainActor
    func testCancellationBeforeExecutionIsScopedToClaimedRun() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let firstClaim = try makeClaim(database: database)
        let provider = ScheduledProviderStub(events: [
            .sessionStarted(sessionID: "scheduled-session"),
            .turnCompleted(usage: nil),
        ])
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )

        runner.cancel(runID: firstClaim.run.id)
        let possibleFirstResult = await runner.execute(firstClaim)
        let firstResult = try XCTUnwrap(possibleFirstResult)

        XCTAssertEqual(firstResult.status, .cancelled)
        XCTAssertNil(provider.lastRequest)

        let secondClaim = try database.claimManualScheduledJob(id: firstClaim.job.id)
        let possibleSecondResult = await runner.execute(secondClaim)
        let secondResult = try XCTUnwrap(possibleSecondResult)

        XCTAssertEqual(secondResult.status, .succeeded)
        XCTAssertNotNil(provider.lastRequest)
    }

    private func makeClaim(database: AppDatabase) throws -> ScheduledJobExecutionClaim {
        let job = try database.createScheduledJob(.init(
            name: "Morning papers",
            prompt: "Find recent papers",
            recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
            provider: .claude
        ))
        return try database.claimManualScheduledJob(id: job.id)
    }

    private func waitUntil(
        _ condition: @escaping () throws -> Bool,
        ticks: Int = 500
    ) async throws {
        for _ in 0..<ticks {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not become true")
    }
}

private final class ScheduledProviderStub: AgentProvider, @unchecked Sendable {
    let kind: AgentProviderKind = .claude
    let events: [AgentEvent]
    let ready: Bool
    let availabilityDelay: Duration?
    let identityCloseGate: ScheduledIdentityCloseGate?
    private(set) var lastRequest: AgentTurnRequest?
    private(set) var decisions: [String: ApprovalDecision] = [:]

    init(
        events: [AgentEvent],
        ready: Bool = true,
        availabilityDelay: Duration? = nil,
        identityCloseGate: ScheduledIdentityCloseGate? = nil
    ) {
        self.events = events
        self.ready = ready
        self.availabilityDelay = availabilityDelay
        self.identityCloseGate = identityCloseGate
    }

    func isAvailable() async -> AgentAvailability {
        if let availabilityDelay { try? await Task.sleep(for: availabilityDelay) }
        return ready
            ? AgentAvailability.installed(version: "test", path: "/test/provider")
            : AgentAvailability.notFound(reason: "missing")
    }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        lastRequest = turn
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func sendEnvelopes(
        turn: AgentTurnRequest,
        attempt: AssistantAttemptIdentity,
        identityObserver: AgentIdentityObserver?
    ) -> AsyncThrowingStream<AgentEventEnvelope, Error> {
        lastRequest = turn
        let events = events
        let identityCloseGate = identityCloseGate
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    if case let .sessionStarted(sessionID) = event {
                        await identityObserver?.sessionStarted(
                            sessionID,
                            runtimeGeneration: attempt.runtimeGeneration
                        )
                    }
                    continuation.yield(AgentEventEnvelope(
                        attempt: attempt,
                        providerItemID: nil,
                        event: event
                    ))
                }
                continuation.finish()
                if let identityCloseGate {
                    await identityCloseGate.wait()
                }
                await identityObserver?.close()
            }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {
        decisions[id] = decision
    }

    func cancel() {}
}

private actor ScheduledIdentityCloseGate {
    private var isReleased = false
    private var isBlocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        isBlocked = true
        let observers = blockedWaiters
        blockedWaiters.removeAll()
        for observer in observers { observer.resume() }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
#endif
