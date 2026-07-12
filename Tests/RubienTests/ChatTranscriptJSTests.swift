#if os(macOS)
import Foundation
import XCTest
@testable import Rubien

/// Pure-helper coverage for the Assistant transcript bridge (Phase 1b). No
/// WKWebView is instantiated — only the AppKit-free JS builder, models, and the
/// external-link classifier (WKWebView in-suite deadlocks — repo memory).
final class ChatTranscriptJSTests: XCTestCase {

    // A single string exercising every escaping hazard the task calls out:
    // a double quote, a newline, backslashes, a unicode char, the literal
    // `</script>`, plus a U+2028 line separator (a JS-source line terminator).
    private let tricky = "q:\" nl:\n bs:\\\\ tag:</script> u:café☕️日本 ls:\u{2028}"

    // MARK: - Call shape (no-arg / simple)

    func testNoArgCalls() {
        XCTAssertEqual(ChatTranscriptJS.reset(), "window.RubienChat.reset()")
        XCTAssertEqual(ChatTranscriptJS.beginAssistantMessage(), "window.RubienChat.beginAssistantMessage()")
    }

    func testSetTheme() {
        XCTAssertEqual(ChatTranscriptJS.setTheme("dark"), #"window.RubienChat.setTheme("dark")"#)
        XCTAssertEqual(ChatTranscriptJS.setTheme("light"), #"window.RubienChat.setTheme("light")"#)
    }

    // MARK: - Single-string-argument calls

    func testStringArgCallsAreValidRoundTrippableJSON() throws {
        // fn name -> builder
        let builders: [(String, (String) -> String)] = [
            ("addUserMessage", ChatTranscriptJS.addUserMessage),
            ("appendDelta", ChatTranscriptJS.appendDelta),
            ("commitAssistantMessage", ChatTranscriptJS.commitAssistantMessage),
            ("addNotice", ChatTranscriptJS.addNotice),
            ("setTheme", ChatTranscriptJS.setTheme),
        ]

        for (fn, build) in builders {
            let call = build(tricky)
            let arg = try extractArgument(from: call, fn: fn)

            // 1. Argument is valid JSON and decodes back to the exact input.
            let decoded = try jsonFragment(arg)
            XCTAssertEqual(decoded as? String, tricky, "\(fn) argument must round-trip to the original string")

            // 2. Correct, non-lossy escaping.
            XCTAssertTrue(arg.hasPrefix("\"") && arg.hasSuffix("\""), "\(fn) arg is a JSON string literal")
            XCTAssertTrue(arg.contains("\\\""), "\(fn): quote escaped as \\\"")
            XCTAssertTrue(arg.contains("\\n"), "\(fn): newline escaped as \\n")
            XCTAssertTrue(arg.contains("\\\\"), "\(fn): backslash escaped as \\\\")
            XCTAssertTrue(arg.contains("<\\/script>"), "\(fn): forward slash escaped -> </script> rendered inert")
            XCTAssertTrue(arg.contains("\\u2028"), "\(fn): U+2028 escaped to \\u2028")

            // 3. No raw hazards leak into the JS source.
            XCTAssertFalse(arg.contains("</script>"), "\(fn): no raw </script>")
            XCTAssertFalse(arg.contains("\n"), "\(fn): no literal newline in the JS source")
            XCTAssertFalse(arg.unicodeScalars.contains(Unicode.Scalar(0x2028)!), "\(fn): no literal U+2028")

            // 4. Unicode is preserved literally (not mangled), per JSONEncoder default.
            XCTAssertTrue(arg.contains("café☕️日本"), "\(fn): unicode preserved literally")
        }
    }

    func testEmptyAndAsciiStrings() throws {
        XCTAssertEqual(ChatTranscriptJS.addUserMessage(""), #"window.RubienChat.addUserMessage("")"#)
        XCTAssertEqual(ChatTranscriptJS.appendDelta("hello"), #"window.RubienChat.appendDelta("hello")"#)
    }

    // MARK: - addToolChip

    func testAddToolChipObjectAndNilDetail() throws {
        let call = ChatTranscriptJS.addToolChip(name: "rubien_pdf_text", detail: "pages </script>", status: .completed)
        let arg = try extractArgument(from: call, fn: "addToolChip")
        let payload = try JSONDecoder().decode(ToolChipPayload.self, from: Data(arg.utf8))
        XCTAssertEqual(payload, ToolChipPayload(name: "rubien_pdf_text", detail: "pages </script>", status: .completed))
        XCTAssertFalse(arg.contains("</script>"), "hostile detail must be slash-escaped")

        let nilCall = ChatTranscriptJS.addToolChip(name: "Write", detail: nil, status: .denied)
        let nilArg = try extractArgument(from: nilCall, fn: "addToolChip")
        XCTAssertFalse(nilArg.contains("\"detail\""), "nil detail is omitted from the JSON (JS treats missing == null)")
        let nilPayload = try JSONDecoder().decode(ToolChipPayload.self, from: Data(nilArg.utf8))
        XCTAssertEqual(nilPayload, ToolChipPayload(name: "Write", detail: nil, status: .denied))
    }

    // MARK: - loadTranscript

    func testLoadTranscriptArrayRoundTrip() throws {
        let messages = [
            ChatRenderMessage(role: .user, body: "hi \"there\"\n</script>", seq: 0),
            ChatRenderMessage(role: .assistant, body: "answer", turnStatus: .interrupted, seq: 1),
            ChatRenderMessage(role: .tool, body: #"{"name":"x","detail":null,"status":"started"}"#, seq: 2),
        ]
        let call = ChatTranscriptJS.loadTranscript(messages)
        let arg = try extractArgument(from: call, fn: "loadTranscript")

        let decoded = try JSONDecoder().decode([ChatRenderMessage].self, from: Data(arg.utf8))
        XCTAssertEqual(decoded, messages)
        XCTAssertTrue(arg.hasPrefix("[") && arg.hasSuffix("]"), "argument is a JSON array literal")
        XCTAssertTrue(arg.contains(#""turnStatus":"interrupted""#), "a present turnStatus is encoded")
        XCTAssertFalse(arg.contains("\"turnStatus\":null"), "nil turnStatus is omitted, not explicit null")
        XCTAssertFalse(arg.contains("</script>"), "hostile body must be slash-escaped")
    }

    func testLoadTranscriptEmpty() {
        XCTAssertEqual(ChatTranscriptJS.loadTranscript([]), "window.RubienChat.loadTranscript([])")
    }

    func testStructuredUserPayloadAndLegacyDecode() throws {
        let attachment = ChatAttachmentPresentation(
            id: UUID(),
            displayName: "figure.png",
            kind: .image,
            byteCount: 123,
            isAvailable: true,
            thumbnailDataURL: "data:image/png;base64,AA=="
        )
        let payload = ChatUserMessagePayload(body: "Look", attachments: [attachment])
        let arg = try extractArgument(
            from: ChatTranscriptJS.addUserMessage(payload),
            fn: "addUserMessage"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ChatUserMessagePayload.self, from: Data(arg.utf8)),
            payload
        )

        let legacy = #"{"role":"user","body":"old","seq":0}"#
        XCTAssertEqual(
            try JSONDecoder().decode(ChatRenderMessage.self, from: Data(legacy.utf8)).attachments,
            []
        )
    }

    // MARK: - Model Codable round-trips

    func testChatRenderMessageRoundTrip() throws {
        let messages = [
            ChatRenderMessage(role: .user, body: "a", seq: 0),
            ChatRenderMessage(role: .assistant, body: "b", turnStatus: .interrupted, seq: 1),
            ChatRenderMessage(role: .tool, body: #"{"name":"t"}"#, turnStatus: nil, seq: 2),
            ChatRenderMessage(role: .notice, body: "c", turnStatus: .denied, seq: 3),
        ]
        let data = try JSONEncoder().encode(messages)
        XCTAssertEqual(try JSONDecoder().decode([ChatRenderMessage].self, from: data), messages)
    }

    func testChatRenderMessageDecodesMissingTurnStatusAsNil() throws {
        let json = #"{"role":"user","body":"x","seq":7}"#
        let msg = try JSONDecoder().decode(ChatRenderMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg, ChatRenderMessage(role: .user, body: "x", turnStatus: nil, seq: 7))
    }

    func testToolChipPayloadRoundTrip() throws {
        for payload in [
            ToolChipPayload(name: "a", detail: "d", status: .started),
            ToolChipPayload(name: "b", detail: nil, status: .completed),
            ToolChipPayload(name: "c", detail: "x", status: .denied),
        ] {
            let data = try JSONEncoder().encode(payload)
            XCTAssertEqual(try JSONDecoder().decode(ToolChipPayload.self, from: data), payload)
        }
    }

    func testEnumRawValuesMatchContract() {
        XCTAssertEqual([ChatRole.user, .assistant, .tool, .notice].map(\.rawValue),
                       ["user", "assistant", "tool", "notice"])
        XCTAssertEqual([ToolChipStatus.started, .completed, .denied].map(\.rawValue),
                       ["started", "completed", "denied"])
        XCTAssertEqual([ChatTheme.light, .dark].map(\.rawValue), ["light", "dark"])
        XCTAssertEqual([TurnStatus.interrupted, .denied].map(\.rawValue), ["interrupted", "denied"])
    }

    // MARK: - External-link classifier (threat-model layer 6)

    func testExternalLinkClassification() {
        // Plain http(s) → open.
        XCTAssertEqual(ChatExternalLink.classify("https://example.com/paper"), .open)
        XCTAssertEqual(ChatExternalLink.classify("http://arxiv.org/abs/1706.03762"), .open)
        XCTAssertEqual(ChatExternalLink.classify("https://example.com:443/x"), .open)
        XCTAssertEqual(ChatExternalLink.classify("http://example.com:80/x"), .open)

        // Non-web schemes and unparseable → reject.
        XCTAssertEqual(ChatExternalLink.classify("javascript:alert(1)"), .reject)
        XCTAssertEqual(ChatExternalLink.classify("file:///etc/passwd"), .reject)
        XCTAssertEqual(ChatExternalLink.classify("ftp://example.com/x"), .reject)
        XCTAssertEqual(ChatExternalLink.classify("mailto:a@b.com"), .reject)
        XCTAssertEqual(ChatExternalLink.classify("example.com/no-scheme"), .reject)
        XCTAssertEqual(ChatExternalLink.classify(""), .reject)

        // Odd hosts → confirm.
        XCTAssertEqual(ChatExternalLink.classify("https://192.168.0.1/x"), .confirm)
        XCTAssertEqual(ChatExternalLink.classify("https://user:pass@example.com/"), .confirm)
        XCTAssertEqual(ChatExternalLink.classify("https://example.com:8080/"), .confirm)
        XCTAssertEqual(ChatExternalLink.classify("https://xn--80ak6aa92e.com/"), .confirm)
    }

    func testIsIPAddress() {
        XCTAssertTrue(ChatExternalLink.isIPAddress("10.0.0.1"))
        XCTAssertTrue(ChatExternalLink.isIPAddress("255.255.255.0"))
        XCTAssertTrue(ChatExternalLink.isIPAddress("::1"))
        XCTAssertTrue(ChatExternalLink.isIPAddress("fe80::1"))
        XCTAssertFalse(ChatExternalLink.isIPAddress("example.com"))
        XCTAssertFalse(ChatExternalLink.isIPAddress("1.2.3"))
        XCTAssertFalse(ChatExternalLink.isIPAddress("999.1.1.1"))
        XCTAssertFalse(ChatExternalLink.isIPAddress("1.2.3.4.5"))
    }

    // MARK: - Helpers

    private enum ExtractError: Error { case mismatch }

    /// Strip `window.RubienChat.<fn>(` … `)` and return the bare argument text.
    private func extractArgument(from call: String, fn: String) throws -> String {
        let prefix = "window.RubienChat.\(fn)("
        guard call.hasPrefix(prefix), call.hasSuffix(")") else {
            XCTFail("call \(call) does not match window.RubienChat.\(fn)(…)")
            throw ExtractError.mismatch
        }
        return String(call.dropFirst(prefix.count).dropLast())
    }

    /// Parse a JSON fragment (top-level string allowed).
    private func jsonFragment(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
}
#endif
