# Global Sync Identities — Design Spec

**Date:** 2026-08-14

**Status:** Proposed — implementation has not started

**Review:** Iterative Claude Code design reviews validated and incorporated on
2026-08-14. They tightened cross-platform migration ownership, PropertyValue
identity adoption, activity quarantine, replay reuse, PDF replay cost and
phase ordering, deterministic convergence, mixed-version write safety,
archive-failure containment, old-binary handling, and final scope reduction.

**Scope:** `RubienCore`, `RubienSync`, `rubien-cli`, CloudKit schema, and the
iOS sync-access gate when this work is integrated with the iOS port

## 1. Summary

Rubien will stop using SQLite `Int64` row IDs as cross-device identities.
Every synced row will have an opaque string `syncId`; new independently
created rows use lowercase UUIDs, while already-server-backed records keep
their existing numeric record-name component as a permanent legacy identity.
SQLite `Int64` primary and foreign keys remain local implementation details.

CloudKit record names remain the canonical identity:

```text
<entityType>:<syncId>
```

New CloudKit string fields carry related entities' sync IDs. Existing `Int64`
fields and numeric record names are never renamed or removed. A new peer
prefers the string fields and falls back to the old fields, so existing cloud
data remains readable without a destructive re-key.

The migration also replaces dirty-tracking keys, reuses Rubien's durable
full-history replay, quarantines ambiguous pre-migration deletes, and holds
only v12-readable hazardous saves/deletes behind an explicit
all-writers-upgraded interlock. New global-identity traffic continues during
the rollout. The specific regression to prevent is a local, never-synced web
clip at SQLite ID 1796 being overwritten by an unrelated remote reference
whose originating device also assigned ID 1796.

## 2. Motivation and incident

The browser extension correctly captured the LinkedIn article “Knowledge
Flywheels” and committed it to the local library. The row was not visible
afterward because the next CloudKit pull applied an unrelated KnapFormer
reference using the same numeric record name. Both devices had independently
allocated local row ID 1796, and the pull path treated that number as the
identity of one logical reference.

This is not LinkedIn-specific and cannot be fixed reliably in the extension.
Any independently inserted reference, tag, annotation, custom property, or
saved view can collide while record names are derived from local
autoincremented IDs. Child records compound the problem because their payloads
also carry local numeric foreign keys.

The current code already anticipated part of the migration:

- `syncState.entityId` and `tombstone.entityId` are `TEXT`;
- record-name parsing preserves an arbitrary string after the first `:`;
- CloudKit foreign keys are plain values rather than `CKRecord.Reference`s;
  and
- the sync runbook identifies this as the A-pks follow-up.

The missing piece is a durable global identity and a rollout that does not
reinterpret or destroy existing records.

## 3. Goals and non-goals

### Goals

- Prevent unrelated rows created on different devices from overwriting or
  deleting one another.
- Preserve local `Int64` IDs for UI selection, FTS rowids, CLI selectors,
  SQLite joins, and existing app code.
- Keep every existing CloudKit record readable and editable.
- Keep CloudKit field evolution additive: no field rename, type change, or
  removal.
- Make mixed-version limits explicit: old peers may temporarily miss new
  UUID-named rows, and v13 must not send a record shape that v12 could
  destructively apply until the user has upgraded or stopped every older
  writable peer.
- Recover UUID records skipped by an old peer once that peer upgrades.
- Translate all synchronized relationships, including IDs embedded in saved
  view JSON, through global identities.
- Preserve current trigger guarantees for dirty rows, tombstones, cascade
  deletes, and push-in-flight edits.
- Keep iOS in read-only replica mode until its local schema and sync dispatch
  use this identity contract.
- Keep migration classification deterministic whether the database is first
  opened by the app, the macOS CLI, or a supported Linux-only library; a
  copied CloudKit-backed database on Linux must fail closed rather than guess.

### Non-goals

- Replacing local `Int64` primary keys with UUID SQLite primary keys. The
  global identity is the application-level key; the integer remains a local
  surrogate.
- Bulk-renaming existing CloudKit record IDs. CloudKit record IDs are
  immutable, and delete-plus-create would create avoidable duplicate and
  rollback hazards.
- Automatically merging two genuinely duplicate references imported on two
  devices. UUIDs prevent data loss; semantic deduplication remains a separate
  feature.
- Automatically reconstructing content that was overwritten before this
  migration. Backups and CloudKit history may help with individual recovery,
  but the identity migration cannot infer lost values.
- Field-level conflict merging. Existing server-wins behavior remains
  independent of identity resolution.
- CloudKit zone deletion or production-library reset as part of migration.

## 4. Normative identity contract

### 4.1 Local key versus sync identity

For ordinary synced models, the two identities have distinct jobs:

| Identity | Example | Meaning |
|---|---|---|
| local ID | `1796` | Row address inside one SQLite library |
| sync ID | `6f29e739-25d1-4a7f-a043-b878bf6ec868` | Stable logical identity shared by peers |
| record name | `reference:6f29e739-25d1-4a7f-a043-b878bf6ec868` | CloudKit canonical identity |

`syncId` is an opaque, non-empty string. Callers must not assume that it is
always a UUID because already-server-backed records retain their legacy
numeric value. New random IDs are RFC 4122 UUID strings normalized to
lowercase. Every newly allocated stored identity is a random UUID except for
the natural and parent-derived identities listed below.

A canonical decimal legacy ID is a string that parses as `Int64` and
round-trips unchanged through `String(parsed)`. This excludes signs, leading
zeroes, whitespace, and other alternate spellings. Reconciliation may branch
on this syntax but never on device-local sync state.

The portion after the first `:` in a record name is opaque to the generic sync
engine. Entity-specific code may parse `/` only for the compound identities
listed below.

### 4.2 Identity by entity

