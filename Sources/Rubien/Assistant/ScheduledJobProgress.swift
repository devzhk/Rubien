#if os(macOS)
import Foundation
import RubienCore

/// Bounded, app-lifetime progress for the scheduled run currently owned by this
/// process. It is intentionally not persisted: the provider transcript remains
/// the durable completed result, while this snapshot lets the UI inspect a run
/// without resuming or otherwise interfering with its live provider session.
struct ScheduledJobProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case running
        case succeeded
        case failed
        case cancelled
    }

    struct Entry: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case assistant(isStreaming: Bool)
            case tool(name: String, status: ToolChipStatus)
            case notice
            case papers(count: Int)
        }

        let id: UUID
        var kind: Kind
        var detail: String
    }

    let runID: String
    let prompt: String?
    private(set) var phase: Phase
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var entries: [Entry] = []
    private(set) var revision = 0

    private var streamingAssistantEntryID: UUID?
    private var totalEntryCharacters = 0
    private static let maximumEntries = 120
    private static let maximumEntryCharacters = 32_000
    private static let maximumTotalCharacters = 128_000

    init(run: ScheduledJobRun, prompt: String? = nil) {
        runID = run.id
        self.prompt = prompt
        phase = switch run.status {
        case .pending, .unknown: .preparing
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
        sessionID = run.providerSessionId
    }

    mutating func markStarted() {
        phase = .running
        revision += 1
    }

    mutating func record(_ event: AgentEvent) {
        switch event {
        case .sessionStarted(let sessionID):
            self.sessionID = sessionID
        case .modelResolved(let model):
            self.model = model
        case .assistantDelta(let text):
            guard appendAssistantDelta(text) else { return }
        case .assistantMessageCompleted(let text):
            commitAssistantMessage(text)
        case .toolUseStarted(let name, let detail):
            append(Entry(
                id: UUID(),
                kind: .tool(name: name, status: .started),
                detail: detail ?? ""
            ))
        case .toolUseCompleted(let name):
            completeTool(named: name, status: .completed, detail: nil)
        case .paperPresentation(_, _, let group):
            let titles = group.items.map(\.title).joined(separator: "\n")
            append(Entry(
                id: UUID(),
                kind: .papers(count: group.items.count),
                detail: titles
            ))
        case .approvalRequested(_, let toolName, let summary):
            append(Entry(
                id: UUID(),
                kind: .tool(name: toolName, status: .denied),
                detail: summary
            ))
        case .toolDenied(let name, let reason):
            completeTool(named: name, status: .denied, detail: reason)
        case .turnCompleted(let completion):
            phase = switch completion.outcome {
            case .succeeded: .succeeded
            case .failed, .interrupted: .failed
            }
        case .providerNotice(let text):
            append(Entry(id: UUID(), kind: .notice, detail: text))
        }
        revision += 1
    }

    mutating func finish(with run: ScheduledJobRun) {
        phase = switch run.status {
        case .pending, .unknown: .preparing
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
        sessionID = run.providerSessionId ?? sessionID
        revision += 1
    }

    @discardableResult
    private mutating func appendAssistantDelta(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if let id = streamingAssistantEntryID,
           let index = entries.firstIndex(where: { $0.id == id }) {
            // Once the visible prefix is saturated, later provider tokens cannot
            // change this bounded snapshot. Avoid repeatedly copying/counting the
            // same 32K string or publishing no-op revisions.
            if entries[index].detail.count > Self.maximumEntryCharacters {
                return false
            }
            let oldCount = entries[index].detail.count
            entries[index].detail.append(contentsOf: text)
            if entries[index].detail.count > Self.maximumEntryCharacters {
                entries[index].detail = bounded(entries[index].detail)
            }
            totalEntryCharacters += entries[index].detail.count - oldCount
            enforceBounds()
            return true
        }
        let entry = Entry(
            id: UUID(),
            kind: .assistant(isStreaming: true),
            detail: bounded(text)
        )
        streamingAssistantEntryID = entry.id
        append(entry)
        return true
    }

    private mutating func commitAssistantMessage(_ text: String) {
        if let id = streamingAssistantEntryID,
           let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].kind = .assistant(isStreaming: false)
            replaceDetail(at: index, with: text)
        } else {
            append(Entry(
                id: UUID(),
                kind: .assistant(isStreaming: false),
                detail: bounded(text)
            ))
        }
        streamingAssistantEntryID = nil
        enforceBounds()
    }

    private mutating func completeTool(
        named name: String,
        status: ToolChipStatus,
        detail: String?
    ) {
        if let index = entries.lastIndex(where: {
            guard case .tool(let entryName, .started) = $0.kind else { return false }
            return entryName == name
        }) {
            entries[index].kind = .tool(name: name, status: status)
            if let detail { replaceDetail(at: index, with: detail) }
            enforceBounds()
        } else {
            append(Entry(
                id: UUID(),
                kind: .tool(name: name, status: status),
                detail: detail ?? ""
            ))
        }
    }

    private mutating func append(_ entry: Entry) {
        var entry = entry
        entry.detail = bounded(entry.detail)
        entries.append(entry)
        totalEntryCharacters += entry.detail.count
        enforceBounds()
    }

    private mutating func replaceDetail(at index: Int, with detail: String) {
        totalEntryCharacters -= entries[index].detail.count
        entries[index].detail = bounded(detail)
        totalEntryCharacters += entries[index].detail.count
    }

    /// Keep app-lifetime snapshots small regardless of event kind. Tool details,
    /// notices, and paper titles are provider-controlled too, so limiting only
    /// assistant text would not provide a real per-run memory bound.
    private mutating func enforceBounds() {
        while entries.count > Self.maximumEntries
                || totalEntryCharacters > Self.maximumTotalCharacters {
            guard entries.count > 1 else {
                replaceDetail(
                    at: 0,
                    with: String(entries[0].detail.prefix(Self.maximumTotalCharacters))
                )
                return
            }
            let removed = entries.removeFirst()
            totalEntryCharacters -= removed.detail.count
            if removed.id == streamingAssistantEntryID {
                streamingAssistantEntryID = nil
            }
        }
    }

    private func bounded(_ text: String) -> String {
        guard text.count > Self.maximumEntryCharacters else { return text }
        return String(text.prefix(Self.maximumEntryCharacters)) + "…"
    }
}
#endif
