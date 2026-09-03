# Durable CloudKit Sync Intent Reconciliation

**Date:** 2026-09-02

**Status:** Proposed

**Incident:** Rubien 0.7.5 stopped uploading after its durable SQLite queue
contained both a save and a delete for the same `referenceTag`. The same
library also contained abandoned `pushInFlight` flags, one pre-global-identity
`referencePDF` queue key, and two references that were clean locally but absent
from CloudKit. Manual database repair restored both Macs to 271 references.

## 1. Decision

SQLite is the source of truth for what Rubien intends to save or delete.
`CKSyncEngine.State.pendingRecordZoneChanges` is a derived scheduling cache
that Rubien must be able to reconstruct and reconcile at any time.

For every `(entityType, entityId)`, the durable database must represent one
unambiguous operation state. An **active delete tombstone** means exactly
`confirmedByServer = 0 AND isPushEligible = 1`; a confirmed tombstone retained
for history is not pending delete intent.

| State | Live local entity | `syncState` | Tombstone |
|---|---:|---|---|
| pending save | yes | dirty | none |
| published clean | yes | clean, with server fields | none |
| pending delete | no | absent | active |
| retained deletion history | no | absent | confirmed |
| suspicious unpublished live row | yes | absent, or clean without server fields | none |

The first four states are valid. A dirty state plus any tombstone is a
contradiction to normalize. A suspicious unpublished live row is diagnosed but
not automatically uploaded because local inspection alone cannot prove the
server's history.

Rubien will enforce this invariant in four layers:

1. Mutation-time trigger and API enforcement.
2. Idempotent database repair before constructing `CKSyncEngine`.
3. Exact reconciliation of the engine's pending-change cache with SQLite.
4. A final batch-provider guard that can never submit both operations for one
   record or mark a clean state in flight.

No CloudKit record types or fields change. The repair preserves the engine
sidecar and its server change tokens; it does not reset the zone or perform an
automatic full-history replay.

## 2. Incident evidence and failure chain

The source Mac contained both:

```text
syncState: referenceTag 72c11106-4aa2-407b-9c63-e950ecdbc5a8/16, dirty=1
tombstone: referenceTag 72c11106-4aa2-407b-9c63-e950ecdbc5a8/16, eligible
```

CloudKit rejected the entire modify operation with `CKError.invalidArguments`:

```text
You can't save and delete the same record ... in a single operation
```

The rejected record was one tag assignment, but every other save and PDF asset
in that batch failed with it. The UI later returned to an apparently normal
sync state because send failures were logged but not retained in the public
sync status.

The observed failure chain is therefore:

1. A delete created a tombstone and removed `syncState`.
2. A later insert or update recreated dirty `syncState` but did not remove the
   tombstone.
3. `ingestPendingChanges()` independently appended every dirty save and every
   eligible delete to `CKSyncEngine`.
4. The batch provider accepted stale engine saves without checking that SQLite
   still considered them dirty.
5. CloudKit rejected the contradictory batch.
6. Failed saves remained in flight, while `.didSendChanges` allowed the UI to
   look idle and did not expose the error.

Two additional defects were visible during recovery:

- process-lifetime `pushInFlight` flags survived a relaunch even though no
  request from the old process could still be active; and
- a never-confirmed `referencePDF` state still used local reference ID `1810`
  after the v13 global-identity migration, although the canonical record name
  is the owning reference's `syncId`.

These are separate manifestations of the same architectural problem: durable
SQLite intent and the engine scheduling cache can drift, but startup does not
currently reconcile them.

## 3. Goals

- A local mutation cannot leave both save and delete intent for one record.
- Every launch safely repairs contradictions and abandoned in-flight state
  before CloudKit can schedule a send.
- The engine pending queue converges to the database without discarding fetch
  tokens or resetting CloudKit state.
- A corrupt or stale engine entry cannot make a clean record appear in flight.
- One malformed record cannot silently stall unrelated uploads indefinitely.
- Safe historical `referencePDF` local-ID keys repair automatically.
- Ambiguous cases are reported without guessing or destroying data.
- Diagnostics identify the invariant violation directly, without requiring
  ad hoc SQL.

## 4. Non-goals

- Do not edit the shipped v13 migration.
- Do not reset the source Mac's sync sidecar, CloudKit zone, or production
  library.
- Do not automatically republish every clean local record. A broad republish
  can resurrect intentional remote deletions and overwrite newer server data.
- Do not infer that a clean local record is missing from CloudKit during an
  ordinary incremental fetch. CloudKit does not provide a cheap, authoritative
  full-zone inventory through that path.
- Do not change CloudKit record schemas or the v13 global identity contract.

