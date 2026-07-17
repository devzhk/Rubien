# Scheduled Assistant Jobs — Design Spec

**Date:** 2026-07-16
**Status:** Implemented on `codex/scheduled-jobs-design`; pending merge
**Scope:** User-created, recurring, read-only Assistant jobs in Agent Home

## 1. Recommendation

Rubien should add scheduled jobs, but the first release should be a focused
**scheduled research** feature rather than a general automation or cron system.
The strongest initial use case is the one that motivated the feature:

> Every morning, find papers released in the last 24 hours that are relevant to
> my library.

This is a good fit for Rubien because the Assistant can combine two things that
ordinary alerts cannot: the user's existing library context and current web
research. It also turns Agent Home from a purely reactive chat surface into a
place that can bring useful work back to the user.

The feature is worth building if v1 is honest about three boundaries:

1. **Best-effort timing.** Rubien runs due jobs while the app is running and
   coalesces missed occurrences into one catch-up run on launch or wake. It does
   not promise to wake the Mac or launch an explicitly quit app at an exact time.
2. **Read-only execution.** A scheduled run may search the web and read the
   Rubien library, but it cannot add, edit, or delete library data without a
   person present.
3. **Local execution.** A job belongs to this Mac in v1. Syncing schedules before
   there is a cross-device execution lease would cause duplicate runs.

These boundaries preserve the product value while avoiding a background helper,
unattended approval prompts, and multi-device coordination in the first release.

## 2. Product decisions proposed for approval

| ID | Decision | Rationale |
|---|---|---|
| D1 | Add **Scheduled** beside **History** in the Agent Home header, using the `alarm` SF Symbol and an icon-plus-label button. | It matches the existing Home header hierarchy and makes the feature discoverable without adding a new sidebar destination. |
| D2 | Clicking **Scheduled** opens a management popover with **Recent Runs** and **Scheduled Jobs** tabs, defaulting to Recent Runs; **New job** opens a sheet. | Home already previews upcoming jobs, so the popover should lead with completed and failed work. Prompt and recurrence editing need more room and validation than a popover row provides. |
| D3 | A fresh Agent Home shows at most three enabled jobs under **Upcoming**, above the existing suggestions. | This makes scheduled work visible without turning Home into a dashboard. |
| D4 | When at least one upcoming job exists, show both **Upcoming** and **Suggestions** section labels. When none exists, keep today's unlabeled three-suggestion layout. | The extra labels are useful only when two groups need to be distinguished; this avoids visual churn for users with no jobs. |
| D5 | v1 recurrence is “selected weekdays at a local time.” | It covers daily, weekdays-only, weekly, and several-times-a-week schedules without exposing cron syntax or a brittle natural-language parser. |
| D6 | Every run starts a fresh provider conversation. Rubien stores job definitions and run metadata, but the provider continues to own the transcript. | Results remain openable through the current History/resume path without creating a second transcript store. |
| D7 | Scheduled execution is always isolated and read-only: Rubien MCP read tools only, user tools off, Codex read-only sandbox, and unattended approval requests denied. | An unattended process must not mutate the library or gain ambient plugin/tool authority. |
| D8 | Jobs and run ledgers are local to this Mac in v1 and do not sync through CloudKit. | Provider installation/authentication is device-local, and syncing definitions without a distributed lease would run the same job on multiple Macs. |
| D9 | Due runs are serialized, only the next runnable occurrence is claimed, and missed occurrences are coalesced into one catch-up run. | This bounds resource usage, avoids stranded durable queues, and prevents a laptop opened after a week from launching seven near-identical searches. |
| D10 | Notifications are opt-in and requested in context after the first job is enabled. | Creating a schedule is the moment notification permission has an understandable purpose. |

## 3. Goals

- Let a user create, edit, enable, disable, run, and delete a recurring research
  job without leaving Agent Home.
- Make the next three scheduled occurrences glanceable from the fresh Home state.
- Run a due job safely without requiring the Assistant UI to be open.
- Let the user open a completed run as a normal Home conversation.
- Preserve the existing provider-owned History architecture: no Rubien transcript
  database and no duplicate rendering stack.
