import Foundation

enum CodexUserInput: Sendable, Equatable {
    case text(String)
    case localImage(path: String)
}
#if canImport(CoreFoundation)
import CoreFoundation  // CFGetTypeID/CFBooleanGetTypeID: not re-exported by Foundation on Linux
#endif

// MARK: - Codex app-server protocol codec (verified against codex-cli 0.142.5)
//
// The PURE JSON-RPC 2.0 codec behind `CodexProvider` (Phase 3b) — the Codex sibling
// of `ClaudeStreamParser` + `ClaudeControlProtocol`. Two halves, both side-effect-free
// so fixture tests can drive them:
//
//   • `CodexAppServerParser`  — maps one inbound NOTIFICATION or server-request line to
//     `[AgentEvent]` (the `thread → turn → item` v2 stream, §2.2/§3 of the Phase-3b
//     design). Tolerant: unknown methods / garbage lines yield `[]`, never a throw.
//   • `CodexAppServerProtocol` — encodes the client requests + approval responses, and
//     classifies inbound frames (response vs server-request vs notification) so the
//     connection can route responses by id and answer server-initiated requests.
//
// Unlike Claude (one process per turn), the connection is long-lived and stateful, so
// the codec also carries the id-correlation types the connection needs:
//   • `CodexRPCID`          — a JSON-RPC id preserving its ORIGINAL type (number|string)
//                             so an approval response echoes it VERBATIM (design #1: the
//                             verified approval request used a numeric `id:0`; sending
//                             `"0"` would fail to correlate).
//   • `PendingCodexApproval`— what the connection stores to answer an approval request.

// MARK: - JSON-RPC id (type-preserving)

/// A JSON-RPC message id. Codex uses integers, but the spec allows strings; either way
/// the response MUST echo the id in its original JSON type, so we never collapse it to
/// a String on the wire (only for the UI-facing `AgentEvent.approvalRequested(id:)`).
enum CodexRPCID: Equatable, Hashable {
    case number(Int)
    case string(String)

    /// Decode from a JSONSerialization value (`NSNumber` → number, `String` → string).
    init?(json value: Any?) {
        switch value {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            // Guard against Bool bridging to NSNumber; ids are integers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            // JSON-RPC ids "SHOULD NOT contain fractional parts" — reject a fractional
            // or out-of-Int-range number rather than echo a lossy `intValue`.
            let d = n.doubleValue
            guard d == d.rounded(.towardZero), abs(d) < 9.0e18 else { return nil }
            self = .number(n.intValue)
        default: return nil
        }
    }

    /// The value to write back into a JSON response object (`Int` or `String`).
    var jsonValue: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        }
    }

    /// Stable, TYPE-DISAMBIGUATED string for the UI-facing event id + the connection's
    /// `pendingApprovals` key (never used on the wire — the response echoes `jsonValue`).
    /// The `s:` tag keeps `.number(1)` ("1") and `.string("1")` ("s:1") from colliding
    /// (review #5): a numeric id is bare digits, a string id is always `s:`-prefixed, so
    /// the two spaces can never overlap.
    var uiString: String {
        switch self {
        case .number(let n): return String(n)
        case .string(let s): return "s:" + s
        }
    }
}

// MARK: - Inbound stream parser (notifications + approval requests → events)

struct CodexParsedAgentEvent {
    let providerItemID: String?
    let event: AgentEvent
}

struct CodexAppServerParser {

    /// itemId → chip display name, so an `item/completed` (which may omit the friendly
    /// name) completes the right chip. Bounded by a turn's tool count.
    private var toolNamesByItemID: [String: String] = [:]
    private var presentationOrdinalsByItemID: [String: Int] = [:]
    private var nextPresentationOrdinal = 0

    /// The most recent per-turn usage (`thread/tokenUsage/updated.last` — NOT `.total`,
    /// which is thread-cumulative and would inflate later turns). Attached at
    /// `turn/completed`, then cleared so the next turn starts fresh.
    private var lastUsage: AgentUsage?

    init() {}

    /// Map one inbound line to zero or more events. Never throws; a blank / non-JSON /
    /// unknown line yields `[]`. Convenience decode+map used by the fixture tests.
    mutating func parse(line rawLine: String) -> [AgentEvent] {
        guard let inbound = CodexAppServerProtocol.decodeInbound(line: rawLine) else { return [] }
        return map(inbound)
    }

    /// Map an already-decoded inbound frame to events. The connection decodes each stdout
    /// line ONCE (`decodeInbound`) and calls this, so the high-frequency delta path is
    /// never re-parsed for event mapping (cleanup #5); `parse(line:)` layers decode on top.
    mutating func map(_ inbound: CodexInbound) -> [AgentEvent] {
        mapEnriched(inbound).map(\.event)
    }

