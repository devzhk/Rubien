# Agent Home and Reading Activity — Implementation Plan

**Design:** `Docs/superpowers/specs/2026-07-15-agent-home-design.md`
**Branch/worktree:** `codex/agent-home` / `/private/tmp/Rubien-agent-home`
**Baseline:** `swift build` passes at `7e44b76`.
**Status:** All checkpoints and visual-QA refinements implemented and verified
2026-07-16.

The feature lands as buildable checkpoints. Activity capture and Home remain
unexposed until their data, privacy, and clear contracts are complete.

## A1 — Activity schema, models, queries, and static sync surface

1. Add Foundation/GRDB models in `RubienCore`:
   - `LocalDay`
   - `ReadingActivity`
   - `AssistantActivity`
   - `ActivityEpoch`
   - `ActivityPendingClear`
   - `ActivityQuarantinedRecord`
   - immutable activity snapshot/DTO types
2. Add immutable migration `v7` without modifying `v1...v6`:
   - three synced tables and indexes
   - two triggerless local-only coordination tables
   - explicit insert/update/delete sync triggers for the v7 synced tables
   - deterministic reading/Assistant epoch seeds
   - explicit dirty `syncState` rows for seeded epochs
3. Keep the shipped `syncedTables` list unchanged; extend only the current-schema
   sync enumeration/PK helpers used outside v1 migration.
4. Add Core query APIs for:
   - qualified paper-day aggregation and fixed intensity bands
   - tracked totals and current-week totals
   - current/longest streaks
   - bounded daily windows and current-generation recent papers
   - scope-explicit CLI/MCP DTO
5. Extend `SyncEntityType`, baseline enumeration, record mappings, and direct
   dispatch for all three synced activity entities.
6. Tests:
   - fresh and v6→v7 migration
   - local-only table and explicit-trigger invariants
   - record mapping/unknown provider round trips
   - threshold, calendar, streak, recent, deleted-paper, and DTO scope
   - representative 10,000-row query fixture

## A2 — Epoch-safe local capture and clear primitives

1. Add Core transaction APIs for:
   - reading component monotonic upsert
   - idempotent Assistant-start insert
   - reading/Assistant clear with stable `intentId`
   - same-intent pending-clear rebase and different-intent stale-write rejection
2. Add `ReadingActivityCoordinator` in the app:
   - one active key/visible reader at a time per window
   - app/window/sleep/day/time-zone pause boundaries
   - monotonic clock and one-minute/threshold/lifecycle flushes
   - flush-time epoch+intent comparison
3. Thread reader lifecycle signals from `ReaderWindowManager`, PDF Reader, and Web
   Reader without changing existing reader reuse.
4. Add Assistant activity recorder injection to `ChatSessionController`; count
   exactly once after admitted provider start and honor expected epoch/intent.
5. Add observable device-local capture controls and clear confirmations in
   Settings; preserve legacy Last Read/Read Count and History attribution.
6. Add equivalent shared CLI clear calls and cross-process notification.
7. Tests cover focus eligibility, minute/threshold boundaries, crash-loss bound,
   local-day rollover, concurrent CLI clear, same-intent rebase, distinct-intent
   discard, and Assistant once/epoch behavior.

## A3 — Reset and CloudKit sync state machines

1. Add epoch-before-fact ordering and save gating until the exact epoch is
   acknowledged.
2. Persist/replay unknown-epoch and missing-reference records through the local
   quarantine table.
3. Rebase pending clears transactionally:
   - preserve original reset boundary and stable intent
   - re-key reading facts and sync identities
   - retag Assistant facts while retaining UUID record IDs
   - preserve current epoch server system fields
4. Handle reference-orphan ordering:
   - child-before-parent across batches
   - known tombstoned parent
   - end-of-fetch permanent orphan
   - reference delete cleaning staged/quarantined children
5. Let the existing scheduler batch epoch/fact saves and old-fact tombstones; do
   not force a send per minute.
6. Tests cover concurrent clears, offline stale facts, relaunch, multi-batch
   initial pull exceeding batch size, and no unrelated batch wedge.

## A4 — CLI/MCP contracts and documentation

1. Add `rubien-cli stats [--year]` with the normative nested DTO.
2. Add confirmed `stats-clear --kind reading|assistant --yes`.
3. Add `rubien_reading_activity` to native and Node MCP implementations, policy,
   version/build gates, parity tests, and documentation.
4. Pin that only `yearActivity` changes with `--year`; tracked totals/current
   week/streaks/recents retain their documented scopes.
5. Update `Docs/CLI-Reference.md` and MCP README/tool counts.

## B — Shared Assistant context and native paper presentation

1. Replace the reader-only context contract with `AssistantConversationContext`
   (`library`, `reference`, `unclassifiedResume`) and a shared production session
   factory.
2. Hoist Home session, renderer, complete composer draft, turn outcome, and
   attention state above destination switching.
3. Add the local content-free attribution store and context-aware History scopes.
4. Add the app-private optional `rubien_present_papers` native catalog only when
   `RUBIEN_APP_PRESENTATION=1`.
5. Add bounded typed provider events with call ID + invocation ordinal; merge one
   per-turn group, stable-deduplicate, cap at ten, and reconstruct identically in
   Claude/Codex History.
6. Add `ChatPaperGroup` renderer items and validated JS→Swift activation bridges.
7. Extract one shared PDF→Web→Library reader-opening policy and use it for cards
   and recent papers.

## C — Main-window Home and Activity UI

1. Add stable Home/Library navigation state; Home is the v1 launch default and
   first Library reveal does not trip the seeded-default-view once guard.
2. Add the library-scoped shared chat surface.
3. Add centered empty composer + subordinate suggestions; commit transitions to
   bottom-docked composer before provider output.
4. Add hidden-turn progress/approval/unread/error attention indicators.
5. Add the top-pinned, content-height neutral glass Activity card:
   - metric grid and coverage labels
   - Month / rolling 13-week Quarter / Year heatmap
   - fixed Levels 1–5 and exact accessible daily detail
   - current-generation recent papers
   - compact overlay and height-constrained internal scrolling
6. Add empty/loading/offline/error states and accessibility/back-deployment QA.

## D — Visual-QA refinements incorporated after the core checkpoints

1. Use 14-point conversation/editor content and one shared 13-point size for
   secondary chat guidance, shortcuts, selectors, suggestions, and Home header
   actions.
2. Keep fresh and docked Home composers at the same 700-point maximum width and
   intrinsic height; apply the compact intrinsic height to reader composers and
   a 420-point reader Assistant minimum width.
3. Keep Home suggestions as a muted, caret-aligned vertical list above the fresh
   composer with neutral-gray hover feedback.
4. Render shared compact paper cards with title, truncated authors, year, and
   type/badge metadata; shrink-wrap them up to the transcript-bubble maximum and
   use neutral-gray hover feedback.
5. Use exact state-backed 225-point defaults for PDF and web left sidebars,
   persist width/visibility independently, clamp restored values, and migrate the
   unreliable legacy web split-view width once.

## Verification and delivery

After every checkpoint:

1. Run the narrowest affected tests.
2. Run `swift build` and the relevant test targets.
3. Inspect schema/CLI/MCP frozen contracts and the uncommitted diff.

Before delivery:

1. Run `swift test`.
2. Run an independent uncommitted-diff review and focused reuse/quality/efficiency
   sweep.
3. Re-run build/tests after accepted findings.
4. Perform a worktree-local `swift run Rubien` UI smoke test; use the signed dev
   launcher only for CloudKit-specific verification.