The two clean references that were absent from the other Mac had archived
server state and an old `lastPushedAt`, so even the new local diagnostics cannot
prove that they disappeared remotely. They are treated as historical fallout.
A separately confirmed “republish local library” recovery operation may be
designed later; it is not a safe automatic startup action.

## 5. Database invariant and v14 migration

Add a new immutable `v14` migration and set
`AppDatabase.currentSchemaVersion = "v14"`. Keep the global sync identity
version at 13: v14 repairs queue semantics, not record identity.

Register v14 inside the existing `includesV13Migration` conditional (or rename
that private flag to `includesPostV12Migrations` while preserving its behavior).
`makeV12DatabaseForTesting(on:)` must still stop after the real v12 migration;
an unconditional v14 would run syncId-based trigger SQL against a v12 schema
and break the migration fixture before v13 can be tested.

The registered migration closure must call a frozen
`AppDatabase.applyV14Body(_:)` and migration-private helpers only.
`applyV14Body` must never call `SyncStateStore.repairDurableIntent()` or another
runtime repair function: changing runtime policy later would otherwise silently
change v14 for fresh installations while already-migrated libraries remain
unchanged. Migration and runtime repair are separate implementations. They
share no mutable behavior or catalog dependency; a fixture matrix asserts that
their deliberately overlapping v14 rules agree today.

### 5.1 Replace mutation triggers

Recreate dirty-tracking triggers for every synchronized table. Insert and
update triggers must perform these operations in the same transaction:

1. Delete the exact `(entityType, entityId)` from `tombstone`.
2. Upsert `syncState` with `isDirty = 1` and `pushInFlight = 0`.

Delete triggers remain the inverse:

1. Upsert the tombstone.
2. Delete the exact `syncState` row.

The replacement must include the v13-triggered tables and the older activity
tables whose identities are not ordinary `syncId` columns:

- `reference`, `tag`, `referenceTag`;
- `pdfAnnotation`, `webAnnotation`;
- `metadataIntake`, `metadataEvidence`;
- `propertyDefinition`, `propertyValue`, `databaseView`;
- `readingActivity`, `assistantActivity`, `activityEpoch`.

`referencePDF` has no synced source table and remains managed by the PDF queue
drainer through the Swift mutation primitive in section 7.

Insert/update deliberately removes even a confirmed tombstone for the exact
identity. The retained tombstone normally prevents a delayed duplicate edit
from resurrecting a deleted row, but an explicit local recreation of a natural
or derived identity (`referenceTag`, `propertyValue`, activity keys) is newer
user intent and must not be blocked for the 30-day retention period. Because
the preceding delete removed `syncState`, the recreated save has no archived
system fields and is sent as a create; the existing `serverRecordChanged`
recovery must keep it retryable if a server incarnation still exists.

The replacement activity delete triggers must explicitly write
`isPushEligible = 1` for `assistantActivity` and `activityEpoch`. Their stable
string identities are safe to delete, but the v7 triggers omit the column and
therefore inherit v13's `DEFAULT 0`. Before upgrading those tombstones, v14
must resolve an ineligible marker beside a live row as save intent: mark the
live state dirty and remove the legacy tombstone. This preserves the old pull
behavior, where a server modification could rematerialize the row and stamp
clean state while the ineligible marker remained. Only the remaining
absent-entity activity tombstones are upgraded, eligible to be sent, and later
compacted.

### 5.2 Share the runtime local identity catalog

`applyV14Body` embeds its own literal, migration-private table and identity
expressions, following `installV13SyncTriggers` precedent. It must not call a
catalog that future schema work will extend.

Separately, add one CloudKit-independent local identity-source catalog in
`RubienCore` for current runtime consumers: repair, initial baseline, and
diagnostics. It maps:

- ordinary v13 entities to `<table>.syncId`;
- `assistantActivity` to `assistantActivity.id`;
- `activityEpoch` to `activityEpoch.kind`; and
- `referencePDF` to `pdfCache JOIN reference` and `reference.syncId`.

`RubienSync.SyncEntityType` should assert in tests that its cases match the
runtime catalog's raw entity names. The migration/runtime fixture matrix catches
drift between v14's frozen literal metadata and the runtime catalog for the
rules they share. This preserves the target dependency direction while
preventing a third runtime existence switch without making shipped migration
behavior depend on mutable catalog data. The runtime catalog must remain
Foundation/GRDB-only with no CloudKit import because `RubienCore` and
`AppDatabase` compile on Linux.

### 5.3 Repair existing contradictory rows

Within v14, normalize every exact `syncState`/tombstone overlap using durable
local intent as the deterministic tie-breaker:

