# Make CloudKit sync runnable on macOS — design

**Status:** approved by user 2026-04-22; codex-reviewed 2026-04-22; ready for implementation plan
**Scope:** wiring commits that make the already-landed `RubienSync` target functional in the shipping app. Split into four sub-commits (see "Commit decomposition"). Scalars-first, PDFs in a follow-up commit stream. Minimal CLI (`sync status` only). Full UI (toolbar icon + banners). Opt-in preference, default off.

## Context

`RubienSync` (11 commits on `main` as of 2026-04-22) ships a complete `CKSyncEngine`-based sync stack: per-entity `CKRecord` mappings, dirty-tracking triggers, a `SyncedLibrary` actor, tombstone lifecycle, file-lock mutex, etc. Everything compiles and has 90 passing tests, but **nothing in the shipping app ever instantiates the actor**. This spec is the design for connecting the engine to the app.

**Preliminary fix already landed (commit `3fe98ae`):** the codex review of this spec surfaced that `SyncTransactionObserver` wasn't actually observing anything — GRDB's `.observerLifetime` registration uses a weak reference, and our install method allocated the observer in a local var that deallocated immediately. Without the retention fix, post-startup edits never reached the engine; sync only worked during `start()`'s one-shot reconciliation pass. Retention tests added as regression guards.

Concurrently: the user has just enrolled in the Apple Developer Program but the membership is not yet active. Enrollment typically clears in 24–48h. Container creation in the CloudKit Dashboard is a separate step the user performs after that. The design therefore builds the wiring in a way that **compiles and runs today** with sync in an `.unavailable` state, and flips to functional automatically once the entitlement is present.

## Scope

**In scope:**

- `SyncCoordinator` — `@MainActor` `ObservableObject` bridging the actor to SwiftUI
- Opt-in preference with first-run confirm dialog
- Full UI error surface: toolbar cloud-state icon + banners for quota / account / errors
- App entrypoint wiring in `RubienApp.swift`
- Settings section with sync toggle
- Entitlements file additions (dormant until enrollment clears)
- Container ID made overridable via `RUBIEN_CLOUDKIT_CONTAINER` env var
- `rubien-cli sync status` subcommand (JSON)
- Unit tests for all Swift additions; CLI tests for the JSON shape
- Manual smoke-test plan for post-enrollment two-Mac verification

**Out of scope (deferred to follow-up commits):**

- CKAsset / PDF file sync — separate commit in this work stream
- `rubien-cli sync push/pull/reset` — noted; minimal `status` only for now
- `dateModified`-based field-level LWW merge — plan's v2 refinement; current policy is server-wins
- A-pks UUID migration — separate future commit, addresses rowID collision risk
- iPad port (Phase C)
- Wipe-iCloud-library action

## Design choices

### Sync-enable model: opt-in, default off

User explicitly toggles sync via Settings. Default off means a privacy-conscious user who has iCloud signed in for other purposes (Photos, iMessage) doesn't silently sync their library. First-time toggle shows a confirm sheet explaining what will happen; once dismissed, the `didConfirmFirstRun` flag persists forever so subsequent toggles don't re-prompt.

### Bridge pattern: `SyncCoordinator` singleton

An `@MainActor final class SyncCoordinator: ObservableObject` that owns an optional `SyncedLibrary` actor. SwiftUI views consume it as `@EnvironmentObject`. This keeps the actor pure (no `@Observable` / actor-hopping awkwardness) and matches the existing house style.

### Actor → coordinator communication: `AsyncStream<SyncStatus>`

The actor exposes `statusStream: AsyncStream<SyncStatus>` populated from inside delegate methods. The coordinator consumes it in a `Task { for await status in stream { self.status = status } }` and republishes via `@Published`. One stream per actor lifetime.

**Task ownership and lifecycle:** the coordinator stores the consumer as `private var statusTask: Task<Void, Never>?`. Started in `startSync()` after the actor is up; cancelled in `stopSync()` before the actor is released; replaced (cancel-and-restart) if the actor ever needs to be re-created mid-session (e.g. after an `.accountChange` that triggers a full engine reset). The stream's termination (when the actor deallocates) naturally ends the for-loop; cancellation is belt-and-suspenders. If the task dies for any unexpected reason, status updates silently freeze — so the restart-on-actor-restart rule above matters.

