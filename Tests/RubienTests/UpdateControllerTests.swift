#if canImport(Sparkle)
import XCTest
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
    var automaticallyChecksForUpdates: Bool = false
    var automaticallyDownloadsUpdates: Bool = false
    var canCheckForUpdates: Bool = true
    var lastUpdateCheckDate: Date? = nil

    var checkForUpdatesCallCount = 0
    var checkForUpdatesInBackgroundCallCount = 0

    func checkForUpdates() { checkForUpdatesCallCount += 1 }
    func checkForUpdatesInBackground() { checkForUpdatesInBackgroundCallCount += 1 }
}
#endif
