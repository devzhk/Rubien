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