- If the local entity exists and its state is dirty, save wins: remove the
  tombstone and leave the state dirty with `pushInFlight = 0`.
- If an active local tombstone exists and there is no newer dirty state,
  delete wins even if a fetched server modification temporarily materialized
  the row: remove `syncState` and keep the tombstone.
- If the local entity does not exist, delete wins: remove `syncState` and keep
  the tombstone.
- A non-active historical tombstone yields to a live entity.

This matches user intent for delete-then-recreate and delete-only sequences.
For `referencePDF`, local existence is an owning `reference` plus its
`pdfCache` row. Missing bytes are a blocked upload to diagnose, not grounds to
convert a save into a delete.

### 5.4 Repair safe stale PDF identities

A stale numeric `referencePDF.entityId` may be moved to its owning reference's
current `syncId` only when all of these are true:

- the old ID is a canonical decimal local reference ID;
- it resolves unambiguously to one current reference and `pdfCache` row;
- the current reference `syncId` differs from the old ID;
- the old state has no `systemFields` and no `lastPushedAt`; and
- no different current reference uses the old string as its canonical
  `syncId`.

If the UUID-keyed target state already exists, merge dirty intent into the
target, preserve the target's server fields, set `pushInFlight = 0`, and remove
the old row. Otherwise move the row and leave it dirty.

Any state with server evidence or ambiguous ownership remains untouched and
is surfaced by diagnostics. Rubien must not guess whether such a key names an
old server record or a local row.

The data-repair order inside v14 is normative:

1. Install the corrected triggers.
2. Move or merge safe stale PDF identities.
3. Resolve live rows beside legacy ineligible activity tombstones as saves.
4. Upgrade the remaining two activity tombstone types' eligibility.
5. Normalize every exact state/tombstone overlap.

Moving PDF identities before overlap normalization prevents a safe numeric PDF
state from being mistaken for an absent local entity. Resolving the legacy
activity shape before eligibility changes prevents a historical marker from
being reinterpreted as a new local delete.

## 6. Idempotent startup repair

Migration alone does not protect a database that becomes inconsistent later,
so semantically equivalent normalization rules must also be implemented as a
transaction-safe, idempotent `SyncStateStore.repairDurableIntent()` operation.
This is deliberately not the function used by frozen `applyV14Body`; parity is
protected by shared fixtures, not shared mutable behavior.

Reorder `SyncedLibrary.start()` so every database-only startup step precedes
the first access that constructs `CKSyncEngine`:

1. Resolve pending local PDF hashes.
2. Run `prepareForStart()` so an account reset or durable replay marker is
   settled first.
3. Perform the initial baseline, which may create dirty states.
4. Drain `pdfUploadQueue` through its database-only half.
5. Repair durable intent and reset abandoned in-flight flags.
6. Compact confirmed stale tombstones.
7. Construct the engine, canonicalize its pending cache, then continue the
   normal explicit startup fetch.

Use a separate durable-intent readiness gate in addition to the existing
sidecar-preparation gate. Transaction-observer callbacks, PDF queue kicks, and
foreground fetches may arrive after sidecar preparation but before startup
repair finishes; none may construct or mutate `CKSyncEngine` until both gates
are ready. If repair fails, `SyncedLibrary.start()` reports failure, the
coordinator surfaces sync as unavailable, and no engine is constructed. A
later external start/fetch may retry the idempotent repair.

The repair returns a structured report with counts for:

- tombstones removed because a live dirty entity exists;
- dirty states removed because only a delete remains;
- removable clean orphan states deleted because they have no live entity,
  delete intent, or server evidence;
- dirty or server-evidenced orphan states preserved for diagnosis;
- abandoned in-flight flags cleared;
- safe PDF identities moved or merged; and
- ambiguous states left for operator attention.

Within the transaction, repair safe stale PDF identities before classifying
generic orphan states; otherwise the legacy numeric PDF row would be deleted
before it can be moved to its canonical UUID key. Generic orphan cleanup may
remove a state only when all of these are true:

- the local entity is absent;
- there is no active delete intent;
- `isDirty = 0`;
- `systemFields IS NULL`; and
- `lastPushedAt IS NULL`.

The implementation must comment why the final predicate is not redundant:
`clearSystemFields()` handles `.unknownItem` by nulling `systemFields` while
leaving `lastPushedAt` intact. Requiring both values to be null prevents cleanup
from erasing a previously published record after that recovery path.

Every dirty orphan remains untouched, including a dirty `referencePDF` whose
`pdfCache` row disappeared. Every orphan with archived server fields or a push
timestamp also remains untouched because that is the only local evidence of a
server record and may be needed for targeted repair. An absent entity never
justifies inventing a delete tombstone—the server may still own the record.

