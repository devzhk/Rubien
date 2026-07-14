#if os(macOS)
import SwiftUI

// MARK: - SLPrimaryButtonStyle
// Filled accent-color button. Use for the primary / confirm action.

struct SLPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SLPrimaryButtonBody(configuration: configuration)
    }
}

private struct SLPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let isSmall = controlSize == .small || controlSize == .mini
        configuration.label
            .font(.system(size: isSmall ? 11 : 13, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, isSmall ? 10 : 14)
            .padding(.vertical, isSmall ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.accentColor.opacity(0.72)
                            : (isHovered ? Color.accentColor.opacity(0.86) : Color.accentColor)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - SLSecondaryButtonStyle
// Ghost background button. Use for cancel / auxiliary actions.

struct SLSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SLSecondaryButtonBody(configuration: configuration)
    }
}

/// Compact hover and pressed treatment for square icon/selection controls.
struct CompactHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactHoverButtonBody(configuration: configuration)
    }
}

private struct CompactHoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.primary.opacity(0.14)
                            : (isHovered ? Color.primary.opacity(0.08) : .clear)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - HoverCheckboxToggleStyle
// Preserves the native macOS checkbox while adding a visible hover target
// around the checkbox and its label.

struct HoverCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCheckboxToggleBody(configuration: configuration)
    }
}

private struct HoverCheckboxToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isHovered && isEnabled
                        ? Color.primary.opacity(0.08)
                        : Color.clear
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct SLSecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let isSmall = controlSize == .small || controlSize == .mini
        configuration.label
            .font(.system(size: isSmall ? 11 : 13, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, isSmall ? 10 : 14)
            .padding(.vertical, isSmall ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.primary.opacity(0.12)
                            : (isHovered ? Color.primary.opacity(0.09) : Color.primary.opacity(0.06))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - SLDestructiveButtonStyle
// Soft red button. Use for irreversible / delete actions.

struct SLDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SLDestructiveButtonBody(configuration: configuration)
    }
}

private struct SLDestructiveButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let isSmall = controlSize == .small || controlSize == .mini
        configuration.label
            .font(.system(size: isSmall ? 11 : 13, weight: .medium))
            .foregroundStyle(Color.red)
            .padding(.horizontal, isSmall ? 10 : 14)
            .padding(.vertical, isSmall ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.red.opacity(0.18)
                            : (isHovered ? Color.red.opacity(0.12) : Color.red.opacity(0.08))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - ToolbarHoverButtonStyle
// Flat toolbar button: nothing at rest, a light rounded highlight on hover and a
// slightly stronger one while pressed. Replaces the macOS 26 Liquid Glass capsule
// on the main-window toolbar buttons with a lighter, minimal interaction cue.
// Pair with `.sharedBackgroundVisibility(.hidden)` on the enclosing toolbar
// item/group (macOS 26+) so the system glass platter doesn't draw behind the flat
// button. Unlike `SLSecondaryButtonStyle` this has no resting fill. It nudges the
// label to medium weight to match AppKit's native toolbar buttons — a plain custom
// ButtonStyle otherwise renders regular weight, which looks too thin — but leaves
// the font size to each call site.

struct ToolbarHoverButtonStyle: ButtonStyle {
    /// Hover / pressed highlight strengths. Defaults match the main-window
    /// toolbar buttons; popover call sites pass stronger values because the
    /// translucent popover material washes out these faint toolbar opacities.
    var hoverOpacity: Double = 0.08
    var pressedOpacity: Double = 0.14

    func makeBody(configuration: Configuration) -> some View {
        ToolbarHoverButtonBody(
            configuration: configuration,
            hoverOpacity: hoverOpacity,
            pressedOpacity: pressedOpacity
        )
    }
}

private struct ToolbarHoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverOpacity: Double
    let pressedOpacity: Double
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.primary.opacity(pressedOpacity)
                            : (isHovered ? Color.primary.opacity(hoverOpacity) : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1.0 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
#endif