- Make recurrence and catch-up behavior deterministic across sleep, wake,
  daylight-saving transitions, clock changes, and relaunch.
- Keep scheduled jobs from silently changing the library or invoking the user's
  unrelated provider apps, plugins, or MCP servers.
- Surface provider availability, failure, and missed-run states clearly.

## 4. Non-goals for v1

- A generic cron editor, arbitrary intervals, calendar dates, or natural-language
  schedule parsing.
- System wake, guaranteed wall-clock execution, or launching Rubien after the user
  explicitly quits it.
- A login item, privileged helper, LaunchAgent, XPC service, or cloud execution
  service.
- Mutating Rubien data, importing recommended papers, downloading PDFs, sending
  messages, or taking actions in connected apps.
- Syncing jobs or run state across Macs.
- Running more than one scheduled job at a time.
- Chained workflows, conditional branches, variables, attachments, or jobs that
  resume prior job runs.
- Scheduling the current conversation or asking the agent to create schedules in
  natural language. v1 creation is an explicit native form.
- Persisting Assistant answers, streaming deltas, tool outputs, or a result
  preview in Rubien.
- Linux background execution. The cross-platform CLI may manage definitions, but
  the macOS app owns scheduling and provider execution.

## 5. User experience

### 5.1 Agent Home header

The current Home header ends with labeled **New** and **History** controls in
`ChatSurfaceView.header`. Add **Scheduled** immediately after **History**:

```text
                                      New   History   Scheduled
                                                        ⏰
```

Use the same `labeledHeaderButton` styling and a stable macOS 14.4-compatible SF
Symbol (`alarm`). A small accent dot may appear when one or more completed runs
are unread. Do not put a numeric count in the resting toolbar unless visual QA
shows the dot is too ambiguous.

The control exists only on Agent Home. Reader-scoped Assistant sidebars keep
their current New/History controls because scheduled jobs are library-wide.

### 5.2 Scheduled jobs popover

The popover uses a two-tab switch and opens on **Recent Runs** every time. Home's
Upcoming preview already covers the next few occurrences, while Recent Runs is
where the user discovers completed or failed unattended work. **New job** stays
visible in the popover header from either tab.

```text
Scheduled                                   + New job
                 Recent Runs | Scheduled Jobs
──────────────────────────────────────────────────────
Daily paper scan                 Completed  Today 8:07
Weekly reading review               Failed  Fri 4:02
```

Behavior:

- **Recent Runs** is the default tab and sorts runs newest first. It includes
  running, succeeded, failed, and cancelled runs with job name, status, provider,
  and time.
- Recent rows show metadata only. Activating a successful run switches Home to
  the run's provider and resumes its provider-owned conversation. A failed row
  exposes its content-free failure explanation and **Run now** action.
- **Scheduled Jobs** sorts enabled jobs by `nextRunAt`, followed by paused jobs
  sorted by name.
- Each scheduled row shows name, recurrence summary, provider, state, and next
  occurrence. Row activation opens the editor.
- The scheduled-row menu offers **Run now**, **Enable/Pause**, **Edit**, and
  **Delete**.
- A running job appears in Recent Runs and also shows progress on its Scheduled
  Jobs row with **Cancel run**. Disabling a job does not retroactively cancel an
  already-started occurrence.
- Delete is disabled for a pending or running occurrence; the user cancels it
  first so a cascading ledger deletion cannot race the runner's final update.
- If provider history is no longer available, keep the run metadata and explain
  that the conversation can no longer be opened.
- Destructive deletion requires confirmation and removes the local job and its
  run ledger. It does not claim to erase provider-owned history.

The popover should use a practical width around 380–420 points. If the job count
or accessibility text makes the content tall, cap it and scroll the list.

### 5.3 Home upcoming preview

Insert the preview in `homeStartPage`, above the current three suggestions and
inside the same 700-point maximum width:

```text
Upcoming
  Tomorrow, 8:00 AM     Daily paper scan
  Friday, 4:00 PM       Weekly reading review

Suggestions
  What should I read next?
  Find recent papers in my field
  Summarize what we’ve been reading this week

┌─────────────────────────────────────────────────────┐
│ Ask your library…                                   │
└─────────────────────────────────────────────────────┘
```

Rules:

- Show only enabled jobs with a future `nextRunAt`, sorted earliest first.
- Show at most three. If more exist, the **Upcoming** heading is a button that
  opens the full Scheduled popover; do not add a fourth “more” row.
- A row shows a concise relative date/time and one-line job name. Its help text
  includes the full recurrence and prompt.
- Activating a row opens that job's editor; it does not run the job.
- A job that is currently due/running may replace its time with **Running now**.
- If no enabled jobs exist, omit the Upcoming section and retain the current
  unlabeled suggestions exactly.
- Upcoming is independent of the prompt/setup state: when jobs exist it appears
  above the normal suggestions, the empty-library actions, or the provider setup
  block. A job whose saved provider is unavailable remains visible with a
  **Needs setup** status rather than silently disappearing.
- The preview appears only in a fresh conversation. Once a user message commits
  or History is resumed, the normal transcript layout remains unchanged.
- The cluster remains scrollable at short heights; the added rows must not push
  the composer below the visible region.

### 5.4 New/edit job sheet

Fields:

1. **Name** — required, one line, suggested from the first prompt sentence.
2. **Prompt** — required, multiline. State that it is saved locally on this Mac.
3. **Repeat on** — seven weekday toggles; at least one is required.
4. **Time** — local wall-clock time.
5. **Provider / model / effort** — seeded from the current Assistant defaults and
   captured by the job so later global preference changes do not silently alter
   an unattended task.
6. **Web search** — explicit toggle, on by default.
7. **Notify when complete** — on by default when notification authorization is
   available; otherwise show the current system permission state.
8. **Enabled** — on by default.

The sheet also states that each run uses the selected provider account and may
consume that provider's subscription allowance or billed usage.

The footer shows a concrete summary such as:

> Next run: Tomorrow at 8:00 AM. If Rubien is not running then, this job runs once
> the next time Rubien opens.

Offer a starter template without making it a special job type:

```text
Name: Daily paper scan

Prompt: Find papers released in the last 24 hours that are most relevant to my
Rubien library. Return at most five, explain the relevance briefly, cite each
source URL, and do not add anything to my library.

Repeat: Every day at 8:00 AM
```

After save, **Run now** is available from the management row. It uses the saved
definition and creates a normal run ledger entry with `trigger = manual`.

### 5.5 Results and notifications

Rubien should not attempt to summarize an answer into a second UI. A completed
run is a normal provider conversation and uses the existing transcript renderer,
paper presentation tool, link validation, and History resume behavior.

On success:

- mark the run succeeded and unread;
- show an unread dot on **Scheduled**;
- optionally deliver “Daily paper scan completed” through
  `UNUserNotificationCenter`;
- notification activation navigates to Agent Home and resumes that run.

On failure:

- persist a typed, content-free failure category such as provider unavailable,
  authentication required, network unavailable, denied tool required, cancelled,
  or provider exited;
- show a useful user-facing explanation and **Run now** action in the popover;
- do not automatically retry a run after provider execution starts, because that
  may duplicate billed work;
- allow the next normal recurrence to proceed.

Opening a run marks it read and uses the existing History supersede behavior:
resuming the selected run cancels any in-flight Home turn, resets the pane, and
loads the provider-owned transcript. Do not introduce a second resume policy for
scheduled results.

## 6. Scheduling semantics

### 6.1 Recurrence model

A recurrence consists of:

- a nonempty weekday bit mask (Monday through Sunday);
- a local hour and minute;
- the user's autoupdating system calendar and time zone.

The schedule follows local time when the user travels. “8:00 AM” means 8:00 AM
where the Mac currently is, not 8:00 AM in the time zone where the job was
created. Past occurrences retain their absolute `scheduledFor` timestamps.

