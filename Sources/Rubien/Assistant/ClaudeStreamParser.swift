import Foundation

// MARK: - Claude stream-json parser (verified against claude 2.1.201)
//
// A PURE, tolerant mapper from NDJSON stdout lines to `[AgentEvent]` (§4.2). It is
// deterministic and free of process/IO side effects, so fixture tests can feed it
// captured lines and assert the exact event sequence. `ClaudeCodeProvider` drives
// it line-by-line off the child's stdout.
//
// Tolerance contract (Risk #3 — the runtime updates monthly): **unknown `type`s
// are ignored and partial/garbage lines are dropped — the parser NEVER throws.**
//
// A tiny bit of cross-line state is retained (tool_use_id → tool name) so a later
// `tool_result` can complete the right chip; this keeps `parse` deterministic over
// a line *sequence* without any external effects.

struct ClaudeImageInput: Sendable, Equatable {
    let mediaType: String
    let base64Data: String
}

struct ClaudeStreamParser {

    /// tool_use_id → tool name, so a `tool_result` (which carries only the id) can
    /// emit `toolUseCompleted(name:)`. Bounded implicitly by a turn's tool count.
    private var toolNamesByUseID: [String: String] = [:]
    private var presentationOrdinalsByUseID: [String: Int] = [:]
    private var nextPresentationOrdinal = 0

    init() {}

    /// Map one raw stdout line to zero or more events. Never throws; a line that is
    /// blank, non-JSON, truncated, or an unknown `type` yields `[]`.
    mutating func parse(line rawLine: String) -> [AgentEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fast reject: NDJSON objects start with '{'. Warnings ("Warning: no stdin
        // data received…"), blank lines, and other stray stdout text are dropped.
        guard line.first == "{" else { return [] }
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        switch object["type"] as? String {
        case "system":
            return parseSystem(object)
        case "stream_event":
            return parseStreamEvent(object)
        case "assistant":
            return parseAssistant(object)
        case "user":
            return parseUser(object)
        case "result":
            return parseResult(object)
        case "control_request":
            return parseControlRequest(object)
        case "rate_limit_event":
            return parseRateLimit(object)
        default:
            // Unknown top-level type (control_response acks to our own requests,
            // system/thinking_tokens, future types, …) → ignored.
            return []
        }
    }

    // MARK: - Per-type handlers

    private func parseSystem(_ object: [String: Any]) -> [AgentEvent] {
        // Only `subtype:"init"` carries the session id; other system subtypes
        // (thinking_tokens, hook_started, task_*) are ignored.
        guard object["subtype"] as? String == "init",
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty
        else { return [] }
        return [.sessionStarted(sessionID: sessionID)]
    }

    private func parseStreamEvent(_ object: [String: Any]) -> [AgentEvent] {
        // Partial messages (`--include-partial-messages`). Only text deltas become
        // `assistantDelta`; message_start / content_block_start|stop / message_delta
        // / message_stop / ping are structural and ignored (no mid-stream flicker).
        guard let event = object["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String
        else { return [] }
        return [.assistantDelta(text: text)]
    }

    private mutating func parseAssistant(_ object: [String: Any]) -> [AgentEvent] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        var events: [AgentEvent] = []
        var textParts: [String] = []
        var toolEvents: [AgentEvent] = []

        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { textParts.append(text) }
            case "tool_use":
                let name = (block["name"] as? String) ?? "tool"
                if let useID = block["id"] as? String {
                    toolNamesByUseID[useID] = name
                    if ChatPaperPresentation.isPresentationTool(name) {
                        presentationOrdinalsByUseID[useID] = nextPresentationOrdinal
                        nextPresentationOrdinal += 1
                    }
                }
                toolEvents.append(.toolUseStarted(name: name, detail: Self.summarize(block["input"])))
            default:
                // `thinking` blocks and any future block type are ignored.
                break
            }
        }

