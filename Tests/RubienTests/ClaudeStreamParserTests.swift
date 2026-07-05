import XCTest

@testable import Rubien

/// Fixture-driven tests for the pure `ClaudeStreamParser` and the control-protocol
/// codec (§4.2). Fixtures under `Fixtures/` are sanitized from the spike captures
/// (real `claude` 2.1.201 stream-json) and are loaded relative to `#filePath`, so
/// no `Package.swift` resource declaration is needed.
final class ClaudeStreamParserTests: XCTestCase {

    // MARK: Fixture loading

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    /// Run every line of a fixture through one parser, in order, collecting events.
    private func events(fromFixture name: String) throws -> [AgentEvent] {
        let text = try String(contentsOf: fixtureURL(name), encoding: .utf8)
        var parser = ClaudeStreamParser()
        var collected: [AgentEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            collected += parser.parse(line: String(line))
        }
        return collected
    }

    // MARK: Happy-path stream

    func testBasicStreamProducesExactEventSequence() throws {
        let events = try events(fromFixture: "claude-basic.ndjson")
        XCTAssertEqual(events, [
            .sessionStarted(sessionID: "11111111-1111-4111-8111-111111111111"),
            .assistantDelta(text: "Hel"),
            .assistantDelta(text: "lo"),
            .assistantMessageCompleted(text: "Hello"),
            // Session id ROTATES — re-captured from `result` (D5 / Risk #5).
            .sessionStarted(sessionID: "22222222-2222-4222-8222-222222222222"),
            .turnCompleted(usage: AgentUsage(
                inputTokens: 10, outputTokens: 5,
                cacheReadTokens: 100, cacheCreationTokens: 20, totalCostUSD: 0.0123)),
        ])
    }

    func testBasicStreamIgnoresAllowedRateLimitHeartbeatAndNonTextDeltas() throws {
        // The `status:"allowed"` rate_limit_event and the thinking_delta /
        // structural stream_events must NOT surface as events.
        let events = try events(fromFixture: "claude-basic.ndjson")
        XCTAssertFalse(events.contains { if case .providerNotice = $0 { return true } else { return false } })
        let deltas = events.filter { if case .assistantDelta = $0 { return true } else { return false } }
        XCTAssertEqual(deltas.count, 2)  // only the two text deltas
    }

    // MARK: Tool use + completion + denial

    func testToolUseStreamMapsChipsCompletionsAndDenials() throws {
        let events = try events(fromFixture: "claude-tooluse.ndjson")
        XCTAssertEqual(events, [
            .sessionStarted(sessionID: "aaaaaaaa-3333-4333-8333-333333333333"),
            // Narration text precedes the tool it introduces; thinking is ignored.
            .assistantMessageCompleted(text: "Let me read it."),
            .toolUseStarted(name: "Read", detail: "/ws/doc.md"),
            .toolUseCompleted(name: "Read"),
            .toolUseStarted(name: "Write", detail: "/ws/out.txt"),
            .toolUseCompleted(name: "Write"),
            .sessionStarted(sessionID: "aaaaaaaa-3333-4333-8333-333333333333"),
            .toolDenied(name: "Write", reason: "Permission denied"),
            .turnCompleted(usage: AgentUsage(inputTokens: 50, outputTokens: 12, totalCostUSD: 0.05)),
        ])
    }

    // MARK: Approval (control protocol)

    func testControlRequestBecomesApprovalRequested() throws {
        let events = try events(fromFixture: "claude-approval.ndjson")
        XCTAssertEqual(events, [
            .sessionStarted(sessionID: "bbbbbbbb-4444-4444-8444-444444444444"),
            .approvalRequested(id: "req-approve-1", toolName: "Write", summary: "note.txt"),
        ])
    }

    // MARK: Tolerance — degrade, never throw

    func testGarbageStreamToleratesUnknownTruncatedAndNonJSONLines() throws {
        // Fixture mixes: a leading warning, system/thinking_tokens, an unknown type,
        // a truncated JSON line, a blank line, a non-JSON line, a control_response
        // ack, and a throttled rate-limit — only the meaningful events survive.
        let events = try events(fromFixture: "claude-garbage.ndjson")
        XCTAssertEqual(events, [
            .sessionStarted(sessionID: "cccccccc-5555-4555-8555-555555555555"),
            .providerNotice("Rate limit (five_hour): throttled."),
            .sessionStarted(sessionID: "cccccccc-5555-4555-8555-555555555555"),
            .turnCompleted(usage: nil),  // empty `usage` → nil
        ])
    }