| Entity | New sync identity | Local key remains |
|---|---|---|
| Reference | random UUID | `reference.id` |
| Tag | random UUID | `tag.id` |
| PDF annotation | random UUID | `pdfAnnotation.id` |
| Web annotation | random UUID | `webAnnotation.id` |
| Metadata intake | random UUID | `metadataIntake.id` |
| Metadata evidence | random UUID | `metadataEvidence.id` |
| Custom property definition | random UUID | `propertyDefinition.id` |
| Built-in property definition | random UUID when not already server-backed | `propertyDefinition.id` |
| Custom database view | random UUID | `databaseView.id` |
| Seeded default database view | random UUID when not already server-backed | `databaseView.id` |
| Reference–tag pivot | `<referenceSyncId>/<tagSyncId>` | `(referenceId, tagId)` |
| Property value | `<referenceSyncId>/<propertySyncId>` | `propertyValue.id` and its unique local pair |
| Reading activity | `<generation>/<installationId>/<referenceSyncId>/<localDay>` | current composite SQLite key |
| Assistant activity | existing UUID-like string `id` | `assistantActivity.id` |
| Activity epoch | existing `kind` (`reading` or `assistant`) | `activityEpoch.kind` |
| Reference PDF | owning reference's sync ID | local `pdfCache.referenceId` |

Derived pivot/value IDs intentionally converge when two devices create the
same logical relationship. Their entity-type prefix keeps identical endpoint
pairs in different record types distinct.

### 4.3 Immutability

Once assigned, a sync ID does not change during normal mutation, merge, or
local row re-numbering. The only allowed adoption is during legacy duplicate
reconciliation, before the local candidate has a confirmed server identity.
Changing a confirmed sync ID is a record deletion plus creation and is outside
this design.

Every new or changed `CKRecord` includes a `syncId` string matching the entity
portion of its record name. Legacy records without that field derive it from
the record name. A mismatch is quarantined and logged; it is never applied to
an arbitrary local row.

## 5. Local schema migration (v13)

The current code schema is v12, so implementation uses a new immutable `v13`
migration and bumps `AppDatabase.currentSchemaVersion` in the same commit. The
sync runbook must document both the existing local-only v12 cache migration
and v13.

### 5.1 Added columns

Add `syncId TEXT` plus a unique index to each synced table whose identity is
not already a global string or natural key:

- `reference`, `tag`, `pdfAnnotation`, `webAnnotation`;
- `metadataIntake`, `metadataEvidence`;
- `propertyDefinition`, `propertyValue`, `databaseView`; and
- `referenceTag` and `readingActivity` for a durable precomputed compound ID.

Add shadow global-FK columns wherever a synced row points at another synced
row:

| Table | Added global-FK columns |
|---|---|
| `referenceTag` | `referenceSyncId`, `tagSyncId` |
| `pdfAnnotation` | `referenceSyncId` |
| `webAnnotation` | `referenceSyncId` |
| `metadataIntake` | `linkedReferenceSyncId` |
| `metadataEvidence` | `intakeSyncId`, `referenceSyncId` |
| `propertyValue` | `referenceSyncId`, `propertySyncId` |
| `readingActivity` | `referenceSyncId` |

The numeric foreign keys remain authoritative for local joins and referential
integrity. The shadow values are immutable denormalization used by CloudKit
mapping and delete triggers. Mutation helpers set both in one transaction;
remote apply resolves a sync ID through the parent's unique index and then
writes the matching numeric and string values.

SQLite cannot add the required non-null constraints to populated tables in
place. v13 therefore backfills first, creates unique indexes, and installs
validation triggers that abort inserts or identity changes with missing or
mismatched sync IDs. A later binary opened against v13 fails loudly on an old
write path rather than silently creating an untracked row.

All added columns on synced tables are added to the corresponding CloudKit
mapping and `allFieldNames`; none are local-only exceptions to
`SyncSchemaInvariantTests`.

`activityQuarantine` is local-only but also needs an additive identity repair:

- add nullable `referenceSyncId TEXT` and make it authoritative for matching a
  quarantined ReadingActivity to a Reference;
- retain `referenceId INTEGER` only as an optional resolved-local cache during
  the transition, never as a wire identity;
- replace the `(entityType, referenceId, receivedAt)` index with
  `(entityType, referenceSyncId, receivedAt)`; and
- store a versioned reading-activity quarantine DTO containing
  `referenceSyncId`, rather than JSON-encoding a `ReadingActivity` whose
  `referenceId` is necessarily local. Assistant-activity quarantine retains
  its reference-free payload case.

For an existing quarantine row, backfill `referenceSyncId` from the matching
Reference when one exists. If the parent is absent, recover the old integer
from the `referenceId` column or the legacy `recordData` payload and preserve
it as the decimal legacy sync ID. If neither source is valid, keep the row
unresolved and report it; never guess from another local row. New quarantine
inserts for ReadingActivity require a non-empty `referenceSyncId`. Replay
resolves that string to the current local integer before constructing or
upserting `ReadingActivity`. Reference-delete cleanup captures the parent's
sync ID before deletion and queries quarantine by `referenceSyncId`.
Replay notifications likewise carry `Set<String>` reference sync IDs; they do
not use an incoming wire number as a `Reference.id` lookup.

### 5.2 Cross-platform classification boundary

The classification cannot depend on `RubienSync`: `AppDatabase` migrations
live in `RubienCore`, and the first opener may be the app, the macOS CLI, or
the Linux CLI. `syncState.systemFields` is a CloudKit-archived `CKRecord`, so
v13 defines the following explicit platform behavior:

- On macOS and iOS, a small `#if canImport(CloudKit)` inspector in
  `RubienCore` decodes only the record's system fields and returns its record
  type and name. It reuses the existing
  `SyncStateStore.rehydrateRecord(from:)` codec and `rehydrateOrNew`
  record-name comparison pattern in the lower layer. It adds the required
  record-type check rather than inventing a second archive format. This is
  local archive decoding; it neither constructs `CKContainer` nor requires an
  iCloud entitlement, so the unsigned macOS CLI can use it.
