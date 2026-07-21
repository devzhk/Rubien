import Foundation
import XCTest
@testable import RubienCore

final class BrowserClipContractTests: XCTestCase {
    func testDeepLinksRoundTripImportedDestinations() throws {
        let destinations: [BrowserClipDeepLinkDestination] = [
            .reference(42),
            .pendingIntake(73),
        ]

        for destination in destinations {
            let url = try XCTUnwrap(BrowserClipDeepLink.url(for: destination))
            XCTAssertEqual(BrowserClipDeepLink.parse(url), destination)
        }

        XCTAssertEqual(
            BrowserClipDeepLink.url(for: .reference(42))?.absoluteString,
            "rubien://reference/42"
        )
        XCTAssertEqual(
            BrowserClipDeepLink.url(for: .pendingIntake(73))?.absoluteString,
            "rubien://pending-intake/73"
        )
    }

    func testDestinationRequiresExactlyOnePositiveIdentifier() {
        XCTAssertEqual(
            BrowserClipDeepLink.destination(referenceID: 42, intakeID: nil),
            .reference(42)
        )
        XCTAssertEqual(
            BrowserClipDeepLink.destination(referenceID: nil, intakeID: 73),
            .pendingIntake(73)
        )
        XCTAssertNil(BrowserClipDeepLink.destination(referenceID: nil, intakeID: nil))
        XCTAssertNil(BrowserClipDeepLink.destination(referenceID: 42, intakeID: 73))
        XCTAssertNil(BrowserClipDeepLink.destination(referenceID: 0, intakeID: nil))
    }

    func testParserRejectsUntrustedOrMalformedDeepLinks() {
        let invalid = [
            "https://reference/42",
            "rubien://unknown/42",
            "rubien://reference/0",
            "rubien://reference/-1",
            "rubien://reference/42/extra",
            "rubien://reference/42?other=1",
            "rubien://user@reference/42",
        ]

        for rawURL in invalid {
            XCTAssertNil(
                URL(string: rawURL).flatMap(BrowserClipDeepLink.parse),
                rawURL
            )
        }
    }
}
