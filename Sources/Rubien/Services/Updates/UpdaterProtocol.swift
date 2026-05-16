#if Sparkle
import Foundation
import Sparkle

/// Narrow abstraction over `SPUUpdater` used by `UpdateController` so unit
/// tests can drive the controller with a fake without spinning up real
/// Sparkle XPC services. Only the surface the controller actually reads
/// is exposed; the controller never imports Sparkle directly through this
/// protocol so substitution at test time is straightforward.
@MainActor
protocol UpdaterProtocol: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }

    func checkForUpdates()
    func checkForUpdatesInBackground()
}

extension SPUUpdater: UpdaterProtocol {
    // SPUUpdater already exposes every member of UpdaterProtocol with the
    // same names. Empty extension to declare conformance.
}
#endif
