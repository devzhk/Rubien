#if Sparkle
import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController {
    /// Whether the underlying updater is in a state where checkForUpdates()
    /// can be called right now. Mirrors `SPUUpdater.canCheckForUpdates`.
    private(set) var canCheckForUpdates: Bool = false

    /// True when a scheduled-check download has completed and the user can
    /// click "Install and Relaunch" from any of the SwiftUI surfaces.
    private(set) var updateReadyToInstall: Bool = false

    /// The shortVersionString of the pending update; surfaced as "Update 0.1.1
    /// ready to install" in the Settings pane and toolbar tooltip.
    private(set) var pendingVersion: String?

    /// Timestamp of the last completed scheduled check, used for the
    /// "Last checked: …" Settings status line. Updated via KVO on the
    /// underlying updater.
    private(set) var lastCheckDate: Date?

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    private let updater: any UpdaterProtocol

    // Strongly retained — SPUStandardUpdaterController stores delegates as
    // weak references, so the delegate must outlive init by being owned here.
    private let userDriverDelegate: UpdateUserDriverDelegate

    // Strongly retained in production. Nil in tests (where a FakeUpdater is
    // injected directly and there's no SPUStandardUpdaterController to keep
    // alive). Threaded through the designated init from the convenience init
    // below.
    private let standardController: SPUStandardUpdaterController?

    /// Designated init. Tests pass a FakeUpdater + their own delegate and
    /// nil standardController. Production goes through the convenience init.
    ///
    /// `userDriverDelegate` has no default value because
    /// `UpdateUserDriverDelegate()` is `@MainActor`-isolated and Swift 6
    /// will not synthesize a main-actor default for a designated init.
    /// Callers either supply one (tests) or use the `convenience init()`
    /// below (production).
    init(
        updater: any UpdaterProtocol,
        userDriverDelegate: UpdateUserDriverDelegate,
        standardController: SPUStandardUpdaterController? = nil
    ) {
        self.updater = updater
        self.userDriverDelegate = userDriverDelegate
        self.standardController = standardController
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.lastCheckDate = updater.lastUpdateCheckDate

        // Wire the callback ONCE here, regardless of which init path was
        // taken. Captures self weakly to avoid a retain cycle.
        userDriverDelegate.onUpdateReady = { [weak self] version in
            self?.updateReadyToInstall = true
            self?.pendingVersion = version
        }
    }

    /// Test convenience: builds a fresh delegate alongside the injected
    /// updater. Production callers go through `init()` (which constructs
    /// the full SPUStandardUpdaterController chain).
    convenience init(updater: any UpdaterProtocol) {
        self.init(
            updater: updater,
            userDriverDelegate: UpdateUserDriverDelegate(),
            standardController: nil
        )
    }

    /// Production init. Constructs an SPUStandardUpdaterController and
    /// threads both it and its delegate through the designated init in a
    /// single call, so:
    ///   - the delegate is owned strongly by self.userDriverDelegate
    ///     (SPUStandardUpdaterController only holds it weakly)
    ///   - the controller is owned strongly by self.standardController
    ///     (without this, the SPUUpdater we delegate to would lose its
    ///     parent controller as soon as this init returned)
    convenience init() {
        let delegate = UpdateUserDriverDelegate()
        let standard = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )
        self.init(
            updater: standard.updater,
            userDriverDelegate: delegate,
            standardController: standard
        )
    }

    func checkNow() {
        updater.checkForUpdates()
    }

    func installAndRelaunch() {
        // TODO(post-v0.1.0): replace with a dedicated install entry point.
        // Sparkle's SPUUpdater doesn't expose a public "install now" method
        // separate from checkForUpdates(); the install flow is triggered as
        // part of the standard check pipeline. For v1 this single entry
        // point is sufficient — both the "Check Now" button and the
        // "Install and Relaunch" button drive the same SPUUpdater pipeline.
        // When Sparkle exposes installPendingUpdate() (or we adopt a custom
        // user driver), call that here instead.
        updater.checkForUpdates()
    }

    // MARK: - Testing hooks

    #if DEBUG
    /// Test-only accessor so unit tests can assert the delegate is alive
    /// after init (regression for the weak-reference foot-gun).
    var delegateForTesting: UpdateUserDriverDelegate { userDriverDelegate }

    /// Test-only simulator for the delegate callback path.
    func simulateDelegateUpdateReady(version: String) {
        userDriverDelegate.onUpdateReady?(version)
    }
    #endif
}
#endif