Use `Calendar.nextDate` with an explicit matching policy and test it rather than
adding fixed 24-hour intervals. Required behavior:

- a nonexistent spring-forward time runs at the next valid local time that day;
- a repeated fall-back time produces one occurrence, not two;
- changing the system time zone or clock recalculates every enabled job's next
  occurrence;
- one job runs at most once for a selected local calendar day, even if travel
  moves the clock backward across the scheduled time;
- editing or re-enabling a job calculates the first occurrence strictly after
  the edit time unless the user presses **Run now**.

### 6.2 Due and catch-up policy

The database's `nextRunAt` is the authoritative occurrence boundary. When and
only when the serialized runner is idle, a due scan claims the single earliest
occurrence in one transaction and returns its execution definition to memory.
Other due jobs remain unclaimed in `scheduledJob`; after the active run reaches a
terminal state, the coordinator scans and claims the next. There is no durable
queue of preclaimed `pending` rows.

If several occurrences were missed while Rubien was closed or the Mac slept:

1. create exactly one catch-up run, associated with the most recent missed
   occurrence;
2. record older occurrences as coalesced only in diagnostics, not as user-visible
   failed runs;
3. immediately advance `nextRunAt` to the next future occurrence;
4. serialize that run behind any already-running scheduled job.

Each claim has an `occurrenceKey`: the selected local calendar date for a
scheduled/catch-up run, or `manual/<run UUID>` for **Run now**. A uniqueness
constraint on `(jobId, occurrenceKey)` makes launch, activation, wake, clock
changes, and scheduler callbacks idempotent even when absolute offsets change.

Manual **Run now** never consumes or moves the next scheduled occurrence.

### 6.3 macOS execution contract

`NSBackgroundActivityScheduler` is suitable for deferrable periodic content
fetches and intentionally gives macOS flexibility around the nominal time. Use a
single one-shot activity aimed at the earliest `nextRunAt`, then reschedule after
each due scan rather than creating one scheduler object per job. See Apple's
[NSBackgroundActivityScheduler documentation](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler).

The coordinator also scans and reschedules on:

- app launch;
- `NSApplication.didBecomeActiveNotification`;
- `NSWorkspace.didWakeNotification`;
- system clock changes;
- system time-zone changes;
- job create/edit/enable/disable/delete.

The scheduler is a best-effort trigger, not a guarantee. v1 does not register a
login item or helper and does not claim to wake or launch an explicitly quit app.
The editor, job detail, and onboarding copy must all state the catch-up behavior.

Register the notification center delegate and action categories during app
launch, before any scheduled-job notification can be delivered. Ask for alert
authorization only after the user enables their first job; Apple recommends
requesting notification permission in context. See
[Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications).

## 7. Safety and authority

Scheduled execution has a stricter posture than interactive chat:

- use a fresh, dedicated `AgentProvider` instance per run;
- set `loadUserTools = false` regardless of the user's interactive default;
- use `CodexSandbox.readOnly`;
- launch Claude in an explicit approval-required permission mode (never
  `acceptEdits`, `bypassPermissions`, or `--dangerously-skip-permissions`) and
  retain its `--permission-prompt-tool stdio` control channel;
- extend `MCPContentChannel` with an access mode and launch
  `rubien-cli mcp --read-only` for scheduled runs;
- keep web access explicit in the saved job;
- automatically deny any provider approval request instead of leaving an
  invisible approval card waiting forever;
- prompt the model to return findings in its final response and not mutate the
  library;
- never attach files or resume a previous scheduled run;
- use the existing minimal environment and the exact live
  `RUBIEN_LIBRARY_ROOT`.

The read-only MCP catalog is the enforcement boundary for library writes; prompt
text is defense in depth. Provider shell tools may still request approval. Since
there is no person present, the runner denies them and records a typed failure if
the job cannot complete with allowed reads and web search.

