#if os(macOS)
import AppKit
import CoreFoundation
import SwiftUI
import WebKit
import RubienCore

/// Hosts the chat transcript renderer (`Resources/ChatTranscript.html`, built by
/// the `scripts/chat-renderer/` esbuild bundle) in a `WKWebView`. Mirrors
/// `RichNoteEditorView`: a fresh web view (no pooling needed for the sidebar),
/// transparent background, magnification off, and a `Coordinator` that bridges the
/// JS→Swift messages (`chatReady`, validated links, paper actions, and copy code).
///
/// The `ChatTranscriptController` (owned by the host view) drives the Swift→JS
/// direction. If `ChatTranscript.html` is missing (the parallel JS bundle may not
/// be built yet), the view loads blank and logs — it never crashes.
struct ChatTranscriptView: NSViewRepresentable {
    @ObservedObject var controller: ChatTranscriptController
    var onOpenReference: ((Int64) -> Void)? = nil
    var onOpenPaperSource: ((String) -> Void)? = nil
    var onAddPaperSource: ((String) -> Void)? = nil

    private static let logger = RubienLogger(subsystem: "com.rubien.app", category: "AssistantChat")

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            onOpenReference: onOpenReference,
            onOpenPaperSource: onOpenPaperSource,
            onAddPaperSource: onAddPaperSource)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coord = context.coordinator

        let contentController = WKUserContentController()
        contentController.add(coord, name: "chatReady")
        contentController.add(coord, name: "openExternalLink")
        contentController.add(coord, name: "openPaperReference")
        contentController.add(coord, name: "openPaperSource")
        contentController.add(coord, name: "addPaperSource")
        contentController.add(coord, name: "copyCode")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        // The transcript web view must never navigate away from its local
        // document; these delegates enforce that (see the Coordinator).
        webView.navigationDelegate = coord
        webView.uiDelegate = coord

        controller.attach(webView)
        Self.loadTranscriptHTML(webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Theme and content are pushed imperatively through the controller. Keep
        // action closures current because the representable's Coordinator may
        // outlive the particular ContentView value that first created it.
        context.coordinator.updateCallbacks(
            onOpenReference: onOpenReference,
            onOpenPaperSource: onOpenPaperSource,
            onAddPaperSource: onAddPaperSource)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        MainActor.assumeIsolated {
            coordinator.controller.detach()
        }
    }

    private static func loadTranscriptHTML(_ webView: WKWebView) {
        if let url = Bundle.module.url(forResource: "ChatTranscript", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url = Bundle.module.url(forResource: "ChatTranscript", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // The JS bundle is produced by a parallel workstream and may not exist
            // yet; degrade to a blank transcript rather than crash.
            logger.error("ChatTranscript.html not found in Bundle.module — transcript renderer will be blank until scripts/chat-renderer is built.")
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let controller: ChatTranscriptController
        private var onOpenReference: ((Int64) -> Void)?
        private var onOpenPaperSource: ((String) -> Void)?
        private var onAddPaperSource: ((String) -> Void)?

        init(
            controller: ChatTranscriptController,
            onOpenReference: ((Int64) -> Void)?,
            onOpenPaperSource: ((String) -> Void)?,
            onAddPaperSource: ((String) -> Void)?
        ) {
            self.controller = controller
            self.onOpenReference = onOpenReference
            self.onOpenPaperSource = onOpenPaperSource
            self.onAddPaperSource = onAddPaperSource
        }

        func updateCallbacks(
            onOpenReference: ((Int64) -> Void)?,
            onOpenPaperSource: ((String) -> Void)?,
            onAddPaperSource: ((String) -> Void)?
        ) {
            self.onOpenReference = onOpenReference
            self.onOpenPaperSource = onOpenPaperSource
            self.onAddPaperSource = onAddPaperSource
        }

        // WKScriptMessageHandler delivers on the main thread; hop onto the main
        // actor synchronously so the @MainActor controller + AppKit calls are legal.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let name = message.name
            let body = message.body
            MainActor.assumeIsolated {
                switch name {
                case "chatReady":
                    controller.handleReady()

                case "openExternalLink":
                    guard let dict = body as? [String: Any],
                          let urlString = dict["url"] as? String else { return }
                    ChatExternalLinkOpener.open(urlString)

                case "openPaperReference":
                    guard let dict = body as? [String: Any],
                          let number = dict["referenceId"] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite,
                          number.doubleValue.rounded() == number.doubleValue,
                          number.doubleValue > 0,
                          number.doubleValue <= 9_007_199_254_740_991
                    else { return }
                    onOpenReference?(number.int64Value)

                case "openPaperSource":
                    guard let dict = body as? [String: Any],
                          let urlString = dict["url"] as? String,
                          ChatExternalLink.classify(urlString) != .reject
                    else { return }
                    onOpenPaperSource?(urlString)

                case "addPaperSource":
                    guard let dict = body as? [String: Any],
                          let urlString = dict["url"] as? String,
                          ChatExternalLink.classify(urlString) != .reject
                    else { return }
                    onAddPaperSource?(urlString)

                case "copyCode":
                    guard let dict = body as? [String: Any],
                          let code = dict["code"] as? String else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)

                default:
                    break
                }
            }
        }

        // MARK: - WKNavigationDelegate / WKUIDelegate
        //
        // The transcript must never navigate away from its local
        // `ChatTranscript.html`. Left-clicks are already intercepted in JS
        // (`openExternalLink`); these are the reliable backstop for context-menu
        // "Open Link", modifier-clicks, `target=_blank`, and any programmatic or
        // remote navigation — otherwise a user- or content-controlled link could
        // load remote content in the transcript web view, defeating the CSP and
        // the "links routed to Swift" invariant (threat-model §3). WebKit delivers
        // these on the main thread, so hop to the main actor for the classifier.

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            // Allow only our own initial local document load (loadFileURL → .other).
            if navigationAction.navigationType == .other, url?.isFileURL == true {
                decisionHandler(.allow)
                return
            }
            // Anything else is a link the user/content activated: route http/https
            // through the same Swift classifier the JS path uses; drop the rest.
            routeExternal(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Never spawn a child web view (target=_blank / "Open in New Window").
            routeExternal(navigationAction.request.url)
            return nil
        }

        private func routeExternal(_ url: URL?) {
            guard let url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            MainActor.assumeIsolated { ChatExternalLinkOpener.open(url.absoluteString) }
        }
    }
}

/// One native open policy for ordinary transcript links and paper-card sources.
/// Every call re-validates the HTTP(S) URL and confirms unusual hosts.
@MainActor
enum ChatExternalLinkOpener {
    private static let logger = RubienLogger(
        subsystem: "com.rubien.app", category: "AssistantChat")

    static func open(_ urlString: String) {
        switch ChatExternalLink.classify(urlString) {
        case .reject:
            logger.error("Rejected non-http(s)/hostless URL from transcript renderer")
        case .confirm:
            guard let url = URL(string: urlString), confirmOpen(url) else { return }
            NSWorkspace.shared.open(url)
        case .open:
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private static func confirmOpen(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open this link?", bundle: .module)
        alert.informativeText = url.absoluteString
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Open", bundle: .module))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
