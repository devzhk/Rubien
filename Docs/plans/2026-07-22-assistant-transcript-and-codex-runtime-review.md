# Review — Assistant transcripts + Codex runtime implementation

**Date:** 2026-07-22
**Target:** uncommitted worktree changes on `codex/assistant-transcript-broker` (base `97995d8`, ~5k added lines)
**Design:** [2026-07-21 design spec](../specs/2026-07-21-assistant-transcript-and-codex-runtime-design.md) · [implementation plan](2026-07-22-assistant-transcript-and-codex-runtime.md)
**Method:** 3 correctness reviews (data layer / capture+runtime / UI+CLI+tests+docs) + 4 simplify reviews (reuse / simplification / efficiency / altitude), plus a direct pass over the v10 migration. Line numbers refer to this worktree's current files.

## Verdict

Strong foundation. The original review found the work **not committable yet**:
three code majors plus one apparent product decision blocked the commit. The
resolution update below supersedes that original gate.

**Build/tests:** `swift build` clean. Migration/core/sync-invariant tests 21/21; new CLI class green (incl. the busy-lock contract). App suite (844 tests): one failure in the first run whose name was lost to a clipped log, then green on two consecutive full re-runs — treat as an intermittent flake and watch CI.

## Resolution update

The follow-up implementation resolved the actionable commit blockers identified
above:

- **B1:** normal scheduled-run opens now always use Rubien's local transcript.
  Provider reads remain only behind explicit legacy-import states, covered by
  routing tests for every transcript state.
- **B2/B3:** a process-wide active-work registry now spans staging through
  provider completion. Clear/delete/reconcile maintenance refuses admission
  while work is live and reserves the same execution-ownership authority before
  mutating the database or filesystem.
- **B4:** this was stale review feedback. The existing job/run confirmation copy
  already discloses transcript and attachment deletion, and formatting tests
  assert both the cascade and provider-survivor wording.
- **E1:** streaming persistence now appends only the new text delta; the terminal
  event performs one authoritative full-row rewrite.
- **E2:** launch recovery and attachment reconciliation run in one joined
  detached preparation task, and first-send durable turn writes no longer block
  the main actor.
- **E3–E5:** live rendering now precedes recorder persistence (with a blocked-
  writer regression test), payload availability trusts the version boundary
  without eager JSON parsing, and FTS search materializes matching ranks once
  before grouping and joining conversations.
- **Q1:** filename, relative-path, containment, and symlink predicates now have
  one public implementation in `AssistantAttachmentFiles`.
- **Q2–Q8:** one conversation-capture factory owns lease/recorder/identity
  composition; Home and reader History share one popover; transcript/session SQL,
  unknown-safe enum coding, directory creation, stream forwarding, CLI mutation
  scaffolding, and transcript-state presentation capabilities each have one
  implementation; the two unused visibility helpers were removed.
- The finishing-identity deviation is also closed: terminal transcript capture
  enters `finishingIdentity`, renders read-only, and enables Continue only after
  the provider identity observer closes.

Post-fix validation: `swift build` is clean; the focused regression suite passes
60/60; the broader provider/runtime/history/scheduler/database/CLI suite passes
309/309; the full suite passes 2,155 tests with 9 skipped and 0 failures; and
`git diff --check` is clean.

## Original blockers (resolved)

- [x] **B1 — Deleted/unknown scheduled runs re-fetch the provider transcript on open.**
  `Sources/Rubien/Views/ContentView.swift:1687-1719` routes only `capturing/available/legacyRetrying` + legacy-import states; `deleted`, `unknown`, and post-schema `none` fall through to the retained pre-transcript `resumeScheduledResult` (`ChatSessionController.swift:2355`), which calls `provider.sessionTranscript` whenever `status == .succeeded` and a `providerSessionId` survives. Deleting a run's local conversation then reopening the row silently resurrects the provider copy — violating acceptance criterion 1, §9.3, and §7.1, and putting a provider RPC on a normal open path. No routing test covers this (the DB-level `admitScheduledAssistantImport` guard is tested but bypassed by this UI path).
