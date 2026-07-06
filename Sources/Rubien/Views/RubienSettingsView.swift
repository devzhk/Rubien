#if os(macOS)
import AppKit
import SwiftUI
import RubienCore
import RubienSync

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
    @State private var defaultCodexSandbox: CodexSandbox = .readOnly
    @State private var defaultWebAccess = true
    @State private var defaultAutoApprove = false
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
            iCloudSyncPane
                .tabItem {
                    Label(
                        String(localized: "iCloud Sync", bundle: .module),
                        systemImage: "icloud"
                    )
                }
        }
        .frame(width: 540, height: 460)
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
            seedModelEffortMirrors(for: defaultProvider)
            if claudeAvailability == nil { recheckClaude() }
            if codexAvailability == nil { recheckCodex() }
        }
        // Persist each mirror to the (non-observable) prefs when the user changes it.
        // Switching the default backend re-seeds the model/effort mirrors from that
        // backend's own prefs (Claude/Codex slugs are disjoint).
        .onChange(of: defaultProvider) { _, value in
            RubienPreferences.assistantProvider = value
            seedModelEffortMirrors(for: value)
        }
        .onChange(of: defaultModel) { _, value in setDefaultModel(value) }
        .onChange(of: defaultEffort) { _, value in setDefaultEffort(value) }
        .onChange(of: defaultCodexSandbox) { _, value in RubienPreferences.assistantCodexSandbox = value }
        .onChange(of: defaultWebAccess) { _, value in RubienPreferences.assistantWebAccess = value }
        .onChange(of: defaultAutoApprove) { _, value in RubienPreferences.assistantAutoApprove = value }
    }

    /// Re-seed the model/effort mirrors from the selected default backend's prefs.
    /// Called on appear and whenever `defaultProvider` changes.
    private func seedModelEffortMirrors(for kind: AgentProviderKind) {
        switch kind {
        case .claude:
            defaultModel = RubienPreferences.assistantModel
            defaultEffort = RubienPreferences.assistantEffort
        case .codex:
            defaultModel = RubienPreferences.assistantCodexModel
            defaultEffort = RubienPreferences.assistantCodexEffort
        }
    }

    /// Route a model-mirror change back to the CURRENTLY-selected backend's pref.
    private func setDefaultModel(_ value: String) {
        switch defaultProvider {
        case .claude: RubienPreferences.assistantModel = value
        case .codex: RubienPreferences.assistantCodexModel = value
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

            // Model/effort are the SELECTED backend's — Claude and Codex accept
            // disjoint slugs, so the lists (and the mirrors) switch with the backend.
            Picker(selection: $defaultModel) {
                ForEach(AssistantModelOptions.models(for: defaultProvider), id: \.value) {
                    Text($0.label).tag($0.value)
                }
            } label: {
                Text(String(localized: "Model", bundle: .module))
            }

            Picker(selection: $defaultEffort) {
                ForEach(AssistantModelOptions.efforts(for: defaultProvider), id: \.value) {
                    Text($0.label).tag($0.value)
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

            Picker(selection: $defaultAutoApprove) {
                Text(String(localized: "Ask before writes", bundle: .module)).tag(false)
                Text(String(localized: "Auto-accept actions", bundle: .module)).tag(true)
            } label: {
                Text(String(localized: "Approvals", bundle: .module))
            }
        } header: {
            Text(String(localized: "Defaults for new conversations", bundle: .module))
        } footer: {
            Text(String(localized: "Used for each new conversation — a newly opened document, or “New conversation” in one already open. Each conversation can pick a backend and change these in its sidebar. Web search lets the assistant fetch pages you didn’t open. Auto-accept runs its writes and shell commands without asking first. Codex’s sandbox limits what a turn can touch on disk (Read-only still asks before any write).", bundle: .module))
        }
    }

    private var assistantClaudeCLISection: some View {
        Section {
            claudeStatusRow
            agentBinaryPathRow(override: binaryPathOverride, onReset: {
                RubienPreferences.assistantBinaryPath = nil
                binaryPathOverride = ""
                recheckClaude()
            }, onChoose: pickBinary)
        } header: {
            Text(String(localized: "Claude Code CLI", bundle: .module))
        } footer: {
            Text(String(localized: "Not signed in? Run “claude login” in Terminal.", bundle: .module))
        }
    }

    private var assistantCodexCLISection: some View {
        Section {
            codexStatusRow
            agentBinaryPathRow(override: codexBinaryPathOverride, onReset: {
                RubienPreferences.assistantCodexBinaryPath = nil
                codexBinaryPathOverride = ""
                recheckCodex()
            }, onChoose: pickCodexBinary)
        } header: {
            Text(String(localized: "Codex CLI", bundle: .module))
        } footer: {
            // The MCP posture (§4): Codex runs over your real ~/.codex, so it uses
            // the same account + any MCP servers you’ve configured there (its built-in
            // app connectors are dropped). Rubien’s own document tools are always added.
            Text(String(localized: "Not signed in? Run “codex login” in Terminal. Codex uses your ~/.codex account and any MCP servers configured there (plus Rubien’s document tools); its sessions are stored by Codex, not Rubien.", bundle: .module))
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
                Image(systemName: availability.isInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(availability.isInstalled ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agentStatusTitle(name: name, availability: availability))
                    if availability.isInstalled, let path = availability.resolvedPath {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if !availability.isInstalled, let reason = availability.unavailableReason {
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
        onChoose: @escaping () -> Void
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
            }
            Button(String(localized: "Choose…", bundle: .module), action: onChoose)
                .buttonStyle(SettingsActionButtonStyle())
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
        if let version = availability.version {
            return String(format: String(localized: "%@ %@ installed", bundle: .module), name, version)
        }
        return String(format: String(localized: "%@ installed", bundle: .module), name)
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
            let availability = await ClaudeCodeProvider(executableOverride: override).isAvailable()
            guard generation == probeGeneration else { return }  // superseded by a newer probe
            claudeAvailability = availability
            isProbingClaude = false
        }
    }

    /// Codex's parallel probe (its own generation token + binary override).
    private func recheckCodex() {
        codexProbeGeneration += 1
        let generation = codexProbeGeneration
        isProbingCodex = true
        let override = RubienPreferences.assistantCodexBinaryPath
        Task {
            let availability = await CodexProvider(executableOverride: override).isAvailable()
            guard generation == codexProbeGeneration else { return }  // superseded by a newer probe
            codexAvailability = availability
            isProbingCodex = false
        }
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
