#if canImport(Sparkle)
import XCTest
import Combine
@testable import Rubien

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testInitialStateIsClean() {
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        XCTAssertFalse(controller.updateReadyToInstall)
        XCTAssertNil(controller.pendingVersion)
    }

    func testUpdateReadyFlipsWhenDelegateFires() {
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        controller.simulateDelegateUpdateReady(version: "0.1.1")

        XCTAssertTrue(controller.updateReadyToInstall)
        XCTAssertEqual(controller.pendingVersion, "0.1.1")
    }

    func testCheckNowCallsUpdater() {
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        controller.checkNow()

        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)
    }

    func testKickLaunchBackgroundCheckRunsWhenAutomaticEnabled() {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        let controller = UpdateController(updater: fake)

        controller.kickLaunchBackgroundCheck()

        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 1)
        // Must not go through the user-initiated path (which shows Sparkle's
        // standard UI instead of the gentle toolbar icon).
        XCTAssertEqual(fake.checkForUpdatesCallCount, 0)
    }

    func testKickLaunchBackgroundCheckSkipsWhenAutomaticDisabled() {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = false
        let controller = UpdateController(updater: fake)

        controller.kickLaunchBackgroundCheck()

        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)
    }

    func testKickLaunchBackgroundCheckIsIdempotent() {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        let controller = UpdateController(updater: fake)

        controller.kickLaunchBackgroundCheck()
        controller.kickLaunchBackgroundCheck()
        controller.kickLaunchBackgroundCheck()

        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 1)
    }

    func testLaunchCheckWaitsForStartupSchedulingToFinish() async {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        fake.canCheckForUpdates = false
        fake.sessionInProgress = true
        let controller = UpdateController(updater: fake)

        controller.kickLaunchBackgroundCheck()
        controller.kickLaunchBackgroundCheck()
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)

        // Sparkle may set readiness before it clears its scheduling session.
        fake.canCheckForUpdates = true
        await flushUpdaterChanges()
        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)

        fake.sessionInProgress = false
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0, "Do not reenter Sparkle's callback")
        await flushUpdaterChanges()
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 1)

        fake.sessionInProgress = true
        fake.sessionInProgress = false
        controller.kickLaunchBackgroundCheck()
        await flushUpdaterChanges()
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 1)
        XCTAssertEqual(fake.checkForUpdatesCallCount, 0)
    }

    func testScheduledCheckSatisfiesPendingLaunchRequest() async {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        fake.sessionInProgress = true
        let controller = UpdateController(updater: fake)
        controller.kickLaunchBackgroundCheck()

        let checkedAt = Date(timeIntervalSince1970: 100)
        fake.lastUpdateCheckDate = checkedAt
        fake.sessionInProgress = false
        await flushUpdaterChanges()

        XCTAssertEqual(controller.lastCheckDate, checkedAt)
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)
    }

    func testScheduledCheckBeforeWindowAppearsSatisfiesLaunchRequest() {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        let controller = UpdateController(updater: fake)
        fake.lastUpdateCheckDate = Date(timeIntervalSince1970: 100)

        controller.kickLaunchBackgroundCheck()

        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)
    }

    func testOptOutWhileWaitingCancelsLaunchCheck() async {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        fake.sessionInProgress = true
        let controller = UpdateController(updater: fake)
        controller.kickLaunchBackgroundCheck()

        controller.automaticallyChecks = false
        fake.sessionInProgress = false
        controller.automaticallyChecks = true
        await flushUpdaterChanges()

        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)
    }

    func testManualCheckReplacesPendingLaunchCheck() async {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        fake.sessionInProgress = true
        let controller = UpdateController(updater: fake)
        controller.kickLaunchBackgroundCheck()

        controller.checkNow()
        fake.sessionInProgress = false
        await flushUpdaterChanges()

        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)
    }

    func testReadinessAndLastCheckDateStayCurrent() async {
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)
        fake.canCheckForUpdates = false
        fake.lastUpdateCheckDate = Date(timeIntervalSince1970: 100)
        await flushUpdaterChanges()

        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertEqual(controller.lastCheckDate, fake.lastUpdateCheckDate)
        fake.canCheckForUpdates = true
        await flushUpdaterChanges()
        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)
    }

    func testPendingLaunchObservationDoesNotRetainController() async {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        fake.sessionInProgress = true
        var controller: UpdateController? = UpdateController(updater: fake)
        weak var weakController = controller
        controller?.kickLaunchBackgroundCheck()
        controller = nil
        fake.sessionInProgress = false
        await flushUpdaterChanges()

        XCTAssertNil(weakController)
        XCTAssertEqual(fake.checkForUpdatesInBackgroundCallCount, 0)
    }

    private func flushUpdaterChanges() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testAutomaticallyChecksRoundTrip() {
        let fake = FakeUpdater()
        fake.automaticallyChecksForUpdates = true
        let controller = UpdateController(updater: fake)

        controller.automaticallyChecks = false
        XCTAssertFalse(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyChecks)
    }

    func testAutomaticallyDownloadsRoundTrip() {
        let fake = FakeUpdater()
        fake.automaticallyDownloadsUpdates = true
        let controller = UpdateController(updater: fake)

        controller.automaticallyDownloads = false
        XCTAssertFalse(fake.automaticallyDownloadsUpdates)
        XCTAssertFalse(controller.automaticallyDownloads)
    }

    func testDelegateIsStronglyRetained() {
        // Regression test: SPUStandardUpdaterController holds delegates weakly.
        // If UpdateController's delegate property is weak, the delegate is
        // deallocated right after init and update-ready signals never fire.
        let fake = FakeUpdater()
        let controller = UpdateController(updater: fake)

        XCTAssertNotNil(controller.delegateForTesting, "Delegate must be alive after init")
    }

    func testConvenienceInitProducesAliveController() {
        // Smoke test: the convenience init must produce a controller whose
        // underlying SPUStandardUpdaterController is retained, otherwise
        // SPUUpdater is orphaned and background checks never fire.
        let controller = UpdateController()
        XCTAssertNotNil(controller.delegateForTesting,
            "Delegate must be alive after convenience init")
        // We can't directly assert on the private standardController, but
        // canCheckForUpdates being accessible (and not crashing) is the
        // observable proof that the SPUUpdater chain is intact.
        _ = controller.canCheckForUpdates
    }
}

@MainActor
final class FakeUpdater: UpdaterProtocol {
    private let changes = PassthroughSubject<Void, Never>()
    var stateChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    var automaticallyChecksForUpdates: Bool = false { didSet { changes.send() } }
    var automaticallyDownloadsUpdates: Bool = false
    var canCheckForUpdates: Bool = true { didSet { changes.send() } }
    var sessionInProgress: Bool = false { didSet { changes.send() } }
    var lastUpdateCheckDate: Date? = nil { didSet { changes.send() } }

    var checkForUpdatesCallCount = 0
    var checkForUpdatesInBackgroundCallCount = 0

    func checkForUpdates() { checkForUpdatesCallCount += 1 }
    func checkForUpdatesInBackground() { checkForUpdatesInBackgroundCallCount += 1 }
}
#endif
