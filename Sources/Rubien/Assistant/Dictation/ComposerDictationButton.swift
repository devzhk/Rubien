#if os(macOS)
import AppKit
import SwiftUI

/// The composer's microphone: click to dictate into the draft, click again to stop.
/// Sized like the "+" menu beside it, so a state change never moves the control row.
struct ComposerDictationButton: View {
    @ObservedObject var controller: DictationController
    let owner: DictationController.Owner
    let bridge: ComposerDictationBridge
    /// Asked at each start: whether the caret sits at the end of a selected mention.
    let separatingFromPrecedingText: () -> Bool
    let onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var shownFailure: DictationFailure?

    private static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        if DictationEngines.isSupported {
            button
        }
    }

    private var state: DictationController.State { controller.state(for: owner) }

    private var button: some View {
        Button(action: toggle) {
            glyph
                .frame(width: 27, height: 27)
                .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .background(Self.shape.fill(background))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("composer-dictation-button")
        #if DEBUG
        // Lets the self-test click the button where it really is on screen. A
        // GeometryReader would miss moves that leave the size unchanged.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            DictationSelfTest.buttonFrames[ObjectIdentifier(bridge)] = frame
        }
        .onChange(of: state, initial: true) { _, state in
            DictationSelfTest.renderedStates[ObjectIdentifier(bridge)] = state
        }
        #endif
        .popover(isPresented: failurePresented, arrowEdge: .top) {
            // The live failure while it is set: the popover's content is built
            // when it is presented, before `shownFailure` has been recorded.
            // `shownFailure` keeps the text while the popover animates away.
            if let reason = ownFailure ?? shownFailure { failurePopover(reason) }
        }
        .onChange(of: ownFailure, initial: true) { _, reason in
            if let reason { shownFailure = reason }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.70))
        case .preparing(let progress?):
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, min(progress, 1)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
        case .preparing(nil):
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        case .listening:
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: !reduceMotion)
        case .finishing:
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.55))
        }
    }

    private var background: Color {
        switch state {
        case .listening, .finishing:
            return Color.accentColor.opacity(hovered ? 0.18 : 0.12)
        case .idle, .preparing:
            return hovered ? Color.primary.opacity(0.06) : Color.clear
        }
    }

    private var label: String {
        switch state {
        case .idle: return "Dictate"
        case .preparing(let progress?):
            return "Downloading speech model… \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        case .preparing(nil): return "Preparing dictation…"
        case .listening: return "Stop dictation"
        case .finishing: return "Finishing dictation…"
        }
    }

    private func toggle() {
        guard state == .idle else {
            controller.finish(owner: owner)
            return
        }
        controller.start(
            owner: owner,
            bridge: bridge,
            locale: DictationLanguage.startLocale(),
            separatingFromPrecedingText: separatingFromPrecedingText())
        onStart()
    }

    // MARK: Failure

    private var ownFailure: DictationFailure? {
        controller.failure?.owner == owner ? controller.failure?.reason : nil
    }

    private var failurePresented: Binding<Bool> {
        Binding(
            get: { ownFailure != nil },
            set: { if !$0 { controller.clearFailure(owner: owner) } })
    }

    private func failurePopover(_ failure: DictationFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure.title)
                .font(.callout.weight(.semibold))
            Text(failure.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = failure.settingsURL {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(url)
                    controller.clearFailure(owner: owner)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

extension DictationFailure {
    var title: String {
        switch self {
        case .microphoneDenied: return "Microphone access is off"
        case .speechRecognitionDenied: return "Speech recognition access is off"
        case .languageUnsupported: return "Language not available"
        case .noMicrophone: return "No microphone"
        case .editorUnavailable: return "Can’t dictate here right now"
        case .recognitionFailed: return "Dictation stopped"
        }
    }

    var message: String {
        switch self {
        case .microphoneDenied:
            return "Rubien needs microphone access to dictate. Turn it on for Rubien in System Settings > Privacy & Security > Microphone."
        case .speechRecognitionDenied:
            return "Rubien needs speech recognition access to dictate. Turn it on for Rubien in System Settings > Privacy & Security > Speech Recognition."
        case .languageUnsupported:
            return "This Mac can’t transcribe the dictation language on-device. Choose another language in Rubien Settings > Assistant."
        case .noMicrophone:
            return "Rubien couldn’t find a microphone, or the input device changed and dictation couldn’t continue. Check your microphone and try again."
        case .editorUnavailable:
            return "Finish the text you’re typing, then try again."
        case .recognitionFailed(let detail):
            let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Speech recognition failed. Try again."
                : "Speech recognition failed: \(detail)"
        }
    }

    /// The System Settings privacy pane that grants the missing permission.
    var settingsURL: URL? {
        switch self {
        case .microphoneDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRecognitionDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .languageUnsupported, .noMicrophone, .editorUnavailable, .recognitionFailed:
            return nil
        }
    }
}
#endif
