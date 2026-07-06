#if canImport(Sparkle)
import SwiftUI

/// The "Software Update" section shown inside the **General** settings pane (folded
/// in from a former standalone Updates tab). Surfaces every user-facing update
/// control:
///   - current app version
///   - automatic-check / automatic-download toggles
///   - "Last checked" status with an on-demand "Check Now" button
///   - "Install and Relaunch…" action when an update is pending
///
/// Reads `UpdateController` from the environment. The toggles are bound via
/// `@Bindable` so they push straight back into the controller's
/// `automaticallyChecks` / `automaticallyDownloads` accessors, which in turn write
/// to the underlying `SPUUpdater`. Renders a bare `Section`, so it composes into the
/// host `Form` (`.formStyle(.grouped)`) rather than owning its own.
struct UpdateSettingsSection: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        @Bindable var updaterBinding = updater

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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "Rubien \(short) (Beta)"
    }

    private var lastCheckedLabel: String {
        guard let date = updater.lastCheckDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
#endif