    mutating func mapEnriched(_ inbound: CodexInbound) -> [CodexParsedAgentEvent] {
        switch inbound {
        case .response:
            // A response to one of OUR client requests — the connection correlates it.
            return []
        case .serverRequest(let id, let method, let params):
            // Server-initiated APPROVAL requests → a card (the connection answers using
            // the raw `id`). A non-approval server request is the connection's to reply
            // to conservatively (design #6), not an event. A malformed-id approval never
            // reaches here — `decodeInbound` downgrades it to a notification, so it drops
            // below rather than surfacing an unanswerable card (correctness #2).
            guard Self.approvalMethods.contains(method) else { return [] }
            let toolName = Self.approvalToolName(method: method, params: params)
            let summary = (params["reason"] as? String)
                ?? (params["command"] as? String)
                ?? (params["message"] as? String)
                ?? toolName
            return [CodexParsedAgentEvent(
                providerItemID: Self.providerItemID(method: method, params: params),
                event: .approvalRequested(
                    id: id.uiString, toolName: toolName, summary: summary)
            )]
        case .notification(let method, let params):
            let itemID = Self.providerItemID(method: method, params: params)
            return mapNotification(method: method, params: params).map {
                CodexParsedAgentEvent(providerItemID: itemID, event: $0)
            }
        }
    }

    private static func providerItemID(
        method: String,
        params: [String: Any]
    ) -> String? {
        if let itemID = params["itemId"] as? String, !itemID.isEmpty { return itemID }
        if let item = params["item"] as? [String: Any],
           let itemID = item["id"] as? String, !itemID.isEmpty { return itemID }
        // Turn- and thread-level events intentionally have no item identity.
        return nil
    }

