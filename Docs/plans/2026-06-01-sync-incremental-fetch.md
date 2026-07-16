# Sync Layer A — Incremental Fetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make remote edits/deletes from another device reach a running Mac without a full token-wipe re-pull, by explicitly driving `CKSyncEngine.fetchChanges()` on app launch, app foreground, and a tunable ~90s idle timer.

**Architecture:** A new actor-isolated `SyncedLibrary.fetchRemoteChanges()` primitive (the portable core) is driven by `SyncCoordinator` (Mac-only, `@MainActor`) on three triggers. The coordinator owns a cancellable idle-poll `Task` gated on its lifecycle generation, subscribes to `NSApplication` activation notifications, and resets a per-fetch backoff on success. A separate fix makes the sync-status banner track fetch and send in-flight independently so a manual fetch can't prematurely flip it to idle.

**Tech Stack:** Swift 6 (strict concurrency, actors, `@MainActor`), CloudKit `CKSyncEngine`, AppKit `NSApplication`, GRDB 7, XCTest.

**Reference spec:** `Docs/specs/2026-06-01-sync-incremental-fetch-design.md`

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/RubienSync/SyncedLibrary.swift` | Engine actor: fetch primitive + status in-flight tracking | Modify |
| `Sources/RubienSync/SyncConstants.swift` | Shared sync constants | Modify (add 2 intervals) |
| `Sources/Rubien/Sync/SyncCoordinator.swift` | Mac trigger wiring: seams, handlers, idle timer, teardown | Modify |
| `Tests/RubienSyncTests/SyncStatusFlickerTests.swift` | Status flicker coverage | Create |
| `Tests/RubienTests/SyncCoordinatorTests.swift` | Backoff + trigger/timer coverage | Modify (append) |
| `Docs/Sync-Runbook.md` | Operator doc | Modify (§4) |

`RubienApp.swift` is intentionally **unchanged** — the foreground signal comes from the coordinator's own `NSApplication` subscription.

---

## Task 1: Status-flicker fix (fetch/send tracked independently)

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift` (state near line 345; `handleEvent` cases at lines 547–551)
- Test: `Tests/RubienSyncTests/SyncStatusFlickerTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/RubienSyncTests/SyncStatusFlickerTests.swift`:

```swift
#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, iOS 17.0, *)
final class SyncStatusFlickerTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() { db = nil; super.tearDown() }

    /// A manual fetch finishing while an automatic send is still in flight
    /// must NOT publish `.idle`. Expected emission order: .syncing, .syncing, .idle.
    func testFetchFinishingMidSendDoesNotPublishIdle() async {
        let library = SyncedLibrary(appDatabase: db)
        var iterator = await library.statusStream.makeAsyncIterator()

        await library.noteSend(inFlight: true)    // → .syncing
        await library.noteFetch(inFlight: true)   // → .syncing
        await library.noteFetch(inFlight: false)  // send still in flight → no emit
        await library.noteSend(inFlight: false)   // both quiescent → .idle

        let a = await iterator.next()
        let b = await iterator.next()
        let c = await iterator.next()
        XCTAssertEqual(a, .syncing)
        XCTAssertEqual(b, .syncing)
        XCTAssertEqual(c, .idle, "idle must only publish once BOTH fetch and send are done")
    }

    /// A standalone fetch cycle still resolves to idle.
    func testStandaloneFetchPublishesIdle() async {
        let library = SyncedLibrary(appDatabase: db)
        var iterator = await library.statusStream.makeAsyncIterator()

        await library.noteFetch(inFlight: true)   // → .syncing
        await library.noteFetch(inFlight: false)  // → .idle

        XCTAssertEqual(await iterator.next(), .syncing)
        XCTAssertEqual(await iterator.next(), .idle)
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SyncStatusFlickerTests`
Expected: BUILD FAILURE — `value of type 'SyncedLibrary' has no member 'noteFetch'` / `noteSend`.

- [ ] **Step 3: Add the in-flight state + helpers**

In `Sources/RubienSync/SyncedLibrary.swift`, add two stored properties next to the other actor state (e.g. just below the `transactionObserver` declaration around line 345):

