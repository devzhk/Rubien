#if os(macOS)
import XCTest
@testable import Rubien

final class CodexRuntimeMetricsTests: XCTestCase {
    func testProfileDeltaSeparatesPluginToggleFromPluginWorkspace() {
        let isolated = CodexRuntimeProfile(webAccess: true)
        let firstPluginWorkspace = CodexRuntimeProfile(
            webAccess: false,
            pluginWorkingDirectory: "/first"
        )
        let secondPluginWorkspace = CodexRuntimeProfile(
            webAccess: false,
            pluginWorkingDirectory: "/second"
        )

        XCTAssertEqual(
            firstPluginWorkspace.delta(from: isolated),
            [.webAccess, .pluginToggle]
        )
        XCTAssertEqual(
            secondPluginWorkspace.delta(from: firstPluginWorkspace),
            [.pluginWorkingDirectory]
        )
    }

    func testMetricsPersistQueueAndRespawnBreakdownsWithoutTurnData() throws {
        let clock = MonotonicClock()
        let fixture = makeStore(monotonicNow: { clock.now })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.store.recordTurnRequest()
        fixture.store.recordTurnRequest()
        var observation = fixture.store.beginQueue(reason: .capacity)
        clock.advance(nanoseconds: 1_250_000_000)
        fixture.store.finishQueue(observation)
        observation = fixture.store.beginQueue(
            reason: .runtimeProfile([.webAccess, .pluginToggle])
        )
        clock.advance(nanoseconds: 3_500_000_000)
        fixture.store.finishQueue(observation)
        fixture.store.recordProfileRespawn(.pluginWorkingDirectory)

        let reloaded = CodexRuntimeMetricsStore(
            defaults: fixture.defaults,
            storageKey: fixture.storageKey,
            wallClockNow: { Date(timeIntervalSince1970: 9_999) }
        )
        let snapshot = reloaded.snapshot()
        XCTAssertEqual(snapshot.observationStartedAt, fixture.startedAt)
        XCTAssertEqual(snapshot.turnRequests, 2)
        XCTAssertEqual(snapshot.capacityQueueIncidents, 1)
        XCTAssertEqual(snapshot.capacityQueueWaitMilliseconds, 1_250)
        XCTAssertEqual(snapshot.profileQueueIncidents, 1)
        XCTAssertEqual(snapshot.profileQueueWaitMilliseconds, 3_500)
        XCTAssertEqual(snapshot.profileQueueWebAccessIncidents, 1)
        XCTAssertEqual(snapshot.profileQueuePluginToggleIncidents, 1)
        XCTAssertEqual(snapshot.profileQueuePluginWorkingDirectoryIncidents, 0)
        XCTAssertEqual(snapshot.profileRespawns, 1)
        XCTAssertEqual(snapshot.profileRespawnWebAccessIncidents, 0)
        XCTAssertEqual(snapshot.profileRespawnPluginToggleIncidents, 0)
        XCTAssertEqual(
            snapshot.profileRespawnPluginWorkingDirectoryIncidents,
            1
        )

        let json = reloaded.exportJSON()
        XCTAssertTrue(json.contains(#""turnRequests" : 2"#))
        XCTAssertTrue(json.contains(#""observationStartedAt""#))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion",
                "observationStartedAt",
                "turnRequests",
                "capacityQueueIncidents",
                "capacityQueueWaitMilliseconds",
                "profileQueueIncidents",
                "profileQueueWaitMilliseconds",
                "profileQueueWebAccessIncidents",
                "profileQueuePluginToggleIncidents",
                "profileQueuePluginWorkingDirectoryIncidents",
                "profileRespawns",
                "profileRespawnWebAccessIncidents",
                "profileRespawnPluginToggleIncidents",
                "profileRespawnPluginWorkingDirectoryIncidents"
            ]
        )
    }

    func testMonotonicQueueObservationSeparatesCapacityAndProfilePhases() {
        let clock = MonotonicClock()
        let fixture = makeStore(monotonicNow: { clock.now })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        var observation = fixture.store.beginQueue(reason: .capacity)
        clock.advance(nanoseconds: 1_500_000_000)
        observation = fixture.store.transitionQueue(
            observation,
            to: .runtimeProfile([.webAccess, .pluginToggle])
        )
        clock.advance(nanoseconds: 250_000_000)
        fixture.store.finishQueue(observation)

        let snapshot = fixture.store.snapshot()
        XCTAssertEqual(snapshot.capacityQueueIncidents, 1)
        XCTAssertEqual(snapshot.capacityQueueWaitMilliseconds, 1_500)
        XCTAssertEqual(snapshot.profileQueueIncidents, 1)
        XCTAssertEqual(snapshot.profileQueueWaitMilliseconds, 250)
        XCTAssertEqual(snapshot.profileQueueWebAccessIncidents, 1)
        XCTAssertEqual(snapshot.profileQueuePluginToggleIncidents, 1)
    }

    func testResetRejectsQueueObservationFromPreviousPeriod() {
        let clock = MonotonicClock()
        let fixture = makeStore(monotonicNow: { clock.now })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let observation = fixture.store.beginQueue(
            reason: .runtimeProfile(.webAccess)
        )
        clock.advance(nanoseconds: 500_000_000)
        _ = fixture.store.reset()
        clock.advance(nanoseconds: 500_000_000)
        fixture.store.finishQueue(observation)

        let snapshot = fixture.store.snapshot()
        XCTAssertEqual(snapshot.profileQueueIncidents, 0)
        XCTAssertEqual(snapshot.profileQueueWaitMilliseconds, 0)
        XCTAssertEqual(snapshot.profileQueueWebAccessIncidents, 0)
    }

    func testResetRejectsDelayedMetricsFromPreviouslyAcceptedTurn() {
        let clock = MonotonicClock()
        let fixture = makeStore(monotonicNow: { clock.now })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let ticket = fixture.store.recordTurnRequest()
        _ = fixture.store.reset()
        let observation = fixture.store.beginQueue(
            reason: .runtimeProfile(.webAccess),
            ticket: ticket
        )
        clock.advance(nanoseconds: 500_000_000)
        fixture.store.finishQueue(observation)
        fixture.store.recordProfileRespawn(.webAccess, ticket: ticket)

        let snapshot = fixture.store.snapshot()
        XCTAssertEqual(snapshot.turnRequests, 0)
        XCTAssertEqual(snapshot.profileQueueIncidents, 0)
        XCTAssertEqual(snapshot.profileQueueWaitMilliseconds, 0)
        XCTAssertEqual(snapshot.profileQueueWebAccessIncidents, 0)
        XCTAssertEqual(snapshot.profileRespawns, 0)
        XCTAssertEqual(snapshot.profileRespawnWebAccessIncidents, 0)
    }

    func testResetStartsAFreshObservationPeriod() {
        let clock = WallClock(Date(timeIntervalSince1970: 1_234))
        let fixture = makeStore(wallClockNow: { clock.now })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.store.recordTurnRequest()
        fixture.store.recordProfileRespawn(.webAccess)
        clock.advance(seconds: 100)

        let reset = fixture.store.reset()

        XCTAssertEqual(
            reset.observationStartedAt,
            Date(timeIntervalSince1970: 1_334)
        )
        XCTAssertEqual(reset.turnRequests, 0)
        XCTAssertEqual(reset.profileRespawns, 0)
        XCTAssertEqual(fixture.store.snapshot(), reset)
    }

    func testDurationFormattingUsesStableCompactUnits() {
        XCTAssertEqual(CodexRuntimeMetricsFormatting.duration(milliseconds: 0), "0 ms")
        XCTAssertEqual(CodexRuntimeMetricsFormatting.duration(milliseconds: 999), "999 ms")
        XCTAssertEqual(CodexRuntimeMetricsFormatting.duration(milliseconds: 1_500), "1.5 s")
        XCTAssertEqual(CodexRuntimeMetricsFormatting.duration(milliseconds: 90_000), "1.5 min")
        XCTAssertEqual(CodexRuntimeMetricsFormatting.duration(milliseconds: 5_400_000), "1.5 h")
    }

    private func makeStore(
        wallClockNow: (@Sendable () -> Date)? = nil,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) -> (
        store: CodexRuntimeMetricsStore,
        defaults: UserDefaults,
        suiteName: String,
        storageKey: String,
        startedAt: Date
    ) {
        let suiteName = "CodexRuntimeMetricsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storageKey = "metrics"
        let startedAt = Date(timeIntervalSince1970: 1_234)
        let effectiveWallClockNow = wallClockNow ?? { startedAt }
        return (
            CodexRuntimeMetricsStore(
                defaults: defaults,
                storageKey: storageKey,
                wallClockNow: effectiveWallClockNow,
                monotonicNow: monotonicNow
            ),
            defaults,
            suiteName,
            storageKey,
            startedAt
        )
    }
}

private final class WallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class MonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000

    var now: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(nanoseconds: UInt64) {
        lock.lock()
        value += nanoseconds
        lock.unlock()
    }
}
#endif