- [x] **B2 — Settings "Clear Assistant Conversations…" interrupts live turns.**
  `Sources/Rubien/Views/RubienSettingsView.swift:525-526` calls `recoverInterruptedAssistantWork()` before clearing, and `AssistantExecutionOwnership.beginMaintenance()` does not check for active in-process work — a running scheduled run or a live turn in another window of the same process is marked `interrupted` and its conversation cleared mid-flight. The CLI `clear` path correctly omits recovery; mirror it and gate maintenance on no-active-work.
- [x] **B3 — Post-delete global attachment reconcile races in-flight staging.**
  `ScheduledJobCoordinator.swift:201` (`delete`) and `:238` (`deleteRun`) run the global `AssistantAttachmentFiles.reconcile` sweep synchronously on main, while `DurableAssistantAttachmentStore.prepare` stages bytes on a background actor **before** DB rows exist (`beginInteractiveAssistantTurn` inserts them afterward). The sweep can delete an in-flight `.pending` temp (→ spurious "could not save this Assistant turn") or a just-finalized file before its row lands (→ silent permanent attachment loss). The launch-time reconcile is safe only because it precedes all staging. Serialize post-delete reconciles through the store actor / execution-ownership authority.
- [x] **B4 — Product decision still missing: job deletion silently destroys transcripts.**
  `deleteScheduledJob` (`ScheduledJobDatabase.swift:99`) is unchanged; the v8 FK cascades job→runs and the new v10 FK cascades runs→conversations→turns/entries/attachments. Mechanically deliberate (files are eventually reaped by the reconcile sweep), but no confirmation copy anywhere warns "also deletes N saved run conversations". Decide explicitly: add the copy + a §18 test, or detach conversations on job delete. (Carried over from the spec review; run-level Delete is handled correctly per §7.1.)

## Spec deviations (minor, should be fixed or consciously waived)

- [x] Unpaginated transcript reads and unbounded previews vs §14/§7.7 — fixed
  with a 240-character normalized preview, bounded SQL source reads, and opaque
  keyset pagination (200 default / 500 maximum) across database, app, and CLI
  consumers. Home, reader, and scheduled-run views prepend older pages on demand
  while preserving the transcript viewport.
- [ ] Live `capturing` run view renders from the in-memory `ScheduledJobProgress`, with DB reads only for terminal `.available` (`ScheduledRunTranscriptView.renderSnapshot`) — user-facing guarantees hold, but §9.2/§13.2's "database observation within 500 ms" is literally met only for terminal transcripts.
- [x] §13.3 "Finishing session identity" state absent: the runner marks `.available` before `identityObserver.waitUntilClosed()`, so Continue can be offered during the identity-open window. Alias CAS makes this safe (rejects as `aliasConflict`), but the UX is an error where the spec wants a brief wait, and §18.2's "Continue disabled until identity closes" is untested.
- [ ] Provider History sheet lacks the §13.1 "slower / requires idle runtime" caveat; the busy condition only surfaces reactively.
- [ ] CLI busy error relies on `LocalizedError`→`localizedDescription` bridging to produce `"assistant-execution-busy"` for `AssistantCLIMutationError.busy` — map the type explicitly for cross-platform stability.

## Scope/process notes

