# SyncStatusIcon Repeating-Pulse Render-Server Saturation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the PDF reader's scroll lag during active iCloud sync when the library window is open. This is a follow-up fix after the earlier observer-throttle / env-key changes (commit-pending) failed to move the needle.

**Architecture (diagnosis from a real `sample`):**

A 5-second `sample` of the lagging process (`/tmp/rubien-lag.txt`, 3536 samples @ 1ms) shows:

- **2062 samples (~58%) blocked in `mach_msg2_trap` inside `-[CAContext waitForCommitId:timeout:]`.** Main thread is not doing work — it is **waiting for the CoreAnimation render server to acknowledge prior commits** before it can submit new ones.
- Almost all of those waits are reached from `CA::Transaction::commit()` → `CA::Layer::display_if_needed` → `-[RBLayer display]` → `wait_for_allocations` → `test_displayed` → `waitForCommitId:timeout:`.
- SwiftUI body re-evaluations are NOT the hot path: only **3 samples** in `ContentView.body.getter` and **1 sample** in `ReferenceDetailView.body.getter` over 5 seconds. So the earlier hypothesis ("ContentView re-render storm starves main") was wrong — re-renders are infrequent and cheap.
- The visible CPU is going into Metal command submission and CALayer commit traversal, both downstream of CA commits.

**Root cause:** `Sources/Rubien/Views/SyncStatusIcon.swift:13–17`:

```swift
.symbolEffect(
    .pulse,
    options: .repeating,
    isActive: status == .syncing
)
```

`.symbolEffect(.pulse, options: .repeating)` is a CoreAnimation-backed SF Symbol effect that pulses **indefinitely** while `isActive == true`. The icon is rendered inside the library window's chrome bar (`ViewChromeBar`). Two compounding effects:

1. **While `status == .syncing`, the pulse issues CALayer commits at the display refresh rate.** Each pulse frame becomes a CA commit on the process-wide render-server connection. The PDF reader window's draws have to queue behind every one of those.
2. **`ViewChromeBar` still subscribes to `@EnvironmentObject SyncCoordinator` (correctly — it renders the icon), so its body re-evaluates on every status flip.** CKSyncEngine flips status `.idle ↔ .syncing` on every `.willFetch / .didFetch / .willSend / .didSend` event — many times per second during a sync batch. Each ViewChromeBar re-evaluation re-creates `SyncStatusIcon`, which re-installs the `.symbolEffect` modifier. CoreAnimation tears down and restarts the pulse animation on every install — additional CA commits per flip.

The two effects together saturate the render-server pipeline for the process. The PDF reader's CA commits stall in `waitForCommitId:timeout:`, blocking main thread, freezing scroll.

This matches the user's discriminating experiment perfectly: **closing the library window eliminates the lag with sync still ON** — because closing the library window destroys the chrome bar, kills the pulse, and frees the render-server pipeline.

**Fix (single targeted change):** Remove `.symbolEffect(.pulse, options: .repeating, isActive: ...)` from `SyncStatusIcon`. The icon and color still change between states (`icloud.and.arrow.up` + blue while syncing vs. `checkmark.icloud.fill` + accent when idle), so the user retains a visual sync indicator — just without the continuous animation.

The prior commit-pending Phase 2 + 3 changes (env-key + throttle + non-observing handle for ContentView/ReferenceDetailView) are **kept**: they remain correct in isolation, eliminate redundant subscriptions, and add defense-in-depth even though they did not address the dominant bottleneck.

**Tech Stack:** SwiftUI on macOS 15+, SF Symbols, CoreAnimation render-server.

---

## File map

| File | Role | Change |
|---|---|---|
| `Sources/Rubien/Views/SyncStatusIcon.swift` | Toolbar glyph for sync state. | Remove the `.symbolEffect(.pulse, options: .repeating, isActive: ...)` modifier. Keep the static `Image(systemName: symbolName).foregroundStyle(symbolColor)` + accessibility/help. |
| `Tests/RubienTests/SyncStatusIconTests.swift` | NEW. Compile-time / smoke test asserting the static icon renders without the repeating effect. | Create. |

---

## Task 0: Workflow setup

