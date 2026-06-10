#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import Rubien

/// Tests for the accent-color hex helpers, the `accentColorHex` preference,
/// and `AccentColorManager` (via throwaway instances, not the lazily latched
/// singleton, so test ordering can't couple to process-global state).
final class AccentColorTests: XCTestCase {

    // MARK: - ColorHex strict parsing

    func testParsesValidHexWithAndWithoutHash() throws {
        let withHash = try XCTUnwrap(ColorHex.components(from: "#3379D8"))
        let without = try XCTUnwrap(ColorHex.components(from: "3379D8"))
        XCTAssertEqual(withHash.r, Double(0x33) / 255, accuracy: 1e-9)
        XCTAssertEqual(withHash.g, Double(0x79) / 255, accuracy: 1e-9)
        XCTAssertEqual(withHash.b, Double(0xD8) / 255, accuracy: 1e-9)
        XCTAssertEqual(withHash.r, without.r)
        XCTAssertEqual(withHash.g, without.g)
        XCTAssertEqual(withHash.b, without.b)
    }

    func testParsesBoundaryValues() throws {
        let black = try XCTUnwrap(ColorHex.components(from: "#000000"))
        XCTAssertEqual(black.r, 0); XCTAssertEqual(black.g, 0); XCTAssertEqual(black.b, 0)
        let white = try XCTUnwrap(ColorHex.components(from: "#FFFFFF"))
        XCTAssertEqual(white.r, 1); XCTAssertEqual(white.g, 1); XCTAssertEqual(white.b, 1)
    }

    func testRejectsMalformedHex() {
        // Strictness matters: a lenient parse would silently pin the accent
        // to near-black on a corrupt stored value.
        for bad in ["", "#", "#FFF", "#GGGGGG", "chartreuse",
                    "#33CC99FF", "33CC99FF",      // 8-digit (alpha) forms
                    "##3379D8", "3379D8#", "#3379D8#"] { // at most ONE leading '#'
            XCTAssertNil(ColorHex.components(from: bad), "must reject \(bad)")
        }
    }

    // MARK: - NSColor → hex

    func testHexRoundTripsThroughNSColor() throws {
        let c = try XCTUnwrap(ColorHex.components(from: "#FF8000"))
        let nsColor = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        XCTAssertEqual(nsColor.srgbHexString, "#FF8000")
    }

    func testSrgbHexStringHandlesCatalogColor() {
        // controlAccentColor is a dynamic catalog color; direct component
        // access raises. The conversion path must not crash and must produce
        // a well-formed value.
        let hex = NSColor.controlAccentColor.srgbHexString
        XCTAssertNotNil(hex)
        XCTAssertNotNil(ColorHex.components(from: hex ?? ""))
    }

    func testSrgbHSBDecomposesKnownColorAndCatalogColor() {
        // #FF8000 is pure orange: hue 30°, full saturation/brightness.
        let orange = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        let hsb = try? XCTUnwrap(orange.srgbHSB)
        XCTAssertEqual(hsb?.h ?? -1, 30.0 / 360.0, accuracy: 0.005)
        XCTAssertEqual(hsb?.s ?? -1, 1, accuracy: 0.005)
        XCTAssertEqual(hsb?.b ?? -1, 1, accuracy: 0.005)
        // Dynamic catalog color must decompose, not return nil (the wheel
        // picker seeds its controls from this for the unset/default accent).
        XCTAssertNotNil(NSColor.controlAccentColor.srgbHSB)
    }

    // MARK: - accentColorHex preference

    private var savedAccentHex: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedAccentHex = UserDefaults.standard.string(forKey: RubienPreferences.accentColorHexKey)
        UserDefaults.standard.removeObject(forKey: RubienPreferences.accentColorHexKey)
    }

    override func tearDown() {
        if let saved = savedAccentHex {
            UserDefaults.standard.set(saved, forKey: RubienPreferences.accentColorHexKey)
        } else {
            UserDefaults.standard.removeObject(forKey: RubienPreferences.accentColorHexKey)
        }
        savedAccentHex = nil
        super.tearDown()
    }

    func testAccentColorHexDefaultsToNilWhenUnset() {
        XCTAssertNil(RubienPreferences.accentColorHex)
    }

    func testAccentColorHexRoundTrips() {
        RubienPreferences.accentColorHex = "#3379D8"
        XCTAssertEqual(RubienPreferences.accentColorHex, "#3379D8")
    }

    func testAccentColorHexNilRemovesKey() {
        RubienPreferences.accentColorHex = "#3379D8"
        RubienPreferences.accentColorHex = nil
        XCTAssertNil(UserDefaults.standard.object(forKey: RubienPreferences.accentColorHexKey),
                     "setting nil must remove the key, not store a null marker")
    }

    // MARK: - AccentColorManager (throwaway instances; key snapshot/restored above)

    @MainActor
    func testManagerInitializesFromPersistedHex() {
        RubienPreferences.accentColorHex = "#FF8000"
        let manager = AccentColorManager()
        XCTAssertNotNil(manager.customColor)
        XCTAssertEqual(manager.customNSColor?.srgbHexString, "#FF8000")
    }

    @MainActor
    func testManagerTreatsInvalidPersistedHexAsUnset() {
        RubienPreferences.accentColorHex = "chartreuse"
        let manager = AccentColorManager()
        XCTAssertNil(manager.customColor)
        XCTAssertNil(manager.customNSColor)
        XCTAssertEqual(manager.effectiveNSColor, .controlAccentColor)
    }

    @MainActor
    func testManagerSetPersistsAndMatchesState() {
        let manager = AccentColorManager()
        manager.setCustomColor(Color(red: 1, green: 0.5, blue: 0))
        // In-memory state must equal the persisted value (set round-trips
        // through hex), and the AppKit twin must agree.
        let persisted = RubienPreferences.accentColorHex
        XCTAssertNotNil(persisted)
        XCTAssertEqual(manager.customNSColor?.srgbHexString, persisted)
        XCTAssertEqual(manager.effectiveNSColor, manager.customNSColor)
    }

    @MainActor
    func testManagerResetClearsStateAndRemovesKey() {
        let manager = AccentColorManager()
        manager.setCustomColor(Color(red: 0.2, green: 0.4, blue: 0.8))
        manager.resetToDefault()
        XCTAssertNil(manager.customColor)
        XCTAssertNil(manager.customNSColor)
        XCTAssertEqual(manager.effectiveNSColor, .controlAccentColor)
        XCTAssertNil(UserDefaults.standard.object(forKey: RubienPreferences.accentColorHexKey))
    }
}
#endif
