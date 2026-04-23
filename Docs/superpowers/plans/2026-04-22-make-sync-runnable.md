# Make CloudKit sync runnable on macOS — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the already-landed `RubienSync` target into the shipping `Rubien.app` so the opt-in CloudKit sync toggle actually works: four-layer enrollment-gap detection, toolbar/banner UI, CLI `sync status` subcommand, dormant entitlement file.

**Architecture:** A new `@MainActor ObservableObject` `SyncCoordinator` lives in the `Rubien` target. It owns an optional `SyncedLibrary` actor, republishes the actor's `AsyncStream<SyncStatus>` via `@Published`, and gates engine startup on a four-layer probe (plist entitlement, `ubiquityIdentityToken`, ObjC-shim-guarded CKContainer construction, `CKContainer.accountStatus`). SwiftUI views bind to the coordinator; the CLI reads DB state directly without instantiating the actor. Entitlement file ships dormant; probe short-circuits to `.unavailable` when CloudKit access isn't granted yet.

**Tech Stack:** Swift 5.9+ / macOS 14.4+ / SwiftUI / CloudKit (`CKSyncEngine`) / GRDB / SwiftPM / swift-argument-parser / XCTest. New Clang-only SPM target for `ExceptionCatcher.{h,m}`.

---

## Prerequisites

Verify setup before starting:

```bash
xcode-select -p
# Expected: /Applications/Xcode.app/Contents/Developer (not CommandLineTools — need XCTest)

swift test --filter RubienSyncTests 2>&1 | tail -2
# Expected: Executed 90 tests, with 0 failures
```

---

## File Structure

Files to be created or modified, with each file's single responsibility:

**New Clang target — ObjC exception shim:**
- `Sources/RubienExceptionCatcher/include/ExceptionCatcher.h` — public ObjC interface
- `Sources/RubienExceptionCatcher/ExceptionCatcher.m` — `@try/@catch` wrapper

**New in `Sources/RubienSync/`:**
- `SyncStatus.swift` — public enum state (`.disabled`, `.unavailable`, `.signedOut`, `.idle`, `.syncing`, `.error`)

**Modified in `Sources/RubienSync/`:**
- `SyncedLibrary.swift` — add `statusStream: AsyncStream<SyncStatus>` + `publishStatus(_:)`; update delegate methods to publish alongside logging
- `SyncConstants.swift` — `containerIdentifier` becomes a computed var with env-var override

**Modified in root:**
- `Package.swift` — add `RubienExceptionCatcher` target; `RubienSync` depends on it; `RubienCLI` adds `RubienSync` dep

**New in `Sources/Rubien/Sync/`:**
- `SyncCoordinator.swift` — `@MainActor` ObservableObject; owns the actor and bridges to SwiftUI

**New in `Sources/Rubien/Views/`:**
- `SyncStatusIcon.swift` — toolbar cloud-state SF Symbol view
- `SyncStatusBanner.swift` — view modifier applying modal alerts / overlay banners based on status
- `RubienSettingsView.swift` — SwiftUI `Settings` scene root with the iCloud Sync section

**Modified in `Sources/Rubien/`:**
- `RubienApp.swift` — `@StateObject` coordinator, `.environmentObject` injection, `Settings { ... }` scene, toolbar icon, banner view modifier
- `Rubien.entitlements` — add `com.apple.developer.icloud-container-identifiers` + `com.apple.developer.icloud-services` (dormant until signing grants them)

**New CLI:**
- `Sources/RubienCLI/SyncCommands.swift` — `sync status` subcommand with JSON output

**Modified CLI entrypoint:**
- `Sources/RubienCLI/RubienCLI.swift` — register new subcommand group

**New tests:**
- `Tests/RubienSyncTests/ExceptionCatcherTests.swift`
- `Tests/RubienSyncTests/SyncStatusStreamTests.swift`
- `Tests/RubienTests/SyncCoordinatorTests.swift`
- `Tests/RubienCLITests/SyncStatusCommandTests.swift`

**New docs:**
- `Docs/Sync-Runbook.md` — post-enrollment operational setup
- `CLAUDE.md` — update CLI description (now links RubienSync)
- `Docs/CLI-Reference.md` — new `sync status` section

---

## Commit 1 — Foundation (Tasks 1–9)

### Task 1: Add `RubienExceptionCatcher` Clang target

**Files:**
- Create: `Sources/RubienExceptionCatcher/include/ExceptionCatcher.h`
- Create: `Sources/RubienExceptionCatcher/ExceptionCatcher.m`
- Modify: `Package.swift`
- Test: `Tests/RubienSyncTests/ExceptionCatcherTests.swift`

- [ ] **Step 1: Create the ObjC header**

Path: `Sources/RubienExceptionCatcher/include/ExceptionCatcher.h`

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps an Objective-C `@try/@catch` so a Swift caller can detect whether
/// a block raised an `NSException`. Swift's own `do/catch` only handles
/// types conforming to `Error` and will let `NSException` terminate the
/// process — this shim is the only way to guard CKContainer construction
/// on a process without a valid CloudKit entitlement.
@interface ExceptionCatcher : NSObject
+ (nullable NSException *)tryBlock:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Create the ObjC implementation**

Path: `Sources/RubienExceptionCatcher/ExceptionCatcher.m`

```objc
#import "ExceptionCatcher.h"

@implementation ExceptionCatcher
+ (nullable NSException *)tryBlock:(NS_NOESCAPE void (^)(void))block {
    @try { block(); return nil; }
    @catch (NSException *e) { return e; }
}
@end
```

- [ ] **Step 3: Add the SPM target and wire the dependency**

Modify `Package.swift` — add a new `.target` entry and extend `RubienSync` + `RubienCLI` dependencies.

Locate the `targets: [` block and replace the `RubienSync` target entry with:

```swift
        .target(
            name: "RubienExceptionCatcher",
            path: "Sources/RubienExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RubienSync",
            dependencies: [
                "RubienCore",
                "RubienExceptionCatcher",
            ]
        ),
```

(Clang-only target; no `dependencies:` needed since it only uses Foundation.)

- [ ] **Step 4: Write the failing test**

Path: `Tests/RubienSyncTests/ExceptionCatcherTests.swift`

```swift
import XCTest
import RubienExceptionCatcher

final class ExceptionCatcherTests: XCTestCase {

    func testReturnsNilWhenBlockDoesNotRaise() {
        let ex = ExceptionCatcher.tryBlock { }
        XCTAssertNil(ex)
    }

    func testReturnsExceptionWhenBlockRaises() {
        let ex = ExceptionCatcher.tryBlock {
            NSException(name: .genericException, reason: "test", userInfo: nil).raise()
        }
        XCTAssertNotNil(ex, "tryBlock must capture NSException so Swift callers can detect the failure")
        XCTAssertEqual(ex?.name, .genericException)
    }
}
```

- [ ] **Step 5: Run the test to verify it fails at build-time**

```bash
swift test --filter ExceptionCatcherTests 2>&1 | tail -5
```

Expected: build failure — `no such module 'RubienExceptionCatcher'` (Package.swift not yet updated to expose the product publicly for tests).

If the test compiles but fails: inspect Package.swift — the new target isn't being resolved by `swift test`.

- [ ] **Step 6: Add the test target dependency**

Modify `Package.swift` — the `RubienSyncTests` target's `dependencies` list:

