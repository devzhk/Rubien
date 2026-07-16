#if os(macOS)
import SwiftUI
import AppKit

// Back-compatibility shims for SwiftUI APIs newer than the macOS 14.4 deployment
// target. Each keeps the modern API on systems that have it and degrades
// gracefully on macOS 14.x. Mirrors the version-gated pattern in
// `LiquidGlassSupport` (which handles the macOS 26 Liquid Glass surface).

extension View {
    /// `pointerStyle(.link)` on macOS 15+. On macOS 14.x `pointerStyle` is
    /// unavailable; the (purely cosmetic) link cursor is dropped rather than
    /// emulated via `onHover` + `NSCursor.pointingHand.push()`, which can leak a
    /// pushed cursor onto the app-wide cursor stack when the view is replaced
    /// before a pointer-exit event balances the `pop()`. Callers keep their own
    /// hover feedback (e.g. a background highlight) regardless.
    @ViewBuilder
    func linkPointerStyle() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }

    /// `presentationSizing(.fitted)` on macOS 15+; a no-op on macOS 14.x, where a
    /// sheet whose content declares an explicit frame already sizes to fit.
    @ViewBuilder
    func fittedPresentation() -> some View {
        if #available(macOS 15.0, *) {
            presentationSizing(.fitted)
        } else {
            self
        }
    }
}

extension Color {
    /// The receiver blended toward white by `fraction` (0…1). Uses
    /// `Color.mix(with:by:)` on macOS 15+ (identical to the shipping appearance)
    /// and an sRGB-component fallback on macOS 14.x, where `mix(with:by:)` is
    /// unavailable.
    func mixedTowardWhite(by fraction: Double) -> Color {
        if #available(macOS 15.0, *) {
            return mix(with: .white, by: fraction)
        }
        let f = min(max(fraction, 0), 1)
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else { return self }
        func lightened(_ component: CGFloat) -> Double { Double(component + (1 - component) * f) }
        return Color(
            .sRGB,
            red: lightened(resolved.redComponent),
            green: lightened(resolved.greenComponent),
            blue: lightened(resolved.blueComponent),
            opacity: Double(resolved.alphaComponent)
        )
    }
}
#endif
