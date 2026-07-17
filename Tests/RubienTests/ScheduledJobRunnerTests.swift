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
        let possibleResult = await runner.execute(claim) {
            statusAtStart = try? database.fetchScheduledJobRun(id: claim.run.id)?.status
        }
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(statusAtStart, .running)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.providerSessionId, "scheduled-session")
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
    func testApprovalRequestIsDeniedAndFailsRun() async throws {
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

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .permissionDenied)
        XCTAssertEqual(provider.decisions, ["approval-1": .deny])
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
        runner.cancel()
        let possibleResult = await execution.value
        let result = try XCTUnwrap(possibleResult)

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.failureKind)
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
}

private final class ScheduledProviderStub: AgentProvider, @unchecked Sendable {
    let kind: AgentProviderKind = .claude
    let events: [AgentEvent]
    let ready: Bool
    let availabilityDelay: Duration?
    private(set) var lastRequest: AgentTurnRequest?
    private(set) var decisions: [String: ApprovalDecision] = [:]

    init(
        events: [AgentEvent],
        ready: Bool = true,
        availabilityDelay: Duration? = nil
    ) {
        self.events = events
        self.ready = ready
        self.availabilityDelay = availabilityDelay
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

    func respondToApproval(id: String, _ decision: ApprovalDecision) {
        decisions[id] = decision
    }

    func cancel() {}
}
#endif
