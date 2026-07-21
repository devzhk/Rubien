#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class ScheduledJobCoordinatorTests: XCTestCase {
    @MainActor
    func testDueRunPublishesRunningThenTerminalState() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        _ = try database.createScheduledJob(
            .init(
                name: "Morning scan",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
                provider: .claude,
                notifyOnCompletion: false
            ),
            now: date("2026-07-13T07:00:00Z"),
            calendar: calendar
        )
        let provider = CoordinatorProviderStub()
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )
        let coordinator = ScheduledJobCoordinator(
            database: database,
            runner: runner,
            now: { self.date("2026-07-13T08:01:00Z") },
            calendar: { calendar },
            // Keep the real background-scheduler path enabled: this overdue
            // startup scenario previously raised NSInvalidArgumentException.
            usesBackgroundScheduler: true
        )

        coordinator.start()

        try await waitUntil { coordinator.activeRun?.status == .running }
        XCTAssertEqual(coordinator.recentRuns.first?.status, .running)
        try await waitUntil {
            coordinator.activeRunProgress?.entries.contains(where: {
                $0.detail == "Scanning the library…"
            }) == true
        }
        try await waitUntil { coordinator.recentRuns.first?.status == .succeeded }
        XCTAssertNil(coordinator.activeRun)
        XCTAssertEqual(coordinator.activeRunProgress?.phase, .succeeded)
        XCTAssertEqual(coordinator.unreadRunCount, 1)
    }

    func testBackgroundActivityTimingRejectsDueDeadlinesAndKeepsFutureValuesValid() throws {
        XCTAssertNil(ScheduledJobCoordinator.backgroundActivityTiming(for: -1))
        XCTAssertNil(ScheduledJobCoordinator.backgroundActivityTiming(for: 0))
        XCTAssertNil(ScheduledJobCoordinator.backgroundActivityTiming(for: .infinity))

        for delay in [0.001, 0.5, 1, 1.01, 10, 600, 86_400] {
            let timing = try XCTUnwrap(
                ScheduledJobCoordinator.backgroundActivityTiming(for: delay)
            )
            XCTAssertGreaterThanOrEqual(timing.interval, 1)
            XCTAssertGreaterThan(timing.tolerance, 0)
            XCTAssertLessThan(timing.tolerance, timing.interval)
            XCTAssertLessThanOrEqual(timing.tolerance, 60)
        }
    }

    @MainActor
    func testRunNowThenImmediateCancelCannotLoseCancellation() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let job = try database.createScheduledJob(
            .init(
                name: "Manual scan",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
                provider: .claude,
                notifyOnCompletion: false
            ),
            now: date("2026-07-13T07:00:00Z"),
            calendar: calendar
        )
        let provider = CoordinatorProviderStub()
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )
        let coordinator = ScheduledJobCoordinator(
            database: database,
            runner: runner,
            now: { self.date("2026-07-13T07:01:00Z") },
            calendar: { calendar },
            usesBackgroundScheduler: false
        )

        try coordinator.runNow(id: job.id)
        let firstRunID = try XCTUnwrap(coordinator.activeRun?.id)
        coordinator.cancelActiveRun()

        try await waitUntil {
            coordinator.recentRuns.first(where: { $0.id == firstRunID })?.status == .cancelled
        }
        XCTAssertEqual(provider.availabilityCallCount, 0)

        try coordinator.runNow(id: job.id)
        try await waitUntil { coordinator.recentRuns.first?.status == .succeeded }
        XCTAssertEqual(provider.availabilityCallCount, 1)
    }

    @MainActor
    func testDeleteRunRefreshesHistoryAndUnavailableState() throws {
        let database = try AppDatabase(DatabaseQueue())
        let job = try database.createScheduledJob(
            .init(
                name: "Finished scan",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
                provider: .claude,
                notifyOnCompletion: false
            )
        )
        let claim = try database.claimManualScheduledJob(id: job.id)
        XCTAssertTrue(try database.finishScheduledJobRun(
            id: claim.run.id,
            status: .succeeded
        ))
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in CoordinatorProviderStub() },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )
        let coordinator = ScheduledJobCoordinator(
            database: database,
            runner: runner,
            usesBackgroundScheduler: false
        )
        coordinator.refresh()
        coordinator.markResultUnavailable(id: claim.run.id)

        try coordinator.deleteRun(id: claim.run.id)

        XCTAssertTrue(coordinator.recentRuns.isEmpty)
        XCTAssertEqual(coordinator.unreadRunCount, 0)
        XCTAssertFalse(coordinator.unavailableResultRunIDs.contains(claim.run.id))
    }

    @MainActor
    func testExternalNotifyingJobRequestsNotificationAuthorization() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let calendar = utcCalendar()
        let provider = CoordinatorProviderStub()
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { _ in provider },
            workspaceProvider: { FileManager.default.temporaryDirectory },
            attributionStore: nil
        )
        var authorizationRequestCount = 0
        let coordinator = ScheduledJobCoordinator(
            database: database,
            runner: runner,
            now: { self.date("2026-07-13T07:00:00Z") },
            calendar: { calendar },
            notificationAuthorizationRequester: {
                authorizationRequestCount += 1
            },
            usesBackgroundScheduler: false
        )
        coordinator.start()
        XCTAssertEqual(authorizationRequestCount, 0)

        let job = try database.createScheduledJob(
            .init(
                name: "Externally created scan",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 8 * 60),
                provider: .claude,
                notifyOnCompletion: true
            ),
            now: date("2026-07-13T07:00:00Z"),
            calendar: calendar
        )
        LibraryChangeBroadcaster.shared.triggerLocalRefresh()

        try await waitUntil {
            coordinator.jobs.contains(where: { $0.id == job.id })
                && authorizationRequestCount == 1
        }

        LibraryChangeBroadcaster.shared.triggerLocalRefresh()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            authorizationRequestCount,
            1,
            "unrelated external refreshes must not repeat the authorization request"
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for scheduled-job coordinator state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class CoordinatorProviderStub: AgentProvider, @unchecked Sendable {
    let kind: AgentProviderKind = .claude
    private(set) var availabilityCallCount = 0

    func isAvailable() async -> AgentAvailability {
        availabilityCallCount += 1
        return .installed(version: "test", path: "/test/provider")
    }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.sessionStarted(sessionID: "coordinator-session"))
            continuation.yield(.assistantDelta(text: "Scanning the library…"))
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                continuation.yield(.turnCompleted(usage: nil))
                continuation.finish()
            }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {}
    func cancel() {}
}
#endif