```swift
    /// Independent in-flight flags so a manual fetch completing mid-send (or
    /// vice-versa) doesn't publish `.idle` while the other operation is still
    /// running. Without this, Layer A polling makes a brief banner flicker
    /// visible whenever a poll's fetch overlaps an automatic send.
    private var isFetchInFlight = false
    private var isSendInFlight  = false
```

Add the helpers (place them right after `publishStatus(_:)` around line 333):

```swift
    /// Update fetch in-flight state and publish status. `internal` so
    /// `SyncStatusFlickerTests` can drive the transitions without standing up
    /// a real `CKSyncEngine` (unentitled XCTest raises `CKException`).
    func noteFetch(inFlight: Bool) {
        isFetchInFlight = inFlight
        if inFlight { publishStatus(.syncing) } else { publishIdleIfQuiescent() }
    }

    func noteSend(inFlight: Bool) {
        isSendInFlight = inFlight
        if inFlight { publishStatus(.syncing) } else { publishIdleIfQuiescent() }
    }

    private func publishIdleIfQuiescent() {
        guard !isFetchInFlight, !isSendInFlight else { return }
        publishStatus(.idle)
    }
```

- [ ] **Step 4: Route `handleEvent` through the helpers**

In `handleEvent` (lines 547–551), replace:

```swift
        case .willFetchChanges, .willSendChanges:
            publishStatus(.syncing)

        case .didFetchChanges, .didSendChanges:
            publishStatus(.idle)
```

with:

```swift
        case .willFetchChanges:
            noteFetch(inFlight: true)
        case .willSendChanges:
            noteSend(inFlight: true)
        case .didFetchChanges:
            noteFetch(inFlight: false)
        case .didSendChanges:
            noteSend(inFlight: false)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter SyncStatusFlickerTests`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/RubienSync/SyncedLibrary.swift Tests/RubienSyncTests/SyncStatusFlickerTests.swift
git commit -m "sync: track fetch/send in-flight separately to fix status flicker

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `fetchRemoteChanges()` primitive + reroute error-path fetches

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift` (add method near the engine accessor ~line 413; reroute lines 1025–1027 and 1079–1081)

This task's core is the live `engine.fetchChanges()` call, which cannot run in an unentitled XCTest process (`CKException`) — so it is build-verified here and exercised by the coordinator tests (Task 4, via the injected seam) and manual two-device verification (Task 7). This matches how the codebase already handles engine-touching code.

- [ ] **Step 1: Add the guarded fetch primitive**

In `Sources/RubienSync/SyncedLibrary.swift`, add a stored flag next to `isFetchInFlight` (from Task 1):

```swift
    /// Overlap guard for explicit fetches. `SyncedLibrary` is an actor, so the
    /// read-then-set below has no suspension point and is race-free across
    /// concurrent callers (launch / foreground / idle timer / error recovery).
    private var isExplicitFetchRunning = false
