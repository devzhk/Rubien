#if os(macOS)
import Foundation
import WebKit

/// Drives the transcript `WKWebView`: the future chat sidebar (and the debug
/// harness) call one method per `window.RubienChat` function; each is turned into
/// a JS call by the pure `ChatTranscriptJS` builder and either evaluated (if the
/// page has posted `chatReady`) or queued until it does.
///
/// The web view is held weakly — it is owned by the view hierarchy via
/// `ChatTranscriptView`. On `chatReady` the current theme is applied first, then
/// the pending-JS queue is flushed in order, so restored content always paints in
/// the right theme.
@MainActor
final class ChatTranscriptController: ObservableObject {

    private weak var webView: WKWebView?
    private(set) var isReady = false
    private var pendingJS: [String] = []
    private var currentTheme: ChatTheme = .light

    init() {}

    // MARK: - Bridge lifecycle (called by ChatTranscriptView / its Coordinator)

    /// Bind the web view that hosts `ChatTranscript.html`. Called from
    /// `makeNSView`; the reference is weak.
    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Handle the one-shot `chatReady` message: mark ready, apply the current
    /// theme, then flush everything queued before the page loaded.
    func handleReady() {
        isReady = true
        webView?.evaluateJavaScript(ChatTranscriptJS.setTheme(currentTheme.rawValue), completionHandler: nil)
        let queued = pendingJS
        pendingJS.removeAll()
        for js in queued {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// The web view is going away (view dismantled). Reset so later calls queue
    /// again rather than target a dead view.
    func detach() {
        isReady = false
        webView = nil
        pendingJS.removeAll()
    }

    // MARK: - window.RubienChat contract (one method per JS function)

    /// Clear the transcript.
    func reset() {
        evaluateOrEnqueue(ChatTranscriptJS.reset())
    }

    /// Full restore render from persisted messages.
    func loadTranscript(_ messages: [ChatRenderMessage]) {
        evaluateOrEnqueue(ChatTranscriptJS.loadTranscript(messages))
    }

    /// Append a user message (markdown).
    func addUserMessage(_ markdown: String) {
        evaluateOrEnqueue(ChatTranscriptJS.addUserMessage(markdown))
    }

    /// Append a user message with safe, local-only attachment presentation.
    func addUserMessage(_ payload: ChatUserMessagePayload) {
        evaluateOrEnqueue(ChatTranscriptJS.addUserMessage(payload))
    }

    /// Open a fresh assistant bubble to stream into.
    func beginAssistantMessage() {
        evaluateOrEnqueue(ChatTranscriptJS.beginAssistantMessage())
    }

    /// Append a streamed chunk to the open assistant bubble (no KaTeX yet).
    func appendDelta(_ text: String) {
        evaluateOrEnqueue(ChatTranscriptJS.appendDelta(text))
    }

    /// Replace the streamed buffer with the authoritative final text (runs KaTeX).
    func commitAssistantMessage(_ markdown: String) {
        evaluateOrEnqueue(ChatTranscriptJS.commitAssistantMessage(markdown))
    }

    /// Add a collapsed tool-use chip.
    func addToolChip(name: String, detail: String?, status: ToolChipStatus) {
        evaluateOrEnqueue(ChatTranscriptJS.addToolChip(name: name, detail: detail, status: status))
    }

    /// Add a chronological suggested-paper row. Invalid/empty groups are
    /// rejected before they can cross into the WebView.
    func addPaperGroup(_ group: ChatPaperGroup) {
        guard let bounded = ChatPaperPresentation.validatedGroup(group) else { return }
        evaluateOrEnqueue(ChatTranscriptJS.addPaperGroup(bounded))
    }

    /// Add an inline notice row (markdown).
    func addNotice(_ markdown: String) {
        evaluateOrEnqueue(ChatTranscriptJS.addNotice(markdown))
    }

    /// Set the renderer theme. Stored as the source of truth and re-applied on the
    /// next `chatReady` so a theme chosen before the page loads still takes effect.
    func setTheme(_ mode: ChatTheme) {
        currentTheme = mode
        if isReady {
            webView?.evaluateJavaScript(ChatTranscriptJS.setTheme(mode.rawValue), completionHandler: nil)
        }
    }

    // MARK: - Internal

    private func evaluateOrEnqueue(_ js: String) {
        if isReady, let webView {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pendingJS.append(js)
        }
    }
}
#endif
