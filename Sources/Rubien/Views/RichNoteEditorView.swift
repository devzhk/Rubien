#if os(macOS)
import SwiftUI
import WebKit

/// A WYSIWYG Markdown note editor powered by TipTap, embedded via WKWebView.
/// Uses NoteEditorPool for pre-warmed instances – zero loading delay.
struct RichNoteEditorView: NSViewRepresentable {
    @Binding var markdown: String
    var placeholder: String = "Add a note…"
    var autoFocus: Bool = true
    /// When true, the editor body is rendered transparent instead of the light
    /// theme's opaque white, so a glass/material surface behind the host view
    /// shows through. Text colors still come from the active theme.
    var transparentBackground: Bool = false
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    var onContentHeightChanged: ((CGFloat) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coord = context.coordinator

        // Try to acquire a pre-warmed WebView from the pool
        if let pooled = NoteEditorPool.shared.acquire() {
            coord.webView = pooled
            coord.ownsWebView = true

            // Re-register message handlers on the pooled WebView
            let controller = pooled.configuration.userContentController
            controller.removeAllScriptMessageHandlers()
            controller.add(coord, name: "noteContentChanged")
            controller.add(coord, name: "noteEditorReady")
            controller.add(coord, name: "noteEditorFocused")
            controller.add(coord, name: "noteEditorBlurred")
            controller.add(coord, name: "noteContentHeightChanged")

            // The pooled view is already loaded — treat as ready
            coord.isEditorReady = true
            let theme = colorScheme == .dark ? "dark" : "light"
            coord.currentTheme = theme
            pooled.evaluateJavaScript("window.NoteEditor?.setTheme('\(theme)')", completionHandler: nil)
            coord.currentTransparent = transparentBackground
            Self.applyBackground(transparent: transparentBackground, to: pooled)

            let escapedPlaceholder = placeholder
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            pooled.evaluateJavaScript("window.NoteEditor?.setPlaceholder('\(escapedPlaceholder)')", completionHandler: nil)

            if !markdown.isEmpty {
                coord.lastSwiftMarkdown = markdown
                let escaped = Self.escapeForJS(markdown)
                pooled.evaluateJavaScript("window.NoteEditor?.setMarkdown('\(escaped)')", completionHandler: nil)
            }

            if autoFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    pooled.evaluateJavaScript("window.NoteEditor?.focus()", completionHandler: nil)
                }
            }

            return pooled
        }

        // Fallback: create a fresh WebView (should rarely happen)
        let controller = WKUserContentController()
        controller.add(coord, name: "noteContentChanged")
        controller.add(coord, name: "noteEditorReady")
        controller.add(coord, name: "noteEditorFocused")
        controller.add(coord, name: "noteEditorBlurred")
        controller.add(coord, name: "noteContentHeightChanged")

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        coord.webView = webView
        coord.ownsWebView = true
        loadEditorHTML(webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        let theme = colorScheme == .dark ? "dark" : "light"

        if coord.currentTheme != theme {
            coord.currentTheme = theme
            webView.evaluateJavaScript("window.NoteEditor?.setTheme('\(theme)')", completionHandler: nil)
        }

        if coord.isEditorReady && coord.currentTransparent != transparentBackground {
            coord.currentTransparent = transparentBackground
            Self.applyBackground(transparent: transparentBackground, to: webView)
        }

        if coord.isEditorReady && coord.lastSwiftMarkdown != markdown && !coord.isUserEditing {
            coord.lastSwiftMarkdown = markdown
            let escaped = Self.escapeForJS(markdown)
            webView.evaluateJavaScript("window.NoteEditor?.setMarkdown('\(escaped)')", completionHandler: nil)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.isEditorReady = false
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        if coordinator.ownsWebView {
            NoteEditorPool.shared.release(webView)
            coordinator.ownsWebView = false
        }
    }

    static func escapeForJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Toggles the editor body between the theme's opaque background and a
    /// transparent one. An inline style on the root element outranks the
    /// stylesheet `--bg`, so it holds in either theme; `removeProperty`
    /// restores the stylesheet default when a pooled WebView is later reused in
    /// an opaque-surface context.
    static func applyBackground(transparent: Bool, to webView: WKWebView) {
        let js = transparent
            ? "document.documentElement.style.setProperty('--bg', 'transparent')"
            : "document.documentElement.style.removeProperty('--bg')"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func loadEditorHTML(_ webView: WKWebView) {
        if let url = Bundle.module.url(forResource: "NoteEditor", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url = Bundle.module.url(forResource: "NoteEditor", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: RichNoteEditorView
        weak var webView: WKWebView?
        var isEditorReady = false
        var isUserEditing = false
        var lastSwiftMarkdown = ""
        var currentTheme = ""
        var currentTransparent = false
        var ownsWebView = false

        init(parent: RichNoteEditorView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "noteEditorReady":
                isEditorReady = true
                let theme = parent.colorScheme == .dark ? "dark" : "light"
                currentTheme = theme
                webView?.evaluateJavaScript("window.NoteEditor?.setTheme('\(theme)')", completionHandler: nil)
                currentTransparent = parent.transparentBackground
                if let webView {
                    RichNoteEditorView.applyBackground(transparent: parent.transparentBackground, to: webView)
                }

                let escapedPlaceholder = parent.placeholder
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                webView?.evaluateJavaScript("window.NoteEditor?.setPlaceholder('\(escapedPlaceholder)')", completionHandler: nil)

                if !parent.markdown.isEmpty {
                    lastSwiftMarkdown = parent.markdown
                    let escaped = RichNoteEditorView.escapeForJS(parent.markdown)
                    webView?.evaluateJavaScript("window.NoteEditor?.setMarkdown('\(escaped)')", completionHandler: nil)
                }

                if parent.autoFocus {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        self?.webView?.evaluateJavaScript("window.NoteEditor?.focus()", completionHandler: nil)
                    }
                }

            case "noteContentChanged":
                guard let body = message.body as? [String: Any],
                      let md = body["markdown"] as? String else { return }
                isUserEditing = true
                lastSwiftMarkdown = md
                Task { @MainActor [weak self] in
                    self?.parent.markdown = md
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self?.isUserEditing = false
                    }
                }

            case "noteEditorFocused":
                parent.onFocus?()

            case "noteContentHeightChanged":
                guard let body = message.body as? [String: Any],
                      let height = body["height"] as? CGFloat else { return }
                Task { @MainActor [weak self] in
                    self?.parent.onContentHeightChanged?(height)
                }

            case "noteEditorBlurred":
                guard let body = message.body as? [String: Any],
                      let md = body["markdown"] as? String else { return }
                isUserEditing = true
                lastSwiftMarkdown = md
                Task { @MainActor [weak self] in
                    self?.parent.markdown = md
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self?.isUserEditing = false
                    }
                }
                parent.onBlur?()

            default:
                break
            }
        }
    }
}
#endif
