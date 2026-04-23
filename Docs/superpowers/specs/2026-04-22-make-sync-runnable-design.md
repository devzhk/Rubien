# Make CloudKit sync runnable on macOS — design

**Status:** approved by user 2026-04-22; ready for implementation plan
**Scope:** wiring commits that make the already-landed `RubienSync` target functional in the shipping app. Scalars-first, PDFs in a follow-up commit. Minimal CLI (`sync status` only). Full UI (toolbar icon + banners). Opt-in preference, default off.

## Context

`RubienSync` (10 commits on `main` as of 2026-04-22) ships a complete `CKSyncEngine`-based sync stack: per-entity `CKRecord` mappings, dirty-tracking triggers, a `SyncedLibrary` actor, tombstone lifecycle, file-lock mutex, etc. Everything compiles and has 87 passing tests, but **nothing in the shipping app ever instantiates the actor**. This spec is the design for connecting the engine to the app.

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

### Conflict resolution

Current v1 policy: server-wins on `.serverRecordChanged`. True LWW by `dateModified` is a later refinement. Single-user testing between Mac mini and MacBook is unlikely to hit this unless the user deliberately edits the same reference on both devices simultaneously.

### Container ID configuration

`SyncConstants.containerIdentifier` changes from a hardcoded `let` to a computed property that reads the `RUBIEN_CLOUDKIT_CONTAINER` env var first and falls back to `"iCloud.com.rubien.app"`. This lets you override per-launch during dev without a rebuild.

### Enrollment-gap behavior

When the actor tries to access `CKContainer.privateCloudDatabase` without the entitlement, CloudKit raises `CKException`. The coordinator catches this at `startSync()` time, tears the partial actor down, and sets `status = .unavailable(reason:)`. UI shows a toolbar warning icon and a Settings caption explaining the state. There's a manual "Try again" button in Settings that retries the `startSync()` flow — useful for flipping the switch the moment entitlement arrives without re-toggling the preference.

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

- `Sources/RubienCLI/SyncCommands.swift` — `sync status` subcommand. JSON output shape:

```json
{
  "enabled": true,
  "appLockHeld": false,
  "hasEverPushed": true,
  "dirtyByEntityType": { "reference": 3, "tag": 0, ... },
  "tombstoneCount": { "confirmed": 12, "unconfirmed": 0 },
  "syncEngineStatePath": "/Users/.../Rubien/sync-engine-state.bin"
}
```

Reads `UserDefaults` (shared suite), `SyncStateStore` queries directly on the DB, `SyncFileLock.tryLockExclusive()` to probe for app-held lock (immediately releases), and sidecar file existence. Never instantiates `SyncedLibrary`.

## Data flow

### Flow A — app launch, sync off

1. `RubienApp.init` → `SyncCoordinator()` → UserDefaults read → `userEnabled = false`
2. `coordinator.status = .disabled`
3. No actor constructed. No CloudKit calls, no entitlement check, no network
4. Toolbar icon: outline cloud, muted

### Flow B — user toggles sync ON first time

1. SwiftUI binds toggle to `coordinator.userEnabled`; flip sets `true`
2. If `didConfirmFirstRun == false`: confirm sheet shown. "Enable Sync" sets the flag + calls `coordinator.startSync()`; "Not Now" flips toggle back to `false`
3. `startSync()` instantiates `SyncedLibrary`, awaits `start()`, awaits `installTransactionObserver()`, launches a consumer Task for `statusStream`
4. `start()` runs baseline (first time only), tombstone compaction, ingestPendingChanges
5. Actor's first engine-accessing call either:
   - succeeds → actor emits `.idle` → coordinator republishes → icon goes solid
   - raises `CKException` (no entitlement) → caught by `startSync()` → coordinator sets `status = .unavailable(reason)` and tears actor down
   - hits account-signed-out → actor emits `.signedOut` → banner appears

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
2. Coordinator cancels status-stream consumer Task
3. Releases `SyncedLibrary` reference (actor deallocates)
4. `SyncTransactionObserver` is removed from the DB writer
5. Local library and sync bookkeeping (syncState, tombstones, sidecar file) **are preserved**
6. Per-table triggers keep firing silently while sync is off; dirty flags and tombstones accumulate but are harmless

ON again:
1. New `SyncedLibrary` constructed; engine reads sidecar state file → resumes with last server change token
2. Baseline one-shot is gated on `syncSession.baselineState = 'complete'` — skips
3. `ingestPendingChanges` picks up everything accumulated during the off period
4. Normal push/pull resumes

## Error handling

| Status | Trigger | UI | Recovery |
|---|---|---|---|
| `.disabled` | Toggle off | Muted outline cloud; Settings caption "Off — local library only" | User flips toggle |
| `.unavailable(reason)` | Entitlement missing, pre-enrollment | Outline cloud with ⚠; no banner | Manual "Try again" in Settings or automatic on app foreground |
| `.signedOut` | `handleAccountChange(.signOut)` or `.switchAccounts` | Cloud-with-slash icon; banner "Signed out of iCloud — sync paused. Your library is safe locally." | Automatic on re-sign-in |
| `.idle` | `.didFetchChanges` / `.didSendChanges` / end of start | Solid cloud, accent color | n/a |
| `.syncing` | `.willFetchChanges` / `.willSendChanges` | Animated solid cloud | n/a |
| `.error(.quotaExceeded)` | `.sentRecordZoneChanges` | Red warning cloud; modal alert "iCloud storage full." + "Open iCloud Settings" button | User frees space; retry on foreground |
| `.error(.networkUnavailable \| .networkFailure)` | Transient network | Warning cloud; no banner (transient) | CKSyncEngine auto-retries |
| `.error(other)` | Any other unhandled `CKError` | Warning cloud; non-modal banner "Sync error: \(localized). Will retry." | Engine retries; banner auto-dismisses on `.idle` |

**First-run confirm dialog** — only modal we show for sync, gated once per user via `UserDefaults["rubien.sync.didConfirmFirstRun"]`.

**Not handled** — partial-batch failures (engine auto-retries), zone deletion by user from iCloud Settings (wipe-and-re-upload is silent), `CKError.changeTokenExpired` (engine-internal).

## Testing

### Unit tests (no CloudKit, no entitlement)

`Tests/RubienTests/SyncCoordinatorTests.swift`:

- `testInitialStateRespectsUserDefaults` — coordinator reads toggle at init; `.disabled` when absent
- `testTogglingOnDoesNotStartUntilConfirmDismissed` — first-run gate: `userEnabled = true` + `didConfirmFirstRun = false` must not instantiate `SyncedLibrary`
- `testTogglingOffTearsDownLibrary` — toggle `false` releases library + emits `.disabled`
- `testMissingEntitlementTransitionsToUnavailable` — inject `containerProvider` that throws `CKException`; coordinator catches, sets `.unavailable`, tears down
- `testRepublishesStatusFromActorStream` — fake stream emits `.syncing` → `.idle` → `.error(.quotaExceeded)`; `@Published status` reflects each in order

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