```

Add the method just above the `private var engine: CKSyncEngine` accessor (line 413):

```swift
    /// Drive an explicit incremental fetch. The single funnel for every
    /// fetch trigger (launch, foreground, idle timer) and the two reactive
    /// error-recovery paths, so the overlap guard is the one concurrency
    /// policy. Returns `true` on success or a no-op skip (another fetch is
    /// already in flight); `false` on error, which the idle timer uses to back
    /// off. Only called once the library is live, so `engine` already exists.
    @discardableResult
    public func fetchRemoteChanges() async -> Bool {
        guard !isExplicitFetchRunning else { return true }
        isExplicitFetchRunning = true
        defer { isExplicitFetchRunning = false }
        do {
            try await engine.fetchChanges()
            return true
        } catch {
            log.error("fetchRemoteChanges failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
```

- [ ] **Step 2: Reroute the `.unknownItem` recovery fetch**

In `handleSentZoneChanges`, replace the `.unknownItem` block's scheduling (lines 1023–1027):

```swift
                    // Schedule outside the delegate callback (Apple's docs:
                    // don't call fetchChanges synchronously from handleEvent).
                    Task { [engine] in
                        _ = try? await engine.fetchChanges()
                    }
```

with:

```swift
                    // Schedule outside the delegate callback (Apple's docs:
                    // don't call fetchChanges synchronously from handleEvent).
                    // Route through fetchRemoteChanges so every fetch shares
                    // one overlap-guard policy.
                    Task { await self.fetchRemoteChanges() }
```

- [ ] **Step 3: Reroute the `.serverRecordChanged`-without-serverRecord fetch**

In `handleServerRecordChanged`, replace lines 1078–1081:

```swift
            log.error("serverRecordChanged without serverRecord — re-fetch to recover")
            Task { [engine] in
                _ = try? await engine.fetchChanges()
            }
            return
```

with:

```swift
            log.error("serverRecordChanged without serverRecord — re-fetch to recover")
            Task { await self.fetchRemoteChanges() }
            return
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: builds clean. (No unit test — the engine call is unentitled-XCTest-hostile; covered via the coordinator seam in Task 4 and manual verification in Task 7.)

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienSync/SyncedLibrary.swift
git commit -m "sync: add guarded fetchRemoteChanges() and route error-path fetches through it

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Idle-fetch constants + `nextBackoff` pure function

**Files:**
- Modify: `Sources/RubienSync/SyncConstants.swift`
- Modify: `Sources/Rubien/Sync/SyncCoordinator.swift` (add `static nextBackoff`)
- Test: `Tests/RubienTests/SyncCoordinatorTests.swift` (append)

- [ ] **Step 1: Add the constants**

In `Sources/RubienSync/SyncConstants.swift`, add inside the `SyncConstants` enum (after `tombstoneRetention`):

```swift
    /// Steady-state idle poll interval (seconds) while the app is frontmost
    /// and sync is active. Bounds worst-case idle-window staleness: a remote
    /// change made while you stare at an idle window appears within ~this long.
    /// Tunable — lower is snappier but spends more no-op fetch round-trips;
    /// mostly moot once push (Layer B) lands. Foreground/launch fetches are
    /// always immediate regardless of this value.
    public static let idleFetchInterval: TimeInterval = 90

    /// Backoff cap (seconds) for the idle poll after repeated fetch failures.
    public static let maxIdleFetchInterval: TimeInterval = 900
```

- [ ] **Step 2: Write the failing test**

Append to `Tests/RubienTests/SyncCoordinatorTests.swift` before the final closing `}` (line 338), inside the class:

```swift
    // MARK: - Idle-fetch backoff

    func testNextBackoffResetsToBaseOnSuccess() {
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 360, failed: false, base: 90), 90)
    }

    func testNextBackoffDoublesOnFailure() {
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 90, failed: true, base: 90), 180)
    }

    func testNextBackoffCapsAtMaxIdleInterval() {
        // 600 * 2 = 1200, capped to maxIdleFetchInterval (900).
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 600, failed: true, base: 90), 900)
        // Already at cap stays at cap.
        XCTAssertEqual(SyncCoordinator.nextBackoff(current: 900, failed: true, base: 90), 900)
    }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter SyncCoordinatorTests/testNextBackoffResetsToBaseOnSuccess`
Expected: BUILD FAILURE — `type 'SyncCoordinator' has no member 'nextBackoff'`.

- [ ] **Step 4: Implement `nextBackoff`**

In `Sources/Rubien/Sync/SyncCoordinator.swift`, add this static method inside the class (e.g. just above `// MARK: - Test hooks` near line 395):

```swift
    // MARK: - Idle-fetch backoff

    /// Pure backoff step for the idle poll: reset to `base` on success, double
    /// toward `SyncConstants.maxIdleFetchInterval` on failure. Pure + static so
    /// it's unit-tested without wall-clock dependence.
    static func nextBackoff(current: TimeInterval, failed: Bool, base: TimeInterval) -> TimeInterval {
        failed ? min(current * 2, SyncConstants.maxIdleFetchInterval) : base
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SyncCoordinatorTests/testNextBackoff`
Expected: PASS (all three backoff tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/RubienSync/SyncConstants.swift Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "sync: add idle-fetch interval constants and nextBackoff helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Coordinator triggers, idle timer, and teardown

**Files:**
- Modify: `Sources/Rubien/Sync/SyncCoordinator.swift` (imports; init seams ~93–123; lifecycle state ~210–219; `performStopSync` ~305–318; add handlers/timer)
- Test: `Tests/RubienTests/SyncCoordinatorTests.swift` (append)

This task adds the trigger state machine and timer, plus their teardown, and tests them by driving the handlers directly. Task 5 then auto-wires them to launch + `NSApplication` events.

- [ ] **Step 1: Add `import AppKit`**

At the top of `Sources/Rubien/Sync/SyncCoordinator.swift`, the imports block begins (line 2) with `import Combine`. Add below `import Combine`:

```swift
import AppKit
```

- [ ] **Step 2: Add the three injected seams**

In the `// MARK: - Collaborators` / DI region, add stored properties (place after `startLibrary` near line 83):

```swift
    /// Fetch seam, mirroring `startLibrary`. Production binds to the library's
    /// `fetchRemoteChanges()`; tests inject a counting spy so the timer /
    /// foreground logic is verifiable without touching the real engine.
    private let fetchLibrary: @Sendable (SyncedLibrary) async -> Bool

    /// Idle-poll cadence (seconds). Injected so timer tests use a tiny value.
    private let idleFetchInterval: TimeInterval

    /// Whether the app is frontmost. Injected for deterministic tests; prod
    /// reads `NSApp.isActive`.
    private let isAppActive: @MainActor () -> Bool
```

Extend the `init` signature — add these parameters between `startLibrary:` and `lockURL:` (around line 99):

```swift
        fetchLibrary: (@Sendable (SyncedLibrary) async -> Bool)? = nil,
        idleFetchInterval: TimeInterval = SyncConstants.idleFetchInterval,
        isAppActive: (@MainActor () -> Bool)? = nil,
```

And assign them in the init body (after the `startLibrary` assignment, before `self.userEnabled = …` near line 122):

```swift
        self.fetchLibrary = fetchLibrary ?? { await $0.fetchRemoteChanges() }
        self.idleFetchInterval = idleFetchInterval
        self.isAppActive = isAppActive ?? { NSApp.isActive }
```

- [ ] **Step 3: Add the timer/observer state**

In the `// MARK: - Lifecycle state` region (after `pdfQueueKickCancellable` near line 219), add:

```swift
    /// The idle-poll task. Owned here so `performStopSync` can cancel it; the
    /// loop also re-checks `lifecycleGeneration` each tick so a stale timer
    /// can never write to the DB after the single-writer flock is released.
    private var idleFetchTask: Task<Void, Never>?

    /// Activation-notification observer tokens, removed on stop.
    private var activationObservers: [NSObjectProtocol] = []

    /// Test-only: counts how many times a NEW idle-poll task was actually
    /// created (guard-passes), proving start-idempotency.
    private(set) var idleTimerStartCountForTest = 0
```

- [ ] **Step 4: Write the failing tests**

Append to `Tests/RubienTests/SyncCoordinatorTests.swift` inside the class (before the final `}`):

```swift
    // MARK: - Incremental-fetch triggers

    /// Thread-safe call counter for the injected fetch seam. Always reports
    /// success — failure backoff is covered deterministically by the pure
    /// `nextBackoff` tests, not by driving a failing fetch through the timer.
    private actor FetchSpy {
        private(set) var count = 0
        func record() -> Bool { count += 1; return true }
    }

    private func allPassProbes() -> SyncCoordinator.Probes {
        SyncCoordinator.Probes(
            bundleHasEntitlement: { true },
            ubiquityIdentityToken: { "token" as NSCoding },
            tryCKContainerInit: { _ in nil },
            accountStatus: { _ in .available }
        )
    }

    private func makeTriggerCoordinator(
        spy: FetchSpy,
        interval: TimeInterval,
        appActive: @escaping @MainActor () -> Bool
    ) -> SyncCoordinator {
        SyncCoordinator(
            appDatabase: db,
            defaults: defaults,
            probes: allPassProbes(),
            makeLibrary: stubLibraryFactory(),
            startLibrary: { _ in },
            fetchLibrary: { _ in await spy.record() },
            idleFetchInterval: interval,
            isAppActive: appActive,
            lockURL: tmpLockURL
        )
    }

    // All trigger tests start with `appActive: { false }` so `performStartSync`
    // (after Task 5 wires the launch hook) does NOT auto-fire — each test drives
    // the handler/tick directly, staying independently verifiable. No assertion
    // depends on `Task.sleep` elapsing: per-tick behaviour is exercised through
    // the deterministic `runIdlePollTickForTest` seam.

    func testDidBecomeActiveFiresImmediateFetchAndStartsTimer() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()
        XCTAssertEqual(await spy.count, 0, "inactive start fires nothing")

        await coordinator.handleDidBecomeActive()
        XCTAssertEqual(await spy.count, 1, "activate fires exactly one immediate fetch")
        XCTAssertEqual(coordinator.idleTimerStartCountForTest, 1, "activate starts one idle timer")

        await coordinator.performStopSyncForTest()
    }

    func testIdlePollTickFetchesWhenActive() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()

        let outcome = await coordinator.runIdlePollTickForTest()
        XCTAssertEqual(outcome, .completed(ok: true), "an active tick fetches")
        XCTAssertEqual(await spy.count, 1, "the tick drove exactly one fetch")

        await coordinator.performStopSyncForTest()
    }

    func testIdlePollTickIsNoOpForStaleGeneration() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()
        let staleGeneration = coordinator.lifecycleGenerationForTest

        await coordinator.performStopSyncForTest()   // bumps the generation

        let outcome = await coordinator.runIdlePollTickForTest(generation: staleGeneration)
        XCTAssertEqual(outcome, .stopped, "a tick from a prior lifecycle must stop, not fetch")
        XCTAssertEqual(await spy.count, 0, "no fetch after teardown")
    }

    func testResignCancelsTimerSoReactivateStartsAFreshOne() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()

        await coordinator.handleDidBecomeActive()
        XCTAssertEqual(coordinator.idleTimerStartCountForTest, 1)

        coordinator.handleWillResignActive()           // cancels + nils the task
        await coordinator.handleDidBecomeActive()       // guard sees nil → starts a NEW timer
        XCTAssertEqual(
            coordinator.idleTimerStartCountForTest, 2,
            "resign must cancel the timer so the next activate starts a fresh one"
        )

        await coordinator.performStopSyncForTest()
    }

    func testDoubleActivateDoesNotStackTimers() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()

        await coordinator.handleDidBecomeActive()
        await coordinator.handleDidBecomeActive()          // no intervening resign → guard blocks
        XCTAssertEqual(
            coordinator.idleTimerStartCountForTest, 1,
            "a second activate without a resign must not start a second timer"
        )

        await coordinator.performStopSyncForTest()
    }
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `swift test --filter SyncCoordinatorTests/testDidBecomeActiveFiresImmediateFetchAndStartsTimer`
Expected: BUILD FAILURE — `handleDidBecomeActive` / `runIdlePollTickForTest` / `IdlePollOutcome` undefined.

- [ ] **Step 6: Implement the handlers, timer, and subscription methods**

In `Sources/Rubien/Sync/SyncCoordinator.swift`, add a new section (e.g. after `kickPDFUploadDrainer()` near line 393):

```swift
    // MARK: - Incremental remote fetch (Layer A)

    /// App became frontmost (or sync just started while active): fetch now and
    /// ensure the idle poll is running. Idempotent — safe to call repeatedly.
    func handleDidBecomeActive() async {
        guard library != nil else { return }
        await fetchRemoteChangesNow()
        startIdleTimerIfNeeded()
    }

    /// App resigned frontmost: stop polling. Foreground/launch fetches on the
    /// next activation pick the work back up; pushes (Layer B) would cover the
    /// background gap later.
    func handleWillResignActive() {
        idleFetchTask?.cancel()
        idleFetchTask = nil
    }

    private func fetchRemoteChangesNow() async {
        guard let library else { return }
        _ = await fetchLibrary(library)
    }

    /// Start the idle poll iff one isn't already running (prevents stacking on
    /// back-to-back activations / multiple WindowGroup `.task` calls). Each tick
    /// delegates to `runIdlePollTick`, which is also the deterministic test
    /// seam — no test asserts on `Task.sleep` elapsing.
    private func startIdleTimerIfNeeded() {
        guard idleFetchTask == nil else { return }
        idleTimerStartCountForTest += 1
        let generation = lifecycleGeneration
        let base = idleFetchInterval
        idleFetchTask = Task { [weak self] in
            var wait = base
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                guard let self else { return }
                switch await self.runIdlePollTick(generation: generation) {
                case .stopped:
                    return
                case .completed(let ok):
                    wait = Self.nextBackoff(current: wait, failed: !ok, base: base)
                }
            }
        }
    }

    /// Outcome of one idle-poll tick.
    enum IdlePollOutcome: Equatable {
        case stopped              // stale generation or torn down — exit the loop
        case completed(ok: Bool)  // fetched; `ok` drives backoff
    }

    /// One idle-poll tick: stop if this timer is from a prior lifecycle or sync
    /// was torn down (the generation gate that, with explicit cancellation in
    /// `performStopSync`, keeps a stale timer from writing after the flock is
    /// released); otherwise fetch. Extracted so tests drive ticks
    /// deterministically with no wall-clock sleeps.
    private func runIdlePollTick(generation: Int) async -> IdlePollOutcome {
        guard lifecycleGeneration == generation, let library else { return .stopped }
        let ok = await fetchLibrary(library)
        return .completed(ok: ok)
    }

    /// Test-only: run one idle-poll tick deterministically. Defaults to the
    /// current generation (an "active" tick); pass a captured prior generation
    /// to prove a stale tick is a no-op.
    func runIdlePollTickForTest(generation: Int? = nil) async -> IdlePollOutcome {
        await runIdlePollTick(generation: generation ?? lifecycleGeneration)
    }

    /// Test-only: current lifecycle generation, to capture a value a later stop
    /// will invalidate.
    var lifecycleGenerationForTest: Int { lifecycleGeneration }

    /// Subscribe to app activation notifications so foreground/background
    /// transitions drive `handleDidBecomeActive` / `handleWillResignActive`.
    /// Idempotent. (Wired into `performStartSync` in the next task.)
    private func subscribeActivationNotifications() {
        guard activationObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        activationObservers.append(
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.handleDidBecomeActive() }
            }
        )
        activationObservers.append(
            nc.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWillResignActive() }
            }
        )
    }

    private func unsubscribeActivationNotifications() {
        let nc = NotificationCenter.default
        activationObservers.forEach { nc.removeObserver($0) }
        activationObservers.removeAll()
    }