    private mutating func mapNotification(method: String, params: [String: Any]) -> [AgentEvent] {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let id = thread["id"] as? String, !id.isEmpty {
                return [.sessionStarted(sessionID: id)]
            }
            return []

        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, !delta.isEmpty {
                return [.assistantDelta(text: delta)]
            }
            return []

        case "item/started":
            return parseItemStarted(params)

        case "item/completed":
            return parseItemCompleted(params)

        case "thread/tokenUsage/updated":
            // Latest per-turn usage wins (not itself an event). Assign unconditionally
            // so an empty/absent `.last` CLEARS a prior value rather than leaving it
            // stale on the next `turn/completed`.
            if let usage = params["tokenUsage"] as? [String: Any] {
                lastUsage = Self.parseUsage(usage["last"] as? [String: Any])
            }
            return []

        case "turn/completed":
            let usage = lastUsage
            lastUsage = nil
            toolNamesByItemID.removeAll(keepingCapacity: true)
            presentationOrdinalsByItemID.removeAll(keepingCapacity: true)
            nextPresentationOrdinal = 0
            let turn = params["turn"] as? [String: Any]
            let outcome = Self.turnOutcome(turn?["status"] as? String)
            var events: [AgentEvent] = []
            if outcome == .failed,
               let error = turn?["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                events.append(.providerNotice(message))
            }
            events.append(.turnCompleted(outcome: outcome, usage: usage))
            return events

        case "error":
            // Transient (`willRetry:true`) errors are heartbeats — don't spam the
            // transcript; only a terminal error surfaces as a notice.
            let willRetry = (params["willRetry"] as? Bool) ?? false
            guard !willRetry,
                  let error = params["error"] as? [String: Any],
                  let message = error["message"] as? String, !message.isEmpty
            else { return [] }
            return [.providerNotice(message)]

        default:
            // turn/started, thread/status, mcpServer/startupStatus, account/rateLimits,
            // serverRequest/resolved, reasoning/plan deltas, and any future method →
            // ignored (the connection uses a few of these for routing, not events).
            return []
        }
    }

    // MARK: Item handling

    /// `turn/completed` is terminal even when its embedded status says the model
    /// failed or was interrupted. Unknown/malformed statuses fail closed.
    static func turnOutcome(_ status: String?) -> AgentTurnOutcome {
        switch status?.lowercased() {
        case "completed": .succeeded
        case "interrupted": .interrupted
        case "failed": .failed
        default: .failed
        }
    }

    private mutating func parseItemStarted(_ params: [String: Any]) -> [AgentEvent] {
        guard let item = params["item"] as? [String: Any] else { return [] }
        guard let name = Self.toolChipName(item) else { return [] }  // non-tool items: no chip
        if let id = item["id"] as? String {
            toolNamesByItemID[id] = name
            if ChatPaperPresentation.isPresentationTool(name) {
                presentationOrdinalsByItemID[id] = nextPresentationOrdinal
                nextPresentationOrdinal += 1
            }
        }
        return [.toolUseStarted(name: name, detail: Self.toolChipDetail(item))]
    }

    private mutating func parseItemCompleted(_ params: [String: Any]) -> [AgentEvent] {
        guard let item = params["item"] as? [String: Any] else { return [] }
        let type = item["type"] as? String

        if type == "agentMessage" {
            let text = (item["text"] as? String) ?? ""
            return text.isEmpty ? [] : [.assistantMessageCompleted(text: text)]
        }

        guard let name = Self.toolChipName(item) else { return [] }
        let recalled = (item["id"] as? String).flatMap { toolNamesByItemID[$0] } ?? name
        // `item/completed` means the item FINISHED: only the explicit failure statuses
        // (via the shared classifier) deny; anything else resolves the chip rather than
        // leaving it spinning. `.started` can't occur here — item/completed is terminal.
        let status = item["status"] as? String
        if Self.toolChipStatus(status) == .denied {
            let reason = (item["aggregatedOutput"] as? String).map(Self.trim) ?? (status ?? "failed").capitalized
            return [.toolDenied(name: recalled, reason: reason)]
        }
        if ChatPaperPresentation.isPresentationTool(recalled),
           let group = ChatPaperPresentation.decodeToolResult(item["result"]) {
            let itemID = (item["id"] as? String) ?? "presentation-\(nextPresentationOrdinal)"
            let ordinal: Int
            if let started = presentationOrdinalsByItemID[itemID] {
                ordinal = started
            } else {
                ordinal = nextPresentationOrdinal
                nextPresentationOrdinal += 1
                presentationOrdinalsByItemID[itemID] = ordinal
            }
            return [
                .paperPresentation(callID: itemID, ordinal: ordinal, group: group),
                .toolUseCompleted(name: recalled),
            ]
        }
        return [.toolUseCompleted(name: recalled)]
    }

    // MARK: Static mapping helpers

    /// Server-initiated request methods that map to an approval card (design §2.4).
    static let approvalMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "mcpServer/elicitation/request",
        "item/tool/requestUserInput",
        // Legacy (v1 protocol) aliases, tolerated.
        "execCommandApproval",
        "applyPatchApproval",
    ]

    /// A short display name for an approval card, derived from the request method.
    static func approvalToolName(method: String, params: [String: Any]) -> String {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval": return "shell"
        case "item/fileChange/requestApproval", "applyPatchApproval": return "apply_patch"
        case "item/permissions/requestApproval": return "permissions"
        case "mcpServer/elicitation/request":
            let server = (params["serverName"] as? String) ?? "mcp"
            if let tool = mcpApprovalToolName(params) { return "\(server)/\(tool)" }
            // Keep an unrecognized Rubien elicitation inside the `rubien/…`
            // namespace. The controller then classifies it as unknown and denies
            // it even in Auto mode instead of inheriting generic auto-approval.
            return "\(server)/unknown"
        case "item/tool/requestUserInput": return "tool input"
        default: return "tool"
        }
    }

    /// Codex 0.144 represents an MCP approval as an elicitation request. The
    /// current wire shape puts the exact tool name in the human message:
    /// `Allow the rubien MCP server to run tool "rubien_create_reference"?`.
    /// Keep parsing narrow and return nil on any future shape we don't recognize;
    /// the caller keeps it under `rubien/unknown` so the controller denies it.
    private static func mcpApprovalToolName(_ params: [String: Any]) -> String? {
        guard let meta = params["_meta"] as? [String: Any],
              meta["codex_approval_kind"] as? String == "mcp_tool_call",
              let message = params["message"] as? String,
              let marker = message.range(of: "run tool \"")
        else { return nil }
        let remainder = message[marker.upperBound...]
        guard let closingQuote = remainder.firstIndex(of: "\"") else { return nil }
        let name = String(remainder[..<closingQuote])
        return name.isEmpty ? nil : name
    }

    /// A tool item's chip display name, or `nil` for a non-tool item (userMessage,
    /// agentMessage, reasoning, plan, …) which produces no chip.
    static func toolChipName(_ item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "commandExecution": return "shell"
        case "fileChange": return "apply_patch"
        case "webSearch": return "web_search"
        case "mcpToolCall":
            let tool = (item["tool"] as? String) ?? "tool"
            if let server = item["server"] as? String, !server.isEmpty { return "\(server)/\(tool)" }
            return tool
        case "dynamicToolCall":
            return (item["tool"] as? String) ?? "tool"
        default:
            return nil
        }
    }

    /// The most descriptive one-line detail for a tool chip. (`tool` is intentionally
    /// omitted — `toolChipName` already surfaces it, so it would just repeat the name.)
    static func toolChipDetail(_ item: [String: Any]) -> String? {
        for key in ["command", "query"] {
            if let value = item[key] as? String, !value.isEmpty { return trim(value) }
        }
        return nil
    }

    /// A tool item's `status` string → chip lifecycle. ONE source of truth shared by
    /// the live `item/completed` path and the History transcript decode, so both agree
    /// on which statuses deny (`failed`/`declined`/`cancelled`) vs. are still running
    /// (`inProgress`/`running`/`queued`, only reachable when History reads a thread
    /// whose turn never finished) vs. completed (anything else, incl. an absent status).
    static func toolChipStatus(_ status: String?) -> ToolChipStatus {
        switch status {
        case "failed", "declined", "cancelled": return .denied
        case "inProgress", "running", "queued": return .started
        default: return .completed
        }
    }

    /// Map a `TokenUsageBreakdown` (the `.last` per-turn slice) to `AgentUsage`, or
    /// `nil` when nothing usable is present.
    static func parseUsage(_ breakdown: [String: Any]?) -> AgentUsage? {
        guard let b = breakdown else { return nil }
        let out = AgentUsage(
            inputTokens: b["inputTokens"] as? Int,
            outputTokens: b["outputTokens"] as? Int,
            cacheReadTokens: b["cachedInputTokens"] as? Int)
        return out.isEmpty ? nil : out
    }

    static let maxDetailLength = 140

    private static func trim(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > maxDetailLength
            ? String(collapsed.prefix(maxDetailLength - 1)) + "…" : collapsed
    }
}