- On Linux, a library with zero non-null `systemFields` rows is necessarily
  local-only under the supported product and may classify all ordinary rows
  as unconfirmed. If any non-null `systemFields` exists, v13 throws an
  actionable `requiresAppleIdentityMigration` error before making schema or
  data changes. A Mac-synced library copied to Linux must be migrated once by
  a v13 Apple binary before Linux may reopen it.
- A corrupt archive, an archive whose record name is unqualified, or any
  mismatch with `<entityType>:<entityId>` is never accepted as proof of the
  numeric identity. It follows the unconfirmed path. Misclassification is
  therefore allowed only toward a new UUID (possible duplicate), never toward
  an unproven legacy identity (possible overwrite).

Apple migration performs a cohort preflight before assigning any identity.
Let `N` be the number of non-null `systemFields` rows and `F` the number that
cannot be decoded to the exact expected qualified record name, including
corrupt, unqualified, record-type-mismatched, and record-name-mismatched
archives. For `N > 0`, the permitted isolated-failure count is:

```text
min(10, max(1, floor(N * 0.01)))
```

When `F` exceeds that value, v13 throws an actionable
`identityArchiveClassificationFailed(total: N, failed: F)` error before
schema or data changes. This catches an OS/archive-format break before it
silently forks a material fraction of the library, while allowing a bounded
number of individual rows to take the safer duplicate-producing path.
Diagnostics report only aggregate counts by failure category, never record
content.

No archive-repair override ships in v13. If this preflight fires, the error
states that the transaction made no changes, reports aggregate failure counts,
and directs the user to stop the upgrade and report those counts. The user may
continue with v12 against the unchanged root, or restore the complete pre-v13
root backup and remain on v12. Support must not clear `systemFields`, reset the
library, or delete the CloudKit zone. A recovery mechanism is designed only
after a real failure provides evidence about the archive incompatibility it
must repair.

The platform and cohort preflights are the first operations in v13's
transaction. Tests must prove that either failure leaves `grdb_migrations`,
table columns, triggers, and user rows unchanged.

Byte-searching the opaque archive is explicitly rejected. It would couple a
production data migration to an undocumented binary encoding and cannot prove
the absence of false positives.

### 5.3 Backfill classification

For each existing row, v13 classifies the current sync-state entry before
assigning an identity:

1. **Server-backed:** matching `syncState.systemFields` decodes successfully
   and its record type and name equal the expected CloudKit type and currently
   qualified `<entityType>:<entityId>`. Preserve the current `entityId` as
   `syncId`. This keeps the existing record name and change tag valid. A
   non-null blob for an older unqualified or otherwise mismatched record is
   not proof that the current numeric identity exists on the server.
2. **Local/unconfirmed:** there are no matching system fields, regardless of
   whether the row is dirty. Assign a random UUID, except for identities
   derived from parent sync IDs. Mark the new key dirty.
3. **Natural/global already:** preserve Assistant activity IDs and activity
   epoch kinds. Rebuild reading-activity IDs with the reference sync ID when
   the old fact is not server-backed.

This distinction is what protects the reported incident. The unsent LinkedIn
row at local ID 1796 gets a UUID. Pulling legacy `reference:1796` then finds no
row with `syncId == "1796"` and inserts KnapFormer at a free local integer ID;
both survive.

Backfill and sync-state key rewriting run with remote-apply dirty triggers
suppressed. The migration then drops the v1/v7 identity triggers and installs
new triggers that write `syncId`, not `id`, to `syncState` and `tombstone`.
Cascade-deleted child rows use their stored shadow IDs, so they do not depend
on querying an already-deleted parent. For an unconfirmed row whose key becomes
a UUID, v13 clears stale `systemFields`/`lastPushedAt`, sets `isDirty = 1`, and
sets `pushInFlight = 0`; it must never rehydrate a new record name from
mismatched legacy system fields. Proven legacy rows preserve their matching
system fields but still set `pushInFlight = 0`, because the sidecar reset
discards the in-flight engine state to which the old flag referred.

### 5.4 Sidecar reset and full replay

The CKSyncEngine sidecar may contain pending numeric saves/deletes that no
longer match v13 keys. It may also contain an advanced cursor from a v12 peer
that fetched and skipped UUID records written by another upgraded device.

v13 inserts the existing `fullHistoryReplayPending` session marker. It does
not add a second replay state machine. `SyncedLibrary.prepareForStart()`,
`FetchStatePersistenceGate`, and the existing durable-finalization path remain
the single owners of sidecar reset, nil-history replay, orphan reconciliation,
and marker removal. Dirty rows and eligible tombstones are re-enqueued from
SQLite after the reset. The marker is cleared only after the end-of-fetch
engine state has been durably serialized.

This replay is mandatory. Merely teaching the upgraded decoder about UUIDs is
insufficient because CloudKit will not redeliver records behind its persisted
cursor.

### 5.5 Full-replay PDF handling

The mandatory history replay can redeliver every `CDReferencePDF`. Applying an
unchanged record must not replace a materialized PDF merely because its
CloudKit change tag or sync metadata changed. The fast path preserves the
existing prepare/apply phase boundary without introducing a per-record retry
or engine-recovery path:

1. Phase 1 always stages every valid incoming asset through the existing
   `prepareReferencePDFMaterialization` path outside the writer transaction.
   It may also snapshot the current `pdfCache` fingerprint and confirm that
   the live cached file exists, but that snapshot is only a reuse hint.
2. In the Phase 2 database transaction, compare the incoming
   `contentHash`/`assetVersion` with the current row. If they match the reuse
   hint, keep the existing filename, update only system fields and sync
   bookkeeping, and record the staged file for post-commit disposal.
3. If the row changed after the hint or otherwise does not match, the already-
   staged file is available. Apply it through the existing transactional
   `pdfCache` upsert and post-commit displaced-file cleanup.

