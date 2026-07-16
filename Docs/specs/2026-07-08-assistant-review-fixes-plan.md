# Assistant availability / reader review — fix plan

**Date:** 2026-07-08
**Scope:** Fixes for issues found reviewing the two commits `5e736e6` (Remember assistant sidebar visibility) and `f7c6bd0` (Detect assistant CLI auth status), both still local on `main` (unpushed).
**Source:** `/code-review` (partial, Fable-max — limited out) + an Opus gap-sweep. Findings deduped by hand; the availability-detection subcommands were verified live against the installed CLIs (see "Verification already done").

## Status

- **Commit 1 (P0) — DONE** (`bd8ccfb`, branch `bugfix/assistant-availability-gating`): #10 (optimistic-nil, path A) + #1 (probe-token guard + synchronous `switchProvider` bump) + the `send()` turnProvider/stale-generation fix that Codex surfaced. Build clean; `RubienTests` 390 pass / 2 skipped / 0 fail. Reviewed by Codex (gpt-5.5, medium — 1 correctness issue, fixed) and an Opus simplify sweep (1 test-pref-leak fix, rest affirmed tight). Reviews run on Codex + Opus, never Fable.
- **Commit 2 (P1 probe layer) — DONE** (`a43013c`): #3 (`captureStderr` flag so the version probe can't be stalled by a grandchild holding stderr), #11 (cache only path+version, re-probe auth every call — added a reprobe test per provider), #8 (documented the load-bearing negatives-first ordering). #12 was already covered by existing signed-out fixtures. Build clean; `RubienTests` 392 pass / 2 skipped / 0 fail. Codex review clean; `/simplify` (literal skill, Opus session) → collapsed a double `environment` build. **Deferred:** hoisting the parallel `isAvailable()` flow into a shared `AgentBinaryProbe` helper — net-neutral / heavier abstraction at two providers (reuse vs altitude split; sided with reuse). Revisit at a 3rd backend.
- **Commit 3 (P1 sidebar & reader UX) — DONE** (`c52068c`): #2 (setup card + Recheck now also shown as a banner above the composer when a conversation is active and the backend is known not-ready — reuses `assistantSetupBlock`/`assistantSetupCopy`; two placements are mutually exclusive), #4 (`setChatSidebarVisible` `persist` flag; Selection→Ask passes `persist: false` so it reveals without overwriting the global hide pref, and no longer leaks `true` into the next window's init seed). View-state changes, no pure unit seam. Build clean; `RubienTests` 392 pass / 2 skipped / 0 fail. Codex review clean; `/simplify` (4 Opus agents) all clean — no changes.
- **Commit 4 (P2/P3 settings + test hygiene) — DONE** (`5c84952`): #6 (Settings shows the resolved path for the installed-but-unauthenticated state, in the shared `agentStatusRow` so both backends get it), #7 (restored the Codex privacy footer, trimmed to one crisp sentence per user), #9 (`makeCodexAuthProbeCLI` now uses a `cat <<'STATUS'` heredoc like the Claude helper). Build clean; `RubienTests` 392 pass / 2 skipped / 0 fail. Codex review clean; `/simplify` (4 Opus agents) all clean.
- **#5 / #13 — DONE** (`b872972` on `bugfix/reader-window-sizing`, merged to main `635b7ec`): web-reader window floor now tracks the visible panels (`ReaderWindowMinWidthEnforcer`); open-time floor honors the assistant pref. Shipped alongside `fc4c1ba` — remember-last-reader-size (Safari model, 1200 default) + the root-cause fix: **NSWindow shrinks to the SwiftUI content's fitting size when an NSHostingController becomes its contentViewController, even with `sizingOptions = []`** — this had silently defeated the per-doc frame autosave all along (why readers "always opened narrow"). Fix: re-assert `setContentSize` after assignment. All live-verified; Codex + /simplify clean; 394 tests / 0 fail.

**ALL 13 findings resolved.** Everything is local on `main` (unpushed).

## Verification already done (2026-07-08)

Ran the real CLIs on this machine:

- `claude auth status --json` → `{"loggedIn": true, "authMethod": "claude.ai", … }`, exit 0. → `AgentAuthProbe.claudeStatus` (reads `object["loggedIn"] as Bool`) is **correct**.
- `codex login status` → `Logged in using ChatGPT`, exit 0. → `AgentAuthProbe.codexStatus` (`contains("logged in")` + exit 0) classifies the signed-in case **correctly**.

Consequence: the auth-detection feature works for signed-in users; #12 drops to "signed-out phrasing not empirically confirmed," and #8 drops to a defensive tidy. The real defects are races / gating / caching / UI.

## Issues, ranked, with the confirmed fix

### P0 — affects every user of these commits

