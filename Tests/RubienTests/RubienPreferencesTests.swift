#if os(macOS)
import XCTest
import AppKit
@testable import Rubien

/// Tests for `RubienPreferences` flags backed by `UserDefaults.standard`.
///
/// Each test snapshots the prior value of the key it mutates and restores it
/// in `tearDown`, since `RubienPreferences` reads/writes the shared standard
/// suite (the production code path) rather than an injectable suite.
final class RubienPreferencesTests: XCTestCase {

    // MARK: - pdfAssetSyncEnabled

    private var savedPDFAssetSyncEnabled: Bool?
    private var savedThemeRaw: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Snapshot only if a value is set; preserve "unset" state otherwise so
        // the default-false test sees a clean key.
        let key = RubienPreferences.pdfAssetSyncEnabledKey
        if UserDefaults.standard.object(forKey: key) != nil {
            savedPDFAssetSyncEnabled = UserDefaults.standard.bool(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: key)

        let themeKey = RubienPreferences.themePreferenceKey
        savedThemeRaw = UserDefaults.standard.string(forKey: themeKey)
        UserDefaults.standard.removeObject(forKey: themeKey)
    }

    override func tearDown() {
        let key = RubienPreferences.pdfAssetSyncEnabledKey
        if let saved = savedPDFAssetSyncEnabled {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        savedPDFAssetSyncEnabled = nil

        let themeKey = RubienPreferences.themePreferenceKey
        if let raw = savedThemeRaw {
            UserDefaults.standard.set(raw, forKey: themeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: themeKey)
        }
        savedThemeRaw = nil
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

    // MARK: - ColorSchemePreference enum

    func testColorSchemePreferenceRawValueRoundTrips() {
        for pref in ColorSchemePreference.allCases {
            XCTAssertEqual(ColorSchemePreference(rawValue: pref.rawValue), pref)
        }
    }

    func testColorSchemeNSAppearanceMapping() {
        XCTAssertNil(ColorSchemePreference.system.nsAppearance,
                     "system must map to nil so the app follows the OS live")
        XCTAssertEqual(ColorSchemePreference.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(ColorSchemePreference.dark.nsAppearance?.name, .darkAqua)
    }

    // MARK: - colorScheme accessor (pure UserDefaults; no NSApp.appearance side effect)

    func testColorSchemeDefaultsToSystemWhenUnset() {
        // setUp removed the key, so this exercises the unset path.
        XCTAssertEqual(RubienPreferences.colorScheme, .system)
    }

    func testColorSchemeIgnoresInvalidRawValue() {
        UserDefaults.standard.set("chartreuse", forKey: RubienPreferences.themePreferenceKey)
        XCTAssertEqual(RubienPreferences.colorScheme, .system,
                       "an unrecognized stored value must fall back to .system, not crash")
    }

    func testColorSchemePersistenceRoundTrips() {
        RubienPreferences.colorScheme = .dark
        XCTAssertEqual(RubienPreferences.colorScheme, .dark)
        RubienPreferences.colorScheme = .light
        XCTAssertEqual(RubienPreferences.colorScheme, .light)
        RubienPreferences.colorScheme = .system
        XCTAssertEqual(RubienPreferences.colorScheme, .system)
    }
}
#endif