Log one summary when the report is non-empty. Repairs must use the normal
database writer so transaction observers schedule a later ingest only after
the transaction commits.

This ordering is required because `CKSyncEngine` may begin automatic work when
constructed. Its `automaticallySync` setting is initialization-only in the
pinned SDK, so there is no supported pause/canonicalize/resume sequence. The
database is therefore normalized first, and the final batch-provider guard in
section 8.2 protects the short interval before pending-cache canonicalization.
This keeps the existing automatic scheduler instead of replacing it with a
new manual one.

Resetting `pushInFlight` belongs here rather than in v14. The migration runs
once, while process restart is the event that proves every old request is
abandoned. Normal dirty tracking still clears `pushInFlight` when an edit races
with a request from the current process.

## 7. One API for durable intent

Add two `SyncStateStore` operations and route all non-trigger writers through
them:

```swift
queueSave(entityType:entityId:)
queueDelete(entityType:entityId:deletedAt:)
```

`queueSave` removes the exact tombstone and then upserts dirty state with
`pushInFlight = 0`. `queueDelete` upserts the tombstone and then removes the
state. Both operations must be performed in the caller's database transaction.

Adopt the save primitive in:

- `PDFUploadQueue.drainPDFUploadQueueIntoSyncState()`;
- manual dirty-marking helpers in `SyncEntityDispatch`;
- view alias republishing;
- activity rebase paths; and
- quarantine merge/retry paths.

This includes bare-update sites such as the reading-activity conflict path
that currently executes `UPDATE syncState SET isDirty = 1 ...`. That statement
silently does nothing when the bookkeeping row is absent. No dirtying path may
depend on a pre-existing `syncState`; scalar and bulk variants must upsert and
clear exact tombstones by construction.

Account reset and intentional full replay may retain their bulk implementation
only if they establish the same invariant in one transaction.

## 8. Reconcile the CKSyncEngine scheduling cache

Split append-only ingestion from exact canonicalization so normal commits stay
cheap while stale engine state still self-heals.

### 8.1 Pure desired-intent planner

Build a small pure planner whose inputs are:

- normalized desired intents, including local-entity existence;
- eligible, unconfirmed tombstones;
- the writer-upgrade gate; and
- the engine's `pendingRecordZoneChanges`.

Its output is a set of pending changes to remove and a set to add. For each
parseable Rubien record ID:

- desired save: retain or add one save and remove deletes;
- desired delete: retain or add one delete and remove saves;
- desired none: remove both save and delete entries;
- writer-gated intent: do not add it and remove a previously queued equivalent
  that is no longer eligible.

Use `CKSyncEngine.State.remove(pendingRecordZoneChanges:)` followed by
`add(pendingRecordZoneChanges:)`. This API is present in the pinned macOS SDK.
Unknown future record types or unparseable record IDs are logged and preserved
conservatively rather than deleted.

Run full reconciliation:

- once immediately after engine construction;
- after a send failure changes durable state; and
- from the existing external idle-timer path before its fetch.

The transaction observer keeps an add-only ingestion path: it reads current
dirty states and eligible tombstones and adds missing desired operations, but
does not enumerate or diff `pendingRecordZoneChanges`. Debounce and coalesce
commit notifications so a bulk import produces one pass per burst rather than
one full-table scan per row. Removing an obsolete opposite engine operation can
wait for idle canonicalization because the authoritative batch guard below
will suppress it in the meantime.

These calls may be actor-scheduled from delegate callbacks, but they must not
call `fetchChanges()` or `sendChanges()` from `handleEvent`.

### 8.2 Final batch-provider guard

Extract the safety decision from the CloudKit delegate into a database-only
function with plain Sendable inputs and output, for example:

```swift
resolveBatchIntents(
    db: Database,
    pendingIdentities: [PendingSyncIdentity]
) throws -> BatchIntentResolution
```

`PendingSyncIdentity` carries only entity type, entity ID, and requested
save/delete operation. `BatchIntentResolution` contains the deduplicated
resolved intents plus `anomalyDetected`. The delegate maps the scoped
`CKSyncEngine.PendingRecordZoneChange` values into these plain identities,
calls the resolver inside its database transaction, and maps the selected
intents back to the original pending changes.

This extraction is required for testability, not just organization:
`CKSyncEngine.SendChangesContext` has no public initializer in the pinned SDK,
and constructing `CKSyncEngine` in an unentitled XCTest raises `CKException`.
The resolver must not accept a CloudKit context, engine, or pending-change
object.

The database-only resolver independently reduces every pending record ID to
one current SQLite intent through the shared local-identity catalog:

