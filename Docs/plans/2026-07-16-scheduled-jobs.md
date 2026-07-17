# Scheduled Assistant Jobs — Implementation Plan

**Date:** 2026-07-16
**Design:** [Scheduled Assistant Jobs](../specs/2026-07-16-scheduled-jobs-design.md)
**Branch:** `codex/scheduled-jobs-design`
**Status:** Implemented; automated verification and review completed in this branch. Interactive visual and VoiceOver smoke checks remain for pre-merge QA.

## Contract

Ship recurring, local-only, read-only Assistant jobs in Agent Home. The header
gains Scheduled; its popover defaults to Recent Runs and switches to Scheduled
Jobs. A fresh Home previews at most three upcoming jobs. Jobs run best-effort
while Rubien is alive and coalesce missed occurrences on launch/wake.

Safety boundaries:

- only one scheduled run at a time;
- claim one occurrence only when the runner is idle; never persist a queue of
  preclaimed jobs;
- Rubien MCP read-only catalog, user tools off, Codex read-only, Claude explicit
  approval-required mode, and every unattended approval denied;
- local tables in `library.sqlite`, omitted from CloudKit/dirty triggers;
- generated output remains in provider-owned History;
- scheduled runs do not count as user Assistant activity.

## Phase 1 — Core persistence and calendar semantics

Files:

- `Sources/RubienCore/Models/ScheduledJob.swift` (new)
- `Sources/RubienCore/Database/ScheduledJobDatabase.swift` (new)
- `Sources/RubienCore/Database/AppDatabase.swift`
- `Tests/RubienCoreTests/ScheduledJobTests.swift` (new)
- `Tests/RubienCoreTests/MigrationV8Tests.swift` (new)
- `Tests/RubienCoreTests/MigrationV6Tests.swift`

Implement:

1. Add immutable v8 tables/indexes for `scheduledJob` and `scheduledJobRun`.
2. Add forward-compatible enums/models and validation.
3. Add pure recurrence calculation using injected Calendar/now, including DST,
   weekday masks, catch-up, and local-day occurrence keys.
4. Add CRUD and observations.
5. Add transactional `claimNextDueJob(now:)` that runs only when the caller is
   idle, advances `nextRunAt`, inserts one pending row, and returns an in-memory
   execution snapshot.
6. Add terminal updates, unread state, recent runs, and stale pending/running
   recovery.

Checkpoint: targeted core tests and `swift build --target RubienCore`.

## Phase 2 — CLI parity

Files:

- `Sources/RubienCLI/RubienCLI.swift`
- `Tests/RubienCLITests/JobsCommandTests.swift` (new)
- `Docs/CLI-Reference.md`

Implement JSON-stable jobs list/get/create/update/delete/runs commands. Mutations
post the existing library-change notification. Repeat the signed-helper versus
SPM `RUBIEN_LIBRARY_ROOT` warning in the Jobs documentation. CLI never executes
providers.

Checkpoint: build `rubien-cli` and run scheduled-job CLI tests.

## Phase 3 — Provider safety and headless runner

Files:

- `Sources/Rubien/Assistant/AgentProvider.swift`
- `Sources/Rubien/Assistant/MCPContentChannel.swift`
- `Sources/Rubien/Assistant/ClaudeCodeProvider.swift`
- `Sources/Rubien/Assistant/CodexProvider.swift`
- `Sources/Rubien/Assistant/ScheduledJobRunner.swift` (new)
- provider/runner tests under `Tests/RubienTests/`

Implement a scheduled execution mode on `AgentTurnRequest`; use `mcp
--read-only`, fixed isolation, no attachments/resume, and a library scheduled-job
seed. The runner owns a fresh provider, records/attributes session IDs, denies all
approval events, updates typed run outcomes, supports cancellation, and shuts the
provider down. It does not record Assistant activity or generated content.

Checkpoint: provider argv/config tests, fake-provider runner tests, and
`swift build --target Rubien`.

## Phase 4 — App-lifetime coordinator and notifications

Files:

- `Sources/Rubien/Assistant/ScheduledJobCoordinator.swift` (new)
- `Sources/Rubien/RubienApp.swift`
- coordinator tests under `Tests/RubienTests/`

Create one coordinator beside SyncCoordinator, not per window. Observe launch,
activation, wake, clock/time-zone changes, and library writes. Schedule one
`NSBackgroundActivityScheduler` for the earliest next run, claim only while idle,
and rescan after every terminal outcome. Register notification routing at launch;
target the frontmost main window or open one, then hand off a run-resume route.

Checkpoint: deterministic coordinator tests and app build.

## Phase 5 — UI and result resume

Files:

- `Sources/Rubien/Views/ScheduledJobsView.swift` (new)
- `Sources/Rubien/Assistant/ChatSidebarView.swift`
- `Sources/Rubien/Views/AgentHomeView.swift`
- `Sources/Rubien/Views/ContentView.swift`
- `Sources/Rubien/Assistant/ChatSessionController.swift`
- UI/controller tests under `Tests/RubienTests/`

Implement:

1. Scheduled labeled header control with unread indicator.
2. Popover tabs: Recent Runs default, Scheduled Jobs secondary, New Job always.
3. Job editor with name/prompt/weekdays/time/provider/model/effort/web/notify.
4. Up to three Upcoming rows above every fresh-Home variant.
5. Run now, pause/enable, cancel, edit, delete, and recent-run failure states.
6. Provider-aware result resume using existing History supersede semantics.
7. Notification route consumption by the targeted ContentView.

Checkpoint: targeted UI/controller tests, app build, then manual light/dark,
compact-window, keyboard, and VoiceOver smoke checks.

## Phase 6 — Verification and delivery

1. Run targeted tests after every phase, then `swift test`.
2. Inspect the complete diff for schema immutability, CLI JSON stability, Linux
   guards, local-only sync behavior, and macOS 14.4 availability.
3. Run the required independent uncommitted-diff review.
4. Run three simplify reviews (reuse, quality, efficiency), decide findings, and
   apply only justified fixes.
5. Build and test again; report any manual verification that still requires a
   signed app or notification authorization.
