#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

/// Regression tests for the observer-retention bug: GRDB's
/// `.observerLifetime` extent holds only a **weak** reference, so if
/// `SyncedLibrary` doesn't retain the observer strongly, it deallocates
/// immediately after `installTransactionObserver` returns. Commits then
/// silently stop reaching the engine and only the startup-reconciliation
/// pass ever syncs.
@available(macOS 14.0, iOS 17.0, *)
final class SyncTransactionObserverRetentionTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testInstallRetainsObserverBeyondTheInstallCall() async throws {
        let library = SyncedLibrary(appDatabase: db)

        let hadObserverBeforeInstall = await library.hasTransactionObserver
        XCTAssertFalse(hadObserverBeforeInstall, "precondition: no observer before install")

        await library.installTransactionObserver()

        let hasObserverAfterInstall = await library.hasTransactionObserver
        XCTAssertTrue(
            hasObserverAfterInstall,
            "SyncedLibrary must hold a strong reference to the observer; GRDB's `.observerLifetime` extent is weak, so a local-var-only install would deallocate immediately and commits would never reach the engine"
        )
    }

    func testRemoveDropsTheObserver() async throws {
        let library = SyncedLibrary(appDatabase: db)
        await library.installTransactionObserver()
        await library.removeTransactionObserver()

        let stillThere = await library.hasTransactionObserver
        XCTAssertFalse(
            stillThere,
            "sync-off must release the observer so subsequent commits stop forwarding to the engine"
        )
    }

    func testRemoveWithoutInstallIsNoOp() async throws {
        let library = SyncedLibrary(appDatabase: db)
        // Defensive: lifecycle code may pair install/remove under error
        // paths where install never happened. Must not throw or crash.
        await library.removeTransactionObserver()
        let hasObserver = await library.hasTransactionObserver
        XCTAssertFalse(hasObserver)
    }
}
#endif