- read `writerUpgradeRequired` and reject every
  `entityType.isUnsafeForV12(entityId:)` save or delete while the gate is
  active;
- a dirty state with a live entity is a save;
- an active delete tombstone (`confirmedByServer = 0 AND isPushEligible = 1`)
  with no live dirty entity is a delete;
- a confirmed or ineligible tombstone is not active delete intent and must not
  suppress a legitimate save;
- an absent entity with only stale dirty state, or a clean state, supplies no
  operation; and
- group by record ID so a batch cannot contain both operations even if engine
  state becomes corrupt between reconciliations.

If an unexpected overlap survives until batch construction, a dirty live state
is a recreation/save, while an active tombstone with no dirty state remains a
delete even if a fetched modification has temporarily materialized the row.
Log the anomaly, set a deferred-reconciliation flag, and still return at most
that one chosen operation. Do not mutate the engine's pending state inline from
`nextRecordZoneChangeBatch`, which is itself a mid-send delegate callback. The
terminal send-event path dispatches reconciliation as its final action without
awaiting it, or the external idle path consumes the flag, so canonicalization
begins only after the current delegate turn returns. This boundary must remain
explicit because direct `fetchChanges()`/`sendChanges()` re-entry from an
event-triggered task caused the 0.1.9 `EXC_BREAKPOINT` regression; pending-state
mutation must not become an excuse to move those calls back into callbacks.

This check is authoritative during launch: if the engine requests a batch
before post-construction canonicalization completes, normalized SQLite still
limits the batch to one current intent.

The save record provider retains two construction-time checks after resolution:

- re-read the writer-upgrade gate and reject v12-unsafe identities again,
  because the resolver's read and provider's write are separate transactions;
  and
- keep `activityFactIsPushEligible(db:entityId:)` in the provider immediately
  before record construction. It validates whether an activity fact still
  belongs to the current epoch, rather than deciding which pending operation
  the scheduler prefers.

The resolver-level writer-gate check is the primary scheduling filter and is
unit tested. The provider recheck is intentional defense across the transaction
gap, not redundant policy.

Change `markPushInFlight` to:

```sql
UPDATE syncState
SET pushInFlight = 1
WHERE entityType = ? AND entityId = ? AND isDirty = 1
```

Return whether the statement matched a row. Do not add
`AND pushInFlight = 0`: SQLite reports a matched row when the value is already
one, and a legitimate engine retry of an in-flight dirty record must continue.
If no dirty row matched, the record provider returns `nil` instead of creating
a record or leaving a clean state marked in flight.

Likewise, `AND isDirty = 1` is the authoritative last word, not a duplicate of
the resolver's earlier dirty check. Resolution happens in a read transaction;
record construction and the in-flight stamp happen later in one write
transaction. A pull, delete, or acknowledgement can clean/remove the state in
between, and this predicate closes that time-of-check/time-of-use gap.

Test `resolveBatchIntents` directly for deduplication, save/delete choice, and
anomaly detection. Test `markPushInFlight` directly against an in-memory
database. Small actor test seams may assert that an anomaly sets the deferred
flag, but no unit test should manufacture `SendChangesContext` or construct a
real engine.

## 9. Failure lifecycle and user-visible status

Every failed save must release `pushInFlight` while retaining `isDirty`, unless
the existing conflict-resolution path has already confirmed or replaced the
state.

When a fetched modification has an exact active local-delete tombstone, skip
applying that stale server version so it cannot rematerialize the locally
deleted row. A tombstone on a retired identity alias does not suppress the
record: route the late payload to the canonical winner and keep the alias
delete queued.
A confirmed or ineligible historical tombstone is not active: remove that
marker, apply the server recreation, and stamp its pulled state normally. The
same rule applies when replaying a previously quarantined record after its
dependencies arrive; delete-wins replay also retires its archived payload and
any staged PDF file.

Handle important errors as follows:

- `serverRecordChanged`: if the save was superseded by an exact active local
  tombstone, skip the stale server record (and discard any staged PDF asset) so
  conflict recovery cannot resurrect the deleted row. Otherwise keep the
  existing conflict policy, then reconcile.
- `zoneNotFound`: preserve the existing zone recovery path, release in-flight
  state, then reconcile.
- `unknownItem`: clear cached server fields, release in-flight state, and let
  the post-callback reconciliation requeue a create.
- `invalidArguments`: release all affected in-flight rows and publish a visible
  error, then schedule durable repair and queue canonicalization to begin only
  after the delegate callback returns, using the deferred boundary in section
  8.2.
- other retryable/permanent errors: release in-flight state and publish the
  error; CKSyncEngine or a later local reconciliation controls retry timing.

