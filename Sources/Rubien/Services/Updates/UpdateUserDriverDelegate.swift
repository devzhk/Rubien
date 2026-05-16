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

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        onUpdateReady?(update.displayVersionString)
        return false  // Suppress Sparkle's default UI; our SwiftUI surfaces handle it.
    }
}
#endif
