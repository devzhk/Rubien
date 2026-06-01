# Sync: reconcile built-in PropertyDefinitions by `defaultFieldKey` (fix the prop-def UNIQUE(name) batch-drop)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop a fetched batch from rolling back (and silently dropping its references + custom property values) when CloudKit delivers a built-in `PropertyDefinition` whose rowID differs from the local seeded copy. Built-in defs (Type, Status, …, Last Read, Read Count) are seeded independently on each device, so their rowIDs diverge; syncing them by rowID makes a peer's `INSERT` collide on `UNIQUE(name)`.

**Approach (chosen): receive-side reconcile by `defaultFieldKey`.** On apply, a `PropertyDefinition` record that has a non-nil `defaultFieldKey` (i.e. a built-in) is matched to the local row with the **same `defaultFieldKey`** and updated **in place, keeping the local rowID** — never re-inserted at the remote rowID. Custom defs (`defaultFieldKey == nil`, e.g. Method/Modality) keep today's rowID-keyed upsert. This is the targeted stand-in for the deferred A-pks UUID identity (`PropertyDefinitionRecord.swift:8-10`, `AppDatabase.swift:544-549`).

**Tech stack:** Swift 6, GRDB 7.10, `RubienSync` (`SyncEntityDispatch.applyRemoteRecord`), `RubienCore` (`PropertyDefinition`).

---

## Status / history