For a successful delete acknowledgement, finalize the exact local deletion
before confirming its tombstone if an older fetched modification had already
rematerialized the row. A failed delete with `.unknownItem` uses the same local
finalization before purging the tombstone because “already absent” is also a
successful server outcome. In both paths, the exact active tombstone is the
ownership token: if a newer live dirty recreation removed or superseded it,
preserve the row and queue its save instead. Run the local delete under the
remote-apply guard and unlink any returned PDF filenames only after commit.

For a failed delete with `.unknownItem`, parse both the entity type and entity
ID from that exact record name and remove only its exact tombstone. Never loop
over `SyncEntityType.allCases` by shared entity ID: `reference` and
`referencePDF` intentionally use the same owning reference `syncId`, so the
current cross-type purge can discard a pending reference deletion when only
the PDF delete was already absent.

Batch-wide errors are often repeated once per record. Deduplicate reporting by
error domain, code, and description, then log one message containing the
number and types of affected records.

Track the most recent send error separately from fetch/send in-flight flags.
Reset a per-cycle failure accumulator at `.willSendChanges`, set it from any
failed save or delete in `.sentRecordZoneChanges`, and inspect it at
`.didSendChanges`. A failed cycle must not be overwritten with `.idle`; a later
cycle with no failures clears the error. The existing status banner can display
the underlying error; add a specific message for contradictory-intent repair
only if generic CloudKit text is not actionable enough.

## 10. Diagnostics and recovery surface

Extend `SyncIdentityDiagnostics` and `rubien-cli sync status` with computed,
read-only counts:

- `contradictoryIntentCount`;
- `pushInFlightCount` (only known to be abandoned during pre-engine startup
  repair; it may be legitimate while a live app is sending);
- `removableOrphanSyncStateCount` for a clean, unproven state eligible for the
  conservative cleanup rule in section 6;
- `preservedOrphanSyncStateCount` for an absent local entity whose state is
  dirty or retains `systemFields`/`lastPushedAt` evidence;
- `unpublishedLiveEntityCount` for a live entity with no state, or a clean
  state with no server fields, after `baselineState = complete`;
- `missingPDFCacheUploadCount` for dirty `referencePDF` state with no matching
  `pdfCache JOIN reference` row;
- `stalePDFIdentityCount`;
- `ambiguousPDFIdentityCount`.

Compute the live-entity counts through the shared local identity catalog. The
unpublished count catches locally untracked rows and bare-UPDATE failures; it
does **not** claim to detect a record whose clean state contains archived server
fields but whose CloudKit record later disappeared. Detecting that case still
requires an explicit remote inventory or republish workflow. Preserved-orphan
and missing-cache counts are safety diagnostics: startup must not erase them or
claim that the corresponding upload completed.

Keep `SyncIdentityDiagnostics.read(from:)` database-only so its existing CLI,
coordinator, and test call sites remain cheap. File materialization is a
separate opt-in `PDFMaterializationDiagnostics` operation. It first snapshots
dirty PDF identities and filenames in a short database read, releases the GRDB
transaction, and only then performs filesystem checks. The CLI exposes it via
`sync status --check-pdf-files`; normal `SyncCoordinator` initialization and
refresh never `stat()` every PDF.

The opt-in check must receive the active library's resolved PDF storage URL
from `AppDatabase`; it must not rediscover a path independently because signed,
unsandboxed, legacy, and backup libraries may coexist on one Mac. Its result
includes missing-file count and affected sync IDs/reasons so the operator can
act on more than a bare count.

Update `Docs/CLI-Reference.md`, `Docs/Sync-Runbook.md`, and CLI contract tests in
the same change. The runbook should define an action for every persistent
diagnostic:

1. Relaunch Rubien and let startup repair run.
2. `contradictoryIntentCount`, `removableOrphanSyncStateCount`, and abandoned
   pre-start in-flight state should become zero. If they do not, preserve a
   backup and stop before manual mutation.
3. For `missingPDFCacheUploadCount` or opt-in missing files, record the listed
   sync IDs and restore or reattach the corresponding local PDF before retrying
   sync; use targeted repair only after a backup if no asset can be recovered.
4. For `preservedOrphanSyncStateCount`, record the count and IDs but take no
   destructive action. Preserve the evidence for the future remote-inventory
   or explicit-republish workflow.
5. For ambiguous PDF identities, back up and follow a targeted operator repair.

Persistent preserved-orphan counts belong in explicit diagnostics, not a
warning banner repeated on every launch. A dirty PDF with no `pdfCache` row is
desired-none, so the planner removes any stale engine save and the resolver
never attempts an upload; that case is surfaced only by explicit diagnostics.
A PDF with a cache row but missing bytes may additionally log once when record
construction fails. Startup logs the repair actions it actually performed, not
the same unactionable preserved count indefinitely.

