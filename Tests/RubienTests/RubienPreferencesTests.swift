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
    /// Snapshot of every assistant key touched by these tests, so the shared
    /// standard suite is restored verbatim (including the "unset" state) on tearDown.
    private var savedAssistant: [String: Any] = [:]
    private var assistantKeys: [String] {
        [
            RubienPreferences.assistantModelKey,
            RubienPreferences.assistantEffortKey,
            RubienPreferences.assistantWebAccessKey,
            RubienPreferences.assistantAutoApproveKey,
            RubienPreferences.assistantWorkspacePathKey,
            RubienPreferences.assistantBinaryPathKey,
            RubienPreferences.assistantProviderKey,
            RubienPreferences.assistantCodexModelKey,
            RubienPreferences.assistantCodexEffortKey,
            RubienPreferences.assistantCodexSandboxKey,
            RubienPreferences.assistantCodexBinaryPathKey,
        ]
    }

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

        for key in assistantKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedAssistant[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
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

        for key in assistantKeys {
            if let value = savedAssistant[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedAssistant.removeAll()
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

    // MARK: - Assistant defaults (Phase 2c-5)

    func testAssistantDefaultsWhenUnset() {
        // setUp cleared the keys, so this exercises the unset path — must match the
        // sidebar's built-in defaults so Settings and the sidebar agree.
        XCTAssertEqual(RubienPreferences.assistantModel, "opus")
        XCTAssertEqual(RubienPreferences.assistantEffort, "high")
        XCTAssertTrue(RubienPreferences.assistantWebAccess)
        XCTAssertFalse(RubienPreferences.assistantAutoApprove)
        XCTAssertNil(RubienPreferences.assistantWorkspacePath)
        XCTAssertNil(RubienPreferences.assistantBinaryPath)
    }

    func testAssistantPrefsRoundTrip() {
        RubienPreferences.assistantModel = "sonnet"
        XCTAssertEqual(RubienPreferences.assistantModel, "sonnet")
        RubienPreferences.assistantEffort = "medium"
        XCTAssertEqual(RubienPreferences.assistantEffort, "medium")
        RubienPreferences.assistantWebAccess = false
        XCTAssertFalse(RubienPreferences.assistantWebAccess)
        RubienPreferences.assistantAutoApprove = true
        XCTAssertTrue(RubienPreferences.assistantAutoApprove)
        RubienPreferences.assistantWorkspacePath = "/tmp/ws"
        XCTAssertEqual(RubienPreferences.assistantWorkspacePath, "/tmp/ws")
        RubienPreferences.assistantBinaryPath = "/usr/local/bin/claude"
        XCTAssertEqual(RubienPreferences.assistantBinaryPath, "/usr/local/bin/claude")
    }

    func testAssistantPathOverridesTreatEmptyAsUnset() {
        RubienPreferences.assistantWorkspacePath = "/tmp/ws"
        RubienPreferences.assistantWorkspacePath = ""
        XCTAssertNil(RubienPreferences.assistantWorkspacePath, "empty override clears to nil (use default)")

        RubienPreferences.assistantBinaryPath = "/bin/claude"
        RubienPreferences.assistantBinaryPath = ""
        XCTAssertNil(RubienPreferences.assistantBinaryPath, "empty override clears to nil (auto-discover)")
    }

    func testAssistantWorkspaceURLReflectsOverride() {
        XCTAssertEqual(RubienPreferences.assistantWorkspaceURL, AssistantContext.defaultWorkspaceURL,
                       "unset ⇒ the default working folder")
        RubienPreferences.assistantWorkspacePath = "/tmp/custom-ws"
        XCTAssertEqual(RubienPreferences.assistantWorkspaceURL.path, "/tmp/custom-ws")
    }

    // MARK: - Backend + Codex defaults (Phase 3b-3)

    func testAssistantBackendDefaultsWhenUnset() {
        XCTAssertEqual(RubienPreferences.assistantProvider, .claude, "unset ⇒ Claude")
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-5.5")
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "medium",
                       "Codex effort defaults to medium (dodges the xhigh stall), not high")
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .readOnly)
        XCTAssertNil(RubienPreferences.assistantCodexBinaryPath)
    }

    func testAssistantBackendPrefsRoundTrip() {
        RubienPreferences.assistantProvider = .codex
        XCTAssertEqual(RubienPreferences.assistantProvider, .codex)
        RubienPreferences.assistantCodexModel = "gpt-5.5-pro"
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-5.5-pro")
        RubienPreferences.assistantCodexEffort = "xhigh"
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "xhigh")
        RubienPreferences.assistantCodexSandbox = .workspaceWrite
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .workspaceWrite)
        RubienPreferences.assistantCodexBinaryPath = "/opt/bin/codex"
        XCTAssertEqual(RubienPreferences.assistantCodexBinaryPath, "/opt/bin/codex")
    }

    /// A model/effort persisted that the backend doesn't offer (stale pref, a Claude
    /// slug left in the Codex pref, or a dropped model) must resolve to the backend's
    /// default rather than leaking an unaccepted slug to the runtime / an empty picker.
    func testAssistantModelEffortPrefsNormalizeAgainstBackendList() {
        // A Claude slug is not a Codex model → snaps to the Codex default.
        RubienPreferences.assistantCodexModel = "opus"
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-5.5")
        // `max` is a Claude effort but not a Codex one → snaps to the Codex default.
        RubienPreferences.assistantCodexEffort = "max"
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "medium")
        // A Codex slug is not a Claude model → snaps to the Claude default.
        RubienPreferences.assistantModel = "gpt-5.5"
        XCTAssertEqual(RubienPreferences.assistantModel, "opus")
    }

    func testAssistantProviderUnknownRawFallsBackToClaude() {
        UserDefaults.standard.set("gemini", forKey: RubienPreferences.assistantProviderKey)
        XCTAssertEqual(RubienPreferences.assistantProvider, .claude)
        UserDefaults.standard.set("banana", forKey: RubienPreferences.assistantCodexSandboxKey)
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .readOnly)
    }
}
#endif
