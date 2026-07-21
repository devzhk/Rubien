#if os(macOS)
import SwiftUI
import RubienCore

/// Projects the app-lifetime scheduled-run event snapshot into the same render
/// model used by Home and reader conversations. Codex/Claude remain the durable
/// transcript owners; this is only the live, read-only presentation while a run
/// is still in progress. A small bounded cache also keeps recent terminal runs
/// inspectable until their durable provider transcript is opened.
enum ScheduledRunTranscript {
    enum IncrementalAction: Equatable {
        case beginAssistant
        case appendAssistantDelta(String)
        case commitAssistant(String)
        case addTool(name: String, detail: String?, status: ToolChipStatus)
        case addNotice(String)
    }

    static func messages(
        run: ScheduledJobRun,
        fallbackPrompt: String,
        progress: ScheduledJobProgress?
    ) -> [ChatRenderMessage] {
        var rows = [ChatRenderMessage(
            role: .user,
            body: progress?.prompt ?? fallbackPrompt,
            seq: 0
        )]

        if let progress {
            for entry in progress.entries {
                let row: ChatRenderMessage
                switch entry.kind {
                case .assistant:
                    row = ChatRenderMessage(
                        role: .assistant,
                        body: entry.detail,
                        seq: rows.count
                    )
                case .tool(let name, let status):
                    row = ChatRenderMessage(
                        role: .tool,
                        body: ChatTranscriptJS.encodeArg(ToolChipPayload(
                            name: name,
                            detail: entry.detail.isEmpty ? nil : entry.detail,
                            status: status
                        )),
                        seq: rows.count
                    )
                case .notice:
                    row = ChatRenderMessage(
                        role: .notice,
                        body: entry.detail,
                        seq: rows.count
                    )
                case .papers(let count):
                    row = ChatRenderMessage(
                        role: .notice,
                        body: paperNotice(count: count, titles: entry.detail),
                        seq: rows.count
                    )
                }
                rows.append(row)
            }
        }

        if rows.count == 1 {
            rows.append(ChatRenderMessage(
                role: .notice,
                body: emptyProgressMessage(for: run),
                seq: rows.count
            ))
        }
        return rows
    }

    /// Translate the common append/streaming mutations into the renderer's
    /// incremental API. `nil` means the snapshot changed structurally (prefix
    /// eviction, in-place tool status update, etc.) and needs one full resync.
    static func incrementalActions(
        from previous: ScheduledJobProgress,
        to current: ScheduledJobProgress
    ) -> [IncrementalAction]? {
        guard previous.runID == current.runID else { return nil }
        let old = previous.entries
        let new = current.entries
        if old == new { return [] }
        // The initial render includes a "waiting" placeholder; the first real row
        // needs one rebuild to remove it. Every later assistant delta is incremental.
        guard !old.isEmpty else { return nil }

        var index = 0
        while index < min(old.count, new.count), old[index] == new[index] {
            index += 1
        }

        var actions: [IncrementalAction] = []
        if index < old.count {
            guard index == old.count - 1,
                  index < new.count,
                  let mutation = mutationActions(from: old[index], to: new[index])
            else { return nil }
            actions += mutation
            index += 1
        }
        guard index == old.count, new.count >= old.count else { return nil }
        for entry in new.dropFirst(index) {
            actions += appendActions(for: entry)
        }
        return actions
    }

    private static func mutationActions(
        from old: ScheduledJobProgress.Entry,
        to new: ScheduledJobProgress.Entry
    ) -> [IncrementalAction]? {
        guard old.id == new.id,
              case .assistant(isStreaming: true) = old.kind,
              case .assistant(let isStreaming) = new.kind
        else { return nil }
        if isStreaming {
            guard new.detail.hasPrefix(old.detail) else { return nil }
            let suffix = String(new.detail.dropFirst(old.detail.count))
            return suffix.isEmpty ? [] : [.appendAssistantDelta(suffix)]
        }
        return [.commitAssistant(new.detail)]
    }

    private static func appendActions(
        for entry: ScheduledJobProgress.Entry
    ) -> [IncrementalAction] {
        switch entry.kind {
        case .assistant(let isStreaming):
            return [
                .beginAssistant,
                isStreaming
                    ? .appendAssistantDelta(entry.detail)
                    : .commitAssistant(entry.detail),
            ]
        case .tool(let name, let status):
            return [.addTool(
                name: name,
                detail: entry.detail.isEmpty ? nil : entry.detail,
                status: status
            )]
        case .notice:
            return [.addNotice(entry.detail)]
        case .papers(let count):
            return [.addNotice(paperNotice(count: count, titles: entry.detail))]
        }
    }

    private static func paperNotice(count: Int, titles: String) -> String {
        let title = String(
            format: ScheduledJobFormatting.localized(
                "scheduled.progress.referencesFound"
            ),
            locale: .current,
            count
        )
        let list = titles
            .split(separator: "\n")
            .map { "- \($0)" }
            .joined(separator: "\n")
        return list.isEmpty ? "**\(title)**" : "**\(title)**\n\n\(list)"
    }

