#if os(macOS)
import AppKit
import SwiftUI
import RubienCore
import RubienSync

private enum AssistantConversationClearOutcome: Sendable {
    case success(Int)
    case failure(String)
}

struct RubienSettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var cacheBytes: Int64 = 0
    @State private var backfillRemaining: Int = 0

    // Assistant pane (Phase 2c-5; per-provider in 3b-3). Availability probes + mirrors
    // of the path overrides (RubienPreferences isn't observable, so the "Choose…"
    // buttons keep these in sync to re-render the displayed path).
    @State private var claudeAvailability: AgentAvailability?
    @State private var isProbingClaude = false
    /// Monotonic probe token: only the latest `recheckClaude` result is applied, so a
    /// Reset/Choose that supersedes an in-flight probe can't be overwritten by the
    /// stale one landing late.
    @State private var probeGeneration = 0
    @State private var workspacePathOverride = ""
    @State private var binaryPathOverride = ""
    // Codex CLI probe + binary mirror (parallel to Claude's — either backend is usable
    // per-conversation via the composer picker, so both are set up here, 3b-3).
    @State private var codexAvailability: AgentAvailability?
    @State private var isProbingCodex = false
    @State private var codexProbeGeneration = 0
    @State private var codexBinaryPathOverride = ""
    // Observable mirrors of the default prefs. A Picker/Toggle bound STRAIGHT to a
    // `Binding(get:set:)` over RubienPreferences persists but doesn't re-render (the
    // store isn't observable), so a pick only showed after relaunch — these @State
    // mirrors drive the controls; `.onChange` writes them through to the prefs. Model
    // and effort are BACKEND-SPECIFIC: their mirror re-seeds from the selected default
    // backend's prefs when `defaultProvider` changes, and writes route back to the
    // matching backend's pref. Initial values match the pref defaults so seeding an
    // unset pref doesn't write one back.
    @State private var defaultProvider: AgentProviderKind = .claude
    @State private var defaultModel = "opus"
    @State private var defaultEffort = "high"
    /// The installed codex's discovered models for the Settings pickers (visible
    /// entries only). Loaded on appear; Recheck force-reloads. Empty while pending
    /// or when discovery failed — the pickers then degrade per spec §4.7.
    @State private var codexCatalogModels: [CodexModelInfo] = []
    /// Monotonic load token mirroring `codexProbeGeneration`: only the latest
    /// `loadCodexCatalog` result is applied, so a fast Reset→Choose can't be
    /// overwritten by a stale load landing late.
    @State private var codexCatalogLoadGeneration = 0
    @State private var defaultCodexSandbox: CodexSandbox = .readOnly
    @State private var defaultWebAccess = true
    @State private var defaultAutoApprove = false
    @State private var defaultLoadUserTools = false
    @State private var libraryPrompt = AssistantContext.defaultPrompt(for: .library)
    @State private var readerPrompt = AssistantContext.defaultPrompt(for: .reader)
    @State private var isEditingLibraryPrompt = false
    @State private var isEditingReaderPrompt = false
    @State private var promptSaveTask: Task<Void, Never>?
    @State private var recordReadingActivity = true
    @State private var recordAssistantActivity = true
    @State private var showClearReadingConfirmation = false
    @State private var showClearAssistantConfirmation = false
    @State private var activityStatusMessage: String?
    @State private var showClearAssistantConversationsConfirmation = false
    @State private var assistantConversationStatusMessage: String?
    /// Latched at the start of an upload session so the indicator can render
    /// as "Uploading 4 of 31 PDFs to iCloud". Cleared back to nil when the
    /// queue reaches 0 so the next upload session re-latches with its own
    /// initial count rather than dividing by a stale denominator.
    @State private var initialBackfillCount: Int? = nil

    private let pdfAssetCache = PDFAssetCache(
        db: AppDatabase.shared,
        storageRoot: AppDatabase.pdfStorageURL
    )

    var body: some View {
        TabView {
            generalPane
                .tabItem {
                    Label(
                        String(localized: "General", bundle: .module),
                        systemImage: "gearshape"
                    )
                }
            assistantPane
                .tabItem {
                    Label(
                        String(localized: "Assistant", bundle: .module),
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
            activityPane
                .tabItem {
                    Label(
                        String(localized: "Activity", bundle: .module),
                        systemImage: "chart.bar.xaxis"
                    )
                }
            iCloudSyncPane
                .tabItem {
                    Label(
                        String(localized: "iCloud Sync", bundle: .module),
                        systemImage: "icloud"
                    )
                }
        }
        .frame(width: 540, height: 500)
    }

    @ViewBuilder
    private var activityPane: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Record reading activity on this Mac", bundle: .module),
                    isOn: $recordReadingActivity
                )
                Toggle(
                    String(localized: "Record Rubien AI session statistics", bundle: .module),
                    isOn: $recordAssistantActivity
                )
            } header: {
                Text(String(localized: "Capture", bundle: .module))
            } footer: {
                Text(String(
                    localized: "Reading time is estimated only while a Rubien PDF or web reader is the active foreground window. It is saved about once per active minute and on pause or close. Activity metadata follows library iCloud sync when sync is on; simultaneous reading on two devices may be counted twice.",
                    bundle: .module
                ))
            }

            Section {
                Button(String(localized: "Clear Reading Activity…", bundle: .module), role: .destructive) {
                    showClearReadingConfirmation = true
                }
                Button(String(localized: "Clear AI Session Statistics…", bundle: .module), role: .destructive) {
                    showClearAssistantConfirmation = true
                }
                if let activityStatusMessage {
                    Text(activityStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Reset", bundle: .module))
            } footer: {
                Text(String(
                    localized: "Clearing creates a synced reset boundary for only that category. Activity recorded offline on another device before it learns the reset may be excluded when it reconnects. Legacy Last Read and Read Count values are unchanged.",
                    bundle: .module
                ))
            }
        }
        .formStyle(.grouped)
        .task {
            recordReadingActivity = RubienPreferences.recordReadingActivity
            recordAssistantActivity = RubienPreferences.recordAssistantActivity
        }
        .onChange(of: recordReadingActivity) { _, value in
            RubienPreferences.recordReadingActivity = value
            ReadingActivityWindowMonitor.shared.refresh()
        }
        .onChange(of: recordAssistantActivity) { _, value in
            RubienPreferences.recordAssistantActivity = value
        }
        .confirmationDialog(
            String(localized: "Clear Reading Activity?", bundle: .module),
            isPresented: $showClearReadingConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear Reading Activity", bundle: .module), role: .destructive) {
                clearActivity(.reading)
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(
                localized: "Papers read, estimated reading time, heatmap history, streaks, and recent-reading history will restart from now. This cannot be undone.",
                bundle: .module
            ))
        }
        .confirmationDialog(
            String(localized: "Clear AI Session Statistics?", bundle: .module),
            isPresented: $showClearAssistantConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear AI Session Statistics", bundle: .module), role: .destructive) {
                clearActivity(.assistant)
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(
                localized: "The AI session count will restart from now. Conversation history and provider attribution are not deleted.",
                bundle: .module
            ))
        }
    }

    private func clearActivity(_ kind: ActivityKind) {
        activityStatusMessage = String(localized: "Clearing…", bundle: .module)
        Task {
            do {
                if kind == .reading {
                    try await ReadingActivityWindowMonitor.shared.clearReadingActivity(
                        in: AppDatabase.shared
                    )
                } else {
                    _ = try await Task.detached(priority: .utility) {
                        try AppDatabase.shared.clearActivity(kind: kind)
                    }.value
                }
                NotificationCenter.default.post(name: .rubienActivityDidChange, object: nil)
                activityStatusMessage = kind == .reading
                    ? String(localized: "Reading activity cleared.", bundle: .module)
                    : String(localized: "AI session statistics cleared.", bundle: .module)
            } catch {
                activityStatusMessage = String(
                    format: String(localized: "Could not clear activity: %@", bundle: .module),
                    error.localizedDescription
                )
            }
        }
    }

    @ViewBuilder
    private var generalPane: some View {
        Form {
            Section(String(localized: "Appearance", bundle: .module)) {
                Picker(
                    String(localized: "Theme", bundle: .module),
                    selection: Binding(
                        get: { RubienPreferences.colorScheme },
                        set: { RubienPreferences.setColorScheme($0) }
                    )
                ) {
                    ForEach(ColorSchemePreference.allCases, id: \.self) { pref in
                        Text(pref.localizedTitle).tag(pref)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(String(localized: "Accent Color", bundle: .module))
                    Spacer()
                    Button(String(localized: "Reset to Default", bundle: .module)) {
                        AccentColorManager.shared.resetToDefault()
                    }
                    .controlSize(.small)
                    .disabled(AccentColorManager.shared.customColor == nil)
                    AccentColorWell()
                }
            }

            #if canImport(Sparkle)
            // Software updates — folded in from a former standalone Updates tab.
            UpdateSettingsSection()
            #endif
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var iCloudSyncPane: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Sync library via iCloud", bundle: .module),
                    isOn: coordinator.toggleBinding
                )
                .confirmationDialog(
                    String(localized: "Enable iCloud Sync?", bundle: .module),
                    isPresented: Binding(
                        get: { coordinator.pendingConfirm },
                        set: { if !$0 { coordinator.cancelConfirm() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Enable Sync", bundle: .module)) {
                        coordinator.confirmEnable()
                    }
                    Button(String(localized: "Not Now", bundle: .module), role: .cancel) {
                        coordinator.cancelConfirm()
                    }
                } message: {
                    Text(String(
                        localized: "This will upload your library to iCloud and keep it in sync with other Macs on the same account. You can turn it off anytime, which stops syncing but keeps your local library intact.",
                        bundle: .module
                    ))
                }

                HStack {
                    Text(String(localized: "PDF cache", bundle: .module))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }

                if let initial = initialBackfillCount, initial > 0, backfillRemaining > 0 {
                    let done = max(0, initial - backfillRemaining)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(initial == 1
                            ? String(format: String(localized: "Uploading %d of %d PDF to iCloud", bundle: .module), done, initial)
                            : String(format: String(localized: "Uploading %d of %d PDFs to iCloud", bundle: .module), done, initial))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(done), total: Double(initial))
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                await refreshCacheStatsLoop()
            }

            if case .unavailable = coordinator.status {
                Section {
                    Button(String(localized: "Try again", bundle: .module)) {
                        Task { await coordinator.retryStartSync() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// One-shot read of cache size + in-flight upload count, then poll
    /// every 2s while uploads are pending so the indicator updates as
    /// CKSyncEngine drains them. Stops polling once nothing is in flight
    /// (or the task is cancelled, e.g. when the Settings window closes).
    ///
    /// Source is `dirtyReferencePDFCount` — `syncState` rows for
    /// `referencePDF` still flagged dirty — NOT the `pdfUploadQueue`
    /// table, which empties at drainer hand-off. With the queue the bar
    /// would zero out long before the engine actually finished pushing.
    ///
    /// `initialBackfillCount` is latched the first poll where the count
    /// is non-zero, then cleared when it returns to zero — so the
    /// indicator renders as "Uploading 4 of 31 PDFs" with a real
    /// progress bar, and a future upload session re-latches with its
    /// own denominator instead of reusing a stale one.
    private func refreshCacheStatsLoop() async {
        repeat {
            cacheBytes = (try? await pdfAssetCache.totalCacheSize()) ?? 0
            let count = (try? AppDatabase.shared.dirtyReferencePDFCount()) ?? 0
            if initialBackfillCount == nil, count > 0 {
                initialBackfillCount = count
            }
            backfillRemaining = count
            if count == 0 {
                initialBackfillCount = nil
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        } while !Task.isCancelled
    }

    private var statusCaption: String {
        switch coordinator.status {
        case .disabled:
            return String(localized: "Off — local library only.", bundle: .module)
        case .unavailable(let reason):
            return String(format: String(localized: "Sync unavailable: %@", bundle: .module), reason)
        case .signedOut:
            return String(localized: "Not signed in to iCloud on this Mac.", bundle: .module)
        case .idle:
            return String(localized: "Syncing via iCloud.", bundle: .module)
        case .syncing:
            return String(localized: "Syncing in progress…", bundle: .module)
        case .error(let err):
            return String(format: String(localized: "Sync error: %@", bundle: .module), err.localizedDescription)
        }
    }

    // MARK: - Assistant pane (Phase 2c-5)

    @ViewBuilder
    private var assistantPane: some View {
        Form {
            assistantWorkspaceSection
            assistantDefaultsSection
            assistantPromptsSection
            assistantConversationStorageSection
            assistantClaudeCLISection
            assistantCodexCLISection
        }
        .formStyle(.grouped)
        .task {
            workspacePathOverride = RubienPreferences.assistantWorkspacePath ?? ""
            binaryPathOverride = RubienPreferences.assistantBinaryPath ?? ""
            codexBinaryPathOverride = RubienPreferences.assistantCodexBinaryPath ?? ""
            defaultProvider = RubienPreferences.assistantProvider
            defaultCodexSandbox = RubienPreferences.assistantCodexSandbox
            defaultWebAccess = RubienPreferences.assistantWebAccess
            defaultAutoApprove = RubienPreferences.assistantAutoApprove
            defaultLoadUserTools = RubienPreferences.assistantLoadUserTools
            libraryPrompt = RubienPreferences.assistantLibraryPromptOverride
                ?? AssistantContext.defaultPrompt(for: .library)
            readerPrompt = RubienPreferences.assistantReaderPromptOverride
                ?? AssistantContext.defaultPrompt(for: .reader)
            seedModelEffortMirrors(for: defaultProvider)
            if claudeAvailability == nil { recheckClaude() }
            if codexAvailability == nil {
                // `recheckCodex` deliberately performs availability THEN model
                // discovery. Starting a second catalog load here made first-open
                // launch up to three codex processes against the same cold runtime.
                if !isProbingCodex { recheckCodex() }
            } else if codexCatalogModels.isEmpty, !isProbingCodex {
                loadCodexCatalog()
            }
        }
        // Persist each mirror to the (non-observable) prefs when the user changes it.
        // Switching the default backend re-seeds the model/effort mirrors from that
        // backend's own prefs (Claude/Codex slugs are disjoint).
        .onChange(of: defaultProvider) { _, value in
            RubienPreferences.assistantProvider = value
            seedModelEffortMirrors(for: value)
        }
        .onChange(of: defaultModel) { _, value in
            // Detect a USER pick vs a mirror RE-SEED (pane appear / backend
            // switch): a seed sets the mirror to the stored pref, so value ==
            // pref there. Snapping on seeds would rewrite the stored effort on
            // mere pane-open — the guard makes the spec-§3 effort snap (an
            // explicit model pick adopts the model's own default effort;
            // plan-review #4) fire on real picks only. Compare BEFORE
            // setDefaultModel persists the new value.
            let isCodexUserPick = defaultProvider == .codex
                && value != (RubienPreferences.assistantCodexModel ?? "")
            setDefaultModel(value)
            if isCodexUserPick,
               let snapped = codexCatalogModels.first(where: { $0.id == value })?.defaultEffort {
                defaultEffort = snapped
            }
        }
        .onChange(of: defaultEffort) { _, value in setDefaultEffort(value) }
        .onChange(of: defaultCodexSandbox) { _, value in RubienPreferences.assistantCodexSandbox = value }
        .onChange(of: defaultWebAccess) { _, value in RubienPreferences.assistantWebAccess = value }
        .onChange(of: defaultAutoApprove) { _, value in RubienPreferences.assistantAutoApprove = value }
        .onChange(of: defaultLoadUserTools) { _, value in
            RubienPreferences.assistantLoadUserTools = value
        }
        .onChange(of: libraryPrompt) { _, _ in
            schedulePromptSave()
        }
        .onChange(of: readerPrompt) { _, _ in
            schedulePromptSave()
        }
        .onDisappear {
            promptSaveTask?.cancel()
            persistPromptOverrides()
        }
    }

    @ViewBuilder
    private var assistantConversationStorageSection: some View {
        Section {
            Button(
                String(localized: "Clear Assistant Conversations…", bundle: .module),
                role: .destructive
            ) {
                showClearAssistantConversationsConfirmation = true
            }
            if let assistantConversationStatusMessage {
                Text(assistantConversationStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Conversation Storage", bundle: .module))
        } footer: {
            Text(String(
                localized: "Rubien saves normalized local transcripts so Home, reader, and scheduled-run History can open without starting the provider.",
                bundle: .module
            ))
        }
        .confirmationDialog(
            String(localized: "Clear Assistant Conversations?", bundle: .module),
            isPresented: $showClearAssistantConversationsConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "Clear Assistant Conversations", bundle: .module),
                role: .destructive
            ) {
                clearAssistantConversations()
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(
                localized: "This deletes idle local Assistant transcripts and their managed attachments. It does not delete AI session statistics or conversations in Claude Code or Codex Provider History.",
                bundle: .module
            ))
        }
    }

    private func clearAssistantConversations() {
        assistantConversationStatusMessage = String(
            localized: "Clearing conversations…",
            bundle: .module
        )
        let database = AppDatabase.shared
        guard AssistantExecutionOwnership.shared.beginMaintenance(
            database: database
        ) else {
            assistantConversationStatusMessage = AssistantExecutionOwnership.shared
                .unavailableReason
                ?? String(
                    localized: "Assistant execution is owned by another Rubien process.",
                    bundle: .module
                )
            return
        }
        let libraryRoot = AppDatabase.libraryRootURL
        Task {
            let outcome = await Task.detached(
                priority: .userInitiated
            ) { () -> AssistantConversationClearOutcome in
                do {
                    let count = try database.clearAssistantConversations()
                    try DurableAssistantAttachmentStore.reconcile(
                        database: database,
                        libraryRoot: libraryRoot
                    )
                    return .success(count)
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            switch outcome {
            case .success(let count):
                AssistantExecutionOwnership.shared.finishMaintenance(
                    libraryRoot: libraryRoot,
                    prepared: true
                )
                NotificationCenter.default.post(
                    name: .rubienAssistantConversationsDidChange,
                    object: nil
                )
                assistantConversationStatusMessage = String(
                    format: String(
                        localized: "Cleared %d local Assistant conversations.",
                        bundle: .module
                    ),
                    count
                )
            case .failure(let message):
                AssistantExecutionOwnership.shared.finishMaintenance(
                    libraryRoot: libraryRoot,
                    prepared: false,
                    failureMessage: "Assistant conversation maintenance failed: \(message)"
                )
                assistantConversationStatusMessage = String(
                    format: String(
                        localized: "Could not clear conversations: %@",
                        bundle: .module
                    ),
                    message
                )
            }
        }
    }

    /// Re-seed the model/effort mirrors from the selected default backend's prefs.
    /// Called on appear and whenever `defaultProvider` changes.
    private func seedModelEffortMirrors(for kind: AgentProviderKind) {
        switch kind {
        case .claude:
            defaultModel = RubienPreferences.assistantModel
            defaultEffort = RubienPreferences.assistantEffort
        case .codex:
            defaultModel = RubienPreferences.assistantCodexModel ?? ""
            defaultEffort = RubienPreferences.assistantCodexEffort
        }
    }

    /// The Codex model the Settings picker DISPLAYS as the current default: the
    /// remembered pick, or — when nothing is pinned (nil pref → "" mirror) — the
    /// first discovered model, exactly mirroring the runtime's floating "first
    /// available" seed (`ChatSessionController.seedCodexModelIfUnset`). Display only:
    /// never written back unless the user makes an explicit pick, so an unpicked
    /// default keeps floating onto whatever codex offers first rather than pinning.
    private var effectiveDefaultCodexModel: String {
        defaultModel.isEmpty ? (codexCatalogModels.first?.id ?? "") : defaultModel
    }

    /// Codex model rows for the Settings picker: the shared builder's CONCRETE
    /// discovered models, with the first shown as the selected default when nothing
    /// is pinned (`effectiveDefaultCodexModel`). There is deliberately NO separate
    /// "first available" row — the first concrete model already IS that default, and
    /// any deviation is remembered, so exposing it as a pickable option only adds a
    /// redundant, confusing choice. A pinned-but-absent slug stays visible via the
    /// builder's keep-pin row. Only while the catalog is still empty (discovery
    /// pending or unavailable) with nothing pinned does a single neutral placeholder
    /// stand in, so the control isn't blank and its "" selection has a matching tag;
    /// it disappears the moment real models arrive.
    private var settingsCodexModelRows: [(label: String, value: String)] {
        var rows = AssistantModelOptions.codexModelRows(
            models: codexCatalogModels,
            pinned: defaultModel.isEmpty ? nil : defaultModel)
            .map { (label: $0.label, value: $0.value ?? "") }
        if rows.isEmpty {
            rows.append((label: String(localized: "Codex default", bundle: .module), value: ""))
        }
        return rows
    }

    /// The model Picker's selection. Claude passes the mirror through unchanged;
    /// Codex resolves an unpinned ("") mirror to the displayed first model for GET so
    /// the control shows a concrete default, while SET writes the raw pick straight
    /// to the mirror — a floating default therefore stays "" (pref nil) until the
    /// user actually picks something.
    private var defaultModelSelection: Binding<String> {
        Binding(
            get: { defaultProvider == .codex ? effectiveDefaultCodexModel : defaultModel },
            set: { defaultModel = $0 }
        )
    }

    /// Effort rows follow the DISPLAYED default model (the pinned pick, or the first
    /// discovered model when floating — `effectiveDefaultCodexModel`) when it's in
    /// the catalog, else the universal four, so the effort list stays consistent with
    /// the model the picker above shows. Includes the current selection even if
    /// unlisted (an unlisted stored effort must not blank the control or trigger a write).
    private var settingsCodexEffortRows: [(label: String, value: String)] {
        let governing = codexCatalogModels.first { $0.id == effectiveDefaultCodexModel }
        return AssistantModelOptions.codexEffortRows(
            governing: governing,
            includingCurrent: defaultEffort.isEmpty ? nil : defaultEffort)
    }

    /// Route a model-mirror change back to the CURRENTLY-selected backend's pref.
    /// For Codex, an empty mirror means "no explicit pick" → the pref key is removed
    /// (nil), so the default keeps floating onto the first discovered model rather
    /// than pinning one (spec §4.4). The picker never offers "" as a real choice; it
    /// resolves to the first model for display via `effectiveDefaultCodexModel`.
    private func setDefaultModel(_ value: String) {
        switch defaultProvider {
        case .claude: RubienPreferences.assistantModel = value
        case .codex: RubienPreferences.assistantCodexModel = value.isEmpty ? nil : value
        }
    }

    private func setDefaultEffort(_ value: String) {
        switch defaultProvider {
        case .claude: RubienPreferences.assistantEffort = value
        case .codex: RubienPreferences.assistantCodexEffort = value
        }
    }

    private var assistantWorkspaceSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text((effectiveWorkspacePath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if !workspacePathOverride.isEmpty {
                    Button(String(localized: "Reset", bundle: .module)) {
                        RubienPreferences.assistantWorkspacePath = nil
                        workspacePathOverride = ""
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                }
                Button(String(localized: "Choose…", bundle: .module)) { pickWorkspace() }
                    .buttonStyle(SettingsActionButtonStyle())
            }
        } header: {
            Text(String(localized: "Working folder", bundle: .module))
        } footer: {
            Text(String(localized: "The assistant works in this folder — its scratch space and any files it writes. Newly opened documents use it as their working directory.", bundle: .module))
        }
    }

    private var assistantDefaultsSection: some View {
        Section {
            Picker(selection: $defaultProvider) {
                Text(String(localized: "Claude Code", bundle: .module)).tag(AgentProviderKind.claude)
                Text(String(localized: "Codex", bundle: .module)).tag(AgentProviderKind.codex)
            } label: {
                Text(String(localized: "Backend", bundle: .module))
            }

            // Model/effort are the SELECTED backend's. Claude: static verified
            // aliases. Codex: discovered rows only — an unpinned default just shows
            // the first discovered model (no "first available" row), and the pref
            // stores nil until the user explicitly picks (spec §4.4). The selection
            // binding resolves that floating default to the first model for display.
            Picker(selection: defaultModelSelection) {
                if defaultProvider == .codex {
                    ForEach(settingsCodexModelRows, id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                } else {
                    ForEach(AssistantModelOptions.models(for: .claude), id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                }
            } label: {
                Text(String(localized: "Model", bundle: .module))
            }

            Picker(selection: $defaultEffort) {
                if defaultProvider == .codex {
                    ForEach(settingsCodexEffortRows, id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                } else {
                    ForEach(AssistantModelOptions.efforts(for: .claude), id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                }
            } label: {
                Text(String(localized: "Reasoning effort", bundle: .module))
            }

            // Codex-only: the OS sandbox a new Codex conversation runs in (D6).
            if defaultProvider.descriptor.supportsSandbox {
                Picker(selection: $defaultCodexSandbox) {
                    Text(String(localized: "Read-only", bundle: .module)).tag(CodexSandbox.readOnly)
                    Text(String(localized: "Workspace-write", bundle: .module)).tag(CodexSandbox.workspaceWrite)
                } label: {
                    Text(String(localized: "Sandbox", bundle: .module))
                }
            }

            Toggle(isOn: $defaultWebAccess) {
                Text(String(localized: "Web search", bundle: .module))
            }

            Toggle(isOn: $defaultLoadUserTools) {
                Text(String(localized: "Use connected apps and MCP tools", bundle: .module))
            }

            Picker(selection: $defaultAutoApprove) {
                if defaultLoadUserTools {
                    Text(String(localized: "Use agent permissions", bundle: .module)).tag(false)
                } else {
                    Text(String(localized: "Ask before writes", bundle: .module)).tag(false)
                }
                Text(String(localized: "Auto-accept actions", bundle: .module)).tag(true)
            } label: {
                Text(String(localized: "Approvals", bundle: .module))
            }
        } header: {
            Text(String(localized: "Defaults for new conversations", bundle: .module))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Only applies to new conversations.", bundle: .module))
                Text(String(localized: "Claude: loads your plugins, settings, and MCP servers.", bundle: .module))
                Text(String(localized: "Codex: enables connected apps; MCP servers are already loaded.", bundle: .module))
                Text(String(localized: "Permissions: your agent rules apply, so Rubien may not ask first.", bundle: .module))
            }
        }
    }

    private var assistantPromptsSection: some View {
        Section {
            assistantPromptEditor(
                title: String(localized: "Home conversations", bundle: .module),
                text: $libraryPrompt,
                isEditing: $isEditingLibraryPrompt,
                defaultPrompt: AssistantContext.defaultPrompt(for: .library))
            assistantPromptEditor(
                title: String(localized: "Reader conversations", bundle: .module),
                text: $readerPrompt,
                isEditing: $isEditingReaderPrompt,
                defaultPrompt: AssistantContext.defaultPrompt(for: .reader))
        } header: {
            Text(String(localized: "Seed prompts", bundle: .module))
        } footer: {
            Text(String(
                localized: "Each prompt starts from Rubien’s built-in text. Choose Edit to customize it or Reset to Default to restore it. Prompts apply to new conversations and support up to 8,000 characters each. In the Reader prompt, {{reference}} is replaced with the current paper; if removed, Rubien appends that context.",
                bundle: .module
            ))
        }
    }

    @ViewBuilder
    private func assistantPromptEditor(
        title: String,
        text: Binding<String>,
        isEditing: Binding<Bool>,
        defaultPrompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(text.wrappedValue.count)/\(AssistantContext.promptCharacterLimit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "\(text.wrappedValue.count) of \(AssistantContext.promptCharacterLimit) characters"
                    )
                Button(String(localized: "Reset to Default", bundle: .module)) {
                    text.wrappedValue = defaultPrompt
                    promptSaveTask?.cancel()
                    persistPromptOverrides()
                }
                .buttonStyle(SettingsActionButtonStyle())
                .accessibilityLabel("Reset \(title) prompt to default")
                Button(String(
                    localized: isEditing.wrappedValue ? "Done" : "Edit",
                    bundle: .module
                )) {
                    if isEditing.wrappedValue {
                        promptSaveTask?.cancel()
                        persistPromptOverrides()
                    }
                    isEditing.wrappedValue.toggle()
                }
                .buttonStyle(SettingsActionButtonStyle())
                .accessibilityLabel(
                    isEditing.wrappedValue
                        ? "Finish editing \(title) prompt"
                        : "Edit \(title) prompt"
                )
            }
            Group {
                if isEditing.wrappedValue {
                    TextEditor(text: Binding(
                        get: { text.wrappedValue },
                        set: {
                            let limited = AssistantContext.limitedPrompt($0)
                            text.wrappedValue = limited
                        }
                    ))
                    .scrollContentBackground(.hidden)
                } else {
                    ScrollView {
                        Text(text.wrappedValue)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
                .font(.body)
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(minHeight: 96, maxHeight: 120)
                .padding(4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(title)
        }
    }

    private func schedulePromptSave() {
        promptSaveTask?.cancel()
        promptSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            persistPromptOverrides()
        }
    }

    private func persistPromptOverrides() {
        let effectiveLibraryPrompt = AssistantContext.effectivePrompt(
            libraryPrompt,
            for: .library)
        let effectiveReaderPrompt = AssistantContext.effectivePrompt(
            readerPrompt,
            for: .reader)
        if libraryPrompt != effectiveLibraryPrompt {
            libraryPrompt = effectiveLibraryPrompt
        }
        if readerPrompt != effectiveReaderPrompt {
            readerPrompt = effectiveReaderPrompt
        }
        RubienPreferences.assistantLibraryPromptOverride = effectiveLibraryPrompt
        RubienPreferences.assistantReaderPromptOverride = effectiveReaderPrompt
    }

    private var assistantClaudeCLISection: some View {
        Section {
            claudeStatusRow
            agentBinaryPathRow(override: binaryPathOverride, onReset: {
                RubienPreferences.assistantBinaryPath = nil
                binaryPathOverride = ""
                recheckClaude()
            }, onChoose: pickBinary, disabled: isProbingClaude)
        } header: {
            Text(String(localized: "Claude Code CLI", bundle: .module))
        }
    }

    private var assistantCodexCLISection: some View {
        Section {
            codexStatusRow
            agentBinaryPathRow(override: codexBinaryPathOverride, onReset: {
                RubienPreferences.assistantCodexBinaryPath = nil
                codexBinaryPathOverride = ""
                recheckCodex()
            }, onChoose: pickCodexBinary, disabled: isProbingCodex)
        } header: {
            Text(String(localized: "Codex CLI", bundle: .module))
        } footer: {
            // Privacy disclosure: Codex persists conversations itself (under ~/.codex),
            // outside Rubien — the non-obvious fact worth surfacing before first use.
            Text(String(localized: "Codex uses your ~/.codex account and stores conversations there, not in Rubien.", bundle: .module))
        }
    }

    private var claudeStatusRow: some View {
        agentStatusRow(name: String(localized: "Claude Code", bundle: .module),
                       availability: claudeAvailability,
                       isProbing: isProbingClaude,
                       recheck: recheckClaude)
    }

    private var codexStatusRow: some View {
        agentStatusRow(name: String(localized: "Codex", bundle: .module),
                       availability: codexAvailability,
                       isProbing: isProbingCodex,
                       recheck: recheckCodex)
    }

    /// The shared availability row for either backend's CLI section (icon + title +
    /// resolved path / reason + Recheck) — Claude and Codex differ only by name +
    /// state source.
    @ViewBuilder
    private func agentStatusRow(
        name: String,
        availability: AgentAvailability?,
        isProbing: Bool,
        recheck: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            if isProbing {
                ProgressView().controlSize(.small)
                Text(String(localized: "Checking…", bundle: .module))
                    .foregroundStyle(.secondary)
            } else if let availability {
                Image(systemName: availability.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(availability.isReady ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agentStatusTitle(name: name, availability: availability))
                    // Show the resolved path whenever one was found — including the
                    // installed-but-not-signed-in state — so a user with multiple installs
                    // can see WHICH binary Rubien probed before running the login it suggests.
                    if let path = availability.resolvedPath {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !availability.isReady, let reason = availability.unavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(String(localized: "Not checked yet", bundle: .module))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Recheck", bundle: .module)) { recheck() }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(isProbing)
        }
    }

    /// The shared "Binary path / Auto-discovered / Reset / Choose…" row for either
    /// backend's CLI section — they differ only by the mirror + the two actions.
    @ViewBuilder
    private func agentBinaryPathRow(
        override: String,
        onReset: @escaping () -> Void,
        onChoose: @escaping () -> Void,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "Binary path", bundle: .module))
            Spacer()
            Text(override.isEmpty
                 ? String(localized: "Auto-discovered", bundle: .module)
                 : (override as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !override.isEmpty {
                Button(String(localized: "Reset", bundle: .module), action: onReset)
                    .buttonStyle(SettingsActionButtonStyle())
                    .disabled(disabled)
            }
            Button(String(localized: "Choose…", bundle: .module), action: onChoose)
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(disabled)
        }
    }

    // MARK: Assistant pane — bindings & helpers

    /// The effective working folder: the override if set, else the default — the one
    /// resolver owns the empty→default rule (`workspacePathOverride` mirrors the pref
    /// so this still re-renders when the picker/reset buttons change it).
    private var effectiveWorkspacePath: String {
        AssistantContext.workspaceURL(override: workspacePathOverride).path
    }

    private func agentStatusTitle(name: String, availability: AgentAvailability) -> String {
        guard availability.isInstalled else {
            return String(format: String(localized: "%@ not found", bundle: .module), name)
        }
        guard availability.isAuthenticated else {
            return String(format: String(localized: "%@ not signed in", bundle: .module), name)
        }
        if let version = availability.version {
            return String(format: String(localized: "%@ %@ ready", bundle: .module), name, version)
        }
        return String(format: String(localized: "%@ ready", bundle: .module), name)
    }

    /// Re-probe the CLI with the current binary-path override. Only a success is
    /// cached inside the provider, so a fresh instance each time re-checks a
    /// previously-missing binary (after an install / path change). The generation
    /// token lets a later probe (e.g. a Reset firing while a Choose probe is still
    /// running) supersede an earlier one, so only the latest result is shown.
    private func recheckClaude() {
        probeGeneration += 1
        let generation = probeGeneration
        isProbingClaude = true
        let override = RubienPreferences.assistantBinaryPath
        Task {
            guard await prepareSettingsAssistantExecution() else {
                claudeAvailability = .notFound(
                    reason: AssistantExecutionOwnership.shared.unavailableReason
                        ?? "Assistant execution is owned by another Rubien process."
                )
                isProbingClaude = false
                return
            }
            let availability = await ClaudeCodeProvider(executableOverride: override).isAvailable()
            guard generation == probeGeneration else { return }  // superseded by a newer probe
            claudeAvailability = availability
            isProbingClaude = false
        }
    }

    /// Codex's parallel probe (its own generation token + binary override).
    ///
    /// Keep the lightweight version/auth checks and the app-server model lookup in
    /// ONE ordered task. On first Settings open these used to run concurrently (and
    /// `.task` also launched a redundant catalog lookup), so a cold codex install
    /// could spend the version probe's five-second budget contending with plugin and
    /// model initialization, report "not found", then succeed immediately on Recheck.
    private func recheckCodex() {
        codexProbeGeneration += 1
        codexCatalogLoadGeneration += 1
        let probeGeneration = codexProbeGeneration
        let catalogGeneration = codexCatalogLoadGeneration
        isProbingCodex = true
        let override = RubienPreferences.assistantCodexBinaryPath
        Task { @MainActor in
            guard await prepareSettingsAssistantExecution() else {
                codexAvailability = .notFound(
                    reason: AssistantExecutionOwnership.shared.unavailableReason
                        ?? "Assistant execution is owned by another Rubien process."
                )
                codexCatalogModels = []
                isProbingCodex = false
                return
            }
            let availability = await CodexProvider(
                executableOverride: override,
                contentChannel: MCPContentChannel.resolveBundled(),
                shareAppServer: true
            ).isAvailable()
            guard probeGeneration == codexProbeGeneration else { return }
            codexAvailability = availability

            guard availability.isInstalled else {
                // Do not launch a heavier app-server after the binary itself failed
                // its bounded probe. It cannot yield a usable catalog and would make
                // an immediate Reset/Choose retry contend with the failed attempt.
                codexCatalogModels = []
                isProbingCodex = false
                return
            }

            let models = await CodexModelCatalog.shared
                .catalog(executableOverride: override, forceReload: true)
                .visibleModels
            guard probeGeneration == codexProbeGeneration else { return }
            guard catalogGeneration == codexCatalogLoadGeneration else {
                // A standalone catalog refresh superseded only this second phase;
                // this probe still owns the availability spinner.
                isProbingCodex = false
                return
            }
            codexCatalogModels = models
            isProbingCodex = false
        }
    }

    /// Fetch a memoized codex model catalog when the pane is revisited after an
    /// earlier unavailable/empty lookup. Recheck performs its forced reload in the
    /// ordered availability task above.
    private func loadCodexCatalog() {
        codexCatalogLoadGeneration += 1
        let generation = codexCatalogLoadGeneration
        let override = RubienPreferences.assistantCodexBinaryPath
        Task { @MainActor in
            guard await prepareSettingsAssistantExecution() else {
                codexCatalogModels = []
                return
            }
            let models = await CodexModelCatalog.shared
                .catalog(executableOverride: override)
                .visibleModels
            guard generation == codexCatalogLoadGeneration else { return }  // superseded by a newer load
            codexCatalogModels = models
        }
    }

    private func prepareSettingsAssistantExecution() async -> Bool {
        await AssistantExecutionOwnership.shared.prepareIfNeededAsync(
            database: .shared
        )
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose", bundle: .module)
        panel.directoryURL = RubienPreferences.assistantWorkspaceURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RubienPreferences.assistantWorkspacePath = url.path
        workspacePathOverride = url.path
    }

    private func pickBinary() {
        pickAgentBinary { path in
            RubienPreferences.assistantBinaryPath = path
            binaryPathOverride = path
            recheckClaude()
        }
    }

    private func pickCodexBinary() {
        pickAgentBinary { path in
            RubienPreferences.assistantCodexBinaryPath = path
            codexBinaryPathOverride = path
            recheckCodex()
        }
    }

    /// The shared "choose an executable" open panel; `assign` persists the picked
    /// path + re-probes for whichever backend invoked it.
    private func pickAgentBinary(assign: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: .module)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assign(url.path)
    }
}

/// A small text action button for the Settings forms: plain text at rest (no
/// border), a subtle rounded highlight only on mouse-hover, a touch more on press —
/// the same idiom as the sidebar's model/effort menu button (`HeaderControlButtonStyle`).
/// The stock `.bordered` / `.automatic` button gave no visible hover feedback on
/// macOS, and a persistent border read as heavier than a form action needs.
private struct SettingsActionButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.10)
                          : (hovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