Phase 2 remains file-I/O-free, a benign race falls back to the ordinary staged
apply, and no call to `markFetchedChangesApplyFailed()` is introduced. The
optimization avoids replacing and unlinking an identical live PDF; it does
not promise to avoid the temporary staging copy.

This optimization bounds persistent live-file churn, not network or temporary
disk I/O. `CKSyncEngine` may download a `CKAsset` before Rubien receives the
record, and Phase 1 creates a staged copy even for unchanged content. The
rollout UI and release notes therefore describe the first v13 sync as a full
zone replay that may re-download and temporarily stage PDF assets. Progress
and failure remain resumable through the existing durable replay marker. The
current post-commit cleanup invariant is retained: the app never deletes a
displaced local PDF before its replacement has been verified, installed, and
committed, and an unused staged copy is removed only after the transaction
outcome is known.

### 5.6 Ambiguous legacy tombstones

The current delete trigger removes `syncState`, including its system fields,
after creating a tombstone. An unconfirmed pre-v13 tombstone therefore cannot
prove whether its numeric ID named a previously synced record or a local row
that never reached CloudKit. Sending the latter could delete an unrelated
record created by another device.

v13 adds an `isPushEligible` flag to tombstones. Existing unconfirmed
tombstones are migrated as ineligible and are not restored to the engine after
the sidecar reset. This intentionally prefers a reversible resurrection over
an irreversible unrelated delete. `rubien-cli sync status` reports their
count, and release notes explain that a pending pre-upgrade delete may need to
be repeated after the full replay.

New delete triggers set eligibility when either:

- the sync ID is collision-safe (UUID or a compound ID made from
  collision-safe/canonical parents); or
- the legacy identity, including a legacy compound ID, was proven by v13
  classification or a later pull, with matching server system fields still
  present in `syncState`.

The trigger captures that evidence before removing the state row.

Identity migration must also audit every Swift-emitted tombstone; replacing
SQL trigger expressions alone is insufficient. In particular:

- `emitReferencePDFTombstonesIfCached` resolves the owning Reference's sync ID
  before the FK cascade instead of using `String(referenceId)`;
- remote Reference cleanup removes ReferencePDF state/tombstones by the
  incoming Reference sync ID, not by the resolved local row ID;
- terminal-orphan cleanup resolves ReferencePDF and activity identities
  through stored sync IDs;
- activity deletion/rebase paths preserve their already-global record-name
  component; and
- fetched server deletions keep using the incoming record name and mark their
  tombstones confirmed.

The implementation inventory includes both raw `INSERT INTO tombstone` calls
and every `SyncStateStore.upsertTombstone` caller. Each path receives an
eligibility test; no manual emitter is assumed safe merely because it lives in
Swift.

### 5.7 Older-binary behavior

GRDB does not reject a database containing an unknown applied migration during
`migrate()`. Consequently a v12 binary can open a v13 database. v13's
validation triggers are the schema-level backstop: old writes abort instead
of creating rows with empty identities, but the resulting error may not be
friendly in an already-released binary.

The v13 binary calls `DatabaseMigrator.hasBeenSuperseded(_:)` before migration
so it produces a legible “library was upgraded by a newer Rubien” error for
future schema versions.
This cannot retroactively improve already-distributed v12 binaries, so release
notes must explicitly prohibit rollback without restoring the pre-v13 library
root and sidecar together.

The coupled MCP release reviews `mcp-server/src/versionGuard.ts`. Its minimum
CLI build is bumped when the server or its schemas depend on v13 CLI behavior;
regardless of that floor, database compatibility remains enforced in Core,
because an older installed MCP server cannot protect every overridden CLI.

## 6. CloudKit compatibility contract

### 6.1 Additive fields

Keep every existing numeric field permanently. Add string counterparts:

- top-level `syncId` on every record (derived from the natural key for
  Assistant activity, activity epochs, and Reference PDFs that have no stored
  top-level sync-ID column);
- `referenceSyncId`, `tagSyncId`, `propertySyncId`, and `intakeSyncId` as
  applicable;
- `linkedReferenceSyncId` for metadata intake; and
- `referenceSyncId` on `CDReferencePDF`.

The CloudKit schema must be deployed to Production before the binary that
writes these fields. Existing field names and types are not changed.

New encoders always write string fields. They write an old `Int64` field only
when the referenced sync ID is a canonical decimal legacy ID. New decoders
prefer the string field, then convert the old integer to its decimal string as
a fallback. Unknown or unresolved parents enter the existing orphan
quarantine rather than being attached by local row number.

### 6.2 Pull resolution

Remote apply never executes `row.id = Int64(entityId)`. It follows this path:

1. parse and validate the record name;
2. read/derive the opaque sync ID;
3. find the local row by its unique `syncId` index;
4. update that row if found; otherwise insert with a newly allocated local
   integer ID; and
5. resolve every parent string ID to its local integer FK before inserting a
   child.

The record name, not a numeric payload field, is authoritative for the row's
identity. Payload `syncId` is a consistency check. Parent fields remain plain
strings rather than `CKRecord.Reference`s.

### 6.3 Mixed-version behavior

| Scenario | Expected behavior |
|---|---|
| v13 reads a legacy record | Derives numeric sync ID, decodes numeric FKs, and preserves its record name |
| v13 edits a v12-readable legacy record | Updates the same record locally, but does not send it until the writer-upgrade interlock is released |
| v13 creates a UUID-named row | Sends it normally; no local row ID appears on the wire and v12 skips it |
| v13 creates a pivot/activity ID that v12 can parse | Queues it behind the interlock even if the row itself was created by v13 |
| v13 deletes a UUID-named row | Sends the safe delete normally; v12 never materialized that identity |
| v12 reads a UUID record | Skips it because its entity ID is not `Int64`; it cannot overwrite it |
| v12 creates a numeric record | v13 resolves the numeric value as a legacy sync ID, never as a local row address |
| v12 later upgrades | v13 resets its cursor and replays all UUID records it previously skipped |