### Conflict resolution

Current v1 policy: server-wins on `.serverRecordChanged`. True LWW by `dateModified` is a later refinement. Single-user testing between Mac mini and MacBook is unlikely to hit this unless the user deliberately edits the same reference on both devices simultaneously.

### Container ID configuration

`SyncConstants.containerIdentifier` changes from a hardcoded `let` to a computed property that reads the `RUBIEN_CLOUDKIT_CONTAINER` env var first and falls back to `"iCloud.com.rubien.app"`. This lets you override per-launch during dev without a rebuild.

### Enrollment-gap behavior

CloudKit raises `CKException` (an Objective-C `NSException`) when `CKContainer(identifier:)` or `privateCloudDatabase` is accessed in a process without the container entitlement. **Swift's `do/catch` does not catch `NSException`** — only Swift errors that conform to `Error`. This rules out a plain Swift `try/catch` approach.

Pre-flight probe strategy (ordered): the coordinator checks the following before ever touching `CKContainer`:

1. `Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.icloud-container-identifiers")` — returns nil in unentitled builds; immediate `.unavailable("No CloudKit entitlement in app bundle")`.
2. `FileManager.default.ubiquityIdentityToken` — non-nil when the user is signed into an iCloud account; nil triggers `.signedOut` without touching CKContainer at all.
3. Only after both probes pass do we construct `CKContainer` via the lazy `containerProvider` and instantiate `SyncedLibrary`.

For the residual "probe said OK but CloudKit still raises" case (e.g., entitlement present in bundle but container not registered in the Dashboard — which Apple reports as an *async* `CKError.missingEntitlement` on first API call, not an NSException), the actor's `statusStream` carries the error out and the coordinator sets `.unavailable("Container not found: \(id)")`. That error path is a normal Swift error through CKSyncEngine's delegate — catchable.

UI: toolbar warning icon + Settings caption explaining the state. Manual "Try again" button in Settings that re-runs the probe + `startSync()` flow — useful for flipping the switch the moment entitlement arrives without re-toggling the preference.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     RubienApp (@main)                       │
│   creates SyncCoordinator at startup, injects to environment│
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  SyncCoordinator  (@MainActor final class, ObservableObject)│
│  ─ @Published userEnabled: Bool   (UserDefaults-backed)     │
│  ─ @Published status: SyncStatus  (republished from actor)  │
│  ─ library: SyncedLibrary?        (nil when off)            │
│                                                             │
│  • on userEnabled=true → instantiate library, start(),      │
│    install tx observer, subscribe to status AsyncStream     │
│  • on userEnabled=false → stop, tear down library, post     │
│    status=.disabled                                         │
└─────────────────────────────────────────────────────────────┘
                │                                 │
                ▼                                 ▼
  ┌──────────────────────────┐     ┌──────────────────────────┐
  │  SyncedLibrary (actor)   │     │  SwiftUI views           │
  │  ─ CKSyncEngine          │     │  ─ toolbar cloud icon    │
  │  ─ emits SyncStatus via  │     │  ─ Settings toggle       │
  │    AsyncStream           │     │  ─ banners on .alert     │
  └──────────────────────────┘     └──────────────────────────┘

  RubienCLI:  sync status reads SyncStateStore + sync-engine-state.bin
              directly. Never instantiates SyncedLibrary
              (honors the single-writer invariant via SyncFileLock
              tryLockExclusive; reports "app is syncing" if held).
