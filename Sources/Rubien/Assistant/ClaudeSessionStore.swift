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
    /// `[]` when the folder has no session directory yet. A non-nil `referenceID`
    /// keeps only sessions attributed to that reference (see `sessionReferences`) —
    /// the History popover's "This document" scope. Does blocking file I/O —
    /// call off the main actor.
    func recentSessions(workspaceURL: URL, limit: Int, referenceID: Int64? = nil) -> [AgentSessionSummary] {
        guard limit > 0 else { return [] }
        var summaries: [AgentSessionSummary] = []
        for url in sessionFilesNewestFirst(for: workspaceURL) {
            if summaries.count >= limit { break }
            if Task.isCancelled { break }
            if let referenceID, !sessionReferences(fileURL: url, referenceID: referenceID) { continue }
            if let summary = summarize(fileURL: url, expectedCWD: workspaceURL.path) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// The session directory claude uses for `workspaceURL`.
    private func projectDir(for workspaceURL: URL) -> URL {
        projectsRoot.appendingPathComponent(
            Self.projectDirName(forWorkspacePath: workspaceURL.path), isDirectory: true)
    }

    /// The folder's session files sorted by modification date (prefetched by the
    /// enumeration) BEFORE reading any body — a folder with hundreds of large
    /// sessions must not read every transcript just to list or search a few.
    private func sessionFilesNewestFirst(for workspaceURL: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectDir(for: workspaceURL),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .sorted { Self.modificationDate(of: $0) > Self.modificationDate(of: $1) }
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
        let managedRoot = AssistantAttachmentStore.managedRootURL(
            for: URL(fileURLWithPath: expectedCWD, isDirectory: true)
        )

        var preview: String?
        var cwdMatches = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: true).prefix(maxLinesScanned) {
            guard let obj = Self.parseLine(line) else { continue }
            if (obj["cwd"] as? String) == expectedCWD { cwdMatches = true }
            if preview == nil,
               obj["type"] as? String == "user",
               obj["isMeta"] as? Bool != true,  // skip Claude's internal/meta entries (command caveats etc.)
               obj["isSidechain"] as? Bool != true,  // and subagent-internal rows
               let text = Self.firstUserText(
                   obj, managedRoot: managedRoot, fileManager: fileManager
               ) {
                preview = text
            }
            if preview != nil, cwdMatches { break }
        }
        guard let preview, cwdMatches else { return nil }
        return AgentSessionSummary(id: sessionID, preview: preview, date: date)
    }

    /// Rebuild a picked session's renderable transcript from its JSONL so a resume
    /// restores the conversation's content, not just a notice. Mirrors the live
    /// event mapping: user text → user rows, assistant text → assistant rows,
    /// an assistant message's `tool_use` blocks → completed tool-chip rows right
    /// after its text (their results arrived later, but the chips belong to the
    /// message that invoked them). Meta/sidechain entries and tool-result-only
    /// user turns render nothing, exactly as they do live. Returns `[]` when the
    /// file is missing/unreadable — the caller falls back to the preview notice.
    /// Known fidelity limit: a tool the user DENIED restores as a completed chip
    /// (denials live in stream-only `permission_denials`, not the session file's
    /// message entries) — accepted for now; denials are rare in history.
    func fullTranscript(sessionID: String, workspaceURL: URL) -> [ChatRenderMessage] {
        let fileURL = projectDir(for: workspaceURL).appendingPathComponent("\(sessionID).jsonl")
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let managedRoot = AssistantAttachmentStore.managedRootURL(for: workspaceURL)

        var rows: [ChatRenderMessage] = []
        func append(
            _ role: ChatRole,
            _ body: String,
            attachments: [ChatAttachmentPresentation] = []
        ) {
            rows.append(ChatRenderMessage(
                role: role, body: body, seq: rows.count, attachments: attachments
            ))
        }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = Self.parseLine(line),
                  let entry = Self.conversationEntry(obj)
            else { continue }
            switch entry.type {
            case "user":
                if let text = Self.messageText(entry.message) {
                    let parsed = AssistantAttachmentManifest.parse(
                        text, managedRoot: managedRoot, fileManager: fileManager
                    )
                    if !parsed.visibleText.isEmpty || !parsed.attachments.isEmpty {
                        append(.user, parsed.visibleText, attachments: parsed.attachments)
                    }
                }
            case "assistant":
                if let text = Self.messageText(entry.message), !text.isEmpty {
                    append(.assistant, text)
                }
                for block in (entry.message["content"] as? [[String: Any]]) ?? []
                where block["type"] as? String == "tool_use" {
                    guard let name = block["name"] as? String else { continue }
                    let chip = ToolChipPayload(
                        name: name,
                        detail: ClaudeStreamParser.summarize(block["input"]),
                        status: .completed)
                    append(.tool, ChatTranscriptJS.encodeArg(chip))
                }
            default:
                break
            }
        }
        return rows
    }

    /// One parsed JSONL line that belongs to the VISIBLE conversation — a user or
    /// assistant message that is neither meta nor sidechain (subagent internals).
    /// The single gate `fullTranscript` (rendering) and the content search
    /// (matching) both go through, so "search matches what a resume renders"
    /// holds by construction.
    private static func conversationEntry(_ obj: [String: Any]) -> (type: String, message: [String: Any])? {
        guard obj["isMeta"] as? Bool != true,
              obj["isSidechain"] as? Bool != true,
              let type = obj["type"] as? String, type == "user" || type == "assistant",
              let message = obj["message"] as? [String: Any]
        else { return nil }
        return (type, message)
    }

    /// Content search over the folder's sessions: matches the VISIBLE conversation
    /// text (user + assistant messages, the same rows `fullTranscript` renders —
    /// never tool payloads, meta, or sidechain internals), case- and
    /// diacritic-insensitively. Newest first, capped at `limit`; each hit carries
    /// a `matchSnippet` around its first match. A linear scan of every session
    /// file — fine at the store's scale (tens of files, ~100 KB each); revisit
    /// with an index only if folders grow orders of magnitude beyond that.
    func searchSessions(
        query: String, workspaceURL: URL, limit: Int, referenceID: Int64? = nil
    ) -> [AgentSessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        var hits: [AgentSessionSummary] = []
        let managedRoot = AssistantAttachmentStore.managedRootURL(for: workspaceURL)
        for url in sessionFilesNewestFirst(for: workspaceURL) {
            if hits.count >= limit { break }
            // A superseded search (the user kept typing) is cancelled by the
            // provider — stop at the file boundary instead of scanning on.
            if Task.isCancelled { return hits }
            // Snippet first: most files won't match, and the reference scan +
            // `summarize` (further reads) then run only for actual text hits.
            guard let snippet = firstMatchSnippet(
                fileURL: url, query: trimmed, managedRoot: managedRoot
            ) else { continue }
            if let referenceID, !sessionReferences(fileURL: url, referenceID: referenceID) { continue }
            guard var hit = summarize(fileURL: url, expectedCWD: workspaceURL.path) else { continue }
            hit.matchSnippet = snippet
            hits.append(hit)
        }
        return hits
    }

    /// Whether the session contains a rubien MCP tool call addressing `referenceID`
    /// — the "This document" scope's attribution. The seed is NOT in the JSONL
    /// (claude does not persist `--append-system-prompt`), but the seeded agent
    /// reads the document through the rubien tools, so their `tool_use` arguments
    /// carry the reference (which keys, per tool, is `ReferenceAttribution`'s ONE
    /// shared policy — the codex scanner rides the same one). Only `tool_use`
    /// blocks count — never tool RESULTS or prose, which can mention OTHER
    /// references' ids (e.g. a `rubien_search` result listing the whole library).
    func sessionReferences(fileURL: URL, referenceID: Int64) -> Bool {
        let prefix = ReferenceAttribution.claudeToolPrefix
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.utf8.count <= maxSearchedLineBytes else { continue }
            guard let obj = Self.parseLine(line),
                  let entry = Self.conversationEntry(obj),
                  entry.type == "assistant"
            else { continue }
            for block in (entry.message["content"] as? [[String: Any]]) ?? []
            where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, name.hasPrefix(prefix),
                      let input = block["input"] as? [String: Any]
                else { continue }
                if ReferenceAttribution.referencedIDs(
                    tool: String(name.dropFirst(prefix.count)), arguments: input
                ).contains(referenceID) {
                    return true
                }
            }
        }
        return false
    }

    /// Lines longer than this are skipped by the search scan — no legitimate
    /// conversation text is megabytes on one line, but a pathological entry
    /// (huge pasted blob) would otherwise pay full JSON-decode cost per query.
    private let maxSearchedLineBytes = 1_000_000

    /// How search matching compares text — shared with the History rows' snippet
    /// highlighting (`HistoryRow`), which re-finds the query to bold it; the two
    /// drifting apart would silently kill or misplace the bolding.
    static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Scan one session file for `query` in its visible text; a snippet around the
    /// first match, or nil when the session doesn't match.
    private func firstMatchSnippet(fileURL: URL, query: String, managedRoot: URL) -> String? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.utf8.count <= maxSearchedLineBytes else { continue }
            guard let obj = Self.parseLine(line),
                  let entry = Self.conversationEntry(obj),
                  let rawText = Self.messageText(entry.message)
            else { continue }
            let text: String
            if entry.type == "user" {
                let parsed = AssistantAttachmentManifest.parse(
                    rawText, managedRoot: managedRoot, fileManager: fileManager
                )
                text = AssistantAttachmentPolicy.historyText(
                    visibleText: parsed.visibleText,
                    attachments: parsed.attachments
                )
            } else {
                text = rawText
            }
            if let snippet = Self.snippet(around: query, in: text) {
                return snippet
            }
        }
        return nil
    }

    /// A whitespace-collapsed window around the first `matchOptions` occurrence
    /// of `query` in `text`, with "…" marking clipped edges.
    static func snippet(around query: String, in text: String, context: Int = 40) -> String? {
        let collapsed = collapseWhitespace(text)
        guard let range = collapsed.range(of: query, options: matchOptions) else { return nil }
        let start = collapsed.index(range.lowerBound, offsetBy: -context, limitedBy: collapsed.startIndex)
            ?? collapsed.startIndex
        let end = collapsed.index(range.upperBound, offsetBy: context, limitedBy: collapsed.endIndex)
            ?? collapsed.endIndex
        let clipped = String(collapsed[start..<end])
        return (start > collapsed.startIndex ? "…" : "")
            + clipped
            + (end < collapsed.endIndex ? "…" : "")
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

    /// Extract the visible text of a `type:"user"` entry, collapsed and truncated
    /// for a one-glance preview. Tool-result-only turns produce no text → nil.
    private static func firstUserText(
        _ obj: [String: Any],
        managedRoot: URL,
        fileManager: FileManager
    ) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let raw = messageText(message) else { return nil }
        let parsed = AssistantAttachmentManifest.parse(
            raw, managedRoot: managedRoot, fileManager: fileManager
        )
        let collapsed = collapseWhitespace(AssistantAttachmentPolicy.historyText(
            visibleText: parsed.visibleText,
            attachments: parsed.attachments
        ))
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 140 ? String(collapsed.prefix(140)) + "…" : collapsed
    }

    /// Runs of any whitespace (incl. newlines) become single spaces — the
    /// one-line form previews and snippets render.
    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A message's full visible text: `content` is either a plain string or an
    /// array of typed blocks (join the `text` blocks; tool_use/tool_result blocks
    /// carry no visible text). nil when there's no textual content at all.
    private static func messageText(_ message: [String: Any]) -> String? {
        if let string = message["content"] as? String { return string }
        if let blocks = message["content"] as? [[String: Any]] {
            let joined = blocks
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
