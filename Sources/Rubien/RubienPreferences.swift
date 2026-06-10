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
