# Sync: fix the cross-batch initial-pull wedge (v5 — refined after 4 Codex passes)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a fresh device's initial CloudKit pull complete instead of rolling back every fetch batch that contains a child whose parent is in a different batch — **without** touching the delete path (which depends on FK cascade) and **without** losing the single-transaction atomicity or the PDF-staging cleanup.

**Approach (chosen): relax FK enforcement only for delete-free batches.** A batch with no deletions (every initial-pull batch, and most incremental "added rows" batches) is applied in **one** transaction with `foreign_keys = OFF`, tolerating transient orphans (a child commits before its parent and becomes valid when the parent arrives in a later batch). A batch **with** deletions keeps today's exact behavior — one FK-**on** transaction so `ON DELETE CASCADE` still drops children. This is the minimal change that fixes the reported bug while leaving the cascade-dependent, atomicity-sensitive paths exactly as they are.

**Tech stack:** Swift 6 (strict concurrency), GRDB 7.10 (`DatabasePool`, async `writeWithoutTransaction<T: Sendable>(_: @Sendable (Database) throws -> T)`, `foreign_keys`/`defer_foreign_keys`), `CKSyncEngine`, `RubienSync`.

---

## Status / history

- **v1** (apply *everything* with `foreign_keys = OFF`) — **rejected**: remote deletes rely on receiver FK cascade (`applyRemoteDelete` `SyncEntityDispatch.swift:410-438`; `recursive_triggers` unset; child tables `ON DELETE CASCADE`), so uniform FK-off orphans children on delete.
- **v2** (two-phase: mods FK-off + dels FK-on, *every* batch) — **rejected by Codex pass 2**: two transactions per batch lose atomicity (mods commit, dels fail → partial) and break the Phase-3 PDF unlink (single `rollbackTriggered` bit would delete files for committed `pdfCache` rows).
- **v3** — relax FK **only for delete-free batches**, single transaction always. Resolves the v2 atomicity + PDF-cleanup holes by never splitting a batch. The residual gap (a batch containing *both* a deletion *and* a cross-batch-orphan modification) stays on today's strict behavior — rare, and **never** the initial-pull case (which has zero deletions).
- **v4** — Codex pass 3 confirmed v3's architecture sound but flagged 2 FK-restore code blockers: a post-commit throw would corrupt Phase 3, and a `try?`-only restore could leave the pooled writer FK-off. Tried: restore via unconditional `defer` + a best-effort `ensureWriterForeignKeysOn()` afterward; `BatchOutcome` promoted to type scope; test stores `Int64` ids.
- **v5** (this) — Codex pass 4: the v4 `defer`+separate-ensure still left an FK-off window (a non-sync write on the serialized writer could run between a swallowed `defer` restore and the later ensure pass). Fixed with **in-band `restoreForeignKeysOrAbort`** (restore + verify before the closure returns; `fatalError` on genuine, near-impossible failure). Also: test `recordType` must be `CDReferenceTag` (the recordName *prefix* `referenceTag` is not the recordType).

---

## Background (root cause, verified on the mini)

CKSyncEngine delivers a zone's records across multiple `FetchedRecordZoneChanges` events with no cross-batch FK ordering. `applyFetchedRecordsInternal` sorts within a batch (`fkDependencyRank`, correct), then runs `PRAGMA foreign_key_check` and `throw CancellationError()` on any violation (`SyncedLibrary.swift:783-787`); a child whose parent is in another batch wedges the pull. Mini log: `FK violations after remote apply: 126 rows — rolling back`. Data is safe (Mac A: 113 refs, all property defs, 422/422 acked).

---

## How each Codex finding is resolved

