#if canImport(Sparkle)
import SwiftUI

/// Toolbar "pill" for an available Sparkle update. Visibility is owned by the
/// caller (the `ReferenceTableView` toolbar, gated on
/// `UpdateController.updateReadyToInstall`), so this view unconditionally renders
/// the button. Tapping it installs the pending update and relaunches.
///
/// Drawn with a hand-rolled `UpdatePillButtonStyle` (a concrete `Capsule().fill`)
/// rather than the system `.glassProminent` style. The native prominent-glass
/// material drops its accent fill while the main window is not key — e.g. when
/// the theme is flipped from the Settings window (`NSApplication.appearance` is
/// set app-wide; see `RubienPreferences.applyColorScheme()`) — so the pill
/// flashed to bare glass (white in light mode, black in dark) until the main
/// window re-rendered. A plain filled shape has no such material state and stays
/// stable across appearance changes.
struct UpdateIndicator: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        Button {
            updater.installAndRelaunch()
        } label: {
            Text("Update")
        }
        .buttonStyle(UpdatePillButtonStyle(fill: softAccent))
        .help("Update to \(updater.pendingVersion ?? "—") ready — click to install and relaunch")
        .accessibilityLabel("Install update and relaunch")
    }

    /// The app's effective accent lightened ~10% toward white (slightly lower
    /// saturation, a touch lighter) so the pill reads less heavy than a full
    /// accent fill while keeping the white label legible. Read from
    /// `AccentColorManager` (the custom-or-system accent source of truth) rather
    /// than the environment's `Color.accentColor`: it is `@Observable`, so the
    /// pill still tracks accent changes, and it stays a concrete color — the
    /// macOS 14.x `mixedTowardWhite` fallback bridges through `NSColor`, which
    /// would otherwise drop a SwiftUI-injected custom accent back to the system
    /// one. Safe as a plain `Capsule` fill: unlike the glass material, a filled
    /// shape doesn't drop out on appearance changes.
    private var softAccent: Color {
        AccentColorManager.shared.effectiveColor.mixedTowardWhite(by: 0.1)
    }
}

/// Accent "pill": a white semibold label on a concrete capsule fill, with subtle
/// hover/press feedback. Text is pinned to 12pt to match the neighboring
/// Properties toolbar button.
///
/// A deliberate sibling of `SLPrimaryButtonStyle` (same concrete-fill technique
/// and press/hover feel), kept separate rather than parameterizing the shared
/// style: the capsule shape, soft-accent fill, and fixed 12pt size are specific
/// to this toolbar pill, and folding them into `SLPrimaryButtonStyle` would
/// churn its many existing call sites for one new caller.
private struct UpdatePillButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        UpdatePillBody(configuration: configuration, fill: fill)
    }
}

private struct UpdatePillBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    configuration.isPressed
                        ? fill.opacity(0.78)
                        : (isHovered ? fill.opacity(0.9) : fill)
                )
            )
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
#endif