// MARK: - Frame classification + client-side codec

/// A decoded inbound JSON-RPC frame, classified for the connection's router.
enum CodexInbound {
    /// A response to one of OUR client requests (correlate by `id`).
    case response(id: CodexRPCID, result: [String: Any]?, error: [String: Any]?)
    /// A server-initiated request needing a response (correlate by `id`).
    case serverRequest(id: CodexRPCID, method: String, params: [String: Any])
    /// A one-way notification (no id).
    case notification(method: String, params: [String: Any])
}

/// What the connection stores to answer a server-initiated approval request: the raw
/// id (echoed verbatim) plus enough context to route/log the decision.
struct PendingCodexApproval {
    let id: CodexRPCID
    let method: String
    let itemId: String?
    let toolName: String
    /// The string-valued decisions the server said it will accept for THIS request
    /// (object-valued variants like `acceptWithExecpolicyAmendment` are dropped — we
    /// only map the three simple ones). Empty ⇒ the server sent none; use the default.
    let availableDecisions: [String]
}

// MARK: - Model catalog wire types (model/list — model auto-discovery)

/// One reasoning-effort level a model supports, from `supportedReasoningEfforts`.
struct CodexEffortInfo: Sendable, Equatable {
    let value: String
    let label: String
    let description: String?

    /// Display label for an effort slug, matching the static list's style
    /// ("xhigh" → "xHigh"); unknown future tiers just capitalize.
    static func label(for value: String) -> String {
        value == "xhigh" ? "xHigh" : value.capitalized
    }
}

/// One model the installed codex reports via `model/list` (spec §2.1). `isDefault`
/// is cosmetic only — it is rollout-state volatile and does NOT reflect the user's
/// `~/.codex` config (verified: config said terra, isDefault said gpt-5.5).
struct CodexModelInfo: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let description: String?
    let efforts: [CodexEffortInfo]
    let defaultEffort: String?
    let isDefault: Bool
    let hidden: Bool
}

/// A `model/list` fetch outcome. Three provider-level states: `nil` (backend has no
/// discovery — Claude), `fetchedOK == false` (discovery attempted, failed → degraded
/// picker), `fetchedOK == true` (live list).
struct CodexCatalog: Sendable, Equatable {
    var models: [CodexModelInfo]
    var fetchedOK: Bool

    static let unavailable = CodexCatalog(models: [], fetchedOK: false)

    /// The picker-facing list (`hidden` entries dropped).
    var visibleModels: [CodexModelInfo] { models.filter { !$0.hidden } }
}

enum CodexAppServerProtocol {