The runner serializes scheduled jobs. An interactive Assistant conversation may
continue concurrently because it owns a separate provider process and the GRDB
library supports concurrent reads. If resource contention becomes visible in
testing, a later setting may defer scheduled work while an interactive turn is
active; v1 should not invent a global conversation lock without evidence.

## 8. Persistence

Add an immutable `v8` migration in `AppDatabase.swift`; update
`currentSchemaVersion` and the literal assertion in `MigrationV6Tests`. Both
tables are local-only: omit them from the `syncedTables` inclusion list, CloudKit
mappings, and dirty-tracking triggers.

### 8.1 `scheduledJob`

| Column | Type | Notes |
|---|---|---|
| `id` | text PK | Lowercase UUID; stable job identity. |
| `name` | text not null | Trimmed, nonempty, length bounded. |
| `prompt` | text not null | Saved locally; trimmed, nonempty, length bounded. |
| `weekdayMask` | integer not null | Seven validated bits, Monday = bit 0. |
| `localMinuteOfDay` | integer not null | `0...1439`. |
| `isEnabled` | boolean not null | Defaults true. |
| `provider` | text not null | Forward-compatible decode with a safe unavailable state. |
| `model` | text nullable | Captured provider override. |
| `effort` | text nullable | Captured provider override. |
| `webAccess` | boolean not null | Defaults true. |
| `notifyOnCompletion` | boolean not null | Defaults true. |
| `nextRunAt` | datetime nullable | Nil only while paused/invalid; indexed. |
| `createdAt` | datetime not null | UTC instant. |
| `dateModified` | datetime not null | Stamped by the Swift mutation layer. |

Do not persist `loadUserTools`, approval mode, MCP mode, or sandbox as editable
fields. Scheduled jobs always use the fixed safe posture in section 7.

### 8.2 `scheduledJobRun`

| Column | Type | Notes |
|---|---|---|
| `id` | text PK | Lowercase UUID. |
| `jobId` | text FK | Cascade on job deletion. |
| `trigger` | text not null | `scheduled`, `catchUp`, or `manual`; unknown values decode safely. |
| `occurrenceKey` | text not null | Local `YYYY-MM-DD` for scheduled/catch-up; `manual/<UUID>` for manual. |
| `scheduledFor` | datetime not null | Claimed occurrence; for manual runs, the request time. |
| `startedAt` | datetime nullable | Set immediately before provider start. |
| `finishedAt` | datetime nullable | Terminal timestamp. |
| `status` | text not null | `pending`, `running`, `succeeded`, `failed`, or `cancelled`. |
| `provider` | text not null | Snapshot used by this run. |
| `providerSessionId` | text nullable | Functional link to provider-owned History; no transcript content. |
| `failureKind` | text nullable | Typed, content-free diagnostic. |
| `isUnread` | boolean not null | Completion badge state. |

Indexes:

- unique `(jobId, occurrenceKey)` for all claims;
- `(status, scheduledFor)` for recovery;
- `(jobId, startedAt DESC)` for the management list.

`pending` is only the brief handoff between the claim transaction and provider
start; it never represents a job waiting behind another run. On launch, a stale
`pending` row becomes failed with `failureKind = interruptedBeforeStart`, while a
stale `running` row becomes failed with `failureKind = interrupted`. Both
occurrences remain consumed and visible; the system does not silently repeat
potentially billed work. The user may explicitly choose **Run now**.

### 8.3 Privacy boundary

This feature necessarily stores the user-authored job prompt because the prompt
is the automation definition. The prompt is stored locally but is sent to the
selected provider when the job runs. Rubien does **not** store generated answers,
deltas, tool inputs/results, citations, or previews. The provider continues to
own the conversation transcript exactly as it does today.

The provider session ID is retained only so a completed run can be opened. Job
deletion removes Rubien's link and metadata but does not claim to delete provider
history. The editor states that job definitions are local to this Mac.

## 9. Architecture

