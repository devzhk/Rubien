import Foundation

/// Pure builder for the `window.RubienChat.*` JavaScript calls that Swift injects
/// into the transcript `WKWebView` via `evaluateJavaScript`.
///
/// Every argument is JSON-encoded and injected as a JS *literal*, never
/// string-interpolated. This is strictly more robust than a hand-rolled escaper:
/// `JSONEncoder` correctly handles quotes, newlines, backslashes, control chars,
/// unicode, and — because Foundation escapes forward slashes by default —
/// renders `</script>`-style hostile content inert (`<\/script>`).
///
/// The type is deliberately AppKit-free and pure so it can be unit-tested without
/// ever instantiating a WebView (WKWebView in the test suite deadlocks — repo memory).
enum ChatTranscriptJS {

    // MARK: - Contract calls (one per `window.RubienChat` function)

    /// `reset()` — clear the transcript.
    static func reset() -> String {
        jsCall("reset", [])
    }

    /// `loadTranscript(messages)` — full restore render.
    static func loadTranscript(_ messages: [ChatRenderMessage]) -> String {
        jsCall("loadTranscript", [encodeArg(messages)])
    }

    /// `addUserMessage(markdown)`.
    static func addUserMessage(_ markdown: String) -> String {
        jsCall("addUserMessage", [encodeArg(markdown)])
    }

    /// `beginAssistantMessage()`.
    static func beginAssistantMessage() -> String {
        jsCall("beginAssistantMessage", [])
    }

    /// `appendDelta(text)` — streaming chunk (no KaTeX yet).
    static func appendDelta(_ text: String) -> String {
        jsCall("appendDelta", [encodeArg(text)])
    }

    /// `commitAssistantMessage(markdown)` — authoritative final (runs KaTeX).
    static func commitAssistantMessage(_ markdown: String) -> String {
        jsCall("commitAssistantMessage", [encodeArg(markdown)])
    }

    /// `addToolChip({name, detail, status})`.
    static func addToolChip(name: String, detail: String?, status: ToolChipStatus) -> String {
        jsCall("addToolChip", [encodeArg(ToolChipPayload(name: name, detail: detail, status: status))])
    }

    /// `addNotice(markdown)`.
    static func addNotice(_ markdown: String) -> String {
        jsCall("addNotice", [encodeArg(markdown)])
    }

    /// `setTheme(mode)` — mode ∈ "light"|"dark".
    static func setTheme(_ mode: String) -> String {
        jsCall("setTheme", [encodeArg(mode)])
    }

    // MARK: - Primitives (pure, unit-tested)

    /// Assemble `window.RubienChat.<fn>(<arg0>,<arg1>,…)` from already-JSON-encoded
    /// literal arguments.
    static func jsCall(_ fn: String, _ jsonEncodedArgs: [String]) -> String {
        "window.RubienChat.\(fn)(\(jsonEncodedArgs.joined(separator: ",")))"
    }

    /// JSON-encode any `Encodable` value into a bare JS literal.
    ///
    /// The value is wrapped in a single-element array before encoding, then the
    /// enclosing `[` `]` are stripped. This sidesteps top-level-fragment
    /// restrictions (a bare `String`/`Int` isn't always a legal JSON document
    /// across Foundation versions) while yielding the exact literal we want —
    /// `"…"`, `123`, `{…}`, or `[…]`.
    static func encodeArg<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // deterministic object key order
        guard let data = try? encoder.encode([value]),
              var json = String(data: data, encoding: .utf8),
              json.hasPrefix("["), json.hasSuffix("]") else {
            return "null"
        }
        json.removeFirst() // leading [
        json.removeLast()  // trailing ]
        return escapeJSLineSeparators(json)
    }

    /// U+2028 / U+2029 are legal inside a JSON string but are line terminators in
    /// (pre-ES2019) JavaScript source. Since the literal is injected into
    /// `evaluateJavaScript`, rewrite them to their `\uXXXX` escapes — still valid
    /// JSON, and safe on every engine.
    static func escapeJSLineSeparators(_ s: String) -> String {
        guard s.contains("\u{2028}") || s.contains("\u{2029}") else { return s }
        return s
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