Sidecar reset remains a receiver-only full-replay tool and must not be the
first response to a stuck source queue.

## 11. Alternatives rejected

- **Only fix the triggers:** prevents one creation path but leaves already
  corrupt databases, stale engine entries, manual dirty writers, and crash
  leftovers unresolved.
- **Trust CKSyncEngine deduplication:** it deduplicates repeated equivalent
  entries, but the incident proves a save and delete for the same record can
  coexist and reach one modify operation.
- **Reset the engine sidecar on every launch:** discards useful change tokens,
  increases replay cost, and cannot repair contradictory SQLite intent.
- **Disable automatic sync during startup:** the SDK exposes the setting only
  at engine initialization. Keeping it disabled would require Rubien to own a
  new send scheduler; the authoritative batch guard solves the race with less
  new machinery.
- **Automatically mark all clean rows dirty:** may resurrect deliberate remote
  deletions or overwrite newer server state. It is suitable only as an
  explicit, confirmed recovery operation.

## 12. Test matrix

### Database and migration tests

- `makeV12DatabaseForTesting(on:)` still applies exactly v1 through v12, while
  the normal migrator applies v14 and matches `currentSchemaVersion`.
- Delete then recreate the same `referenceTag`: only dirty save intent remains.
- Local delete, server confirmation, then recreation of the same composite key
  removes the retained tombstone and queues one create; if that create receives
  `serverRecordChanged`, conflict recovery leaves a valid retry path.
- Insert/update with a stale tombstone removes it for every trigger family.
- Delete still leaves only a tombstone.
- Cover `assistantActivity` and `activityEpoch`, not only v13 tables.
- New and pre-v14 unconfirmed activity tombstones are explicitly push eligible.
- A pre-v14 unconfirmed `activityEpoch` tombstone plus its live epoch row is
  removed by post-upgrade overlap repair and queues no delete.
- v14 migration repairs a dirty live overlap with save-wins behavior.
- v14 migration preserves an active local delete when a fetched modification
  materialized a live row without a newer dirty state.
- v14 migration repairs an absent-row overlap with delete-wins behavior.
- **Slice 2:** Frozen `applyV14Body` and the separate runtime repair agree only
  on their intentionally shared fixture subset: overlap normalization, safe
  PDF-key repair, and activity-tombstone eligibility. Runtime-only in-flight
  reset and generic orphan cleanup are excluded from this parity assertion.
- Startup repair is idempotent and clears abandoned in-flight flags.
- Startup removes only clean orphan state with no fields or push timestamp; it
  preserves dirty, server-evidenced, and last-pushed orphan states.
- A state passed through `clearSystemFields` retains `lastPushedAt` and remains
  ineligible for orphan cleanup.
- A safe unconfirmed numeric PDF key moves or merges into the UUID key.
- A proven or ambiguous PDF key remains unchanged and diagnosed.
- A dirty `referencePDF` state remains diagnosed when `pdfCache` or its bytes
  are missing; startup never silently deletes it.
- PDF queue draining removes an exact stale tombstone before marking dirty.
- A bare dirtying path with no pre-existing `syncState` upserts a dirty row.
- **Slice 2:** The Core local-identity catalog and `SyncEntityType.allCases`
  remain in lockstep.

### Planner and batch tests

- Pending save plus pending delete converges to the single SQLite intent.
- A stale engine save for a clean state is removed.
- A writer-gated change is neither re-added by the pending-cache planner nor
  selected by the DB-only batch resolver.
- Unknown future record types are preserved.
- The DB-only batch resolver cannot select save and delete for the same record.
- A confirmed retained tombstone does not suppress a recreated save.
- Direct database tests prove a clean state cannot be marked `pushInFlight`
  and an already-in-flight dirty state still matches for an engine retry.
- If a resolver selects a dirty save and the state becomes clean before the
  provider transaction, `markPushInFlight` matches nothing and the provider
  returns nil.
- Activity-fact epoch eligibility remains a provider-level construction check,
  while the resolver owns the writer-upgrade scheduling gate.
- A burst of commit notifications coalesces into one add-only ingestion pass;
  full pending-cache enumeration is absent from the commit path.
- The DB-only resolver reports a batch anomaly, and the actor seam records only
  deferred reconciliation; no test constructs a CloudKit engine or
  `SendChangesContext`.

The pending-cache planner and database batch resolver must be directly testable
without a CloudKit entitlement. Only the thin production delegate adapter
touches `SendChangesContext` and the live engine.

