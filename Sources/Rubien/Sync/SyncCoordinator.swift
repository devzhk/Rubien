import Foundation
import SwiftUI
import CloudKit
import RubienCore
import RubienSync

/// Bridges the `SyncedLibrary` actor to SwiftUI. Owns the actor's
/// lifecycle (start on toggle-on, stop on toggle-off), runs the
/// four-layer enrollment-gap probe, and republishes the actor's
/// `statusStream` as a `@Published` property the UI can bind to.
///
/// Single-user app → one instance, constructed at app startup,
/// injected via `.environmentObject`.
@available(macOS 14.0, *)
@MainActor
public final class SyncCoordinator: ObservableObject {

    // MARK: - UserDefaults keys

    public enum DefaultsKey {
        public static let enabled             = "rubien.sync.enabled"
        public static let didConfirmFirstRun  = "rubien.sync.didConfirmFirstRun"
    }

    // MARK: - Published state

    @Published public private(set) var status: SyncStatus = .disabled
    @Published public private(set) var userEnabled: Bool

    /// Transient, non-persistent. True between toggle flip and
    /// confirm-sheet dismissal. Binding uses this for flicker-free
    /// visual state during the confirm dance.
    @Published public internal(set) var pendingConfirm: Bool = false

    // MARK: - Collaborators

    private let appDatabase: AppDatabase
    private let defaults: UserDefaults

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        defaults: UserDefaults = .standard
    ) {
        self.appDatabase = appDatabase
        self.defaults = defaults
        self.userEnabled = defaults.bool(forKey: DefaultsKey.enabled)
    }

    // MARK: - Toggle binding

    /// Backing binding for the SwiftUI Settings toggle. `get` returns
    /// true while the confirm sheet is pending OR the user has actually
    /// enabled sync — so the toggle stays visually ON during the
    /// confirm dance without persistent flicker. `set` routes through
    /// handleToggle so UserDefaults isn't written until confirm.
    public var toggleBinding: Binding<Bool> {
        Binding(
            get: { self.pendingConfirm || self.userEnabled },
            set: { self.handleToggle($0) }
        )
    }

    // MARK: - Lifecycle transitions

    public func handleToggle(_ newValue: Bool) {
        if newValue {
            if defaults.bool(forKey: DefaultsKey.didConfirmFirstRun) {
                persistEnabled(true)
                startSync()
            } else {
                pendingConfirm = true
            }
        } else {
            persistEnabled(false)
            stopSync()
        }
    }

    public func confirmEnable() {
        pendingConfirm = false
        defaults.set(true, forKey: DefaultsKey.didConfirmFirstRun)
        persistEnabled(true)
        startSync()
    }

    public func cancelConfirm() {
        pendingConfirm = false
        // userEnabled stays false; no defaults write; no startSync.
    }

    // MARK: - Private

    private func persistEnabled(_ value: Bool) {
        userEnabled = value
        defaults.set(value, forKey: DefaultsKey.enabled)
    }

    // MARK: - Sync lifecycle (stubs until Task 7)

    private func startSync() {
        // Task 7 fills this in; stub sets .idle so the toggle flow's
        // status transitions look sane to tests that don't exercise
        // the probe path.
        status = .idle
    }

    private func stopSync() {
        status = .disabled
    }
}
