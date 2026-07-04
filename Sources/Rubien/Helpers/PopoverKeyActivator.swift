#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Popover key-window activator
//
// SwiftUI's `.onHover` installs its NSTrackingArea with key-window scope, so hover
// highlights only fire while the hosting window is key. A `.popover` does not become
// key on its own: hover highlights inside it never fire, and — worse — mouse-moved
// events keep activating the window *behind* the popover (e.g. the reference table's
// row hover), leaking phantom highlights onto it. Making the popover window key on
// appear activates the popover's own tracking (and deactivates the window behind),
// fixing both the dead hover and the leak-through.
//
// Apply `.activatePopoverHover()` to the root view of any `.popover { … }` content.
struct PopoverKeyActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ActivatorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            // The popover window may not be ready to take key synchronously on the
            // same runloop turn it's added, so defer the activation.
            DispatchQueue.main.async { [weak window] in
                window?.makeKey()
            }
        }
    }
}

extension View {
    /// Makes the hosting popover window key on appear so `.onHover` highlights inside
    /// the popover fire reliably and don't leak onto the window behind it. Apply to
    /// the root of `.popover { … }` content. See ``PopoverKeyActivator``.
    ///
    /// - Important: Avoid combining this with a text field that is auto-focused on
    ///   appear (e.g. `@FocusState` set from `.onAppear`). The deferred `makeKey()`
    ///   here races with that focus assignment and breaks the field's interaction,
    ///   while auto-focus alone does *not* reliably key the window for `.onHover`.
    ///   Let such fields focus on user interaction instead (as the tag / select
    ///   pickers do), so this modifier owns the key-window activation cleanly.
    func activatePopoverHover() -> some View {
        background(PopoverKeyActivator())
    }
}
#endif
