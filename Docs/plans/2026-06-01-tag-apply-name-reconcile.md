# Tag Apply Name-Reconcile — Fix Plan

**Goal:** Stop a `UNIQUE(tag.name)` collision during remote apply from rolling back the entire fetched batch (which silently wedges all sync on a device). Reconcile tag-name collisions the way `PropertyDefinition` already reconciles built-ins.

**Status:** IMPLEMENTED on branch `fix/sync-tag-name-reconcile`. Reconcile + Bool-gated `markPulled` + empty-name skip landed in `SyncEntityDispatch.swift` / `SyncedLibrary.swift`; 7 tests RED→GREEN-verified; full suite **801/0**. Codex impl-review (pass 5, gpt-5.5) on the actual diff found 3 real issues (now fixed, see v5) the 4 plan-level passes couldn't see. Pending: a confirming codex pass on the v5 diff, then commit + DMG.

## Revision history

- **v5 (post-codex impl-review on the real diff):** The 4 prior passes reviewed the *plan*; this one reviewed the *implementation* and caught 3 issues invisible at plan level (they live in the interaction with the push/dirty-tracking side). **(1, MAJOR)** the re-keyed loser pivots got **no `syncState` row** (the dirty trigger is suppressed under `applyingRemote`), so the local device's own tag associations would **never push** → lost on other devices. Fix: dirty each re-keyed pivot by hand (`INSERT … syncState … isDirty=1 ON CONFLICT …`). **(2, MAJOR)** the v4 empty-name guard was a *skip path*, and the loop's `markPulled` is unconditional — so a skipped malformed record still stamped sync-state, clobbering a pending local edit on an occupied row (the exact pass-2 problem, re-introduced). Fix (user chose "Bool-gate"): `applyRemoteRecord` now returns `Bool` (`@discardableResult`), `false` on every skip path (malformed id/record, empty-name, referencePDF-no-prep); **both** call sites (`SyncedLibrary.swift:909` + the `serverRecordChanged` merge ~1165) gate `markPulled` on it. This also fixes the latent malformed-`entityId` cases that previously got a spurious `markPulled`. **(3, MINOR)** re-keyed pivots inherited the incoming *tag's* `dateModified`; now each pivot's own `dateModified` is carried through verbatim (`DatabaseValue`, no decode/encode). Tests: test #1 gained dirty + dateModified-preservation assertions (with a sentinel pivot timestamp to discriminate); new **test #7** pins the Bool-gate (empty-name through the real loop must not clobber an occupied dirty row's name or `isDirty`). Codex confirmed FK ordering, `LIKE '%/'||loserId` safety, and the Option-A overwrite path were all correct.
- **v4 (post-codex pass-3 REWORK):** Pass 3 confirmed the Option A *design* is correct (the unconditional `markPulled` is dissolved across all 3 branches — its finding #5) but flagged TEST/cleanup gaps. Applied: **(#1)** added a **delete-free batch test** through `applyFetchedRecordsForTest` so the **FK-OFF** orphan-tolerance path is exercised — test #3 carries a deletion and therefore only hits the **FK-ON** branch (`SyncedLibrary.swift:779` splits on `deletions.isEmpty`), so it never proved loser-pivot cleanup in the mode where `ON DELETE CASCADE` does NOT fire and the explicit `DELETE` is the *only* cleanup. **(#2)** added **`referenceTag` tombstone cleanup** to the reconcile (symmetric with the existing tag-tombstone cleanup) + a test that pre-seeds and asserts it. **(#3)** added a batch-level occupied-rowID test asserting `markPulled` populated `syncState(tag, incomingId)` *through the real apply loop* (pins the v2-blocker resolution, not just the data outcome). **(#4)** documented that the occupant's own pivots survive at `incomingId` (silently re-labeled) — already asserted in test #2. **(#6)** folded in a **defense-in-depth empty-name skip** in the `.tag` apply: a missing/blank name is a malformed record (per `TagRecord.init(record:)` doc), and persisting `""` would itself trip `UNIQUE(name)` and wedge a later batch — same wedge class, same method, trivial guard, no legitimate-case downside. Custom-`PropertyDefinition` + general per-record batch isolation remain deferred follow-ups (codex: higher blast radius).
- **v3 (design decision — Option A):** Resolved the v2 open fork on the double-divergence corner (incoming rowID already occupied by an *unrelated* tag). **Chose Option A: drop the guard — let the reconcile overwrite the occupant.** Rationale: (a) it is exactly what the existing plain-rowID upsert already does on any rowID collision today, so it adds **no new data-loss class**; (b) it keeps `markPulled(incomingId)` correct (the incoming record IS applied at incomingId — no skip to plumb), so **no change to `SyncedLibrary`'s apply loop**, directly dissolving codex pass-2's blocker (a bare `return` from `applyRemoteRecord` would still have been followed by an unconditional `markPulled`); (c) the double-collision (name AND rowID) is the already-deferred **A-pks** corner. Cost: a lost bystander tag in that corner (its references silently re-label to the incoming tag — no *reference* is ever deleted). Test #2 rewritten from "skip/no-corruption" to "overwrite/no-wedge".
- **v2 (post-codex REWORK):** Codex review of v1 returned REWORK. Applied: (#1, blocker) added a **double-divergence guard** — if the incoming rowID is already occupied locally by an unrelated (different-named) tag, *skip* the reconcile rather than overwrite/corrupt it (v1 would have silently renamed the occupant). (#2) added **explicit `syncState`/`tombstone` cleanup** for the deleted loser tag + its pivots, since `applyingRemote` suppresses the cleanup triggers. (#3) dropped the FK-broken dedup test. (#4) added the occupied-rowID guard test + a syncState-cleared assertion. (#5) the parallel **custom-PropertyDefinition** name-collision gap is *filed* as a tracked follow-up (below), not folded in (codex: higher blast radius — `propertyValue` + view JSON cascade). Codex confirmed adopt-incoming + the FK-safe ordering + the convergence/ping-pong reasoning are correct.

---

## Bug (confirmed, reproduced on the mini)

Mini log: `applyFetchedZoneChanges failed: UNIQUE constraint failed: tag.name — INSERT INTO "tag" (...)`. The mini **was** fetching (Layer A works), but the apply transaction threw on a tag-name collision and **rolled back the whole batch**, so it applied nothing — not the tag, not an unrelated reference deletion. Total sync wedge.

- `SyncEntityDispatch.applyRemoteRecord` `.tag` case (`SyncEntityDispatch.swift:337-341`) does a plain rowID upsert with **no name reconcile**.
- Contrast `.propertyDefinition` (`:376-407`), which reconciles built-ins by the stable `defaultFieldKey` (keeping the *local* rowID) precisely to dodge this `UNIQUE(name)` wedge.
- Trigger here: the `acceleration` restore minted a new rowId (155) while the mini still held the old `acceleration` at a different rowId → `INSERT(155, "acceleration")` collides.

Layer A makes this **reachable in normal incremental sync** (before, devices barely fetched). Same family as the v0.1.5 built-in `PropertyDefinition` collision fix.

## Design

Reconcile by name inside the `.tag` apply case. **Adopt the INCOMING rowID** (not keep-local like PropertyDefinition), because:
- Tags have pivot children (`referenceTag.tagId`), and the incoming fetch carries `referenceTag` records that reference the **incoming** tagId. Keeping the local rowID would orphan those incoming pivots (FK-fail). PropertyDefinition can keep-local only because the divergent built-ins "carry no propertyValues" (its own comment) — tags don't have that luxury.
- There is no stable secondary key for tags (only `name` + a divergent rowID), so we converge on the incoming identity.

**FK-safe ordering** (must be correct whether FK enforcement is ON — direct unit-test apply — or OFF — the batch apply's orphan-tolerance window, where `ON DELETE CASCADE` does *not* fire):

```
row = Tag(record:); row.id = :incomingId
// DEFENSE-IN-DEPTH (codex pass-3 #6): a missing/blank name is a malformed or
// forward-incompat record (see TagRecord.init(record:) doc). Skip persistence
// rather than upsert a "" that would itself trip UNIQUE(name) and wedge a later
// batch. The caller's unconditional markPulled still runs → a harmless orphan
// syncState row (same shape as a divergent-builtin PropertyDefinition's), never
// pushed (isDirty=0). Same wedge class, same method as the reconcile below.
if row.name.isEmpty: return

loserId = SELECT id FROM tag WHERE name = :name AND id <> :incomingId   // name collision?
if loserId:
    // OPTION A (user-approved): NO guard on an occupied incoming rowID. If a
    // different tag already sits at :incomingId, the upsert below OVERWRITES it.
    // We deliberately accept this because:
    //   - it is exactly what the existing plain-rowID upsert already does on any
    //     rowID collision today → no NEW data-loss class, and
    //   - the double-collision (name AND rowID) needs two independent rowID
    //     divergences at once → the already-deferred A-pks corner.
    // Benefit: markPulled(incomingId) stays correct (incoming IS applied at
    // incomingId) → zero change to SyncedLibrary's apply loop. Cost: a lost
    // bystander tag in that corner; its refs silently re-label (no ref deleted).
    refIds = SELECT referenceId FROM referenceTag WHERE tagId = loserId  // capture children
    DELETE FROM referenceTag WHERE tagId = loserId                       // explicit (cascade off during apply)
    Tag.deleteOne(loserId)                                               // frees the name
    // CLEANUP: triggers are suppressed under applyingRemote, so clean the loser's
    // stale bookkeeping explicitly (else an orphan syncState keeps referencing
    // the gone rowID).
    DELETE FROM syncState WHERE entityType='tag'          AND entityId = loserId
    DELETE FROM tombstone WHERE entityType='tag'          AND entityId = loserId
    DELETE FROM syncState WHERE entityType='referenceTag' AND entityId LIKE '%/'||loserId
    DELETE FROM tombstone WHERE entityType='referenceTag' AND entityId LIKE '%/'||loserId  // symmetric (codex pass-3 #2)
    upsert tag(incomingId, …)                                           // UPDATE if occupied (overwrite), else INSERT.
                                                                        // Any pivots the OCCUPANT already had at incomingId
                                                                        // survive unchanged → they silently re-label to the
                                                                        // incoming tag (codex pass-3 #4; A-pks bystander cost).
    for refId in refIds: INSERT OR IGNORE referenceTag(refId, incomingId, now)
    return
upsert tag(incomingId, …)                                               // no name collision → unchanged path (rename of incomingId is fine)
```

Runs under `applyingRemote`, so the trigger guard (`WHERE applyingRemote IS NULL`) suppresses re-dirtying — these rewrites are not pushed back. `INSERT OR IGNORE` handles a reference that already carries the incoming rowID (UNIQUE(referenceId, tagId)). Because the reconcile always lands the incoming record at `incomingId` (Option A — there is no skip path), the caller's unconditional `markPulled(entityId: incomingId)` (`SyncedLibrary.swift:909`) records the incoming server systemFields against the row that genuinely holds them — correct, and the reason no apply-loop change is needed. (This is precisely the codex pass-2 blocker that Option A dissolves: the rejected guard-skip would have left `markPulled` writing the incoming tag's systemFields against the surviving *occupant's* rowID.)

### Convergence / ping-pong analysis
- **Delete+recreate (the mini, and the common case):** the local loser was genuinely deleted on the peer (a tombstone is in-flight), so it is never re-pushed → both devices converge on the incoming rowId. No ping-pong. ✔
- **Pure offline dual-create (same name, two live rowIds):** both rowIds stay in iCloud; each device adopts what it fetches → a one-time, *stable* divergence (records don't re-deliver unless changed, so no infinite churn). This is the **already-deferred A-pks limitation** (memory: "sync one device first … until A-pks ships"). The point of this fix is that it **no longer wedges** — it degrades to the pre-existing A-pks divergence instead of total sync failure.

## Scope (and explicit non-scope)

**In scope:** the `.tag` apply reconcile, a defense-in-depth empty-name skip guard (same whole-batch-wedge class, same method — codex pass-3 #6), and tests.

**Related gaps — NOT in this fix, flagged for a decision:**
1. **Custom `PropertyDefinition`s** (`defaultFieldKey == nil`, e.g. Method/Modality) upsert by rowID with no name reconcile → the *same* `UNIQUE(name)` wedge on a custom-prop name collision. The built-in reconcile doesn't cover them. Lower likelihood (custom-prop dual-create), but identical mechanism.
2. **General batch resilience:** the apply already tolerates FK orphans (FK-off window) but a *constraint* throw still rolls back the whole batch. Per-record isolation would be defense-in-depth against any unforeseen collision.

Recommendation (codex-endorsed): ship the tag reconcile for v0.1.6 (the confirmed, reproduced wedge). **File #1 and #2 as tracked follow-ups** — codex explicitly advised NOT folding custom-PropertyDefinition into this patch (its `propertyValue` + view-JSON cascade is materially riskier), but not silently deferring it either. A memory note + a follow-up plan will track both.

## Tests (written — `TagReconcileTests.swift`, 7 tests)

1. `testTagNameCollisionAdoptsIncomingRowIDAndRekeysPivots` — unit (direct `applyRemoteRecord`): local `accel`@localId + pivot; apply remote `accel`@(localId+1000) → one `accel` at the incoming id, pivot re-keyed, local row gone, incoming color adopted, FK clean, **and the loser's `syncState` (tag + pivot) cleaned**. v5: also asserts the **re-keyed pivot is dirtied** (`isDirty=1`, finding 1) and **preserves its own `dateModified`** (a sentinel timestamp, finding 3).
2. `testIncomingRowIDOccupiedOverwritesOccupant` — unit: the double-divergence corner under Option A. An unrelated `unrelated`@incomingId already exists (carrying its own reference), and the loser `accel`@loserId also carries a reference. The reconcile **overwrites** the occupant — asserts: no throw/wedge; exactly one `accel`, at `incomingId`, incoming color; `unrelated` gone; loser row gone; BOTH references (loser's re-keyed + the **occupant's bystander pivot, silently re-labeled** — covers #4) resolve to `incomingId`; no pivots left on `loserId`; FK clean.
3. `testMixedBatchNoLongerRollsBackOnTagCollision` — end-to-end via `applyFetchedRecordsForTest`, **FK-ON branch** (batch carries a deletion): colliding tag insert + a reference deletion → the deletion applies (batch commits), tag at the incoming id, FK clean. (Pre-fix: the deletion is rolled back — the wedged-mini scenario.)
4. `testDeleteFreeBatchCleansLoserPivotsAndTombstones` — end-to-end via `applyFetchedRecordsForTest`, **FK-OFF branch** (delete-free batch — the path #3 can't reach, where `ON DELETE CASCADE` does not fire so the explicit `DELETE` is load-bearing). Loser carries a pivot AND a pre-seeded stale `referenceTag` tombstone; after apply → reconciled to `incomingId`, **no pivot left on `loserId`**, FK clean, and the loser's pivot `syncState` **and** `tombstone` both cleaned (covers #1 + #2).
5. `testOccupiedRowIDBatchRecordsIncomingSystemFields` — end-to-end via `applyFetchedRecordsForTest`: occupied-incoming-rowID through the **real apply loop**, so the unconditional `markPulled` runs. Asserts the incoming tag is resident at `incomingId` (name overwritten) **and** `syncState(tag, incomingId).systemFields` is non-null — pinning that `markPulled` recorded the incoming record's system fields against the row that genuinely holds the incoming entity (the property the rejected guard-skip would have violated — covers #3).
6. `testEmptyNameRecordIsSkippedNotPersisted` — unit: a malformed record with an empty name is **skipped**, not persisted as `""`; no tag row created, no throw (covers #6).
7. `testEmptyNameRecordDoesNotClobberOccupiedDirtyRow` — end-to-end via `applyFetchedRecordsForTest` (v5, the Bool-gate): an empty-name record for an id occupied by a real **dirty** tag must NOT `markPulled` → the occupied row keeps its name AND its `isDirty=1` (pre-Bool-gate, the unconditional `markPulled` would clear the pending local edit).

## Verification

1. `swift test --filter RubienSyncTests.TagReconcileTests` → RED before the fix (collision throws), GREEN after.
2. Full `swift test` → 0 failures.
3. codex-rescue review of the diff.
4. Rebuild the signed DMG → reinstall on both Macs. The **fixed apply self-heals the mini** (it reconciles `acceleration` on next fetch and unwedges), which re-verifies the fix end-to-end → resume the two-device sync smoke → ship v0.1.6.
