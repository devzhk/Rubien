#if os(macOS) && DEBUG
import AppKit
import SwiftUI

/// Debug-only harness for the full chat sidebar — composer → streamed answer with a
/// tool chip + LaTeX — driven by a scripted fake provider (no real agent). Open from
/// **Debug ▸ Assistant Sidebar Harness** (`swift run Rubien`). Also exercises the exact
/// `@StateObject` init-wiring the web reader uses (renderer shared as the session's sink).
struct ChatSidebarHarnessView: View {
    private enum HarnessAppearance: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        var id: Self { self }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    @StateObject private var renderer: ChatTranscriptController
    @StateObject private var session: ChatSessionController
    @State private var appearance: HarnessAppearance = .system

    init() {
        let renderer = ChatTranscriptController()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rubien-Assistant-Sidebar-Harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let session = ChatSessionController(
            provider: ScriptedAgentProvider(),
            transcript: renderer,
            reference: ChatReference(
                id: 1,
                title: "Attention Is All You Need",
                authors: "Vaswani et al."),
            workspaceURL: workspace)
        _renderer = StateObject(wrappedValue: renderer)
        _session = StateObject(wrappedValue: session)

        // Keep a ready text chip and an image thumbnail in the debug composer so
        // light/dark layout can be inspected without signing in to an agent CLI.
        let noteURL = workspace.appendingPathComponent("Harness Context.md")
        try? Data("# Harness context\nA staged Markdown attachment.".utf8).write(to: noteURL)
        session.stageAttachments([noteURL])
        if let imageData = Data(base64Encoded: Self.previewPNGBase64) {
            session.stagePastedImage(imageData, suggestedName: "Architecture Preview.png")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Appearance", selection: $appearance) {
                ForEach(HarnessAppearance.allCases) { appearance in
                    Text(appearance.rawValue).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            ChatSidebarView(session: session, renderer: renderer, onClose: {
                // In the reader this collapses the pane; in the harness, close the window.
                NSApp.keyWindow?.performClose(nil)
            })
        }
        .preferredColorScheme(appearance.colorScheme)
        .frame(minWidth: 340, minHeight: 520)
    }

    /// A tiny valid PNG fixture; the production normalizer expands it into its
    /// regular bounded thumbnail path, exercising the same preview code as a paste.
    private static let previewPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}

/// Streams a canned answer (session id → tool chip → deltas → commit) so the sidebar's
/// live path can be eyeballed. Approval + empty-state are exercised against real Claude
/// in the reader.
private final class ScriptedAgentProvider: AgentProvider, @unchecked Sendable {
    let kind: AgentProviderKind = .claude

    func isAvailable() async -> AgentAvailability { .installed(version: "demo", path: "/demo/claude") }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.sessionStarted(sessionID: "demo-session"))
                continuation.yield(.toolUseStarted(name: "rubien_read_text", detail: "pages 1–3"))
                try? await Task.sleep(nanoseconds: 250_000_000)
                continuation.yield(.toolUseCompleted(name: "rubien_read_text"))
                let answer = """
                Here is a streamed answer with inline math \\(E=mc^2\\) and a display:

                $$\\int_0^1 x^2\\,dx = \\tfrac13$$

                It also has a code block:

                ```swift
                let attn = softmax(q @ k.transposed() / sqrt(dk)) @ v
                ```
                """
                let chars = Array(answer)
                var index = 0
                while index < chars.count {
                    if Task.isCancelled { break }
                    let end = min(index + 14, chars.count)
                    continuation.yield(.assistantDelta(text: String(chars[index..<end])))
                    index = end
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                if !Task.isCancelled {
                    continuation.yield(.assistantMessageCompleted(text: answer))
                    continuation.yield(.turnCompleted(usage: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {}
    func cancel() {}
}

// MARK: - Debug window (the menu button lives in AssistantHarnessMenuCommands)

@MainActor
final class AssistantSidebarHarnessWindowController {
    static let shared = AssistantSidebarHarnessWindowController()
    private var window: NSWindow?
    private init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: ChatSidebarHarnessView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Assistant Sidebar Harness"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 380, height: 620))
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
