import XCTest
@testable import Rubien

final class ClaudeSessionStoreTests: XCTestCase {

    // MARK: cwd → project-dir-name encoding

    func testProjectDirNameReplacesNonAlphanumericsWithDash() {
        XCTAssertEqual(
            ClaudeSessionStore.projectDirName(forWorkspacePath: "/Users/me/Documents/Rubien Assistant"),
            "-Users-me-Documents-Rubien-Assistant",
            "slashes AND the space collapse to dashes")
        XCTAssertEqual(
            ClaudeSessionStore.projectDirName(forWorkspacePath: "/Users/me/CodeHub/Rubien"),
            "-Users-me-CodeHub-Rubien")
        // A dot is non-alphanumeric too.
        XCTAssertEqual(
            ClaudeSessionStore.projectDirName(forWorkspacePath: "/a/.config"),
            "-a--config")
    }

    // MARK: recentSessions

    private func makeStore() throws -> (store: ClaudeSessionStore, root: URL, workspace: URL, dir: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-store-\(UUID().uuidString)", isDirectory: true)
        let workspace = URL(fileURLWithPath: "/Users/test/Documents/Rubien Assistant", isDirectory: true)
        let dir = root.appendingPathComponent(
            ClaudeSessionStore.projectDirName(forWorkspacePath: workspace.path), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ClaudeSessionStore(projectsRoot: root), root, workspace, dir)
    }

    /// Write a `<id>.jsonl` with the given raw lines and set its modification date.
    @discardableResult
    private func writeSession(_ id: String, lines: [String], mtime: Date, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func userLine(cwd: String, content: String) -> String {
        #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":"\#(content)"}}"#
    }

    func testRecentSessionsReturnsNewestFirstWithPreviewAndID() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        try writeSession("aaaa1111", lines: [
            #"{"type":"queue-operation","operation":"start"}"#,
            userLine(cwd: cwd, content: "Older conversation"),
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)
        try writeSession("bbbb2222", lines: [
            userLine(cwd: cwd, content: "Newer conversation"),
        ], mtime: Date(timeIntervalSince1970: 2_000), in: dir)

        let sessions = store.recentSessions(workspaceURL: workspace, limit: 25)
        XCTAssertEqual(sessions.map(\.id), ["bbbb2222", "aaaa1111"], "newest first")
        XCTAssertEqual(sessions.first?.preview, "Newer conversation")
        XCTAssertEqual(sessions.last?.preview, "Older conversation")
    }

    func testRecentSessionsIgnoresNonJSONLAndRespectsLimit() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        try "not a session".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        for i in 0..<5 {
            try writeSession("s\(i)", lines: [userLine(cwd: cwd, content: "Chat \(i)")],
                             mtime: Date(timeIntervalSince1970: TimeInterval(1_000 + i)), in: dir)
        }
        let limited = store.recentSessions(workspaceURL: workspace, limit: 3)
        XCTAssertEqual(limited.count, 3, "the .txt is ignored and the limit is applied")
        XCTAssertEqual(limited.map(\.id), ["s4", "s3", "s2"])
    }

    func testRecentSessionsExcludesSessionWhoseRecordedCWDMismatches() throws {
        let (store, _, workspace, dir) = try makeStore()
        // A file that landed in this dir but whose cwd is a DIFFERENT folder.
        try writeSession("wrong", lines: [userLine(cwd: "/somewhere/else", content: "Not ours")],
                         mtime: Date(timeIntervalSince1970: 3_000), in: dir)
        try writeSession("right", lines: [userLine(cwd: workspace.path, content: "Ours")],
                         mtime: Date(timeIntervalSince1970: 2_000), in: dir)
        let sessions = store.recentSessions(workspaceURL: workspace, limit: 25)
        XCTAssertEqual(sessions.map(\.id), ["right"], "cwd-mismatched session is filtered out")
    }

    func testRecentSessionsReturnsEmptyForMissingFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-store-\(UUID().uuidString)", isDirectory: true)
        let store = ClaudeSessionStore(projectsRoot: root)
        let sessions = store.recentSessions(
            workspaceURL: URL(fileURLWithPath: "/nope/never", isDirectory: true), limit: 25)
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: summarize — content shapes