**#10 Send is blocked on every reader-window open (regression).**
`ChatSessionController.canSendWithCurrentAvailability` is `availability?.isReady == true` (`ChatSessionController.swift:203`); `send()` newly guards on it (`:210`). A fresh window starts with `availability == nil` (`ReaderChatSession.make` never passes `initialAvailability`, `ReaderChatSession.swift:67`), populated only after the sidebar mounts via `.task { recheckAvailability() }` (`ChatSidebarView.swift:41`), which runs two sequential subprocess probes. So every newly-opened window shows "Checking assistant setup…" with send greyed and ⌘↩ swallowed for ~1–2s even for a signed-in user (amplified to ~10s by #3). Each window re-probes cold (only *ready* is cached, per provider instance).
- **⚠ This is deliberate, tested behavior** — `f7c6bd0` added `testCanSendWithCurrentAvailabilityRequiresReadyBackend` (asserts `nil` → `canSend == false`, `ChatSessionControllerTests.swift:903`) and `testSendDoesNotCallProviderWhileAvailabilityIsChecking` (`:917`). So "block while checking" was an intentional choice, not a bug. The question is whether its UX cost (dead composer on every cold window open) is acceptable. **Two paths — needs the author's call (see Open decisions).**
- **Fix (path A, optimistic):** treat unknown (`nil`) as allowed — `availability?.isReady ?? true` — so the composer works immediately and a genuinely-missing backend degrades to a turn-failure notice (pre-PR behavior); known `.notFound` / `.unauthenticated` keep blocking. Rely on the existing `.task { recheckAvailability() }` (`ChatSidebarView.swift:41`) to populate availability — do NOT also probe at construction (Codex: avoid double-probing). Let the start page show suggestions (not the "Checking…" gate) while `nil`.
- **Fix (path B, keep the block, make it fast):** preserve the block but resolve availability ~instantly via a shared cross-window "ready" cache (see #11 — the cache must still re-probe auth so sign-out is detected). First window still has probe latency; windows 2+ are instant.
- **Files:** `ChatSessionController.swift` (:203–205), `ChatSidebarView.swift` (`assistantSetupCopy` :227 — return `nil` while checking so suggestions show). **Either path must rewrite the two f7c6bd0 tests** to the chosen behavior — do not merely delete them.

**#1 Availability probe race overwrites the current backend.**
`recheckAvailability()` writes `availability = await provider.isAvailable()` with no staleness guard (`ChatSessionController.swift:458`). `switchProvider` sets `availability = nil` then fires `Task { recheckAvailability() }` (`:369–372`); a slow in-flight probe for the *previous* backend (or a mount-time `.task` racing a switch) lands afterward and stamps the wrong backend's state. `RubienSettingsView` already solves this exact race with a `probeGeneration` token (`RubienSettingsView.swift:20,518–524`); the controller has no equivalent.
- **Fix:** mirror the Settings pattern — a monotonic `availabilityProbeToken` bumped at the start of each `recheckAvailability()`; drop the write if the token changed across the `await`. **Also bump the token synchronously inside `switchProvider` (`:369`, when it sets `availability = nil`)** — Codex caught that bumping only at the scheduled `Task` start leaves a gap where an old probe lands between `availability = nil` and the new task running. Optionally also capture + compare the provider kind as a belt-and-suspenders guard.
- **Files:** `ChatSessionController.swift` (:458–460, :358–373).

### P1 — realistic triggers

**#2 Setup card + Recheck unreachable after resuming a History conversation.**
The setup/warning block (the only in-sidebar Recheck button) renders only inside `startPage`, gated on `!session.hasMessages` (`ChatSidebarView.swift:163,200`). Resuming a past conversation while signed out sets `hasMessages = true`, so the transcript loads with a silently-disabled composer, no reason, no Recheck — even after the user signs in via Terminal. The pre-PR full-pane `emptyState` covered this regardless of conversation state.
- **Fix:** in `content` (`:158`), also render the setup affordance (reason + Recheck) above the composer when `hasMessages && assistantSetupCopy != nil` — e.g. a compact banner reusing `assistantSetupBlock`. Start page keeps the full version for the fresh state.
- **Files:** `ChatSidebarView.swift`.

**#11 Stale "ready" cache → Recheck becomes a no-op after mid-session sign-out / token expiry.**
Both providers cache only the *ready* result and never invalidate it (`ClaudeCodeProvider.swift:414,433`; `CodexProvider.swift:884,904`). The comment anticipates only sign-in ("light up after the user installs / logs in"). But "ready" now depends on auth, and reader windows are long-lived, so a token expiry or `claude logout` after the first success leaves the cache pinned to `.installed`; `recheckAvailability()` returns the stale value, the Recheck button does nothing, and the next turn fails with a raw error instead of the setup guidance.
- **Fix:** cache only the expensive, stable part (resolved path + `--version`); always run the auth probe in `isAvailable()` and recompute, so sign-*out* is detected too. (Alternative: cache with a short TTL.)
- **Files:** `ClaudeCodeProvider.swift`, `CodexProvider.swift`.

**#3 Piped stderr can hang the version probe → "CLI wasn't found" on a working install.**
`runCommand` now pipes stderr and waits for **both** stdout and stderr EOF via the DispatchGroup (`SpawnedAgentProcess.swift:377–396`). A login-shell grandchild that inherits stderr never closes it, forcing the 5s timeout; `run()` then returns `nil` (timedOut) and discards the valid path already in stdout. The `run()` doc (`:345–349`) still says stderr goes to `/dev/null`.
- **Fix:** add `captureStderr: Bool` to `runCommand`. `run()` (version probe, stdout-only) passes `false` → `stderr = FileHandle.nullDevice`, no stderr reader in the group → a grandchild can't block it (restores pre-PR behavior; makes the doc true again). Auth probes pass `true` (they need stderr) with the 5s timeout as backstop.
- **Files:** `SpawnedAgentProcess.swift` (:368–413; `run()` :350).

**#4 Selection→Ask silently overwrites the global "hide assistant" preference.**
`onAsk` calls `setChatSidebarVisible(true)` (`PDFReaderView.swift:682`, `WebReaderView.swift:1804`), and that helper persists `RubienPreferences.assistantSidebarVisible` (`PDFReaderView.swift:642–644`, `WebReaderView.swift:1768–1770`). A user who deliberately hid the assistant and clicks Ask once re-enables the panel for **all** future reader windows.
- **Fix:** reveal the panel for *this* window without persisting the default — add `persist: Bool = true` to `setChatSidebarVisible` (or a `revealChatSidebarForAsk()` that only sets `showChatSidebar = true`); `onAsk` calls it with `persist: false`. The toolbar toggle keeps persisting.
- **Files:** `PDFReaderView.swift`, `WebReaderView.swift`.

### P2 — lower severity

**#6 Settings hides the resolved path for the installed-but-unauthenticated state.**
`RubienSettingsView.swift:440` shows the path only `if availability.isReady`; the new `.installedButUnauthenticated` state carries a `resolvedPath` but shows "not signed in" with no path — hiding which of several installs Rubien resolved.
- **Fix:** show the path whenever `resolvedPath != nil`, and show the reason below when `!isReady` (both together for the unauth state).
- **Files:** `RubienSettingsView.swift` (:438–451).

**#7 Removed Codex privacy disclosure.**
`f7c6bd0` deleted the Codex CLI section footer (`RubienSettingsView.swift:393–404`), the only place the app disclosed that Codex uses the real `~/.codex` account + any MCP servers configured there, and stores sessions outside Rubien.
- **Fix:** re-add a `footer:` to `assistantCodexCLISection` with the disclosure (recover exact copy from `git show HEAD~2:Sources/Rubien/Views/RubienSettingsView.swift`).
- **Files:** `RubienSettingsView.swift`.

**#5 / #13 Web reader minimum window width raised to 972 pt unconditionally.**
`WebReaderMetrics.minimumWindowWidth = 972` (`WebReaderView.swift:33` — worst case: content 320 + notes 260 + chat 380 + inset 12) is used as the NSWindow `minSize` (`ReaderWindowManager.swift:105`, `WebReaderView.swift:1684`). It removes the previously-allowed 900–971 pt sizes even when both panels are hidden (content-only floor is 540), and on a display ≤ ~1072 pt the `preferredWindowSize` clamp (`ReaderWindowManager.swift:251`) is overridden by `minSize`, so the window opens past the screen edge (#13).
- **Fix:** set the window `minSize` to the content-only floor (both panels hidden) and rely on the existing dynamic `.frame(minWidth: contentMinimumWidth(chatVisible:))` (`WebReaderView.swift:1669`) to enforce larger widths when panels are shown. (Alternative: update `NSWindow.minSize` live on panel toggle.)
- **Files:** `WebReaderView.swift` (`WebReaderMetrics`), `ReaderWindowManager.swift`.

### P3 — defensive / test-only

**#8 codex auth parser is fail-closed before the authenticated branch.**
`codexStatus` checks negative phrases first over `combinedOutput` (`SpawnedAgentProcess.swift:439–443`) with no exit-code condition. The real signed-in output classifies correctly today; the risk is a future wording where a negative phrase co-occurs with a signed-in state.
- **Fix (defensive):** do **NOT** simply reorder the authenticated branch ahead of the negatives — Codex caught that `"not logged in"` *contains* `"logged in"`, so a naive positive-first check would misclassify a signed-out CLI as authenticated. Keep negatives-first; tighten the positive match to a specific token (e.g. `"logged in using"`, which matches the real `Logged in using ChatGPT`) plus `exitCode == 0`; default ambiguous to `.unknown` (fail-open, matching `claudeStatus`).
- **Files:** `SpawnedAgentProcess.swift`.

**#12 Signed-out CLI phrasing not empirically confirmed.**
Signed-in argv + parsing verified live; signed-out output (`loggedIn:false` for claude, "Not logged in" for codex) is inferred. Cover with fixtures rather than another live check.
- **Fix:** add signed-out fixtures in the provider tests (folds into commit 2).

**#9 Test shell-quoting fragility (test-only).**
`makeCodexAuthProbeCLI` interpolates `authOutput` into a single-quoted `/bin/sh printf` with no escaping (`CodexProviderTests.swift:720`); a fixture containing `'` breaks the generated script.
- **Fix:** escape `'` → `'\''` before interpolation, or write `authOutput` to a sibling file the script `cat`s.
- **Files:** `Tests/RubienTests/CodexProviderTests.swift`.

## Proposed commit sequence

Each commit builds + passes tests on its own (CLAUDE.md: one coherent step).

1. **Availability gating & probe race (P0)** — #10 (chosen path) and #1 (probe-token guard + synchronous bump in `switchProvider`). `ChatSessionController.swift`, `ChatSidebarView.swift`. Tests: stale-probe-drop, switch race, and **rewrite the two f7c6bd0 tests** (`testCanSendWithCurrentAvailabilityRequiresReadyBackend`, `testSendDoesNotCallProviderWhileAvailabilityIsChecking`) to the chosen #10 behavior so they don't re-encode the block.
2. **Probe-layer correctness (P1/P3)** — #3 (`captureStderr`), #11 (re-probe auth / cache only resolution), #8 (parser ordering), #12 (signed-out fixtures). `SpawnedAgentProcess.swift`, `ClaudeCodeProvider.swift`, `CodexProvider.swift`, provider tests.
3. **Sidebar & reader UX (P1)** — #2 (setup+Recheck reachable after resume), #4 (Ask reveals without persisting). `ChatSidebarView.swift`, `PDFReaderView.swift`, `WebReaderView.swift`.
4. **Settings, window sizing & test hygiene (P2/P3)** — #6 (path for unauth), #7 (Codex footer), #5/#13 (window minSize), #9 (test escaping). `RubienSettingsView.swift`, `WebReaderView.swift`, `ReaderWindowManager.swift`, `CodexProviderTests.swift`.

## Testing

- App-target changes → `RubienTests` (every file `#if os(macOS)`-guarded). Run filtered: `swift test --filter RubienTests` (full `swift test` hangs on `RubienCLITests`; needs full Xcode toolchain). No WKWebView tests in-suite (they deadlock) — test controller/metrics logic, not the WebView.
- Provider probe logic → prefer pure `CommandResult` → `AgentAuthStatus` unit tests + the fake-CLI fixtures already in `CodexProviderTests`.
- `WebReaderMetrics` / `ReaderWindowMetrics.preferredWindowSize` are pure — unit-test the width math directly.

## Per-commit review cadence

Per CLAUDE.md: codex-rescue + `/simplify` on each commit's diff before committing. Run reviews on **Opus (medium) / codex gpt-5.5**, not a Fable dynamic workflow (see [[feedback_subagent_model]]).

## Codex review (2026-07-08)

Reviewed by Codex (gpt-5.5, medium). Verdict: all 13 diagnoses correct; 4 refinements folded in above — (#1) bump the probe token synchronously in `switchProvider`, not just in the scheduled task; (#8) don't reorder the auth branches because `"not logged in"` contains `"logged in"`; (#10) drop construction-time probing to avoid a double probe, and note the block is author-intended and tested; (sequencing) commit 1 must rewrite the two f7c6bd0 availability tests. No new defects found beyond the 13.

## Open decisions (recommendations inline)

- **#10 approach — needs the author's call.** The block-while-checking is *intentional and tested* (`f7c6bd0`). Pick: **(A) optimistic-`nil`** — composer always usable, a doomed send during the brief unknown window degrades to a notice (Codex's recommendation; reverses the author's tests); or **(B) keep the block, make it fast** — shared cross-window "ready" cache so windows 2+ resolve instantly, preserving "never send to an unknown backend" (honors the author's intent; first window still waits, and the shared cache must re-probe auth per #11).
- **#5 sizing** — *Recommend* lower the static window `minSize` to the content-only floor and keep dynamic content-frame mins. Alternative: update `NSWindow.minSize` live on panel toggle (more moving parts).
- **Scope/sequencing** — *Recommend* land commits 1–3 (P0/P1) first; commit 4 (P2/P3) can follow or be deferred.