```swift
        .testTarget(
            name: "RubienSyncTests",
            dependencies: ["RubienSync", "RubienCore", "RubienExceptionCatcher"],
            path: "Tests/RubienSyncTests"
        ),
```

- [ ] **Step 7: Re-run the test to verify it passes**

```bash
swift test --filter ExceptionCatcherTests 2>&1 | tail -5
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/RubienExceptionCatcher Tests/RubienSyncTests/ExceptionCatcherTests.swift
git commit -m "$(cat <<'EOF'
add RubienExceptionCatcher Clang target for CKContainer guard

Tiny ObjC shim that wraps @try/@catch so Swift callers can detect
NSException raised by CKContainer(identifier:) / privateCloudDatabase
when the process has no CloudKit entitlement. Swift's own do/catch
doesn't catch NSException — it terminates. SwiftPM forbids mixing
.swift and .m in one target, so the shim lives in its own Clang-only
target that RubienSync depends on.

Tests verify tryBlock returns nil on normal execution and the raised
NSException on @throw — foundation for the four-layer enrollment-gap
probe to land in the next commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `SyncStatus` enum

**Files:**
- Create: `Sources/RubienSync/SyncStatus.swift`

- [ ] **Step 1: Create the enum**

Path: `Sources/RubienSync/SyncStatus.swift`

```swift
import Foundation
import CloudKit

/// Observable state the sync stack reports to SwiftUI and the CLI.
///
/// `.error` wraps raw `CKError` so the error table's per-code UX
/// decisions (see spec) can switch on `.code`. Equality requires
/// manual == because `CKError` is a struct wrapping `NSError` which
/// doesn't conform to Equatable by default.
public enum SyncStatus: Sendable {
    case disabled
    case unavailable(reason: String)
    case signedOut
    case idle
    case syncing
    case error(CKError)
}

extension SyncStatus: Equatable {
    public static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.disabled, .disabled), (.signedOut, .signedOut),
             (.idle, .idle), (.syncing, .syncing):
            return true
        case (.unavailable(let l), .unavailable(let r)):
            return l == r
        case (.error(let l), .error(let r)):
            // NSError equality compares domain + code + userInfo;
            // SyncStatus callers only care about code for routing, so
            // we match on (domain, code) to keep tests stable.
            return l._domain == r._domain && l.errorCode == r.errorCode
        default:
            return false
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
swift build --target RubienSync 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienSync/SyncStatus.swift
git commit -m "add SyncStatus enum for sync coordinator state machine"
```

---

### Task 3: `statusStream` on `SyncedLibrary`

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`
- Test: `Tests/RubienSyncTests/SyncStatusStreamTests.swift`

- [ ] **Step 1: Write the failing test**

Path: `Tests/RubienSyncTests/SyncStatusStreamTests.swift`

```swift
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, iOS 17.0, *)
final class SyncStatusStreamTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() { db = nil; super.tearDown() }

    func testStatusStreamEmitsWhenPublishCalled() async throws {
        let library = SyncedLibrary(appDatabase: db)

        var iterator = await library.statusStream.makeAsyncIterator()

        await library.publishStatusForTest(.syncing)
        let first = await iterator.next()
        XCTAssertEqual(first, .syncing)

        await library.publishStatusForTest(.idle)
        let second = await iterator.next()
        XCTAssertEqual(second, .idle)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter SyncStatusStreamTests 2>&1 | tail -5
```

Expected: compile failure — `SyncedLibrary` has no `statusStream` property.

- [ ] **Step 3: Add `statusStream` and `publishStatus` to `SyncedLibrary`**

Modify `Sources/RubienSync/SyncedLibrary.swift`. Add these inside the actor class body, near the top (after the existing stored properties):

```swift
    // MARK: - Status stream

    /// Observable state changes the coordinator republishes to SwiftUI.
    /// One stream per actor lifetime; the actor calls `publishStatus(_:)`
    /// from inside its delegate methods.
    public nonisolated let statusStream: AsyncStream<SyncStatus>

    private let statusContinuation: AsyncStream<SyncStatus>.Continuation

    // MARK: - Status publishing

    func publishStatus(_ status: SyncStatus) {
        statusContinuation.yield(status)
        switch status {
        case .error(let error):
            log.error("sync status → error: \(error.localizedDescription, privacy: .public)")
        case .unavailable(let reason):
            log.info("sync status → unavailable: \(reason, privacy: .public)")
        default:
            log.debug("sync status → \(String(describing: status), privacy: .public)")
        }
    }

    /// Test-only hook. Production callers go through `publishStatus`.
    func publishStatusForTest(_ status: SyncStatus) {
        publishStatus(status)
    }
```

Then modify the existing `init(appDatabase:stateFileURL:containerProvider:)` to create the stream/continuation:

Replace the existing init body's first lines so they include:

```swift
        var continuation: AsyncStream<SyncStatus>.Continuation!
        self.statusStream = AsyncStream { cont in continuation = cont }
        self.statusContinuation = continuation
        self.appDatabase = appDatabase
        // ... rest of existing assignments
```

