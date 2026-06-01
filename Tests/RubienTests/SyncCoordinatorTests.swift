#if os(macOS)
import XCTest
import Foundation
import GRDB
import CloudKit
@testable import Rubien
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, *)
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    private var db: AppDatabase!
    private var defaults: UserDefaults!
    private var tmpLockURL: URL!
    private let suiteName = "rubien.test.sync.\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        // Per-test sync lock so tests don't collide with a real running
        // Rubien.app holding the production lock at SyncFileLock.defaultURL.
        tmpLockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-test-lock-\(UUID().uuidString).lock")
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        if let tmpLockURL { try? FileManager.default.removeItem(at: tmpLockURL) }
        db = nil
        super.tearDown()
    }

    func testInitialStateRespectsUserDefaults() {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults
        )
        XCTAssertFalse(coordinator.userEnabled, "default must be false")
        XCTAssertEqual(coordinator.status, .disabled)
    }

    func testInitialStateReadsPersistedEnabled() {
        defaults.set(true, forKey: "rubien.sync.enabled")
        defaults.set(true, forKey: "rubien.sync.didConfirmFirstRun")

        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults
        )
        XCTAssertTrue(
            coordinator.userEnabled,
            "previously-enabled state must survive a relaunch"
        )
    }

    // MARK: - Confirm flow

    func testTogglingOnShowsPendingConfirmWithoutPersisting() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        coordinator.handleToggle(true)

        XCTAssertTrue(coordinator.pendingConfirm, "confirm sheet must be pending")
        XCTAssertFalse(
            defaults.bool(forKey: SyncCoordinator.DefaultsKey.enabled),
            "UserDefaults must not be written until user confirms — prevents the app-quit-mid-sheet inconsistency"
        )
    }

    func testToggleBindingReflectsPendingConfirm() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        XCTAssertFalse(coordinator.toggleBinding.wrappedValue)

        coordinator.handleToggle(true)
        XCTAssertTrue(
            coordinator.toggleBinding.wrappedValue,
            "binding reads true while pendingConfirm is set, so the toggle stays visually ON during the confirm sheet"
        )
    }

    func testCancelConfirmClearsPendingAndLeavesDisabled() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        coordinator.handleToggle(true)
        coordinator.cancelConfirm()

        XCTAssertFalse(coordinator.pendingConfirm)
        XCTAssertFalse(coordinator.userEnabled)
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(defaults.bool(forKey: SyncCoordinator.DefaultsKey.enabled))
    }

    func testConfirmEnablePersistsAndSetsFlag() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        coordinator.handleToggle(true)
        coordinator.confirmEnable()

        XCTAssertFalse(coordinator.pendingConfirm)
        XCTAssertTrue(coordinator.userEnabled)
        XCTAssertTrue(defaults.bool(forKey: SyncCoordinator.DefaultsKey.enabled))
        XCTAssertTrue(defaults.bool(forKey: SyncCoordinator.DefaultsKey.didConfirmFirstRun))
    }

    func testSecondToggleSkipsConfirmSheet() {
        defaults.set(true, forKey: SyncCoordinator.DefaultsKey.didConfirmFirstRun)
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)

        coordinator.handleToggle(true)
        XCTAssertFalse(
            coordinator.pendingConfirm,
            "didConfirmFirstRun == true means we skip the sheet on subsequent toggles"
        )
        XCTAssertTrue(coordinator.userEnabled)
    }

    // MARK: - Probe tests

    func testProbeUnavailableWhenEntitlementAbsent() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { false },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected .unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("entitlement"))
    }

    func testProbeSignedOutWhenTokenNil() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { nil },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        XCTAssertEqual(result, .signedOut)
    }

    func testProbeUnavailableWhenCKContainerThrows() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in
                    NSException(name: .internalInconsistencyException, reason: "no container", userInfo: nil)
                },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected .unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("Container"))
    }

    func testProbeSignedOutWhenAccountStatusNoAccount() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .noAccount }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        XCTAssertEqual(result, .signedOut)
    }

    func testProbeIdleWhenAllPass() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        XCTAssertEqual(result, .idle)
    }

    // MARK: - startSync / stopSync integration

    /// Returns a `SyncedLibrary` factory that creates a library without
    /// calling `start()`. This avoids `CKSyncEngine` init which requires
    /// CloudKit entitlements and crashes in an unentitled XCTest process.
    private func stubLibraryFactory() -> @Sendable (AppDatabase) async -> SyncedLibrary {
        return { db in SyncedLibrary(appDatabase: db) }
    }

    func testStartSyncSetsUnavailableWhenProbeFails() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { false },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            )
        )
        await coordinator.performStartSyncForTest()

        guard case .unavailable = coordinator.status else {
            return XCTFail("expected .unavailable, got \(coordinator.status)")
        }
        XCTAssertNil(coordinator.librarySnapshotForTest, "no library instantiated when probes fail")
    }

    func testStopSyncClearsLibraryAndCancelsStatusTask() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            ),
            makeLibrary: stubLibraryFactory(),
            startLibrary: { _ in },
            lockURL: tmpLockURL
        )
        await coordinator.performStartSyncForTest()
        XCTAssertNotNil(coordinator.librarySnapshotForTest)

        await coordinator.performStopSyncForTest()
        XCTAssertNil(coordinator.librarySnapshotForTest)
        XCTAssertEqual(coordinator.status, .disabled)
    }

    func testRapidToggleDoesNotLeakStaleLibrary() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: .init(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            ),
            makeLibrary: stubLibraryFactory(),
            startLibrary: { _ in },
            lockURL: tmpLockURL
        )
        async let first: Void = coordinator.performStartSyncForTest()
        await coordinator.performStopSyncForTest()
        async let second: Void = coordinator.performStartSyncForTest()

        _ = await (first, second)

        XCTAssertNotNil(coordinator.librarySnapshotForTest)
    }

    func testStartIfEnabledLaunchesSyncWhenUserDefaultsPersisted() async {
        defaults.set(true, forKey: SyncCoordinator.DefaultsKey.enabled)
        defaults.set(true, forKey: SyncCoordinator.DefaultsKey.didConfirmFirstRun)

        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: .init(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            ),
            makeLibrary: stubLibraryFactory(),
            startLibrary: { _ in },
            lockURL: tmpLockURL
        )
        await coordinator.startIfEnabled()
        XCTAssertNotNil(
            coordinator.librarySnapshotForTest,
            "startIfEnabled must launch the library when userDefaults says enabled"
        )
    }

    func testStartIfEnabledIsNoOpWhenDisabled() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        await coordinator.startIfEnabled()
        XCTAssertNil(coordinator.librarySnapshotForTest)
        XCTAssertEqual(coordinator.status, .disabled)
    }

    // MARK: - Status mapping rule

    func testMissingEntitlementRemapsToUnavailable() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        let missing = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.missingEntitlement.rawValue
        ))
        let mapped = await coordinator.mapStatusForTest(.error(missing))
        guard case .unavailable = mapped else {
            return XCTFail("missingEntitlement must map to .unavailable, got \(mapped)")
        }
    }

    func testOtherErrorCodesPassThrough() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        let quota = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.quotaExceeded.rawValue
        ))
        let mapped = await coordinator.mapStatusForTest(.error(quota))
        XCTAssertEqual(mapped, .error(quota))
    }

    func testNonErrorStatusPassesThrough() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        let idleMapped = await coordinator.mapStatusForTest(.idle)
        XCTAssertEqual(idleMapped, .idle)
        let syncingMapped = await coordinator.mapStatusForTest(.syncing)
        XCTAssertEqual(syncingMapped, .syncing)
    }

    // MARK: - Idle-fetch backoff

    func testNextBackoffResetsToBaseOnSuccess() {
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 360, failed: false, base: 90), 90)
    }

    func testNextBackoffDoublesOnFailure() {
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 90, failed: true, base: 90), 180)
    }

    func testNextBackoffCapsAtMaxIdleInterval() {
        // 600 * 2 = 1200, capped to maxIdleFetchInterval (900).
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 600, failed: true, base: 90), 900)
        // Already at cap stays at cap.
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 900, failed: true, base: 90), 900)
    }

    // MARK: - Incremental-fetch triggers

    /// Thread-safe call counter for the injected fetch seam. Always reports
    /// success — failure backoff is covered deterministically by the pure
    /// `nextBackoff` tests, not by driving a failing fetch through the timer.
    private actor FetchSpy {
        private(set) var count = 0
        func record() -> Bool { count += 1; return true }
    }

    private func allPassProbes() -> SyncCoordinator.Probes {
        SyncCoordinator.Probes(
            bundleHasEntitlement: { true },
            ubiquityIdentityToken: { "token" as NSCoding },
            tryCKContainerInit: { _ in nil },
            accountStatus: { _ in .available }
        )
    }

    private func makeTriggerCoordinator(
        spy: FetchSpy,
        interval: TimeInterval,
        appActive: @escaping @MainActor () -> Bool
    ) -> SyncCoordinator {
        SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: allPassProbes(),
            makeLibrary: stubLibraryFactory(),
            startLibrary: { _ in },
            fetchLibrary: { _ in await spy.record() },
            idleFetchInterval: interval,
            isAppActive: appActive,
            lockURL: tmpLockURL
        )
    }

    // All trigger tests start with `appActive: { false }` so `performStartSync`
    // (after Task 5 wires the launch hook) does NOT auto-fire — each test drives
    // the handler/tick directly, staying independently verifiable. No assertion
    // depends on `Task.sleep` elapsing: per-tick behaviour is exercised through
    // the deterministic `runIdlePollTickForTest` seam.

    func testDidBecomeActiveFiresImmediateFetchAndStartsTimer() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()
        let beforeActivate = await spy.count
        XCTAssertEqual(beforeActivate, 0, "inactive start fires nothing")

        await coordinator.handleDidBecomeActive()
        let afterActivate = await spy.count
        XCTAssertEqual(afterActivate, 1, "activate fires exactly one immediate fetch")
        XCTAssertEqual(coordinator.idleTimerStartCountForTest, 1, "activate starts one idle timer")

        await coordinator.performStopSyncForTest()
    }

    func testIdlePollTickFetchesWhenActive() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()

        let outcome = await coordinator.runIdlePollTickForTest()
        XCTAssertEqual(outcome, .completed(ok: true), "an active tick fetches")
        let count = await spy.count
        XCTAssertEqual(count, 1, "the tick drove exactly one fetch")

        await coordinator.performStopSyncForTest()
    }

    func testIdlePollTickIsNoOpForStaleGeneration() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()
        let staleGeneration = coordinator.lifecycleGenerationForTest

        await coordinator.performStopSyncForTest()   // bumps the generation

        let outcome = await coordinator.runIdlePollTickForTest(generation: staleGeneration)
        XCTAssertEqual(outcome, .stopped, "a tick from a prior lifecycle must stop, not fetch")
        let count = await spy.count
        XCTAssertEqual(count, 0, "no fetch after teardown")
    }

    func testResignCancelsTimerSoReactivateStartsAFreshOne() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()

        await coordinator.handleDidBecomeActive()
        XCTAssertEqual(coordinator.idleTimerStartCountForTest, 1)

        coordinator.handleWillResignActive()           // cancels + nils the task
        await coordinator.handleDidBecomeActive()       // guard sees nil → starts a NEW timer
        XCTAssertEqual(
            coordinator.idleTimerStartCountForTest, 2,
            "resign must cancel the timer so the next activate starts a fresh one"
        )

        await coordinator.performStopSyncForTest()
    }

    func testDoubleActivateDoesNotStackTimers() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()

        await coordinator.handleDidBecomeActive()
        await coordinator.handleDidBecomeActive()          // no intervening resign → guard blocks
        XCTAssertEqual(
            coordinator.idleTimerStartCountForTest, 1,
            "a second activate without a resign must not start a second timer"
        )

        await coordinator.performStopSyncForTest()
    }
}
#endif
