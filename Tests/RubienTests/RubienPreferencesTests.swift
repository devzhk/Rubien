#if canImport(Rubien)
import XCTest
@testable import Rubien

/// Tests for `RubienPreferences` flags backed by `UserDefaults.standard`.
///
/// Each test snapshots the prior value of the key it mutates and restores it
/// in `tearDown`, since `RubienPreferences` reads/writes the shared standard
/// suite (the production code path) rather than an injectable suite.
final class RubienPreferencesTests: XCTestCase {

    // MARK: - pdfAssetSyncEnabled

    private var savedPDFAssetSyncEnabled: Bool?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Snapshot only if a value is set; preserve "unset" state otherwise so
        // the default-false test sees a clean key.
        let key = RubienPreferences.pdfAssetSyncEnabledKey
        if UserDefaults.standard.object(forKey: key) != nil {
            savedPDFAssetSyncEnabled = UserDefaults.standard.bool(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        let key = RubienPreferences.pdfAssetSyncEnabledKey
        if let saved = savedPDFAssetSyncEnabled {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        savedPDFAssetSyncEnabled = nil
        super.tearDown()
    }

    func testPdfAssetSyncEnabledDefaultsToTruePostB8() {
        // Phase E Task 35 flipped the default. Unset → treat as true.
        XCTAssertTrue(
            RubienPreferences.pdfAssetSyncEnabled,
            "post-Phase-E default must be true; users opt out by setting false"
        )
    }

    func testPdfAssetSyncEnabledRoundTrips() {
        RubienPreferences.pdfAssetSyncEnabled = true
        XCTAssertTrue(RubienPreferences.pdfAssetSyncEnabled)
        RubienPreferences.pdfAssetSyncEnabled = false
        XCTAssertFalse(RubienPreferences.pdfAssetSyncEnabled)
    }
}
#endif