(Keep the rest of the init body unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter SyncStatusStreamTests 2>&1 | tail -5
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 5: Wire `publishStatus` calls into existing delegate methods**

In `SyncedLibrary.swift`'s `handleEvent(_:syncEngine:)` switch — add `publishStatus(_:)` calls alongside the existing log lines:

```swift
        case .willFetchChanges, .willSendChanges:
            publishStatus(.syncing)
        case .didFetchChanges, .didSendChanges:
            publishStatus(.idle)
```

(Leave the other cases untouched for now — account change, fetched/sent zone changes, etc. get their publishStatus hooks in later tasks.)

- [ ] **Step 6: Build and re-run all tests**

```bash
swift test --filter RubienSyncTests 2>&1 | tail -2
```

Expected: all 91+ tests pass (90 prior + 1 new).

- [ ] **Step 7: Commit**

```bash
git add Sources/RubienSync/SyncedLibrary.swift Tests/RubienSyncTests/SyncStatusStreamTests.swift
git commit -m "$(cat <<'EOF'
add SyncedLibrary.statusStream for coordinator bridging

AsyncStream<SyncStatus> emitted from publishStatus, hooked into the
willFetchChanges/didFetchChanges/willSendChanges/didSendChanges
delegate events so the coordinator can republish as @Published and
drive the toolbar icon. Account-change and error paths get their
publishStatus hooks in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `SyncCoordinator` scaffold + initial-state behavior

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Rubien/Sync/SyncCoordinator.swift`
- Test: `Tests/RubienTests/SyncCoordinatorTests.swift`

- [ ] **Step 1: Add `RubienSync` + `RubienExceptionCatcher` deps to the app and its test target**

The `Rubien` executable target currently only depends on `RubienCore`; `SyncCoordinator` imports `RubienSync` (for `SyncedLibrary`, `SyncStatus`, `SyncConstants`) and `RubienExceptionCatcher` (for the ObjC shim used by `Probes.live` in Task 6). Update `Package.swift`:

```swift
        .executableTarget(
            name: "Rubien",
            dependencies: [
                "RubienCore",
                "RubienSync",
                "RubienExceptionCatcher",
            ],
            exclude: [
                "Rubien.entitlements"
            ],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources")
            ]
        ),
        ...
        .testTarget(
            name: "RubienTests",
            dependencies: ["Rubien", "RubienCore", "RubienSync"],
            path: "Tests/RubienTests"
        ),
```

Build to confirm the deps wire up cleanly before adding new code:

```bash
swift build --target Rubien 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 2: Write the failing test**

Path: `Tests/RubienTests/SyncCoordinatorTests.swift`

```swift
import XCTest
import Foundation
import GRDB
@testable import Rubien
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, *)
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    private var db: AppDatabase!
    private var defaults: UserDefaults!
    private let suiteName = "rubien.test.sync.\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        db = nil
        super.tearDown()
    }

    func testInitialStateRespectsUserDefaults() {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults
        )
        XCTAssertFalse(coordinator.userEnabled, "default must be false")
        XCTAssertEqual(coordinator.status, .disabled)
    }

    func testInitialStateReadsPersistedEnabled() {
        defaults.set(true, forKey: "rubien.sync.enabled")
        defaults.set(true, forKey: "rubien.sync.didConfirmFirstRun")

        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults
        )
        XCTAssertTrue(
            coordinator.userEnabled,
            "previously-enabled state must survive a relaunch"
        )
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -10
```

Expected: compile failure — `SyncCoordinator` doesn't exist.

- [ ] **Step 4: Create the coordinator file**

Path: `Sources/Rubien/Sync/SyncCoordinator.swift`

```swift
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
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -5
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "add SyncCoordinator scaffold with UserDefaults-backed preference"
```

---

### Task 5: Toggle binding + pendingConfirm flow

**Files:**
- Modify: `Sources/Rubien/Sync/SyncCoordinator.swift`
- Modify: `Tests/RubienTests/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RubienTests/SyncCoordinatorTests.swift`:

```swift
    // MARK: - Confirm flow

    func testTogglingOnShowsPendingConfirmWithoutPersisting() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        coordinator.handleToggle(true)

        XCTAssertTrue(coordinator.pendingConfirm, "confirm sheet must be pending")
        XCTAssertFalse(
            defaults.bool(forKey: SyncCoordinator.DefaultsKey.enabled),
            "UserDefaults must not be written until user confirms — prevents the app-quit-mid-sheet inconsistency"
        )
    }

    func testToggleBindingReflectsPendingConfirm() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        XCTAssertFalse(coordinator.toggleBinding.wrappedValue)

        coordinator.handleToggle(true)
        XCTAssertTrue(
            coordinator.toggleBinding.wrappedValue,
            "binding reads true while pendingConfirm is set, so the toggle stays visually ON during the confirm sheet"
        )
    }

    func testCancelConfirmClearsPendingAndLeavesDisabled() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        coordinator.handleToggle(true)
        coordinator.cancelConfirm()

        XCTAssertFalse(coordinator.pendingConfirm)
        XCTAssertFalse(coordinator.userEnabled)
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(defaults.bool(forKey: SyncCoordinator.DefaultsKey.enabled))
    }

    func testConfirmEnablePersistsAndSetsFlag() {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        coordinator.handleToggle(true)
        coordinator.confirmEnable()

        XCTAssertFalse(coordinator.pendingConfirm)
        XCTAssertTrue(coordinator.userEnabled)
        XCTAssertTrue(defaults.bool(forKey: SyncCoordinator.DefaultsKey.enabled))
        XCTAssertTrue(defaults.bool(forKey: SyncCoordinator.DefaultsKey.didConfirmFirstRun))
    }

    func testSecondToggleSkipsConfirmSheet() {
        defaults.set(true, forKey: SyncCoordinator.DefaultsKey.didConfirmFirstRun)
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)

        coordinator.handleToggle(true)
        XCTAssertFalse(
            coordinator.pendingConfirm,
            "didConfirmFirstRun == true means we skip the sheet on subsequent toggles"
        )
        XCTAssertTrue(coordinator.userEnabled)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -10
```

Expected: compile failures on `handleToggle`, `toggleBinding`, `cancelConfirm`, `confirmEnable`.

- [ ] **Step 3: Implement the toggle + confirm flow**

Append to `Sources/Rubien/Sync/SyncCoordinator.swift` (inside the class):

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -5
```

