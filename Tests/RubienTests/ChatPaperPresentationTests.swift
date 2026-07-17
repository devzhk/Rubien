#if os(macOS)
import XCTest
import RubienCore
@testable import Rubien

@MainActor
final class ChatPaperPresentationTests: XCTestCase {
    func testClaudeSuccessfulPresentationDecodesTypedCards() {
        var parser = ClaudeStreamParser()
        _ = parser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"paper-call","name":"mcp__rubien__rubien_present_document_cards","input":{"items":[{"referenceId":7}]}}]}}"#)
        let events = parser.parse(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"paper-call","is_error":false,"content":"{\"items\":[{\"kind\":\"library\",\"referenceId\":7,\"title\":\"Paper Seven\",\"authors\":\"Ada Lovelace, Grace Hopper\",\"year\":2026,\"badge\":\"PDF\"}]}"}]}}"#)

        XCTAssertEqual(events.count, 2)
        guard case .paperPresentation(let callID, let ordinal, let group) = events[0] else {
            return XCTFail("expected typed presentation before completion")
        }
        XCTAssertEqual(callID, "paper-call")
        XCTAssertEqual(ordinal, 0)
        XCTAssertEqual(group.items.first?.title, "Paper Seven")
        XCTAssertEqual(group.items.first?.authors, "Ada Lovelace, Grace Hopper")
        XCTAssertEqual(group.items.first?.referenceId, 7)
    }

    func testCodexSuccessfulPresentationDecodesTypedCards() {
        var parser = CodexAppServerParser()
        let line = #"{"method":"item/completed","params":{"item":{"type":"mcpToolCall","id":"call-1","server":"rubien","tool":"rubien_present_document_cards","status":"completed","result":{"content":[{"type":"text","text":"{\"items\":[{\"kind\":\"web\",\"url\":\"https://example.com/paper\",\"title\":\"A Web Paper\",\"badge\":\"Web candidate\"}]}"}]}}}}"#
        let events = parser.parse(line: line)

        XCTAssertEqual(events.count, 2)
        guard case .paperPresentation(let callID, let ordinal, let group) = events[0] else {
            return XCTFail("expected typed presentation before completion")
        }
        XCTAssertEqual(callID, "call-1")
        XCTAssertEqual(ordinal, 0)
        XCTAssertEqual(group.items.first?.url, "https://example.com/paper")
    }

    func testPresentationToolIsSilentReadButNotPublicPolicy() {
        XCTAssertTrue(ChatSessionController.isSilentReadTool("rubien/rubien_present_document_cards"))
        XCTAssertFalse(ChatSessionController.isUnknownRubienTool("mcp__rubien__rubien_present_document_cards"))
        XCTAssertNil(RubienMCPToolPolicy.access(for: "rubien_present_document_cards"))
        XCTAssertFalse(ChatPaperPresentation.isPresentationTool("rubien_present_papers"))
        XCTAssertTrue(ChatSessionController.isUnknownRubienTool("rubien_present_papers"))
    }

    func testClaudeHistoryReconstructsPaperRowWithoutToolChip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rubien-paper-history-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = projects.appendingPathComponent(
            ClaudeSessionStore.projectDirName(forWorkspacePath: workspace.path),
            isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            "{\"type\":\"user\",\"cwd\":\"\(workspace.path)\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"recommend\"}]}}",
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"paper-a","name":"mcp__rubien__rubien_present_document_cards","input":{"items":[{"referenceId":7}]}},{"type":"tool_use","id":"paper-b","name":"mcp__rubien__rubien_present_document_cards","input":{"items":[{"url":"https://example.com/web","title":"Web Paper"}]}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"paper-b","is_error":false,"content":"{\"items\":[{\"kind\":\"library\",\"referenceId\":7,\"title\":\"Duplicate Seven\",\"year\":2026,\"badge\":\"PDF\"},{\"kind\":\"web\",\"url\":\"https://example.com/web\",\"title\":\"Web Paper\",\"badge\":\"Web candidate\"}]}"},{"type":"tool_result","tool_use_id":"paper-a","is_error":false,"content":"{\"items\":[{\"kind\":\"library\",\"referenceId\":7,\"title\":\"Paper Seven\",\"year\":2026,\"badge\":\"PDF\"}]}"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Here are the papers."}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(
            to: project.appendingPathComponent("session.jsonl"))

        let rows = ClaudeSessionStore(projectsRoot: projects).fullTranscript(
            sessionID: "session",
            workspaceURL: workspace)
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .paper])
        let group = try XCTUnwrap(rows.last.flatMap {
            ChatPaperPresentation.decodeHistoryGroup($0.body)
        })
        XCTAssertEqual(group.items.map(\.title), ["Paper Seven", "Web Paper"])
    }

    func testCodexHistoryReconstructsPaperRowWithoutToolChip() throws {
        let result: [String: Any] = [
            "thread": [
                "turns": [[
                    "items": [
                        [
                            "type": "mcpToolCall",
                            "id": "paper-a",
                            "server": "rubien",
                            "tool": "rubien_present_document_cards",
                            "status": "completed",
                            "result": [
                                "content": [[
                                    "type": "text",
                                    "text": #"{"items":[{"kind":"library","referenceId":3,"title":"Library Paper","badge":"PDF"}]}"#,
                                ]],
                            ],
                        ],
                        [
                            "type": "mcpToolCall",
                            "id": "paper-b",
                            "server": "rubien",
                            "tool": "rubien_present_document_cards",
                            "status": "completed",
                            "result": [
                                "content": [[
                                    "type": "text",
                                    "text": #"{"items":[{"kind":"library","referenceId":3,"title":"Duplicate","badge":"PDF"},{"kind":"web","url":"https://example.com/paper","title":"Web Paper","badge":"Web candidate"}]}"#,
                                ]],
                            ],
                        ],
                        ["type": "agentMessage", "text": "Here are two papers."],
                    ],
                ]],
            ],
        ]
        let rows = CodexAppServerProtocol.decodeThreadTranscript(result)
        XCTAssertEqual(rows.map(\.role), [.assistant, .paper])
        let group = try XCTUnwrap(rows.last.flatMap {
            ChatPaperPresentation.decodeHistoryGroup($0.body)
        })
        XCTAssertEqual(group.items.map(\.title), ["Library Paper", "Web Paper"])
    }

    func testMalformedSuccessfulPresentationRemainsVisibleInHistory() throws {
        let codex: [String: Any] = [
            "thread": [
                "turns": [[
                    "items": [[
                        "type": "mcpToolCall",
                        "id": "bad-paper",
                        "server": "rubien",
                        "tool": "rubien_present_document_cards",
                        "status": "completed",
                        "result": ["content": [["type": "text", "text": "not json"]]],
                    ]],
                ]],
            ],
        ]
        let codexRows = CodexAppServerProtocol.decodeThreadTranscript(codex)
        XCTAssertEqual(codexRows.map(\.role), [.tool])

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rubien-bad-paper-history-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = projects.appendingPathComponent(
            ClaudeSessionStore.projectDirName(forWorkspacePath: workspace.path),
            isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let claudeLines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"bad-paper","name":"mcp__rubien__rubien_present_document_cards","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bad-paper","is_error":false,"content":"not json"}]}}"#,
        ]
        try Data(claudeLines.joined(separator: "\n").utf8).write(
            to: project.appendingPathComponent("bad.jsonl"))
        let claudeRows = ClaudeSessionStore(projectsRoot: projects).fullTranscript(
            sessionID: "bad", workspaceURL: workspace)
        XCTAssertEqual(claudeRows.map(\.role), [.tool])

        var parser = ClaudeStreamParser()
        _ = parser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"bad-paper","name":"mcp__rubien__rubien_present_document_cards","input":{}}]}}"#)
        let events = parser.parse(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bad-paper","is_error":false,"content":"not json"}]}}"#)
        XCTAssertEqual(events.count, 1)
        guard case .toolUseCompleted(let name) = events[0] else {
            return XCTFail("malformed result must fall back to ordinary completion")
        }
        XCTAssertTrue(ChatPaperPresentation.isPresentationTool(name))
    }
}
#endif
