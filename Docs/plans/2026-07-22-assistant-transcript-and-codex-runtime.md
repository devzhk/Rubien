# Assistant Transcripts and Codex Runtime Broker — Implementation Plan

**Date:** 2026-07-22
**Design:** [Rubien-owned Assistant transcripts and Codex runtime broker](../specs/2026-07-21-assistant-transcript-and-codex-runtime-design.md)
**Branch/worktree:** `codex/assistant-transcript-broker` / `/private/tmp/Rubien-assistant-transcript-broker`
**Baseline:** `97995d8`
**Status:** Implementation complete in isolated worktree; UI validation and integration pending

## Contract

Make Rubien's local database the presentation source for Home, reader, and
scheduled Assistant transcripts while preserving provider-native continuation.
Remove normal History/model reads from the user-critical turn path. Give Codex
one app-owned admission and process-lifecycle boundary whose transport policy is
selected only after the required compatibility spike.

Safety boundaries:

- never edit shipped migrations `v1...v9`; add the local-only transcript schema
  in `v10`;
- transcript tables and attachment files remain local-only and never enter
  CloudKit or MCP;
- every scheduled result is incrementally durable and terminal run/turn state is
  atomic;
- deletion, import, continuation, and recovery are deterministic across crashes
  and concurrent processes;
- retain the July 21 abandoned-history preemption fix until the broker replacement
  has equivalent regression coverage;
- preserve Linux compilation for `RubienCore`, the CLI, and the portable
  Assistant subset.

## Phase A — data foundation

Files:

- `Sources/RubienCore/Database/AppDatabase.swift`
- `Sources/RubienCore/Models/AssistantConversation.swift` (new)
- `Sources/RubienCore/Database/AssistantConversationDatabase.swift` (new)
- `Sources/RubienCore/Models/ScheduledJob.swift`
- `Sources/RubienCore/Database/ScheduledJobDatabase.swift`
- `Sources/RubienCLI/RubienCLI.swift`
- `Docs/CLI-Reference.md`
- migration/core/CLI/sync-invariant tests

Implement:

1. Add immutable `v10`: conversations, turns, transcript entries, normalized
   attachments, revisioned alias tombstones, external-content FTS5 plus database
   synchronization triggers, scheduled-run transcript lifecycle/status fields,
   constraints, indexes, and legacy-run classification.
2. Add unknown-safe storage enums, DTOs, GRDB records, normalized payload
   contracts, deterministic ordering, CRUD/search, alias claim/transfer, active
   delete protection, scheduled cascade/scrub semantics, and launch-recovery
   transaction APIs.
3. Add portable attachment path metadata and database APIs; filesystem adoption
   remains an app-layer Phase B responsibility.
4. Add `assistant-conversations list/get/delete/clear` and extend `jobs runs` JSON
   with transcript lifecycle/status. Update the CLI reference and preserve stable
   busy/error behavior for later execution-lock integration.
5. Verify fresh and v9→v10 migration, legacy classification, FTS cascade/direct
   SQL behavior, mixed payload versions, alias/import races, scheduled deletion,
   sync exclusion, CLI JSON, and Linux compilation.

Checkpoint: targeted migration/core/CLI tests, sync schema invariants, and
`swift build --target RubienCore` plus `swift build --target RubienCLI`.

## Phase B — durable capture and execution ownership

Files:

- new app-layer conversation service, recorder, attachment store, and execution
  lock files under `Sources/Rubien/Assistant/`
- `AgentProvider.swift`, Claude/Codex adapters, `ChatSessionController.swift`
- scheduled runner/coordinator and focused app tests

Implement:

1. Add the per-library OS execution lock before recovery or Assistant mutation;
   make non-owning app instances read-only and make CLI transcript/cascading job
   mutations return a stable busy error.
2. Add `AssistantAttemptIdentity`, normalized event envelopes with native item
   IDs, content/identity leases, and one recorder per conversation.
3. Capture user, assistant, tool, paper, notice, usage/model, and attachment
   presentation incrementally; keep late same-attempt session identity while
   rejecting stale visible content.
4. Add durable attachment copy/rename/reconciliation and bounded thumbnail
   regeneration.
5. Integrate scheduled runs: create/link before dispatch, persist live progress,
   atomically finish run/turn/transcript state, and recover every crash matrix.

Checkpoint: recorder/attachment/lock/recovery/scheduled tests, app build, and a
worktree-local scheduled live-progress smoke test.

## Phase C — local History, import, and continuation split

1. Switch Home/reader History, search, and transcript load to the local store;
   provider processes start only on send/resume.
2. Add explicit **Provider History…** using the real result-bearing protocol
   seams, local alias snapshot/CAS, revisioned tombstone behavior, and atomic
   import.
3. Implement `legacyEligible → legacyAttempted/legacyRetrying → available`,
   durable status codes, one-time automatic scheduled import, and explicit Retry.
4. Keep scheduled result conversations immutable. Drain identity ownership before
   transferring aliases/binding to one ordinary continuation child.
5. Retain the attribution JSON reader for compatibility while stopping new writes
   only after DB attribution parity is verified.

Checkpoint: zero-provider-call local History tests, importer race/failure tests,
scheduled continuation/deletion tests, and Home/reader UI smoke tests.

## Phase D entry checkpoint — Codex transport spike

Against Codex 0.142.5 and the current supported version, measure stdio versus a
Rubien-owned Unix listener with independent turn/metadata connections. Verify
initialize/notification routing, request close semantics, account/model reads,
posture isolation, resumed turns, forced app death, private socket cleanup, and
complete process-group disappearance.

If the listener is selected, first prove the out-of-group watchdog, gated
listener wrapper, durable identity record, child-lifecycle lock, stale-record
matrix, and exact PID/start-time/PGID checks. Do not adopt the separately managed
Codex daemon without a new ownership decision.

Checkpoint: publish the spike evidence in the design and freeze only the
transport-specific policy before broker implementation.

## Phase D — Codex broker

1. Port the complete `CodexProviderTests` behavior suite to a fake transport.
2. Extract the app-lifetime broker, scheduler, process gate, transport, turn
   adapter, and metadata adapter without changing the Phase B attempt identity.
3. Implement explicit state/event transitions, interactive/scheduled/metadata
   admission, claimed-run fairness, metadata preemption, configuration restart,
   account/model caching, and stale-generation rejection.
4. Confirm process-group disappearance rather than leader exit; fail closed on
   ambiguous ownership or reap failure.
5. Route every production Codex probe/client through the composition root and
   remove method-specific abandoned-request flags only after parity passes.

Checkpoint: exhaustive fake-server state-machine tests, compatibility fixtures,
full app tests, and the original July 21 regression.

## Phase E — cleanup and delivery

1. Remove obsolete in-memory-only scheduled transcript ownership and dead
   provider-History plumbing after replacement coverage proves parity.
2. Update superseded specs and operational documentation without rewriting their
   historical decisions.
3. Run targeted tests after every checkpoint, then full `swift test`, app/CLI
   builds, Linux-compatible tests, sync invariants, and worktree-local UI smoke
   tests.
4. Run the required independent uncommitted-diff review and three simplify
   reviews (reuse, quality, efficiency); apply justified findings and re-run all
   verification.
5. Commit coherent buildable phases separately and leave release preparation for
   an explicit follow-up approval.