```

## Components

### New types in `Sources/RubienSync/`

**`SyncStatus`** (enum, `Equatable, Sendable`):
- `.disabled` — sync toggle off
- `.unavailable(reason: String)` — entitlement missing, container unreachable
- `.signedOut` — iCloud account not signed in
- `.idle` — engine running, nothing pending
- `.syncing` — engine mid-fetch-or-send
- `.error(CKError)` — sticky failure state

**`SyncedLibrary.statusStream: AsyncStream<SyncStatus>`** — new property on the actor, consumed once by the coordinator. Populated from `handleEvent`'s `.willFetchChanges` / `.didFetchChanges` / `.willSendChanges` / `.didSendChanges` / `.accountChange` branches and from the `.serverRecordChanged` merge path.

### New types in `Sources/Rubien/`

- `SyncCoordinator` — `@MainActor final class ... ObservableObject`. UserDefaults keys `"rubien.sync.enabled"` (toggle) and `"rubien.sync.didConfirmFirstRun"` (gate).
- `SyncStatusIcon.swift` (`View`) — 16pt cloud SF Symbol that switches on `coordinator.status` for glyph + color + accessibility label.
- `SyncStatusBanner.swift` (`ViewModifier`) — `.alert`-based modal for `.error(.quotaExceeded)`; non-blocking `overlay(alignment: .top)` banner for `.signedOut` / `.unavailable`.

### Modifications

- `Sources/Rubien/RubienApp.swift` — instantiate `SyncCoordinator` as `@StateObject`, inject via `.environmentObject`, add `SyncStatusIcon` to the toolbar, apply banner view modifier at the scene root.
- `Sources/Rubien/Views/PreferencesView.swift` — new "iCloud Sync" section: toggle + caption that varies with `status` + "Try again" button shown only in `.unavailable`.
- `Sources/Rubien/Rubien.entitlements` — add `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.icloud-services`.
- `Sources/RubienSync/SyncConstants.swift` — `containerIdentifier` becomes a computed `var` reading the env var with fallback.
- `Package.swift` — the `RubienCLI` target gains a `RubienSync` dependency. CLI previously linked only `RubienCore`; the `sync status` subcommand needs `SyncStateStore`, `SyncEntityType`, and `SyncFileLock`. On macOS this adds only the system `CloudKit` framework (always present on the min target) — negligible binary-size cost. `CLAUDE.md`'s description of the CLI should be updated alongside.

### New CLI

- `Sources/RubienCLI/SyncCommands.swift` — `sync status` subcommand. JSON output shape (expanded from codex-review feedback — thin JSON is useless for "my sync is wedged" diagnosis):

```json
{
  "enabled": true,
  "containerIdentifier": "iCloud.com.rubien.app",
  "entitlementPresent": true,
  "iCloudAccountAvailable": true,
  "appLockHeld": false,
  "baselineState": "complete",
  "dirtyByEntityType": { "reference": 3, "tag": 0, "pdfAnnotation": 1 },
  "tombstoneCount": { "confirmed": 12, "unconfirmed": 0 },
  "syncEngineState": {
    "sidecarPath": "/Users/.../Rubien/sync-engine-state.bin",
    "sidecarExists": true,
    "sidecarLastModified": "2026-04-22T14:32:11Z"
  },
  "lastObservedError": {
    "code": "quotaExceeded",
    "localizedDescription": "iCloud storage is full.",
    "retryAfter": null,
    "observedAt": "2026-04-22T14:30:00Z"
  },
  "schemaVersion": "v1"
}
```

Field sources:
- `enabled` — `UserDefaults["rubien.sync.enabled"]`
- `containerIdentifier` — resolved value of `SyncConstants.containerIdentifier` (env-var override applied)
- `entitlementPresent` — probe of `Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.icloud-container-identifiers")`
- `iCloudAccountAvailable` — `FileManager.default.ubiquityIdentityToken != nil`
- `appLockHeld` — `SyncFileLock.tryLockExclusive()` probe (immediately released)
- `baselineState` — `syncSession` table query
- `dirtyByEntityType` — `syncState` aggregate by entityType
- `tombstoneCount` — `tombstone` aggregate split by `confirmedByServer`
- `lastObservedError` — read from a new `syncState`-level row we'll write at each error handler in the actor; `null` if never observed

Reads all of these **without instantiating `SyncedLibrary`** (and without constructing `CKContainer`, so CLI works in unentitled dev builds).

## Data flow

### Flow A — app launch, sync off