The compatibility boundary is asymmetric. A v12 peer skips UUID-named rows,
so it cannot overwrite those rows. It can still misapply an edit to a
grandfathered numeric record by assigning the incoming number to an unrelated
local row—the original bug on the old device. “Degraded visibility only” is
therefore not a valid blanket claim.

After v13 migration, a local `writerUpgradeRequired` gate filters only record
identities that v12 can parse into local integer addresses. A pure
`SyncEntityType.isUnsafeForV12(entityId:)` classifier exactly mirrors the old
dispatch grammar:

- canonical decimal IDs are unsafe for Reference, Tag, PDF/Web Annotation,
  Metadata Intake/Evidence, PropertyDefinition, PropertyValue, DatabaseView,
  and ReferencePDF;
- ReferenceTag is unsafe when both endpoint components are decimal; and
- ReadingActivity is unsafe when its four-part legacy grammar contains a
  decimal reference component.

AssistantActivity's existing global ID and ActivityEpoch's natural key are
explicitly safe. UUID and compound IDs that the v12 parser rejects are also
safe. Unknown or malformed shapes default to blocked, not assumed safe.

While the gate is set, startup restoration and `ingestPendingChanges` leave
unsafe work in SQLite rather than adding it to CKSyncEngine's pending queue.
`nextRecordZoneChangeBatch` also applies the predicate to both saves and
deletes before constructing the batch, and repeats the save guard in the
record provider closure as defense in depth. This avoids a send loop driven by
permanently unbatchable engine state. Safe traffic continues normally while
hazardous dirty rows and tombstones accumulate durably. Acknowledgement calls
`ingestPendingChanges` to enqueue the released work. The user confirms that
every older writable Mac has been upgraded or taken offline to release the
filter. The app presents this as a one-time sync-upgrade step; CLI status
exposes it, and the CLI may acknowledge it only through an explicit command.
It is never cleared merely because one v13 device finished its own migration.

This interlock prevents a v13 legacy edit from reaching a known-old peer. It
cannot stop an already-running v12 peer from reproducing the pre-existing
v12↔v12 collision, so release messaging says **upgrade or stop every writable
peer before resuming v12-readable sends**. iOS remains read-only through this
rollout.

## 7. Saved views and embedded identities

`databaseView` cannot be made portable by changing only its row identity.
Several JSON fields currently embed local IDs:

- `ViewScope.tag(Int64)`;
- `FieldTarget.custom(Int64)` in filters, sorts, and grouping;
- tag IDs inside `FilterValue.selectKeys`;
- tag IDs inside group `customOrder` and `collapsed`; and
- custom-property IDs encoded in `columnWrapsJSON` customization keys.

This codec cannot be deferred. v12 accidentally makes legacy view JSON
portable by inserting pulled rows at `Int64(entityId)`, so peers often share
the same local numbering. v13 intentionally inserts a newly pulled sync ID at
an independently allocated local integer; without translation, a fresh v13
device would resolve an otherwise valid synced view to unrelated local tags or
properties.

Add portable **CloudKit-only** fields rather than changing the local SQLite
schema or UI model in this migration:

- `scopeSyncJSON`;
- `filtersSyncJSON`;
- `sortsSyncJSON`;
- `groupBySyncJSON`; and
- `columnWrapsSyncJSON`.

The portable codec replaces each embedded tag/property local ID with its sync
ID on push and resolves it back to the receiving library's local ID on pull.
It understands the target type before translating select/group keys, so normal
string option values are never mistaken for IDs.

The original JSON fields stay in the CloudKit schema. For an existing legacy
view, they are mirrored only when every embedded identity can be represented
losslessly as a canonical decimal legacy ID; otherwise a new peer updates only
the portable fields and preserves the old record's legacy fields. An old peer
then sees a stale view definition instead of a definition that points at the
wrong local rows.

Because portable views depend on Tags and PropertyDefinitions, `databaseView`
moves after both in pull dependency order. A view with unresolved dependencies
is quarantined and retried after the batch, matching other FK-bearing records.
CloudKit-only fields may appear in `allFieldNames`/mapping-specific coverage
without a SQLite column: `SyncSchemaInvariantTests` enforces the safe direction
(`table columns ⊆ record fields`), so the portable wire projection does not
need fake local columns.

## 8. Duplicate and uniqueness reconciliation

UUIDs distinguish independently created rows; they do not guarantee that two
rows have different user-visible values. Local uniqueness constraints still
need deterministic handling. Every winner function below is a pure function
of normalized identities and resolved endpoints. It never consults local
confirmation, dirty state, replay state, writer-upgrade acknowledgement,
timestamps, or local row IDs; peers applying the same identities must choose
the same winner forever.

No v13 allocator emits a canonical decimal ID. A decimal contender is
therefore necessarily a grandfathered legacy identity from migration or a
server record, not a newly invented local row address.

- References with matching DOI/URL/title are kept as separate records. No
  automatic semantic merge occurs in v13.
- Tags that collide on unique `name` use the existing re-parenting strategy,
  but compare sync identities rather than row IDs. A canonical decimal legacy
  ID always beats a non-decimal ID; two decimal IDs compare by numeric value;
  otherwise the lexicographically smaller normalized sync ID wins. The losing
  server identity receives an eligible tombstone only when deletion is proven
  safe. Confirmation affects cleanup eligibility, never winner selection.
- Built-in PropertyDefinitions reconcile by `defaultFieldKey`. A canonical
  decimal legacy identity always wins; among multiple decimals the numerically
  smaller wins; absent a decimal, the lexicographically smaller normalized
  sync ID wins. The seeded local row adopts that winner; an unconfirmed losing
  state entry is removed, while an observed/confirmed losing server identity
  is retired only with an eligible exact-name tombstone. Custom definitions
  reconcile by sync ID with unique-name conflicts handled explicitly.
- The seeded default view applies the same adopt-and-retire rule by its
  `isDefault` role: decimal identities precede non-decimal identities,
  multiple decimals compare numerically, and other identities compare
  lexicographically.
