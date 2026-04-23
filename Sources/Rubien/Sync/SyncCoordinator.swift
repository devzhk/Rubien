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
}