Expected: `Executed 7 tests, with 0 failures` (2 initial + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "add pendingConfirm flow + toggleBinding to SyncCoordinator"
```

---

### Task 6: Four-layer entitlement/account probe

**Files:**
- Modify: `Sources/Rubien/Sync/SyncCoordinator.swift`
- Modify: `Tests/RubienTests/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests for each probe layer**

Append to `Tests/RubienTests/SyncCoordinatorTests.swift`:

```swift
    // MARK: - Probe tests

    func testProbeUnavailableWhenEntitlementAbsent() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { false },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected .unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("entitlement"))
    }

    func testProbeSignedOutWhenTokenNil() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { nil },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        XCTAssertEqual(result, .signedOut)
    }

    func testProbeUnavailableWhenCKContainerThrows() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in
                    NSException(name: .internalInconsistencyException, reason: "no container", userInfo: nil)
                },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected .unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("Container"))
    }

    func testProbeSignedOutWhenAccountStatusNoAccount() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .noAccount }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        XCTAssertEqual(result, .signedOut)
    }

    func testProbeIdleWhenAllPass() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { _ in .available }
            )
        )
        let result = await coordinator.runPreflightProbes(containerIdentifier: "iCloud.test")
        XCTAssertEqual(result, .idle)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -10
```

Expected: compile failure on `Probes` struct, new init signature, and `runPreflightProbes`.

- [ ] **Step 3: Add the probe struct and method**

Modify `Sources/Rubien/Sync/SyncCoordinator.swift` — add the nested `Probes` struct and update init / add `runPreflightProbes`:

```swift
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
```

Modify the existing `init` to add the `probes:` parameter with a `.live` default (see Step 4 for the default). For now, add a new convenience init signature alongside the existing one:

```swift
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
```

(Remove the old two-arg init; tests using the old signature still compile via the default.)

Add `runPreflightProbes` method:

```swift
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
```

- [ ] **Step 4: Add the `Probes.live` default (production implementations)**

Add this extension in the same file (outside the class body):

```swift
import RubienExceptionCatcher

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
                ExceptionCatcher.tryBlock {
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
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -5
```

Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "add four-layer probe (plist/iCloud token/ObjC shim/accountStatus)"
```

---

### Task 7: `startSync` integration + `lifecycleGeneration` + statusTask

**Files:**
- Modify: `Sources/Rubien/Sync/SyncCoordinator.swift`
- Modify: `Tests/RubienTests/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `Tests/RubienTests/SyncCoordinatorTests.swift`:

```swift
    // MARK: - startSync / stopSync integration

    func testStartSyncSetsUnavailableWhenProbeFails() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { false },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { .available }
            )
        )
        await coordinator.performStartSyncForTest()

        guard case .unavailable = coordinator.status else {
            return XCTFail("expected .unavailable, got \(coordinator.status)")
        }
        XCTAssertNil(coordinator.librarySnapshotForTest, "no library instantiated when probes fail")
    }

    func testStopSyncClearsLibraryAndCancelsStatusTask() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: SyncCoordinator.Probes(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { .available }
            )
        )
        await coordinator.performStartSyncForTest()
        XCTAssertNotNil(coordinator.librarySnapshotForTest)

        await coordinator.performStopSyncForTest()
        XCTAssertNil(coordinator.librarySnapshotForTest)
        XCTAssertEqual(coordinator.status, .disabled)
    }

    func testRapidToggleDoesNotLeakStaleLibrary() async {
        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: .init(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { .available }
            )
        )
        // Start then immediately stop + start again. With the lifecycle
        // counter, only the second start's library should survive.
        async let first: Void = coordinator.performStartSyncForTest()
        await coordinator.performStopSyncForTest()
        async let second: Void = coordinator.performStartSyncForTest()

        _ = await (first, second)

        // Library is from the second start (counter=3), not the first.
        XCTAssertNotNil(coordinator.librarySnapshotForTest)
    }
```

Append one more test for the `startIfEnabled()` auto-start path:

```swift
    func testStartIfEnabledLaunchesSyncWhenUserDefaultsPersisted() async {
        defaults.set(true, forKey: SyncCoordinator.DefaultsKey.enabled)
        defaults.set(true, forKey: SyncCoordinator.DefaultsKey.didConfirmFirstRun)

        let coordinator = SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: .init(
                bundleHasEntitlement: { true },
                ubiquityIdentityToken: { "token" as NSCoding },
                tryCKContainerInit: { _ in nil },
                accountStatus: { .available }
            )
        )
        await coordinator.startIfEnabled()
        XCTAssertNotNil(
            coordinator.librarySnapshotForTest,
            "startIfEnabled must launch the library when userDefaults says enabled"
        )
    }

    func testStartIfEnabledIsNoOpWhenDisabled() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        await coordinator.startIfEnabled()
        XCTAssertNil(coordinator.librarySnapshotForTest)
        XCTAssertEqual(coordinator.status, .disabled)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -10
```

Expected: compile failure on `performStartSyncForTest`, `performStopSyncForTest`, `librarySnapshotForTest`, `startIfEnabled`, `retryStartSync`.

- [ ] **Step 3: Implement the lifecycle machinery**

Modify `Sources/Rubien/Sync/SyncCoordinator.swift` — replace the stub `startSync()` / `stopSync()` from Task 5 with real implementations, and add the lifecycle counter / library storage / statusTask:

```swift
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
        do {
            let lock = try SyncFileLock(fileURL: SyncFileLock.defaultURL)
            guard try lock.tryLockExclusive() else {
                status = .unavailable(reason: "Another Rubien process is syncing")
                return
            }
            self.syncLock = lock
        } catch {
            status = .unavailable(reason: "Sync lock unavailable: \(error)")
            return
        }

        let newLibrary = SyncedLibrary(appDatabase: appDatabase)
        await newLibrary.start()
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

    /// Placeholder; Task 8 implements the real error-code remap rule.
    private func mapStatus(_ raw: SyncStatus) async -> SyncStatus { raw }

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

    // MARK: - Test hooks

    func performStartSyncForTest() async {
        await performStartSync()
    }

    func performStopSyncForTest() async {
        await performStopSync()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -5
```

Expected: `Executed 17 tests, with 0 failures` (12 prior + 5 new: two lifecycle tests + `testRapidToggle…` + two `startIfEnabled` tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "wire startSync/stopSync with lifecycleGeneration + startIfEnabled"
```

---

### Task 8: Status mapping rule

**Files:**
- Modify: `Sources/Rubien/Sync/SyncCoordinator.swift`
- Modify: `Tests/RubienTests/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `Tests/RubienTests/SyncCoordinatorTests.swift`:

```swift
    // MARK: - Status mapping rule

    func testMissingEntitlementRemapsToUnavailable() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        let missing = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.missingEntitlement.rawValue
        ))
        let mapped = await coordinator.mapStatusForTest(.error(missing))
        guard case .unavailable = mapped else {
            return XCTFail("missingEntitlement must map to .unavailable, got \(mapped)")
        }
    }

    func testOtherErrorCodesPassThrough() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        let quota = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.quotaExceeded.rawValue
        ))
        let mapped = await coordinator.mapStatusForTest(.error(quota))
        XCTAssertEqual(mapped, .error(quota))
    }

    func testNonErrorStatusPassesThrough() async {
        let coordinator = SyncCoordinator(appDatabase: db, defaults: defaults)
        XCTAssertEqual(await coordinator.mapStatusForTest(.idle), .idle)
        XCTAssertEqual(await coordinator.mapStatusForTest(.syncing), .syncing)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -10
```

Expected: compile failure on `mapStatusForTest` + semantic failure on the placeholder `mapStatus`.

- [ ] **Step 3: Replace placeholder mapping with the real rule**

In `Sources/Rubien/Sync/SyncCoordinator.swift`, replace the placeholder `mapStatus` body:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter SyncCoordinatorTests 2>&1 | tail -5
```

Expected: `Executed 20 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "add .error → .unavailable/.signedOut mapping rule in coordinator"
```

---

### Task 9: `SyncConstants.containerIdentifier` env-var override

**Files:**
- Modify: `Sources/RubienSync/SyncConstants.swift`
- Modify: `Tests/RubienSyncTests/SyncConstantsTests.swift` (new test file)

- [ ] **Step 1: Write failing test**

Path: `Tests/RubienSyncTests/SyncConstantsTests.swift`

```swift
import XCTest
@testable import RubienSync

final class SyncConstantsTests: XCTestCase {

    func testContainerIdentifierFallsBackToDefault() {
        unsetenv("RUBIEN_CLOUDKIT_CONTAINER")
        XCTAssertEqual(
            SyncConstants.containerIdentifier,
            "iCloud.com.rubien.app",
            "without override, constant returns the production default"
        )
    }

    func testContainerIdentifierReadsEnvVar() {
        setenv("RUBIEN_CLOUDKIT_CONTAINER", "iCloud.test.override", 1)
        defer { unsetenv("RUBIEN_CLOUDKIT_CONTAINER") }
        XCTAssertEqual(SyncConstants.containerIdentifier, "iCloud.test.override")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter SyncConstantsTests 2>&1 | tail -5
```

Expected: the env-var override test fails — the constant is currently a hardcoded `let`.

- [ ] **Step 3: Make containerIdentifier computed**

Modify `Sources/RubienSync/SyncConstants.swift` — replace the `let` with a computed property:

```swift
    /// CloudKit container identifier. Reads `RUBIEN_CLOUDKIT_CONTAINER`
    /// env var first (dev override) and falls back to the hardcoded
    /// production default. Must match the
    /// `com.apple.developer.icloud-container-identifiers` entitlement
    /// on both Mac and iPad builds.
    public static var containerIdentifier: String {
        ProcessInfo.processInfo.environment["RUBIEN_CLOUDKIT_CONTAINER"]
            ?? "iCloud.com.rubien.app"
    }
```

- [ ] **Step 4: Re-run the test to verify it passes**

```bash
swift test --filter SyncConstantsTests 2>&1 | tail -5
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Run the full RubienSync + RubienTests suites to catch regressions**

```bash
swift test --filter RubienSyncTests 2>&1 | grep Executed | tail -1
swift test --filter SyncCoordinatorTests 2>&1 | grep Executed | tail -1
```

Expected: both show `0 failures`.

- [ ] **Step 6: Commit — Commit 1 complete**

```bash
git add Sources/RubienSync/SyncConstants.swift Tests/RubienSyncTests/SyncConstantsTests.swift
git commit -m "$(cat <<'EOF'
make containerIdentifier overridable via RUBIEN_CLOUDKIT_CONTAINER

Completes Commit 1 of the make-sync-runnable plan. Env var override
lets dev builds point at a non-production container without a rebuild;
production falls back to the hardcoded default.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Commit 2 — SwiftUI surface (Tasks 10–13)

### Task 10: `SyncStatusIcon` view

**Files:**
- Create: `Sources/Rubien/Views/SyncStatusIcon.swift`

- [ ] **Step 1: Create the view**

Path: `Sources/Rubien/Views/SyncStatusIcon.swift`

```swift
import SwiftUI
import RubienSync

/// Small toolbar glyph reflecting the coordinator's current sync status.
/// Eight visual states keyed off the SyncStatus cases, using SF Symbols.
@available(macOS 14.0, *)
struct SyncStatusIcon: View {
    let status: SyncStatus

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(symbolColor)
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: status == .syncing
            )
            .accessibilityLabel(accessibilityLabel)
            .help(accessibilityLabel)
    }

    private var symbolName: String {
        switch status {
        case .disabled: return "icloud.slash"
        case .unavailable: return "exclamationmark.icloud"
        case .signedOut: return "icloud.slash"
        case .idle: return "checkmark.icloud.fill"
        case .syncing: return "icloud.and.arrow.up"
        case .error: return "xmark.icloud"
        }
    }

    private var symbolColor: Color {
        switch status {
        case .disabled, .signedOut: return .secondary
        case .unavailable: return .orange
        case .idle: return .accentColor
        case .syncing: return .blue
        case .error: return .red
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .disabled: return String(localized: "Sync off", bundle: .module)
        case .unavailable(let reason): return String(format: String(localized: "Sync unavailable: %@", bundle: .module), reason)
        case .signedOut: return String(localized: "Not signed in to iCloud", bundle: .module)
        case .idle: return String(localized: "Sync idle", bundle: .module)
        case .syncing: return String(localized: "Syncing", bundle: .module)
        case .error(let err): return String(format: String(localized: "Sync error: %@", bundle: .module), err.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
swift build --target Rubien 2>&1 | tail -5
```

Expected: `Build complete!` (with possible "Localizable.strings" warnings — harmless).

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/SyncStatusIcon.swift
git commit -m "add SyncStatusIcon toolbar view with 6 visual states"
```

---

### Task 11: `SyncStatusBanner` view modifier

**Files:**
- Create: `Sources/Rubien/Views/SyncStatusBanner.swift`

- [ ] **Step 1: Create the modifier**

Path: `Sources/Rubien/Views/SyncStatusBanner.swift`

```swift
import AppKit
import SwiftUI
import CloudKit
import RubienSync

/// View modifier that overlays a non-blocking banner or shows a modal
/// alert depending on the coordinator's current SyncStatus.
///
/// - `.error(.quotaExceeded)` → modal alert with "Open iCloud Settings"
/// - `.signedOut` / `.unavailable` / most user-actionable errors → top
///   overlay banner, auto-dismissable
/// - `.idle` / `.syncing` / transient errors → nothing
@available(macOS 14.0, *)
struct SyncStatusBanner: ViewModifier {
    let status: SyncStatus
    let onRetry: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let banner = bannerMessage {
                    bannerView(banner)
                }
            }
            .alert(
                String(localized: "iCloud storage full", bundle: .module),
                isPresented: .constant(isQuotaExceeded),
                actions: {
                    Button(String(localized: "Open iCloud Settings", bundle: .module)) {
                        openSystemSettingsAppleID()
                    }
                    Button(String(localized: "OK", bundle: .module), role: .cancel) {}
                },
                message: {
                    Text(String(localized: "Free space in iCloud Settings to resume sync.", bundle: .module))
                }
            )
    }

    private var isQuotaExceeded: Bool {
        if case .error(let err) = status, err.code == .quotaExceeded { return true }
        return false
    }

    private struct BannerMessage {
        let text: String
        let tone: Tone
        let action: Action?

        enum Tone { case info, warning, error }
        struct Action {
            let label: String
            let handler: () -> Void
        }
    }

    private var bannerMessage: BannerMessage? {
        switch status {
        case .disabled, .idle, .syncing:
            return nil
        case .unavailable(let reason):
            return BannerMessage(
                text: String(format: String(localized: "iCloud sync unavailable: %@", bundle: .module), reason),
                tone: .warning,
                action: BannerMessage.Action(
                    label: String(localized: "Try again", bundle: .module),
                    handler: onRetry
                )
            )
        case .signedOut:
            return BannerMessage(
                text: String(localized: "Signed out of iCloud — sync paused. Your library is safe locally.", bundle: .module),
                tone: .info,
                action: nil
            )
        case .error(let err):
            return bannerForError(err)
        }
    }

    private func bannerForError(_ err: CKError) -> BannerMessage? {
        switch err.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .zoneBusy, .requestRateLimited, .limitExceeded,
             .batchRequestFailed, .accountTemporarilyUnavailable,
             .changeTokenExpired:
            return nil  // transient / engine-handled
        case .quotaExceeded:
            return nil  // handled by .alert above
        case .notAuthenticated:
            return BannerMessage(
                text: String(localized: "Sync authentication failed. Re-authenticate iCloud in System Settings.", bundle: .module),
                tone: .error,
                action: BannerMessage.Action(
                    label: String(localized: "Open System Settings", bundle: .module),
                    handler: { openSystemSettingsAppleID() }
                )
            )
        case .managedAccountRestricted:
            return BannerMessage(
                text: String(localized: "Sync not available on this account (restricted by management policy). Your library stays local.", bundle: .module),
                tone: .warning,
                action: nil
            )
        case .tooManyRetries:
            return BannerMessage(
                text: String(localized: "Sync is stuck. Tap Retry to try again.", bundle: .module),
                tone: .error,
                action: BannerMessage.Action(
                    label: String(localized: "Retry", bundle: .module),
                    handler: onRetry
                )
            )
        case .serverRejectedRequest:
            return BannerMessage(
                text: String(localized: "Sync paused — server rejected request. See Console for details.", bundle: .module),
                tone: .error,
                action: nil
            )
        default:
            return BannerMessage(
                text: String(format: String(localized: "Sync error: %@. Will retry.", bundle: .module), err.localizedDescription),
                tone: .warning,
                action: nil
            )
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: BannerMessage) -> some View {
        HStack(spacing: 12) {
            Text(banner.text)
                .font(.callout)
            if let action = banner.action {
                Button(action.label, action: action.handler)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor(banner.tone), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func backgroundColor(_ tone: BannerMessage.Tone) -> Color {
        switch tone {
        case .info: return Color.blue.opacity(0.15)
        case .warning: return Color.orange.opacity(0.15)
        case .error: return Color.red.opacity(0.15)
        }
    }
}

@available(macOS 14.0, *)
extension View {
    func syncStatusBanner(status: SyncStatus, onRetry: @escaping () -> Void) -> some View {
        modifier(SyncStatusBanner(status: status, onRetry: onRetry))
    }
}

/// Opens System Settings' Apple ID pane. macOS 14+ uses the
/// `com.apple.systempreferences.AppleIDSettings` bundle id; older URL
/// schemes targeting `com.apple.preferences.AppleIDPrefPane` stopped
/// working when the Settings app was rewritten in macOS 13. Apple does
/// not ship a `CKContainer.openSettingsURLString` constant on macOS —
/// that's an iOS-only UIApplication API.
@available(macOS 14.0, *)
private func openSystemSettingsAppleID() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
swift build --target Rubien 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/SyncStatusBanner.swift
git commit -m "add SyncStatusBanner view modifier with per-code UX mapping"
```

---

### Task 12: `RubienSettingsView` with sync section

**Files:**
- Create: `Sources/Rubien/Views/RubienSettingsView.swift`

- [ ] **Step 1: Create the settings view**

Path: `Sources/Rubien/Views/RubienSettingsView.swift`

```swift
import SwiftUI
import RubienSync

@available(macOS 14.0, *)
struct RubienSettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        TabView {
            iCloudSyncPane
                .tabItem {
                    Label(
                        String(localized: "iCloud Sync", bundle: .module),
                        systemImage: "icloud"
                    )
                }
        }
        .frame(width: 480, height: 320)
    }

    @ViewBuilder
    private var iCloudSyncPane: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Sync library via iCloud", bundle: .module),
                    isOn: coordinator.toggleBinding
                )
                .confirmationDialog(
                    String(localized: "Enable iCloud Sync?", bundle: .module),
                    isPresented: Binding(
                        get: { coordinator.pendingConfirm },
                        set: { if !$0 { coordinator.cancelConfirm() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Enable Sync", bundle: .module)) {
                        coordinator.confirmEnable()
                    }
                    Button(String(localized: "Not Now", bundle: .module), role: .cancel) {
                        coordinator.cancelConfirm()
                    }
                } message: {
                    Text(String(
                        localized: "This will upload your library to iCloud and keep it in sync with other Macs on the same account. You can turn it off anytime, which stops syncing but keeps your local library intact.",
                        bundle: .module
                    ))
                }
            } footer: {
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .unavailable = coordinator.status {
                Section {
                    Button(String(localized: "Try again", bundle: .module)) {
                        Task { await coordinator.retryStartSync() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusCaption: String {
        switch coordinator.status {
        case .disabled:
            return String(localized: "Off — local library only.", bundle: .module)
        case .unavailable(let reason):
            return String(format: String(localized: "Sync unavailable: %@", bundle: .module), reason)
        case .signedOut:
            return String(localized: "Not signed in to iCloud on this Mac.", bundle: .module)
        case .idle:
            return String(localized: "Syncing via iCloud.", bundle: .module)
        case .syncing:
            return String(localized: "Syncing in progress…", bundle: .module)
        case .error(let err):
            return String(format: String(localized: "Sync error: %@", bundle: .module), err.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
swift build --target Rubien 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/RubienSettingsView.swift
git commit -m "add RubienSettingsView with iCloud Sync pane"
```

---

### Task 13: Wire coordinator + views into `RubienApp`

**Files:**
- Modify: `Sources/Rubien/RubienApp.swift`

- [ ] **Step 1: Add the coordinator as `@StateObject`, inject, wire toolbar + banner + Settings scene**

Modify `Sources/Rubien/RubienApp.swift`:

Add imports at the top:

```swift
import RubienSync
```

Inside the `RubienApp` struct, add a `@StateObject` for the coordinator:

```swift
    @StateObject private var syncCoordinator = SyncCoordinator(appDatabase: AppDatabase.shared)
```

Replace the existing `WindowGroup { ContentView() ... }` scene's body to inject the coordinator and apply the banner:

```swift
        WindowGroup {
            ContentView()
                .environmentObject(syncCoordinator)
                .overlay(alignment: .top) {
                    if let toast = addinToast {
                        AddinToast(message: toast.message, tone: toast.tone)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .syncStatusBanner(status: syncCoordinator.status) {
                    Task { await syncCoordinator.retryStartSync() }
                }
                .task {
                    await syncCoordinator.startIfEnabled()
                }
                .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
                    // ... unchanged body
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SyncStatusIcon(status: syncCoordinator.status)
                    }
                }
        }
```

Add a new `Settings` scene after the `WindowGroup`, before the closing brace of `var body`:

```swift
        Settings {
            RubienSettingsView()
                .environmentObject(syncCoordinator)
        }
```

(The existing `.windowStyle`, `.defaultSize`, `.commands` modifiers stay attached to `WindowGroup` — don't move them to the `Settings` scene.)

- [ ] **Step 2: Build and run**

```bash
swift build --target Rubien 2>&1 | tail -5
swift run Rubien &
sleep 3
pkill -f "Rubien$" || true
```

Expected: builds cleanly; app opens, cloud icon appears in toolbar in `.disabled` state; Cmd+, opens the Settings window.

- [ ] **Step 3: Commit — Commit 2 complete**

```bash
git add Sources/Rubien/RubienApp.swift
git commit -m "$(cat <<'EOF'
wire SyncCoordinator + toolbar icon + banner + Settings into RubienApp

Completes Commit 2: SwiftUI surface. The coordinator is instantiated
at startup, injected as @EnvironmentObject, observed by the toolbar
cloud icon and the banner view modifier, and surfaced in a Settings
scene with the iCloud Sync pane. Sync stays .disabled by default
because userEnabled reads as false from UserDefaults on first launch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Commit 3 — CLI sync status (Tasks 14–16)

### Task 14: Add `RubienSync` dependency to `RubienCLI`

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add dependency**

Modify `Package.swift` — update the `RubienCLI` target's `dependencies`:

```swift
        .executableTarget(
            name: "RubienCLI",
            dependencies: [
                "RubienCore",
                "RubienSync",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
```

Also add `RubienSync` to the `RubienCLITests` target:

```swift
        .testTarget(
            name: "RubienCLITests",
            dependencies: ["RubienSync"],
            path: "Tests/RubienCLITests"
        ),
```

- [ ] **Step 2: Build to verify**

```bash
swift build --target RubienCLI 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "link RubienSync into RubienCLI for sync status subcommand"
```

---

### Task 15: `sync status` subcommand implementation

**Files:**
- Create: `Sources/RubienCLI/SyncCommands.swift`
- Modify: `Sources/RubienCLI/RubienCLI.swift`
- Test: `Tests/RubienCLITests/SyncStatusCommandTests.swift`

- [ ] **Step 1: Write failing test**

Path: `Tests/RubienCLITests/SyncStatusCommandTests.swift`

```swift
import XCTest
import Foundation

final class SyncStatusCommandTests: XCTestCase {

    private var cliURL: URL {
        URL(fileURLWithPath: ".build/debug/rubien-cli")
    }

    func testSyncStatusReturnsJSONWithExpectedFields() throws {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["sync", "status"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)

        // Required fields per spec.
        for key in [
            "enabled", "containerIdentifier", "entitlementPresent",
            "iCloudAccountAvailable", "appLockHeld", "baselineState",
            "dirtyByEntityType", "tombstoneCount", "syncEngineState",
            "schemaVersion"
        ] {
            XCTAssertNotNil(json?[key], "missing field '\(key)' in JSON output")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift build && swift test --filter SyncStatusCommandTests 2>&1 | tail -10
```

Expected: test fails — `sync status` subcommand unknown.

- [ ] **Step 3: Create the subcommand**

Path: `Sources/RubienCLI/SyncCommands.swift`

```swift
import Foundation
import ArgumentParser
import RubienCore
import RubienSync
import GRDB

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Inspect iCloud sync state.",
        subcommands: [StatusCommand.self]
    )
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print sync state as JSON."
    )

    func run() throws {
        let db = try AppDatabase(makePool())
        let defaults = UserDefaults.standard
        let stateStore = SyncStateStore()

        let dirtyByType: [String: Int] = try db.dbWriter.read { db in
            var counts: [String: Int] = [:]
            for type in SyncEntityType.allCases {
                let n = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM syncState WHERE entityType = ? AND isDirty = 1",
                    arguments: [type.rawValue]
                ) ?? 0
                counts[type.rawValue] = n
            }
            return counts
        }

        let (confirmed, unconfirmed): (Int, Int) = try db.dbWriter.read { db in
            let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE confirmedByServer = 1") ?? 0
            let u = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE confirmedByServer = 0") ?? 0
            return (c, u)
        }

        let baselineState: String = try db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='baselineState'")
                ?? "pending"
        }

        let sidecarPath = AppDatabase.syncEngineStateURL
        let sidecarExists = FileManager.default.fileExists(atPath: sidecarPath.path)
        let sidecarMtime: String?
        if sidecarExists,
           let attrs = try? FileManager.default.attributesOfItem(atPath: sidecarPath.path),
           let date = attrs[.modificationDate] as? Date {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            sidecarMtime = fmt.string(from: date)
        } else {
            sidecarMtime = nil
        }

        let lockFile = SyncFileLock.defaultURL
        let appLockHeld: Bool
        if FileManager.default.fileExists(atPath: lockFile.path),
           let lock = try? SyncFileLock(fileURL: lockFile) {
            appLockHeld = (try? lock.tryLockExclusive()) != true
            if (try? lock.unlock()) != nil {}
        } else {
            appLockHeld = false
        }

        // JSONSerialization rejects Optional<T>.none — a bare `sidecarMtime`
        // bound as Any would serialize as the string "nil" or throw,
        // depending on the Swift runtime. Use NSNull explicitly for
        // absent optionals so the contract stays stable.
        let syncEngineState: [String: Any] = [
            "sidecarPath": sidecarPath.path,
            "sidecarExists": sidecarExists,
            "sidecarLastModified": sidecarMtime.map { $0 as Any } ?? NSNull()
        ]

        let output: [String: Any] = [
            "enabled": defaults.bool(forKey: "rubien.sync.enabled"),
            "containerIdentifier": SyncConstants.containerIdentifier,
            "entitlementPresent": Bundle.main.object(
                forInfoDictionaryKey: "com.apple.developer.icloud-container-identifiers"
            ) != nil,
            "iCloudAccountAvailable": FileManager.default.ubiquityIdentityToken != nil,
            "appLockHeld": appLockHeld,
            "baselineState": baselineState,
            "dirtyByEntityType": dirtyByType,
            "tombstoneCount": ["confirmed": confirmed, "unconfirmed": unconfirmed],
            "syncEngineState": syncEngineState,
            "schemaVersion": "v1"
        ]

        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func makePool() throws -> DatabasePool {
        let url = AppDatabase.syncEngineStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("library.sqlite")
        return try DatabasePool(path: url.path)
    }
}
```

- [ ] **Step 4: Register the subcommand**

Modify `Sources/RubienCLI/RubienCLI.swift` — add `SyncCommand.self` to the top-level command's `subcommands` array:

```swift
    static let configuration = CommandConfiguration(
        commandName: "rubien-cli",
        subcommands: [
            // ... existing entries
            SyncCommand.self,
        ]
    )
```

(Locate the existing `subcommands: [...]` list and append `SyncCommand.self` at the end.)

- [ ] **Step 5: Build and run the test**

```bash
swift build 2>&1 | tail -5
swift test --filter SyncStatusCommandTests 2>&1 | tail -5
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RubienCLI/SyncCommands.swift Sources/RubienCLI/RubienCLI.swift Tests/RubienCLITests/SyncStatusCommandTests.swift
git commit -m "$(cat <<'EOF'
add `rubien-cli sync status` JSON subcommand

11-field JSON output for "my sync is wedged" diagnosis: enabled,
container id, entitlement probe, iCloud account, app-lock probe,
baseline state, per-entity dirty counts, tombstone confirmed/unconfirmed,
sidecar path/mtime, schema version. Never instantiates SyncedLibrary
so the CLI works in unentitled dev builds.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 16: Update `CLAUDE.md` + `Docs/CLI-Reference.md`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `Docs/CLI-Reference.md`

- [ ] **Step 1: Update `CLAUDE.md` CLI description**

Modify `CLAUDE.md` — find the line that says "The CLI does not link it" (RubienSync) and update:

```markdown
- **`RubienCLI`** (executable, binary name `rubien-cli`) — built with swift-argument-parser. Links `RubienCore` and `RubienSync` (the latter for the `sync status` subcommand, which reads sync bookkeeping tables + the engine-state sidecar file).
```

(Locate the existing RubienCLI bullet under "### CLI" or "Four Swift targets" and replace.)

- [ ] **Step 2: Add `sync status` section to `Docs/CLI-Reference.md`**

Find the subcommand table near the top of `Docs/CLI-Reference.md` and add a row:

```markdown
| `sync status` | Inspect iCloud sync state (JSON only) |
```

Then add a per-subcommand section at the bottom:

```markdown
## sync status

Prints iCloud sync state as JSON. Never instantiates the CloudKit sync
engine — reads `syncState` / `tombstone` / `syncSession` tables directly
and probes entitlement / iCloud availability via OS-level APIs. Safe to
run while the app is using the library (acquires and releases the sync
file lock only to read `appLockHeld`).

### Example

```bash
$ rubien-cli sync status
{
  "appLockHeld" : false,
  "baselineState" : "complete",
  "containerIdentifier" : "iCloud.com.rubien.app",
  "dirtyByEntityType" : { "reference" : 3, "tag" : 0, ... },
  "enabled" : true,
  "entitlementPresent" : true,
  "iCloudAccountAvailable" : true,
  "schemaVersion" : "v1",
  "syncEngineState" : {
    "sidecarExists" : true,
    "sidecarLastModified" : "2026-04-22T14:32:11Z",
    "sidecarPath" : "/Users/.../Rubien/sync-engine-state.bin"
  },
  "tombstoneCount" : { "confirmed" : 12, "unconfirmed" : 0 }
}
```

### Fields

- `enabled` — user's preference value (UserDefaults `"rubien.sync.enabled"`)
- `containerIdentifier` — resolved container ID, with env-var override applied
- `entitlementPresent` — Info.plist entitlement probe
- `iCloudAccountAvailable` — `FileManager.ubiquityIdentityToken != nil`
- `appLockHeld` — non-blocking probe of the sync file lock; `true` means the app is currently using CloudKit
- `baselineState` — `"pending"` or `"complete"`
- `dirtyByEntityType` — per-table count of rows with `isDirty=1`
- `tombstoneCount` — `.confirmed` (server ack'd) vs `.unconfirmed` (pending delete)
- `syncEngineState` — sidecar-file metadata
- `schemaVersion` — DB migration version
```

- [ ] **Step 3: Commit — Commit 3 complete**

```bash
git add CLAUDE.md Docs/CLI-Reference.md
git commit -m "$(cat <<'EOF'
document sync status CLI subcommand and RubienCLI→RubienSync link

CLAUDE.md's "CLI does not link it" claim is stale now that sync
status needs SyncStateStore/SyncEntityType/SyncFileLock. Docs/CLI-
Reference.md gains a new subcommand row and per-field documentation
for the JSON output.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Commit 4 — Operational hardening (Tasks 17–18)

### Task 17: Add dormant entitlement entries

**Files:**
- Modify: `Sources/Rubien/Rubien.entitlements`

- [ ] **Step 1: Add iCloud entitlement keys**

Modify `Sources/Rubien/Rubien.entitlements` — add the CloudKit entries before the closing `</dict>`:

```xml
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.rubien.app</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
```

Full file after edit:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.rubien.app</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Build to verify**

```bash
swift build --target Rubien 2>&1 | tail -5
```

Expected: `Build complete!`. Entitlements file is `.exclude`d from SPM target sources (see Package.swift), so this change doesn't affect the build — it's only read by `xcodebuild` / `scripts/build-app.sh`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Rubien.entitlements
git commit -m "add dormant iCloud entitlement keys to app bundle"
```

---

### Task 18: Sync operational runbook

**Files:**
- Create: `Docs/Sync-Runbook.md`

- [ ] **Step 1: Create the runbook**

Path: `Docs/Sync-Runbook.md`

```markdown
# iCloud Sync — operational setup runbook

Post-enrollment steps to take Rubien's sync from `.unavailable` to actually syncing.

## Prerequisites

- Active paid Apple Developer Program membership
- Bundle ID `com.rubien.app` on your developer team
- Mac mini + MacBook (or any two Macs) signed into the same iCloud account

## Steps (do in order)

### 1. Create the CloudKit container

1. Sign in at <https://icloud.developer.apple.com>
2. Click **New Container**
3. Identifier: `iCloud.com.rubien.app` (must exactly match `SyncConstants.containerIdentifier`)
4. Save

### 2. Add the CloudKit capability in Xcode

If building via Xcode's GUI:

1. Open the project in Xcode → select the Rubien target
2. Signing & Capabilities tab
3. Click **+ Capability** → choose **iCloud**
4. Check **CloudKit**
5. Under **Containers**, click **+** and select the `iCloud.com.rubien.app` container created above
6. Xcode updates the entitlements file automatically; the CloudKit capability's container should match the `<array><string>iCloud.com.rubien.app</string></array>` entry we ship dormant.

If building via `scripts/build-app.sh` (which calls `xcodebuild`):

- A signing identity with the CloudKit capability on the `com.rubien.app` bundle ID must be present in your keychain
- Without it, the build produces an unsigned app whose entitlements are stripped and sync stays in `.unavailable`
- xcconfig-driven signing is a separate follow-up; for first smoke test, use the Xcode GUI path

### 3. Smoke test

On the Mac you use for development:

1. Build and launch Rubien
2. Cmd+, to open Settings → iCloud Sync pane
3. Flip the toggle on; confirm the first-run sheet
4. Toolbar cloud icon should go blue (syncing), then to accent color (idle) within ~10s
5. Open Console.app, filter `subsystem:Rubien category:SyncedLibrary`; you should see `reconciled N pending changes` followed by `sent N records`

### 4. Second-Mac verification

1. Sign into the same iCloud account on a second Mac
2. Build + install Rubien
3. Cmd+, → iCloud Sync → toggle on + confirm
4. Library should populate from the cloud within ~30s
5. Create a reference on Mac A; verify it appears on Mac B within ~10s
6. Edit the same reference on both within a few seconds; observe "server wins" behavior (whichever pushed first, other side overwrites — documented quirk of v1 merge policy)
7. Delete on Mac A; verify removal on Mac B within ~10s

### 5. Failure diagnostics

From the CLI: `swift run rubien-cli sync status` gives JSON.

- `entitlementPresent: false` → Xcode signing didn't grant the entitlement; check team + provisioning
- `iCloudAccountAvailable: false` → user not signed into iCloud on this Mac
- `enabled: false` → user hasn't flipped the toggle on
- `dirtyByEntityType` not draining → engine isn't pushing; check Console for CKError codes
- `tombstoneCount.unconfirmed > 0` after pushes drain → deletes aren't being ack'd by the server (likely transient; retry on next app foreground)

### 6. Reset (destructive, only if stuck)

To force a full re-sync:

```bash
# Stop the app first
rm "$HOME/Library/Application Support/Rubien/sync-engine-state.bin"
# Launch the app; next startup reconciliation will push every row dirty
```

To wipe the iCloud copy (can't be undone): use the CloudKit Dashboard "Delete Zone" action in the Library zone. The next app launch with sync enabled will re-upload everything as a fresh baseline.

## Known follow-ups

- A-pks migration (UUID primary keys) — currently using stringified Int64 rowIDs; two devices inserting independently offline can collide on rowID. Sync one device first before inserting on the second until A-pks ships.
- Field-level LWW merge — current policy is server-wins on conflict; planned refinement uses `dateModified` for finer-grained merges.
- `rubien-cli sync push / pull / reset` subcommands — deferred; only `sync status` ships in v1.
- xcconfig-driven entitlement injection for `scripts/build-app.sh` — use Xcode GUI signing for first testing.
```

- [ ] **Step 2: Commit — Commit 4 complete**

```bash
git add Docs/Sync-Runbook.md
git commit -m "$(cat <<'EOF'
add iCloud sync operational runbook

Step-by-step setup for post-enrollment smoke test: CloudKit container
creation, Xcode capability wiring, single-Mac verification, two-Mac
convergence test, CLI diagnostics, reset procedure. Documents known
follow-ups (A-pks, LWW, xcconfig) so the on-call reader isn't
surprised by the v1 shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification after all 18 tasks

Full regression test + manual smoke:

- [ ] **Full test suite passes**

```bash
swift test 2>&1 | grep Executed | tail -1
```

Expected: `Executed 400+ tests, with 0 failures` (or 1 pre-existing CLI failure from `testViewsListIncludesDefault`, which is unrelated to sync work).

- [ ] **Manual smoke: app launches in `.disabled` state**

```bash
swift run Rubien &
sleep 3
pkill -f "Rubien$" || true
```

Verify in the app: toolbar icon is muted slash-cloud; Cmd+, opens Settings → iCloud Sync pane with toggle off + caption "Off — local library only."

- [ ] **Manual smoke: toggling on shows `.unavailable` (because no entitlement in `swift run` build)**

Launch app, flip toggle → confirm sheet appears. Click "Enable Sync". Expected: toolbar icon goes to warning-orange; status caption changes to "Sync unavailable: No CloudKit entitlement in app bundle". No crash. The `.unavailable` banner appears at the top of the window.

- [ ] **CLI emits the expected JSON shape**

```bash
swift run rubien-cli sync status
```

Expected: JSON with all 11 required fields, `enabled: true` / `false` matching the UserDefaults state.

---

## Open follow-ups (tracked, not blocking plan completion)

- A-pks UUID migration
- Field-level LWW merge
- `rubien-cli sync push / pull / reset` parity
- CKAsset pipeline for PDFs (follow-up work stream)
- xcconfig-driven entitlements for `scripts/build-app.sh` release builds
- "Wipe iCloud library" destructive action