- ReferenceTag already uses an endpoint pair before and after v13. Once its
  legacy integer endpoints resolve to parent sync IDs, repeated creation is
  idempotent.

PropertyValue requires a separate rule because its legacy identity is a
surrogate integer (`propertyValue:55`) while its v13 identity is the endpoint
pair (`propertyValue:<referenceSyncId>/<propertySyncId>`). The local table's
`UNIQUE(referenceId, propertyId)` constraint is resolved before insert:

1. Decode both parent sync IDs and resolve the local `(referenceId,
   propertyId)` pair.
2. If no row owns the pair, insert with the incoming identity.
3. If the pair exists under the same identity, update normally.
4. If the pair exists under a different identity, choose the canonical
   identity by a permanent total order: a canonical decimal legacy ID always
   wins over a non-decimal ID; two decimals compare by numeric value; absent a
   decimal, the exact ID derived from the resolved canonical parent sync IDs
   wins; any remaining malformed/noncanonical tie falls back to lexical order.
5. Apply the incoming scalar value using the existing conflict policy. If the
   local row adopts the incoming identity, move its bookkeeping atomically. If
   the local identity remains canonical, mark that canonical row dirty so the
   value is written there.
6. Remove an unconfirmed losing state entry without a server delete. For a
   losing identity observed or confirmed on the server, queue an eligible
   tombstone for that exact record name.

This rule covers both arrival orders: a local derived value before legacy
`propertyValue:55` arrives, and a derived server record arriving where a
legacy value already owns the pair. It prevents the unique constraint from
rolling back every future fetch batch.

Reconciliation must re-key child numeric FKs and shadow sync IDs in one
transaction. It must never silently relabel children by overwriting whichever
row happens to occupy the incoming numeric ID.

## 9. Mutation and API changes

A Foundation-only `SyncIdentifier` helper in `RubienCore` owns UUID allocation,
normalization, compound construction, and validation. Identity allocation
happens inside the same AppDatabase transaction as insertion. Production
mutation paths may not rely on `didInsert` to discover a local row ID and then
derive a sync identity from it.

Models with stored identities gain `syncId` properties and GRDB columns.
Public CLI `get`, `list`, and Rubien JSON export include `syncId` additively,
and `Docs/CLI-Reference.md` documents it. Existing numeric `id` selectors keep
their current local semantics in v13; accepting sync IDs as selectors is a
separate ergonomic follow-up.

The browser native-messaging response may continue returning a numeric local
reference ID because the extension and host address the same local library.
Its import transaction must nevertheless allocate the reference UUID before
the insert commits.

The v13 migration writes `writerUpgradeRequired = true` into the local
`syncSession` store. The sync coordinator checks this state at the final
outbound boundary, not only in UI commands: queue ingestion withholds unsafe
work, and `nextRecordZoneChangeBatch` defensively excludes saves/deletes for
which `isUnsafeForV12(entityId:)` is true while continuing to emit provably
safe global-identity traffic. The acknowledgement API is an explicit local
operation that records its time and the current identity schema version for
diagnostics, then enqueues the released SQLite work. It does not infer fleet
state from CloudKit, and neither a successful fetch nor completion of the
full-history replay clears it.

`rubien-cli sync status` adds:

- identity schema version;
- counts by identity shape (UUID, legacy, and compound/natural) and entity
  type;
- unresolved global-FK count;
- ineligible legacy tombstone count;
- whether the mandatory full replay is pending;
- whether v12-readable outbound work is waiting for the all-writers-upgraded
  acknowledgement, including blocked save/delete counts; and
- the acknowledgement timestamp and schema version, when present.

The app exposes the same distinction between “replay pending” and “some legacy
edits and relationships are waiting”; it must not claim that all sync is
paused while safe new records continue.

`rubien-cli sync acknowledge-writer-upgrade` requires explicit confirmation
text and explains that releasing the blocked work is safe only after every
writable Mac has v13 or is offline. Local dirty rows and tombstones remain
inspectable while the gate is set.

User-facing copy includes a concrete boundary example: during the gate,
creating a paper, creating an annotation on an existing paper, and setting a
previously unset property sync normally because their new record IDs are
rejected by v12. Editing a grandfathered numeric annotation or PropertyValue
waits. Applying an existing legacy tag to an existing legacy paper also waits
because `<decimalReference>/<decimalTag>` is v12-readable; applying a newly
created UUID tag to that same paper syncs normally.
Attaching a PDF to a grandfathered numeric Reference waits because
`referencePDF:<decimalReference>` is v12-readable; attaching one to a newly
created UUID Reference syncs normally.

No titles, URLs, annotation text, or other library content is logged as part
of collision diagnostics.

## 10. Rollout

1. Deploy all additive string fields to the CloudKit Development schema; run
   record round-trip and mixed-shape tests.
2. Deploy those fields to Production before distributing the v13 binary.
3. Before the first v13 launch, follow `Docs/Sync-Runbook.md`: quit Rubien and
   copy the entire resolved library root, including SQLite WAL/SHM files, PDFs,
   metadata artifacts, and `sync-engine-state.bin`. Keep that backup until the
   migration and full replay are verified.
4. Ship the migration/dual-reader release with the durable full replay enabled
   and the writer-upgrade filter engaged. Fetch, local editing, and safe UUID
   traffic continue; only v12-readable hazardous saves and deletes accumulate
   without being sent.
5. Require every writable Mac to upgrade to v13 or be taken offline. The user
   then explicitly acknowledges that fleet condition on each v13 library,
   which releases that device's legacy-traffic filter. Do not release it
   automatically from a fetch result, replay completion, elapsed time, or peer
   inference.
6. Surface replay progress and explain that the first v13 sync may redownload
   and temporarily stage PDF assets. Identical live PDFs are retained by
   content hash and the staged copies are discarded as specified in §5.5. A
   failed or interrupted replay resumes from durable state.
