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
    /// Snapshot of every preference key touched by these tests, so the shared
    /// standard suite is restored verbatim (including the "unset" state) on tearDown.
    private var savedPreferences: [String: Any] = [:]
    private var preferenceKeys: [String] {
        [
            RubienPreferences.assistantModelKey,
            RubienPreferences.assistantEffortKey,
            RubienPreferences.assistantWebAccessKey,
            RubienPreferences.assistantAutoApproveKey,
            RubienPreferences.assistantLoadUserToolsKey,
            RubienPreferences.assistantWorkspacePathKey,
            RubienPreferences.assistantBinaryPathKey,
            RubienPreferences.assistantProviderKey,
            RubienPreferences.assistantCodexModelKey,
            RubienPreferences.assistantCodexEffortKey,
            RubienPreferences.assistantCodexSandboxKey,
            RubienPreferences.assistantCodexBinaryPathKey,
            RubienPreferences.assistantSidebarVisibleKey,
            RubienPreferences.pdfReaderSidebarVisibleKey,
            RubienPreferences.pdfReaderSidebarWidthKey,
            RubienPreferences.webReaderSidebarVisibleKey,
            RubienPreferences.webReaderSidebarWidthKey,
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

        for key in preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedPreferences[key] = value }
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

        for key in preferenceKeys {
            if let value = savedPreferences[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedPreferences.removeAll()
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
        XCTAssertFalse(RubienPreferences.assistantLoadUserTools,
                       "connected apps and user MCP tools must require an explicit opt-in")
        XCTAssertNil(RubienPreferences.assistantCodexModel,
                     "unset ⇒ Codex default (no model sent; codex resolves its own config)")
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "medium",
                       "Codex effort defaults to medium (dodges the xhigh stall), not high")
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .readOnly)
        XCTAssertNil(RubienPreferences.assistantCodexBinaryPath)
    }

    func testAssistantBackendPrefsRoundTrip() {
        RubienPreferences.assistantProvider = .codex
        XCTAssertEqual(RubienPreferences.assistantProvider, .codex)
        RubienPreferences.assistantCodexModel = "gpt-5.6-terra"
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-5.6-terra")
        RubienPreferences.assistantCodexModel = nil
        XCTAssertNil(RubienPreferences.assistantCodexModel, "nil clears back to Codex default")
        RubienPreferences.assistantCodexEffort = "xhigh"
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "xhigh")
        RubienPreferences.assistantCodexSandbox = .workspaceWrite
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .workspaceWrite)
        RubienPreferences.assistantCodexBinaryPath = "/opt/bin/codex"
        XCTAssertEqual(RubienPreferences.assistantCodexBinaryPath, "/opt/bin/codex")
        RubienPreferences.assistantLoadUserTools = true
        XCTAssertTrue(RubienPreferences.assistantLoadUserTools)
        RubienPreferences.assistantLoadUserTools = false
        XCTAssertFalse(RubienPreferences.assistantLoadUserTools)
    }

    /// The Codex prefs are RAW (spec §4.4): no static normalization — the old clamp
    /// would silently rewrite a chosen `max`/`ultra` (absent from the static four)
    /// back to `medium`, and a pinned model unknown to a static list must survive
    /// for the catalog-aware picker to handle visibly. Claude prefs still normalize.
    func testCodexPrefsAreRawClaudePrefsStillNormalize() {
        RubienPreferences.assistantCodexModel = "gpt-9-future"
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-9-future")
        RubienPreferences.assistantCodexEffort = "ultra"
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "ultra", "ultra survives the round-trip")
        // A Codex slug is not a Claude model → the CLAUDE pref still snaps to its default.
        RubienPreferences.assistantModel = "gpt-5.5"
        XCTAssertEqual(RubienPreferences.assistantModel, "opus")
    }

    func testAssistantProviderUnknownRawFallsBackToClaude() {
        UserDefaults.standard.set("gemini", forKey: RubienPreferences.assistantProviderKey)
        XCTAssertEqual(RubienPreferences.assistantProvider, .claude)
        UserDefaults.standard.set("banana", forKey: RubienPreferences.assistantCodexSandboxKey)
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .readOnly)
    }

    func testAssistantSidebarVisibleDefaultsToTrueWhenUnset() {
        XCTAssertTrue(
            RubienPreferences.assistantSidebarVisible,
            "new reader windows should show the assistant until the user hides it"
        )
    }

    func testAssistantSidebarVisibleRoundTrips() {
        RubienPreferences.assistantSidebarVisible = false
        XCTAssertFalse(RubienPreferences.assistantSidebarVisible)
        RubienPreferences.assistantSidebarVisible = true
        XCTAssertTrue(RubienPreferences.assistantSidebarVisible)
    }

    func testReaderSidebarPreferencesDefaultAndRoundTrip() {
        XCTAssertTrue(RubienPreferences.pdfReaderSidebarVisible)
        XCTAssertNil(RubienPreferences.pdfReaderSidebarWidth)
        XCTAssertTrue(RubienPreferences.webReaderSidebarVisible)
        XCTAssertNil(RubienPreferences.webReaderSidebarWidth)

        RubienPreferences.pdfReaderSidebarVisible = false
        RubienPreferences.pdfReaderSidebarWidth = 276.5
        RubienPreferences.webReaderSidebarVisible = false
        RubienPreferences.webReaderSidebarWidth = 312

        XCTAssertFalse(RubienPreferences.pdfReaderSidebarVisible)
        XCTAssertEqual(RubienPreferences.pdfReaderSidebarWidth, 276.5)
        XCTAssertFalse(RubienPreferences.webReaderSidebarVisible)
        XCTAssertEqual(RubienPreferences.webReaderSidebarWidth, 312)
    }
}
#endif