        // Reading order: the narration text ("Let me read it.") precedes the tool it
        // introduces, so emit the completed text first, then the tool chips.
        let joined = textParts.joined()
        if !joined.isEmpty { events.append(.assistantMessageCompleted(text: joined)) }
        events.append(contentsOf: toolEvents)
        return events
    }

    private mutating func parseUser(_ object: [String: Any]) -> [AgentEvent] {
        // A `user` message carries tool_result block(s) — the completion side of a
        // tool chip. Map each to `toolUseCompleted` using the recalled name.
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }
        var events: [AgentEvent] = []
        for block in content where block["type"] as? String == "tool_result" {
            guard let useID = block["tool_use_id"] as? String else { continue }
            let name = toolNamesByUseID[useID] ?? "tool"
            if ChatPaperPresentation.isPresentationTool(name),
               block["is_error"] as? Bool != true,
               let group = ChatPaperPresentation.decodeToolResult(block["content"]) {
                let ordinal: Int
                if let started = presentationOrdinalsByUseID[useID] {
                    ordinal = started
                } else {
                    ordinal = nextPresentationOrdinal
                    nextPresentationOrdinal += 1
                    presentationOrdinalsByUseID[useID] = ordinal
                }
                events.append(.paperPresentation(
                    callID: useID,
                    ordinal: ordinal,
                    group: group
                ))
            }
            events.append(.toolUseCompleted(name: name))
        }
        return events
    }

    private mutating func parseResult(_ object: [String: Any]) -> [AgentEvent] {
        var events: [AgentEvent] = []
        // Re-capture the (rotated) session id from EVERY result (D5 / Risk #5),
        // even if unchanged — this is the only channel the controller has to learn
        // the next `--resume` id.
        if let sessionID = object["session_id"] as? String, !sessionID.isEmpty {
            events.append(.sessionStarted(sessionID: sessionID))
        }
        // permission_denials[] → denied-tool chips.
        if let denials = object["permission_denials"] as? [[String: Any]] {
            for denial in denials {
                let name = (denial["tool_name"] as? String) ?? "tool"
                events.append(.toolDenied(name: name, reason: "Permission denied"))
            }
        }
        events.append(.turnCompleted(
            outcome: Self.parseOutcome(object),
            usage: Self.parseUsage(object)
        ))
        toolNamesByUseID.removeAll(keepingCapacity: true)
        presentationOrdinalsByUseID.removeAll(keepingCapacity: true)
        nextPresentationOrdinal = 0
        return events
    }

    private func parseControlRequest(_ object: [String: Any]) -> [AgentEvent] {
        guard let request = object["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool"
        else { return [] }
        let requestID = (object["request_id"] as? String) ?? ""
        let toolName = (request["tool_name"] as? String) ?? "tool"
        // `description` is claude's own short summary (e.g. "note.txt"); fall back to
        // a summary of the tool input, then the tool name.
        let summary = (request["description"] as? String)
            ?? Self.summarize(request["input"])
            ?? toolName
        return [.approvalRequested(id: requestID, toolName: toolName, summary: summary)]
    }

    private func parseRateLimit(_ object: [String: Any]) -> [AgentEvent] {
        // Only surface a notice when a limit is actually in effect — `status:"allowed"`
        // is a frequent heartbeat and must not spam the transcript. (Intentional
        // refinement of the raw "rate_limit_event → notice" mapping.)
        guard let info = object["rate_limit_info"] as? [String: Any],
              let status = info["status"] as? String,
              status.lowercased() != "allowed"
        else { return [] }
        let kind = (info["rateLimitType"] as? String) ?? "rate"
        return [.providerNotice("Rate limit (\(kind)): \(status).")]
    }

    // MARK: - Helpers

    /// Claude reports terminal disposition across both `subtype` and `is_error`.
    /// Treat contradictory or future error subtypes as failures rather than
    /// accidentally upgrading them to success.
    static func parseOutcome(_ result: [String: Any]) -> AgentTurnOutcome {
        let subtype = (result["subtype"] as? String)?.lowercased()
        if subtype == "interrupted" || subtype == "cancelled" || subtype == "canceled" {
            return .interrupted
        }
        if result["is_error"] as? Bool == true { return .failed }
        if subtype == "success" { return .succeeded }
        if subtype?.hasPrefix("error") == true { return .failed }
        return result["is_error"] as? Bool == false ? .succeeded : .failed
    }

    /// Parse `result.usage` + top-level `total_cost_usd` into `AgentUsage`, or `nil`
    /// when nothing usable is present.
    static func parseUsage(_ result: [String: Any]) -> AgentUsage? {
        let usage = result["usage"] as? [String: Any] ?? [:]
        let out = AgentUsage(
            inputTokens: usage["input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int,
            cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int,
            // `as? Double` already bridges every JSON NSNumber (int or float).
            totalCostUSD: result["total_cost_usd"] as? Double)
        return out.isEmpty ? nil : out
    }

    /// Longest tool-input detail shown on a chip / approval summary before eliding.
    static let maxSummaryLength = 140

    /// A short, human-readable detail for a tool-use chip / approval summary, picking
    /// the most descriptive field of the tool input. Truncated to keep chips compact.
    static func summarize(_ input: Any?) -> String? {
        guard let dict = input as? [String: Any] else { return nil }
        let priority = ["file_path", "command", "path", "url", "pattern", "query", "description"]
        for key in priority {
            if let value = dict[key] as? String, !value.isEmpty {
                return value.count > maxSummaryLength
                    ? String(value.prefix(maxSummaryLength - 1)) + "…" : value
            }
        }
        return nil
    }
}

// MARK: - Control protocol codec (stdin side)
//
// The control protocol rides the same streams the runtime already reads/writes: the
// prompt + approval answers are stream-json objects written to **stdin**, while
// `can_use_tool` requests arrive on stdout. These pure encode/decode helpers are the
// stdin-side counterpart to the parser and are unit-tested directly.

enum ClaudeControlProtocol {

    /// The bookkeeping `ClaudeCodeProvider` retains for an in-flight approval so it
    /// can build the matching `control_response` when the user decides. Created,
    /// stored, and consumed entirely inside the `ClaudeTurnEngine` actor — never
    /// crosses an isolation boundary — so the raw `[String: Any]` input needs no
    /// `Sendable`/`Equatable` wrapper.
    struct PendingApproval {
        let requestID: String
        let toolUseID: String
        let toolName: String
        /// The original tool input, echoed back verbatim as `updatedInput` on allow.
        let input: [String: Any]
    }

    /// The opening `initialize` control_request (sent before the first user message).
    static func initializeRequest(requestID: String) -> String {
        encode([
            "type": "control_request",
            "request_id": requestID,
            "request": ["subtype": "initialize"],
        ])
    }

    /// A stream-json `user` message carrying the prompt (delivered on stdin, §4.2).
    static func userMessage(prompt: String, images: [ClaudeImageInput] = []) -> String {
        let imageBlocks: [[String: Any]] = images.map { image in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.base64Data,
                ],
            ]
        }
        return encode([
            "type": "user",
            "session_id": "",
            "message": [
                "role": "user",
                "content": imageBlocks + [["type": "text", "text": prompt]],
            ],
            "parent_tool_use_id": NSNull(),
        ])
    }

    /// Decode a stdout `control_request`/`can_use_tool` line into the bookkeeping the
    /// provider needs. Returns `nil` for any other line (tolerant).
    static func decodeCanUseTool(line rawLine: String) -> PendingApproval? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "control_request",
              let request = object["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool"
        else { return nil }
        let requestID = (object["request_id"] as? String) ?? ""
        let toolUseID = (request["tool_use_id"] as? String) ?? ""
        let toolName = (request["tool_name"] as? String) ?? "tool"
        let input = (request["input"] as? [String: Any]) ?? [:]
        return PendingApproval(
            requestID: requestID, toolUseID: toolUseID, toolName: toolName, input: input)
    }

    /// Build the `control_response` answering an approval, per the verified shape.
    /// On allow, `updatedInput` echoes the original input; on deny we `interrupt`.
    static func controlResponse(for pending: PendingApproval, decision: ApprovalDecision) -> String {
        var inner: [String: Any] = [
            "behavior": decision.behavior,
            "toolUseID": pending.toolUseID,
        ]
        if decision.isAllow {
            inner["updatedInput"] = pending.input
        } else {
            inner["message"] = "Denied by user."
            inner["interrupt"] = true
        }
        return encode([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": pending.requestID,
                "response": inner,
            ],
        ])
    }

    // MARK: Encoding

    /// Encode a JSON object to a single compact line. Falls back to `{}` on the
    /// (impossible for these inputs) serialization failure rather than throwing.
    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
