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
    private(set) var phase: Phase
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var entries: [Entry] = []
    private(set) var revision = 0

    private var streamingAssistantEntryID: UUID?
    private static let maximumEntries = 120
    private static let maximumEntryCharacters = 64_000

    init(run: ScheduledJobRun) {
        runID = run.id
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
            appendAssistantDelta(text)
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

    private mutating func appendAssistantDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if let id = streamingAssistantEntryID,
           let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].detail.append(contentsOf: text)
            if entries[index].detail.count > Self.maximumEntryCharacters {
                entries[index].detail = bounded(entries[index].detail)
            }
            return
        }
        let entry = Entry(
            id: UUID(),
            kind: .assistant(isStreaming: true),
            detail: bounded(text)
        )
        streamingAssistantEntryID = entry.id
        append(entry)
    }

    private mutating func commitAssistantMessage(_ text: String) {
        if let id = streamingAssistantEntryID,
           let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].kind = .assistant(isStreaming: false)
            entries[index].detail = bounded(text)
        } else {
            append(Entry(
                id: UUID(),
                kind: .assistant(isStreaming: false),
                detail: bounded(text)
            ))
        }
        streamingAssistantEntryID = nil
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
            if let detail { entries[index].detail = detail }
        } else {
            append(Entry(
                id: UUID(),
                kind: .tool(name: name, status: status),
                detail: detail ?? ""
            ))
        }
    }

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
        guard entries.count > Self.maximumEntries else { return }
        let overflow = entries.count - Self.maximumEntries
        let removed = entries.prefix(overflow)
        if let streamingAssistantEntryID,
           removed.contains(where: { $0.id == streamingAssistantEntryID }) {
            self.streamingAssistantEntryID = nil
        }
        entries.removeFirst(overflow)
    }

    private func bounded(_ text: String) -> String {
        guard text.count > Self.maximumEntryCharacters else { return text }
        return String(text.prefix(Self.maximumEntryCharacters)) + "…"
    }
}
#endif
