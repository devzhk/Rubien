import Foundation
import SwiftUI
import CloudKit
import Security
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

    /// Factory that creates and starts a `SyncedLibrary` for a given
    /// database. The closure is responsible for both construction and
    /// calling `start()` so tests can inject a factory that skips the
    /// `CKSyncEngine` init (which requires CloudKit entitlements and
    /// would crash in an unentitled XCTest process).
    /// Production uses the default value which calls `start()`.
    private let makeLibrary: @Sendable (AppDatabase) async -> SyncedLibrary

    /// Path to the single-writer flock file. Production uses
    /// `SyncFileLock.defaultURL` (one global lock per device); tests
    /// inject a temp URL so they don't collide with a real running app
    /// holding the production lock.
    private let lockURL: URL

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        defaults: UserDefaults = .standard,
        probes: Probes = .live,
        makeLibrary: (@Sendable (AppDatabase) async -> SyncedLibrary)? = nil,
        lockURL: URL = SyncFileLock.defaultURL
    ) {
        self.appDatabase = appDatabase
        self.defaults = defaults
        self.probes = probes
        self.lockURL = lockURL
        if let makeLibrary {
            self.makeLibrary = makeLibrary
        } else {
            self.makeLibrary = { db in
                // Inject the B8 PDF-asset-sync flag from the app target's
                // RubienPreferences. RubienSync can't import Rubien (would
                // create a target cycle), so the read goes through a
                // closure resolved at construction.
                let lib = SyncedLibrary(
                    appDatabase: db,
                    pdfAssetSyncEnabledProvider: { RubienPreferences.pdfAssetSyncEnabled }
                )
                await lib.start()
                return lib
            }
        }
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

    // MARK: - Lifecycle state

    private var library: SyncedLibrary?
    private var statusTask: Task<Void, Never>?
    private var syncLock: SyncFileLock?
    private var lifecycleGeneration: Int = 0

    /// Test-only accessor; production callers never read the library
    /// directly (status is the observable surface).
    var librarySnapshotForTest: SyncedLibrary? { library }

    // MARK: - Real startSync / stopSync

    private func startSync() {
        Task { await performStartSync() }
    }

    private func stopSync() {
        Task { await performStopSync() }
    }

    /// Internal async workhorse — exposed as `performStartSyncForTest`
    /// so tests can await completion deterministically.
    func performStartSync() async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration

        let probeResult = await runPreflightProbes(containerIdentifier: SyncConstants.containerIdentifier)
        // Stale-completion guard after each await suspension.
        guard generation == lifecycleGeneration else { return }

        if probeResult != .idle {
            status = probeResult
            return
        }

        // Acquire the single-writer lock before instantiating the
        // library. A running CLI `sync status` probes this lock
        // non-blockingly to report `appLockHeld`.
        //
        // If this coordinator already holds the lock (e.g. a rapid
        // start → stop → start sequence where the first start acquired
        // the lock but the stale-completion guard fires before the lock
        // was released), we reuse the existing lock rather than
        // attempting a second acquisition — flock(2) on macOS treats
        // same-process attempts as conflicting.
        if syncLock == nil {
            do {
                let lock = try SyncFileLock(fileURL: self.lockURL)
                guard try lock.tryLockExclusive() else {
                    status = .unavailable(reason: "Another Rubien process is syncing")
                    return
                }
                self.syncLock = lock
            } catch {
                status = .unavailable(reason: "Sync lock unavailable: \(error)")
                return
            }
        }

        let newLibrary = await makeLibrary(appDatabase)
        await newLibrary.installTransactionObserver()

        guard generation == lifecycleGeneration else {
            await newLibrary.removeTransactionObserver()
            try? syncLock?.unlock()
            syncLock = nil
            return
        }

        library = newLibrary
        status = .idle
        startStatusConsumer(for: newLibrary)
    }

    func performStopSync() async {
        lifecycleGeneration += 1
        statusTask?.cancel()
        statusTask = nil

        if let existing = library {
            await existing.removeTransactionObserver()
        }
        library = nil
        try? syncLock?.unlock()
        syncLock = nil
        status = .disabled
    }

    // MARK: - Status stream consumer

    private func startStatusConsumer(for library: SyncedLibrary) {
        statusTask?.cancel()  // prevent leaking a prior consumer on retry
        let stream = library.statusStream
        let currentGeneration = lifecycleGeneration
        statusTask = Task { [weak self] in
            for await newStatus in stream {
                guard let self = self else { return }
                let mappedStatus = await self.mapStatus(newStatus)
                await MainActor.run {
                    guard currentGeneration == self.lifecycleGeneration else { return }
                    self.status = mappedStatus
                }
            }
        }
    }

    /// Coordinator-level `.error → .unavailable / .signedOut` remap. Keeps
    /// the actor ignorant of UX semantics and the UI layer ignorant of
    /// raw CK error codes.
    private func mapStatus(_ raw: SyncStatus) async -> SyncStatus {
        switch raw {
        case .error(let error):
            switch error.code {
            case .missingEntitlement:
                return .unavailable(reason: "CloudKit container not registered or entitlement invalid")
            case .notAuthenticated where !defaults.bool(forKey: DefaultsKey.didConfirmFirstRun):
                return .signedOut
            default:
                return raw
            }
        default:
            return raw
        }
    }

    // Test hook
    func mapStatusForTest(_ raw: SyncStatus) async -> SyncStatus {
        await mapStatus(raw)
    }

    // MARK: - Startup auto-start

    /// Call at app launch (from `.task` on the root scene) after the
    /// coordinator is injected. If the user previously enabled sync,
    /// kicks off the lifecycle automatically so they don't have to
    /// re-toggle on every relaunch. Safe to call multiple times —
    /// second call bumps the generation counter and early-returns if
    /// the library is already live.
    public func startIfEnabled() async {
        guard userEnabled, library == nil else { return }
        await performStartSync()
    }

    // MARK: - Public retry entry point

    /// Used by the "Try again" button on the Settings `.unavailable`
    /// state and by the error-banner retry action. Renamed from the
    /// earlier test-only name so production UI isn't calling a
    /// `*ForTest` method.
    public func retryStartSync() async {
        await performStartSync()
    }

    // MARK: - PDF upload-queue kick

    /// Trigger the PDF upload-queue drainer immediately. Called from import
    /// flows so newly-attached PDFs flow into CloudKit without waiting for
    /// the next app launch's `SyncedLibrary.start()` drain. No-op when sync
    /// isn't running (the queue rows persist; next start() will drain them).
    public func kickPDFUploadDrainer() async {
        await library?.drainPDFUploadQueue()
    }

    // MARK: - Test hooks

    func performStartSyncForTest() async {
        await performStartSync()
    }

    func performStopSyncForTest() async {
        await performStopSync()
    }
}

