#if os(macOS)
import AppKit
import SwiftUI

/// Keynote-style accent color well: a swatch that opens an anchored popover
/// with a hue/saturation wheel and brightness slider, instead of SwiftUI's
/// `ColorPicker`, whose shared `NSColorPanel` floats as a detached window.
struct AccentColorWell: View {
    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(AccentColorManager.shared.effectiveColor)
                .frame(width: 36, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Accent Color", bundle: .module))
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            ColorWheelPopover()
                .padding(16)
        }
    }
}

/// Hue/saturation wheel (hue = angle, saturation = radius, rendered at full
/// brightness) over a brightness slider, both committing live to
/// `AccentColorManager` so the whole app previews while dragging.
private struct ColorWheelPopover: View {
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 1

    private let wheelSize: CGFloat = 200
    private var wheelRadius: CGFloat { wheelSize / 2 }

    /// Static full-hue ring — never changes, so it's built once rather than
    /// re-allocated on every drag tick's body re-evaluation.
    private static let hueRingColors: [Color] =
        stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }

    var body: some View {
        VStack(spacing: 14) {
            wheel
            brightnessSlider
        }
        .onAppear(perform: loadCurrentColor)
    }

    // MARK: Wheel

    private var wheel: some View {
        ZStack {
            Circle()
                .fill(
                    // Hue = angle, 0° at 3 o'clock increasing clockwise (screen
                    // y is down) — must match the atan2 mapping in updateWheel.
                    AngularGradient(colors: Self.hueRingColors, center: .center)
                )
                .overlay(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white, .white.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: wheelRadius
                            )
                        )
                )
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
            marker
        }
        .frame(width: wheelSize, height: wheelSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { updateWheel(at: $0.location) }
        )
    }

    private var marker: some View {
        let angle = hue * 2 * .pi
        let distance = saturation * wheelRadius
        return Circle()
            .stroke(.white, lineWidth: 2)
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
            .offset(
                x: cos(angle) * distance,
                y: sin(angle) * distance
            )
            .allowsHitTesting(false)
    }

    private func updateWheel(at location: CGPoint) {
        let dx = location.x - wheelRadius
        let dy = location.y - wheelRadius
        saturation = min(1, sqrt(dx * dx + dy * dy) / wheelRadius)
        var degrees = atan2(dy, dx) * 180 / .pi // y-down → clockwise, matches the ring
        if degrees < 0 { degrees += 360 }
        hue = degrees / 360
        commit()
    }

    // MARK: Brightness

    private var brightnessSlider: some View {
        GeometryReader { geo in
            // Track the knob can travel: full width minus its own diameter
            // (the knob is as tall as the track).
            let usable = geo.size.width - geo.size.height
            let knobX = (1 - brightness) * usable
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: hue, saturation: saturation, brightness: 1),
                                .black,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                Circle()
                    .fill(.white)
                    .frame(width: geo.size.height - 2, height: geo.size.height - 2)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: knobX + 1)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(0, value.location.x - geo.size.height / 2), usable)
                        brightness = 1 - x / usable
                        commit()
                    }
            )
        }
        .frame(width: wheelSize, height: 20)
        .accessibilityLabel(String(localized: "Brightness", bundle: .module))
    }

    // MARK: State

    private func commit() {
        AccentColorManager.shared.setCustomColor(
            Color(hue: hue, saturation: saturation, brightness: brightness)
        )
    }

    private func loadCurrentColor() {
        // Seed the controls from the current effective accent (custom or system).
        (hue, saturation, brightness) = AccentColorManager.shared.effectiveHSB
    }
}
#endif
