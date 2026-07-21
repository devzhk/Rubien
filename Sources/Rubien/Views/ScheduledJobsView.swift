#if os(macOS)
import AppKit
import SwiftUI
import RubienCore
import UserNotifications

struct ScheduledJobsPresentation: Equatable {
    let message: String?
}

struct ScheduledJobsPopover: View {
    @ObservedObject var coordinator: ScheduledJobCoordinator
    let onOpenRun: (ScheduledJobRun) -> Void
    var initialEditorJob: ScheduledJob? = nil
    var initialErrorMessage: String? = nil

    private enum Tab: String, CaseIterable, Identifiable {
        case recentRuns = "Recent Runs"
        case scheduledJobs = "Scheduled Jobs"
        var id: String { rawValue }
    }

    private enum EditorTarget: Identifiable {
        case create
        case edit(ScheduledJob)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let job): job.id
            }
        }

        var job: ScheduledJob? {
            guard case .edit(let job) = self else { return nil }
            return job
        }
    }

    @State private var tab: Tab = .recentRuns
    @State private var editorTarget: EditorTarget?
    @State private var deleteTarget: ScheduledJob?
    @State private var deleteRunTarget: ScheduledJobRun?
    @State private var errorMessage: String?
    @State private var expandedRunID: String?
    @State private var recentRunQuery = ""
    @FocusState private var recentRunSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scheduled")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    editorTarget = .create
                } label: {
                    Label("New Job", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(SLSecondaryButtonStyle())
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            DraggableSegmentedControl(
                selection: $tab,
                items: Tab.allCases.map { (label: $0.rawValue, value: $0) }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .recentRuns: recentRuns
                case .scheduledJobs: scheduledJobs
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 350, height: 430)
        .activatePopoverHover()
        .onAppear {
            coordinator.refresh()
            errorMessage = initialErrorMessage
            if let initialEditorJob {
                editorTarget = .edit(initialEditorJob)
            }
        }
        .sheet(item: $editorTarget) { target in
            ScheduledJobEditor(
                coordinator: coordinator,
                job: target.job,
                onDismiss: { editorTarget = nil }
            )
        }
        .alert(
            "Delete scheduled job?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { job in
            Button("Delete", role: .destructive) { delete(job) }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { job in
            Text("“\(job.name)” and its run history will be deleted.")
        }
        .alert(
            "Delete run history?",
            isPresented: Binding(
                get: { deleteRunTarget != nil },
                set: { if !$0 { deleteRunTarget = nil } }
            ),
            presenting: deleteRunTarget
        ) { run in
            Button("Delete Run", role: .destructive) { deleteRun(run) }
            Button("Cancel", role: .cancel) { deleteRunTarget = nil }
        } message: { run in
            Text(String(
                format: ScheduledJobFormatting.localized("scheduled.deleteRun.confirmation"),
                locale: .current,
                coordinator.job(id: run.jobId)?.name
                    ?? ScheduledJobFormatting.localized("scheduled.job.fallbackName"),
                ScheduledJobFormatting.runDetail(run)
            ))
        }
    }

    @ViewBuilder
    private var recentRuns: some View {
        if displayedRecentRuns.isEmpty {
            ContentUnavailableView(
                "No recent runs",
                systemImage: "clock.arrow.circlepath",
                description: Text("Completed and failed scheduled jobs will appear here.")
            )
        } else {
            VStack(spacing: 0) {
                recentRunSearchField
                Divider()
                Group {
                    if filteredRecentRuns.isEmpty {
                        ContentUnavailableView(
                            "No matching runs",
                            systemImage: "magnifyingglass",
                            description: Text("Try another job name, status, provider, or date.")
                        )
                    } else {
                        recentRunList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom) {
                    if coordinator.unreadRunCount > 0 {
                        HStack {
                            Text("\(coordinator.unreadRunCount) unread")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Mark All Read") { coordinator.markAllRunsRead() }
                                .font(.caption)
                                .buttonStyle(ToolbarHoverButtonStyle(
                                    hoverOpacity: 0.10,
                                    pressedOpacity: 0.16
                                ))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.bar)
                    }
                }
            }
        }
    }

    private var recentRunSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search recent runs", text: $recentRunQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($recentRunSearchFocused)
            if !recentRunQuery.isEmpty {
                Button {
                    recentRunQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear search", bundle: .module))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                recentRunSearchFocused = true
            }
        }
    }

    private var recentRunList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredRecentRuns) { run in
                    let isActive = coordinator.activeRun?.id == run.id
                    ScheduledRunRow(
                        run: run,
                        job: coordinator.job(id: run.jobId),
                        resultUnavailable: coordinator.unavailableResultRunIDs.contains(run.id),
                        isExpanded: expandedRunID == run.id,
                        onOpen: expandedRunID == run.id ? {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                expandedRunID = nil
                            }
                        } : (isActive ? {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                expandedRunID = run.id
                            }
                        } : (run.status.isTerminal ? {
                            onOpenRun(run)
                        } : nil)),
                        onCancel: isActive && (run.status == .pending || run.status == .running)
                            ? { coordinator.cancelActiveRun() }
                            : nil,
                        onRunNow: run.status == .failed ? { runNow(jobID: run.jobId) } : nil,
                        onDelete: run.status.isTerminal ? { deleteRunTarget = run } : nil
                    )
                    if expandedRunID == run.id {
                        ScheduledRunProgressView(
                            run: coordinator.activeRun?.id == run.id
                                ? coordinator.activeRun ?? run
                                : run,
                            progress: coordinator.activeRunProgress?.runID == run.id
                                ? coordinator.activeRunProgress
                                : nil,
                            onCancel: isActive ? { coordinator.cancelActiveRun() } : nil
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Divider().padding(.leading, 42)
                }
            }
        }
    }

    private var displayedRecentRuns: [ScheduledJobRun] {
        guard let activeRun = coordinator.activeRun else { return coordinator.recentRuns }
        return [activeRun] + coordinator.recentRuns.filter { $0.id != activeRun.id }
    }

    private var filteredRecentRuns: [ScheduledJobRun] {
        displayedRecentRuns.filter { run in
            ScheduledJobFormatting.runMatchesSearch(
                run,
                job: coordinator.job(id: run.jobId),
                resultUnavailable: coordinator.unavailableResultRunIDs.contains(run.id),
                query: recentRunQuery
            )
        }
    }

    @ViewBuilder
    private var scheduledJobs: some View {
        if coordinator.jobs.isEmpty {
            ContentUnavailableView(
                "No scheduled jobs",
                systemImage: "alarm",
                description: Text("Create a recurring Assistant job to run while Rubien is open.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(coordinator.jobs) { job in
                        ScheduledJobRow(
                            job: job,
                            isActive: coordinator.activeRun?.jobId == job.id,
                            onOpenProgress: coordinator.activeRun?.jobId == job.id
                                ? { showActiveRunProgress() }
                                : nil,
                            onSetEnabled: { enabled in setEnabled(job, enabled) },
                            onRunNow: { runNow(job) },
                            onCancel: coordinator.activeRun?.jobId == job.id
                                ? { coordinator.cancelActiveRun() }
                                : nil,
                            onEdit: { editorTarget = .edit(job) },
                            onDelete: { deleteTarget = job }
                        )
                        Divider().padding(.leading, 42)
                    }
                }
            }
        }
    }

    private func setEnabled(_ job: ScheduledJob, _ enabled: Bool) {
        do {
            _ = try coordinator.setEnabled(id: job.id, isEnabled: enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runNow(_ job: ScheduledJob) {
        runNow(jobID: job.id)
    }

    private func runNow(jobID: String) {
        do {
            try coordinator.runNow(id: jobID)
            errorMessage = nil
            recentRunQuery = ""
            tab = .recentRuns
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showActiveRunProgress() {
        guard let runID = coordinator.activeRun?.id else { return }
        recentRunQuery = ""
        expandedRunID = runID
        tab = .recentRuns
    }

    private func delete(_ job: ScheduledJob) {
        do {
            try coordinator.delete(id: job.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        deleteTarget = nil
    }

    private func deleteRun(_ run: ScheduledJobRun) {
        do {
            try coordinator.deleteRun(id: run.id)
            if expandedRunID == run.id { expandedRunID = nil }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        deleteRunTarget = nil
    }
}

private struct ScheduledRunRow: View {
    let run: ScheduledJobRun
    let job: ScheduledJob?
    let resultUnavailable: Bool
    let isExpanded: Bool
    let onOpen: (() -> Void)?
    let onCancel: (() -> Void)?
    let onRunNow: (() -> Void)?
    let onDelete: (() -> Void)?

    @ViewBuilder
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if let onOpen {
                Button(action: onOpen) {
                    primaryContent
                }
                .buttonStyle(ScheduledRunRowButtonStyle())
                .linkPointerStyle()
            } else {
                primaryContent
            }

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .font(.caption)
                    .buttonStyle(ToolbarHoverButtonStyle(
                        hoverOpacity: 0.10,
                        pressedOpacity: 0.16
                    ))
            } else if let onRunNow {
                Button("Run Now", action: onRunNow)
                    .font(.caption)
                    .buttonStyle(ToolbarHoverButtonStyle(
                        hoverOpacity: 0.10,
                        pressedOpacity: 0.16
                    ))
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ToolbarHoverButtonStyle(
                    hoverOpacity: 0.10,
                    pressedOpacity: 0.16
                ))
                .help(ScheduledJobFormatting.localized("scheduled.action.deleteRun"))
                .accessibilityLabel(ScheduledJobFormatting.localized("scheduled.action.deleteRun"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryContent: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            runSummary
            Spacer(minLength: 8)
            if onOpen != nil {
                HStack(spacing: 3) {
                    Text(ScheduledJobFormatting.localized(actionLabelKey))
                    Image(systemName: isExpanded
                          ? "chevron.down"
                          : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, onCancel == nil && onRunNow == nil && onDelete == nil ? 12 : 4)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var actionLabelKey: String {
        if isExpanded { return "scheduled.action.hideProgress" }
        if run.status.isActive { return "scheduled.action.viewProgress" }
        if run.status == .succeeded,
           run.providerSessionId != nil,
           !resultUnavailable {
            return "scheduled.action.openResult"
        }
        return "scheduled.action.viewDetails"
    }

    private var runSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(job?.name ?? ScheduledJobFormatting.localized("scheduled.job.fallbackName"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if run.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            Text(ScheduledJobFormatting.runDetail(run, resultUnavailable: resultUnavailable))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScheduledJobFormatting.runAccessibilityLabel(
            run,
            jobName: job?.name,
            resultUnavailable: resultUnavailable
        ))
    }

    @ViewBuilder private var statusIcon: some View {
        switch run.status {
        case .pending, .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

}

/// Clickable run and active-job rows expose one large primary target. The
/// highlight is clear at rest, then fills that target on hover/press.
private struct ScheduledRunRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.10)
                          : (isHovered ? Color.primary.opacity(0.06) : .clear))
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct ScheduledJobRow: View {
    let job: ScheduledJob
    let isActive: Bool
    let onOpenProgress: (() -> Void)?
    let onSetEnabled: (Bool) -> Void
    let onRunNow: () -> Void
    let onCancel: (() -> Void)?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(ScheduledJobFormatting.localized("scheduled.accessibility.enableJob"), isOn: Binding(
                get: { job.isEnabled },
                set: onSetEnabled
            ))
            .labelsHidden()
            .accessibilityLabel(String(
                format: ScheduledJobFormatting.localized("scheduled.accessibility.enableNamedJob"),
                locale: .current,
                job.name
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.top, 2)

            Button(action: onOpenProgress ?? onEdit) {
                jobSummary
            }
            .buttonStyle(ScheduledRunRowButtonStyle())
            .linkPointerStyle()
            .accessibilityLabel(ScheduledJobFormatting.jobAccessibilityLabel(
                job,
                isActive: isActive
            ))
            .accessibilityHint(ScheduledJobFormatting.localized(
                isActive
                    ? "scheduled.accessibility.viewProgressHint"
                    : "scheduled.accessibility.editHint"
            ))
            Spacer(minLength: 6)
            Menu {
                if let onCancel {
                    Button("Cancel Run", systemImage: "stop.fill", action: onCancel)
                } else {
                    Button("Run Now", systemImage: "play.fill", action: onRunNow)
                }
                Button("Edit", systemImage: "pencil", action: onEdit)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .disabled(isActive)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var jobSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(job.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if isActive {
                    ProgressView().controlSize(.mini)
                        .accessibilityHidden(true)
                }
            }
            Text(ScheduledJobFormatting.scheduleLabel(job))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(job.provider.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(ScheduledJobFormatting.nextRunLabel(job))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if isActive {
                Label(
                    ScheduledJobFormatting.localized("scheduled.action.viewProgress"),
                    systemImage: "chevron.right"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ScheduledRunProgressView: View {
    let run: ScheduledJobRun
    let progress: ScheduledJobProgress?
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if run.status.isActive {
                    ProgressView().controlSize(.mini)
                }
                Text(progressStatus)
                    .font(.system(size: 11, weight: .semibold))
                if let model = progress?.model {
                    Text(model)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .font(.caption)
                        .buttonStyle(ToolbarHoverButtonStyle(
                            hoverOpacity: 0.10,
                            pressedOpacity: 0.16
                        ))
                }
            }

            if let entries = progress?.entries, !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { entry in
                                progressEntry(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: progress?.revision) { _, _ in
                        guard let lastID = progress?.entries.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: 180)
            } else {
                Text(ScheduledJobFormatting.localized("scheduled.progress.waitingForOutput"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
            }
        }
        .padding(.leading, 42)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private func progressEntry(_ entry: ScheduledJobProgress.Entry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            switch entry.kind {
            case .assistant(let isStreaming):
                Image(systemName: isStreaming ? "ellipsis.bubble" : "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: entry.detail)
                    .textSelection(.enabled)
            case .tool(let name, let status):
                Image(systemName: toolIcon(status))
                    .foregroundStyle(status == .denied ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .fontWeight(.medium)
                    if !entry.detail.isEmpty {
                        Text(verbatim: entry.detail)
                            .foregroundStyle(.secondary)
                    }
                }
            case .notice:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(verbatim: entry.detail)
                    .textSelection(.enabled)
            case .papers(let count):
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        format: ScheduledJobFormatting.localized("scheduled.progress.referencesFound"),
                        locale: .current,
                        count
                    ))
                    .fontWeight(.medium)
                    if !entry.detail.isEmpty {
                        Text(verbatim: entry.detail)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressStatus: String {
        guard let progress else {
            return ScheduledJobFormatting.runDetail(run)
        }
        switch progress.phase {
        case .preparing:
            return ScheduledJobFormatting.localized("scheduled.progress.preparing")
        case .running:
            return ScheduledJobFormatting.localized("scheduled.status.running")
        case .succeeded:
            return ScheduledJobFormatting.localized("scheduled.status.finished")
        case .failed:
            return run.failureKind.map(ScheduledJobFormatting.failureLabel)
                ?? ScheduledJobFormatting.localized("scheduled.status.failed")
        case .cancelled:
            return ScheduledJobFormatting.localized("scheduled.status.cancelled")
        }
    }

    private func toolIcon(_ status: ToolChipStatus) -> String {
        switch status {
        case .started: "gearshape.2"
        case .completed: "checkmark.circle"
        case .denied: "xmark.circle"
        }
    }
}

private struct ScheduledJobEditor: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var coordinator: ScheduledJobCoordinator
    let job: ScheduledJob?
    let onDismiss: () -> Void

    @State private var name: String
    @State private var prompt: String
    @State private var weekdayMask: Int
    @State private var hoveredWeekday: ScheduledWeekday?
    @State private var time: Date
    @State private var isEnabled: Bool
    @State private var provider: ScheduledJobProvider
    @State private var model: String
    @State private var effort: String
    @State private var codexModels: [CodexModelInfo] = []
    @State private var codexCatalogLoaded = false
    @State private var codexCatalogAvailable = true
    @State private var codexCatalogLoadGeneration = 0
    @State private var webAccess: Bool
    @State private var notifyOnCompletion: Bool
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus?
    @State private var errorMessage: String?

    init(
        coordinator: ScheduledJobCoordinator,
        job: ScheduledJob?,
        onDismiss: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.job = job
        self.onDismiss = onDismiss
        _name = State(initialValue: job?.name ?? "")
        _prompt = State(initialValue: job?.prompt ?? "")
        _weekdayMask = State(initialValue: job?.weekdayMask ?? 127)
        let minute = job?.localMinuteOfDay ?? 8 * 60
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = minute / 60
        components.minute = minute % 60
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        _isEnabled = State(initialValue: job?.isEnabled ?? true)
        let defaultProvider = ScheduledJobProvider(RubienPreferences.assistantProvider)
        let initialProvider = job?.provider ?? defaultProvider
        _provider = State(initialValue: initialProvider)
        _model = State(initialValue: ScheduledJobEditorOptions.initialOverride(
            savedValue: job?.model,
            defaultValue: Self.defaultModel(for: initialProvider),
            isEditing: job != nil
        ))
        _effort = State(initialValue: ScheduledJobEditorOptions.initialOverride(
            savedValue: job?.effort,
            defaultValue: Self.defaultEffort(for: initialProvider),
            isEditing: job != nil
        ))
        _webAccess = State(initialValue: ScheduledJobEditorOptions.initialWebSearch(
            savedValue: job?.webAccess,
            preference: RubienPreferences.assistantWebAccess
        ))
        _notifyOnCompletion = State(initialValue: ScheduledJobEditorOptions.initialNotifyOnCompletion(
            savedValue: job?.notifyOnCompletion
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Text(job == nil ? "New Scheduled Job" : "Edit Scheduled Job")
                    .font(.headline)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || weekdayMask == 0)
            }
            .padding()
            Divider()

            Form {
                TextField("Name", text: $name)

                Section("Instructions") {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 110)
                }

                Section("Schedule") {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        ForEach(ScheduledWeekday.allCases, id: \.self) { weekday in
                            weekdayButton(weekday)
                        }
                        Spacer(minLength: 0)
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("Enabled", isOn: $isEnabled)
                }

                Section("Assistant") {
                    Picker("Provider", selection: $provider) {
                        if !ScheduledJobProvider.knownCases.contains(provider) {
                            Text(provider.displayName).tag(provider)
                        }
                        ForEach(ScheduledJobProvider.knownCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    Picker("Model", selection: modelSelection) {
                        ForEach(modelChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .disabled(provider.agentProviderKind == nil)

                    Picker("Effort", selection: $effort) {
                        ForEach(effortChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .disabled(provider.agentProviderKind == nil)

                    if provider == .codex, codexCatalogLoaded, !codexCatalogAvailable {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label(
                                "Couldn’t load models from Codex. The saved or default model will be used.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("Retry") {
                                Task { await loadCodexCatalog(forceReload: true) }
                            }
                            .controlSize(.small)
                        }
                    }

                    Toggle("Web search", isOn: $webAccess)
                }

                Section {
                    Toggle("Notify when finished", isOn: $notifyOnCompletion)

                    if notifyOnCompletion, notificationAuthorizationStatus == .denied {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label(
                                "Notifications are disabled in System Settings.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Settings", action: openNotificationSettings)
                                .controlSize(.small)
                        }
                    } else if notifyOnCompletion, notificationAuthorizationStatus == .notDetermined {
                        Text(isEnabled
                             ? "Rubien will request notification permission after you save this job."
                             : "Rubien will request notification permission when you enable this job.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Scheduled jobs run only while Rubien is open on this Mac. Library access is read-only.")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 380, height: 650)
        .onChange(of: provider) { _, newProvider in
            model = Self.defaultModel(for: newProvider, codexModels: codexModels)
            effort = Self.defaultEffort(for: newProvider)
            ensureEffortIsSupported()
        }
        .task(id: provider) {
            guard provider == .codex else { return }
            await loadCodexCatalog()
        }
        .task(id: notifyOnCompletion) {
            guard notifyOnCompletion else { return }
            await refreshNotificationAuthorizationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, notifyOnCompletion else { return }
            Task { await refreshNotificationAuthorizationStatus() }
        }
    }

    private var modelChoices: [(label: String, value: String)] {
        ScheduledJobEditorOptions.modelRows(
            provider: provider,
            codexModels: codexModels,
            current: model,
            catalogLoaded: codexCatalogLoaded
        )
    }

    private var effortChoices: [(label: String, value: String)] {
        ScheduledJobEditorOptions.effortRows(
            provider: provider,
            codexModels: codexModels,
            model: model,
            current: effort
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { model },
            set: { selectModel($0) }
        )
    }

    private func weekdayButton(_ weekday: ScheduledWeekday) -> some View {
        let selected = weekdayMask & weekday.mask != 0
        let isHovered = hoveredWeekday == weekday
        return Button {
            if selected {
                weekdayMask &= ~weekday.mask
            } else {
                weekdayMask |= weekday.mask
            }
        } label: {
            Text(ScheduledJobFormatting.shortWeekday(weekday))
                .font(.caption2.weight(.semibold))
                .frame(width: 38, height: 38)
                .background(
                    selected
                        ? Color.accentColor.opacity(isHovered ? 0.20 : 0.14)
                        : Color.primary.opacity(isHovered ? 0.08 : 0.045),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .foregroundStyle(
                    selected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.92 : 0.76)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredWeekday = weekday
            } else if hoveredWeekday == weekday {
                hoveredWeekday = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(ScheduledJobFormatting.fullWeekday(weekday))
        .accessibilityValue(ScheduledJobFormatting.localized(
            selected ? "scheduled.accessibility.selected" : "scheduled.accessibility.notSelected"
        ))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let definition = ScheduledJobDefinition(
            name: name,
            prompt: prompt,
            recurrence: .init(weekdayMask: weekdayMask, localMinuteOfDay: minute),
            isEnabled: isEnabled,
            provider: provider,
            model: model,
            effort: effort,
            webAccess: webAccess,
            notifyOnCompletion: notifyOnCompletion
        )
        do {
            if let job {
                _ = try coordinator.update(id: job.id, definition: definition)
            } else {
                _ = try coordinator.create(definition)
            }
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCodexCatalog(forceReload: Bool = false) async {
        codexCatalogLoadGeneration += 1
        let generation = codexCatalogLoadGeneration
        let catalog = await CodexModelCatalog.shared.catalog(
            executableOverride: RubienPreferences.assistantCodexBinaryPath,
            forceReload: forceReload
        )
        guard !Task.isCancelled,
              generation == codexCatalogLoadGeneration,
              provider == .codex
        else { return }
        codexModels = catalog.visibleModels
        codexCatalogAvailable = catalog.fetchedOK
        codexCatalogLoaded = true

        guard provider == .codex, job == nil else { return }
        if model.isEmpty, let first = codexModels.first {
            model = first.id
        }
        ensureEffortIsSupported()
    }

    private func selectModel(_ value: String) {
        guard value != model else { return }
        model = value
        guard provider == .codex,
              let selected = codexModels.first(where: { $0.id == value })
        else { return }
        effort = selected.defaultEffort ?? selected.efforts.first?.value ?? effort
    }

    private func ensureEffortIsSupported() {
        guard provider == .codex,
              let selected = codexModels.first(where: { $0.id == model }),
              !selected.efforts.isEmpty,
              !selected.efforts.contains(where: { $0.value == effort })
        else { return }
        effort = selected.defaultEffort ?? selected.efforts[0].value
    }

    private func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshNotificationAuthorizationStatus() async {
        guard ScheduledJobNotifications.isAvailable else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
    }

    private static func defaultModel(
        for provider: ScheduledJobProvider,
        codexModels: [CodexModelInfo] = []
    ) -> String {
        switch provider {
        case .claude: RubienPreferences.assistantModel
        case .codex: RubienPreferences.assistantCodexModel ?? codexModels.first?.id ?? ""
        case .unknown: ""
        }
    }

    private static func defaultEffort(for provider: ScheduledJobProvider) -> String {
        switch provider {
        case .claude: RubienPreferences.assistantEffort
        case .codex: RubienPreferences.assistantCodexEffort
        case .unknown: ""
        }
    }
}

enum ScheduledJobEditorOptions {
    static func initialOverride(
        savedValue: String?,
        defaultValue: String,
        isEditing: Bool
    ) -> String {
        if isEditing { return savedValue ?? "" }
        return savedValue ?? defaultValue
    }

    static func initialWebSearch(savedValue: Bool?, preference: Bool) -> Bool {
        savedValue ?? preference
    }

    static func initialNotifyOnCompletion(savedValue: Bool?) -> Bool {
        savedValue ?? true
    }

    static func modelRows(
        provider: ScheduledJobProvider,
        codexModels: [CodexModelInfo],
        current: String,
        catalogLoaded: Bool
    ) -> [(label: String, value: String)] {
        switch provider {
        case .claude:
            var rows = AssistantModelOptions.models(for: .claude)
            if current.isEmpty {
                rows.insert((label: "Claude default", value: ""), at: 0)
            } else if !rows.contains(where: { $0.value == current }) {
                rows.append((label: "\(current) — not offered by this Claude", value: current))
            }
            return rows
        case .codex:
            var rows = AssistantModelOptions.codexModelRows(
                models: codexModels,
                pinned: current.isEmpty ? nil : current
            ).map { (label: $0.label, value: $0.value ?? "") }
            if current.isEmpty, !rows.isEmpty {
                rows.insert((label: "Codex default", value: ""), at: 0)
            }
            if rows.isEmpty {
                rows.append((
                    label: catalogLoaded ? "Codex default" : "Loading Codex models…",
                    value: ""
                ))
            }
            return rows
        case .unknown:
            return [(label: current.isEmpty ? "Provider default" : current, value: current)]
        }
    }

    static func effortRows(
        provider: ScheduledJobProvider,
        codexModels: [CodexModelInfo],
        model: String,
        current: String
    ) -> [(label: String, value: String)] {
        let rows: [(label: String, value: String)]
        let unavailableLabel: String
        switch provider {
        case .claude:
            rows = AssistantModelOptions.efforts(for: .claude)
            unavailableLabel = "not offered by this Claude"
        case .codex:
            let governing = codexModels.first(where: { $0.id == model })
            rows = AssistantModelOptions.codexEffortRows(governing: governing)
            unavailableLabel = governing.map { "not offered by \($0.displayName)" } ?? "saved value"
        case .unknown:
            return [(label: current.isEmpty ? "Provider default" : current, value: current)]
        }
        if current.isEmpty {
            return [(label: "\(provider.displayName) default", value: "")] + rows
        }
        guard !rows.contains(where: { $0.value == current }) else {
            return rows
        }
        return rows + [(
            label: "\(CodexEffortInfo.label(for: current)) — \(unavailableLabel)",
            value: current
        )]
    }
}

enum ScheduledJobFormatting {
    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .module)
    }

    static func scheduleLabel(_ job: ScheduledJob) -> String {
        let selected = ScheduledWeekday.allCases.filter { job.recurrence.contains($0) }
        let days: String
        if selected.count == 7 {
            days = localized("scheduled.recurrence.everyDay")
        } else if selected == [.monday, .tuesday, .wednesday, .thursday, .friday] {
            days = localized("scheduled.recurrence.weekdays")
        } else if selected == [.saturday, .sunday] {
            days = localized("scheduled.recurrence.weekends")
        } else {
            days = selected.map(shortWeekday).joined(separator: ", ")
        }
        let hour = job.localMinuteOfDay / 60
        let minute = job.localMinuteOfDay % 60
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return String(
            format: localized("scheduled.recurrence.atTime"),
            locale: .current,
            days,
            date.formatted(date: .omitted, time: .shortened)
        )
    }

    static func shortWeekday(_ weekday: ScheduledWeekday) -> String {
        switch weekday {
        case .monday: localized("scheduled.weekday.monday.short")
        case .tuesday: localized("scheduled.weekday.tuesday.short")
        case .wednesday: localized("scheduled.weekday.wednesday.short")
        case .thursday: localized("scheduled.weekday.thursday.short")
        case .friday: localized("scheduled.weekday.friday.short")
        case .saturday: localized("scheduled.weekday.saturday.short")
        case .sunday: localized("scheduled.weekday.sunday.short")
        }
    }

    static func fullWeekday(_ weekday: ScheduledWeekday) -> String {
        switch weekday {
        case .monday: localized("scheduled.weekday.monday.full")
        case .tuesday: localized("scheduled.weekday.tuesday.full")
        case .wednesday: localized("scheduled.weekday.wednesday.full")
        case .thursday: localized("scheduled.weekday.thursday.full")
        case .friday: localized("scheduled.weekday.friday.full")
        case .saturday: localized("scheduled.weekday.saturday.full")
        case .sunday: localized("scheduled.weekday.sunday.full")
        }
    }

    static func failureLabel(_ kind: ScheduledJobFailureKind) -> String {
        switch kind {
        case .providerUnavailable: localized("scheduled.failure.providerUnavailable")
        case .libraryChannelUnavailable: localized("scheduled.failure.libraryChannelUnavailable")
        case .permissionDenied: localized("scheduled.failure.permissionDenied")
        case .interruptedBeforeStart, .interrupted: localized("scheduled.failure.interrupted")
        case .launchFailed: localized("scheduled.failure.launchFailed")
        case .providerFailed: localized("scheduled.failure.providerFailed")
        case .unknown(let value): value
        }
    }

    static func failureDetail(_ kind: ScheduledJobFailureKind) -> String {
        switch kind {
        case .providerUnavailable:
            localized("scheduled.failureDetail.providerUnavailable")
        case .libraryChannelUnavailable:
            localized("scheduled.failureDetail.libraryChannelUnavailable")
        case .permissionDenied:
            localized("scheduled.failureDetail.permissionDenied")
        case .interruptedBeforeStart, .interrupted:
            localized("scheduled.failureDetail.interrupted")
        case .launchFailed:
            localized("scheduled.failureDetail.launchFailed")
        case .providerFailed:
            localized("scheduled.failureDetail.providerFailed")
        case .unknown(let value):
            value
        }
    }

    static func failedRunMessage(_ run: ScheduledJobRun) -> String {
        let detail = run.failureKind.map(failureDetail)
            ?? localized("scheduled.failureDetail.unknown")
        return String(
            format: localized("scheduled.result.failedReasonMessage"),
            locale: .current,
            detail
        )
    }

    /// Recent Runs is a local history index rather than a transcript copy. Match
    /// every whitespace-separated term across the fields the run row represents,
    /// plus the job prompt/model so a remembered task description is searchable.
    static func runMatchesSearch(
        _ run: ScheduledJobRun,
        job: ScheduledJob?,
        resultUnavailable: Bool = false,
        query: String
    ) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }

        var fields = [
            job?.name,
            job?.prompt,
            job?.model,
            job?.effort,
            run.provider.displayName,
            run.provider.rawValue,
            run.status.rawValue,
            run.trigger.rawValue,
            run.providerSessionId,
            runDetail(run, resultUnavailable: resultUnavailable),
        ].compactMap { $0 }
        if let failure = run.failureKind {
            fields.append(failure.rawValue)
            fields.append(failureLabel(failure))
            fields.append(failureDetail(failure))
        }
        let haystack = fields.joined(separator: "\n")
        return terms.allSatisfy { term in
            haystack.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil
        }
    }

    static func runDetail(
        _ run: ScheduledJobRun,
        resultUnavailable: Bool = false
    ) -> String {
        let time = run.activityAt.formatted(date: .abbreviated, time: .shortened)
        let status: String
        switch run.status {
        case .pending:
            status = localized("scheduled.status.waiting")
        case .running:
            status = localized("scheduled.status.running")
        case .succeeded:
            status = run.providerSessionId == nil || resultUnavailable
                ? localized("scheduled.status.finishedResultUnavailable")
                : localized("scheduled.status.finished")
        case .failed:
            status = run.failureKind.map(failureLabel)
                ?? localized("scheduled.status.failed")
        case .cancelled:
            status = localized("scheduled.status.cancelled")
        case .unknown(let value):
            status = value
        }
        return String(
            format: localized("scheduled.status.atTime"),
            locale: .current,
            status,
            time
        )
    }

    static func nextRunLabel(_ job: ScheduledJob) -> String {
        guard let next = job.nextRunAt else {
            return localized("scheduled.status.paused")
        }
        return String(
            format: localized("scheduled.status.nextRun"),
            locale: .current,
            next.formatted(date: .abbreviated, time: .shortened)
        )
    }

    static func runAccessibilityLabel(
        _ run: ScheduledJobRun,
        jobName: String?,
        resultUnavailable: Bool = false
    ) -> String {
        var parts = [
            jobName ?? localized("scheduled.job.fallbackName"),
            runDetail(run, resultUnavailable: resultUnavailable),
        ]
        if run.isUnread {
            parts.append(localized("scheduled.status.unread"))
        }
        return parts.joined(separator: ", ")
    }

    static func jobAccessibilityLabel(_ job: ScheduledJob, isActive: Bool) -> String {
        var parts = [
            job.name,
            job.isEnabled
                ? localized("scheduled.status.enabled")
                : localized("scheduled.status.disabled"),
            scheduleLabel(job),
            job.provider.displayName,
            nextRunLabel(job),
        ]
        if isActive {
            parts.append(localized("scheduled.status.running"))
        }
        return parts.joined(separator: ", ")
    }
}
#endif
