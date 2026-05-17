#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

/// Predicate-level tests for `AddByIdentifierView`'s "Also download PDF"
/// toggle gating and the onSave-time `shouldDownload` computation.
///
/// These tests deliberately do NOT stand up a SwiftUI environment. The view's
/// gating logic is extracted as `static` helpers on `AddByIdentifierView` so a
/// pure-Swift test can exercise the exact predicate the view renders. If the
/// view drifts away from these helpers, the visible coverage gap will be
/// caught here, not in a UI-screenshot test.
final class AddByIdentifierGatingTests: XCTestCase {

    // MARK: - toggleDisabled

    func testToggleDisabledWithNoURLAndNoDOI() {
        XCTAssertTrue(AddByIdentifierView.toggleDisabled(
            canDownloadPDF: false,
            preferredPDFURL: nil
        ))
    }

    func testToggleEnabledByDOI() {
        XCTAssertFalse(AddByIdentifierView.toggleDisabled(
            canDownloadPDF: true,
            preferredPDFURL: nil
        ))
    }

    func testToggleEnabledByScrapedURL() {
        XCTAssertFalse(AddByIdentifierView.toggleDisabled(
            canDownloadPDF: false,
            preferredPDFURL: "https://example.com/foo.pdf"
        ))
    }

    func testToggleEnabledByBoth() {
        XCTAssertFalse(AddByIdentifierView.toggleDisabled(
            canDownloadPDF: true,
            preferredPDFURL: "https://example.com/foo.pdf"
        ))
    }

    // MARK: - shouldDownload

    func testOnSaveDownloadWhenToggleCheckedAndURLPresent() {
        XCTAssertTrue(AddByIdentifierView.shouldDownload(
            toggleChecked: true,
            canDownloadPDF: false,
            preferredPDFURL: "https://example.com/foo.pdf"
        ))
    }

    func testOnSaveDownloadWhenToggleCheckedAndDOIPresent() {
        XCTAssertTrue(AddByIdentifierView.shouldDownload(
            toggleChecked: true,
            canDownloadPDF: true,
            preferredPDFURL: nil
        ))
    }

    func testOnSaveNoDownloadWhenToggleUnchecked() {
        XCTAssertFalse(AddByIdentifierView.shouldDownload(
            toggleChecked: false,
            canDownloadPDF: true,
            preferredPDFURL: "https://example.com/foo.pdf"
        ))
    }

    func testOnSaveNoDownloadWhenNothingAvailable() {
        XCTAssertFalse(AddByIdentifierView.shouldDownload(
            toggleChecked: true,
            canDownloadPDF: false,
            preferredPDFURL: nil
        ))
    }
}
#endif
