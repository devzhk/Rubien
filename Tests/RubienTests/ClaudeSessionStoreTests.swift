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