```

- [ ] **Step 7: Cancel the timer + observers in `performStopSync`**

In `performStopSync` (lines 305–318), after `pdfQueueKickCancellable = nil` (line 309), add:

```swift
        idleFetchTask?.cancel()
        idleFetchTask = nil
        unsubscribeActivationNotifications()
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter SyncCoordinatorTests`
Expected: PASS (all existing + the five new trigger tests + the three backoff tests).

- [ ] **Step 9: Commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "sync: coordinator foreground/idle-timer fetch triggers with generation-gated teardown

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Auto-wire launch fetch + activation subscription into `performStartSync`

**Files:**
- Modify: `Sources/Rubien/Sync/SyncCoordinator.swift` (`performStartSync` success tail ~294–303)
- Test: `Tests/RubienTests/SyncCoordinatorTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

Append inside the class in `Tests/RubienTests/SyncCoordinatorTests.swift`:

```swift
    func testLaunchWhileActiveFiresInitialFetch() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { true })
        await coordinator.performStartSyncForTest()       // launch fetch is awaited inside
        XCTAssertEqual(await spy.count, 1, "starting sync while frontmost fires exactly one launch fetch")
        XCTAssertEqual(coordinator.idleTimerStartCountForTest, 1, "launch while active starts one idle timer")
        await coordinator.performStopSyncForTest()
    }

    func testLaunchWhileInactiveDoesNotFetchOrPoll() async {
        let spy = FetchSpy()
        let coordinator = makeTriggerCoordinator(spy: spy, interval: 1, appActive: { false })
        await coordinator.performStartSyncForTest()
        XCTAssertEqual(await spy.count, 0, "no launch fetch when app isn't frontmost")
        XCTAssertEqual(coordinator.idleTimerStartCountForTest, 0, "no timer when inactive")
        await coordinator.performStopSyncForTest()
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncCoordinatorTests/testLaunchWhileActiveFiresInitialFetch`
Expected: FAIL — `spy.count` is 0 (launch fetch not wired yet).