### Failure and status tests

- Every failed save releases `pushInFlight` and remains retryable.
- `unknownItem` clears server fields and is re-planned as a create.
- Repeated batch-wide `invalidArguments` errors produce one diagnostic.
- An `.unknownItem` PDF-delete failure removes only the `referencePDF`
  tombstone and preserves a same-ID `reference` tombstone.
- A failed send remains visible after `.didSendChanges`.
- A later successful send clears the error and returns to idle.

### CLI and manual tests

- `sync status --json` retains its documented shape plus the new fields,
  including unpublished-live, removable-orphan, preserved-orphan, and
  missing-PDF-cache fixtures.
- `sync status --check-pdf-files` snapshots rows before filesystem checks,
  reports missing IDs using the injected active storage root, and leaves the
  default status path database-only.
- Two signed 0.7.5+fix builds converge after delete/recreate of one tag
  assignment while unrelated reference and PDF uploads are queued.
- Force-quit during a send, relaunch, and verify abandoned flags repair and the
  queue drains.
- Simulate a stale unconfirmed numeric PDF key and verify automatic migration.
- Keep both Macs open through a foreground/idle-fetch cycle and verify equal
  reference manifests, not only equal counts.

Follow the existing suite workaround: run the known wedged activity deletion
test alone, and run the broader suite with `--skip ActivityRecordTests`.

## 13. Delivery slices

Each slice should build and pass its focused tests before the next begins.

1. **v14 invariant:** frozen literal migration metadata, guarded registration,
   trigger replacement, activity tombstone eligibility, overlap repair, safe
   PDF-key repair, and migration tests.
2. **Durable intent APIs:** runtime local-identity catalog,
   `queueSave`/`queueDelete`, PDF drainer and manual writer adoption, startup
   repair report, and scoped migration/runtime parity fixtures.
3. **Engine reconciliation:** debounced add-only commit ingestion, pure full
   planner, DB-only `resolveBatchIntents` with writer-gate filtering,
   pending-cache remove/add on startup/failure/idle, thin delegate adapter, and
   final provider/TOCTOU guards.
4. **Failure observability:** release failed in-flight rows, sticky send errors,
   exact-type failed-delete cleanup, deduplicated batch diagnostics, and status
   tests.
5. **Operator surface:** SQL-only core diagnostics, opt-in PDF filesystem
   diagnostics and CLI flag, app messaging, runbook actions, and the signed
   two-Mac test.
6. **Delivery verification:** focused suites, broad suite workaround, build,
   independent diff review, simplify sweep, final rebuild and retest.

## 14. Acceptance criteria

The fix is complete when all of the following hold:

- A query cannot find an exact active `syncState`/tombstone overlap after any
  supported local mutation or app launch.
- The v12 migration test fixture remains v12; production migration reaches v14.
- The engine pending queue converges to the normalized database intent without
  resetting fetch tokens.
- The batch provider never submits both save and delete for one record.
- Relaunching after interruption leaves no abandoned `pushInFlight` rows.
- Commit-driven ingestion is coalesced and never performs full engine-state
  canonicalization per imported row.
- Safe legacy PDF keys self-heal; unsafe ones are reported and unchanged.
- Dirty or server-evidenced orphan state is retained and reported.
- Normal coordinator diagnostics perform no PDF filesystem scan; opt-in scans
  use the active database's resolved storage root outside the read transaction.
- A CloudKit send failure remains visible and all affected records remain
  retryable.
- Failed-delete cleanup cannot remove a tombstone belonging to another entity
  type with the same ID.
- The reproduced tag conflict no longer blocks unrelated references or PDFs.
- Two Macs converge by stable `syncId` manifest in the manual signed-app test.

## 15. Rollout and rollback

Ship the change as the next app database schema version. Because v14 changes
only local triggers and queue rows, Macs on v14 and v13 remain CloudKit
wire-compatible during a staged rollout; only the upgraded Mac has the new
invariant enforcement. However, once a Mac has opened and migrated its SQLite
library to v14, Rubien 0.7.5 detects a newer schema and refuses to open it.
Rolling back the binary on that Mac therefore requires restoring that Mac's
complete pre-upgrade library backup. Keep each machine's backup until
two-device verification completes.

On first launch, log the repairs actually performed. Keep preserved orphans in
explicit diagnostics without repeating an unactionable warning banner. Surface
no-cache PDF state through SQL diagnostics and missing files through the
opt-in scan or a one-time record-construction log. Do not automatically erase
the sidecar or republish clean history. If field telemetry or user reports show
unresolved clean-local/server-missing records, design the explicit republish
operation separately with confirmation and a manifest preview.