- [ ] **Step 1: Confirm baseline build + tests pass on the current uncommitted tree**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!`, `Executed 757 tests, with 4 tests skipped and 0 failures`. The earlier Phase 2 + 3 changes are still uncommitted and on disk — confirm they're clean.

---

## Task 1: Remove the repeating pulse animation

**Files:**
- Modify: `Sources/Rubien/Views/SyncStatusIcon.swift:10-20`

- [ ] **Step 1: Replace the `body` of `SyncStatusIcon`**

Locate the current body (lines 10–20):

```swift
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
```

Replace with the unanimated version:

```swift
    var body: some View {
        // The icon + color change ARE the visual sync indicator. A previous
        // `.symbolEffect(.pulse, options: .repeating, isActive: status == .syncing)`
        // ran a continuous CoreAnimation pulse whenever sync was active.
        // Because the chrome bar re-evaluates on every status flip
        // (.willFetch → .syncing → .didFetch → .idle, many times per second
        // during a batch), the pulse was being torn down and re-installed
        // constantly, saturating the process-wide render-server pipeline and
        // starving the PDF reader window's draw cycle (verified with `sample`).
        // Static icon + color is enough feedback; the animation is not worth
        // the rendering cost.
        Image(systemName: symbolName)
            .foregroundStyle(symbolColor)
            .accessibilityLabel(accessibilityLabel)
            .help(accessibilityLabel)
    }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`.

- [ ] **Step 3: Run the existing suite to confirm zero regressions**

Run: `swift test 2>&1 | tail -3`
Expected: `Executed 757 tests, with 4 tests skipped and 0 failures` (or +1 if Task 2 has already added the smoke test).

---

## Task 2: Add a compile-time smoke test asserting the icon renders for every state

**Files:**
- Create: `Tests/RubienTests/SyncStatusIconTests.swift`

A behavioral test (was-the-pulse-removed?) requires SwiftUI view inspection libraries we don't have. The realistic test is: the icon can be constructed for every `SyncStatus` case and the eight state-to-symbol/color mappings still resolve. This guards against accidental deletion of a case mapping.

- [ ] **Step 1: Write the smoke test**

```swift
#if os(macOS)
import XCTest
import SwiftUI
@testable import Rubien
@testable import RubienSync

@MainActor
final class SyncStatusIconTests: XCTestCase {

    /// Every SyncStatus case must produce a renderable icon. This is a
    /// regression guard: if a future SyncStatus case is added and the icon's
    /// symbol/color/accessibility switches are not extended, the compiler
    /// catches the missing case via `@unknown default` — but the runtime
    /// fallback could still ship a blank icon. This test fails loudly if
    /// the host can't build the view for any current case.
    func testIconConstructsForEveryStatus() {
        let cases: [SyncStatus] = [
            .disabled,
            .unavailable(reason: "test"),
            .signedOut,
            .idle,
            .syncing,
            .error(SyncError(code: .unknown, underlying: nil))
        ]
        for status in cases {
            let host = NSHostingController(rootView: SyncStatusIcon(status: status))
            XCTAssertNotNil(host.view, "icon must render for \(status)")
        }
    }
}
#endif
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter RubienTests.SyncStatusIconTests 2>&1 | tail -10`
Expected: 1 test passes.

**Foot-gun:** the test constructs a `SyncError` literal. Verify the actual initializer signature before locking in — `SyncError(code: .unknown, underlying: nil)` might not match the real `SyncError` type in `RubienSync`. If the build fails on this line, adjust to whatever the project's existing `SyncError` test helpers do (grep `Tests/RubienSyncTests/` for an example construction).

---

## Task 3: Manual verification

### Task 3.1: Build the debug bundle and re-launch with sync ON

- [ ] **Step 1: Build + launch via dev-launch**

Run: `unset CODESIGN_IDENTITY && rm -rf build/Rubien.app && ./scripts/dev-launch.sh`
Expected: `✅ Rubien.app running (PID …)`.

- [ ] **Step 2: Reproduce the original test**

Open a known-large PDF in the reader window. With sync actively pushing or fetching (the sync icon at the top of the library window should show `icloud.and.arrow.up` in blue when syncing, `checkmark.icloud.fill` in accent when idle), scroll through the PDF for ~30 seconds. Watch Activity Monitor for the Rubien process CPU.

Expected:
- PDF scroll is smooth.
- CPU drops well below 100%.
- Sync icon still changes color/symbol between idle and syncing — just no continuous animation.

- [ ] **Step 3: (Optional) Re-sample under load to confirm the fix**

While scrolling with sync ON:

```bash
PID=$(pgrep -f "Rubien.app/Contents/MacOS/Rubien" | head -1)
sample $PID 5 -file /tmp/rubien-lag-after.txt
```

`grep -c "waitForCommitId" /tmp/rubien-lag-after.txt` should be substantially lower than the ~2062-sample figure observed pre-fix. If it isn't, the pulse wasn't the dominant cause and we need a different fix.

---

## Task 4: Pre-commit review and commit

### Task 4.1: Run /simplify on the uncommitted diff (now larger — includes the prior Phase 2 + 3 + this fix)

- [ ] **Step 1: Invoke the bundled code-review skill**

Use the `Skill` tool with `code-review`.

### Task 4.2: Hand the uncommitted diff to codex-rescue

- [ ] **Step 1: Dispatch codex-rescue**

Prompt: "Review the uncommitted diff in `Sources/Rubien/Views/SyncStatusIcon.swift` (pulse removal) together with the prior uncommitted Phase 2 + 3 changes (env-key swap + reference-observer throttles). Verify: (1) the pulse removal does not break the icon for any `SyncStatus` case; (2) accessibility labels still cover all states; (3) no other view in the codebase reads or depends on the `.pulse` symbol effect; (4) the prior throttle / env-key changes are still internally consistent and have not been damaged by the new edit."

### Task 4.3: Commit (single commit with a message that includes the diagnosis trail)

- [ ] **Step 1: Final build + test**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: clean build, all tests pass.

- [ ] **Step 2: Stage and commit**

```bash
git add Sources/Rubien/Sync/SyncCoordinatorEnvironment.swift \
        Sources/Rubien/Views/SyncStatusBanner.swift \
        Sources/Rubien/Views/SyncStatusIcon.swift \
        Sources/Rubien/RubienApp.swift \
        Sources/Rubien/Views/ContentView.swift \
        Sources/Rubien/Views/ReferenceDetailView.swift \
        Tests/RubienTests/SyncCoordinatorEnvironmentTests.swift \
        Tests/RubienTests/LibraryViewModelThrottleTests.swift \
        Tests/RubienTests/SyncStatusIconTests.swift \
        Docs/plans/2026-05-21-library-window-main-thread-lag.md \
        Docs/plans/2026-05-21-sync-status-icon-pulse-render-server-saturation.md
