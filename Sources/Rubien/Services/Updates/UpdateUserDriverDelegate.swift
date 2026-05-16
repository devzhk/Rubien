#if Sparkle
import Foundation
import Sparkle

/// Sparkle delegate that suppresses the framework's default update window
/// for *scheduled* background checks. User-initiated checks (via
/// `SPUUpdater.checkForUpdates()`) are intentionally NOT suppressed and
/// will fall through to Sparkle's standard interactive UI — the silent
/// path is reserved for the background-download UX.
@MainActor
final class UpdateUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Invoked when a scheduled update is ready. The string is the appcast
    /// item's `shortVersionString` (e.g., "0.1.1"). `UpdateController`
    /// observes this to flip its `updateReadyToInstall` flag.
    var onUpdateReady: ((String) -> Void)?

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Sparkle invokes this on the main thread per its docs but the
        // protocol is declared nonisolated, so we hop explicitly. We need
        // the boolean answer synchronously, so capture the displayVersion
        // up-front (it's an immutable Objective-C property) and dispatch
        // the callback delivery.
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            self.onUpdateReady?(version)
        }
        return false  // Suppress Sparkle's default UI; our SwiftUI surfaces handle it.
    }
}
#endif
