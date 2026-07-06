import Foundation

// MARK: - Claude session store reader (Phase 2c-6)
//
// A light, read-only view of Claude Code's OWN session store so the History picker
// can `--resume` a past conversation (§5.3). Rubien persists no transcripts (D5);
// this reads the runtime's files and writes/deletes nothing.
//
// Layout (verified against claude 2.1.201): sessions live at
//   ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
// where <encoded-cwd> is the working folder's absolute path with every
// non-ASCII-alphanumeric character replaced by '-' (so
// "/Users/me/Documents/Rubien Assistant" → "-Users-me-Documents-Rubien-Assistant").
// Each file is newline-delimited JSON; the first `type:"user"` line with text is the
// conversation's opening prompt, and carries the real `cwd` (used to verify we found
// the right folder). The file's modification date is the last-activity time.

struct ClaudeSessionStore {
    /// `~/.claude/projects` by default; injectable for tests.
    let projectsRoot: URL
    let fileManager: FileManager
    /// Cap on lines scanned per file when hunting the first user message — it sits
    /// near the top, so this bounds work on a very long transcript.
    private let maxLinesScanned = 400

    init(projectsRoot: URL? = nil, fileManager: FileManager = .default) {
        self.projectsRoot = projectsRoot
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Claude's cwd → project-directory-name encoding: every character that isn't an
    /// ASCII letter or digit becomes '-'.
    static func projectDirName(forWorkspacePath path: String) -> String {
        String(path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    /// Recent sessions for `workspaceURL`, newest first, capped at `limit`. Returns
    /// `[]` when the folder has no session directory yet. Does blocking file I/O —
    /// call off the main actor.
    func recentSessions(workspaceURL: URL, limit: Int) -> [AgentSessionSummary] {
        guard limit > 0 else { return [] }
        let dir = projectsRoot.appendingPathComponent(
            Self.projectDirName(forWorkspacePath: workspaceURL.path), isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Sort by modification date (cached by the enumeration above) BEFORE reading
        // any file, then read only the newest ~`limit` — a folder with hundreds of
        // large sessions must not read every transcript just to show 25.
        let newestFirst = entries
            .filter { $0.pathExtension == "jsonl" }
            .sorted { Self.modificationDate(of: $0) > Self.modificationDate(of: $1) }
        var summaries: [AgentSessionSummary] = []
        for url in newestFirst {
            if summaries.count >= limit { break }
            if let summary = summarize(fileURL: url, expectedCWD: workspaceURL.path) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// Build a summary for one session file: session id (filename stem), first user
    /// message preview, and modification date. Returns nil if no user text is found
    /// or the recorded cwd doesn't match `expectedCWD` (a defensive guard against an
    /// encoding collision landing us in the wrong folder).
    func summarize(fileURL: URL, expectedCWD: String) -> AgentSessionSummary? {
        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        guard !sessionID.isEmpty else { return nil }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        guard let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }

        var preview: String?
        var cwdMatches = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: true).prefix(maxLinesScanned) {
            guard let obj = Self.parseLine(line) else { continue }
            if (obj["cwd"] as? String) == expectedCWD { cwdMatches = true }
            if preview == nil,
               obj["type"] as? String == "user",
               obj["isMeta"] as? Bool != true,  // skip Claude's internal/meta entries (command caveats etc.)
               let text = Self.firstUserText(obj) {
                preview = text
            }
            if preview != nil, cwdMatches { break }
        }
        guard let preview, cwdMatches else { return nil }
        return AgentSessionSummary(id: sessionID, preview: preview, date: date)
    }

    /// The file's modification date (cached by `contentsOfDirectory`'s prefetch),
    /// `.distantPast` if unreadable — used to rank newest-first before reading bodies.
    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func parseLine(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Extract the visible text of a `type:"user"` entry. `message.content` is either
    /// a plain string or an array of typed blocks; join the `text` blocks and skip
    /// tool-result-only turns (which produce no text). Collapses whitespace and
    /// truncates for a one-glance preview.
    private static func firstUserText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        let raw: String
        if let string = message["content"] as? String {
            raw = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            raw = blocks
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        } else {
            return nil
        }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 140 ? String(collapsed.prefix(140)) + "…" : collapsed
    }
}