7. Do not instruct users to reset their library or delete the zone. Support
   guidance for a still-active v12 writer is to stop or upgrade that peer,
   fetch again on v13, and inspect collision diagnostics before resuming
   v12-readable sends.
8. If archive classification exceeds the automatic threshold, stop. Record
   the aggregate counts, preserve the unchanged v12 root, and report the
   failure. Continue on v12 or restore the complete pre-v13 backup; do not
   clear system fields, reset the local library, or delete the CloudKit zone.
9. Keep iOS `SyncAccessMode.replicaReadOnly` until the iOS build includes v13,
   dual FK decoding, portable saved views, replay handling, and collision tests.
10. Enable iOS writes only in a later, separately reviewed change. No CloudKit
   re-key is required for that enablement.

This is a forward-only local migration. Rolling back means quitting Rubien and
restoring the pre-v13 library root and sync sidecar together from backup. An
older binary must not be used against a v13 database. The v13 validation
triggers are the last-resort protection against missing identities, but—as
§5.7 notes—already-shipped v12 binaries cannot present a purpose-built schema
compatibility error.

## 11. Verification

### 11.1 Required regression tests

- **Reported collision:** device A has server-backed `reference:1796`
  KnapFormer; device B has never-synced local row 1796 containing the LinkedIn
  article. After v13 plus pull, both references and the LinkedIn web content
  remain.
- **Two fresh devices:** both allocate local row 1 offline, exchange records,
  and finish with two references under different UUIDs.
- **Legacy edit:** a server-backed numeric record retains its record name,
  change tag, children, and PDF after migration and edit. Its save remains
  queued until the writer-upgrade gate is explicitly acknowledged.
- **Skipped-then-upgraded:** a v12-shaped cursor advances past UUID records;
  v13's forced replay fetches and applies them.
- **Legacy old writer:** a new numeric record from a v12 peer inserts beside a
  UUID row even when its numeric value equals that row's local ID.
- **Selective outbound interlock:** after migration, fetched records and local
  edits work. UUID saves and deletes leave
  `nextRecordZoneChangeBatch`, while decimal, legacy-pivot, and
  legacy-reading-activity shapes remain durable only in SQLite. Replay
  completion does not clear the gate; explicit acknowledgement enqueues and
  releases those shapes without requiring another edit.
- **Ambiguous delete:** an unconfirmed pre-v13 numeric tombstone is not sent;
  full replay cannot delete an unrelated server record.
- **Proven delete:** deleting a pulled legacy row still sends and confirms the
  correct tombstone.
- **Unchanged PDF replay:** redelivering a `CDReferencePDF` with matching
  `contentHash`, asset version, and an existing cached file updates sync state
  without unlinking or replacing the live file; the staged duplicate is
  removed after commit.
- **PDF fast-path race:** a reuse hint followed by a changed `pdfCache` row
  falls back to the already-staged ordinary apply, commits normally, and does
  not request CKSyncEngine recovery.

### 11.2 Graph and invariant tests

- Round-trip every entity with UUID and legacy record shapes.
- Resolve ReferenceTag, PropertyValue, annotations, metadata intake/evidence,
  reading activity, and PDF records onto different local integer IDs.
- Exercise cascade deletion after the parent row is gone and verify child
  tombstones retain global identities.
- Inventory every manual tombstone emitter and verify ReferencePDF, terminal
  orphan, activity, fetched-delete, and remote-parent cleanup paths use the
  original global record name with the correct eligibility.
- Translate saved-view scope, custom targets, tag filter/group keys, and wrap
  keys between databases with deliberately different local IDs.
- Apply PropertyValue legacy and endpoint-pair records in both arrival orders;
  verify identity adoption/retirement, scalar conflict handling, exact
  loser tombstones, and no `UNIQUE(referenceId, propertyId)` fetch wedge.
- Apply the same Tag/PropertyValue/built-in conflicts on peers with different
  confirmation state and writer-upgrade acknowledgement; every peer must pick
  the same winner and must not tombstone the other's winner.
- Reconcile built-in PropertyDefinitions and the default view when independently
  seeded UUID identities meet, and when a UUID meets a canonical decimal legacy
  identity; verify every peer chooses the same winner and retires the loser
  safely.
- Store an activity quarantine entry whose reference is not yet local, replay
  it after that global reference arrives, and remove it by global identity on
  fetched deletion.
- Verify unknown enum cases retain existing safe fallbacks.
- Verify `syncId` uniqueness, non-empty validation, immutable update guards,
  and global-FK/local-FK consistency.
- Extend `SyncSchemaInvariantTests` for every added synced column and CloudKit
  field, while allowing the explicitly CloudKit-only portable-view fields.
- Add v12-to-v13 migration tests for fresh, server-backed, dirty-unsynced,
  mixed, orphan-quarantine, activity-quarantine, PDF, activity, and tombstone
  states. Verify every rewritten `syncState` row clears `pushInFlight` and the
  existing `fullHistoryReplayPending` lifecycle is reused; an unconfirmed key
  rewrite must also clear stale system fields and become dirty.
- On Apple, classify exact archived system fields as proven legacy and treat a
  corrupt archive, record-type mismatch, or record-name mismatch as
  unconfirmed. Exercise the cohort threshold immediately below and above its
  boundary, including a broad archive-format failure that aborts atomically.
  The classifier must not contact a CloudKit container.
- On Linux, migrate a database with no non-null system fields successfully;
  when any exist, throw `requiresAppleIdentityMigration` before the first
  schema/data change and verify the transaction leaves the database logically
  unchanged.
- Open a v13 fixture with the oldest test harness that can model v12 writes and
  verify validation triggers abort missing-identity inserts. Verify the v13
  `hasBeenSuperseded` preflight rejects a simulated future migration with a
  legible error.
- Keep CLI JSON/error contracts, browser-host import tests, Linux Core/CLI
  builds, and macOS sync tests green.
