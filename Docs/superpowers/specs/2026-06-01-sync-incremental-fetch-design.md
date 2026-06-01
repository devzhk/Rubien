# Design: incremental remote-change fetch (Sync "Layer A")

- **Date:** 2026-06-01
- **Status:** Approved (pending implementation plan)
- **Scope:** `RubienSync` + `Rubien` app coordinator. Mac-only today; the portable core is reused by the future iOS port.
- **Related memory:** `sync-no-incremental-fetch`, `sync-tombstone-entityid-keying-bug`

## 1. Problem

Rubien syncs through `CKSyncEngine` (private DB) with `automaticallySync = true`. Verified root cause of a real bug: **a device never receives incremental remote changes** (edits/deletes made on another device) while running — only a full re-pull (wiping `sync-engine-state.bin` to force a fresh token) pulls them.

`CKSyncEngine` is event-driven. It **sends** local changes on its own, but it only **fetches** remote changes when woken by a CloudKit silent **push notification**. Rubien cannot receive those pushes and has no fallback:

1. **No push entitlement.** `Sources/Rubien/Rubien.entitlements` declares CloudKit but **no `aps-environment`**. `scripts/build-app.sh` injects only `com.apple.developer.icloud-container-environment=Production` at sign time (~lines 300–305), never `aps-environment`. Neither dev nor release builds can receive APNs.
2. **No registration / no subscription.** No `registerForRemoteNotifications` / `didReceiveRemoteNotification` / `CKDatabaseSubscription` anywhere in `Sources/`.
3. **No manual fetch fallback.** `SyncedLibrary.start()` (`SyncedLibrary.swift:110–134`) pushes/ingests but never calls `engine.fetchChanges()`. The only two `fetchChanges()` calls are reactive error paths (`:1026` `.unknownItem`, `:1080` `.serverRecordChanged` without a serverRecord).

The canonical Apple `sample-cloudkit-sync-engine` confirms push is the trigger and the entitlement is the only missing prerequisite for it (the sample creates no subscription, registers for nothing, and calls no manual fetch — but its entitlements **do** include `aps-environment`).

## 2. Goal & non-goals

**Goal:** remote edits/deletes reach a running device without a token-wipe re-pull, by explicitly driving `CKSyncEngine.fetchChanges()` on three triggers — **app launch, app foreground, and a periodic idle timer while frontmost** — with no entitlement or provisioning changes.

**Non-goals (deferred):**
- **Layer B — push notifications.** Adding `aps-environment` (dev/release split mirroring `icloud-container-environment`), enabling Push on the `com.rubien.app` App ID, embedding a provisioning profile, and on-device verification that a Developer-ID DMG build actually receives CloudKit silent pushes. Pursued with the iOS port, when push provisioning is being done anyway.
- Merge-policy changes, tombstone (entityType,entityId) keying, and other open sync items.

**Why Layer A first:** it is fully within our control (pure Swift), unblocks real two-Mac use now, and works regardless of whether pushes ever reach the Developer-ID build. Push later only *lowers latency* on top of this; it never replaces fetch-on-activate (a quit/asleep Mac receives no push; APNs silent pushes are best-effort).

## 3. Architecture

```
RubienApp (SwiftUI @main, unchanged)
        │  .task { coordinator.startIfEnabled() }     ← existing
        ▼
SyncCoordinator (@MainActor, #if os(macOS))           ← owns triggers + idle timer
        │  launch / NSApplication.didBecomeActive / willResignActive / ~90s timer
        ▼
SyncedLibrary.fetchRemoteChanges()  (actor, RubienSync)   ← portable core (iOS reuses)
        ▼
CKSyncEngine.fetchChanges()
```

The only platform-specific piece is the trigger wiring in the (already Mac-gated) coordinator. The fetch primitive lives in the shared `RubienSync` core.

## 4. Component design

### 4.1 `SyncedLibrary.fetchRemoteChanges()` (RubienSync)

A single entry point for every fetch, with an actor-isolated overlap guard. Returns success so the caller (the idle timer) can drive backoff.

```swift
private var isFetching = false   // actor-isolated; no suspension between read and set → race-free

/// Drive an explicit incremental fetch. Returns true on success (or a
/// no-op skip because a fetch is already running), false on error.
@discardableResult
func fetchRemoteChanges() async -> Bool {
    guard !isFetching else { return true }   // another fetch is in flight; treat as success
    isFetching = true
    defer { isFetching = false }
    do { try await engine.fetchChanges(); return true }
    catch {
        log.error("fetchRemoteChanges failed: \(error.localizedDescription, privacy: .public)")
        return false
    }
}
```