- [ ] **Step 3: Wire the launch hook + subscription**

In `performStartSync`, the success tail currently reads (lines 294–303):

```swift
        library = newLibrary
        status = .idle
        startStatusConsumer(for: newLibrary)

        // Catch-up drain in case a kick fired between coordinator init
        // and the subscription assignment. `drainPDFUploadQueue` is
        // idempotent + re-entrant safe; offloaded to a Task so it doesn't
        // delay the `.idle` status surfacing to the UI.
        Task { [weak newLibrary] in await newLibrary?.drainPDFUploadQueue() }
```

Insert the activation subscription + launch fetch immediately after `startStatusConsumer(for: newLibrary)`:

```swift
        library = newLibrary
        status = .idle
        startStatusConsumer(for: newLibrary)

        // Layer A: subscribe to activation events and, if we're already
        // frontmost, fetch remote changes now + begin the idle poll. The
        // launch-time `didBecomeActive` fires before this subscription exists
        // (AppDelegate activates the app at finishLaunching), so the explicit
        // `isAppActive()` check covers that race.
        subscribeActivationNotifications()
        if isAppActive() {
            await handleDidBecomeActive()
        }

        // Catch-up drain in case a kick fired between coordinator init
        // and the subscription assignment. `drainPDFUploadQueue` is
        // idempotent + re-entrant safe; offloaded to a Task so it doesn't
        // delay the `.idle` status surfacing to the UI.
        Task { [weak newLibrary] in await newLibrary?.drainPDFUploadQueue() }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SyncCoordinatorTests`
