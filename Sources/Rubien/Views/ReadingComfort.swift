#if os(macOS)
import SwiftUI

/// A display-only tint above the native reader surface. Keeping the native view
/// mounted preserves its scroll position, selection, and document rendering.
/// Apply before action-popover overlays so their colors remain unchanged.
extension View {
    func readingComfort(enabled: Bool) -> some View {
        overlay {
            Color(red: 1, green: 0.72, blue: 0.25)
                .opacity(enabled ? 0.12 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct ReadingComfortToggle: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            Label(String(localized: "Reading comfort", bundle: .module), systemImage: "sun.haze")
        }
        .toggleStyle(.button)
        .help(String(localized: "Apply a warm paper tint to the reader", bundle: .module))
    }
}
#endif
