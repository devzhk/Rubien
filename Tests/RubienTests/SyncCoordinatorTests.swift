import XCTest
import Foundation
import GRDB
@testable import Rubien
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, *)
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    private var db: AppDatabase!
    private var defaults: UserDefaults!
    private let suiteName = "rubien.test.sync.\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
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
}