    func testSummarizePrefersFirstTextUserMessageSkippingToolResults() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        let url = try writeSession("mix", lines: [
            // A tool-result-only user turn (no text) must be skipped for the preview.
            #"{"type":"user","cwd":"\#(cwd)","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
            // Array-of-blocks text content.
            #"{"type":"user","cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"Real question"}]}}"#,
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)
        let summary = store.summarize(fileURL: url, expectedCWD: cwd)
        XCTAssertEqual(summary?.preview, "Real question")
        XCTAssertEqual(summary?.id, "mix")
    }

    func testSummarizeSkipsMetaEntriesForThePreview() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        let url = try writeSession("meta", lines: [
            // Claude marks command caveats / continuation wrappers isMeta:true — they
            // must not be shown as the conversation's opening prompt.
            #"{"type":"user","isMeta":true,"cwd":"\#(cwd)","message":{"content":"<local-command-caveat>ignore</local-command-caveat>"}}"#,
            userLine(cwd: cwd, content: "The actual question"),
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)
        XCTAssertEqual(store.summarize(fileURL: url, expectedCWD: cwd)?.preview, "The actual question")
    }

    // MARK: fullTranscript (resume restores content)

    func testFullTranscriptRebuildsUserAssistantAndToolRows() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        try writeSession("conv", lines: [
            // Meta entries render nothing.
            #"{"type":"user","isMeta":true,"cwd":"\#(cwd)","message":{"content":"<caveat/>"}}"#,
            userLine(cwd: cwd, content: "What is attention?"),
            // One assistant message: text + a tool call. Live rendering commits the
            // text, then the chip — the restored order must match.
            #"{"type":"assistant","cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"Let me check."},{"type":"tool_use","name":"mcp__rubien__rubien_get","input":{"id":7}}]}}"#,
            // The tool result (a user entry with no text) renders nothing.
            #"{"type":"user","cwd":"\#(cwd)","message":{"content":[{"type":"tool_result","content":"…"}]}}"#,
            #"{"type":"assistant","cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"It is a weighted sum."}]}}"#,
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)

        let rows = store.fullTranscript(sessionID: "conv", workspaceURL: workspace)
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(rows[0].body, "What is attention?")
        XCTAssertEqual(rows[1].body, "Let me check.")
        XCTAssertEqual(rows[3].body, "It is a weighted sum.")
        XCTAssertEqual(rows.map(\.seq), [0, 1, 2, 3], "rows are sequenced in file order")

        let chip = try JSONDecoder().decode(ToolChipPayload.self, from: Data(rows[2].body.utf8))
        XCTAssertEqual(chip.name, "mcp__rubien__rubien_get")
        XCTAssertEqual(chip.status, .completed, "historical tool calls restore as completed chips")
    }

    func testFullTranscriptIsEmptyForAMissingSession() throws {
        let (store, _, workspace, _) = try makeStore()
        XCTAssertTrue(store.fullTranscript(sessionID: "nope", workspaceURL: workspace).isEmpty)
    }

    func testSidechainRowsAreSkippedByTranscriptAndPreview() throws {
        // Subagent (sidechain) entries are the agent's internals, not the
        // conversation — they must not render as rows nor become the preview.
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        let url = try writeSession("side", lines: [
            #"{"type":"user","isSidechain":true,"cwd":"\#(cwd)","message":{"content":"subagent task prompt"}}"#,
            #"{"type":"assistant","isSidechain":true,"cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"subagent answer"}]}}"#,
            userLine(cwd: cwd, content: "The real question"),
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)

        let rows = store.fullTranscript(sessionID: "side", workspaceURL: workspace)
        XCTAssertEqual(rows.map(\.body), ["The real question"])
        XCTAssertEqual(store.summarize(fileURL: url, expectedCWD: cwd)?.preview, "The real question")
    }

    // MARK: searchSessions (content search)

    private func assistantLine(cwd: String, text: String) -> String {
        #"{"type":"assistant","cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func testSearchMatchesAssistantContentNotJustThePreview() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        try writeSession("hit", lines: [
            userLine(cwd: cwd, content: "Summarize this"),
            assistantLine(cwd: cwd, text: "The paper introduces the transformer architecture."),
        ], mtime: Date(timeIntervalSince1970: 2_000), in: dir)
        try writeSession("miss", lines: [
            userLine(cwd: cwd, content: "Unrelated question"),
            assistantLine(cwd: cwd, text: "Nothing relevant here."),
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)

        let hits = store.searchSessions(query: "transformer", workspaceURL: workspace, limit: 25)
        XCTAssertEqual(hits.map(\.id), ["hit"], "matches the ANSWER's content, not just previews")
        XCTAssertEqual(hits.first?.preview, "Summarize this", "the row title stays the conversation's opener")
        XCTAssertEqual(hits.first?.matchSnippet?.contains("transformer"), true)
    }

