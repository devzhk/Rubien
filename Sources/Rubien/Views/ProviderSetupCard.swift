#if os(macOS)
import SwiftUI
import AppKit

struct ProviderSetupCard: View {
    @ObservedObject var model: ProviderSetupModel
    var onChecked: ((AgentAvailability?) -> Void)?
    @State private var showingProcedure = false
    @State private var showingOutput = false
    @State private var selectedOverride = ""
    @ObservedObject private var updateAction: ProviderUpdateActionModel

    init(model: ProviderSetupModel, onChecked: ((AgentAvailability?) -> Void)? = nil) {
        self.model = model
        self.onChecked = onChecked
        self.updateAction = .shared(model.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.provider.setupName).font(.headline)
                Spacer()
                if model.activity != nil { ProgressView().controlSize(.small) }
            }
            Text(status).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let found = model.installation {
                if let path = found.path {
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                    Text(found.hint.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                if let detail = found.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            if let message = model.message {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if model.installation?.canInstall == true {
                Text("Installs the official CLI for your macOS account, shared with Terminal and other apps. Sign-in is a separate step.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Official terminal command").font(.caption.weight(.medium))
                Text(model.provider.officialInstallCommand).font(.caption.monospaced())
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install") { model.install() }.buttonStyle(.borderedProminent).disabled(!model.canInstall)
                    Button("Copy command") { copy(model.provider.officialInstallCommand) }
                    Link("Official instructions", destination: model.provider.setupDocumentationURL)
                }
                DisclosureGroup("What Rubien will run", isExpanded: $showingProcedure) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rubien downloads the complete script, validates it, then runs it without a terminal. The temporary folder is created when you click Install.")
                        Text(model.provider.installProcedure).font(.caption.monospaced()).textSelection(.enabled)
                    }.font(.caption).padding(.top, 4)
                }
            }
            if model.canSignIn || model.activity == .signingIn {
                Text(model.loginCommand).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Sign in") { model.signIn() }.buttonStyle(.borderedProminent).disabled(!model.canSignIn)
                    Button("Copy sign-in command") { copy(model.loginCommand) }
                }
                Text("Uses your existing account. If a browser doesn’t open, cancel and run this command in Terminal, then recheck.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Recheck") { Task { await model.refresh() } }.disabled(model.activity != nil || updateAction.isRunning)
                Button("Choose executable…") { chooseExecutable() }.disabled(model.activity != nil || updateAction.isRunning)
                if model.canCancel { Button("Cancel") { model.cancel() } }
            }
            if !selectedOverride.isEmpty {
                Button("Use automatic discovery") { setOverride(nil) }.disabled(model.activity != nil || updateAction.isRunning)
            }
            if model.installation?.state == .found {
                Divider().padding(.vertical, 4)
                ProviderUpdatesView(model: .shared(model.provider))
                    .onChange(of: model.completedChecks) { _, _ in
                        Task { await ProviderUpdateModel.shared(model.provider).check() }
                    }
            }
            if let procedure = model.concreteProcedure {
                DisclosureGroup("Operation details") {
                    Text(procedure).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.diagnostics.isEmpty {
                DisclosureGroup("Installer output", isExpanded: $showingOutput) {
                    ScrollView { Text(model.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 160)
                }
            }
        }
        .buttonStyle(SettingsActionButtonStyle())
        .padding(.vertical, 6)
        .task {
            selectedOverride = model.override ?? ""
            let checks = model.completedChecks
            await model.refresh(force: false)
            if model.completedChecks == checks { onChecked?(model.availability) }
        }
        .onChange(of: model.completedChecks) { _, _ in onChecked?(model.availability) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh(force: false) }
        }
    }

    private var status: String {
        if let activity = model.activity { return activity.title }
        guard let found = model.installation else { return "Not checked yet" }
        if found.canInstall { return "Not installed" }
        guard found.state == .found else { return "Needs attention" }
        guard let availability = model.availability, availability.isInstalled else {
            return model.availability?.unavailableReason ?? "Found an executable, but it could not be verified."
        }
        if availability.isReady { return "Ready" + (availability.version.map { " · \($0)" } ?? "") }
        return availability.unavailableReason ?? "Installed · Sign in to continue"
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private func setOverride(_ path: String?) {
        if model.provider == .codex { RubienPreferences.assistantCodexBinaryPath = path }
        else { RubienPreferences.assistantBinaryPath = path }
        selectedOverride = path ?? ""
        updateAction.invalidateSelection()
        ProviderUpdateModel.shared(model.provider).invalidateSelection()
        Task { await model.refresh() }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setOverride(url.path)
    }
}

struct AssistantSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up your assistant").font(.title2.bold())
            Text("Choose Codex or Claude Code. You can keep using your library without setting up an assistant.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 16) {
                    ProviderSetupCard(model: .codex)
                    Divider()
                    ProviderSetupCard(model: .claude)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580, height: 600)
    }
}
#endif
