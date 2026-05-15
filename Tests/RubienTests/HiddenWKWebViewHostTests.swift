#if canImport(Rubien)
import WebKit
import XCTest
@testable import Rubien
@testable import RubienCore

final class HiddenWKWebViewHostTests: XCTestCase {
    func testBackgroundWebViewConfigurationSuppressesMediaPlayback() {
        let configuration = WKWebViewConfiguration()

        HiddenWKWebViewMediaGuard.configure(configuration)

        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertFalse(configuration.allowsAirPlayForMediaPlayback)
        XCTAssertTrue(
            configuration.userContentController.userScripts.contains {
                $0.injectionTime == .atDocumentStart &&
                $0.source.contains("HTMLMediaElement") &&
                $0.source.contains("pause()")
            }
        )
    }
}
#endif
