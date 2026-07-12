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

    func testNumericAndStringIdsDoNotCollideInUiString() {
        // The pendingApprovals key is the uiString — .number(1) and .string("1") must
        // NOT map to the same key (review #5), or one approval would overwrite the other.
        XCTAssertNotEqual(CodexRPCID.number(1).uiString, CodexRPCID.string("1").uiString)
        XCTAssertEqual(CodexRPCID.number(1).uiString, "1")
        // The wire value is still echoed by TYPE, unaffected by the ui tag.
        XCTAssertEqual(CodexRPCID.string("1").jsonValue as? String, "1")
        XCTAssertEqual(CodexRPCID.number(1).jsonValue as? Int, 1)
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

    // SAFETY REGRESSION: without `approvalsReviewer: "user"`, codex falls back to the
    // user's `~/.codex` `approvals_reviewer` — an `auto_review` guardian silently
    // auto-approves mutations, so a write runs WITHOUT Rubien's approval card. Both
    // thread/start AND thread/resume must force "user" (approvals route to the client).
    func testThreadStartAndResumeForceUserApprovalsReviewer() {
        let start = try! XCTUnwrap(json(CodexAppServerProtocol.threadStart(
            requestID: 1, cwd: "/w", sandbox: "read-only", approvalPolicy: "on-request",
            developerInstructions: nil, model: nil))["params"] as? [String: Any])
        XCTAssertEqual(start["approvalsReviewer"] as? String, "user",
                       "thread/start must not defer approvals to codex's own guardian")

        let resume = try! XCTUnwrap(json(CodexAppServerProtocol.threadResume(
            requestID: 2, threadId: "t1"))["params"] as? [String: Any])
        XCTAssertEqual(resume["approvalsReviewer"] as? String, "user",
                       "a resumed conversation keeps the client-approval invariant")
        XCTAssertEqual(resume["threadId"] as? String, "t1")
    }

    func testTurnStartCarriesTextThenLocalImagesAndEffort() {
        let obj = json(CodexAppServerProtocol.turnStart(
            requestID: 3, threadId: "t", prompt: "hi",
            imagePaths: ["/ws/a.png", "/ws/b.jpg"], effort: "medium"))
        let params = try! XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "t")
        XCTAssertEqual(params["effort"] as? String, "medium")
        let input = (params["input"] as? [[String: Any]]) ?? []
        XCTAssertEqual(input.map { $0["type"] as? String }, ["text", "localImage", "localImage"])
        XCTAssertEqual(input.first?["text"] as? String, "hi")
        XCTAssertEqual(input[1]["path"] as? String, "/ws/a.png")
        XCTAssertEqual(input[2]["path"] as? String, "/ws/b.jpg")
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

    // MARK: History decoders (thread/list · thread/search · thread/read — 3b-4)

    func testDecodeThreadListMapsSummariesAndSkipsIdless() {
        let result: [String: Any] = ["data": [
            ["id": "t1", "preview": "Alpha", "updatedAt": 1_700_000_200],
            ["preview": "no id — dropped", "updatedAt": 1_700_000_100],  // no id → skipped
            ["id": "t2", "preview": "Beta", "updatedAt": 1_700_000_000],
        ]]
        let out = CodexAppServerProtocol.decodeThreadList(result)
        XCTAssertEqual(out.map(\.id), ["t1", "t2"])
        XCTAssertEqual(out[0].date, Date(timeIntervalSince1970: 1_700_000_200))
        XCTAssertTrue(out.allSatisfy { $0.matchSnippet == nil })
    }

    func testSessionSummaryEpochFallsBackWhenUpdatedAtMissing() {
        // No updatedAt → recencyAt; then createdAt; then 0.
        let recency = CodexAppServerProtocol.sessionSummary(
            fromThread: ["id": "t", "recencyAt": 111, "createdAt": 99])
        XCTAssertEqual(recency?.date, Date(timeIntervalSince1970: 111))
        let created = CodexAppServerProtocol.sessionSummary(fromThread: ["id": "t", "createdAt": 99])
        XCTAssertEqual(created?.date, Date(timeIntervalSince1970: 99))
        XCTAssertNil(CodexAppServerProtocol.sessionSummary(fromThread: ["preview": "x"]),
                     "a thread without an id has no resume target")
    }

    func testPreviewAndSnippetAreWhitespaceCollapsedAndTruncated() {
        let long = String(repeating: "wo rd ", count: 100)  // ~600 chars, spaced
        let summary = CodexAppServerProtocol.sessionSummary(
            fromThread: ["id": "t", "preview": "  multi\n\nline   preview  "],
            snippet: long)
        XCTAssertEqual(summary?.preview, "multi line preview")
        let snippet = try! XCTUnwrap(summary?.matchSnippet)
        XCTAssertLessThanOrEqual(snippet.count, CodexAppServerProtocol.snippetLimit)
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testDecodeThreadSearchWrapsThreadCarriesSnippetAndFiltersByCwd() {
        let result: [String: Any] = ["data": [
            ["thread": ["id": "h1", "preview": "Hit", "updatedAt": 1_700_000_000, "cwd": "/ws"], "snippet": "…ctx…"],
            ["thread": ["id": "other", "preview": "Foreign", "cwd": "/elsewhere"], "snippet": "x"],  // wrong cwd → dropped
            ["snippet": "orphan snippet, no thread"],  // no thread → skipped
        ]]
        // codex search is global; the decoder scopes hits to the requesting workspace.
        let out = CodexAppServerProtocol.decodeThreadSearch(result, cwd: "/ws")
        XCTAssertEqual(out.map(\.id), ["h1"], "only the in-workspace hit survives")
        XCTAssertEqual(out.first?.matchSnippet, "…ctx…")
    }

    func testTranscriptJoinsMultiTextUserAndDropsNonTextAndReasoning() {
        let result: [String: Any] = ["thread": ["turns": [
            ["items": [
                ["type": "userMessage", "content": [
                    ["type": "text", "text": "part one"],
                    ["type": "image", "url": "x"],          // non-text → skipped
                    ["type": "text", "text": "part two"],
                ]],
                ["type": "reasoning", "text": "internal"],   // reasoning → no row
                ["type": "agentMessage", "text": "answer"],
            ]],
        ]]]
        let rows = CodexAppServerProtocol.decodeThreadTranscript(result)
        XCTAssertEqual(rows.map(\.role), [.user, .assistant])
        XCTAssertEqual(rows[0].body, "part one\n\npart two")
        XCTAssertEqual(rows[1].body, "answer")
    }

    func testToolChipStatusClassifierIsSharedAndComplete() {
        // The denied set MUST match the live parser (failed/declined/cancelled); the
        // active set only surfaces when History reads a thread whose turn never finished.
        for denied in ["failed", "declined", "cancelled"] {
            XCTAssertEqual(CodexAppServerParser.toolChipStatus(denied), .denied)
        }
        for active in ["inProgress", "running", "queued"] {
            XCTAssertEqual(CodexAppServerParser.toolChipStatus(active), .started)
        }
        for done in ["completed", "unknownFutureState"] {
            XCTAssertEqual(CodexAppServerParser.toolChipStatus(done), .completed)
        }
        XCTAssertEqual(CodexAppServerParser.toolChipStatus(nil), .completed)
    }

    func testTranscriptToolStatusMapsDeniedAndActiveConsistently() {
        let result: [String: Any] = ["thread": ["turns": [
            ["items": [
                ["type": "commandExecution", "command": "rm -rf x", "status": "declined"],
                ["type": "fileChange", "status": "cancelled"],       // cancelled → denied (was dropped before)
                ["type": "commandExecution", "command": "sleep 9", "status": "inProgress"],  // active → started
            ]],
        ]]]
        let rows = CodexAppServerProtocol.decodeThreadTranscript(result)
        XCTAssertEqual(rows.map(\.role), [.tool, .tool, .tool])
        XCTAssertTrue(rows[0].body.contains("\"status\":\"denied\"") && rows[0].body.contains("shell"))
        XCTAssertTrue(rows[1].body.contains("\"status\":\"denied\""), "cancelled tool is denied, not completed")
        XCTAssertTrue(rows[2].body.contains("\"status\":\"started\""), "an unfinished tool stays started")
    }

    func testHistoryDecodersTolerateEmptyOrMissingPayloads() {
        XCTAssertTrue(CodexAppServerProtocol.decodeThreadList([:]).isEmpty)
        XCTAssertTrue(CodexAppServerProtocol.decodeThreadSearch(["data": []], cwd: "/x").isEmpty)
        XCTAssertTrue(CodexAppServerProtocol.decodeThreadTranscript([:]).isEmpty)
        XCTAssertTrue(CodexAppServerProtocol.decodeThreadTranscript(["thread": ["turns": []]]).isEmpty)
        XCTAssertTrue(CodexAppServerProtocol.threadReferencedIDs([:]).isEmpty)
    }

    func testThreadReferencedIDsExtractRubienToolArgumentsOnly() {
        // The "This document" scope's attribution: only `mcpToolCall` items from
        // the rubien server count — never other servers, prose, or results. Both
        // arg keys (`id`/`referenceId`), lenient string ids, and failed calls all
        // attribute; item shape verified against the live thread/read spike.
        let result: [String: Any] = ["thread": ["turns": [
            ["items": [
                ["type": "userMessage", "content": [["type": "text", "text": "id 999 in prose"]]],
                ["type": "mcpToolCall", "server": "rubien", "tool": "rubien_get",
                 "status": "completed", "arguments": ["id": 1675],
                 "result": ["content": [["type": "text", "text": "{\"id\":31}"]]]],
                ["type": "mcpToolCall", "server": "rubien", "tool": "rubien_annotations_list",
                 "status": "failed", "arguments": ["referenceId": 9]],
                ["type": "mcpToolCall", "server": "other", "tool": "get", "arguments": ["id": 3]],
                ["type": "mcpToolCall", "server": "rubien", "tool": "rubien_search",
                 "arguments": ["query": "ppo"]],
                ["type": "mcpToolCall", "server": "rubien", "tool": "rubien_get",
                 "arguments": ["id": "12"]],
            ]],
        ]]]
        XCTAssertEqual(CodexAppServerProtocol.threadReferencedIDs(result), [1675, 9, 12])
    }

    func testReferenceAttributionPolicyIsToolAwareAndRejectsNonIntegerIds() {
        // The properties trap: `id`/`ids` there are PROPERTY rowids (a colliding
        // namespace) — the reference is the `reference` argument. Encoded now so
        // Phase 4's write registration can't silently mis-attribute.
        XCTAssertEqual(
            ReferenceAttribution.referencedIDs(
                tool: "rubien_properties_set", arguments: ["reference": 900, "id": "29"]),
            [900], "property rowid 29 must not attribute; reference 900 must")
        XCTAssertTrue(
            ReferenceAttribution.referencedIDs(
                tool: "rubien_properties_list", arguments: ["ids": ["29", "31"]]).isEmpty,
            "properties_list ids are property rowids")
        // Array-shaped reference ids (cite/delete address MANY references).
        XCTAssertEqual(
            ReferenceAttribution.referencedIDs(tool: "rubien_cite", arguments: ["ids": [4, 5]]),
            [4, 5])
        // A boolean is not reference 1; a fractional number is not reference 42.
        XCTAssertNil(ReferenceAttribution.referenceArgument(true))
        XCTAssertNil(ReferenceAttribution.referenceArgument(42.9))
        XCTAssertEqual(ReferenceAttribution.referenceArgument(42), 42)
        XCTAssertEqual(ReferenceAttribution.referenceArgument("42"), 42)
        // Unknown (future) tools fall back to the default keys.
        XCTAssertEqual(
            ReferenceAttribution.referencedIDs(tool: "rubien_future_tool", arguments: ["id": 8]),
            [8])
    }

    // MARK: - model/list (model auto-discovery)

    /// Shape sanitized from a real codex 0.144.1 `model/list` capture (spec §2.1).
    private let modelListResult: [String: Any] = [
        "data": [
            [
                "id": "gpt-5.5", "model": "gpt-5.5", "displayName": "GPT-5.5",
                "description": "Frontier model.", "hidden": false, "isDefault": true,
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low", "description": "Fast"],
                    ["reasoningEffort": "medium", "description": "Balanced"],
                    ["reasoningEffort": "high", "description": "Deep"],
                    ["reasoningEffort": "xhigh", "description": "Extra deep"],
                ],
                "defaultReasoningEffort": "medium",
                "inputModalities": ["text", "image"], "futureUnknownField": 42,
            ],
            [
                "id": "gpt-5.6-sol", "model": "gpt-5.6-sol", "displayName": "GPT-5.6-Sol",
                "description": "Latest frontier agentic coding model.", "hidden": false,
                "isDefault": false,
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low", "description": "Fast"],
                    ["reasoningEffort": "max", "description": "Maximum"],
                    ["reasoningEffort": "ultra", "description": "Maximum + delegation"],
                ],
                "defaultReasoningEffort": "low",
            ],
            // Hidden entry — decoded, filtered only by visibleModels.
            ["id": "gpt-5.4", "displayName": "GPT-5.4", "hidden": true, "isDefault": false],
            // Missing efforts + displayName — falls back to id, empty efforts.
            ["id": "gpt-x-experimental"],
            // No usable id — dropped.
            ["displayName": "Ghost"],
        ]
    ]

    func testDecodeModelListMapsFieldsAndTolerartesUnknowns() {
        let models = CodexAppServerProtocol.decodeModelList(modelListResult)
        XCTAssertEqual(models.map(\.id), ["gpt-5.5", "gpt-5.6-sol", "gpt-5.4", "gpt-x-experimental"])

        let five5 = models[0]
        XCTAssertEqual(five5.displayName, "GPT-5.5")
        XCTAssertEqual(five5.description, "Frontier model.")
        XCTAssertTrue(five5.isDefault)
        XCTAssertFalse(five5.hidden)
        XCTAssertEqual(five5.efforts.map(\.value), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(five5.efforts.map(\.label), ["Low", "Medium", "High", "xHigh"])
        XCTAssertEqual(five5.defaultEffort, "medium")

        let sol = models[1]
        XCTAssertEqual(sol.efforts.map(\.value), ["low", "max", "ultra"])
        XCTAssertEqual(sol.efforts.map(\.label), ["Low", "Max", "Ultra"])
        XCTAssertEqual(sol.defaultEffort, "low")

        XCTAssertTrue(models[2].hidden)
        let experimental = models[3]
        XCTAssertEqual(experimental.displayName, "gpt-x-experimental", "missing displayName falls back to id")
        XCTAssertTrue(experimental.efforts.isEmpty)
        XCTAssertNil(experimental.defaultEffort)
        XCTAssertFalse(experimental.isDefault)
    }

    func testCodexCatalogVisibleModelsFiltersHidden() {
        let catalog = CodexCatalog(models: CodexAppServerProtocol.decodeModelList(modelListResult), fetchedOK: true)
        XCTAssertEqual(catalog.visibleModels.map(\.id), ["gpt-5.5", "gpt-5.6-sol", "gpt-x-experimental"])
        XCTAssertEqual(CodexCatalog.unavailable, CodexCatalog(models: [], fetchedOK: false))
    }

    func testDecodeModelListEmptyOrGarbageYieldsEmpty() {
        XCTAssertTrue(CodexAppServerProtocol.decodeModelList([:]).isEmpty)
        XCTAssertTrue(CodexAppServerProtocol.decodeModelList(["data": "not-an-array"]).isEmpty)
    }

    func testModelListRequestEncoding() throws {
        let line = CodexAppServerProtocol.modelList(requestID: 7)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(line.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "model/list")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual((object["params"] as? [String: Any])?.isEmpty, true)
    }

    /// The thread/start response reports the RESOLVED model — including when the
    /// request omitted `model` (Codex default; spec §2.2, verified 0.144.1).
    func testResolvedModelFromThreadResponse() {
        XCTAssertEqual(
            CodexAppServerProtocol.resolvedModel(fromThreadResponse:
                ["thread": ["id": "T1"], "model": "gpt-5.6-terra", "reasoningEffort": "max"]),
            "gpt-5.6-terra")
        XCTAssertNil(CodexAppServerProtocol.resolvedModel(fromThreadResponse: ["thread": ["id": "T1"]]))
        XCTAssertNil(CodexAppServerProtocol.resolvedModel(fromThreadResponse: ["model": ""]))
    }

    func testEffortLabelMapping() {
        XCTAssertEqual(CodexEffortInfo.label(for: "low"), "Low")
        XCTAssertEqual(CodexEffortInfo.label(for: "xhigh"), "xHigh")
        XCTAssertEqual(CodexEffortInfo.label(for: "ultra"), "Ultra")
        XCTAssertEqual(CodexEffortInfo.label(for: "some-new-tier"), "Some-New-Tier")
    }
}
#endif