```text
ChatSurfaceView.header ── Scheduled ──> ScheduledJobsPopover ──> JobEditorSheet
        │                                      │
        └─ homeStartPage <── up to 3 ── ScheduledJobStore
                                                   │
AppDelegate / RubienApp lifecycle ──> ScheduledJobCoordinator
                                                   │ claim due occurrence
                                                   v
                                           ScheduledJobRunner
                                             │           │
                                  read-only MCP      AgentProvider
                                             │           │
                                             └──── run metadata
                                                      │
                                      attribution + notification
                                                      │
                                      Agent Home History/resume
```

### 9.1 `RubienCore`

Add Foundation/GRDB-only types:

- `ScheduledJob`
- `ScheduledJobRun`
- `ScheduledRecurrence`
- `ScheduledJobStore` operations on `AppDatabase`
- a pure `ScheduledRecurrenceCalculator`

The recurrence calculator accepts an injected `Calendar` and `now`; UI and
tests must not duplicate calendar math. Claiming, advancing, and inserting the
run ledger occur in one GRDB write transaction.

### 9.2 macOS app

Add:

- `ScheduledJobCoordinator`: lifecycle triggers, one-shot background activity,
  due scans, rescheduling, and observable snapshots for UI;
- `ScheduledJobRunner`: actor that serializes work, owns the provider for the
  active run, captures the latest session ID and terminal status, and supports
  cancellation;
- `ScheduledJobsPopover`, `ScheduledJobEditor`, and compact upcoming rows;
- `ScheduledJobNotificationController`: permission, delivery, and activation
  routing.

The coordinator should be a single app-lifetime object created beside
`SyncCoordinator` in `RubienApp` and injected into Home. Do not create a scheduler
per `ContentView`; `WindowGroup` may have multiple windows.

### 9.3 Provider integration

Do not drive the UI-oriented `ChatSessionController` headlessly. Extract or add a
small runner around the existing `AgentProvider` protocol that:

1. creates the requested provider through the production provider factory;
2. builds a fresh `AgentTurnRequest` with library context and safe scheduled mode;
3. records every `sessionStarted` ID in the run and
   `AssistantSessionAttributionStore` as `.library`;
4. ignores streaming UI events while retaining the provider-owned transcript;
5. denies `approvalRequested` events;
6. treats `turnCompleted` as success unless an earlier terminal provider error
   was recorded;
7. shuts the provider down on completion or cancellation.

Opening a successful run needs a new `ChatSessionController` entry point that
switches to the recorded provider when safe, then resumes the saved session ID.
It should share the existing generation, draft, transcript replay, and turn-gate
rules rather than synthesizing a transcript.

Scheduled runs do not increment Reading Activity's **AI sessions** metric. That
metric represents user-initiated Assistant engagement; automation volume is
already available from `scheduledJobRun` and may be summarized separately later.

## 10. CLI and sync contracts

Because scheduled jobs add new RubienCore entities and mutations, the CLI must
gain JSON-stable management commands in the same implementation:

- `rubien-cli jobs list`
- `rubien-cli jobs get <id>`
- `rubien-cli jobs create ...`
- `rubien-cli jobs update <id> ...`
- `rubien-cli jobs delete <id>`
- `rubien-cli jobs runs <id>`

These commands manage definitions and inspect run metadata; they do not execute
an Assistant provider. macOS app **Run now** remains the only v1 execution path.
Update `Docs/CLI-Reference.md` and `RubienCLITests` with the JSON contract.

The Jobs section must repeat the storage-root warning rather than relying only on
the document preamble: an unsigned/SPM `rubien-cli` resolves to Application
Support, not the signed app's App Group library, unless the user selects the
embedded helper or sets `RUBIEN_LIBRARY_ROOT`. Otherwise a created schedule can
silently exist in a library the app never opens.

No CloudKit record type, mapping, trigger, or sync command is added for these
tables in v1. If synced schedules are designed later, they require an explicit
execution target or a server-backed lease before enabling the same definition on
multiple devices.

## 11. Failure and edge behavior