- **Prereq shipped:** cross-batch FK fix ([[sync-fresh-device-pull-bug]]) shipped v0.1.4; mini went 22 → 78 refs. This plan fixes the *next* wedge cause.
- **v1 (this):** receive-side `defaultFieldKey` reconcile, scoped to the apply path. No schema/migration/CKRecord/recordName change, no push-side change. Both devices must run the fix (the collision is bidirectional). Server-side duplicate built-in records (from each device's baseline push) are tolerated — they reconcile harmlessly to one local row; the eventual A-pks migration collapses them.

---

## Background (root cause, verified)

`PropertyDefinition` syncs by **rowID** (recordName `propertyDefinition:<rowID>`, `SyncEntityDispatch.swift`). Built-ins are seeded independently per device:
- v1 seed (`AppDatabase.swift:328-375`) creates 28 built-ins at ids **1-28** — these match across devices (same seed order on a fresh DB).
- The **v5 migration** (`AppDatabase.swift:557-573`) adds built-ins **"Last Read" / "Read Count"**. On a *fresh* library they seed at **29/30** (verified: `RUBIEN_LIBRARY_ROOT=/tmp/x rubien-cli list` then `sqlite3 'SELECT id,name FROM propertyDefinition'`); on Mac A's *old* library autoincrement put them at **339/340**.

So when the mini pulls Mac A's "Last Read" (recordName `propertyDefinition:339`), the apply path does `INSERT … id=339` (no local id 339) and trips `UNIQUE constraint failed: propertyDefinition.name` against the local id-29 copy. CKSyncEngine delivers all ~32 prop-defs in one batch; the throw rolls back the **whole transaction**, dropping the custom defs (Method/Modality), their property values, and the ~35 refs in that batch. `applyFetchedRecordsInternal` swallows the error (no rethrow) → token advances → the batch never redelivers. Mini log: `applyFetchedZoneChanges failed: … UNIQUE constraint failed: propertyDefinition.name`. The v5 migration comment (`:544-549`) already documents this and defers it to A-pks.

**Verified invariants (Mac A library + code review):**
- **The only divergent built-ins are Last Read / Read Count.** Built-ins 1-28 are seeded in identical order on every device, so their rowIDs **match** across devices → reconcile resolves them to the *same* rowID (a no-op rowID-wise; remote propertyValues referencing that id stay valid). Only Last Read/Read Count (added by the later v5 migration) land at divergent ids (29/30 fresh vs 339/340 on Mac A).
- **Orphaning safety (narrowed per Codex — the broad claim was wrong).** Reconciling a built-in to a *different* local rowID would orphan that built-in's *remote* propertyValues. That only bites a built-in that is both **divergent** *and* **has propertyValues**. The only divergent built-ins are **Last Read (date) / Read Count (number)**, which carry **no propertyValues** — verified on Mac A (only Method 236 / Modality 237 have any), and by code: `setPropertyValue` (`AppDatabase.swift:3214+`) and Zotero import (`ZoteroImportSupport.swift:57+`) write values for string/url/singleSelect props, not date/number, and the reader-activity fields are projected from `Reference` columns. So reconcile orphans nothing **today**. **Residual (deferred to A-pks):** a *future* divergent built-in that is string/select-typed *and* accrues propertyValues would orphan its remote values — that needs a propertyValue `propertyId` remap, out of scope here.
- Custom defs have **`defaultFieldKey = NULL`**; every seed has a non-null `defaultFieldKey` (`AppDatabase.swift:328,345,562`); custom creation omits it (`PropertyDefinition.swift:63,74`, `RubienCLI.swift:1168`). Reliable discriminator — but a **code-path invariant**, not DB-enforced.
- `propertyValue.propertyId → propertyDefinition(id)` (`AppDatabase.swift:277-282`, rowID FK). DatabaseViews/column config address built-ins by **`FieldTarget.builtin(ColumnIdentifier)` string, not rowID** (`FieldTarget+Options.swift:56-63`) → keep-local-rowID is safe for views.

---

## Key facts

- **Apply site:** `SyncEntityDispatch.applyRemoteRecord(_:entityId:db:)` `case .propertyDefinition` (`Sources/RubienSync/SyncEntityDispatch.swift:376-380`):
  ```swift
  case .propertyDefinition:
      guard let id = Int64(entityId) else { return }
      var row = PropertyDefinition(record: record)
      row.id = id
      try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }
  ```
- **`PropertyDefinition(record:)`** decodes `defaultFieldKey` (`PropertyDefinitionRecord.swift:77`), so `row.defaultFieldKey` is available to branch on.
- **`PropertyDefinition`** is `MutablePersistableRecord`; `row.update(db)` updates by `id`. Setting `row.id = localId` then `row.update(db)` rewrites the local row's mutable columns (name/type/optionsJSON/sortOrder/isDefault/isVisible/dateModified) without changing its rowID.
- **Schema:** `propertyDefinition.name TEXT NOT NULL UNIQUE`; `defaultFieldKey TEXT` (nullable, **not** unique in schema but logically unique per built-in).
- **Bookkeeping note (accepted debt — rationale corrected per Codex):** `applyRemoteRows` calls `markPulled(entityId: "339", …)` (`SyncedLibrary.swift:856-860`), so systemFields land under the *remote* entityId "339" while the local row stays at 29. The earlier "never pushes" rationale was **wrong**: visibility/reorder edits dirty by local rowID (`AppDatabase.swift:2875,2888`) and baseline can pick up local built-ins (`SyncedLibrary.swift:464,498`), so the local copy *can* push as a separate server record and the systemFields under "339" can go stale. **Not a crash and not an infinite loop** (remote apply suppresses dirty triggers, `SyncedLibrary.swift:823`). Accepted bookkeeping debt for v0.1.5, resolved by A-pks. A fuller fix would have `applyRemoteRecord` return the resolved local id so `markPulled` keys on it — out of scope (`applyRemoteRecord` is `Void` today).

---

## Task 1: Reconcile built-ins by `defaultFieldKey` on apply

**Files:** Modify `Sources/RubienSync/SyncEntityDispatch.swift`

- [ ] **Step 1:** Replace the `.propertyDefinition` case body (`:376-380`) with the reconcile branch:

```swift
        case .propertyDefinition:
            guard let id = Int64(entityId) else { return }
            var row = PropertyDefinition(record: record)
            // Built-in PropertyDefinitions (defaultFieldKey != nil) are seeded
            // independently on every device, so their rowIDs diverge ("Last
            // Read" is id 29 on a fresh library, 339 on an older one). Syncing
            // them by rowID makes this INSERT collide on UNIQUE(name) and the
            // whole fetched batch rolls back. Reconcile by the stable
            // defaultFieldKey instead: update the local seeded row in place,
            // keeping its rowID. Safe because built-ins carry no propertyValues
            // (only custom props do, and those have nil defaultFieldKey → they
            // keep the rowID-keyed upsert below). Targeted stand-in for the
            // A-pks UUID identity (PropertyDefinitionRecord.swift:8-10).
            if let fieldKey = row.defaultFieldKey,
               let localId = try Int64.fetchOne(
                   db,
                   sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey = ? LIMIT 1",
                   arguments: [fieldKey]
               ) {
                row.id = localId
                row.isDefault = true   // A defaultFieldKey-bearing row IS a built-in.
                                       // `isDefault` is a synced/mutable field, so never
                                       // write the peer's value verbatim: a stray isDefault=0
                                       // would make the built-in deletable and break the
                                       // next reconcile (Codex pass 3). Force it true.
                try row.update(db)
            } else {
                row.id = id
                try Self.upsert(row, id: id, tableName: self.rawValue, db: db) { try row.update(db) } insert: { try row.insert(db) }
            }
```

- [ ] **Step 2 (delete-path guard — defense-in-depth, added per Codex pass 2):** Because reconcile keeps a built-in at its *local* rowID while the peer's record uses a *divergent* rowID, a remote delete keyed on the peer's built-in rowID (e.g. `propertyDefinition:339`) would target the wrong local row. In practice no such delete is ever generated — built-ins are delete-protected (`deletePropertyDefinition` guards `isDefault`, `AppDatabase.swift:2861-2865`; CLI rejects at `RubienCLI.swift:1143`) — but harden the receive path so a stray/legacy delete can never drop a local built-in. Edit `applyRemoteDelete` `case .propertyDefinition` (`SyncEntityDispatch.swift:453`):

```swift
        case .propertyDefinition:
            if let id = Int64(entityId) {
                // Never honor a remote delete against a local built-in. Built-ins
                // are seeded + delete-protected on every device, and reconcile keeps
                // them at divergent local rowIDs, so a delete keyed on a peer's
                // built-in rowID must not drop whatever sits at that id locally.
                // Custom props (isDefault=0) delete normally.
                let isLocalDefault = try Bool.fetchOne(
                    db,
                    sql: "SELECT isDefault FROM propertyDefinition WHERE id = ? LIMIT 1",
                    arguments: [id]
                ) ?? false
                guard !isLocalDefault else { return }
                _ = try PropertyDefinition.deleteOne(db, key: id)
            }
```

- [ ] **Step 3:** `swift build` → clean.

Notes for the implementer:
- Do **not** change `markPulled`/recordName/push paths — receive-side only (apply reconcile + delete guard).
- The apply `else` branch is byte-for-byte today's behavior (custom defs + any built-in whose `defaultFieldKey` isn't yet seeded locally fall here; the latter inserts at the remote rowID, correct when there's no local seed to collide with).
- **Match by `defaultFieldKey` alone — do NOT gate on `isDefault` (Codex pass 3).** `isDefault` is a synced, mutable field; gating the match on it is self-defeating (a peer record with `isDefault=0` misses the match → falls to the rowID upsert → reproduces the `UNIQUE(name)` crash). Matching by `defaultFieldKey` is safe because **only built-ins carry a non-null `defaultFieldKey`** (custom creation omits it → NULL, verified), so the predicate can only resolve to a local built-in. Forcing `row.isDefault = true` on the matched row keeps the flag authoritative.
- `Int64.fetchOne` returns nil when no local row has that `defaultFieldKey` → falls to the upsert (custom defs, or a built-in this device hasn't seeded yet).
- The delete guard mirrors the existing local guard in `deletePropertyDefinition` — built-ins are never removed by a remote delete, consistent with their being undeletable locally. **Documented limitation (Codex pass 3, non-fireable today):** the guard protects whatever row occupies the incoming numeric id; a *stray* delete for `propertyDefinition:339` on a device where id 339 is a *custom* row (`isDefault=0`) would still delete it. No in-tree path generates a built-in delete (so recordName 339 — Mac A's undeletable "Last Read" — never produces a delete), so this can't fire; noted for the A-pks migration.

---

## Task 2: Tests

**Files:** Modify `Tests/RubienSyncTests/SyncEntityDispatchTests.swift` (or create `Tests/RubienSyncTests/PropertyDefinitionReconcileTests.swift` if the dispatch tests file is unwieldy — check first).

- [ ] **Step 1:** Built-in with a divergent remote rowID reconciles to the local seed (no collision, no duplicate). Pre-fix this threw `SQLITE_CONSTRAINT_UNIQUE`.

```swift
#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class PropertyDefinitionReconcileTests: XCTestCase {
    private var db: AppDatabase!
    private let store = SyncStateStore()

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }
    override func tearDown() { db = nil; super.tearDown() }

    /// A remote built-in ("Last Read") arrives at a rowID that differs from the
    /// local seed. It must update the local row in place (matched by
    /// defaultFieldKey) rather than INSERT a colliding name.
    func testBuiltinReconcilesByDefaultFieldKeyKeepingLocalRowID() throws {
        // The fresh DB seeds "Last Read" with defaultFieldKey="lastReadAt".
        let localId = try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'")
        }
        let localId2 = try XCTUnwrap(localId)
        let remoteId = localId2 + 1000          // simulate the divergent peer rowID (e.g. 339)

        // Build a remote CKRecord for "Last Read" at the divergent rowID.
        let def = PropertyDefinition(
            id: remoteId, name: "Last Read", type: .date, options: [],
            sortOrder: 99, isDefault: true, defaultFieldKey: "lastReadAt", isVisible: false
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(remoteId)),
            definition: def
        )

        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteRecord(record, entityId: String(remoteId), db: db)
            try self.store.clearApplyingRemote(db)
        }

        try db.dbWriter.read { db in
            // Still exactly one "Last Read"; still at the local rowID; no remote-id row.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE name='Last Read'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), localId2)
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE id=?", arguments: [remoteId]))
            // sortOrder was updated from the remote record (proves update-in-place).
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT sortOrder FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), 99)
        }
    }

    /// A peer record carrying a defaultFieldKey but isDefault=0 must still
    /// reconcile by defaultFieldKey (no UNIQUE(name) crash, no rowID insert) and
    /// must NOT poison the local built-in's flag — isDefault stays true.
    /// Guards the self-defeating-gate regression Codex pass 3 caught.
    func testPeerRecordWithDefaultFieldKeyButIsDefaultFalseStillReconciles() throws {
        let localId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") })
        let remoteId = localId + 1000
        let def = PropertyDefinition(
            id: remoteId, name: "Last Read", type: .date, options: [],
            sortOrder: 7, isDefault: false, defaultFieldKey: "lastReadAt", isVisible: false)  // poisoned flag
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(remoteId)),
            definition: def)
        // Poison the LOCAL flag too — else the test is vacuous against the old
        // `AND isDefault=1` gate, which would still match the seeded isDefault=1
        // row and appear to pass. With both sides isDefault=0, only the gate-less
        // match-by-defaultFieldKey can find the row and restore isDefault=true.
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE propertyDefinition SET isDefault = 0 WHERE defaultFieldKey = 'lastReadAt'")
        }
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteRecord(record, entityId: String(remoteId), db: db)
            try self.store.clearApplyingRemote(db)
        }
        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE name='Last Read'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), localId)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT isDefault FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), true)
        }
    }

    /// A custom def (defaultFieldKey == nil) still inserts at the remote rowID.
    func testCustomDefinitionInsertsByRowID() throws {
        let def = PropertyDefinition(
            id: 237, name: "Method", type: .singleSelect, options: [],
            sortOrder: 50, isDefault: false, defaultFieldKey: nil, isVisible: true
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: "237"),
            definition: def
        )
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteRecord(record, entityId: "237", db: db)
            try self.store.clearApplyingRemote(db)
        }
        try db.dbWriter.read { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE name='Method'"), 237)
        }
    }

    /// A remote delete must never drop a local built-in (defense-in-depth for the
    /// reconcile's entityId↔localId mismatch). Custom-def deletes still work.
    func testRemoteDeleteNeverDropsLocalBuiltin() throws {
        let builtinId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") })
        // Worst case: the delete keys on the local built-in's own id.
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteDelete(entityId: String(builtinId), db: db)
            try self.store.clearApplyingRemote(db)
        }
        XCTAssertEqual(try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") }, 1,
            "remote delete must not drop a local built-in")

        // A custom def still deletes normally.
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO propertyDefinition (id, name, type, optionsJSON, sortOrder, isDefault, isVisible) VALUES (500, 'Custom', 'singleSelect', '[]', 99, 0, 1)")
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteDelete(entityId: "500", db: db)
            try self.store.clearApplyingRemote(db)
        }
        XCTAssertEqual(try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE id=500") }, 0,
            "custom-def remote delete still works")
    }
}
#endif
```

- [ ] **Step 2:** `swift test --filter PropertyDefinitionReconcileTests` → all pass. Confirm `testBuiltinReconcilesByDefaultFieldKeyKeepingLocalRowID` fails on a stash of the pre-fix code (throws `SQLITE_CONSTRAINT_UNIQUE`), so it's a real regression guard.

- [ ] **Step 3:** Verify the `PropertyDefinition` memberwise init signature/labels used above against `Sources/RubienCore/Models/PropertyDefinition.swift` before running — match the actual `options:`/`optionsJSON` shape (the model init takes `options: [SelectOption]`; `makeRecord`→`populate` ships `optionsJSON`, and `init(record:)` preserves the JSON verbatim, so an empty `options: []` is fine for these fixtures).

---

## Task 3: End-to-end guard through SyncedLibrary (optional but recommended)

**Files:** same test file.

- [ ] **Step 1:** Drive `applyFetchedRecordsForTest` with a batch that mixes the divergent built-in + a custom def + a reference, and assert the **whole batch commits** (pre-fix it rolled back). This proves the batch-drop is gone, not just the single-record apply.

```swift
    func testMixedBatchNoLongerRollsBackOnBuiltinCollision() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true })

        let localLastRead = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") })

        let builtin = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(localLastRead + 1000)),
            definition: PropertyDefinition(id: localLastRead + 1000, name: "Last Read", type: .date, options: [],
                sortOrder: 99, isDefault: true, defaultFieldKey: "lastReadAt", isVisible: false))
        let custom = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: "237"),
            definition: PropertyDefinition(id: 237, name: "Method", type: .singleSelect, options: [],
                sortOrder: 50, isDefault: false, defaultFieldKey: nil, isVisible: true))
        let ref = Reference.makeRecord(
            recordName: SyncEntityType.reference.qualifiedRecordName(entityId: "5"),
            reference: Reference(title: "R5"))

        await library.applyFetchedRecordsForTest(modifications: [builtin, custom, ref], deletions: [])

        try db.dbWriter.read { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE name='Method'"), 237)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference WHERE id=5"), 1)   // ref survived the batch
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
```

- [ ] **Step 2:** `swift test --filter PropertyDefinitionReconcileTests` → all green.

---

## Task 4: Build, suite, review, commit

- [ ] `swift build`; `swift test --filter RubienSyncTests` (then full `swift test`).
- [ ] `codex-rescue` review of the uncommitted diff; `/simplify` sweep.
- [ ] Commit: `sync: reconcile built-in PropertyDefinitions by defaultFieldKey (fix UNIQUE(name) batch-drop that stalled the mini's pull at 78 + hid Method/Modality)`

---

## Task 5: Release v0.1.5 + re-sync the mini

- [ ] `VERSION` → `0.1.5`, `BUILD.txt` → `6`.
- [ ] `RELEASE_NOTES_TEXT="iCloud Sync fix: custom properties (e.g. Method, Modality) and the rest of your library now sync to a new Mac instead of stalling." CODESIGN_IDENTITY="Developer ID Application: Hongkai Zheng (9TXK4V3SS8)" ./scripts/release.sh`
- [ ] Update **both** Macs to v0.1.5 (the collision is bidirectional — both peers must run the fix).
- [ ] Mini: quit → delete `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/sync-engine-state.bin` → relaunch.
- [ ] Verify mini reaches **113 refs + Method/Modality (with their values) + PDFs**; mini log shows **no** `UNIQUE constraint failed: propertyDefinition.name`.

---

## Codex review outcome (2026-05-31) — Sound; build it

Codex verified root cause, the Task-1 code (compiles against real types), DatabaseView safety (built-ins addressed by `ColumnIdentifier` string, not rowID), bidirectional convergence (no dirty-loop; no push-side change needed for v0.1.5), and test fidelity (no vacuous paths). Resolutions:

1. **Match key** — `defaultFieldKey != nil` is a reliable built-in discriminator (code-path invariant, not DB-enforced; no current path creates a custom def with a non-null `defaultFieldKey`). ✅
2. **`markPulled` bookkeeping** — accepted debt; rationale corrected above (divergent built-ins *can* push via visibility/reorder/baseline). No crash/loop. Defer the resolved-local-id change to A-pks. ✅ (accepted)
3. **Bidirectional + duplicates** — convergent without churn; defer server-dup cleanup to A-pks. ✅ (accepted)
4. **`update` semantics** — `row.update(db)` is a plain `UPDATE … WHERE id=?` on the matched existing row; no transient duplicate-name state. ✅
5. **Orphaning** — narrowed above: safe for the only divergent built-ins (date/number, no values); future string/select divergent built-ins need a propertyValue remap (A-pks). ✅ (accepted residual)
6. **NEW residual (Codex Q5) — non-blocking, worth noting:** a library where a user already has a **custom** "Last Read"/"Read Count" row owning that *name* (e.g. v5 seeding was skipped, or a hand-made prop) won't be helped by the `defaultFieldKey` match (the custom row has null `defaultFieldKey`) — the peer's built-in still collides on `UNIQUE(name)`. Such users need a separate one-time repair (rename/merge). Not our reported case (Mac A/mini both have the v5-seeded built-in), so out of scope for v0.1.5; flag for the A-pks migration.

## Codex review outcome — PASS 2 (independent second pass, 2026-05-31)

A fresh independent reviewer re-derived from the code and found one **blocking** issue pass 1 missed, now **resolved**:

- **Remote-delete hazard (was BLOCKING → resolved).** Reconcile keeps a built-in at its *local* rowID while `markPulled` stores identity under the peer's *divergent* rowID ("339"). A remote delete keyed on "339" would route through `applyRemoteDelete` → `deleteOne(key: 339)` and could hit the wrong local row (or a future id-339 reuse). **Resolution:** verified built-ins are **delete-protected on every device** — `deletePropertyDefinition` early-returns on `isDefault` (`AppDatabase.swift:2861-2865`) and the CLI rejects it (`RubienCLI.swift:1143`) — so no delete record for a built-in (`propertyDefinition:339`) is ever generated; recordName 339 is permanently Mac A's undeletable "Last Read" (a custom prop gets 341+, never 339). **Plus defense-in-depth** (Task 1 Step 2): `applyRemoteDelete` now skips any local `isDefault=1` row, so even a stray/legacy delete can't drop a built-in. New test `testRemoteDeleteNeverDropsLocalBuiltin`.
- **`defaultFieldKey` not schema-unique (non-blocking).** No in-tree path produces two non-nil rows; hardened the reconcile match with `AND isDefault = 1` so it can only ever resolve to a local built-in.
- **Confirmed non-issues:** FK-off path doesn't change correctness; Method/Modality (custom, by rowID) unaffected; no `UNIQUE(name)` collision from the reconcile UPDATE itself; idempotent under repeated delivery (trigger-skip prevents self-dirty); the three tests are substantive.
- **Separate pre-existing bug to FILE (out of scope, NOT introduced here):** tombstone confirmation / `.unknownItem` purge are keyed by `entityId` only, not `(entityType, entityId)` (`SyncStateStore.swift:250`, `SyncedLibrary.swift:1049`), so a confirmed delete for `reference:7` also confirms a tombstone for `tag:7`/`propertyDefinition:7`. Independent of this fix; track separately.

## Codex review outcome — PASS 3 (independent third pass, 2026-05-31)

A third independent reviewer found a **blocking** issue that passes 1 & 2 missed — one *introduced by the pass-2 hardening*, now fixed:

- **`AND isDefault = 1` on the reconcile match was self-defeating (was BLOCKING → fixed).** `isDefault` is a synced, mutable field. A `defaultFieldKey`-bearing peer record arriving with `isDefault=0` would (a) miss the gated match, (b) fall to the rowID upsert, (c) reproduce the original `UNIQUE(name)` crash — and the reconcile UPDATE wrote `isDefault` back verbatim, poisoning the local flag. **Fix:** match by `defaultFieldKey` **alone** (safe — only built-ins carry a non-null `defaultFieldKey`, so it can only resolve to a built-in), and **force `row.isDefault = true`** on the matched row so the built-in flag stays authoritative. New test `testPeerRecordWithDefaultFieldKeyButIsDefaultFalseStillReconciles`.
- **Delete guard's protection is narrow (documented, non-fireable).** It protects whatever row holds the incoming numeric id; a stray delete for `propertyDefinition:339` where local 339 is a *custom* row would still delete it. No in-tree path generates a built-in delete, so it can't fire — noted in Task 1 and for A-pks.
- **Confirmed:** root cause right; `Bool.fetchOne` returns nil (not throw) on a missing row → `?? false` → no-op `deleteOne` (correct); `isDefault` is a synced CKRecord field so the delete guard's local-`isDefault` read is a sound "is built-in" proxy; the four tests fail pre-fix / pass post-fix; markPulled/duplicate debt is non-corrupting.
- **Delete-path coverage enumerated:** local UI/CLI deletes (guarded), trigger tombstones (built-ins never reach them), remote per-record delete / server expiry (new receive guard covers), zone-wide purge & account-change reset (don't delete PropertyDefinitions). No uncovered path that deletes a built-in.

**Net after 3 passes:** root cause confirmed; fix = `defaultFieldKey`-alone reconcile + force-isDefault + receive-side delete guard; all blocking findings resolved; residuals (markPulled bookkeeping, server duplicates, the custom-row-owns-the-name edge, the separate `entityId`-only tombstone bug) are documented and deferred to A-pks / separate fixes.

**Pass-3 reviewer re-review of the revision (2026-05-31):** confirmed the `defaultFieldKey`-alone match + force-`isDefault=true` **fully resolves** the self-defeating-gate crash, force-true introduces no new problem (only built-ins carry a non-null `defaultFieldKey`; stays consistent with the delete guard), and no new edges opened. One **test-vacuity** fix applied: `testPeerRecordWithDefaultFieldKeyButIsDefaultFalseStillReconciles` now also poisons the *local* row to `isDefault=0` before applying, so it genuinely fails against the old gated code instead of passing for the wrong reason. **Verdict: build it.**

---

## Rollback / safety

Receive-path only; no schema/migration/CKRecord/recordName/push change. Custom-def path unchanged. Reversible via one commit revert. Data is safe on Mac A + CloudKit throughout; the mini reset is the documented `sync-engine-state.bin` reset.