Expected: PASS (all coordinator tests, including the two new launch tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinator.swift Tests/RubienTests/SyncCoordinatorTests.swift
git commit -m "sync: fetch remote changes on launch + subscribe to activation events

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Update the sync runbook

**Files:**
- Modify: `Docs/Sync-Runbook.md` (§4 "Second-Mac verification"; "Known follow-ups")

- [ ] **Step 1: Correct the live-sync expectation in §4**

In `Docs/Sync-Runbook.md`, replace step 5–7 of "### 4. Second-Mac verification" (the lines claiming ~10s propagation) with text that matches the actual trigger model. Replace:

```
5. Create a reference on Mac A; verify it appears on Mac B within ~10s
6. Edit the same reference on both within a few seconds; observe "server wins" behavior (whichever pushed first, other side overwrites — documented quirk of v1 merge policy)
7. Delete on Mac A; verify removal on Mac B within ~10s
```

with:

```
5. Create a reference on Mac A. Mac B pulls it on its **next fetch trigger**, not instantly: bring Mac B to the foreground (or wait up to one idle-poll interval, `SyncConstants.idleFetchInterval`, ~90s, while it's frontmost). Incremental remote changes are fetched on app launch, on app foreground, and on the idle timer — there is **no push-driven live fetch yet** (that's Layer B / the iCloud push entitlement, deferred to the iOS port).
6. Edit the same reference on both within a few seconds; on the next fetch each side observes "server wins" behavior (whichever pushed first, other side overwrites — documented quirk of v1 merge policy)
7. Delete on Mac A; bring Mac B to the foreground (or wait one idle-poll interval) and verify the removal
```

- [ ] **Step 2: Add the Layer B follow-up**

Under "## Known follow-ups", add a bullet:

```
- **Push-driven live fetch (Layer B).** Today incremental remote changes arrive only on launch / foreground / a ~90s idle poll (`SyncConstants.idleFetchInterval`). True push-driven sync needs the `aps-environment` entitlement (dev/release split like `icloud-container-environment`), Push enabled on the `com.rubien.app` App ID, and on-device verification that a Developer-ID DMG build actually receives CloudKit silent pushes. Planned with the iOS port. See `Docs/specs/2026-06-01-sync-incremental-fetch-design.md`.
```

- [ ] **Step 3: Commit**

```bash
git add Docs/Sync-Runbook.md
git commit -m "docs: runbook — correct cross-device propagation to fetch-on-activate model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full verification + review

**Files:** none (verification + review gate)

- [ ] **Step 1: Full build**

Run: `swift build`
Expected: builds clean, no warnings introduced by this work.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: all green. (Needs full Xcode toolchain — verify `xcode-select -p` points at `/Applications/Xcode.app/...`.)

- [ ] **Step 3: Independent review (per CLAUDE.md workflow)**

Ask `codex-rescue` to review the uncommitted/branch diff, then run a `/simplify` sweep (reuse, quality, efficiency). Triage findings; apply the ones that warrant a change; re-run `swift build && swift test`.

- [ ] **Step 4: Manual two-device verification (the engine path Task 2 couldn't unit-test)**

With sync enabled on two Macs on the same iCloud account + environment (see runbook §0 dev-vs-prod):
1. On Mac A, edit a reference's title. On Mac B (frontmost), confirm the edit appears within ~`idleFetchInterval`, and immediately on bringing B to the foreground.
2. On Mac A, delete a reference. Confirm B drops it on its next foreground/idle fetch.
3. Confirm the sync banner doesn't flicker to idle mid-send during an active push.
4. Toggle sync off on B; confirm Console shows no further fetch attempts (timer cancelled) and the writer lock is released (`rubien-cli sync status` → `appLockHeld: false`).

- [ ] **Step 5: Finalize**

If all green and review is addressed, the branch `feat/sync-incremental-fetch` is ready for the finishing-a-development-branch step (PR or merge). Do not merge without explicit user approval.

---

## Self-review notes

- **Spec coverage:** fetch primitive + guard (Task 2) ✓; reroute existing fetches (Task 2) ✓; launch trigger (Task 5) ✓; foreground trigger (Tasks 4–5) ✓; idle timer + tunable interval + backoff (Tasks 3–4) ✓; idempotent timer / no double-start (Task 4) ✓; generation-gated teardown (Task 4) ✓; status-flicker fix (Task 1) ✓; constants (Task 3) ✓; runbook (Task 6) ✓; Layer B out of scope ✓.
- **Type consistency:** `fetchRemoteChanges() -> Bool` (Task 2) matches the `fetchLibrary` seam default (Task 4) and the spy's `-> Bool` (Task 4). `noteFetch`/`noteSend(inFlight:)` consistent between Task 1 implementation and test. `nextBackoff(current:failed:base:)` consistent (Tasks 3–4). `idleTimerStartCountForTest` consistent (Task 4–5).
- **Non-unit-tested by design:** the live `engine.fetchChanges()` (Task 2) and `NSApplication` notification delivery (Task 5 production path) — both unentitled-XCTest-hostile / AppKit-runtime-bound; covered by the injected seam tests + Task 7 manual verification, consistent with the codebase's existing sync test boundary.
- **Determinism (addresses Codex's timing-flake concern):** no test asserts on `Task.sleep` elapsing. Per-tick behaviour goes through the `runIdlePollTick` seam (`runIdlePollTickForTest`); start/stop/idempotency via `idleTimerStartCountForTest` + `lifecycleGenerationForTest`; backoff via the pure `nextBackoff`; launch/foreground fetches are awaited so counts are exact. Task 4 handler tests use `appActive: { false }` so they stay independent of Task 5's launch wiring.
