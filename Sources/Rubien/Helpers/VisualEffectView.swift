#if os(macOS)
import SwiftUI
import AppKit

/// Neutral Liquid Glass background for the details inspector, made to match the
/// `NavigationSplitView` sidebar. The sidebar's look is *system-applied* to the
/// first split column (SidebarView itself sets no material), so it can't be
/// copied in SwiftUI — we reproduce it with AppKit's Liquid Glass primitive,
/// `NSGlassEffectView`, with `tintColor == nil` (neutral, so it doesn't pick up
/// the app's accent the way the inspector's default glass does).
@available(macOS 26.0, *)
struct GlassEffectView: NSViewRepresentable {
    var tintColor: NSColor? = nil
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.tintColor = tintColor
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.tintColor = tintColor
        view.cornerRadius = cornerRadius
    }
}

/// Pre-Tahoe fallback: AppKit's named visual-effect materials (SwiftUI's
/// `Material` tokens don't expose the sidebar material). On macOS 26 this
/// renders flat — use `GlassEffectView` there instead.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
#endif
