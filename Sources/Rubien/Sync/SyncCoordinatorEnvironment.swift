#if os(macOS)
import SwiftUI

/// Non-observing handle to the app's `SyncCoordinator`.
///
/// Use this in views that need to *call* the coordinator (e.g.
/// `kickPDFUploadDrainer()`) but do **not** render anything from its
/// `@Published` properties. Reading via `@Environment(\.syncCoordinator)`
/// does not subscribe to `objectWillChange`, so the view's body is not
/// re-evaluated on every `status` flip. Views that legitimately render the
/// status (e.g. `ViewChromeBar`) keep `@EnvironmentObject SyncCoordinator`.
private struct SyncCoordinatorKey: EnvironmentKey {
    static let defaultValue: SyncCoordinator? = nil
}

extension EnvironmentValues {
    var syncCoordinator: SyncCoordinator? {
        get { self[SyncCoordinatorKey.self] }
        set { self[SyncCoordinatorKey.self] = newValue }
    }
}
#endif