1. `RubienApp.init` → `SyncCoordinator()` → UserDefaults read → `userEnabled = false`
2. `coordinator.status = .disabled`
3. No actor constructed. No CloudKit calls, no entitlement check, no network
4. Toolbar icon: outline cloud, muted

### Flow B — user toggles sync ON first time

Uses a transient `pendingConfirm` state (in-memory only, not persisted) so relaunches never land in "toggle says on but user never agreed":

1. SwiftUI binds toggle to `coordinator.userEnabled`. Flip to `true` does **not** immediately persist — instead it sets `coordinator.pendingConfirm = true` and shows the confirm sheet. UserDefaults is not updated yet.
2. **"Enable Sync"** → persist `UserDefaults["rubien.sync.enabled"] = true` + `"rubien.sync.didConfirmFirstRun"] = true`, clear `pendingConfirm`, run `startSync()`.
3. **"Not Now"** → snap the toggle's visual state back to `false` (SwiftUI binding update), clear `pendingConfirm`, do nothing else.
4. **App quit while sheet is open** → no UserDefaults change happened at step 1, so on relaunch the toggle reads `false` and the world is consistent.
5. `startSync()` path: runs the entitlement + account pre-flight probes described in "Enrollment-gap behavior". If any probe fails, sets `status = .unavailable(reason)` or `.signedOut` and returns without instantiating `SyncedLibrary`. If probes pass, instantiates `SyncedLibrary`, awaits `start()`, awaits `installTransactionObserver()`, launches the consumer Task for `statusStream`.
6. `start()` runs baseline (first time only), tombstone compaction, `ingestPendingChanges`.
7. Actor's first engine-driven event emits `.idle` or `.syncing`; coordinator republishes. If CloudKit delivers an async error later (e.g. `.missingEntitlement` because the container wasn't registered in the Dashboard even though the bundle had the entitlement), actor emits `.error(...)` → coordinator sets `.unavailable`.

Subsequent toggles (ON after a previous OFF): `didConfirmFirstRun` is already true, so step 1 skips the sheet and persists the toggle immediately.

### Flow C — ongoing sync during normal use

1. User edits a reference → GRDB write → per-table trigger sets `syncState.isDirty = 1`
2. `SyncTransactionObserver.databaseDidCommit` fires on the DB's serial write queue
3. Detached `Task` calls `library.ingestPendingChanges()`
4. `ingestPendingChanges` reads dirty list, calls `engine.state.add(pendingRecordZoneChanges:)`
5. Engine's scheduler (with `automaticallySync = true`) picks up the change
6. Actor emits `.syncing` at `.willSendChanges`, `.idle` at `.didSendChanges`
7. Icon animates accordingly

### Flow D — error: iCloud quota exceeded mid-sync

1. `.sentRecordZoneChanges` delivers failure with `CKError.quotaExceeded`
2. Actor's `handleSentZoneChanges` matches the error, emits `.error(.quotaExceeded)` on the stream
3. Coordinator's consumer Task receives it, updates `@Published status`
4. Banner view modifier shows modal alert with "Open iCloud Settings" button
5. User frees space; next app foreground → coordinator calls `library.engine.sendChanges()` (scheduled via Task); success returns status to `.idle`; banner dismisses

### Flow E — toggle OFF → ON cycle

OFF:
1. `coordinator.userEnabled = false`
2. Coordinator cancels `statusTask`
3. Awaits `library.removeTransactionObserver()` — calls GRDB's explicit `remove(transactionObserver:)` and drops the actor's retention so the observer can deallocate
4. Releases `SyncedLibrary` reference (actor deallocates)
5. Local library and sync bookkeeping (syncState, tombstones, sidecar file) **are preserved**
6. Per-table triggers keep firing silently while sync is off; dirty flags and tombstones accumulate

ON again:
1. New `SyncedLibrary` constructed; engine reads sidecar state file → resumes with last server change token
2. Baseline one-shot is gated on `syncSession.baselineState = 'complete'` — skips
3. `ingestPendingChanges` picks up everything accumulated during the off period