- `CodexAppServerConnection` was **renamed** `CodexRuntimeBroker` and a real `CodexWorkScheduler` was extracted and wired (it *replaces* `queuedTurns`/`reservedTurn`; admission at `CodexProvider.swift:401`). Review found it behavior-preserving for the stdio policy, and the July 21 preemption fix is intact at all three sites (`:1639`, `:1854`, `:1889`). But this is Phase-D work landed ahead of the transport-spike gate, and the rename banks the spec's decomposed-broker name on the undecomposed monolith — keep the scheduler; revert or annotate the rename until the real Phase-D split.
- Nit: `beginMetadataWork` kills an in-flight availability probe before the admission check that may refuse the metadata work (`CodexProvider.swift:1868` vs `:1879`), forcing an unnecessary re-probe.
- Linux gating verified by inspection only (macOS builds can't prove it) — push the branch to Linux CI before merge.

## Efficiency findings (first two violate the spec's own §19 budget)

- [x] **E1 — Quadratic streaming write amplification.** Every 250 ms / 4 KiB flush rewrites the *entire* accumulated assistant body, not the delta (`AssistantConversationRecorder.swift:548-594`) — ≈5 MB of SQLite/WAL traffic for a 200 KB answer. Grow the flush threshold with body size (e.g. `max(4 KiB, body/8)`) or append to a chunk table and coalesce at completion.
- [x] **E2 — Synchronous main-actor SQLite on every send.** `beginInteractiveAssistantTurn` / `markAssistantTurnStarted` (`ChatSessionController.swift:841`, `:849`) block main under writer contention; first send after launch also runs recovery + full attachment-tree reconcile on main (`AssistantExecutionOwnership.swift:77-82`). Use the `Task.detached` pattern already used for reads (`:1491`, `:2148`); move prepare to launch.
- [x] **E3 — Delta rendering gated behind the recorder actor hop** (and its blocking flush) at `ChatSessionController.swift:~957-985` — perceptible stutter possible when a scheduled flush contends the writer. Decouple render from persist.
- [x] **E4 — Transcript open re-parses every tool/paper `payloadJSON`** even when `payloadVersion` already matches current (`AssistantConversation.swift:519-528`) — trust the version; parse lazily.
- [x] **E5 — FTS ranking re-evaluates MATCH once per result row** via a correlated ORDER BY subquery (`AssistantConversationDatabase.swift:181-212`) — compute a grouped rank CTE once and join.
- Minor: per-flush `lastActivityAt` update (`:1680-1697`, stamp at turn boundaries instead); fresh `JSONEncoder` per call in `ChatTranscriptJS.encodeArg` / `ChatPaperModels`; per-event `recorder → lease → recorder` actor hop (fold lease flags into the recorder if streaming CPU ever shows up).

## Quality / simplify findings (post-fix cleanup commit)

- [x] **Q1 — Path-security helper cluster** (three independent review angles converged): three divergent copies of `isContained` (`AssistantAttachmentFiles.swift:146` with `allowRoot`, `DurableAssistantAttachmentStore.swift:349` with `>`, `AssistantAttachmentStore.swift:638` with `>=`), three of `isSymbolicLink` (older one weaker), a new `safeFilename` (`DurableAssistantAttachmentStore.swift:315`) weaker than the existing `sanitizeBasename`/`truncateUTF8` (grapheme-count vs UTF-8-byte truncation), and the `<attachmentID>/<file>` validator written twice (`:325` vs `AssistantAttachmentFiles.swift:121`). Consolidate on public `AssistantAttachmentFiles` predicates. Concrete risk if drifted: the reconcile sweep deletes files `resolvedURL` still considers valid.
- [x] **Q2 — The spec's `AssistantConversationService` (§8.1) was never built**: the lease + recorder + identity-observer quartet (including the subtle `runtimeGeneration` re-stamping closure) is copy-pasted between `ChatSessionController.swift:791-893` and `ScheduledJobRunner.swift:143-178`, with no single chokepoint enforcing one lease per turn. Extract the factory/service.
- [x] **Q3 — History popovers duplicate ~150 lines** (`ChatSidebarView.swift:1964-2157` vs `:2162-2428`); this diff added the whole deletion flow (state, dialog, alert, `delete()`, reload, import sheet) to both copies, and `retryCurrentLoad` ≡ `reloadCurrentList` ×4. Unify into one popover with an optional scope.
- [x] **Q4 — Duplicated SQL bodies**: `fetchAssistantConversationDetail(scheduledJobRunID:)` copies ~45 lines from the id overload (`AssistantConversationDatabase.swift:89-145` vs `:40-87`); `recordAssistantSessionBinding` vs `recordScheduledAssistantSessionBinding` duplicate the alias-claim + monotonic-advance SQL (`:700-754` vs `:758-826`). Share private helpers.
- [x] **Q5 — Unknown-safe Codable boilerplate ×8 enums** (`AssistantConversation.swift`, `ScheduledJob.swift`) → one `RawStringCodable` protocol with default `init(from:)`/`encode(to:)`.
- [x] **Q6 — Dead code**: `AssistantTranscriptEntryKind.isVisible` (vacuously true, unreferenced) and `AssistantConversationOrigin.isVisibleInLocalHistory` (unused — the real filter is hard-coded in SQL at `:154-156`, a drift trap). Delete or make SQL use it.
- [x] **Q7 — Repetition**: `prepare`'s check→create→check triple ×4 (`DurableAssistantAttachmentStore.swift:63-133`) → one `createValidatedDirectory`; envelope-forwarding stream skeleton ×3 (`AgentProvider.swift:624-654`, `ClaudeCodeProvider.swift:60-85`, `CodexProvider.swift:102-135`) → one `forwardEnvelopes(from:transform:)`; CLI lock+reconcile+notify scaffold ×2 (`RubienCLI.swift:1728-1739`, `:1770-1780`) → `withAssistantCLIMutationLock { }`.
- [x] **Q8 — Transcript-state capabilities open-coded in three views** (`ContentView.swift:1662-1686`, `ScheduledRunTranscriptView.swift:347-432`, `AgentHomeView.swift:136-137`) → capability accessors on `AssistantTranscriptState` (precedent: `AssistantTranscriptStatusCode.isRetryable`).
- Longer-term (flag, don't rush): three implementations of event semantics must agree — live `handle`, recorder capture, and `StoredAssistantTranscriptProjection` each re-implement tool pairing / paper suppression / streaming accumulation. The durable simplification is driving live rendering off the recorder's projection.
- Trivial: 4th copy of the `Data→hex` one-liner (`AssistantSessionIdentity.swift:32`); inline `ISO8601DateFormatter()` in `AssistantExecutionLock.swift:92` (diagnostic-only, acceptable).

## Data-layer nits (latent, not currently reachable)

- Tombstoned alias (`conversationId IS NULL`) during live binding throws `.aliasConflict`, conflating "owned elsewhere" with "previously deleted" (`AssistantConversationDatabase.swift:719-722`, `:781-784`).
- `replaceAssistantAttachments` returns every prior path as obsolete (`:607-622`) — safe today only because the recorder always uses fresh attachment UUIDs.
- Read-time `contextKind` coercion to `.unclassified` (`AssistantConversation.swift:322-327`) would persist the coercion if a future code path does a full-row `update(db)` of a fetched conversation.

## Verified solid (no action; do not re-litigate)

Attempt identity rides every persisted event with stale-generation drops end-to-end; late-`.sessionStarted`-after-Stop still updates continuation binding and persists through the identity gate + monotonic CAS; crash recovery covers `queued`+`starting`+`running` from a pre-mutation CTE snapshot with the full scheduled matrix in one transaction; scheduled terminal run+turn+final-entry commit is atomic; FTS5 external-content sync survives one- and two-level FK cascade deletes (verified empirically, `recursive_triggers` OFF); transcript tables absent from `syncedTables`/`SyncEntityType` with no dirty triggers; unknown enum raw values decode to safe fallbacks everywhere; per-entry `payloadVersion`; usage keeps cache-creation tokens + total cost; v10 backfill is one-time classification only; `flock`-based execution lock is crash-safe and shared with the CLI (busy contract tested); all new `Tests/RubienTests` files are whole-file `#if os(macOS)`-gated; portable Assistant subset stays portable; CLI matches `Docs/CLI-Reference.md` exactly and existing JSON is only extended; superseded specs received notes without rewriting history; Home and both readers perform zero provider RPCs for History/search/resume.

## Recommended order

1. Fix B1–B3; decide and implement B4.
2. Apply E1–E2 (spec-budget violations) and preferably E3–E5 while in the files.
3. Consolidate Q1 (security-sensitive) and add the two missing routing tests (B1, B2 scenarios).
4. Re-run: filtered core/CLI/app suites + `codex-rescue` pass on the fix diff; push branch for Linux CI.
5. Land Q2–Q8 as a follow-up cleanup commit; keep the scheduler, revert/annotate the `CodexRuntimeBroker` rename.
6. Commit in coherent phases per the plan (data foundation / capture / History+import / runtime), not as one squash.