1. **Atomicity / partial batch** → **single transaction per batch** (no mods/dels split). Delete-free → one FK-off txn; with-deletions → one FK-on txn (unchanged). Same rollback boundary as today.
2. **Phase-3 PDF cleanup across two txns** → moot; one transaction ⇒ the existing `rollbackTriggered`/`outcome` cleanup (`SyncedLibrary.swift:797-818`) is unchanged.
3. **FK-restore robustness** → `restoreForeignKeysOrAbort` restores + verifies **in-band on both paths** inside the FK-off closure (the serialized writer can't hand the connection to another write before the closure returns ⇒ no interleaving window; no post-commit throw that would corrupt Phase 3). A genuine restore failure `fatalError`s (data-integrity fail-safe, unreachable in practice) rather than swallowing it (leaves the writer FK-off) or throwing (corrupts Phase 3). See Task 2.
4. **Don't extract actor-isolated helpers** → the apply body becomes a **`static`** function (file-scope `log` at `SyncedLibrary.swift:8` is usable from it); call sites capture only `[stateStore]`, never `self`.
5. **Test recordName + nested type** → use the real synced name `"referenceTag:1/2"` (`qualifiedRecordName` = `"<type>:<entityId>"`, pivot entityId = `"<refId>/<tagId>"`, split on first `:` — `SyncEntityDispatch.swift:115-129`), and qualify `SyncedLibrary.FetchedDeletionInput`.

---

## Key facts

- **Apply site:** `SyncedLibrary.swift:676-819`. Phase 1 PDF pre-stage (690-704) and Phase 3 unlink (797-818) are untouched; only the Phase-2 write (715-795) changes.
- **recordName:** synced names are `"<type>:<entityId>"` (`qualifiedRecordName`, `:115-117`); `referenceTag` entityId is the composite `"<refId>/<tagId>"`, so its full name is `"referenceTag:<refId>/<tagId>"`. `parseRecordName` splits on the first `:` (`:122-129`).
- **GRDB:** default `Configuration()` → FK on per connection; `PRAGMA foreign_keys` is a no-op inside a transaction, so the FK-off path uses `writeWithoutTransaction` (async `<T: Sendable>`, `DatabaseWriter.swift:132`) which routes through the serialized `DatabasePool` writer; `db.inTransaction` (sync, non-`@Sendable`, `Database.swift:1511`) wraps the upserts. Mutating a `var local` declared in the `@Sendable` closure from inside the sync `inTransaction` closure is Swift-6-legal.
- **`applyingRemote`:** `setApplyingRemote`/`clearApplyingRemote` must wrap the upserts in the **same** transaction (`SyncStateStore.swift:30-43`; trigger gate `AppDatabase.swift:432-433`). Single transaction ⇒ trivially preserved.
- **Deletes (unchanged path):** `applyRemoteDelete` relies on `ON DELETE CASCADE` (`SyncEntityDispatch.swift:410-438`); the with-deletions branch keeps FK **on**, so cascade is intact.
- **Test hook:** `applyFetchedRecordsForTest` (`SyncedLibrary.swift:826`); pattern in `PDFMaterializationStagingTests.swift:198-227`.

---

## Task 1: Extract the Phase-2 apply body as a `static` helper (behavior-preserving)

**Files:** Modify `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1:** First promote `struct BatchOutcome` out of `applyFetchedRecordsInternal`'s local scope (currently `SyncedLibrary.swift:710-713`) to type or file scope so the `static` helper can name it as a return type. Then move the contents of the current write closure (the mods loop 724-762, deletions loop 764-779, and the `foreign_key_check` block 783-787) into a `static` function. It captures no `self`; `log` is file-scope so it's callable.

```swift
private static func applyRemoteRows(
    sortedMods: [CKRecord],
    deletions: [FetchedDeletionInput],
    preparedPDFs: [CKRecord.ID: SyncEntityType.PreparedReferencePDFMaterialization],
    stateStore: SyncStateStore,
    tolerateOrphans: Bool,
    db: Database
) throws -> BatchOutcome {
    var local = BatchOutcome(displacedFilenames: [], appliedPDFRecordIDs: [])
    try stateStore.setApplyingRemote(db)

    for record in sortedMods {
        // … verbatim from current 724-762 (mutates `local` for PDFs) …
    }
    for deletion in deletions {
        // … verbatim from current 764-779 …
    }

    let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    if !violations.isEmpty {
        if tolerateOrphans {
            log.info("remote apply: \(violations.count, privacy: .public) transient FK orphans tolerated (resolve when parents arrive)")
        } else {
            log.error("FK violations after remote apply: \(violations.count, privacy: .public) rows — rolling back")
            throw CancellationError()
        }
    }

    try stateStore.clearApplyingRemote(db)
    return local
}
```

- [ ] **Step 2:** Make the existing call site call the helper with `tolerateOrphans: false`, FK semantics unchanged, so this step is a pure refactor:

```swift
outcome = try await appDatabase.dbWriter.write { [stateStore] db -> BatchOutcome in
    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
    return try Self.applyRemoteRows(
        sortedMods: sortedMods, deletions: deletions, preparedPDFs: preparedPDFs,
        stateStore: stateStore, tolerateOrphans: false, db: db)
}
```

- [ ] **Step 3:** `swift build` + `swift test --filter RubienSyncTests` → green (no behavior change yet).

---

## Task 2: Branch — FK-off single transaction for delete-free batches

**Files:** Modify `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1:** Add an **in-band** FK-restore guard. It restores + verifies on the writer connection *inside* the `writeWithoutTransaction` closure (so the serialized writer can't hand the connection to another write before FK is back on — closing the interleaving window), and **aborts** if FK genuinely won't re-enable rather than throwing (a throw would flow to the outer catch and corrupt Phase 3) or swallowing (which would leave the writer FK-off):

```swift
/// Restore FK enforcement on the writer IN-BAND. DatabasePool serializes writes
/// on one connection, so restoring before the writeWithoutTransaction closure
/// returns guarantees the next write sees FK=ON — no interleaving window. A
/// restore that won't take means a corrupt writer; abort rather than silently
/// let later local writes persist FK-invalid data. Unreachable in practice —
/// `PRAGMA foreign_keys = ON` is an in-memory flag toggle on a healthy connection.
private static func restoreForeignKeysOrAbort(_ db: Database) {
    do {
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
            log.fault("foreign_keys would not re-enable on the sync writer — aborting")
            fatalError("Rubien: failed to restore foreign_keys on the database writer")
        }
    } catch {
        log.fault("foreign_keys restore threw: \(error.localizedDescription, privacy: .public)")
        fatalError("Rubien: failed to restore foreign_keys on the database writer")
    }
}
```

- [ ] **Step 2:** Replace the single call site (from Task 1 Step 2) with the branch. Restore runs **in-band on both paths** via `restoreForeignKeysOrAbort` — never as a post-commit throw (which would set `rollbackTriggered` and corrupt Phase 3) and never swallowed (which would leave the writer FK-off):

```swift
        do {
            if deletions.isEmpty {
                // Delete-free batch (every initial-pull batch): tolerate transient
                // cross-batch FK orphans. `foreign_keys` can't change inside a txn,
                // so toggle it on the serialized writer around an explicit txn and
                // restore IN-BAND before the closure returns.
                outcome = try await appDatabase.dbWriter.writeWithoutTransaction { [stateStore] db -> BatchOutcome in
                    try db.execute(sql: "PRAGMA foreign_keys = OFF")
                    var local = BatchOutcome(displacedFilenames: [], appliedPDFRecordIDs: [])
                    do {
                        try db.inTransaction {
                            local = try Self.applyRemoteRows(
                                sortedMods: sortedMods, deletions: [], preparedPDFs: preparedPDFs,
                                stateStore: stateStore, tolerateOrphans: true, db: db)
                            return .commit
                        }
                    } catch {
                        Self.restoreForeignKeysOrAbort(db)   // restore, THEN report the apply failure
                        throw error
                    }
                    Self.restoreForeignKeysOrAbort(db)        // success: restore before returning
                    return local
                }
            } else {
                // Batch contains deletions → keep FK ON so ON DELETE CASCADE drops
                // children (unchanged from today; strict foreign_key_check).
                outcome = try await appDatabase.dbWriter.write { [stateStore] db -> BatchOutcome in
                    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                    return try Self.applyRemoteRows(
                        sortedMods: sortedMods, deletions: deletions, preparedPDFs: preparedPDFs,
                        stateStore: stateStore, tolerateOrphans: false, db: db)
                }
            }
        } catch {
            log.error("applyFetchedZoneChanges failed: \(error.localizedDescription, privacy: .public)")
            rollbackTriggered = true
        }
```

Why this is sound: on the **error** path, FK is restored in-band, then the apply error propagates → outer catch → `rollbackTriggered = true` → Phase 3 unlinks staged PDFs (correct — nothing committed). On the **success** path, FK is restored in-band before the closure returns → the serialized writer cannot run another write FK-off → `rollbackTriggered` stays false → Phase 3 sees success. A genuine restore failure `fatalError`s (logged) rather than throwing into the catch or leaving the writer FK-off. Phase 3 (797-818) is unchanged.

- [ ] **Step 3:** `swift build` → clean (watch `@Sendable`/`Sendable` around `local`).

---

## Task 3: Tests

**Files:** Create `Tests/RubienSyncTests/SyncOrphanToleranceTests.swift`

- [ ] **Step 1:** Orphan tolerance — a `referenceTag` child applied alone (delete-free batch) commits; pre-fix it rolled back to 0.

```swift
#if canImport(CloudKit)
import XCTest; import GRDB; import CloudKit
@testable import RubienSync; @testable import RubienCore

final class SyncOrphanToleranceTests: XCTestCase {
    func testOrphanChildCommitsInDeleteFreeBatch() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(/* as PDFMaterializationStagingTests:222 */)
        let child = makeRecord(type: "referenceTag", name: "referenceTag:1/2",
                               fields: ["referenceId": 1, "tagId": 2])
        await library.applyFetchedRecordsForTest(modifications: [child], deletions: [])
        let n = try await db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM referenceTag") }
        XCTAssertEqual(n, 1)                       // pre-fix: 0 (rolled back)
        // Parents arrive in a later batch → consistent.
        await library.applyFetchedRecordsForTest(
            modifications: [makeRecord(type: "reference", name: "reference:1", fields: refFields(1)),
                            makeRecord(type: "tag", name: "tag:2", fields: ["name": "x"])],
            deletions: [])
        let v = try await db.dbWriter.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }
        XCTAssertTrue(v.isEmpty)
    }

    func testDeleteStillCascades() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(/* … */)
        await library.applyFetchedRecordsForTest(
            modifications: [makeRecord(type: "reference", name: "reference:1", fields: refFields(1)),
                            makeRecord(type: "tag", name: "tag:2", fields: ["name": "x"]),
                            makeRecord(type: "referenceTag", name: "referenceTag:1/2", fields: ["referenceId": 1, "tagId": 2])],
            deletions: [])
        await library.applyFetchedRecordsForTest(modifications: [], deletions: [
            SyncedLibrary.FetchedDeletionInput(recordID: .init(recordName: "reference:1", zoneID: testZoneID),
                                               recordType: SyncConstants.RecordType.reference)])
        let tags = try await db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM referenceTag") }
        XCTAssertEqual(tags, 0)                    // FK-on deletion phase cascaded
    }
}
#endif
```

**Critical helper detail (recordType ≠ recordName prefix):** the apply loop dispatches on `record.recordType` (`SyncedLibrary.swift:724`), which must be the CKRecord type constant `SyncConstants.RecordType.*` — `"CDReference"`, `"CDTag"`, `"CDReferenceTag"` — **not** the bare `reference`/`tag`/`referenceTag` (that's only the recordName prefix). A wrong `recordType` makes `forRecordType` return nil and the record is silently skipped → vacuous test. So `makeRecord` takes (recordType: `SyncConstants.RecordType.referenceTag`, recordName: `"referenceTag:1/2"`, fields). **`referenceId`/`tagId` must be stored as `Int64`** — `ReferenceTag(record:)` decodes `Int64` (`ReferenceTagRecord.swift:73-83`); a plain `Int` decodes to nil and the pivot is silently skipped too. `refFields` mirrors `Reference.populate(record:)`.

- [ ] **Step 2:** `swift test --filter RubienSyncTests.SyncOrphanToleranceTests` → both pass.
- [ ] **Step 3:** FK-restore guard: after the orphan test, assert a normal write rejects an FK violation (proves `foreign_keys` was restored to ON on the writer).

---

## Task 4: Build, suite, review, commit

- [ ] `swift build`; `swift test --filter RubienSyncTests`.
- [ ] `codex-rescue` review of the uncommitted diff; `/simplify`.
- [ ] `git commit -m "sync: tolerate transient FK orphans on delete-free remote applies (fix cross-batch initial-pull wedge); deletes keep FK cascade"`

---

## Task 5: Release v0.1.4 + re-sync the mini

- [ ] `VERSION` → `0.1.4`, `BUILD.txt` → `5`.
- [ ] `RELEASE_NOTES_TEXT="iCloud Sync fix: a fresh Mac now pulls your full library and PDFs instead of stalling partway through the first sync." CODESIGN_IDENTITY="Developer ID Application: Hongkai Zheng (9TXK4V3SS8)" ./scripts/release.sh`
- [ ] Update Mac A (Sparkle) to v0.1.4.
- [ ] Mini: update to v0.1.4 → quit → delete `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/sync-engine-state.bin` → relaunch with sync on.
- [ ] Verify mini reaches **113 refs + property defs (Method/Modality) + PDFs**; log shows `transient FK orphans tolerated` (info), no rollback. Spot-check: delete a reference on Mac A → row + children disappear on the mini (cascade path still works).

---

## Open questions for re-review

1. **Scope = delete-free batches.** Is scoping orphan-tolerance to `deletions.isEmpty` acceptable, given the initial pull (the actual bug) is always delete-free and the delete/cascade path is left untouched? The residual gap is a single batch carrying *both* a deletion and a cross-batch-orphan modification → stays on today's strict (rollback) behavior. Real-world likelihood and is it acceptable to defer?
2. **FK-restore verify.** Restore on both paths + read-back `PRAGMA foreign_keys` on the writer + throw `SyncApplyError.foreignKeysNotRestored` if not 1. Is reading it back on the same `writeWithoutTransaction` connection a valid check, and is throwing (vs. recycling the connection) a sufficient response?
3. **`static` helper.** Confirm a file-private `static func applyRemoteRows(...)` using the file-scope `log` and called from the `@Sendable` GRDB closures compiles cleanly (no actor-isolation capture).
4. **`inTransaction` + `local`.** Confirm assigning `var local` inside `db.inTransaction { … return .commit }` (sync, non-`@Sendable`) from within the `@Sendable` `writeWithoutTransaction` closure is Swift-6-clean.

---

## Rollback / safety

- Receive-path only; no schema/migration/CKRecord/push change. FK enforcement is unchanged for all local writes and for any batch containing a deletion; only delete-free remote applies run FK-off, and FK is restored+verified immediately. Reversible via one commit revert. Mini reset is the documented `sync-engine-state.bin` reset. Source data untouched.
