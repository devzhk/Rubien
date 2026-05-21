#if canImport(Sparkle)
import SwiftUI

/// Settings pane that surfaces every user-facing update control:
///   - current app version
///   - automatic-check / automatic-download toggles
///   - "Last checked" status with an on-demand "Check Now" button
///   - "Install and Relaunch…" action when an update is pending
///
/// Reads `UpdateController` from the environment. The toggles are bound
/// via `@Bindable` so they push straight back into the controller's
/// `automaticallyChecks` / `automaticallyDownloads` accessors, which in
/// turn write to the underlying `SPUUpdater`.
struct UpdateSettingsView: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        @Bindable var updaterBinding = updater

        Form {
            Section("Software Update") {
                LabeledContent("Current version") {
                    Text(versionLabel)
                        .foregroundStyle(.secondary)
                }

                Toggle("Automatically check for updates", isOn: $updaterBinding.automaticallyChecks)
                Toggle("Automatically download updates", isOn: $updaterBinding.automaticallyDownloads)

                HStack {
                    Text("Last checked")
                    Spacer()
                    Text(lastCheckedLabel)
                        .foregroundStyle(.secondary)
                    Button("Check Now") { updater.checkNow() }
                        .disabled(!updater.canCheckForUpdates)
                }

                if updater.updateReadyToInstall {
                    HStack {
                        Text("Update \(updater.pendingVersion ?? "—") ready to install")
                        Spacer()
                        Button("Install and Relaunch…") { updater.installAndRelaunch() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "Rubien \(short) (Alpha)"
    }

    private var lastCheckedLabel: String {
        guard let date = updater.lastCheckDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
#endif
