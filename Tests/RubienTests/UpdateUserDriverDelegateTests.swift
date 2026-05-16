#if canImport(Sparkle)
import XCTest
import Sparkle
@testable import Rubien

final class UpdateUserDriverDelegateTests: XCTestCase {
    @MainActor
    func testScheduledUpdateInvokesCallbackAndSuppressesUI() throws {
        let delegate = UpdateUserDriverDelegate()
        var capturedVersion: String?
        delegate.onUpdateReady = { capturedVersion = $0 }

        // Sparkle 2.9 marks the dictionary initializer as deprecated for
        // app-level callers (the designated init lives in a private header),
        // but it remains the only public API for synthesizing an item in
        // tests. Suppress the deprecation warning locally.
        @available(*, deprecated)
        func makeItem() -> (SUAppcastItem?, NSString?) {
            var failureReason: NSString?
            let item = SUAppcastItem(
                dictionary: [
                    "sparkle:version": "2",
                    "sparkle:shortVersionString": "0.1.1",
                    "enclosure": [
                        "url": "https://example.invalid/Rubien-0.1.1.dmg",
                        "sparkle:edSignature": "abc=",
                        "length": "100"
                    ] as [String: Any]
                ] as [AnyHashable: Any],
                relativeTo: nil,
                failureReason: &failureReason
            )
            return (item, failureReason)
        }
        let (rawItem, failureReason) = makeItem()
        let item = try XCTUnwrap(rawItem, "SUAppcastItem init failed: \(failureReason ?? "")")

        let suppressed = delegate.standardUserDriverShouldHandleShowingScheduledUpdate(
            item,
            andInImmediateFocus: false
        )

        XCTAssertFalse(suppressed, "Delegate must return false to suppress Sparkle's default UI for scheduled checks")
        XCTAssertEqual(capturedVersion, "0.1.1", "Callback must fire with the appcast item's shortVersionString")
    }
}
#endif