Notes:
- `SyncedLibrary` is an `actor`, so the `guard`→`isFetching = true` sequence has no suspension point and is race-free for concurrent callers.
- Only called once the library is live (engine already constructed), so it never forces engine construction in a test process.

**Reroute existing calls (Codex IMPORTANT #1):** the two reactive error-path fetches at `SyncedLibrary.swift:1026` and `:1080` change from `Task { _ = try? await engine.fetchChanges() }` to `Task { await self.fetchRemoteChanges() }`, so the overlap guard is the single concurrency policy for all fetches. (They remain dispatched off the delegate callback per Apple's guidance.)

### 4.2 Status-flicker fix (Codex IMPORTANT #4)

`handleEvent` currently maps both `willFetchChanges`/`willSendChanges` → `.syncing` and both `didFetchChanges`/`didSendChanges` → `.idle`. With Layer A polling, a manual fetch finishing mid-send would publish `.idle` while an automatic send is still in flight (banner flicker). Track the two independently:

```swift
private var isFetchInFlight = false
private var isSendInFlight  = false

case .willFetchChanges: isFetchInFlight = true; publishStatus(.syncing)
case .willSendChanges:  isSendInFlight  = true; publishStatus(.syncing)
case .didFetchChanges:  isFetchInFlight = false; publishIdleIfQuiescent()
case .didSendChanges:   isSendInFlight  = false; publishIdleIfQuiescent()

private func publishIdleIfQuiescent() {
    guard !isFetchInFlight, !isSendInFlight else { return }
    publishStatus(.idle)
}
```

`.idle` is published only when both fetch and send are done. No other status plumbing changes: the existing `statusStream` → coordinator → banner path is reused.

### 4.3 `SyncCoordinator` triggers (Mac app)

New injected seams (mirroring existing `makeLibrary` / `startLibrary`):

| Seam | Default | Purpose |
|------|---------|---------|
| `fetchLibrary: @Sendable (SyncedLibrary) async -> Bool` | `{ await $0.fetchRemoteChanges() }` | Counting spy in tests; never touches the real engine. |
| `idleFetchInterval: TimeInterval` | `SyncConstants.idleFetchInterval` (90s) | Tiny value in timer tests. |
| `isAppActive: () -> Bool` (MainActor) | `{ NSApp.isActive }` | Deterministic in tests. |

New state:
```swift
private var idleFetchTask: Task<Void, Never>?
private var activationObservers: [NSObjectProtocol] = []
```

**Launch trigger** — at the end of a successful `performStartSync` (after `library` is set, `status = .idle`, and `startStatusConsumer` runs — the ordering Codex IMPORTANT #2 confirms is required so fetch events aren't emitted before the status consumer exists), subscribe to activation notifications and, iff `isAppActive()`, run `handleDidBecomeActive()`. This covers the launch-time activation that fires *before* the coordinator subscribes (Codex NIT #1).

**Foreground trigger** — subscribe (in production) to:
- `NSApplication.didBecomeActiveNotification` → `Task { @MainActor in await self.handleDidBecomeActive() }`
- `NSApplication.willResignActiveNotification` → `Task { @MainActor in self.handleWillResignActive() }`

Tokens stored in `activationObservers`; removed in `performStopSync`. (The existing `AppDelegate` observer for `didBecomeActiveNotification` that refreshes `LibraryChangeBroadcaster` is unrelated and stays; both firing is harmless given the guards.)

```swift
func handleDidBecomeActive() async {
    guard library != nil else { return }
    await fetchRemoteChangesNow()      // immediate fetch on activate
    startIdleTimerIfNeeded()           // idempotent
}

func handleWillResignActive() {
    idleFetchTask?.cancel()            // don't poll while not frontmost
    idleFetchTask = nil
}

private func fetchRemoteChangesNow() async {
    guard let library else { return }
    _ = await fetchLibrary(library)
}
```

**Idle timer** — idempotent start; runs only while frontmost + sync active; cancels cleanly; re-checks the lifecycle generation each iteration (Codex BLOCKING):

```swift
private func startIdleTimerIfNeeded() {
    guard idleFetchTask == nil else { return }      // never stack two timers (Codex #5)
    let generation = lifecycleGeneration
    let base = idleFetchInterval
    idleFetchTask = Task { [weak self] in
        var wait = base
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(wait))
            guard let self,
                  !Task.isCancelled,
                  await self.lifecycleGeneration == generation,   // stale-timer gate
                  let library = await self.library
            else { return }
            let ok = await self.fetchLibrary(library)
            wait = Self.nextBackoff(current: wait, failed: !ok, base: base)
        }
    }
}

/// Pure, unit-tested. Reset to base on success; double toward cap on failure.
static func nextBackoff(current: TimeInterval, failed: Bool, base: TimeInterval) -> TimeInterval {
    failed ? min(current * 2, SyncConstants.maxIdleFetchInterval) : base
}
```

(Exact `await self.…` access shapes are an implementation detail for the plan — the contract is: cancel on stop, gate on generation, idempotent start, pure backoff.)

**Teardown** — `performStopSync` additionally:
```swift
idleFetchTask?.cancel(); idleFetchTask = nil
activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
activationObservers.removeAll()
```
`lifecycleGeneration += 1` (already there) plus the explicit cancel gives belt-and-suspenders against an orphaned timer writing to the DB after the single-writer flock lock is released.

### 4.4 `RubienApp.swift`

Unchanged — the foreground signal comes from the coordinator's own `NSApplication` subscription, not from the SwiftUI scene.

## 5. Constants

Added to `SyncConstants` (or the coordinator):
- `idleFetchInterval: TimeInterval = 90`   — steady-state idle poll while frontmost. **Tunable.** A comment documents the trade-off: max idle-window staleness ≈ this interval; lower = snappier but more no-op round-trips; mostly moot once Layer B push lands.
- `maxIdleFetchInterval: TimeInterval = 900` — backoff cap (15 min) on repeated failure.

## 6. Error handling & status

- Fetch failures are logged and swallowed (a failed background poll must not flip the banner to a hard `.error`; the engine's own retry covers transient failures). The idle timer reacts to failure only by backing off.
- Status is surfaced entirely through the engine's existing `will*/did*` events (§4.2), now flicker-free.

## 7. Testing strategy

Follows the codebase rule: test the wiring/DB side, skip the live `CKSyncEngine` call (an unentitled XCTest raises `CKException`).

**`SyncCoordinator` tests** (via injected seams; `makeLibrary`/`startLibrary` already no-op the engine):
- Launch with `isAppActive = { true }` → at least one fetch fired and the idle timer polls (spy count grows over a few tiny intervals).
- `handleWillResignActive()` → timer cancelled (count stops growing).
- `handleDidBecomeActive()` after resign → fetch fired + timer restarted.
- `performStopSyncForTest()` → timer cancelled, no further fetches, observers removed.
- Double `handleDidBecomeActive()` → only one timer (rate stays ~1×, not 2×).

**Pure backoff** — `nextBackoff` truth table (success resets to base; failures double; capped at `maxIdleFetchInterval`). No timing flakiness.

**Status-flicker** (`RubienSyncTests`, pure/in-memory) — drive the will/did fetch+send flag transitions through a test hook and assert `statusStream` only emits `.idle` when both are quiescent.

## 8. Files touched

- `Sources/RubienSync/SyncedLibrary.swift` — `fetchRemoteChanges()` + guard; reroute the two error-path fetches; fetch/send in-flight flags + `publishIdleIfQuiescent`.
- `Sources/Rubien/Sync/SyncCoordinator.swift` — seams, activation subscription, idle timer, launch fetch, teardown.
- `Sources/RubienSync/SyncConstants.swift` — `idleFetchInterval`, `maxIdleFetchInterval`.
- `Tests/RubienTests/…` (coordinator) + `Tests/RubienSyncTests/…` (status flicker) — new coverage.
- `Docs/Sync-Runbook.md` §4 — correct the "~10s push-driven" claim to the actual launch/foreground/~90s behavior; list Layer B (push) as the known follow-up for lower latency.

## 9. Risks / open items

- **Latency, not live sync.** Max staleness while frontmost ≈ `idleFetchInterval`; while backgrounded, until next foreground/launch. Acceptable for the stated goal; Layer B closes the gap later. (Codex NIT #3.)
- **Cosmetic only:** none outstanding after §4.2.
- **Determinism:** all timer logic is exercised through injected interval + spy + the pure backoff function — no wall-clock dependence in tests.