| Condition | Behavior |
|---|---|
| Rubien is quit at the scheduled time | Run one catch-up occurrence next launch; calculate the next future time. |
| Mac is asleep | Scan on wake and apply the same catch-up rule. |
| Provider binary is missing or signed out | Fail before execution, show setup guidance, do not bill/retry automatically. |
| Bundled `rubien-cli` channel is missing | Fail preflight; do not run a “library relevance” job without its promised library context. |
| Network is unavailable | Fail visibly; the next recurrence remains scheduled. A manual retry is available. |
| A tool asks for approval | Deny it. Continue if the provider can recover; otherwise fail as `deniedToolRequired`. |
| Two callbacks claim the same occurrence | The unique transactional claim admits one run. |
| Several jobs are due | Claim the earliest by `scheduledFor`, then stable job ID. Leave the rest unclaimed; scan again after the active run terminates. |
| Job is edited while waiting behind another run | It is still unclaimed, so its eventual claim uses the latest saved definition. |
| Job is disabled while running | Current run continues unless explicitly cancelled; no future occurrence is scheduled. |
| User tries to delete a pending/running job | Require cancellation and a terminal ledger state before deletion. |
| App terminates during a run | Mark interrupted on next launch; do not auto-repeat it. |
| Provider History was pruned | Keep completion metadata, disable Open Result, explain the limitation. |
| Time zone or clock changes | Recompute future occurrences; never duplicate an already-claimed occurrence. |
| Notification permission is denied | Runs still execute; status and unread indicator remain in-app. |

## 12. Accessibility and localization

- Section labels, recurrence summaries, relative dates, statuses, and notification
  text are localized; do not build recurrence sentences by concatenating English
  fragments.
- Every job row has one coherent VoiceOver label including name, state, next run,
  recurrence, and provider.
- Weekday controls support keyboard navigation and expose selected state.
- Upcoming rows precede suggestions and the composer in visual, keyboard, and
  VoiceOver order.
- Status is never conveyed by color or the unread dot alone.
- Long job names and large accessibility text wrap or truncate predictably; prompt
  content is available in the editor and help text, not forced into compact rows.
- Reduce Motion disables list insertion and running-state animations.

## 13. Verification strategy

### 13.1 Pure/core tests

- daily and selected-weekday next-date calculation;
- before, exactly at, and after the scheduled minute;
- spring-forward nonexistent time and fall-back repeated time;
- time-zone travel, clock changes, month/year boundaries, and leap day;
- at-most-once local-day identity across fall-back and westward travel;
- missed-occurrence coalescing and manual-run noninterference;
- transactional duplicate-claim race;
- create/edit/enable/disable/delete validation;
- stale-running recovery and forward-compatible enum decoding;
- fresh install and v7 → v8 migration.

### 13.2 Runner tests

- fresh provider request uses library seed, read-only sandbox, web setting, no
  user tools, no attachments, and read-only MCP config;
- scheduled provider session IDs are recorded and attributed to Home;
- approvals are denied and cannot wait indefinitely;
- Claude scheduled argv pins approval-required mode and excludes every permission
  bypass; Codex remains read-only;
- success, provider exit, cancellation, availability failure, and interruption;
- multiple due jobs execute serially;
- no generated answer or tool content is written to Rubien tables.

### 13.3 UI tests and visual QA

- header order and macOS 14.4 symbol availability;
- zero, one, three, and more-than-three upcoming jobs;
- paused/running/failed/unread states;
- fresh Home versus docked transcript behavior;
- popover → editor → save → updated Home preview;
- Run now, cancel, delete confirmation, and missing provider history;
- notification permission and activation routing;
- notification activation targets the frontmost Rubien main window, or opens a
  new main window when none exists, then selects Home and resumes the run;
- short window, 900-point minimum width, Activity panel shown/hidden, light/dark,
  high contrast, large text, keyboard, VoiceOver, and Reduce Motion.

### 13.4 CLI contracts

- stable JSON for list/get/create/update/delete/runs;
- validation failures return the established JSON error shape;
- explicit `RUBIEN_LIBRARY_ROOT` targets the app's live library in integration
  tests;
