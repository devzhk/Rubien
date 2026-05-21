#if canImport(Sparkle)
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

    // Sparkle invokes this delegate method on the main thread. The guarantee
    // is in Sparkle's user-driver documentation, not the header annotations
    // (which don't carry a main-thread attribute):
    //   https://sparkle-project.org/documentation/customization/
    // "The Standard User Driver invokes its delegate on the main run loop"
    //
    // Because the guarantee lives in docs rather than the type system,
    // MainActor.assumeIsolated is the right tool: it preserves our
    // MainActor isolation guarantees without spawning an extra hop, but will
    // crash with a clear backtrace if Sparkle ever violates the contract —
    // surfacing a regression at the source rather than racing silently.
    //
    // We need the boolean answer synchronously, so capture the displayVersion
    // up-front (it's an immutable Objective-C property) before the
    // assumeIsolated block delivers the callback.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            self.onUpdateReady?(version)
        }
        return false  // Suppress Sparkle's default UI; our SwiftUI surfaces handle it.
    }
}
#endif
