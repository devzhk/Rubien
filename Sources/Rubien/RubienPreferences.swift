#if os(macOS)
import AppKit
import Foundation
import SwiftUI

/// User-selectable app appearance. Applied app-wide via `NSApplication.appearance`
/// (not SwiftUI `.preferredColorScheme`) so it reaches the independent reader
/// `NSWindow`s, not just the SwiftUI `WindowGroup`.
enum ColorSchemePreference: String, CaseIterable {
    case system, light, dark

    /// `nil` for `.system` so the app follows the OS appearance live.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    var localizedTitle: String {
        switch self {
        case .system: return String(localized: "System", bundle: .module)
        case .light:  return String(localized: "Light", bundle: .module)
        case .dark:   return String(localized: "Dark", bundle: .module)
        }
    }
}

enum RubienPreferences {
    private static let appGroupDefaults =
        UserDefaults(suiteName: "9TXK4V3SS8.group.com.rubien.shared") ?? .standard

    /// 用于 CrossRef / OpenAlex API polite pool 的联系邮箱。
    /// CrossRef 要求提供真实 mailto 才能进入 polite pool（更快速率限制）。
    static let apiContactEmailKey = "Rubien.apiContactEmail"

    static var apiContactEmail: String {
        get { UserDefaults.standard.string(forKey: apiContactEmailKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiContactEmailKey) }
    }

    /// App appearance override. Per-device (not synced). Unset or an
    /// unrecognized value falls back to `.system`, matching the app's
    /// historical "follow the OS" behavior.
    static let themePreferenceKey = "Rubien.themePreference"