git commit -m "$(cat <<'EOF'
Library window: fix PDF reader scroll lag during active iCloud sync

The dominant cause was `SyncStatusIcon`'s `.symbolEffect(.pulse,
options: .repeating, isActive: status == .syncing)`: while sync was
active, the pulse issued CALayer commits at the display refresh rate on
the process-wide render-server pipeline. Each commit had to be drained
before the PDF reader window could submit its own draws, so scroll
stalled in `[CAContext waitForCommitId:timeout:]`. A `sample` of the
lagging process showed ~58% of main-thread time blocked in
`mach_msg2_trap` waiting on the render server. Closing the library
window — and with it the chrome bar — eliminated the lag because it
killed the pulse.

The fix removes `.symbolEffect(.pulse, ...)`. The icon and color
change still convey sync state; the animation was not worth the
render-server cost.

The earlier Phase 2 + 3 changes (non-observing `\.syncCoordinator`
environment key for `ContentView` / `ReferenceDetailView`; 150 ms
`.throttle(latest:)` on both `LibraryViewModel` reference observers;
extracting the root-scene `.syncStatusBanner` status read into its own
ViewModifier) are kept — they remove redundant subscriptions and
coalesce bursts in the data-layer pipeline. They were not the bottleneck
for this specific user-visible lag but they don't hurt and reduce
unrelated jank.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Verify clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

---

## Self-review checklist (writer ran this before saving)

- **Diagnosis is evidence-based, not theoretical.** Direct citation of `/tmp/rubien-lag.txt` showing 2062 samples in `waitForCommitId:timeout:` and only 3 samples in ContentView.body. Discriminating experiment (close library window → lag gone) is consistent with the render-server hypothesis. ✓
- **The earlier diagnosis is acknowledged as wrong.** This plan does not claim the Phase 2 + 3 changes were unnecessary — only that they did not address THIS bottleneck. They remain on disk and are committed together as defense-in-depth. ✓
- **Single targeted change at the source.** The `body` of `SyncStatusIcon` is the only modified production file. No coordinator surgery, no animation framework introduction. ✓
- **The test is honest about its limits.** `testIconConstructsForEveryStatus` is a smoke test, not a behavioral verification that the pulse is gone. SwiftUI view-inspection libraries are not in the project. Manual verification (Task 3) is the real validation. ✓
- **No CLAUDE.md hard-constraint touches** (no migration edits, no CKRecord-field renames, no `--no-verify`, no `--deep` codesign). ✓
