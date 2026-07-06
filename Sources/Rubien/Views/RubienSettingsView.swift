#if os(macOS)
import AppKit
import SwiftUI
import RubienCore
import RubienSync

struct RubienSettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var cacheBytes: Int64 = 0
    @State private var backfillRemaining: Int = 0

    // Assistant pane (Phase 2c-5). Availability probe + mirrors of the two path
    // overrides (RubienPreferences isn't observable, so the "Choose…" buttons keep
    // these in sync to re-render the displayed path).
    @State private var claudeAvailability: AgentAvailability?
    @State private var isProbingClaude = false
    /// Monotonic probe token: only the latest `recheckClaude` result is applied, so a
    /// Reset/Choose that supersedes an in-flight probe can't be overwritten by the
    /// stale one landing late.
    @State private var probeGeneration = 0
    @State private var workspacePathOverride = ""
    @State private var binaryPathOverride = ""
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
                        systemImage: "sparkles"
                    )
                }
            iCloudSyncPane
                .tabItem {
                    Label(
                        String(localized: "iCloud Sync", bundle: .module),
                        systemImage: "icloud"
                    )
                }
            #if canImport(Sparkle)
            UpdateSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.down.circle")
                }
            #endif
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
            assistantCLISection
        }
        .formStyle(.grouped)
        .task {
            workspacePathOverride = RubienPreferences.assistantWorkspacePath ?? ""
            binaryPathOverride = RubienPreferences.assistantBinaryPath ?? ""
            if claudeAvailability == nil { recheckClaude() }
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
                    .controlSize(.small)
                }
                Button(String(localized: "Choose…", bundle: .module)) { pickWorkspace() }
                    .controlSize(.small)
            }
        } header: {
            Text(String(localized: "Working folder", bundle: .module))
        } footer: {
            Text(String(localized: "The assistant works in this folder — its scratch space and any files it writes. Newly opened documents use it as their working directory.", bundle: .module))
        }
    }

    private var assistantDefaultsSection: some View {
        Section {
            Picker(selection: assistantModelBinding) {
                ForEach(AssistantModelOptions.models, id: \.value) { Text($0.label).tag($0.value) }
            } label: {
                Text(String(localized: "Model", bundle: .module))
            }

            Picker(selection: assistantEffortBinding) {
                ForEach(AssistantModelOptions.efforts, id: \.value) { Text($0.label).tag($0.value) }
            } label: {
                Text(String(localized: "Reasoning effort", bundle: .module))
            }

            Toggle(isOn: assistantWebBinding) {
                Text(String(localized: "Web search", bundle: .module))
            }

            Picker(selection: assistantApprovalBinding) {
                Text(String(localized: "Ask before writes", bundle: .module)).tag(false)
                Text(String(localized: "Auto-accept actions", bundle: .module)).tag(true)
            } label: {
                Text(String(localized: "Approvals", bundle: .module))
            }
        } header: {
            Text(String(localized: "Defaults for new conversations", bundle: .module))
        } footer: {
            Text(String(localized: "Applied when you open a document; each conversation can still change them in the sidebar. Web search lets the assistant fetch pages you didn’t open. Auto-accept runs its writes and shell commands without asking first.", bundle: .module))
        }
    }

    private var assistantCLISection: some View {
        Section {
            claudeStatusRow
            HStack(spacing: 8) {
                Text(String(localized: "Binary path", bundle: .module))
                Spacer()
                Text(binaryPathOverride.isEmpty
                     ? String(localized: "Auto-discovered", bundle: .module)
                     : (binaryPathOverride as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !binaryPathOverride.isEmpty {
                    Button(String(localized: "Reset", bundle: .module)) {
                        RubienPreferences.assistantBinaryPath = nil
                        binaryPathOverride = ""
                        recheckClaude()
                    }
                    .controlSize(.small)
                }
                Button(String(localized: "Choose…", bundle: .module)) { pickBinary() }
                    .controlSize(.small)
            }
        } header: {
            Text(String(localized: "Claude Code CLI", bundle: .module))
        } footer: {
            Text(String(localized: "Not signed in? Run “claude login” in Terminal. Codex support arrives in a later update.", bundle: .module))
        }
    }

    @ViewBuilder
    private var claudeStatusRow: some View {
        HStack(spacing: 8) {
            if isProbingClaude {
                ProgressView().controlSize(.small)
                Text(String(localized: "Checking…", bundle: .module))
                    .foregroundStyle(.secondary)
            } else if let availability = claudeAvailability {
                Image(systemName: availability.isInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(availability.isInstalled ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(claudeStatusTitle(availability))
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
            Button(String(localized: "Recheck", bundle: .module)) { recheckClaude() }
                .controlSize(.small)
                .disabled(isProbingClaude)
        }
    }

    // MARK: Assistant pane — bindings & helpers

    /// The effective working folder: the override if set, else the default — the one
    /// resolver owns the empty→default rule (`workspacePathOverride` mirrors the pref
    /// so this still re-renders when the picker/reset buttons change it).
    private var effectiveWorkspacePath: String {
        AssistantContext.workspaceURL(override: workspacePathOverride).path
    }

    private var assistantModelBinding: Binding<String> {
        Binding(get: { RubienPreferences.assistantModel },
                set: { RubienPreferences.assistantModel = $0 })
    }

    private var assistantEffortBinding: Binding<String> {
        Binding(get: { RubienPreferences.assistantEffort },
                set: { RubienPreferences.assistantEffort = $0 })
    }

    private var assistantWebBinding: Binding<Bool> {
        Binding(get: { RubienPreferences.assistantWebAccess },
                set: { RubienPreferences.assistantWebAccess = $0 })
    }

    private var assistantApprovalBinding: Binding<Bool> {
        Binding(get: { RubienPreferences.assistantAutoApprove },
                set: { RubienPreferences.assistantAutoApprove = $0 })
    }

    private func claudeStatusTitle(_ availability: AgentAvailability) -> String {
        guard availability.isInstalled else {
            return String(localized: "Claude Code not found", bundle: .module)
        }
        if let version = availability.version {
            return String(format: String(localized: "Claude Code %@ installed", bundle: .module), version)
        }
        return String(localized: "Claude Code installed", bundle: .module)
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: .module)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RubienPreferences.assistantBinaryPath = url.path
        binaryPathOverride = url.path
        recheckClaude()
    }
}
#endif