- Linux compiles and manages definitions without attempting app execution.

## 14. Implementation phases

Each phase should build and pass its targeted tests before the next starts.

1. **Core model and recurrence** — v8 migration, models, recurrence calculator,
   transactional claiming, CRUD, recovery, and tests.
2. **CLI parity** — management commands, JSON contract tests, and CLI reference.
3. **Headless safe runner** — read-only MCP mode, provider factory integration,
   run ledger, attribution, cancellation, and fake-provider tests.
4. **Coordinator** — app-lifetime ownership, lifecycle scans, one-shot background
   activity, serialization, and deterministic scheduler tests.
5. **Management UI** — Scheduled header control, popover, editor, and recent runs.
6. **Home preview and result routing** — Upcoming section, provider-aware resume,
   unread state, and layout/accessibility verification.
7. **Notifications and hardening** — contextual permission, activation routing,
   sleep/time-change cases, full build/test, independent review, simplify sweep,
   and manual signed-app verification.

## 15. Acceptance criteria

- A user can create an enabled “every day at 8:00 AM” job from Agent Home and see
  its next occurrence immediately in both Scheduled and Upcoming.
- Opening Scheduled defaults to Recent Runs, while the Scheduled Jobs tab exposes
  enabled and paused definitions; New Job remains reachable from either tab.
- Home shows at most three upcoming jobs above suggestions only for a fresh
  conversation, without clipping the composer at supported window sizes.
- One due occurrence creates at most one run despite concurrent launch,
  activation, wake, and scheduler callbacks.
- Only the active occurrence is claimed; later due jobs remain recoverable and a
  stale transient pending claim becomes visibly interrupted on relaunch.
- If three occurrences were missed, Rubien runs once on next launch and schedules
  the next future occurrence.
- A scheduled run can search the web and read the live Rubien library but cannot
  advertise or invoke Rubien write tools, ambient user tools, or a writable Codex
  sandbox.
- An approval request cannot wait for hidden UI; it is denied deterministically.
- Only one scheduled run executes at a time.
- Success/failure/cancellation and unread state survive relaunch.
- Opening a successful run resumes the provider-owned conversation in Agent Home;
  Rubien stores no generated answer or tool output.
- Notifications are optional, requested in context, and never required for job
  execution.
- Jobs do not sync or duplicate across Macs in v1, and the UI says **On this Mac**.
- CLI definitions and run metadata have documented, tested JSON contracts.
- Existing reader Assistant behavior, Home History, provider switching, Activity,
  and the current three suggestions remain unchanged for users with no jobs.

## 16. Later extensions, deliberately deferred

- **Run reliably when Rubien is closed:** opt-in login item or separately packaged
  helper, designed with signing, update, lifecycle, and provider-auth behavior.
- **Sync definitions:** CloudKit mapping plus a device target or distributed lease
  so one occurrence has one executor.
- **Write-capable jobs:** explicit per-job capabilities, dry-run/review queue, and
  bounded approvals; never a simple “Auto” toggle copied from interactive chat.
- **Schedule this conversation:** turn a reviewed prompt into a job while removing
  transient attachments and conversation-only context.
- **More recurrence types:** one-time dates, monthly rules, and intervals only
  after the weekday/time model proves too limiting.
- **Templates:** daily paper scan, weekly reading review, unread-library triage,
  and citation-integrity checks.

## 17. Questions for the product decision

The design recommends the first option in each pair:

1. Is **best-effort while open + catch up on launch** useful enough for v1, or is
   closed-app execution a launch requirement?
2. Should v1 remain strictly **read-only**, or must a paper-discovery job be able
   to place candidates into a review queue?
3. Should schedules be **local to this Mac**, or is cross-device sync important
   enough to justify an execution-leasing design now?
4. Is **selected weekdays + local time** sufficient, or does v1 need one-off and
   interval schedules?
5. Should successful runs appear in the existing **Home History** as proposed, or
   should Scheduled have a completely separate result-reading surface?
