#if os(macOS)
import AppKit
import SwiftUI

/// A row-wide fill below the cell views, so selection never washes out text
/// or intercepts clicks. The always-visible Title column owns its lifetime.
struct ReferenceRowSelectionBackground: NSViewRepresentable {
    let isSelected: Bool
    let accent: NSColor

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.fill.accent = accent
        view.fill.isHidden = !isSelected
        view.attach()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.fill.removeFromSuperview()
    }

    final class Anchor: NSView {
        let fill = Fill()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func layout() {
            super.layout()
            attach()
        }

        func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let row = view as? NSTableRowView {
                    row.selectionHighlightStyle = .none
                    if fill.superview !== row {
                        fill.removeFromSuperview()
                        fill.frame = row.bounds
                        fill.autoresizingMask = [.width, .height]
                        row.addSubview(fill, positioned: .below, relativeTo: nil)
                    }
                    return
                }
                ancestor = view.superview
            }
            fill.removeFromSuperview()
        }
    }

    final class Fill: NSView {
        var accent: NSColor = .controlAccentColor {
            didSet { needsDisplay = true }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let opacity = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? 0.35 : (dark ? 0.28 : 0.16)
            accent.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}
#endif