    static var colorScheme: ColorSchemePreference {
        get {
            guard let raw = UserDefaults.standard.string(forKey: themePreferenceKey),
                  let pref = ColorSchemePreference(rawValue: raw) else { return .system }
            return pref
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themePreferenceKey) }
    }

    /// Applies the stored preference to `NSApplication.appearance` — the one
    /// place appearance is set (see `ColorSchemePreference` for why this and
    /// not `.preferredColorScheme`).
    @MainActor static func applyColorScheme() {
        NSApplication.shared.appearance = colorScheme.nsAppearance
    }

    /// Single write path used by the Settings picker: persist, then apply, so
    /// the appearance side effect can never be skipped.
    @MainActor static func setColorScheme(_ pref: ColorSchemePreference) {
        colorScheme = pref
        applyColorScheme()
    }

    /// Custom app accent color as "#RRGGBB". Per-device (not synced).
    /// nil/unset = no override — the app follows the system accent as before.
    /// Raw string only; validation lives in `AccentColorManager`.
    static let accentColorHexKey = "Rubien.accentColorHex"

    static var accentColorHex: String? {
        get { UserDefaults.standard.string(forKey: accentColorHexKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: accentColorHexKey)
            } else {
                UserDefaults.standard.removeObject(forKey: accentColorHexKey)
            }
        }
    }

    /// Gates the B8 PDF asset sync (CDReferencePDF push/pull). Default
    /// flipped from false → true in Phase E Task 35 once the schema
    /// invariant test + dateModified cleanup landed. Users can still
    /// opt out by setting the value to false explicitly. Setting at
    /// runtime stops the upload-queue drainer; existing
    /// pdfUploadQueue rows accumulate harmlessly until the flag flips
    /// back on.
    static let pdfAssetSyncEnabledKey = "Rubien.pdfAssetSyncEnabled"

    static var pdfAssetSyncEnabled: Bool {
        get {
            // Treat unset as true now that B8 has shipped. Users who
            // explicitly set the key to false (via prefs or CLI) keep
            // the asset sync disabled.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: pdfAssetSyncEnabledKey) == nil { return true }
            return defaults.bool(forKey: pdfAssetSyncEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: pdfAssetSyncEnabledKey) }
    }

    // MARK: - Assistant (Phase 2c)
    //
    // Defaults for NEW assistant conversations (a reader builds its session from
    // these at open time; an already-open conversation keeps its live values, which
    // stay editable in the sidebar). Per-device, not synced. String overrides treat
    // "" as unset so a cleared field means "use the built-in default / auto-discover".

    /// The assistant working folder (the agent's cwd, D4). Empty/unset ⇒ the default
    /// `~/Documents/Rubien Assistant/` (see `assistantWorkspaceURL`).
    static let assistantWorkspacePathKey = "Rubien.assistant.workspacePath"

    static var assistantWorkspacePath: String? {
        get {
            let path = UserDefaults.standard.string(forKey: assistantWorkspacePathKey)
            return (path?.isEmpty == false) ? path : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: assistantWorkspacePathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: assistantWorkspacePathKey)
            }
        }
    }

    /// The resolved working folder: the override if set, else the default. Not yet
    /// created on disk — the reader passes it through `AssistantContext.ensureWorkspace`.
    static var assistantWorkspaceURL: URL {
        AssistantContext.workspaceURL(override: assistantWorkspacePath)
    }

    /// Optional additive instructions for new Home/library conversations. The
    /// built-in Rubien seed remains fixed; this text is appended as user preferences.
    static let assistantLibraryInstructionsKey = "Rubien.assistant.instructions.library"

    static var assistantLibraryInstructions: String? {
        get { assistantInstructions(forKey: assistantLibraryInstructionsKey) }
        set { setAssistantInstructions(newValue, forKey: assistantLibraryInstructionsKey) }
    }

    /// Optional additive instructions for new PDF/web reader conversations.
    static let assistantReaderInstructionsKey = "Rubien.assistant.instructions.reader"

    static var assistantReaderInstructions: String? {
        get { assistantInstructions(forKey: assistantReaderInstructionsKey) }
        set { setAssistantInstructions(newValue, forKey: assistantReaderInstructionsKey) }
    }

    private static func assistantInstructions(forKey key: String) -> String? {
        guard let stored = UserDefaults.standard.string(forKey: key) else { return nil }
        let value = AssistantContext.limitedCustomInstructions(stored)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func setAssistantInstructions(_ value: String?, forKey key: String) {
        if let value {
            let limited = AssistantContext.limitedCustomInstructions(value)
            guard !limited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                UserDefaults.standard.removeObject(forKey: key)
                return
            }
            UserDefaults.standard.set(limited, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Default model alias for new Claude conversations. Normalized against Claude's
    /// current list, so an empty/unset or stale slug resolves to Claude's default.
    static let assistantModelKey = "Rubien.assistant.model"

    static var assistantModel: String {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantModelKey) ?? ""
            return AssistantModelOptions.normalizedModel(raw, for: .claude)
        }
        set { UserDefaults.standard.set(newValue, forKey: assistantModelKey) }
    }

    /// Default reasoning effort for new Claude conversations, normalized to Claude's
    /// current list (empty/stale ⇒ default).
    static let assistantEffortKey = "Rubien.assistant.effort"

    static var assistantEffort: String {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantEffortKey) ?? ""
            return AssistantModelOptions.normalizedEffort(raw, for: .claude)
        }
        set { UserDefaults.standard.set(newValue, forKey: assistantEffortKey) }
    }

    /// Default web access for new conversations. Unset ⇒ on (the sidebar default).
    static let assistantWebAccessKey = "Rubien.assistant.webAccess"

    static var assistantWebAccess: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: assistantWebAccessKey) == nil { return true }
            return defaults.bool(forKey: assistantWebAccessKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: assistantWebAccessKey) }
    }

    /// Default approval mode for new conversations: `false` = Ask (prompt before
    /// writes/shell), `true` = Auto (accept automatically). Unset ⇒ Ask.
    static let assistantAutoApproveKey = "Rubien.assistant.autoApprove"

    static var assistantAutoApprove: Bool {
        get { UserDefaults.standard.bool(forKey: assistantAutoApproveKey) }
        set { UserDefaults.standard.set(newValue, forKey: assistantAutoApproveKey) }
    }

    /// Whether new conversations load the selected provider's normal connected
    /// apps, plugins, settings, and user-configured MCP servers in addition to
    /// Rubien's own MCP channel. Unset ⇒ false. Codex's own configured MCP servers
    /// remain an accepted ambient-config residual; this flag additionally enables
    /// Codex Apps, while Claude switches from isolated to normal user settings.
    static let assistantLoadUserToolsKey = "Rubien.assistant.loadUserTools"

    static var assistantLoadUserTools: Bool {
        get { UserDefaults.standard.bool(forKey: assistantLoadUserToolsKey) }
        set { UserDefaults.standard.set(newValue, forKey: assistantLoadUserToolsKey) }
    }

    /// Default visibility for the assistant panel in newly opened reader windows.
    /// Unset ⇒ visible, so the assistant is discoverable until the user explicitly
    /// hides it. Existing open readers keep their local state; this seeds new ones.
    static let assistantSidebarVisibleKey = "Rubien.assistant.sidebarVisible"

    static var assistantSidebarVisible: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: assistantSidebarVisibleKey) == nil { return true }
            return defaults.bool(forKey: assistantSidebarVisibleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: assistantSidebarVisibleKey) }
    }

    /// The size the user last left a reader window at, reused as the open size for the
    /// next reader. Papers/blogs are usually read once, so per-document frame memory
    /// rarely pays off — a single "last size" is the useful signal (like Safari). nil
    /// until the first reader is resized/closed; new readers then open at it, clamped
    /// to the window minimum and the visible screen.
    static let readerWindowSizeKey = "Rubien.reader.windowSize"

    static var readerWindowSize: CGSize? {
        get {
            guard let stored = UserDefaults.standard.dictionary(forKey: readerWindowSizeKey),
                  let width = stored["w"] as? Double, let height = stored["h"] as? Double,
                  width > 0, height > 0
            else { return nil }
            return CGSize(width: width, height: height)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(["w": newValue.width, "h": newValue.height], forKey: readerWindowSizeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: readerWindowSizeKey)
            }
        }
    }

    /// Per-reader left-sidebar state. PDF and web keep separate values because
    /// their sidebars contain different tools and users may size them differently.
    /// These preferences are local to this Mac and seed newly opened windows.
    static let pdfReaderSidebarVisibleKey = "Rubien.reader.pdf.sidebarVisible"
    static let pdfReaderSidebarWidthKey = "Rubien.reader.pdf.sidebarWidth"
    static let webReaderSidebarVisibleKey = "Rubien.reader.web.sidebarVisible"
    static let webReaderSidebarWidthKey = "Rubien.reader.web.sidebarWidth"
    static let readerSidebarPersistenceVersionKey = "Rubien.reader.sidebarPersistenceVersion"

    /// The first web-width implementation observed `HSplitView` layout and could
    /// save AppKit's automatic allocation as if the user had dragged the divider.
    /// Discard that one unreliable value once; widths written by the exact bound
    /// resize handle introduced in version 1 are genuine user choices.
    static func migrateReaderSidebarPreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: readerSidebarPersistenceVersionKey) < 1 else { return }
        defaults.removeObject(forKey: webReaderSidebarWidthKey)
        defaults.set(1, forKey: readerSidebarPersistenceVersionKey)
    }

    static var pdfReaderSidebarVisible: Bool {
        get { sidebarVisibility(forKey: pdfReaderSidebarVisibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: pdfReaderSidebarVisibleKey) }
    }

    static var pdfReaderSidebarWidth: CGFloat? {
        get { sidebarWidth(forKey: pdfReaderSidebarWidthKey) }
        set { setSidebarWidth(newValue, forKey: pdfReaderSidebarWidthKey) }
    }

    static var webReaderSidebarVisible: Bool {
        get { sidebarVisibility(forKey: webReaderSidebarVisibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: webReaderSidebarVisibleKey) }
    }

    static var webReaderSidebarWidth: CGFloat? {
        get { sidebarWidth(forKey: webReaderSidebarWidthKey) }
        set { setSidebarWidth(newValue, forKey: webReaderSidebarWidthKey) }
    }

    private static func sidebarVisibility(forKey key: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    private static func sidebarWidth(forKey key: String) -> CGFloat? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return nil }
        let width = defaults.double(forKey: key)
        guard width.isFinite, width > 0 else { return nil }
        return CGFloat(width)
    }

    private static func setSidebarWidth(_ width: CGFloat?, forKey key: String) {
        guard let width, width.isFinite, width > 0 else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(Double(width), forKey: key)
    }

    // MARK: - Activity

    static let recordReadingActivityKey = "Rubien.activity.recordReading"
    static let recordAssistantActivityKey = "Rubien.activity.recordAssistant"
    static let activityInstallationIdKey = "Rubien.activity.installationId"
    static let activityHeatmapRangeKey = "Rubien.activity.heatmapRange"

    /// Per-device capture controls. Turning one off stops new local facts but
    /// does not hide facts already synced from this or another device.
    static var recordReadingActivity: Bool {
        get {
            if appGroupDefaults.object(forKey: recordReadingActivityKey) == nil { return true }
            return appGroupDefaults.bool(forKey: recordReadingActivityKey)
        }
        set { appGroupDefaults.set(newValue, forKey: recordReadingActivityKey) }
    }

    static var recordAssistantActivity: Bool {
        get {
            if appGroupDefaults.object(forKey: recordAssistantActivityKey) == nil { return true }
            return appGroupDefaults.bool(forKey: recordAssistantActivityKey)
        }
        set { appGroupDefaults.set(newValue, forKey: recordAssistantActivityKey) }
    }

    /// Random stable installation component identity. It is never derived
    /// from hardware and never written as a standalone synced record.
    static var activityInstallationId: String {
        if let stored = appGroupDefaults.string(forKey: activityInstallationIdKey),
           !stored.isEmpty,
           !stored.contains("/")
        {
            return stored
        }
        let created = UUID().uuidString.lowercased()
        appGroupDefaults.set(created, forKey: activityInstallationIdKey)
        return created
    }

    static var activityHeatmapRange: String {
        get { appGroupDefaults.string(forKey: activityHeatmapRangeKey) ?? "quarter" }
        set { appGroupDefaults.set(newValue, forKey: activityHeatmapRangeKey) }
    }

    /// Explicit path to the `claude` binary; empty/unset ⇒ auto-discovery (§5.5:
    /// well-known dirs → login-shell `command -v`). Threaded to
    /// `ClaudeCodeProvider(executableOverride:)`.
    static let assistantBinaryPathKey = "Rubien.assistant.binaryPath"

    static var assistantBinaryPath: String? {
        get {
            let path = UserDefaults.standard.string(forKey: assistantBinaryPathKey)
            return (path?.isEmpty == false) ? path : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: assistantBinaryPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: assistantBinaryPathKey)
            }
        }
    }

    // MARK: - Assistant backend + Codex defaults (Phase 3b-3)
    //
    // The default runtime for a NEW conversation/window, plus Codex's own model /
    // effort / sandbox / binary defaults (disjoint from Claude's — Codex accepts
    // different model slugs and effort levels). The composer picker switches a live
    // conversation's backend and remembers that choice here; Settings edits the same
    // default directly.

    /// The default coding-agent backend for a new conversation. Unknown raw ⇒ Claude.
    static let assistantProviderKey = "Rubien.assistant.provider"

    static var assistantProvider: AgentProviderKind {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantProviderKey)
            return raw.flatMap(AgentProviderKind.init(rawValue:)) ?? .claude
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: assistantProviderKey) }
    }

    /// Default Codex model slug for new conversations — RAW (spec §4.4). A stored
    /// slug is the user's REMEMBERED last pick (the composer persists every model
    /// choice here) and is sent verbatim; validity is the catalog-aware picker's
    /// job, never a silent rewrite here. nil/absent ⇒ a fresh conversation SEEDS
    /// its model from the first discovered model once the catalog loads (the seed
    /// itself is not persisted — only an explicit pick writes here).
    static let assistantCodexModelKey = "Rubien.assistant.codex.model"

    static var assistantCodexModel: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantCodexModelKey) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            if let value = newValue, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: assistantCodexModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: assistantCodexModelKey)
            }
        }
    }

    /// Default Codex reasoning effort for new conversations — RAW except the unset
    /// fallback `medium` (universal since codex 0.142; deliberately not the
    /// `~/.codex` default, which is often `xhigh` and stalls). No list clamp: the
    /// per-model effort lists come from the live catalog (a static clamp would
    /// silently rewrite a chosen `max`/`ultra` back to `medium`).
    static let assistantCodexEffortKey = "Rubien.assistant.codex.effort"

    static var assistantCodexEffort: String {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantCodexEffortKey) ?? ""
            return raw.isEmpty ? "medium" : raw
        }
        set { UserDefaults.standard.set(newValue, forKey: assistantCodexEffortKey) }
    }

    /// Default Codex OS-sandbox mode for new conversations. Unknown raw ⇒ read-only.
    static let assistantCodexSandboxKey = "Rubien.assistant.codex.sandbox"

    static var assistantCodexSandbox: CodexSandbox {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantCodexSandboxKey)
            return raw.flatMap(CodexSandbox.init(rawValue:)) ?? .readOnly
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: assistantCodexSandboxKey) }
    }

    /// Explicit path to the `codex` binary; empty/unset ⇒ auto-discovery (same
    /// resolution as Claude). Threaded to `CodexProvider(executableOverride:)`.
    static let assistantCodexBinaryPathKey = "Rubien.assistant.codex.binaryPath"

    static var assistantCodexBinaryPath: String? {
        get {
            let path = UserDefaults.standard.string(forKey: assistantCodexBinaryPathKey)
            return (path?.isEmpty == false) ? path : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: assistantCodexBinaryPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: assistantCodexBinaryPathKey)
            }
        }
    }

    static let columnConfigsKey = "Rubien.columnConfigs"
    static let tableColumnCustomizationKey = "Rubien.tableColumnCustomization"

    static func loadTableColumnCustomization<R: Identifiable>() -> TableColumnCustomization<R> {
        guard let data = UserDefaults.standard.data(forKey: tableColumnCustomizationKey),
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<R>.self, from: data) else {
            return TableColumnCustomization<R>()
        }
        return decoded
    }

    static func saveTableColumnCustomization<R: Identifiable>(_ value: TableColumnCustomization<R>) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: tableColumnCustomizationKey)
    }
}
#endif
