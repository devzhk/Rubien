import SwiftUI
import RubienSync

@available(macOS 14.0, *)
struct RubienSettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        TabView {
            iCloudSyncPane
                .tabItem {
                    Label(
                        String(localized: "iCloud Sync", bundle: .module),
                        systemImage: "icloud"
                    )
                }
        }
        .frame(width: 480, height: 320)
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
            } footer: {
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}