    func testSearchIsCaseInsensitiveAndSnippetsClipWithEllipses() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        let padding = String(repeating: "lorem ipsum ", count: 20)
        try writeSession("s", lines: [
            userLine(cwd: cwd, content: "Q"),
            assistantLine(cwd: cwd, text: "\(padding)the Transformer core idea\(padding)"),
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)

        let hits = store.searchSessions(query: "TRANSFORMER", workspaceURL: workspace, limit: 25)
        let snippet = try XCTUnwrap(hits.first?.matchSnippet)
        XCTAssertTrue(snippet.localizedCaseInsensitiveContains("transformer"))
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…"),
                      "a mid-text match clips both edges: \(snippet)")
        XCTAssertLessThan(snippet.count, 120, "the snippet is a window, not the message")
    }

    func testSearchIgnoresToolPayloadsMetaAndSidechainText() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        try writeSession("noise", lines: [
            userLine(cwd: cwd, content: "Visible question"),
            // "needle" appears ONLY in non-conversation places:
            #"{"type":"assistant","cwd":"\#(cwd)","message":{"content":[{"type":"tool_use","name":"rubien_search","input":{"query":"needle"}}]}}"#,
            #"{"type":"user","cwd":"\#(cwd)","message":{"content":[{"type":"tool_result","content":"needle"}]}}"#,
            #"{"type":"user","isMeta":true,"cwd":"\#(cwd)","message":{"content":"needle"}}"#,
            #"{"type":"assistant","isSidechain":true,"cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"needle"}]}}"#,
        ], mtime: Date(timeIntervalSince1970: 1_000), in: dir)

        XCTAssertTrue(store.searchSessions(query: "needle", workspaceURL: workspace, limit: 25).isEmpty,
                      "tool payloads / results / meta / sidechain text must not match")
    }

    func testSearchIsNewestFirstAndRespectsLimit() throws {
        let (store, _, workspace, dir) = try makeStore()
        let cwd = workspace.path
        for (i, id) in ["old", "mid", "new"].enumerated() {
            try writeSession(id, lines: [userLine(cwd: cwd, content: "shared topic \(id)")],
                             mtime: Date(timeIntervalSince1970: TimeInterval(1_000 + i)), in: dir)
        }
        let hits = store.searchSessions(query: "shared topic", workspaceURL: workspace, limit: 2)
        XCTAssertEqual(hits.map(\.id), ["new", "mid"])
    }

    func testSearchReturnsNothingForABlankQuery() throws {
        let (store, _, workspace, dir) = try makeStore()
        try writeSession("s", lines: [userLine(cwd: workspace.path, content: "Anything")],
                         mtime: Date(timeIntervalSince1970: 1_000), in: dir)
        XCTAssertTrue(store.searchSessions(query: "", workspaceURL: workspace, limit: 25).isEmpty)
        XCTAssertTrue(store.searchSessions(query: "   ", workspaceURL: workspace, limit: 25).isEmpty)
    }

    func testSummarizeCollapsesWhitespaceAndTruncates() throws {
        let (store, _, workspace, dir) = try makeStore()
        let long = String(repeating: "word ", count: 60)  // > 140 chars
        let url = try writeSession("long", lines: [userLine(cwd: workspace.path, content: long.trimmingCharacters(in: .whitespaces))],
                                   mtime: Date(timeIntervalSince1970: 1_000), in: dir)
        let preview = store.summarize(fileURL: url, expectedCWD: workspace.path)?.preview ?? ""
        XCTAssertTrue(preview.hasSuffix("…"), "an over-long preview is truncated with an ellipsis")
        XCTAssertLessThanOrEqual(preview.count, 141)
        XCTAssertFalse(preview.contains("  "), "runs of whitespace collapse to single spaces")
    }
}
