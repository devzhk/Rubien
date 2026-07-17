#if os(macOS)
import AppKit
import SwiftUI
import RubienCore
import UserNotifications

struct ScheduledJobsPopover: View {
    @ObservedObject var coordinator: ScheduledJobCoordinator
    let onOpenRun: (ScheduledJobRun) -> Void
    var initialEditorJob: ScheduledJob? = nil

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
    @State private var errorMessage: String?

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
                .buttonStyle(.bordered)
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
        .frame(width: 440, height: 430)
        .onAppear {
            coordinator.refresh()
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
    }

    @ViewBuilder
    private var recentRuns: some View {
        if coordinator.recentRuns.isEmpty {
            ContentUnavailableView(
                "No recent runs",
                systemImage: "clock.arrow.circlepath",
                description: Text("Completed and failed scheduled jobs will appear here.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(coordinator.recentRuns) { run in
                        ScheduledRunRow(
                            run: run,
                            job: coordinator.job(id: run.jobId),
                            onOpen: run.status == .succeeded && run.providerSessionId != nil ? {
                                coordinator.markRunRead(id: run.id)
                                onOpenRun(run)
                            } : nil,
                            onCancel: run.status.isActive ? { coordinator.cancelActiveRun() } : nil,
                            onRunNow: run.status == .failed ? { runNow(jobID: run.jobId) } : nil
                        )
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if coordinator.unreadRunCount > 0 {
                    HStack {
                        Text("\(coordinator.unreadRunCount) unread")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Mark All Read") { coordinator.markAllRunsRead() }
                            .font(.caption)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.bar)
                }
            }
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
            tab = .recentRuns
        } catch {
            errorMessage = error.localizedDescription
        }
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
}

private struct ScheduledRunRow: View {
    let run: ScheduledJobRun
    let job: ScheduledJob?
    let onOpen: (() -> Void)?
    let onCancel: (() -> Void)?
    let onRunNow: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job?.name ?? "Scheduled job")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if run.isUnread {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    }
                }
                Text(runDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .font(.caption)
                    .buttonStyle(.borderless)
            } else if let onRunNow {
                Button("Run Now", action: onRunNow)
                    .font(.caption)
                    .buttonStyle(.borderless)
            } else if onOpen != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
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

    private var runDetail: String {
        let date = run.finishedAt ?? run.startedAt ?? run.scheduledFor
        let time = date.formatted(date: .abbreviated, time: .shortened)
        switch run.status {
        case .pending: return "Waiting · \(time)"
        case .running: return "Running · \(time)"
        case .succeeded: return "Finished · \(time)"
        case .failed:
            let reason = run.failureKind.map(ScheduledJobFormatting.failureLabel) ?? "Failed"
            return "\(reason) · \(time)"
        case .cancelled: return "Cancelled · \(time)"
        case .unknown(let value): return "\(value) · \(time)"
        }
    }
}

private struct ScheduledJobRow: View {
    let job: ScheduledJob
    let isActive: Bool
    let onSetEnabled: (Bool) -> Void
    let onRunNow: () -> Void
    let onCancel: (() -> Void)?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { job.isEnabled },
                set: onSetEnabled
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if isActive { ProgressView().controlSize(.mini) }
                }
                Text(ScheduledJobFormatting.scheduleLabel(job))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(job.provider.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let next = job.nextRunAt {
                    Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Paused")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
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
}

private struct ScheduledJobEditor: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var coordinator: ScheduledJobCoordinator
    let job: ScheduledJob?
    let onDismiss: () -> Void

    @State private var name: String
    @State private var prompt: String
    @State private var weekdayMask: Int
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
                    selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.76))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ScheduledJobFormatting.fullWeekday(weekday))
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
    static func scheduleLabel(_ job: ScheduledJob) -> String {
        let selected = ScheduledWeekday.allCases.filter { job.recurrence.contains($0) }
        let days: String
        if selected.count == 7 {
            days = "Every day"
        } else if selected == [.monday, .tuesday, .wednesday, .thursday, .friday] {
            days = "Weekdays"
        } else if selected == [.saturday, .sunday] {
            days = "Weekends"
        } else {
            days = selected.map(shortWeekday).joined(separator: ", ")
        }
        let hour = job.localMinuteOfDay / 60
        let minute = job.localMinuteOfDay % 60
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return "\(days) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func shortWeekday(_ weekday: ScheduledWeekday) -> String {
        switch weekday {
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        case .sunday: "Sun"
        }
    }

    static func fullWeekday(_ weekday: ScheduledWeekday) -> String {
        switch weekday {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }

    static func failureLabel(_ kind: ScheduledJobFailureKind) -> String {
        switch kind {
        case .providerUnavailable: "Provider unavailable"
        case .libraryChannelUnavailable: "Library tools unavailable"
        case .permissionDenied: "Permission required"
        case .interruptedBeforeStart, .interrupted: "Interrupted"
        case .launchFailed: "Couldn’t start"
        case .providerFailed: "Provider failed"
        case .unknown(let value): value
        }
    }
}
#endif
