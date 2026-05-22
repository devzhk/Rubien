#if os(macOS)
import XCTest
import SwiftUI
import GRDB
@testable import Rubien
@testable import RubienCore
@testable import RubienSync

/// The non-observing `\.syncCoordinator` environment key must surface the
/// same instance that's injected at the root scene. (Subscription semantics —
/// "does NOT re-render on @Published flips" — are structural and guaranteed
/// by SwiftUI's `@Environment` vs `@EnvironmentObject` split; this test just
/// verifies plumbing.)
@MainActor
final class SyncCoordinatorEnvironmentTests: XCTestCase {

    func testEnvironmentKeyDefaultIsNil() {
        XCTAssertNil(EnvironmentValues().syncCoordinator)
    }

    func testEnvironmentKeyRoundTripsCoordinator() throws {
        let db = try AppDatabase(DatabaseQueue())
        let coordinator = SyncCoordinator(appDatabase: db)
        var env = EnvironmentValues()
        env.syncCoordinator = coordinator
        XCTAssertTrue(env.syncCoordinator === coordinator)
    }
}
#endif