- Account for the known full-suite ActivityRecordTests deadlock documented in
  repository history (`326411c`, clean-main reproduction dated 2026-08-08) by
  running its affected test alone and the broader suite with that class
  skipped.

### 11.3 Acceptance criteria

The feature is complete when:

1. no new syncable row or relationship encodes a local SQLite ID in its record
   name or new FK fields;
2. a pull resolves rows exclusively by sync ID and cannot overwrite a row
   merely because its local integer equals a remote legacy ID;
3. all legacy Production records remain readable and editable;
4. Apple migration proves legacy identity only from a matching decoded record,
   aborts without mutation when archive failures exceed the bounded cohort
   threshold, while Linux either migrates a never-synced database or fails
   atomically;
5. an upgraded peer recovers UUID records skipped before upgrade using the
   existing durable replay state machine;
6. no v12-readable hazardous v13 save or delete is sent before the explicit
   all-writers-upgraded acknowledgement, while UUID traffic is not
   unnecessarily blocked;
7. ambiguous legacy deletes cannot be sent automatically, and every manual
   tombstone path uses a global identity;
8. Tag, PropertyValue, and seeded built-in collisions use a permanent
   identity-only winner function and converge without violating a local
   uniqueness constraint or deleting an unproven server identity;
9. quarantined activity, PDF, annotation, metadata, and pivot relationships
   resolve parents by global identity rather than a foreign local row ID;
10. an unchanged materialized PDF is not replaced during full replay, and a
    reuse-hint race falls back to the staged apply without engine recovery;
11. portable saved views resolve correctly across divergent local IDs;
12. the reported LinkedIn/KnapFormer sequence passes as an automated test; and
13. no production migration wipes or rebuilds the user's library from cloud.

## 12. Proposed implementation slices

Implementation should begin only after this design is reviewed and accepted.
Before slice 1, refresh this worktree onto the intended integration base and
ensure its checked-in `AGENTS.md` includes the verification guidance from
`326411c`; this worktree's current base predates that commit.

Use one coherent, buildable commit per slice:

1. Add `SyncIdentifier`, extract the Apple local-archive classifier, add the
   cohort and Linux fail-closed preflights, then implement v13
   columns/backfill/validation, trigger replacement, state-key migration, and
   focused atomic Core migration tests.
2. Convert top-level record dispatch to lookup by sync ID and add dual top-level
   CloudKit fields plus legacy/UUID round-trip tests.
3. Convert global FKs and compound entities, including PropertyValue
   adopt-and-retire, activity quarantine, activities, PDF materialization, and
   every SQL- or Swift-emitted cascade tombstone.
4. Add seeded built-in reconciliation plus portable saved-view wire codecs and
   dependency ordering.
5. Reuse the durable sidecar-reset/full-replay state machine, add the two-phase
   unchanged-PDF fast path, ambiguous tombstone eligibility, the selective
   v12-readable writer-upgrade filter, and app/CLI status and acknowledgement
   flows.
6. Update CLI JSON/docs, review the MCP CLI-build floor and rollback messaging,
   and add mixed-version, old-binary, cross-platform, and end-to-end collision
   verification.
7. Run the repository's independent correctness review, three simplify
   reviews, final build/tests, and worktree app verification before commit or
   publication.

## 13. Rejected alternatives

### Assign deterministic identities to seeded built-ins

A reserved identity such as `builtin:<defaultFieldKey>` would let two fresh
installations seed the same built-in CloudKit record. It would not eliminate
reconciliation: v13 must still merge those rows with existing numeric
built-ins, and it must reconcile simultaneous or corrupt duplicates by
`defaultFieldKey` or the default-view role. Giving seeded built-ins random
UUIDs keeps one allocation model for independent rows; the required
decimal-first, then lexical winner rule handles both fresh/fresh and
fresh/legacy encounters and exercises the same path in normal use.

### Pre-build an archive-repair override

The cohort preflight addresses an unobserved, likely platform-wide CloudKit
archive incompatibility. A migration-bypassing writer, acknowledgement digest,
CLI command, and recovery UI would add permanent high-risk machinery before
the actual failure shape is known. v13 instead fails before mutation, reports
aggregate counts, and relies on the already-required complete pre-v13 backup
and continued v12 operation. If this failure occurs, recovery should be
designed from the real evidence rather than a speculative bypass.

### Rely only on release notes for the writer upgrade

Release notes cannot detect or contain a v12 peer that remains active. In
particular, a v12 peer can silently misapply a v13 edit to a grandfathered
numeric record without writing any record that reveals its presence. The
selective interlock is retained because Rubien is used across multiple Macs
and this class of cross-device identity failure has already occurred. Its
per-entity classifier is also the inexpensive part of the feature and lets
UUID traffic continue while only v12-readable shapes wait.

### Replace every SQLite primary key with UUID text

This would make local and global identity identical, but it would also rewrite
every FK, FTS integration, CLI selector, view model, and UI selection path in
one migration. It increases migration and rollback risk without improving the
CloudKit guarantee over a unique immutable `syncId` beside the surrogate key.

### Prefix the device ID onto the current row ID

`<installation>/<rowId>` avoids collisions but exposes device identity,
complicates restored libraries, and makes identity depend on installation
state. Random UUIDs provide the same uniqueness with fewer semantics.

### Derive reference identity from DOI or URL

Many references lack either value, identifiers can be corrected, and two
records may intentionally refer to the same work. Mutable bibliographic
metadata is unsuitable as a primary identity.

### Re-key every existing CloudKit record to a UUID

CloudKit has no record-ID rename. Creating UUID copies and deleting legacy
records would double the live graph during rollout, break old peers, invalidate
change tags, and require a failure-prone cross-record transaction protocol.
Grandfathering proven legacy IDs is safer and still removes collisions from
all new writers.

### Fix only Reference record names

The immediate symptom would disappear, but numeric tag/property/annotation
IDs and saved-view JSON could still attach data to unrelated rows. Identity
must be graph-wide to be durable.