@available(macOS 14.0, *)
extension SyncCoordinator.Probes {
    public static var live: SyncCoordinator.Probes {
        SyncCoordinator.Probes(
            bundleHasEntitlement: {
                // Entitlements live in a signed blob on the executable, not
                // in Info.plist. `SecTaskCopyValueForEntitlement` reads the
                // runtime-effective entitlement for the current process —
                // the canonical check for whether codesign+profile actually
                // granted us CloudKit access.
                guard let task = SecTaskCreateFromSelf(nil) else { return false }
                let value = SecTaskCopyValueForEntitlement(
                    task,
                    "com.apple.developer.icloud-container-identifiers" as CFString,
                    nil
                )
                return value != nil
            },
            ubiquityIdentityToken: {
                // Defer to Layer 4 (`CKContainer.accountStatus`) for the
                // authoritative signed-in check — it works with just the
                // `com.apple.developer.icloud-container-identifiers`
                // entitlement we already have. `ubiquityIdentityToken`
                // requires `com.apple.developer.ubiquity-kvstore-identifier`
                // or `ubiquity-container-identifiers` to be readable from a
                // sandboxed process; without them the API returns nil even
                // when the user IS signed in, producing a spurious
                // `.signedOut` from Layer 2. We don't need iCloud Drive
                // ubiquity containers — only CloudKit — so returning a
                // sentinel here keeps the probe flow coherent.
                "sentinel" as NSString
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