    func testIndividualMalformedLinesYieldNoEventsAndDoNotThrow() {
        var parser = ClaudeStreamParser()
        for line in ["", "   ", "not json", "{", "{\"type\":", #"{"type":"assistant","message":{"content":[{"type":"tex"#, "Warning: x"] {
            XCTAssertTrue(parser.parse(line: line).isEmpty, "line should be ignored: \(line)")
        }
    }

    func testUnknownTopLevelTypeIsIgnored() {
        var parser = ClaudeStreamParser()
        XCTAssertTrue(parser.parse(line: #"{"type":"some_new_2027_event","data":1}"#).isEmpty)
    }

    // MARK: Control-protocol codec (stdin side)

    func testDecodeCanUseToolExtractsBookkeeping() throws {
        let text = try String(contentsOf: fixtureURL("claude-approval.ndjson"), encoding: .utf8)
        let controlLine = text.split(separator: "\n").first { $0.contains("can_use_tool") }
        let pending = ClaudeControlProtocol.decodeCanUseTool(line: String(controlLine!))
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.requestID, "req-approve-1")
        XCTAssertEqual(pending?.toolUseID, "toolu_appr_1")
        XCTAssertEqual(pending?.toolName, "Write")
        XCTAssertEqual(pending?.input["file_path"] as? String, "/ws/note.txt")
    }

    func testDecodeCanUseToolReturnsNilForNonControlLines() {
        XCTAssertNil(ClaudeControlProtocol.decodeCanUseTool(line: #"{"type":"assistant","message":{}}"#))
        XCTAssertNil(ClaudeControlProtocol.decodeCanUseTool(line: "garbage"))
    }

    func testControlResponseAllowEchoesInputAndOmitsInterrupt() throws {
        let pending = ClaudeControlProtocol.PendingApproval(
            requestID: "req-9", toolUseID: "toolu_9", toolName: "Write",
            input: ["file_path": "/ws/a.txt"])
        let json = try decode(ClaudeControlProtocol.controlResponse(for: pending, decision: .allowOnce))

        XCTAssertEqual(json["type"] as? String, "control_response")
        let response = json["response"] as! [String: Any]
        XCTAssertEqual(response["subtype"] as? String, "success")
        XCTAssertEqual(response["request_id"] as? String, "req-9")
        let inner = response["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        XCTAssertEqual(inner["toolUseID"] as? String, "toolu_9")
        XCTAssertNil(inner["interrupt"])
        let updated = inner["updatedInput"] as! [String: Any]
        XCTAssertEqual(updated["file_path"] as? String, "/ws/a.txt")
    }

    func testControlResponseDenySetsInterrupt() throws {
        let pending = ClaudeControlProtocol.PendingApproval(
            requestID: "req-9", toolUseID: "toolu_9", toolName: "Bash", input: [:])
        let json = try decode(ClaudeControlProtocol.controlResponse(for: pending, decision: .deny))
        let inner = (json["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        XCTAssertEqual(inner["interrupt"] as? Bool, true)
        XCTAssertNotNil(inner["message"])
    }

    func testInitializeAndUserMessageShapes() throws {
        let initJSON = try decode(ClaudeControlProtocol.initializeRequest(requestID: "init-7"))
        XCTAssertEqual(initJSON["type"] as? String, "control_request")
        XCTAssertEqual(initJSON["request_id"] as? String, "init-7")
        XCTAssertEqual((initJSON["request"] as! [String: Any])["subtype"] as? String, "initialize")

        let userJSON = try decode(ClaudeControlProtocol.userMessage(prompt: "quotes \" and \n newline"))
        XCTAssertEqual(userJSON["type"] as? String, "user")
        let message = userJSON["message"] as! [String: Any]
        XCTAssertEqual(message["role"] as? String, "user")
        let content = message["content"] as! [[String: Any]]
        XCTAssertEqual(content.first?["text"] as? String, "quotes \" and \n newline")
    }

    // MARK: Helpers

    private func decode(_ line: String) throws -> [String: Any] {
        let data = try XCTUnwrap(line.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