    /// Classify one inbound line, or `nil` if it isn't a JSON object. A frame with an
    /// `id` AND a `method` is a server request; `id` without `method` is a response;
    /// `method` without `id` is a notification.
    static func decodeInbound(line rawLine: String) -> CodexInbound? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let id = CodexRPCID(json: object["id"])
        let method = object["method"] as? String
        let params = object["params"] as? [String: Any] ?? [:]
        switch (id, method) {
        case let (id?, method?):
            return .serverRequest(id: id, method: method, params: params)
        case let (id?, nil):
            return .response(id: id, result: object["result"] as? [String: Any],
                             error: object["error"] as? [String: Any])
        case let (nil, method?):
            return .notification(method: method, params: params)
        default:
            return nil
        }
    }

    /// Decode a server-initiated APPROVAL request from a raw line into the answering
    /// bookkeeping. A tested convenience over `decodeInbound` + `pendingApproval`; the
    /// live connection decodes once and calls `pendingApproval(id:method:params:)`
    /// directly. Returns `nil` for any other line (tolerant).
    static func decodeApprovalRequest(line rawLine: String) -> PendingCodexApproval? {
        guard case let .serverRequest(id, method, params)? = decodeInbound(line: rawLine),
              CodexAppServerParser.approvalMethods.contains(method)
        else { return nil }
        return pendingApproval(id: id, method: method, params: params)
    }

    /// The approval bookkeeping from an already-classified server request (the
    /// connection's decode-once path).
    static func pendingApproval(
        id: CodexRPCID, method: String, params: [String: Any]
    ) -> PendingCodexApproval {
        PendingCodexApproval(
            id: id, method: method,
            itemId: params["itemId"] as? String,
            toolName: CodexAppServerParser.approvalToolName(method: method, params: params),
            // Only the simple string decisions (the object-valued amendment variants
            // aren't part of our three-button mapping) — drives the deny→cancel fallback.
            availableDecisions: (params["availableDecisions"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }

    // MARK: Client → server encoders

    static func initialize(requestID: Int, clientName: String, version: String) -> String {
        request(id: requestID, method: "initialize", params: [
            "clientInfo": ["name": clientName, "title": "Rubien", "version": version],
            "capabilities": ["experimentalApi": true, "requestAttestation": false],
        ])
    }

    static func initialized() -> String {
        notification(method: "initialized", params: [:])
    }

    /// `approvalsReviewer` MUST be sent explicitly (`"user"`) — unset, codex falls
    /// back to the user's `~/.codex` `approvals_reviewer`, and a value of `auto_review`
    /// makes codex's OWN LLM guardian answer approval requests instead of the client,
    /// so a mutation runs WITHOUT Rubien's approval card (verified against codex 0.142).
    /// `"user"` routes every on-request approval to Rubien; the controller then cards it
    /// (Ask) or auto-accepts (Auto). Valid enum: `user | auto_review | guardian_subagent`.
    static func threadStart(
        requestID: Int, cwd: String, sandbox: String, approvalPolicy: String,
        approvalsReviewer: String = "user", developerInstructions: String?, model: String?
    ) -> String {
        var params: [String: Any] = [
            "cwd": cwd,
            "sandbox": sandbox,
            "approvalPolicy": approvalPolicy,
            "approvalsReviewer": approvalsReviewer,
            "ephemeral": false,
        ]
        if let developerInstructions, !developerInstructions.isEmpty {
            params["developerInstructions"] = developerInstructions
        }
        if let model, !model.isEmpty { params["model"] = model }
        return request(id: requestID, method: "thread/start", params: params)
    }

    static func turnStart(
        requestID: Int,
        threadId: String,
        inputs: [CodexUserInput],
        effort: String?
    ) -> String {
        let input: [[String: Any]] = inputs.map {
            switch $0 {
            case .text(let text):
                return ["type": "text", "text": text, "text_elements": []]
            case .localImage(let path):
                return ["type": "localImage", "path": path]
            }
        }
        var params: [String: Any] = [
            "threadId": threadId,
            "input": input,
        ]
        if let effort, !effort.isEmpty { params["effort"] = effort }
        return request(id: requestID, method: "turn/start", params: params)
    }

    /// Re-assert `approvalsReviewer: "user"` on resume too, so a History-resumed
    /// conversation can't fall back to the `~/.codex` guardian for its mutations (same
    /// safety invariant as `threadStart`; the param is accepted by `thread/resume`).
    static func threadResume(requestID: Int, threadId: String, approvalsReviewer: String = "user") -> String {
        request(id: requestID, method: "thread/resume",
                params: ["threadId": threadId, "approvalsReviewer": approvalsReviewer])
    }

    static func threadRead(requestID: Int, threadId: String) -> String {
        request(id: requestID, method: "thread/read",
                params: ["threadId": threadId, "includeTurns": true])
    }

    static func threadList(requestID: Int, cwd: String, limit: Int) -> String {
        request(id: requestID, method: "thread/list", params: [
            "cwd": cwd, "limit": limit, "sortDirection": "desc",
            "sourceKinds": ["appServer", "cli", "vscode"],
        ])
    }

    /// `cwd` is sent for forward-compat (a future server may honor it) but codex
    /// 0.142 IGNORES it — search is GLOBAL across every workspace — so results are
    /// ALSO filtered by `thread.cwd` client-side in `decodeThreadSearch` (verified via
    /// spike: a bogus cwd returns the same hits). Without the filter, a search in one
    /// workspace would surface (and resume) another's conversations.
    static func threadSearch(requestID: Int, searchTerm: String, limit: Int, cwd: String) -> String {
        request(id: requestID, method: "thread/search", params: [
            "searchTerm": searchTerm, "limit": limit, "cwd": cwd,
            "sourceKinds": ["appServer", "cli", "vscode"],
        ])
    }

    static func turnInterrupt(requestID: Int, threadId: String, turnId: String) -> String {
        request(id: requestID, method: "turn/interrupt",
                params: ["threadId": threadId, "turnId": turnId])
    }

    /// The installed codex's own model catalog (local, fast, not auth-gated —
    /// verified back to codex 0.142.5; spec §2.1). Params are empty by design.
    static func modelList(requestID: Int) -> String {
        request(id: requestID, method: "model/list", params: [:])
    }

    // MARK: - History decoders (thread/list · thread/search · thread/read → 3b-4)

    static let previewLimit = 240
    static let snippetLimit = 200

    /// `thread/list` result → session summaries (server pre-sorts newest-first).
    static func decodeThreadList(_ result: [String: Any]) -> [AgentSessionSummary] {
        let data = result["data"] as? [[String: Any]] ?? []
        return data.compactMap { sessionSummary(fromThread: $0) }
    }

    /// `thread/search` result → summaries with a match snippet. Each `data[]` hit is
    /// `{thread:{…}, snippet}` (the thread wrapped, unlike `thread/list`). Search is
    /// GLOBAL on codex 0.142 (the `cwd` param is ignored), so hits are filtered to
    /// `cwd` here — a provider search must not surface another workspace's conversations.
    static func decodeThreadSearch(_ result: [String: Any], cwd: String) -> [AgentSessionSummary] {
        let data = result["data"] as? [[String: Any]] ?? []
        return data.compactMap { hit in
            guard let thread = hit["thread"] as? [String: Any],
                  thread["cwd"] as? String == cwd
            else { return nil }
            return sessionSummary(fromThread: thread, snippet: hit["snippet"] as? String)
        }
    }

    /// `thread/read {includeTurns:true}` result → renderable rows (read-only preview).
    /// Walks the items in order, mirroring the LIVE event mapping: userMessage →
    /// user row, agentMessage → assistant row, tool items → a completed (or denied)
    /// chip; successful paper calls merge into one bounded paper row at the end
    /// of their turn; reasoning/plan/other items render nothing, as they do live.
    static func decodeThreadTranscript(
        _ result: [String: Any],
        managedAttachmentsRoot: URL? = nil
    ) -> [ChatRenderMessage] {
        var rows: [ChatRenderMessage] = []
        for turn in threadTurns(result) {
            let items = (turn["items"] as? [[String: Any]]) ?? []
            var presentations: [(callID: String, ordinal: Int, group: ChatPaperGroup)] = []
            for (ordinal, item) in items.enumerated() {
                if let group = paperPresentationGroup(item) {
                    let callID = (item["id"] as? String) ?? "history-presentation-\(ordinal)"
                    presentations.append((callID, ordinal, group))
                    continue
                }
                if let row = transcriptRow(
                    item, seq: rows.count, managedAttachmentsRoot: managedAttachmentsRoot
                ) {
                    rows.append(row)
                }
            }
            if let group = ChatPaperPresentation.merge(presentations),
               let body = ChatPaperPresentation.encodeHistoryGroup(group)
            {
                rows.append(ChatRenderMessage(
                    role: .paper, body: body, seq: rows.count))
            }
        }
        return rows
    }

    /// The reference ids addressed by a thread's rubien MCP tool calls, from a
    /// `thread/read {includeTurns:true}` result — the History "This document"
    /// scope's attribution. Codex returns neither `developerInstructions` (the
    /// seed) nor per-thread metadata we could stamp, but the seeded agent reads
    /// the document through the rubien tools, so their `mcpToolCall.arguments`
    /// carry the reference (which keys, per tool, is `ReferenceAttribution`'s ONE
    /// shared policy — the claude scanner rides the same one). Only OUR server's
    /// call items count — never results or prose, which can mention OTHER
    /// references (e.g. a `rubien_search` result listing the library). A failed
    /// call still attributes: the agent was addressing that reference.
    static func threadReferencedIDs(_ result: [String: Any]) -> Set<Int64> {
        var ids: Set<Int64> = []
        for item in threadItems(result) {
            guard item["type"] as? String == "mcpToolCall",
                  item["server"] as? String == ReferenceAttribution.serverName,
                  let tool = item["tool"] as? String,
                  let args = item["arguments"] as? [String: Any]
            else { continue }
            ids.formUnion(ReferenceAttribution.referencedIDs(tool: tool, arguments: args))
        }
        return ids
    }

    /// Every item across a `thread/read` result's turns, in order — the ONE walk
    /// of the wire shape both the transcript decoder and the attribution scan use.
    private static func threadItems(_ result: [String: Any]) -> [[String: Any]] {
        threadTurns(result).flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
    }

    private static func threadTurns(_ result: [String: Any]) -> [[String: Any]] {
        guard let thread = result["thread"] as? [String: Any] else { return [] }
        return thread["turns"] as? [[String: Any]] ?? []
    }

    /// One summary from `thread/list`'s `data[]` or a search hit's `.thread`. `id`
    /// (the `thread/resume` target + picker identity) is required; `updatedAt` /
    /// `recencyAt` / `createdAt` are epoch seconds (newest present wins).
    static func sessionSummary(fromThread thread: [String: Any], snippet: String? = nil) -> AgentSessionSummary? {
        guard let id = thread["id"] as? String, !id.isEmpty else { return nil }
        let epoch = (thread["updatedAt"] as? Int)
            ?? (thread["recencyAt"] as? Int)
            ?? (thread["createdAt"] as? Int) ?? 0
        return AgentSessionSummary(
            id: id,
            preview: collapse(thread["preview"] as? String ?? "", limit: previewLimit),
            date: Date(timeIntervalSince1970: TimeInterval(epoch)),
            matchSnippet: snippet.map { collapse($0, limit: snippetLimit) })
    }

    /// Rebuild the History row from already-sanitized `thread/read` rows. The raw
    /// `thread.preview` / search snippet are intentionally used only for identity
    /// and date above: both can echo Rubien's private attachment manifest. A user
    /// turn with only attachments gets the same path-free fallback as Claude.
    /// Search considers only the visible user/assistant rows and returns nil when
    /// the query matched only server-internal text.
    static func visibleSessionSummary(
        from raw: AgentSessionSummary,
        rows: [ChatRenderMessage],
        matching searchTerm: String? = nil
    ) -> AgentSessionSummary? {
        let visibleRows = rows.compactMap { row -> (role: ChatRole, text: String)? in
            guard row.role == .user || row.role == .assistant else { return nil }
            let body = collapseWhitespace(row.body)
            if row.role == .user, !row.attachments.isEmpty {
                return (
                    .user,
                    AssistantAttachmentPolicy.historyText(
                        visibleText: body,
                        attachments: row.attachments
                    )
                )
            }
            return body.isEmpty ? nil : (row.role, body)
        }
        guard let firstUser = visibleRows.first(where: { $0.role == .user })?.text else {
            return nil
        }

        let matchedSnippet: String?
        if let searchTerm {
            let query = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty,
                  let match = visibleRows.lazy.compactMap({ snippet(around: query, in: $0.text) }).first
            else { return nil }
            matchedSnippet = collapse(match, limit: snippetLimit)
        } else {
            matchedSnippet = nil
        }

        return AgentSessionSummary(
            id: raw.id,
            preview: collapse(firstUser, limit: previewLimit),
            date: raw.date,
            matchSnippet: matchedSnippet
        )
    }

    /// `model/list` result → decoded catalog entries. Tolerant: unknown fields are
    /// ignored, a missing `displayName` falls back to the slug, missing efforts
    /// decode as empty (the UI then offers the universal fallback four), and an
    /// entry without a usable id is dropped.
    static func decodeModelList(_ result: [String: Any]) -> [CodexModelInfo] {
        let data = result["data"] as? [[String: Any]] ?? []
        return data.compactMap { entry in
            let slug = (entry["id"] as? String) ?? (entry["model"] as? String)
            guard let id = slug, !id.isEmpty else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { effort -> CodexEffortInfo? in
                    guard let value = effort["reasoningEffort"] as? String, !value.isEmpty else { return nil }
                    return CodexEffortInfo(
                        value: value,
                        label: CodexEffortInfo.label(for: value),
                        description: effort["description"] as? String)
                }
            let displayName = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CodexModelInfo(
                id: id,
                displayName: displayName ?? id,
                description: entry["description"] as? String,
                efforts: efforts,
                defaultEffort: (entry["defaultReasoningEffort"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isDefault: entry["isDefault"] as? Bool ?? false,
                hidden: entry["hidden"] as? Bool ?? false)
        }
    }

    /// The model a `thread/start` / `thread/resume` response reports as RESOLVED for
    /// the thread — present even when the request omitted `model` (a transient
    /// unseeded turn; codex then applies its own config-chain fallback — spec §2.2).
    /// Optional: older servers may not report it.
    static func resolvedModel(fromThreadResponse result: [String: Any]) -> String? {
        guard let model = result["model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    private static func transcriptRow(
        _ item: [String: Any],
        seq: Int,
        managedAttachmentsRoot: URL?
    ) -> ChatRenderMessage? {
        switch item["type"] as? String {
        case "userMessage":
            let text = joinedText(item["content"])
            guard let managedAttachmentsRoot else {
                return text.isEmpty ? nil : ChatRenderMessage(role: .user, body: text, seq: seq)
            }
            let parsed = AssistantAttachmentManifest.parse(
                text, managedRoot: managedAttachmentsRoot
            )
            guard !parsed.visibleText.isEmpty || !parsed.attachments.isEmpty else { return nil }
            return ChatRenderMessage(
                role: .user,
                body: parsed.visibleText,
                seq: seq,
                attachments: parsed.attachments
            )
        case "agentMessage":
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : ChatRenderMessage(role: .assistant, body: text, seq: seq)
        default:
            // Tool items → a chip; non-tool items (reasoning, plan, …) produce nothing.
            // The status classifier is shared with the live path, so History and a live
            // turn agree on denied (failed/declined/cancelled) vs still-running.
            guard let name = CodexAppServerParser.toolChipName(item) else { return nil }
            let chip = ToolChipPayload(
                name: name,
                detail: CodexAppServerParser.toolChipDetail(item),
                status: CodexAppServerParser.toolChipStatus(item["status"] as? String))
            return ChatRenderMessage(role: .tool, body: ChatTranscriptJS.encodeArg(chip), seq: seq)
        }
    }

    private static func paperPresentationGroup(_ item: [String: Any]) -> ChatPaperGroup? {
        guard let name = CodexAppServerParser.toolChipName(item),
              ChatPaperPresentation.isPresentationTool(name),
              CodexAppServerParser.toolChipStatus(item["status"] as? String) == .completed
        else { return nil }
        return ChatPaperPresentation.decodeToolResult(item["result"])
    }

    /// Join a userMessage `content[]`'s text elements (skips non-text, e.g. images).
    private static func joinedText(_ content: Any?) -> String {
        let blocks = content as? [[String: Any]] ?? []
        let texts = blocks.compactMap { ($0["type"] as? String == "text") ? $0["text"] as? String : nil }
        return texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whitespace-collapse (newlines + runs → single space) + ellipsis-truncate.
    private static func collapse(_ value: String, limit: Int) -> String {
        let collapsed = collapseWhitespace(value)
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A collapsed window around the first case/diacritic-insensitive match. This
    /// mirrors Claude History's visible-text search and keeps UI highlighting in
    /// agreement with provider-side filtering.
    private static func snippet(around query: String, in text: String, context: Int = 40) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let range = text.range(of: query, options: options) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex)
            ?? text.endIndex
        return (start > text.startIndex ? "…" : "")
            + String(text[start..<end])
            + (end < text.endIndex ? "…" : "")
    }

    /// The response answering a server-initiated approval request. `id` is echoed
    /// VERBATIM (design #1) via `CodexRPCID.jsonValue`; `available` is the request's
    /// `availableDecisions` (from `PendingCodexApproval`) so a `deny` maps to `cancel`
    /// when the server didn't offer `decline` (codec review #1).
    static func approvalResponse(
        id: CodexRPCID,
        _ decision: ApprovalDecision,
        method: String? = nil,
        available: [String] = []
    ) -> String {
        if method == "mcpServer/elicitation/request" {
            let action = decision.isAllow ? "accept" : "decline"
            return encode([
                "jsonrpc": "2.0",
                "id": id.jsonValue,
                "result": ["action": action],
            ])
        }
        return encode([
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": ["decision": codexDecision(for: decision, available: available)],
        ])
    }

    /// A conservative response to an UNKNOWN server request so the server never wedges
    /// (design #6): a JSON-RPC "method not found" error carrying the echoed id.
    static func unsupportedRequestResponse(id: CodexRPCID, method: String) -> String {
        encode([
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": ["code": -32601, "message": "Unsupported request: \(method)"],
        ])
    }

    /// `ApprovalDecision` → the codex `CommandExecution`/`FileChangeApprovalDecision`
    /// string (verified enum), honoring the request's `available` decisions: the verified
    /// command-approval offered `["accept", …, "cancel"]` with NO `"decline"`, so a `deny`
    /// falls back to `"cancel"` (codec review #1). Empty `available` ⇒ the plain mapping.
    static func codexDecision(for decision: ApprovalDecision, available: [String] = []) -> String {
        func pick(_ preferred: String, _ fallback: String) -> String {
            if available.isEmpty || available.contains(preferred) { return preferred }
            return available.contains(fallback) ? fallback : preferred
        }
        switch decision {
        case .allowOnce: return pick("accept", "acceptForSession")
        case .allowForConversation: return pick("acceptForSession", "accept")
        case .deny: return pick("decline", "cancel")
        }
    }

    // MARK: Encoding

    private static func request(id: Int, method: String, params: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private static func notification(method: String, params: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Encode a JSON object to a single compact line. Falls back to `{}` on the
    /// (impossible for these inputs) serialization failure rather than throwing.
    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
