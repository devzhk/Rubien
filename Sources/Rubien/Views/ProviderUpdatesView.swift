#if os(macOS)
import SwiftUI
import AppKit

struct ProviderUpdatesView: View {
    @ObservedObject var model: ProviderUpdateModel
    @State private var showingInstructions = false
    @ObservedObject private var action: ProviderUpdateActionModel
    init(model: ProviderUpdateModel) {
        self.model = model
        self.action = .shared(model.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates").font(.subheadline.weight(.semibold))
            if let result = model.record.snapshot {
                if result.hasNewerRelease {
                    Text("New release available: \(result.availableVersion)").font(.subheadline.weight(.medium))
                    Text("Installed: \(result.installedVersion)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Installed: \(result.installedVersion) · Latest: \(result.availableVersion)")
                        .font(.caption)
                    Text("No newer release found at the last check.").font(.caption).foregroundStyle(.secondary)
                }
                Text(result.source.label).font(.caption).foregroundStyle(.secondary)
                Text("Last checked: \(result.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if !result.source.allowsReleaseNotice {
                    Text("The provider manages native updates. The latest release may differ from your selected channel or version policy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.isChecking, model.detail == nil, model.record.lastError == nil {
                Text("Releases have not been checked yet.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.record.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                if model.record.snapshot != nil {
                    Text("The versions above are from the previous successful check.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let detail = model.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { model.record.automaticChecks }, set: { enabled in
                    model.setAutomaticChecks(enabled)
                    if enabled { Task { await model.check() } }
                }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(model.installation?.state != .found)
            if let message = action.stage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let explanation = action.explanation {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            if action.plan?.allowsAutomaticInstall == true {
                Toggle("Install updates automatically when idle", isOn: Binding(
                    get: { action.policy.enabled }, set: { action.setAutomatic($0) }))
                    .toggleStyle(.checkbox).font(.caption).disabled(action.isRunning)
                Text("Updates the shared CLI used by Terminal and other apps. Rubien waits for conversations to finish.")
                    .font(.caption).foregroundStyle(.secondary)
                if action.policy.suspended {
                    Text("Automatic updates paused after repeated failures. Re-enable them after checking the installation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.isChecking ? "Checking for updates…" : "Check for updates") {
                    Task { await model.check(manual: true) }
                }.disabled(model.isChecking || action.isRunning)
                if action.canUpdate {
                    Button("Update…") { showingInstructions = true }
                } else if model.record.snapshot?.hasNewerRelease == true && !action.isRunning {
                    Button("Update instructions") { showingInstructions = true }
                }
                if action.canCancel { Button("Cancel") { action.cancel() } }
                if model.isChecking || action.isRunning { ProgressView().controlSize(.small) }
            }
            if !action.output.isEmpty {
                DisclosureGroup("Update details") {
                    ScrollView {
                        Text(action.output).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 160)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(SettingsActionButtonStyle())
        .task {
            await model.check()
            await prepareAction()
        }
        .onChange(of: model.record.snapshot) { _, _ in Task { await prepareAction() } }
        .sheet(isPresented: $showingInstructions) { ProviderUpdateInstructions(model: model) }
    }
    private func prepareAction() async {
        await action.prepare(installation: model.installation, snapshot: model.record.snapshot)
    }
}

struct ProviderUpdateInstructions: View {
    @ObservedObject var model: ProviderUpdateModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @ObservedObject private var action: ProviderUpdateActionModel
    init(model: ProviderUpdateModel) {
        self.model = model
        self.action = .shared(model.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update \(model.provider.setupName)").font(.title2.bold())
            if let result = model.record.snapshot {
                Text("Installed \(result.installedVersion) · Latest \(result.availableVersion)")
                if let plan = action.plan, action.canUpdate {
                    Text("This updates your shared \(model.provider.setupName) installation, also used by Terminal and other apps.")
                    Text("Rubien will run").font(.caption.weight(.semibold))
                    Text(plan.method == .codexNative ? model.provider.installProcedure : plan.command)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if plan.needsUsageExclusion {
                        Text("Running conversations finish first. New conversations wait while the update is applied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let command = result.source.updateCommand {
                    Text("Run this command in Terminal using the same package manager and environment that installed this executable.")
                    Text(command).font(.body.monospaced()).textSelection(.enabled)
                    Text("This is general guidance. Your registry, release channel, or version pins may select a different version.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                } else {
                    Text("Use the provider’s official update instructions for your installation and release channel.")
                }
            }
            if let path = model.installation?.path {
                Text("Executable used by Rubien").font(.caption.weight(.medium))
                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Official update instructions", destination: model.provider.setupDocumentationURL)
            Text(action.plan != nil
                 ? "Rubien refreshes the installed version and model list after updating."
                 : "After updating in Terminal, click Recheck in Assistant settings to refresh the installed version and model list.")
                .font(.callout)
            if let stage = action.stage {
                HStack {
                    if action.isRunning { ProgressView().controlSize(.small) }
                    Text(stage).font(.callout)
                }
            }
            if let explanation = action.explanation {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            if !action.output.isEmpty {
                DisclosureGroup("Update details") {
                    ScrollView {
                        Text(action.output).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 160)
                }
            }
            HStack {
                Spacer()
                if action.canCancel { Button("Cancel update") { action.cancel() } }
                Button("Close") { dismiss() }
                if action.canUpdate {
                    Button("Update now") { action.update(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .buttonStyle(SettingsActionButtonStyle())
        .task { await action.prepare(installation: model.installation, snapshot: model.record.snapshot) }
    }
}

/// An overlay leaves the window's toolbar and sidebar layout untouched.
struct ProviderUpdateNotices: View {
    @ObservedObject private var codex = ProviderUpdateModel.codex
    @ObservedObject private var claude = ProviderUpdateModel.claude

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            if showsVisualPreview {
                ProviderUpdateNotice(model: codex, visualPreview: true)
            } else {
                ProviderUpdateNotice(model: codex)
                ProviderUpdateNotice(model: claude)
            }
        }
        .padding(12)
        .padding(.top, 32)
    }

    private var showsVisualPreview: Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier == "com.rubien.provider-setup-preview"
            && ProcessInfo.processInfo.arguments.contains("--preview-provider-update-notice")
        #else
        return false
        #endif
    }
}

private struct ProviderUpdateNotice: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var model: ProviderUpdateModel
    @ObservedObject private var action: ProviderUpdateActionModel
    var visualPreview = false
    @State private var showingInstructions = false
    @State private var previewDismissed = false
    @State private var preparingAction = true
    @State private var updateRequested = false

    init(model: ProviderUpdateModel, visualPreview: Bool = false) {
        self.model = model
        self.action = .shared(model.provider)
        self.visualPreview = visualPreview
    }

    var body: some View {
        if !previewDismissed, visualPreview || model.notice != nil || action.presentedPlan != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor.mixedTowardWhite(by: 0.12))
                        .saturation(0.60)
                        .accessibilityHidden(true)
                    Text(action.presentedPlan != nil && !visualPreview
                         ? "\(model.provider.setupName) update"
                         : "New \(model.provider.setupName) release available").font(.headline)
                }
                Text("Installed \(visualPreview ? "0.153.4" : action.presentedPlan?.previousVersion ?? model.notice?.installedVersion ?? "") · Latest \(visualPreview ? "0.160.0" : action.presentedPlan?.targetVersion ?? model.notice?.availableVersion ?? "")").font(.callout)
                if visualPreview {
                    Text("Visual preview · sample versions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if updateRequested || action.presentedPlan != nil {
                    HStack(spacing: 8) {
                        if action.isRunning && !visualPreview { ProgressView().controlSize(.small) }
                        Text(visualPreview ? "Preview only — no update was run." : action.stage ?? "Preparing update…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    if visualPreview || action.canUpdate || preparingAction || action.isRunning {
                        Button(action.isRunning && !visualPreview ? "Updating…" : "Update now") {
                            updateRequested = true
                            if !visualPreview { action.update() }
                        }
                        .buttonStyle(ProviderUpdateButtonStyle())
                        .disabled(!visualPreview && (preparingAction || !action.canUpdate))
                        .help("Update the shared CLI used by Rubien and Terminal")
                    }
                    Button(visualPreview || action.canUpdate || preparingAction || action.presentedPlan != nil
                           ? "Details" : "Update instructions") { showingInstructions = true }
                        .buttonStyle(SettingsActionButtonStyle())
                        .help("Review the versions, update command, and instructions")
                    if action.canCancel && !visualPreview {
                        Button("Cancel") { action.cancel() }
                            .buttonStyle(SettingsActionButtonStyle())
                    }
                    Button(action.presentedPlan == nil || visualPreview ? "Later" : "Dismiss") {
                        if visualPreview { previewDismissed = true }
                        else if action.presentedPlan != nil {
                            action.dismissProgress()
                            model.dismissNotice()
                        } else { model.later() }
                    }
                        .buttonStyle(SettingsActionButtonStyle())
                        .disabled(action.isRunning && !visualPreview)
                        .help(action.presentedPlan == nil || visualPreview
                              ? "Remind me about this version in seven days" : "Dismiss the update result")
                }
            }
            .padding(14)
            .frame(maxWidth: 380, alignment: .leading)
            .background { noticeSurface }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.15),
                                Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.18),
                                Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.15),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .task { await prepareAction() }
            .onChange(of: model.record.snapshot) { _, _ in Task { await prepareAction() } }
            .sheet(isPresented: $showingInstructions) {
                if visualPreview {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Update notice preview").font(.headline)
                        Text("These are sample versions for checking the notice’s appearance. No update will run.")
                        Button("Close") { showingInstructions = false }
                    }
                    .padding(24)
                    .frame(width: 360)
                } else {
                    ProviderUpdateInstructions(model: model)
                }
            }
        }
    }

    private var noticeSurface: some View {
        ZStack {
            if #available(macOS 26.0, *), !reduceTransparency {
                GlassEffectView(cornerRadius: 12)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
        }
        .allowsHitTesting(false)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.09), radius: 9, y: 4)
        .shadow(color: Color.accentColor.opacity(0.10), radius: 11)
    }

    private func prepareAction() async {
        guard !visualPreview else { preparingAction = false; return }
        preparingAction = true
        await action.prepare(installation: model.installation, snapshot: model.record.snapshot)
        preparingAction = false
    }
}

private struct ProviderUpdateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.mixedTowardWhite(by: 0.12))
                    .saturation(0.60)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(isEnabled
                                ? (configuration.isPressed ? 0.32 : (hovered ? 0.22 : 0)) : 0))
                    }
            }
            .shadow(color: Color.accentColor.opacity(isEnabled && hovered ? 0.22 : 0), radius: 3, y: 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
#endif
