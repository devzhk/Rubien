#if os(macOS)
import XCTest
import SwiftUI
import CloudKit
@testable import Rubien
@testable import RubienSync

/// Smoke test: `SyncStatusIcon` must be constructible (and the per-case
/// symbol/color/accessibility switches in its body must resolve) for every
/// `SyncStatus` case currently defined. Guard against accidentally dropping
/// a case mapping if a new `SyncStatus` case is added later.
///
/// This is intentionally a load-only test — SwiftUI view-inspection
/// libraries are not in the project, so we cannot behaviorally assert that
/// the `.symbolEffect(.pulse, options: .repeating, ...)` modifier is gone.
/// Manual verification (large-PDF scroll with sync ON) is the real proof
/// for that.
@MainActor
final class SyncStatusIconTests: XCTestCase {

    func testIconConstructsForEveryStatus() {
        let quotaError = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.quotaExceeded.rawValue
        ))
        let cases: [SyncStatus] = [
            .disabled,
            .unavailable(reason: "test"),
            .signedOut,
            .idle,
            .syncing,
            .error(quotaError)
        ]
        for status in cases {
            let host = NSHostingController(rootView: SyncStatusIcon(status: status))
            XCTAssertNotNil(host.view, "icon must render for \(status)")
        }
    }
}
#endif
