#if os(macOS)
import SwiftUI

extension View {
    @ViewBuilder
    func liquidGlassSurface<S: InsettableShape, F: ShapeStyle>(
        in shape: S,
        fallback: F
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    /// Neutral Liquid Glass card background (rounded corners + soft shadow) that
    /// matches the sidebar's *untinted* glass. Deliberately does NOT use
    /// `liquidGlassSurface` / SwiftUI `glassEffect`: that tints toward the app's
    /// accent colour (the blue cast we don't want on this panel). Uses AppKit's
    /// `NSGlassEffectView` (neutral `tintColor`) on macOS 26 and the legacy
    /// `.sidebar` `NSVisualEffectView` material on earlier systems.
    func neutralGlassCard(cornerRadius: CGFloat) -> some View {
        background {
            if #available(macOS 26.0, *) {
                GlassEffectView(cornerRadius: cornerRadius)
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
            } else {
                VisualEffectView()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
            }
        }
    }

    @ViewBuilder
    func legacyToolbarBackground<S: ShapeStyle>(
        _ style: S,
        for placement: ToolbarPlacement
    ) -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            toolbarBackground(style, for: placement)
        }
    }

    @ViewBuilder
    func legacyBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            background(style)
        }
    }

    @ViewBuilder
    func liquidGlassPresentation() -> some View {
        if #available(macOS 26.0, *) {
            presentationBackground(.thinMaterial)
        } else {
            self
        }
    }
}
#endif