    private static func emptyProgressMessage(for run: ScheduledJobRun) -> String {
        switch run.status {
        case .failed:
            return ScheduledJobFormatting.failedRunMessage(run)
        case .cancelled:
            return ScheduledJobFormatting.localized("scheduled.result.cancelledMessage")
        case .succeeded:
            return ScheduledJobFormatting.localized("scheduled.progress.completedWithoutOutput")
        case .pending, .running, .unknown:
            return ScheduledJobFormatting.localized("scheduled.progress.waitingForOutput")
        }
    }
}

/// Full-size read-only Home presentation for an active scheduled run. It owns a
/// separate transcript renderer so inspecting progress cannot reset, resume, or
/// otherwise interfere with the user's retained Home conversation.
struct ScheduledRunTranscriptView: View {
    let run: ScheduledJobRun
    let job: ScheduledJob?
    let progress: ScheduledJobProgress?
    let onBack: () -> Void
    let onCancel: (() -> Void)?
    let onOpenResultOrDetails: () -> Void
    let onOpenReference: (Int64) -> Void
    let onOpenPaperSource: (String) -> Void
    let onAddPaperSource: (String) -> Void

    @StateObject private var renderer = ChatTranscriptController()
    @State private var renderedProgress: ScheduledJobProgress?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ChatTranscriptView(
                controller: renderer,
                onOpenReference: onOpenReference,
                onOpenPaperSource: onOpenPaperSource,
                onAddPaperSource: onAddPaperSource
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            applyTheme(colorScheme)
            renderSnapshot()
        }
        .onChange(of: colorScheme) { _, value in applyTheme(value) }
        .onChange(of: progress?.revision) { _, _ in renderProgressUpdate() }
        .onChange(of: run.status) { _, _ in
            // With real rows, status is header-only. Empty runs need their waiting
            // placeholder replaced by the terminal failure/cancel/success message.
            if progress?.entries.isEmpty != false { renderSnapshot() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Label(
                    ScheduledJobFormatting.localized("scheduled.action.backToAssistant"),
                    systemImage: "chevron.left"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(ToolbarHoverButtonStyle())

            Divider().frame(height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(job?.name ?? ScheduledJobFormatting.localized(
                    "scheduled.job.fallbackName"
                ))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

                HStack(spacing: 6) {
                    if run.status.isActive {
                        ProgressView().controlSize(.mini)
                    }
                    Text(statusLabel)
                    if let model = progress?.model {
                        Text(model).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let onCancel {
                Button(
                    ScheduledJobFormatting.localized("scheduled.action.cancelRun"),
                    action: onCancel
                )
                .font(.caption)
                .buttonStyle(ToolbarHoverButtonStyle())
            } else if run.status.isTerminal {
                Button(action: onOpenResultOrDetails) {
                    Label(
                        ScheduledJobFormatting.localized(
                            run.status == .succeeded
                                ? "scheduled.action.openResult"
                                : "scheduled.action.viewDetails"
                        ),
                        systemImage: run.status == .succeeded
                            ? "arrow.up.right.square"
                            : "info.circle"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ToolbarHoverButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var statusLabel: String {
        switch progress?.phase {
        case .preparing?:
            ScheduledJobFormatting.localized("scheduled.progress.preparing")
        case .running?:
            ScheduledJobFormatting.localized("scheduled.status.running")
        case .succeeded?:
            ScheduledJobFormatting.localized("scheduled.status.finished")
        case .failed?:
            run.failureKind.map(ScheduledJobFormatting.failureLabel)
                ?? ScheduledJobFormatting.localized("scheduled.status.failed")
        case .cancelled?:
            ScheduledJobFormatting.localized("scheduled.status.cancelled")
        case nil:
            ScheduledJobFormatting.runDetail(run)
        }
    }

    private func applyTheme(_ value: ColorScheme) {
        renderer.setTheme(value == .dark ? .dark : .light)
    }

    private func renderSnapshot() {
        var messages = ScheduledRunTranscript.messages(
            run: run,
            fallbackPrompt: job?.prompt ?? "",
            progress: progress
        )
        // `loadTranscript` renders restored assistant rows as static bubbles. Keep
        // the current streaming row out of that restore and open it through the
        // incremental contract, so the next token extends the same bubble.
        if let last = progress?.entries.last,
           case .assistant(isStreaming: true) = last.kind {
            messages.removeLast()
            renderer.loadTranscript(messages)
            renderer.beginAssistantMessage()
            if !last.detail.isEmpty { renderer.appendDelta(last.detail) }
        } else {
            renderer.loadTranscript(messages)
        }
        renderedProgress = progress
    }

    private func renderProgressUpdate() {
        guard let previous = renderedProgress,
              let current = progress,
              let actions = ScheduledRunTranscript.incrementalActions(
                from: previous,
                to: current
              )
        else {
            renderSnapshot()
            return
        }
        for action in actions {
            switch action {
            case .beginAssistant:
                renderer.beginAssistantMessage()
            case .appendAssistantDelta(let text):
                renderer.appendDelta(text)
            case .commitAssistant(let text):
                renderer.commitAssistantMessage(text)
            case .addTool(let name, let detail, let status):
                renderer.addToolChip(name: name, detail: detail, status: status)
            case .addNotice(let text):
                renderer.addNotice(text)
            }
        }
        renderedProgress = current
    }
}
#endif
