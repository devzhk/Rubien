#if os(macOS) && DEBUG
import AppKit
import SwiftUI

/// Debug-only harness for the full chat sidebar — composer → streamed answer with a
/// tool chip + LaTeX — driven by a scripted fake provider (no real agent). Open from
/// **Debug ▸ Assistant Sidebar Harness** (`swift run Rubien`). Also exercises the exact
/// `@StateObject` init-wiring the web reader uses (renderer shared as the session's sink).
struct ChatSidebarHarnessView: View {
    @StateObject private var renderer: ChatTranscriptController
    @StateObject private var session: ChatSessionController

    init() {
        let renderer = ChatTranscriptController()
        _renderer = StateObject(wrappedValue: renderer)
        _session = StateObject(wrappedValue: ChatSessionController(
            provider: ScriptedAgentProvider(),
            transcript: renderer,
            reference: ChatReference(id: 1, title: "Attention Is All You Need", authors: "Vaswani et al."),
            workspaceURL: FileManager.default.temporaryDirectory))
    }

    var body: some View {
        ChatSidebarView(session: session, renderer: renderer, onClose: {
            // In the reader this collapses the pane; in the harness, close the window.
            NSApp.keyWindow?.performClose(nil)
        })
        .frame(minWidth: 340, minHeight: 520)
    }
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