**Long-off backlog consideration:** a user who had sync on, then off for months, then on again, accumulates N dirty rows per entity they touched. `ingestPendingChanges` calls `engine.state.add(pendingRecordZoneChanges: [N items])`. CKSyncEngine internally paginates the resulting push into CloudKit-safe batches (CKOperation limit ≈ 400 records / 2 MB), so the app doesn't hit `.limitExceeded` from this path. However, the first push cycle after a long gap can take minutes of wall-clock for a library with thousands of changes — worth surfacing in the UI via `.syncing` status instead of presenting as hung.

4. Normal push/pull resumes once the backlog drains.

## Error handling

| Status | Trigger | UI | Recovery |
|---|---|---|---|
| `.disabled` | Toggle off | Muted outline cloud; Settings caption "Off — local library only" | User flips toggle |
| `.unavailable(reason)` | Entitlement absent from bundle OR container not registered (async `.missingEntitlement`) | Outline cloud with ⚠; no banner | Manual "Try again" in Settings or automatic on app foreground |
| `.signedOut` | `handleAccountChange(.signOut)` / `.switchAccounts` / `ubiquityIdentityToken == nil` | Cloud-with-slash icon; banner "Signed out of iCloud — sync paused. Your library is safe locally." | Automatic on re-sign-in |
| `.idle` | `.didFetchChanges` / `.didSendChanges` / end of start | Solid cloud, accent color | n/a |
| `.syncing` | `.willFetchChanges` / `.willSendChanges` | Animated solid cloud | n/a |
| `.error(.quotaExceeded)` | `.sentRecordZoneChanges` delivers this code | Red warning cloud; modal alert "iCloud storage full." + "Open iCloud Settings" button | User frees space; retry on foreground |
| `.error(.networkUnavailable \| .networkFailure)` | Transient network | Warning cloud; no banner (transient) | CKSyncEngine auto-retries with backoff |
| `.error(.zoneBusy \| .requestRateLimited)` | Server backpressure; carries `retryAfter` | Warning cloud; no banner (transient) | Engine respects `retryAfter` automatically |
| `.error(.limitExceeded)` | Batch exceeded 400 records / 2 MB | Warning cloud; no banner | Engine auto-paginates and retries — if recurring, log for investigation |
| `.error(.batchRequestFailed)` | One record in the batch failed; others may have succeeded | Warning cloud; no banner | Engine splits the batch and retries individual records |
| `.error(.serverRejectedRequest)` | Server rejected the operation outright (rare; schema / auth issue) | Red warning; non-modal banner "Sync paused — server rejected request. See Console for details." | Manual investigation required; engine keeps trying but likely needs intervention |
| `.error(.changeTokenExpired)` | Server's change token has aged out | None (handled internally — engine re-fetches with no token) | No user-visible recovery needed |
| `.error(other)` | Any other unhandled `CKError` | Warning cloud; non-modal banner "Sync error: \(localized). Will retry." | Engine retries; banner auto-dismisses on `.idle` |

**First-run confirm dialog** — only modal we show for sync, gated once per user via `UserDefaults["rubien.sync.didConfirmFirstRun"]`.

**Verified engine behaviors** (Apple doc refs tracked in an implementation note):
- `.limitExceeded` / `.batchRequestFailed` / `.zoneBusy` / `.requestRateLimited`: CKSyncEngine's default retry policy handles these per Apple's `CKSyncEngine.Configuration` docs; our handler just logs + records in `lastObservedError` for the CLI status output.
- `.changeTokenExpired`: CKSyncEngine auto-recovers by re-fetching from scratch. No delegate code needed.

**Not handled** — partial-batch per-record errors surfaced via `.sentRecordZoneChanges.failedRecordSaves` are already handled in the existing actor code (server-record-changed merge, unknown-item retry, zone-not-found re-create). Zone deletion by user from iCloud Settings: wipe-and-re-upload is silent.

## Testing

### Unit tests (no CloudKit, no entitlement)

`Tests/RubienTests/SyncCoordinatorTests.swift`:

