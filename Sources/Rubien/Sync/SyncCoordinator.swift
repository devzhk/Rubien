import Foundation
import SwiftUI
import CloudKit
import RubienCore
import RubienSync
import RubienExceptionCatcher

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

    // MARK: - Probes (DI seam)

    /// Four-layer entitlement/account probe. All calls go through this
    /// struct so tests can inject deterministic behavior without touching
    /// CloudKit or Bundle.main. Production uses `Probes.live`.
    ///
    /// `accountStatus` is `async` because Apple's underlying API uses a
    /// completion handler and we can't block the MainActor on a
    /// DispatchSemaphore without risking UI freezes. Callers must
    /// `await` it from a suspension point (the `startSync` path is
    /// already async).
    public struct Probes: Sendable {
        public var bundleHasEntitlement: @Sendable () -> Bool
        public var ubiquityIdentityToken: @Sendable () -> NSCoding?
        /// Returns nil if construction succeeded; the raised NSException if not.
        public var tryCKContainerInit: @Sendable (String) -> NSException?
        public var accountStatus: @Sendable (String) async -> CKAccountStatus

        public init(
            bundleHasEntitlement: @escaping @Sendable () -> Bool,
            ubiquityIdentityToken: @escaping @Sendable () -> NSCoding?,
            tryCKContainerInit: @escaping @Sendable (String) -> NSException?,
            accountStatus: @escaping @Sendable (String) async -> CKAccountStatus
        ) {
            self.bundleHasEntitlement = bundleHasEntitlement
            self.ubiquityIdentityToken = ubiquityIdentityToken
            self.tryCKContainerInit = tryCKContainerInit
            self.accountStatus = accountStatus
        }
    }

    private let probes: Probes

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        defaults: UserDefaults = .standard,
        probes: Probes = .live
    ) {
        self.appDatabase = appDatabase
        self.defaults = defaults
        self.probes = probes
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

    // MARK: - Preflight

    /// Run the four-layer entitlement/account probe. Returns the
    /// `SyncStatus` to assign on failure, or `.idle` when all pass and
    /// the actor can safely be instantiated.
    public func runPreflightProbes(containerIdentifier: String) async -> SyncStatus {
        // Layer 1 — plist probe (coarse filter).
        guard probes.bundleHasEntitlement() else {
            return .unavailable(reason: "No CloudKit entitlement in app bundle")
        }
        // Layer 2 — iCloud signed-in check, no CKContainer required.
        guard probes.ubiquityIdentityToken() != nil else {
            return .signedOut
        }
        // Layer 3 — CKContainer init guarded by ObjC exception shim.
        if let ex = probes.tryCKContainerInit(containerIdentifier) {
            return .unavailable(reason: "Container init raised \(ex.name.rawValue)")
        }
        // Layer 4 — CloudKit account status (rich detection) on the
        // configured container, not the default container.
        switch await probes.accountStatus(containerIdentifier) {
        case .available:
            return .idle
        case .noAccount, .couldNotDetermine:
            return .signedOut
        case .restricted:
            let error = CKError(_nsError: NSError(domain: CKErrorDomain, code: CKError.Code.managedAccountRestricted.rawValue))
            return .error(error)
        case .temporarilyUnavailable:
            let error = CKError(_nsError: NSError(domain: CKErrorDomain, code: CKError.Code.accountTemporarilyUnavailable.rawValue))
            return .error(error)
        @unknown default:
            return .unavailable(reason: "Unknown CloudKit account status")
        }
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

@available(macOS 14.0, *)
extension SyncCoordinator.Probes {
    public static var live: SyncCoordinator.Probes {
        SyncCoordinator.Probes(
            bundleHasEntitlement: {
                Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.icloud-container-identifiers") != nil
            },
            ubiquityIdentityToken: {
                FileManager.default.ubiquityIdentityToken
            },
            tryCKContainerInit: { identifier in
                ExceptionCatcher.catchException {
                    _ = CKContainer(identifier: identifier).privateCloudDatabase
                }
            },
            accountStatus: { identifier in
                // Bridges the completion-handler API to Swift concurrency.
                // Uses the configured container (not `.default()`) so the
                // env-var override flows through.
                await withCheckedContinuation { continuation in
                    CKContainer(identifier: identifier).accountStatus { status, _ in
                        continuation.resume(returning: status)
                    }
                }
            }
        )
    }
}
