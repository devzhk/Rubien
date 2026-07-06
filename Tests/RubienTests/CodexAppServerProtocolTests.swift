#if os(macOS)
import XCTest

@testable import Rubien

/// Fixture-driven tests for the pure `CodexAppServerParser` + `CodexAppServerProtocol`
/// codec (Phase 3b). Fixtures under `Fixtures/` are sanitized from the spike captures
/// (real `codex app-server` 0.142.5, v2 thread→turn→item stream) and loaded relative
/// to `#filePath`, so no `Package.swift` resource declaration is needed.
final class CodexAppServerProtocolTests: XCTestCase {

    // MARK: Fixture / JSON helpers

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func lines(ofFixture name: String) throws -> [String] {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Run every line of a fixture through one parser, in order, collecting events.
    private func events(fromFixture name: String) throws -> [AgentEvent] {
        var parser = CodexAppServerParser()
        var collected: [AgentEvent] = []
        for line in try lines(ofFixture: name) { collected += parser.parse(line: line) }
        return collected
    }

    private func firstLine(ofFixture name: String, containing needle: String) throws -> String {
        let line = try lines(ofFixture: name).first { $0.contains(needle) }
        return try XCTUnwrap(line, "no fixture line containing \(needle)")
    }

    private func json(_ string: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Happy-path stream

    func testBasicStreamProducesExactEventSequence() throws {
        let events = try events(fromFixture: "codex-basic.ndjson")

        // First meaningful event is the thread id (the resume target).
        guard case .sessionStarted = events.first else {
            return XCTFail("expected .sessionStarted first, got \(String(describing: events.first))")
        }

        // Streaming deltas, then the authoritative completed message.
        let deltas = events.compactMap { if case .assistantDelta(let t) = $0 { return t } else { return nil } }
        XCTAssertFalse(deltas.isEmpty, "expected at least one assistantDelta")

        let completed = events.compactMap { if case .assistantMessageCompleted(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(completed.count, 1)
        XCTAssertTrue(completed[0].contains("spike-ok"), "completed text was \(completed[0])")

        // Ends with a turnCompleted carrying usage (from tokenUsage.last).
        guard case .turnCompleted(let usage)? = events.last else {
            return XCTFail("expected .turnCompleted last, got \(String(describing: events.last))")
        }
        XCTAssertEqual(usage?.outputTokens, 7)
        XCTAssertEqual(usage?.inputTokens, 17435)
        XCTAssertEqual(usage?.cacheReadTokens, 1920)

        // Noise frames (remoteControl, mcpServer/startupStatus, thread/settings/status,
        // account/rateLimits) produced no events — only the 3-delta + framing set.
        XCTAssertNil(events.first { if case .toolUseStarted = $0 { return true } else { return false } })
    }

    // MARK: Approval flow

    func testApprovalStreamEmitsApprovalThenToolCompletes() throws {
        let events = try events(fromFixture: "codex-approval.ndjson")

        // Exactly one approval request, from the command-execution write.
        let approvals = events.compactMap { event -> (String, String, String)? in
            if case .approvalRequested(let id, let tool, let summary) = event { return (id, tool, summary) }
            return nil
        }
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.0, "0", "the verified approval id is numeric 0 → uiString \"0\"")
        XCTAssertEqual(approvals.first?.1, "shell")
        XCTAssertTrue(approvals.first?.2.contains("spike.txt") == true, "summary: \(approvals.first?.2 ?? "")")

        // The shell tool chip starts, then completes (status completed → not denied).
        let started = events.contains { if case .toolUseStarted("shell", _) = $0 { return true } else { return false } }
        let completed = events.contains { if case .toolUseCompleted("shell") = $0 { return true } else { return false } }
        XCTAssertTrue(started && completed, "shell chip should start and complete")
        XCTAssertNil(events.first { if case .toolDenied = $0 { return true } else { return false } })

        // The turn finishes.
        XCTAssertTrue(events.contains { if case .turnCompleted = $0 { return true } else { return false } })
    }

    // MARK: id-verbatim round-trip (design #1)

    func testApprovalRequestDecodesRawNumericIdAndEchoesVerbatim() throws {
        let line = try firstLine(ofFixture: "codex-approval.ndjson", containing: "requestApproval")
        let pending = try XCTUnwrap(CodexAppServerProtocol.decodeApprovalRequest(line: line))
        XCTAssertEqual(pending.id, .number(0), "the wire id is numeric 0, not the string \"0\"")
        XCTAssertEqual(pending.method, "item/commandExecution/requestApproval")
        XCTAssertEqual(pending.toolName, "shell")

        // The response MUST serialize the id as a NUMBER, not a string.
        let response = CodexAppServerProtocol.approvalResponse(id: pending.id, .allowOnce)
        let obj = json(response)
        XCTAssertEqual(obj["id"] as? Int, 0)
        XCTAssertNil(obj["id"] as? String)
        XCTAssertEqual((obj["result"] as? [String: Any])?["decision"] as? String, "accept")

        // The verified request offers ["accept", …, "cancel"] with NO "decline", so a
        // deny must fall back to "cancel" (codec review #1).
        XCTAssertTrue(pending.availableDecisions.contains("cancel"))
        XCTAssertFalse(pending.availableDecisions.contains("decline"))
        let denyObj = json(CodexAppServerProtocol.approvalResponse(
            id: pending.id, .deny, available: pending.availableDecisions))
        XCTAssertEqual((denyObj["result"] as? [String: Any])?["decision"] as? String, "cancel")
    }

    func testDenyPrefersDeclineWhenOffered() {
        // When the request DOES offer "decline", deny uses it (not cancel).
        let d = CodexAppServerProtocol.codexDecision(for: .deny, available: ["accept", "decline", "cancel"])
        XCTAssertEqual(d, "decline")
    }

    func testEmptyLastUsageClearsStaleUsage() {
        var parser = CodexAppServerParser()
        _ = parser.parse(line: #"{"jsonrpc":"2.0","method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"inputTokens":10,"outputTokens":2}}}}"#)
        // A later empty `.last` must CLEAR the prior usage, not leave it stale.
        _ = parser.parse(line: #"{"jsonrpc":"2.0","method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{}}}}"#)
        let done = parser.parse(line: #"{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
        guard case .turnCompleted(let usage)? = done.first else { return XCTFail("expected turnCompleted") }
        XCTAssertNil(usage)
    }

    func testMalformedApprovalIdProducesNoUnanswerableCard() {
        var parser = CodexAppServerParser()
        // id:true is not a valid JSON-RPC id → no approval event (it would be unanswerable).
        let events = parser.parse(line: #"{"jsonrpc":"2.0","id":true,"method":"item/commandExecution/requestApproval","params":{"reason":"x"}}"#)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(CodexAppServerProtocol.decodeApprovalRequest(
            line: #"{"jsonrpc":"2.0","id":true,"method":"item/commandExecution/requestApproval","params":{}}"#))
    }

    func testFractionalIdRejected() {
        // A fractional numeric id would echo lossily as an int — reject it as malformed.
        XCTAssertNil(CodexAppServerProtocol.decodeInbound(line: #"{"jsonrpc":"2.0","id":0.5,"result":{}}"#))
    }

    func testStringIdIsPreservedAsString() {
        let inbound = CodexAppServerProtocol.decodeInbound(
            line: #"{"jsonrpc":"2.0","id":"req-7","method":"item/fileChange/requestApproval","params":{}}"#)
        guard case .serverRequest(let id, _, _)? = inbound else { return XCTFail("expected serverRequest") }
        XCTAssertEqual(id, .string("req-7"))
        let obj = json(CodexAppServerProtocol.approvalResponse(id: id, .deny))
        XCTAssertEqual(obj["id"] as? String, "req-7")
    }

    // MARK: Frame classification

    func testDecodeInboundClassifiesResponseNotificationRequest() {
        // Response (id, no method).
        if case .response(let id, let result, _)? = CodexAppServerProtocol.decodeInbound(
            line: #"{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"t1"}}}"#) {
            XCTAssertEqual(id, .number(3))
            XCTAssertNotNil(result?["turn"])
        } else { XCTFail("expected .response") }

        // Notification (method, no id).
        if case .notification(let method, _)? = CodexAppServerProtocol.decodeInbound(
            line: #"{"jsonrpc":"2.0","method":"turn/completed","params":{}}"#) {
            XCTAssertEqual(method, "turn/completed")
        } else { XCTFail("expected .notification") }

        // Server request (id + method).
        if case .serverRequest(_, let method, _)? = CodexAppServerProtocol.decodeInbound(
            line: #"{"jsonrpc":"2.0","id":0,"method":"item/commandExecution/requestApproval","params":{}}"#) {
            XCTAssertEqual(method, "item/commandExecution/requestApproval")
        } else { XCTFail("expected .serverRequest") }

        XCTAssertNil(CodexAppServerProtocol.decodeInbound(line: "not json"))
    }

    // MARK: Usage uses `.last`, not the cumulative `.total` (design #7)

    func testUsageUsesLastNotTotal() {
        var parser = CodexAppServerParser()
        // .total is cumulative (big); .last is this turn (small) — we must report .last.
        let usageLine = #"""
        {"jsonrpc":"2.0","method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"u","tokenUsage":{"total":{"inputTokens":99999,"outputTokens":88888,"cachedInputTokens":7},"last":{"inputTokens":120,"outputTokens":34,"cachedInputTokens":5}}}}
        """#
        XCTAssertTrue(parser.parse(line: usageLine).isEmpty, "tokenUsage is accumulated, not emitted")
        let done = parser.parse(line: #"{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
        guard case .turnCompleted(let usage)? = done.first else { return XCTFail("expected turnCompleted") }
        XCTAssertEqual(usage?.inputTokens, 120)
        XCTAssertEqual(usage?.outputTokens, 34)
        XCTAssertEqual(usage?.cacheReadTokens, 5)
    }

    func testUsageResetsBetweenTurns() {
        var parser = CodexAppServerParser()
        _ = parser.parse(line: #"{"jsonrpc":"2.0","method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"inputTokens":10,"outputTokens":2}}}}"#)
        _ = parser.parse(line: #"{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
        // A second turn with NO usage frame must not inherit the first turn's usage.
        let done = parser.parse(line: #"{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
        guard case .turnCompleted(let usage)? = done.first else { return XCTFail("expected turnCompleted") }
        XCTAssertNil(usage)
    }

    // MARK: Failure + tolerance

    func testTerminalErrorNoticesButTransientRetryIsSilent() {
        var parser = CodexAppServerParser()
        let transient = parser.parse(line: #"{"jsonrpc":"2.0","method":"error","params":{"willRetry":true,"error":{"message":"blip"}}}"#)
        XCTAssertTrue(transient.isEmpty, "willRetry errors are heartbeats")
        let terminal = parser.parse(line: #"{"jsonrpc":"2.0","method":"error","params":{"willRetry":false,"error":{"message":"boom"}}}"#)
        XCTAssertEqual(terminal.count, 1)
        guard case .providerNotice(let msg)? = terminal.first else { return XCTFail("expected notice") }
        XCTAssertEqual(msg, "boom")
    }

    func testFailedToolItemBecomesDeniedChip() {
        var parser = CodexAppServerParser()
        _ = parser.parse(line: #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"type":"commandExecution","id":"c1","command":"rm x","status":"inProgress"}}}"#)
        let done = parser.parse(line: #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"type":"commandExecution","id":"c1","status":"declined"}}}"#)
        guard case .toolDenied(let name, _)? = done.first else { return XCTFail("expected toolDenied") }
        XCTAssertEqual(name, "shell")
    }

    func testToleranceIgnoresUnknownGarbageAndResponses() {
        var parser = CodexAppServerParser()
        XCTAssertTrue(parser.parse(line: "").isEmpty)
        XCTAssertTrue(parser.parse(line: "not json").isEmpty)
        XCTAssertTrue(parser.parse(line: #"{"jsonrpc":"2.0","method":"some/futureMethod","params":{}}"#).isEmpty)
        // A response to our own request has no `method` → the parser ignores it.
        XCTAssertTrue(parser.parse(line: #"{"jsonrpc":"2.0","id":1,"result":{}}"#).isEmpty)
    }

    // MARK: Encoders

    func testInitializeOptsIntoExperimentalApi() {
        let obj = json(CodexAppServerProtocol.initialize(requestID: 1, clientName: "rubien-assistant", version: "0.2.0"))
        XCTAssertEqual(obj["method"] as? String, "initialize")
        let caps = (obj["params"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertEqual(caps?["experimentalApi"] as? Bool, true)
    }

    func testThreadStartCarriesSandboxApprovalAndSeed() {
        let obj = json(CodexAppServerProtocol.threadStart(
            requestID: 2, cwd: "/w", sandbox: "read-only", approvalPolicy: "on-request",
            developerInstructions: "seed text", model: nil))
        let params = try! XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params["cwd"] as? String, "/w")
        XCTAssertEqual(params["developerInstructions"] as? String, "seed text")
        XCTAssertNil(params["model"], "empty/nil model override is omitted")
    }

    func testTurnStartCarriesTextInputAndEffort() {
        let obj = json(CodexAppServerProtocol.turnStart(requestID: 3, threadId: "t", prompt: "hi", effort: "medium"))
        let params = try! XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "t")
        XCTAssertEqual(params["effort"] as? String, "medium")
        let input = params["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["type"] as? String, "text")
        XCTAssertEqual(input?.first?["text"] as? String, "hi")
    }

    func testThreadListIncludesAppServerSourceKind() {
        let obj = json(CodexAppServerProtocol.threadList(requestID: 4, cwd: "/w", limit: 30))
        let kinds = (obj["params"] as? [String: Any])?["sourceKinds"] as? [String]
        XCTAssertEqual(kinds?.contains("appServer"), true, "omitting appServer would drop Rubien's own threads")
    }

    func testDecisionMapping() {
        XCTAssertEqual(CodexAppServerProtocol.codexDecision(for: .allowOnce), "accept")
        XCTAssertEqual(CodexAppServerProtocol.codexDecision(for: .allowForConversation), "acceptForSession")
        XCTAssertEqual(CodexAppServerProtocol.codexDecision(for: .deny), "decline")
    }

    func testUnsupportedRequestResponseEchoesIdAndErrors() {
        let obj = json(CodexAppServerProtocol.unsupportedRequestResponse(id: .number(5), method: "item/tool/call"))
        XCTAssertEqual(obj["id"] as? Int, 5)
        XCTAssertEqual((obj["error"] as? [String: Any])?["code"] as? Int, -32601)
    }
}
#endif
