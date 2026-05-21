#if canImport(Sparkle)
import SwiftUI

/// Toolbar badge that becomes visible once `UpdateController` flips
/// `updateReadyToInstall` to true. Tapping it triggers the install-and-relaunch
/// flow. At rest (no update pending) the view renders nothing, so it does not
/// disturb the layout of neighboring toolbar items.
struct UpdateIndicator: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        if updater.updateReadyToInstall {
            Button {
                updater.installAndRelaunch()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
            }
            .help("Update to \(updater.pendingVersion ?? "—") ready — click to install and relaunch")
            .accessibilityLabel("Install update and relaunch")
        }
    }
}
#endif