- `testInitialStateRespectsUserDefaults` — coordinator reads toggle at init; `.disabled` when absent
- `testTogglingOnShowsPendingConfirmNotPersisted` — toggle flip sets `pendingConfirm = true` without writing UserDefaults; a subsequent coordinator re-init reads `enabled = false` (confirms the persist-after-confirm rule from Flow B)
- `testConfirmCancelSnapsToggleBack` — with `pendingConfirm = true`, simulating "Not Now" clears `pendingConfirm` and resets toggle to false; `SyncedLibrary` is never instantiated
- `testConfirmEnablePersistsAndStarts` — "Enable Sync" writes both UserDefaults keys and calls `startSync()`
- `testRelaunchWithEnabledButNoConfirmIsImpossibleByDesign` — seed `UserDefaults["rubien.sync.enabled"] = true, didConfirmFirstRun = false` (a state the UI shouldn't produce but defensive code should tolerate), init coordinator, verify it treats the inconsistency as disabled and clears `enabled` on next launch
- `testTogglingOffTearsDownLibrary` — toggle `false` calls `removeTransactionObserver`, cancels `statusTask`, releases `library`, emits `.disabled`
- `testMissingEntitlementProbeTransitionsToUnavailable` — mock `Bundle.main.infoDictionary` lookup to return nil; `startSync()` sets `.unavailable` without constructing `SyncedLibrary`
- `testSignedOutProbeTransitionsToSignedOut` — mock `FileManager.default.ubiquityIdentityToken` to return nil; `startSync()` sets `.signedOut`
- `testAsyncMissingEntitlementFromActorTransitionsToUnavailable` — pass a fake actor that emits `.error(CKError(.missingEntitlement))` on its status stream; coordinator maps to `.unavailable` (covers the "entitlement in bundle but container not registered" case)
- `testRepublishesStatusFromActorStream` — fake stream emits `.syncing` → `.idle` → `.error(.quotaExceeded)`; `@Published status` reflects each in order, and tearing down mid-stream cancels `statusTask` cleanly

`Tests/RubienSyncTests/SyncedLibraryObserverIntegrationTests.swift` — covers Flow C (commit → observer → ingestPendingChanges):

- `testCommitFiresObserverAndEnqueuesDirtyRow` — install observer, insert a row via GRDB, await a small delay; verify that a subsequent `engine.state.pendingRecordZoneChanges` scan would include the new ID. Uses a fake engine / test double to observe without CloudKit. This is the test that would have caught the retention bug earlier — keep it as a regression guard.
- `testCommitAfterRemoveTransactionObserverDoesNotEnqueue` — covers Flow E off leg: after removal, inserts don't reach the engine.

### CLI tests

`Tests/RubienCLITests/SyncCommandsTests.swift`:

- `testSyncStatusJSONShape` — seed syncState + tombstones, run CLI, verify JSON fields + counts
- `testSyncStatusReportsLockHeld` — acquire `SyncFileLock` in harness, run CLI, verify `"appLockHeld": true`

### Existing tests

All 398 current tests must still pass. Add one assertion to `SyncedLibraryStartupTests`: `testStatusStreamEmitsIdleAfterStart` — consume stream for 500ms, assert `.idle` emitted.

### What we can't test automatically

- Real CloudKit round-trips (need container + iCloud account)
- Multi-device convergence (need two Macs)
- `CKError.quotaExceeded` recovery (need to actually fill iCloud)

### Manual smoke test (after enrollment clears)

On Mac mini + MacBook, both signed into same iCloud account:

1. Build + launch on Mac mini; toggle sync on; confirm; watch icon syncing→idle; `Console.app` filter `subsystem:Rubien category:SyncedLibrary` shows "reconciled N pending changes"
2. Check iCloud Dashboard: `Library` zone exists, records match local count
3. Build + launch on MacBook; toggle sync on; confirm; library populates from cloud
4. Create a reference on MacBook → within ~10s it appears on Mac mini
5. Edit same reference on both within ~30s → "server wins" behavior (whichever pushed first, other device overwrites)
6. Delete on Mac mini → MacBook's copy disappears shortly after
7. Sign out of iCloud on MacBook → banner appears; library preserved. Sign back in → sync resumes
8. On Mac mini: `swift run rubien-cli sync status` → JSON showing zero dirty, tombstone count matches recent deletes, `appLockHeld: true` if app is open

### Smoke test failure diagnostics

- Push fails `.unauthorized` → entitlement or container ID wrong → check Developer portal
- Records don't appear in Dashboard → Console logs for `CKError` details
- Second device pulls nothing → verify both devices' `CKContainer(identifier:)` matches

## Commit decomposition

Codex flagged the single-commit plan as too broad. Implementation ships as four focused commits, each independently buildable and testable:

**Commit 1 — `SyncCoordinator` + state model** (scope: `Sources/RubienSync/SyncStatus.swift`, `Sources/RubienSync/SyncedLibrary.swift` stream additions, `Sources/Rubien/Sync/SyncCoordinator.swift`, tests)
- `SyncStatus` enum
- `SyncedLibrary.statusStream: AsyncStream<SyncStatus>` + publishStatus helper in existing delegate methods
- `SyncCoordinator` class with UserDefaults-backed preference, pendingConfirm state machine, entitlement + account pre-flight probes, statusTask management
- Unit tests for all the coordinator state transitions
- No UI changes; coordinator isn't yet wired into `RubienApp`. Verify via tests only.

**Commit 2 — SwiftUI surface** (scope: `RubienApp.swift`, `PreferencesView.swift`, `SyncStatusIcon.swift`, `SyncStatusBanner.swift`)
- Inject `SyncCoordinator` as `@StateObject` via `.environmentObject`
- Toolbar cloud icon with the seven visual states
- Settings section with toggle, confirm sheet, status caption, "Try again" button
- Banner view modifier at scene root
- Smoke tested by running Rubien locally in "entitlement absent" mode — UI should show `.unavailable` cleanly

**Commit 3 — CLI `sync status`** (scope: `Package.swift` CLI→RubienSync dep, `Sources/RubienCLI/SyncCommands.swift`, `Tests/RubienCLITests/SyncCommandsTests.swift`, `CLAUDE.md` + `Docs/CLI-Reference.md` updates)
- Subcommand structure, JSON contract per the shape above
- `CLAUDE.md` amendment: RubienCLI now transitively imports CloudKit

**Commit 4 — Operational hardening** (scope: `Rubien.entitlements`, `scripts/build-app.sh` notes, `Docs/superpowers/specs/2026-04-22-make-sync-runnable-setup.md`)
- Entitlements entries (dormant until paid enrollment clears + container is registered)
- Smoke test runbook
- Container-creation steps in Developer Portal, signing setup

Commits 1–3 can land during enrollment gap. Commit 4 lands once the container is registered and verified.

## Appendix — operational setup steps (user performs)

Post-enrollment:

1. **CloudKit Dashboard** (icloud.developer.apple.com) → sign in → "New Container" → identifier `iCloud.com.rubien.app` → save
2. **Xcode project settings** for the Rubien target → Signing & Capabilities → add "iCloud" capability → check "CloudKit" → select the container created above. (If you're building via `scripts/build-app.sh` / SPM, entitlements need to be configured via xcconfig + signing identity; this is the `xcconfig` plumbing called out in the plan's open decisions but deferred here — for first-pass testing, use Xcode's GUI signing.)
3. **Bundle ID must match** the container's linked identifier. Current bundle ID is `com.rubien.app` which aligns with `iCloud.com.rubien.app`.

If any of these steps are incomplete, sync stays in `.unavailable` state with a reason visible in Settings. The wiring itself needs no change.

## Open follow-ups (tracked, not blocking this spec)

- A-pks UUID migration — pre-A-pks rowID collision risk between devices
- Field-level LWW merge — currently server-wins
- `rubien-cli sync push/pull/reset` — parity gap beyond `status`
- CKAsset pipeline for PDFs — next commit in this work stream
- xcconfig-driven entitlements for CLI builds via `scripts/build-app.sh`
- "Wipe iCloud library" destructive action
