# Library-Window Main-Thread Lag (sync ON) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate PDF-reader scroll lag that appears only when iCloud sync is active *and* the library window is open. Bring CPU back below 100% on bursty sync batches.

**Architecture:** Two compounding storms on the library window's main thread are starving the PDF-reader window's draw cycle:

1. **Sync-status flip storm.** `CKSyncEngine` fires `willFetchChanges` / `didFetchChanges` / `willSendChanges` / `didSendChanges` per batch. `SyncedLibrary.publishStatus(.syncing|.idle)` propagates into `SyncCoordinator.@Published status`. Every SwiftUI view holding `@EnvironmentObject syncCoordinator` re-evaluates its body on every flip — including `ContentView` (`ContentView.swift:735`) and `ReferenceDetailView` (`ReferenceDetailView.swift:33`), which do **not** read `.status` (they only use the coordinator to call `kickPDFUploadDrainer()` or hand a reference off to the view model). Separately, the root scene reads `.status` directly at `RubienApp.swift:33` (`.syncStatusBanner(status: syncCoordinator.status) { … }`) — that read is captured at the scene-body level, so the entire root scene's modifier chain re-evaluates on every flip.
2. **observeReferences storm.** A sync batch commits many `reference` rows (and `syncState` / `pdfCache` rows that don't affect this particular observer in the default view). `LibraryViewModel` subscribes to two `observeReferences` publishers: a scoped one (`AppDatabase.swift:2647`, fetch is `Reference.all()` + tag-join only under `.tag` scope + FTS only when a keyword filter is active + pdfCache join only with `hasPDF` filter, scheduled `.async(onQueue: .main)`) and an unscoped title scan (`AppDatabase.swift:2636`). Each tracked-table commit re-fires the fetch, schedules an emission to main, and updates `@Published references` / `allReferenceTitles` — forcing ContentView and ReferenceTableView to diff and rebuild the table on each tick. The per-emit cost is highest under keyword filtering (FTS+joins) but is still enough to lag main under the default unfiltered view, because dozens of single-row commits in a sync batch each pay a full SQLite fetch + Combine emission + `@Published` assignment + downstream view diff.

The user already verified the diagnosis with the discriminating test: closing the library window (leaving only the PDF reader) eliminates the lag entirely with sync still ON. Both storms originate in the library window's view + observer tree.

**Fix:**
- **Phase 2 — narrow `SyncCoordinator` observation scope.** Introduce a non-observing `EnvironmentValues.syncCoordinator` key. Switch the two non-status consumers (ContentView, ReferenceDetailView) off `@EnvironmentObject` and onto `@Environment(\.syncCoordinator)`. Keep `@EnvironmentObject` where the status actually renders (ViewChromeBar, RubienSettingsView). Encapsulate the root-scene `.syncStatusBanner` status read inside a tiny `ViewModifier` that owns the `@EnvironmentObject` itself, so `RubienApp.body` (which carries the entire root scene's view-expression tree) no longer reads `.status` and stops re-evaluating on every status flip.
- **Phase 3 — throttle the heavy observers.** Coalesce burst emissions on both `LibraryViewModel` reference observers with `.throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)`.

Phase 1 is a single regression-probe test that fails today and proves the storm is real; Phases 2 and 3 each carry it from red to green and then commit.

**Tech Stack:** SwiftUI, Combine, GRDB 7 `ValueObservation`, `CKSyncEngine`, Swift 6 actors / `@MainActor`.

---

## File map

| File | Role | Change |
|---|---|---|
| `Sources/Rubien/Sync/SyncCoordinatorEnvironment.swift` | NEW. Houses the non-observing `EnvironmentValues.syncCoordinator` key. | Create. |
| `Sources/Rubien/Views/SyncStatusBanner.swift` | Existing modifier. | Add a sibling `View.syncStatusBannerFromCoordinator()` extension whose `ViewModifier` body owns `@EnvironmentObject SyncCoordinator` — so the status read moves out of `RubienApp.body`. |
| `Sources/Rubien/RubienApp.swift` | Root scene; injects `SyncCoordinator` into env. | Add a sibling `.environment(\.syncCoordinator, syncCoordinator)` modifier next to the existing `.environmentObject(syncCoordinator)` so both forms resolve to the same instance. Replace the inline `.syncStatusBanner(status: syncCoordinator.status) { … }` at line 33 with the new `.syncStatusBannerFromCoordinator()` so the root scene body no longer reads `.status`. |
| `Sources/Rubien/Views/ContentView.swift` | Library shell. | Replace `@EnvironmentObject private var syncCoordinator: SyncCoordinator` (line 735) with `@Environment(\.syncCoordinator) private var syncCoordinator: SyncCoordinator?`. Update the three call sites that read it (lines 1178, 1257, and the `weak var` wiring in `LibraryViewModel` at line 119) to unwrap. Throttle the heavy observer (lines 199–207, 226–238). |
| `Sources/Rubien/Views/ReferenceDetailView.swift` | Detail pane. | Replace `@EnvironmentObject` (line 33) with `@Environment(\.syncCoordinator)`. Update the two `kickPDFUploadDrainer` call sites (1093, 1119) to unwrap. |
| `Sources/Rubien/Views/ViewChromeBar.swift` | Renders the sync-status icon. | **No change.** Keeps `@EnvironmentObject` because it reads `.status` legitimately. |
| `Sources/Rubien/Views/RubienSettingsView.swift` | Sync settings UI; reads `.status`. | **No change.** Keeps `@EnvironmentObject`. |
| `Tests/RubienTests/SyncCoordinatorEnvironmentTests.swift` | NEW. Verifies the env-key plumbing. | Create. |
| `Tests/RubienTests/LibraryViewModelThrottleTests.swift` | NEW. Drives a synthetic burst of commits and asserts the references observer coalesces to ≤ N emissions. | Create. |

---

## Task 0: Workflow setup

- [ ] **Step 1: Confirm baseline tests pass before any change**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed`. Record current test count for the post-change diff.

- [ ] **Step 2: Confirm `swift build` is clean on the current main**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`.

---

## Phase 1 — Regression probe (red)

The user already verified the storm exists empirically (closing the library window kills the lag). This phase encodes the storm-rate assumption as an automated red test so Phase 2 + 3 can drive it to green. It is intentionally narrow — one test that asserts the heavy observer coalesces under burst input. The status-flip storm is structurally fixed in Phase 2 (the new env key cannot subscribe, by design), so no separate red test for that.

### Task 1.1: Write a failing throttle-coalescing test

**Files:**
- Create: `Tests/RubienTests/LibraryViewModelThrottleTests.swift`

- [ ] **Step 1: Write the test file**

The test drives the storm through `LibraryViewModel` so it actually exercises the throttle insertion point added in Phase 3 (inside `rebuildReferenceObserver`). A test that subscribed to the raw `AppDatabase.observeReferences(...)` publisher would not catch a missing or mis-applied throttle in the view-model chain.

```swift
#if os(macOS)
import XCTest
import Combine
import GRDB
@testable import Rubien
@testable import RubienCore

/// Bursty writes to the `reference` table during sync apply commit one row at
/// a time. Without throttling, every commit triggers a fresh
/// `fetchReferences` + a `@Published references` assignment on main, which
/// starves the PDF reader window's draw cycle.
///
/// This test commits 20 rows in rapid succession and asserts
/// `LibraryViewModel.$references` delivers no more than 4 emissions in the
/// ~600 ms window after the burst — i.e. the 150 ms throttle (applied inside
/// `rebuildReferenceObserver`) has coalesced the burst.
@MainActor
final class LibraryViewModelThrottleTests: XCTestCase {

    func testReferenceObserverCoalescesBurstyCommits() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var cancellables = Set<AnyCancellable>()

        // Seed an initial row so the view-model primes the observer with a
        // non-empty fetch.
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, ?, ?, ?)",
                           arguments: [1, "seed", Date(), Date()])
        }

        let vm = LibraryViewModel(db: db)

        // Wait for the view-model's initial emission (which seeds
        // `references` with the row above). We can't use `dropFirst()` here
        // because `LibraryViewModel.init -> setupObservation` may have
        // synchronously assigned to `references` before our `sink` attaches,
        // which would cause `dropFirst()` to skip the seed-row notification
        // and `primed` to time out. Instead, fulfill on the first emission
        // that matches the post-seed count of 1.
        let primed = expectation(description: "view-model primed with seed row")
        var primedOnce = false
        var emissionCount = 0
        let countLock = NSLock()
        vm.$references
            .sink { refs in
                countLock.lock()
                let alreadyPrimed = primedOnce
                if alreadyPrimed { emissionCount += 1 }
                countLock.unlock()
                if !alreadyPrimed, refs.count == 1 {
                    countLock.lock(); primedOnce = true; countLock.unlock()
                    primed.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [primed], timeout: 2.0)

        // Burst: 20 sequential single-row commits.
        for i in 2...21 {
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, ?, ?, ?)",
                               arguments: [i, "row\(i)", Date(), Date()])
            }
        }

        // Wait long enough for any throttle window (150 ms) plus scheduling
        // slack to close. 600 ms upper-bounds ~4 throttle windows.
        try await Task.sleep(nanoseconds: 600_000_000)

        countLock.lock(); let observed = emissionCount; countLock.unlock()
        XCTAssertLessThanOrEqual(observed, 4,
                                 "burst of 20 commits should coalesce into ≤ 4 emissions; got \(observed)")
        XCTAssertGreaterThanOrEqual(observed, 1,
                                    "throttle must still deliver at least one update")
        XCTAssertEqual(vm.references.count, 21,
                       "after the throttle window settles, the final value must include every committed row")
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails (RED)**

Run: `swift test --filter RubienTests.LibraryViewModelThrottleTests 2>&1 | tail -20`
Expected: **FAIL** with `observed` > 4 (likely 15–20 — one emission per commit).
If the test passes already, the storm assumption is wrong → stop and re-investigate before changing any code.

- [ ] **Step 3: Do NOT commit the red test alone** — Phase 3 makes it green in the same commit.

---

## Phase 2 — Narrow SyncCoordinator observation scope

### Task 2.1: Add a non-observing environment key for SyncCoordinator

**Files:**
- Create: `Sources/Rubien/Sync/SyncCoordinatorEnvironment.swift`

- [ ] **Step 1: Write the env-key shim**

```swift
#if os(macOS)
import SwiftUI

/// Non-observing handle to the app's `SyncCoordinator`.
///
/// Use this in views that need to *call* the coordinator (e.g.
/// `kickPDFUploadDrainer()`) but do **not** render anything from its
/// `@Published` properties. Reading via `@Environment(\.syncCoordinator)`
/// does not subscribe to `objectWillChange`, so the view's body is not
/// re-evaluated on every `status` flip. Views that legitimately render the
/// status (e.g. `ViewChromeBar`) keep `@EnvironmentObject SyncCoordinator`.
private struct SyncCoordinatorKey: EnvironmentKey {
    static let defaultValue: SyncCoordinator? = nil
}

extension EnvironmentValues {
    var syncCoordinator: SyncCoordinator? {
        get { self[SyncCoordinatorKey.self] }
        set { self[SyncCoordinatorKey.self] = newValue }
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`.

### Task 2.2: Add a plumbing test for the new env key

**Files:**
- Create: `Tests/RubienTests/SyncCoordinatorEnvironmentTests.swift`

- [ ] **Step 1: Write the test**

```swift
#if os(macOS)
import XCTest
import SwiftUI
import GRDB
@testable import Rubien
@testable import RubienCore
@testable import RubienSync

/// The non-observing `\.syncCoordinator` environment key must surface the
/// same instance that's injected at the root scene. (Subscription semantics —
/// "does NOT re-render on @Published flips" — are structural and guaranteed
/// by SwiftUI's `@Environment` vs `@EnvironmentObject` split; this test just
/// verifies plumbing.)
@MainActor
final class SyncCoordinatorEnvironmentTests: XCTestCase {

    func testEnvironmentKeyDefaultIsNil() {
        XCTAssertNil(EnvironmentValues().syncCoordinator)
    }

    func testEnvironmentKeyRoundTripsCoordinator() throws {
        let db = try AppDatabase(DatabaseQueue())
        let coordinator = SyncCoordinator(appDatabase: db)
        var env = EnvironmentValues()
        env.syncCoordinator = coordinator
        XCTAssertTrue(env.syncCoordinator === coordinator)
    }
}
#endif
```

- [ ] **Step 2: Run and verify green**

Run: `swift test --filter RubienTests.SyncCoordinatorEnvironmentTests 2>&1 | tail -10`
Expected: 2 tests pass.

### Task 2.3: Add a thin `syncStatusBannerFromCoordinator()` modifier that owns the EnvironmentObject

**Files:**
- Modify: `Sources/Rubien/Views/SyncStatusBanner.swift:147-151`

Goal: move the `.status` read out of `RubienApp.body`. The new modifier subscribes to `@EnvironmentObject SyncCoordinator` inside its own tiny view body, so the root-scene body no longer triggers a re-evaluation on every status flip.

- [ ] **Step 1: Append the new modifier + extension to the existing file**

After the existing `View.syncStatusBanner(status:onRetry:)` extension (around line 147–151), append:

```swift
/// Variant of `.syncStatusBanner` that reads the status from the ambient
/// `SyncCoordinator` instead of taking it as a parameter. Use at the root
/// scene so `RubienApp.body` does NOT have to read `syncCoordinator.status`
/// itself — otherwise the whole scene-body view-expression tree re-evaluates
/// on every status flip (multiple times per sync batch).
private struct SyncStatusBannerFromCoordinator: ViewModifier {
    @EnvironmentObject private var coordinator: SyncCoordinator

    func body(content: Content) -> some View {
        content.syncStatusBanner(status: coordinator.status) {
            Task { await coordinator.retryStartSync() }
        }
    }
}

extension View {
    func syncStatusBannerFromCoordinator() -> some View {
        modifier(SyncStatusBannerFromCoordinator())
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`.

### Task 2.4: Inject the env key in RubienApp and switch the banner to the coordinator-aware modifier

**Files:**
- Modify: `Sources/Rubien/RubienApp.swift:18-47, 56-62`

- [ ] **Step 1: Add `.environment(\.syncCoordinator, ...)` to both injection points and swap the inline banner**

Locate the WindowGroup body (line 19). Add the new environment modifier directly after the existing `.environmentObject(syncCoordinator)`, AND replace the inline `.syncStatusBanner(status: syncCoordinator.status) { … }` with the new coordinator-aware variant:

```swift
            ContentView()
                .environmentObject(syncCoordinator)
                .environment(\.syncCoordinator, syncCoordinator)
                #if canImport(Sparkle)
                .environment(updateController)
                .focusedSceneValue(\.updateController, updateController)
                #endif
                .overlay(alignment: .top) {
                    if let toast = addinToast {
                        AddinToast(message: toast.message, tone: toast.tone)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .syncStatusBannerFromCoordinator()
                .task {
                    await syncCoordinator.startIfEnabled()
                }
                .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
                    // … unchanged …
                }
```

The `.task { await syncCoordinator.startIfEnabled() }` call still reads `syncCoordinator` but does NOT subscribe — `await` on a method does not register the scene body as an observer of `@Published` properties. The body re-evaluates exactly once at scene construction.

And in the Settings scene (lines 56–62):

```swift
        Settings {
            RubienSettingsView()
                .environmentObject(syncCoordinator)
                .environment(\.syncCoordinator, syncCoordinator)
                #if canImport(Sparkle)
                .environment(updateController)
                #endif
        }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`. Both injections still resolve to the same `@StateObject` instance.

- [ ] **Step 3: Verify no remaining direct `.status` read in `RubienApp.swift`**

Run: `grep -n "syncCoordinator\.status" Sources/Rubien/RubienApp.swift || echo "no direct .status reads — good"`
Expected: `no direct .status reads — good`.

### Task 2.5: Switch ContentView to the non-observing handle

**Files:**
- Modify: `Sources/Rubien/Views/ContentView.swift:735, 1178, 1257`

- [ ] **Step 1: Swap the property wrapper at line 735**

```swift
    @StateObject private var viewModel = LibraryViewModel()
    @Environment(\.syncCoordinator) private var syncCoordinator: SyncCoordinator?
    @State private var showSearch = false
```

- [ ] **Step 2: Unwrap at line 1178 (`viewModel.syncCoordinator = syncCoordinator`)**

```swift
        .onAppear {
            // Hand the sync coordinator to the view model so import flows
            // inside the model can kick the PDF upload-queue drainer.
            viewModel.syncCoordinator = syncCoordinator
        }
```

`LibraryViewModel.syncCoordinator` is already declared `weak var syncCoordinator: SyncCoordinator?` (line 119), so the optional assignment is a direct match — no signature change needed.

- [ ] **Step 3: Unwrap at line 1257 (`Task { await syncCoordinator.kickPDFUploadDrainer() }`)**

```swift
                Task { [weak syncCoordinator] in
                    await syncCoordinator?.kickPDFUploadDrainer()
                }
```

The `[weak syncCoordinator]` capture is a no-op for our root-owned coordinator (it lives in `@StateObject`), but it makes the optionality explicit and avoids a force-unwrap.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`.

- [ ] **Step 5: Run app-target tests to verify the wiring still works**

Run: `swift test --filter RubienTests 2>&1 | tail -10`
Expected: all RubienTests pass, including the new env-key test from Task 2.2.

### Task 2.6: Switch ReferenceDetailView to the non-observing handle

**Files:**
- Modify: `Sources/Rubien/Views/ReferenceDetailView.swift:33, 1093, 1119`

- [ ] **Step 1: Swap the property wrapper at line 33**

```swift
    @Environment(\.syncCoordinator) private var syncCoordinator: SyncCoordinator?
```

- [ ] **Step 2: Unwrap both `kickPDFUploadDrainer` call sites (1093 and 1119)**

```swift
                    Task { [weak syncCoordinator] in
                        await syncCoordinator?.kickPDFUploadDrainer()
                    }
```

and

```swift
        Task { [weak syncCoordinator] in
            await syncCoordinator?.kickPDFUploadDrainer()
        }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`.

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests pass except the Phase 1 red test (still red — Phase 3 fixes it).

---

## Phase 3 — Throttle the heavy reference observers

### Task 3.1: Add throttle to the scoped reference observer in LibraryViewModel

**Files:**
- Modify: `Sources/Rubien/Views/ContentView.swift:226-238`

- [ ] **Step 1: Update `rebuildReferenceObserver` to throttle**

Locate `rebuildReferenceObserver` (line 215) and modify the publisher chain:

```swift
        referenceObserverCancellable = db
            .observeReferences(scope: scope, filter: filter, limit: 0)
            // Coalesce bursty commits. Sync apply batches commit reference
            // rows back-to-back; each commit re-fires `fetchReferences` (a
            // SQLite query — joins under `.tag` scope, FTS only when a
            // keyword filter is active) and emits to main. Without this,
            // the burst saturates the main thread and starves any PDF
            // reader window currently rendering. `latest: true` keeps the
            // freshest snapshot per window.
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.errorMessage = "References refresh failed: \(error.localizedDescription)"
                    }
                },
                receiveValue: { [weak self] refs in
                    self?.references = refs
                }
            )
```

- [ ] **Step 2: Verify the Phase 1 red test now passes**

Run: `swift test --filter RubienTests.LibraryViewModelThrottleTests 2>&1 | tail -10`
Expected: 1 test, **PASS** with `observed ≤ 4`.

### Task 3.2: Add throttle to the title-scan observer

**Files:**
- Modify: `Sources/Rubien/Views/ContentView.swift:198-207`

- [ ] **Step 1: Throttle the all-titles observer**

The unscoped `observeReferences()` powers `allReferenceTitles` (used by sidebar keyword extraction). Same burst risk, smaller blast radius — throttle with the same 150 ms window:

```swift
        // Observe all reference titles for smart keyword extraction.
        db.observeReferences()
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] refs in
                    self?.allReferenceTitles = refs.map(\.title)
                }
            )
            .store(in: &cancellables)
```

Note: `.throttle` runs on `DispatchQueue.main`, so the subsequent `.receive(on: DispatchQueue.main)` is a no-op for the throttled branch — but leave it in place because it also covers the `LibraryChangeBroadcaster` cross-process nudge branch inside `observePublisher`, which originates on a different queue.

- [ ] **Step 2: Build + run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests pass, including both phase-1 tests and the new env-key tests.

---

## Phase 4 — Manual verification

### Task 4.1: Build the debug bundle and launch with sync ON

- [ ] **Step 1: Build the debug app**

Run: `./scripts/build-app.sh`
Expected: `build/Rubien.app` produced.

- [ ] **Step 2: Make sure no leaked Release identity is in the shell env**

Run: `echo "CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-<unset>}"`
Expected: `<unset>` or empty. If a `Developer ID Application: …` identity is shown, run `unset CODESIGN_IDENTITY && rm -rf build/Rubien.app && ./scripts/dev-launch.sh` per the previously-fought foot-gun.

- [ ] **Step 3: Launch via dev-launch**

Run: `./scripts/dev-launch.sh`
Expected: app launches; iCloud sync activates per the saved preference.

- [ ] **Step 4: Reproduction protocol**

Open a known-large PDF in the reader window. With sync actively pushing or fetching (look for the syncing icon in `ViewChromeBar`), scroll through the PDF for ~30 seconds. Watch Activity Monitor for the Rubien process CPU.

Expected: scroll is smooth; CPU stays well below 100%; no blank-page stutter.

If the lag persists, capture a 60-second log sample:

```bash
log show --predicate 'process == "Rubien"' --last 1m --info | wc -l
```

Compare against the pre-fix baseline (~30 k lines per 90 s during sync from the previous investigation). A meaningful drop in render/observation log noise confirms the fix.

- [ ] **Step 5: Cross-check legitimate status rendering still works**

Confirm the sync-status icon in the chrome bar still animates between idle / syncing / error states during a sync batch. (This is the only path that should still re-evaluate on status flips.)

---

## Phase 5 — Pre-commit review + commit

### Task 5.1: Run /simplify on the uncommitted diff

- [ ] **Step 1: Invoke the bundled code-review skill**

Use the `Skill` tool with `code-review` (matches the stored user preference for max-effort review).

- [ ] **Step 2: Triage findings**

For each agent finding, decide fix vs skip. Apply fixes inline; do not bundle drive-by refactors.

### Task 5.2: Hand the uncommitted diff to codex-rescue

- [ ] **Step 1: Dispatch codex-rescue on the staged + unstaged diff**

Prompt: "Review the uncommitted diff that implements the library-window main-thread lag fix described in `Docs/superpowers/plans/2026-05-21-library-window-main-thread-lag.md`. Verify: (1) the `\.syncCoordinator` environment key swap is structurally correct (no view that reads `.status` was downgraded by accident); (2) the throttle windows do not introduce a perceptible first-emit lag for the search / sidebar-click path; (3) the regression test actually measures what it claims (no false-green from the seed-row priming step)."

### Task 5.3: Final build + test + commit

- [ ] **Step 1: Final build + test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: clean build, all tests pass.

- [ ] **Step 2: Stage and commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinatorEnvironment.swift \
        Sources/Rubien/Views/SyncStatusBanner.swift \
        Sources/Rubien/RubienApp.swift \
        Sources/Rubien/Views/ContentView.swift \
        Sources/Rubien/Views/ReferenceDetailView.swift \
        Tests/RubienTests/SyncCoordinatorEnvironmentTests.swift \
        Tests/RubienTests/LibraryViewModelThrottleTests.swift \
        Docs/superpowers/plans/2026-05-21-library-window-main-thread-lag.md
git commit -m "$(cat <<'EOF'
Library window: kill main-thread storm that lags PDF reader during sync

Two compounding storms saturated the library window's main thread during
active iCloud sync, starving the PDF reader window's draw cycle:

1. SyncCoordinator status flips re-rendered every view holding
   @EnvironmentObject syncCoordinator, plus the root scene body via
   a direct `.syncStatusBanner(status: coordinator.status)` read in
   RubienApp. Most of those consumers (ContentView, ReferenceDetailView,
   the root scene itself) never render the status — they only call
   `kickPDFUploadDrainer()` or wire the coordinator into the view model.
2. observeReferences re-fetched and emitted to main on every commit in a
   sync batch — dozens of full table fetches + @Published assignments
   per second, even in the default unfiltered view where the per-fetch
   cost is just `Reference.all().fetchAll`.

Phase A introduces a non-observing \.syncCoordinator environment key for
views that don't render .status, and moves the root-scene status read
behind a tiny ViewModifier that owns the EnvironmentObject itself.
Phase B throttles both LibraryViewModel reference observers to
150 ms / latest, coalescing burst emissions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Verify clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

---

## Self-review checklist (writer ran this before saving)

- **Spec coverage:** Both storms diagnosed in the architecture section are addressed — Phase 2 fixes storm 1 (sync-status flips at ContentView + ReferenceDetailView + the root scene's `.syncStatusBanner` site), Phase 3 fixes storm 2 (observer re-fires). ✓
- **Placeholder scan:** No TBDs, no "implement later"; every code step has actual code. ✓
- **Type consistency:** `syncCoordinator` is `SyncCoordinator?` everywhere after the swap (matches the env-key's optional default and the existing `weak var` on `LibraryViewModel`). The throttle parameters (`for:`, `scheduler:`, `latest:`) match Combine's `Publisher.throttle` signature. `EnvironmentKey.defaultValue` is `SyncCoordinator?`. ✓
- **No `--deep`, no `--no-verify`, no migration edits, no CKRecord-field renames** — Phase scope is SwiftUI views + Combine wiring + one new env key + one new view modifier + tests. ✓
- **Test fidelity:** the throttle test drives the burst through `LibraryViewModel`, not the raw DB publisher, so it actually exercises the throttle insertion point. The env-key test imports `GRDB` because it constructs `DatabaseQueue` directly. ✓
- **Codex review round 1 findings addressed:** Blockers #10 (test routed via view model) and #14 (`import GRDB` added) — both fixed. Important #5 (overstated FTS+joins claim) — diagnosis prose AND the throttle code comment in Task 3.1 now both qualify "FTS only under keyword filter; joins only under tag scope." Important #9 (root-scene `.syncStatusBanner` status read at `RubienApp.swift:33`) — addressed via the new Task 2.3 `syncStatusBannerFromCoordinator` modifier and Task 2.4 replacement at the call site. ✓
- **Codex review round 2 findings addressed:** Important #1 (stale FTS+joins comment inside the Task 3.1 code block) — comment rewritten to match the corrected prose. Important #2 (race-prone `dropFirst()` priming in the throttle test) — fulfillment condition now checks `refs.count == 1` (post-seed-row count) instead of relying on exactly one suppressed synchronous emission. ✓
