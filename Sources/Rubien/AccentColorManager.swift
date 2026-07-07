#if os(macOS)
import AppKit
import SwiftUI

/// App-wide custom accent color, backed by `RubienPreferences.accentColorHex`.
///
/// `nil` = no custom accent → no override is applied anywhere and the app
/// follows the system accent (System Settings → Appearance), the historical
/// behavior. (There is deliberately no asset-catalog AccentColor /
/// `NSAccentColorName`: an Info.plist-level accent can't change at runtime,
/// and the SPM bundle layout wouldn't honor it anyway.)
///
/// Separate from the theme (light/dark) preference — the two compose freely.
@MainActor @Observable
final class AccentColorManager {
    static let shared = AccentColorManager()

    /// nil = no custom accent; the system accent stays in effect. Stored as
    /// the AppKit color (the persistence round-trip's native form); the
    /// SwiftUI faces below derive from it so there is no two-field invariant.
    private(set) var customNSColor: NSColor?

    /// SwiftUI twin of `customNSColor`. Reading it in a view body registers
    /// observation of the underlying stored property.
    var customColor: Color? { customNSColor.map { Color(nsColor: $0) } }

    /// NSColor for AppKit consumers (PDF flash highlights). The fallback is
    /// `controlAccentColor` — byte-for-byte what those call sites used before
    /// (see class docs for why that, and not the asset color, is the app's
    /// real default).
    var effectiveNSColor: NSColor { customNSColor ?? .controlAccentColor }

    /// Current effective accent as a SwiftUI Color (Settings picker swatch).
    var effectiveColor: Color { Color(nsColor: effectiveNSColor) }

    /// Current effective accent decomposed to HSB (seeds the wheel picker's
    /// controls). Falls back to opaque white if sRGB conversion fails.
    var effectiveHSB: (h: Double, s: Double, b: Double) {
        effectiveNSColor.srgbHSB ?? (0, 0, 1)
    }

    /// Internal (not private) as a test seam: tests construct throwaway
    /// instances against a snapshot/restored `UserDefaults.standard` (the
    /// `RubienPreferencesTests` convention) instead of racing the lazily
    /// latched singleton. App code must use `.shared`.
    init() {
        if let hex = RubienPreferences.accentColorHex {
            customNSColor = Self.parse(hex: hex)
            // Invalid stored hex parses to nil → behaves as unset.
        }
    }

    /// Single write path used by the Settings picker: persist, then apply.
    /// Round-trips through hex so in-memory state always equals the persisted
    /// value, and drops repeated identical ticks from NSColorPanel drags.
    func setCustomColor(_ color: Color) {
        guard let hex = NSColor(color).srgbHexString,
              hex != RubienPreferences.accentColorHex else { return }
        RubienPreferences.accentColorHex = hex
        customNSColor = Self.parse(hex: hex)
    }

    func resetToDefault() {
        RubienPreferences.accentColorHex = nil
        customNSColor = nil
    }

    private static func parse(hex: String) -> NSColor? {
        ColorHex.components(from: hex).map {
            NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1)
        }
    }
}

// MARK: - Root injection

private struct RubienAccentModifier: ViewModifier {
    /// Sole `accentColor(_:)` call site. The SDK currently marks the modifier
    /// deprecated at sentinel version 100000.0 so no warning fires today; the
    /// deprecated-body isolation is cheap insurance — Swift suppresses
    /// deprecation warnings inside declarations that are themselves
    /// deprecated, and SwiftUI invokes `body` through the protocol witness,
    /// so nothing leaks to callers. `.accentColor` writes the environment
    /// value that `Color.accentColor` reads; `.tint` is a separate value used
    /// by controls — both are needed.
    @available(macOS, deprecated: 12.0,
               message: "Sole accentColor(_:) call site — use .rubienAccent() everywhere else")
    func body(content: Content) -> some View {
        // Reading the @Observable singleton in body registers observation for
        // THIS hosting root's hierarchy; every root invalidates independently
        // when the color changes. Passing nil (instead of branching) keeps
        // structural identity stable when toggling set ↔ unset.
        let accent = AccentColorManager.shared.customColor
        return content
            .tint(accent)          // native controls
            .accentColor(accent)   // Color.accentColor reads; nil = default
    }
}

extension View {
    /// Apply at every SwiftUI hosting root — the SwiftUI environment (and so
    /// the injected accent) does not cross `NSHostingView`/`NSHostingController`
    /// boundaries. App scenes apply this directly; independent windows go
    /// through `makeRubienHostingController`; the legacy `OverlayScrollView`
    /// re-applies it on its nested hosting root.
    func rubienAccent() -> some View { modifier(RubienAccentModifier()) }
}

/// Content controller for an independent `NSWindow` (reader windows, quick
/// preview). Use this instead of `NSHostingController(rootView:)` so new
/// windows can't forget to re-apply the app accent on their fresh SwiftUI
/// root.
@MainActor
func makeRubienHostingController<Content: View>(rootView: Content) -> NSViewController {
    NSHostingController(rootView: rootView.rubienAccent())
}
#endif
