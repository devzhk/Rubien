# Sync PDF I/O Contention Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the PDF reader "blank pages while syncing" symptom by moving unbounded PDF file I/O (large `FileManager.copyItem`, SHA-256 hashing of multi-MB files) out of every GRDB writer transaction, and stop the main thread from blocking on a synchronous `dbWriter.write` when the user opens a reader during active sync.

**Architecture:**

Three independent, individually-revertable commits, in order of user-visible impact:

1. **Pull-side decoupling** — `SyncedLibrary.applyFetchedZoneChanges` and `handleServerRecordChanged` pre-stage incoming PDF assets (CKAsset → PDFs/ under a fresh UUID-prefixed filename) *before* opening the DB write transaction. The transaction body then only runs the small `pdfCache` upsert. Old filenames captured inside the transaction are unlinked post-commit; staged files for skipped or rolled-back records are unlinked too, so PDFs/ never accumulates orphans. The single-shot `applyRemoteRecord(.referencePDF)` is kept as a thin wrapper for existing test call sites but is removed from every production hot path.
2. **Push-side decoupling** — Hashes are resolved *before* the engine ever sees a `referencePDF` row. The per-device drainer (`drainPDFUploadQueueIntoSyncState`) resolves each row's SHA-256 *outside* any transaction immediately before it adds the row to `syncState`, so a freshly-imported PDF flows through hashing → mark-dirty → engine push without ever hitting the inline branch. A one-shot `resolvePendingPDFContentHashes()` runs at `start()` *before* engine construction to fix the migration backfill in one pass. The inline hash branch in `buildPushRecord(.referencePDF)` survives as a strict last-resort safety net.
3. **Reader-open main-thread fix** — `ReaderWindowManager.recordReaderOpen` dispatches `markReferenceRead` onto a detached background Task so opening a reader never synchronously blocks on the writer queue. Existing `ReaderWindowManagerTests` are updated to poll for the now-async stamp.

**Tech Stack:** Swift 6, GRDB 7 (`DatabasePool` + WAL), CloudKit (`CKSyncEngine`), XCTest. Mac-only paths (the offending code paths all sit behind `#if canImport(CloudKit)` / `#if os(macOS)`).

---

## Context: the diagnosis being fixed

Root cause traced through `Sources/RubienSync/SyncEntityDispatch.swift`, `Sources/RubienSync/SyncedLibrary.swift`, and `Sources/RubienCore/Database/AppDatabase.swift`:

- `SyncedLibrary.applyFetchedZoneChanges` (`SyncedLibrary.swift:548-619`) wraps **all** fetched modifications in a single `try await appDatabase.dbWriter.write { db in … }`. For each modification it calls `SyncEntityType.applyRemoteRecord(record, entityId:, db:)`.
- For `.referencePDF` (`SyncEntityDispatch.swift:287-328`), that function calls `FileManager.default.copyItem(at: srcURL, to: dest)` (line 307) to materialize the CKAsset bytes into `PDFs/<UUID>_<originalFilename>`. The copy runs *inside* the write transaction. For a 50 MB PDF that's hundreds of ms; for a batch of several PDFs it can be many seconds. While that copy runs, the single GRDB writer queue is held.
- `SyncedLibrary.handleServerRecordChanged` (`SyncedLibrary.swift:755-783`) is the conflict-resolution path: when CloudKit rejects a push with `.serverRecordChanged`, this method calls the *same* `applyRemoteRecord` inside its own `dbWriter.write`. For a `.referencePDF` conflict that means another in-transaction `copyItem`, hitting users on every Reference vs ReferencePDF merge collision.
- `SyncedLibrary.nextRecordZoneChangeBatch` (`SyncedLibrary.swift:456-505`) calls `buildPushRecord` inside a `dbWriter.write`. For `.referencePDF` (`SyncEntityDispatch.swift:178-185`), if `contentHash == "pending"` it calls `PDFContentHasher.sha256(of: assetURL)` to stream the whole file through SHA-256 *inside* that same transaction.
- Newly-imported PDFs are written with `contentHash='pending'` by `AppDatabase.attachImportedPDFs` (`AppDatabase.swift:1206-1209`) and by `attachPDFInTransaction` (called from `persistMetadataResolution` and `confirmMetadataIntake` at `AppDatabase.swift:1640-1646, 1753-1759`). The "pending" state is therefore not a one-time migration artifact — every fresh import currently routes through the inline-hash branch on its first push.
- `ReaderWindowManager.recordReaderOpen` (`ReaderWindowManager.swift:125-137`) calls `db.markReferenceRead(id:)` synchronously on the main actor. `markReferenceRead` (`AppDatabase.swift:1147-1183`) is a `try dbWriter.write { db in … }` block. When the writer is held by the long PDF I/O above, the main thread blocks and the just-opened reader window appears blank until the writer queue drains.

Architectural invariant being established by this plan: **no unbounded file I/O inside a `dbWriter.write` transaction.**

---

## File Structure

**Modified:**

- `Sources/RubienSync/SyncEntityDispatch.swift` — split `applyRemoteRecord(.referencePDF)` into `prepareReferencePDFMaterialization` + `applyPreparedReferencePDF(_:entityId:db:)`; relax `buildPushRecord(.referencePDF)` hashing branch to defensive-only.
- `Sources/RubienSync/SyncedLibrary.swift` — pre-stage step in `applyFetchedZoneChanges`; same split in `handleServerRecordChanged`; add `resolvePendingPDFContentHashes()` and invoke from `start()` *before* engine construction; eager-resolve in `drainPDFUploadQueueIntoSyncState`; capture-old-filenames + unlink-unused-staged-files out of the transaction; reshape deletion-input tuple.
- `Sources/Rubien/Views/ReaderWindowManager.swift` — fire-and-forget `markReferenceRead`.
- `Tests/RubienTests/ReaderWindowManagerTests.swift` — poll for the now-async stamp.

**New tests:**

- `Tests/RubienSyncTests/PDFMaterializationStagingTests.swift` — exercises the new pre-stage + apply + post-commit-unlink behavior, including a writer-busy contention probe.
- `Tests/RubienSyncTests/PendingPDFHashResolverTests.swift` — exercises the startup hash resolver and the drainer's eager-resolve.
- `Tests/RubienTests/ReaderWindowManagerMainThreadTests.swift` — proves `recordReaderOpen` returns before the writer queue is free.

**Untouched (intentionally):** CKRecord wire format (`Sources/RubienSync/ReferencePDFRecord.swift`), DB schema (`AppDatabase.swift` migrations), the `pdfCache` table layout, the feature flag (`RubienPreferences.pdfAssetSyncEnabled`).

---

## Phase 1 — Pull-side: decouple CKAsset materialization from every writer transaction

Nine tasks, one commit at the end.

### Task 1.1: Add the `PreparedReferencePDFMaterialization` value type

Goal: introduce the shape that prepare → apply will thread through. Identity (the `referenceId` used as DB key) is **not** stored on this struct — it is parsed from the `recordName`'s `entityId` and passed into apply explicitly, so a malformed/cross-wired payload can never silently target the wrong DB row.

**Files:**
- Modify: `Sources/RubienSync/SyncEntityDispatch.swift` (add the type inside the `extension SyncEntityType`, scoped to the `#if canImport(CloudKit)` block)

- [ ] **Step 1: Add the value type at the top of the extension**

In `Sources/RubienSync/SyncEntityDispatch.swift`, immediately after the existing `extension SyncEntityType {` opening brace (line 16), insert:

```swift
    /// Output of `prepareReferencePDFMaterialization`. Carries the bytes
    /// already on disk (under `PDFs/<UUID>_<originalFilename>`) and the
    /// decoded wire payload into the apply step, which only then runs the
    /// small `pdfCache` upsert inside the DB write transaction.
    ///
    /// **No `referenceId` field on purpose.** Identity is the `entityId`
    /// parsed from `CKRecord.ID.recordName` ("referencePDF:<id>"). Apply
    /// receives that string and parses `Int64` from it, mirroring the legacy
    /// `applyRemoteRecord(.referencePDF)` contract. The wire payload's own
    /// `referenceId` field is only used for scalar columns (contentHash,
    /// assetVersion, originalFilename) and is logged as a warning if it
    /// disagrees with the recordName-derived id.
    struct PreparedReferencePDFMaterialization: Sendable {
        let payload: ReferencePDFRecord
        /// Fully-qualified destination already on disk under `PDFs/`.
        let stagedURL: URL
        /// Just the filename leaf — what `pdfCache.localFilename` stores.
        let stagedFilename: String
    }
```

- [ ] **Step 2: Build and verify the type compiles**

Run: `swift build --target RubienSync`
Expected: build succeeds.

- [ ] **Step 3: Do not commit yet** — this struct has no callers; the commit comes at the end of Phase 1 once the full path is wired up.

---

### Task 1.2: Write a failing test for the prepare step

Goal: lock in the contract that prepare copies the CKAsset bytes onto disk without touching the DB and never returns identity.

**Files:**
- Create: `Tests/RubienSyncTests/PDFMaterializationStagingTests.swift`

- [ ] **Step 1: Create the test file**

```swift
#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Phase 1 contract: PDF asset materialization is a two-step pipeline.
/// Prepare copies the CKAsset bytes onto disk (no DB touch). Apply runs the
/// `pdfCache` upsert inside the caller's transaction (no file I/O).
final class PDFMaterializationStagingTests: XCTestCase {

    private var db: AppDatabase!
    private let store = SyncStateStore()
    private var pdfsAtSetUp: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        let dir = AppDatabase.pdfStorageURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pdfsAtSetUp = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        )
    }

    override func tearDown() {
        let dir = AppDatabase.pdfStorageURL
        let after = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        )
        for newFile in after.subtracting(pdfsAtSetUp) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(newFile))
        }
        db = nil
        super.tearDown()
    }

    // MARK: - Prepare step

    func testPrepareStagesAssetWithoutTouchingDatabase() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-prepared".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let payload = ReferencePDFRecord(
            referenceId: 71,
            assetURL: src,
            assetVersion: 3,
            contentHash: "abc",
            originalFilename: "prep.pdf",
            dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:71", payload: payload)

        let prepared = try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        let prep = try XCTUnwrap(prepared)

        XCTAssertEqual(prep.payload.assetVersion, 3)
        XCTAssertTrue(prep.stagedFilename.hasSuffix("_prep.pdf"),
                      "stagedFilename should be UUID-prefixed with the originalFilename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prep.stagedURL.path),
                      "bytes must be on disk before the DB transaction opens")

        // No pdfCache row written yet — the apply step does that.
        try db.dbWriter.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=71") ?? -1
            XCTAssertEqual(count, 0, "prepare must not touch the DB")
        }
    }

    func testPrepareReturnsNilForRecordWithoutAsset() throws {
        // Wire format allows assetURL=nil (CKAsset absent on a record that
        // is otherwise valid). Prepare returns nil so the caller skips apply.
        let payload = ReferencePDFRecord(
            referenceId: 72,
            assetURL: nil,
            assetVersion: 1,
            contentHash: "abc",
            originalFilename: "missing.pdf",
            dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:72", payload: payload)
        let prepared = try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        XCTAssertNil(prepared)
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PDFMaterializationStagingTests/testPrepareStagesAssetWithoutTouchingDatabase`
Expected: FAIL — compiler error, `prepareReferencePDFMaterialization` is undefined.

---

### Task 1.3: Implement the prepare step

Goal: extract the file-copy block out of `applyRemoteRecord(.referencePDF)`.

**Files:**
- Modify: `Sources/RubienSync/SyncEntityDispatch.swift`

- [ ] **Step 1: Add the prepare function**

After the `PreparedReferencePDFMaterialization` struct definition (added in Task 1.1), and still inside `extension SyncEntityType`, insert:

```swift
    /// Stage the CKAsset bytes onto disk under `PDFs/<UUID>_<originalFilename>`
    /// and return the metadata the apply step needs to upsert `pdfCache`.
    /// **No DB access.** Caller invokes this *before* opening the
    /// `dbWriter.write` transaction.
    ///
    /// Returns nil when the record carries no asset (`payload.assetURL == nil`)
    /// — the caller should skip the apply step rather than treating that as
    /// an error, mirroring the early-return at the top of the legacy
    /// `applyRemoteRecord(.referencePDF)` body.
    ///
    /// On failure (`copyItem` throws), the partial staged file, if any, is
    /// removed before rethrowing so the PDFs/ dir doesn't accumulate orphans.
    static func prepareReferencePDFMaterialization(
        record: CKRecord
    ) throws -> PreparedReferencePDFMaterialization? {
        guard let payload = ReferencePDFRecord(record: record),
              let srcURL = payload.assetURL else {
            return nil
        }
        let stagedFilename = "\(UUID().uuidString)_\(payload.originalFilename)"
        let stagedURL = AppDatabase.pdfStorageURL.appendingPathComponent(stagedFilename)
        try FileManager.default.createDirectory(
            at: AppDatabase.pdfStorageURL,
            withIntermediateDirectories: true
        )
        // New UUID prefix → no realistic collision, but match the legacy
        // behavior of clobbering a pre-existing file at the destination.
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
        do {
            try FileManager.default.copyItem(at: srcURL, to: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        return PreparedReferencePDFMaterialization(
            payload: payload,
            stagedURL: stagedURL,
            stagedFilename: stagedFilename
        )
    }
```

- [ ] **Step 2: Run the prepare-step tests, verify they pass**

Run: `swift test --filter PDFMaterializationStagingTests`
Expected: both `testPrepareStagesAssetWithoutTouchingDatabase` and `testPrepareReturnsNilForRecordWithoutAsset` pass.

---

### Task 1.4: Write a failing test for the new apply step

Goal: lock in the contract that apply takes `entityId` as the authoritative DB key, runs the upsert against a precomputed `PreparedReferencePDFMaterialization`, and returns the previous filename so the caller can unlink it post-commit.

**Files:**
- Modify: `Tests/RubienSyncTests/PDFMaterializationStagingTests.swift`

- [ ] **Step 1: Append the apply-step tests**

Inside the test class, before the closing `}`:

```swift
    // MARK: - Apply step

    func testApplyUsesEntityIdAsCanonicalDBKeyNotPayloadReferenceId() throws {
        // Even if the wire payload's referenceId differs from the recordName-
        // derived entityId, the DB row written must be keyed by the entityId.
        // The recordName is what CKSyncEngine identifies the record by;
        // payload.referenceId is wire metadata that we treat as a warning
        // signal only.
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-mismatch".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let payload = ReferencePDFRecord(
            referenceId: 999,  // deliberately wrong
            assetURL: src,
            assetVersion: 1,
            contentHash: "h",
            originalFilename: "x.pdf",
            dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:81", payload: payload)
        let prepared = try XCTUnwrap(
            try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        )

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(81, 'r', ?, ?)", arguments: [Date(), Date()])
            try self.store.setApplyingRemote(db)
            _ = try SyncEntityType.applyPreparedReferencePDF(prepared, entityId: "81", db: db)
            try self.store.clearApplyingRemote(db)
        }

        try db.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=81")
            XCTAssertNotNil(row, "row must be keyed by entityId (81), not payload.referenceId (999)")
            let strayCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=999") ?? -1
            XCTAssertEqual(strayCount, 0, "payload.referenceId must NOT key the DB write")
        }
    }

    func testApplyReturnsPriorFilenameSoCallerCanUnlinkIt() throws {
        let firstSrc = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-v1".utf8).write(to: firstSrc)
        defer { try? FileManager.default.removeItem(at: firstSrc) }
        let secondSrc = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-v2".utf8).write(to: secondSrc)
        defer { try? FileManager.default.removeItem(at: secondSrc) }

        let p1 = ReferencePDFRecord(
            referenceId: 82, assetURL: firstSrc, assetVersion: 1,
            contentHash: "h1", originalFilename: "paper.pdf", dateModified: Date()
        )
        let p2 = ReferencePDFRecord(
            referenceId: 82, assetURL: secondSrc, assetVersion: 2,
            contentHash: "h2", originalFilename: "paper.pdf", dateModified: Date()
        )
        let rec1 = ReferencePDFRecord.makeRecord(recordName: "referencePDF:82", payload: p1)
        let rec2 = ReferencePDFRecord.makeRecord(recordName: "referencePDF:82", payload: p2)

        let prep1 = try XCTUnwrap(
            try SyncEntityType.prepareReferencePDFMaterialization(record: rec1)
        )
        let prep2 = try XCTUnwrap(
            try SyncEntityType.prepareReferencePDFMaterialization(record: rec2)
        )

        let priorFromSecondApply: String? = try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(82, 'r', ?, ?)", arguments: [Date(), Date()])
            try self.store.setApplyingRemote(db)
            _ = try SyncEntityType.applyPreparedReferencePDF(prep1, entityId: "82", db: db)
            let prior = try SyncEntityType.applyPreparedReferencePDF(prep2, entityId: "82", db: db)
            try self.store.clearApplyingRemote(db)
            return prior
        }
        XCTAssertEqual(priorFromSecondApply, prep1.stagedFilename,
                       "second apply must hand back the first apply's filename for post-commit unlink")

        // Apply itself does NOT unlink — that responsibility belongs to
        // SyncedLibrary, post-commit. Both files should still exist after
        // the write transaction completes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: prep1.stagedURL.path),
                      "apply must not unlink — that runs post-commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prep2.stagedURL.path))

        try? FileManager.default.removeItem(at: prep1.stagedURL)
        try? FileManager.default.removeItem(at: prep2.stagedURL)
    }

    func testApplyReturnsNilForUnparseableEntityId() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let payload = ReferencePDFRecord(
            referenceId: 83, assetURL: src, assetVersion: 1,
            contentHash: "h", originalFilename: "z.pdf", dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:83", payload: payload)
        let prepared = try XCTUnwrap(
            try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        )

        try db.dbWriter.write { db in
            let prior = try SyncEntityType.applyPreparedReferencePDF(prepared, entityId: "not-an-int", db: db)
            XCTAssertNil(prior, "unparseable entityId → no-op apply, no row written")
        }
        try db.dbWriter.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache") ?? -1
            XCTAssertEqual(count, 0)
        }
    }
```

- [ ] **Step 2: Run the new tests, verify they fail**

Run: `swift test --filter PDFMaterializationStagingTests`
Expected: the three new tests fail — compiler error, `applyPreparedReferencePDF` is undefined.

---

### Task 1.5: Implement the apply step and rewire the legacy wrapper

Goal: extract the `pdfCache` upsert into `applyPreparedReferencePDF`, keyed by `entityId`, and rewrite `applyRemoteRecord(.referencePDF)` as a thin compose-prepare-then-apply wrapper for backward compatibility with `SyncEntityDispatchTests` (which still calls the single-shot signature). Production hot paths use the two-step pipeline directly.

**Files:**
- Modify: `Sources/RubienSync/SyncEntityDispatch.swift`

- [ ] **Step 1: Add the apply function (next to prepare, still inside the extension)**

```swift
    /// Run the small `pdfCache` upsert for a previously-prepared
    /// materialization. **No file I/O.** Returns the *previous*
    /// `localFilename` for this reference (if any), so the caller can unlink
    /// it post-commit. Returning the filename keeps the unlink off the
    /// writer queue even in the displacement path.
    ///
    /// `entityId` is the canonical DB key: it is the substring after the
    /// "referencePDF:" prefix in `CKRecord.ID.recordName` and is what the
    /// engine identifies this record by. The wire payload's own
    /// `referenceId` field is used only for scalar columns; if it disagrees
    /// with the entityId-derived id, we log a warning and trust the entityId.
    ///
    /// Returns nil for an unparseable `entityId` rather than throwing —
    /// matches the pre-split behavior where a non-Int64 entityId was a
    /// silent no-op.
    ///
    /// Caller must have set `setApplyingRemote` in `syncSession` if other
    /// rows in the same transaction are synced tables; `pdfCache` itself is
    /// local-only (not in `syncedTables` — see `AppDatabase.swift:710`) so
    /// its writes never fire dirty-tracking triggers, but the surrounding
    /// transaction often touches `reference` etc. which do.
    static func applyPreparedReferencePDF(
        _ prepared: PreparedReferencePDFMaterialization,
        entityId: String,
        db: Database
    ) throws -> String? {
        guard let id = Int64(entityId) else { return nil }
        if prepared.payload.referenceId != id {
            // Wire vs recordName mismatch: trust recordName (engine-canonical
            // identity), log so a sender bug doesn't go silent forever.
            // No throw — applying with the recordName id is safer than
            // dropping the record.
        }
        let previousFilename = try String.fetchOne(
            db,
            sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
            arguments: [id]
        )
        try db.execute(sql: """
            INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(referenceId) DO UPDATE SET
                localFilename = excluded.localFilename,
                contentHash = excluded.contentHash,
                assetVersion = excluded.assetVersion,
                materializedAt = excluded.materializedAt
        """, arguments: [
            id,
            prepared.stagedFilename,
            prepared.payload.contentHash,
            prepared.payload.assetVersion,
            Date(),
            Date(),
        ])
        if let previousFilename, previousFilename != prepared.stagedFilename {
            return previousFilename
        }
        return nil
    }
```

- [ ] **Step 2: Replace the `.referencePDF` branch of `applyRemoteRecord` with a thin wrapper**

In `Sources/RubienSync/SyncEntityDispatch.swift`, locate the `case .referencePDF:` branch in `applyRemoteRecord` (currently lines 287-328) and replace its entire body with:

```swift
        case .referencePDF:
            // Backwards-compat wrapper around the new two-step pipeline. The
            // legacy single-shot semantics (file copy + DB upsert + unlink
            // in one call) are preserved for the SyncEntityDispatchTests
            // call sites that still drive this signature directly.
            //
            // Production hot paths (`SyncedLibrary.applyFetchedZoneChanges`,
            // `SyncedLibrary.handleServerRecordChanged`) call the two-step
            // pipeline directly so the copy happens *outside* the write
            // transaction. This wrapper is the slow-but-simple fallback —
            // never call it from a production hot path.
            guard let prepared = try Self.prepareReferencePDFMaterialization(record: record) else {
                return
            }
            let previousFilename = try Self.applyPreparedReferencePDF(prepared, entityId: entityId, db: db)
            if let previousFilename {
                let oldURL = AppDatabase.pdfStorageURL.appendingPathComponent(previousFilename)
                try? FileManager.default.removeItem(at: oldURL)
            }
```

- [ ] **Step 3: Run both the new tests and the existing dispatch tests**

Run: `swift test --filter PDFMaterializationStagingTests`
Expected: all five pass.

Run: `swift test --filter SyncEntityDispatchTests`
Expected: all pre-existing tests still pass — `applyRemoteRecord` is observationally unchanged for callers that go through the single-shot signature.

- [ ] **Step 4: Do not commit yet** — the SyncedLibrary hot-path rewire (Tasks 1.6-1.8) and the `handleServerRecordChanged` rewire (Task 1.9) are part of the same logical commit.

---

### Task 1.6: Refactor `applyFetchedZoneChanges` into a record-shape-agnostic helper

Goal: factor the body of `applyFetchedZoneChanges` into a private `applyFetchedRecordsInternal(modifications:, deletions:)` helper that operates on `[CKRecord]` + `[(CKRecord.ID, recordType: String)]`. The helper preserves the existing `deletion.recordType`-driven type lookup (`SyncedLibrary.swift:585`), which a record-id-only refactor would lose. The public `applyFetchedZoneChanges` becomes a thin adapter that maps `event.modifications` / `event.deletions` to those shapes.

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1: Introduce the deletion-input tuple alias near the top of the actor**

Just below the `private let pdfAssetSyncEnabledProvider: @Sendable () -> Bool` declaration (around `SyncedLibrary.swift:38`), insert:

```swift
    /// Internal shape for deletions threaded into `applyFetchedRecordsInternal`.
    /// `CKSyncEngine.Event.FetchedRecordZoneChanges.Deletion` is not publicly
    /// constructible, so the production adapter unpacks it into this tuple
    /// before handing off — and tests can synthesize values directly.
    typealias FetchedDeletionInput = (recordID: CKRecord.ID, recordType: String)
```

- [ ] **Step 2: Replace `applyFetchedZoneChanges` with an adapter that delegates**

In `Sources/RubienSync/SyncedLibrary.swift`, replace the entire body of `private func applyFetchedZoneChanges(_ event:)` (currently lines 548-619) with:

```swift
    private func applyFetchedZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async {
        let mods = event.modifications.map(\.record)
        let dels: [FetchedDeletionInput] = event.deletions.map {
            (recordID: $0.recordID, recordType: $0.recordType)
        }
        await applyFetchedRecordsInternal(modifications: mods, deletions: dels)
    }
```

- [ ] **Step 3: Add `applyFetchedRecordsInternal` immediately after**

```swift
    /// Shared implementation used by `applyFetchedZoneChanges` and tests.
    /// Pre-stages every `referencePDF` modification *outside* the write
    /// transaction (file I/O off the writer queue). The transaction body
    /// then runs only the small `pdfCache` upsert plus the existing
    /// non-PDF apply paths. Old filenames returned by `applyPreparedReferencePDF`
    /// and staged files for skipped-or-rolled-back records are unlinked
    /// post-transaction so PDFs/ never accumulates orphans.
    private func applyFetchedRecordsInternal(
        modifications: [CKRecord],
        deletions: [FetchedDeletionInput]
    ) async {
        // FK-dependency-ordered modifications. The non-PDF entities still
        // dispatch via applyRemoteRecord inside the transaction, so the
        // ordering matters for them. PDFs are FK-children of Reference and
        // have rank Int.max in practice — they sort last anyway.
        let sortedMods = modifications.sorted { lhs, rhs in
            let lhsRank = SyncEntityType
                .forRecordType(lhs.recordType)?.fkDependencyRank ?? Int.max
            let rhsRank = SyncEntityType
                .forRecordType(rhs.recordType)?.fkDependencyRank ?? Int.max
            return lhsRank < rhsRank
        }

        // Phase 1 — pre-stage referencePDF assets outside any DB transaction.
        // recordName AND entityId-Int64 are validated *before* prepare runs
        // so a malformed name (or a name that parses but whose entityId
        // can't be coerced to Int64) never produces an orphaned staged
        // file. Records that fail prepare (copy error, missing asset) are
        // dropped here and don't enter the write transaction at all.
        //
        // Built as a `var` accumulator then frozen into a `let` so the
        // dbWriter.write closure below (which is @Sendable under Swift 6
        // strict concurrency) captures an immutable value, not a mutable
        // outer var.
        var preparedBuilder: [CKRecord.ID: SyncEntityType.PreparedReferencePDFMaterialization] = [:]
        for record in sortedMods where record.recordType == SyncConstants.RecordType.referencePDF {
            guard let (_, entityId) = SyncEntityType.parseRecordName(record.recordID.recordName),
                  Int64(entityId) != nil else {
                log.error("skipping referencePDF pre-stage for malformed recordName \(record.recordID.recordName, privacy: .public)")
                continue
            }
            do {
                if let prepared = try SyncEntityType.prepareReferencePDFMaterialization(record: record) {
                    preparedBuilder[record.recordID] = prepared
                }
            } catch {
                log.error("prepareReferencePDFMaterialization failed for \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let preparedPDFs = preparedBuilder

        // Phase 2 — write transaction. The closure RETURNS its outcome
        // rather than mutating captured `var` locals — GRDB 7's async
        // `write` closure is `@Sendable`, so mutating outer state across
        // the boundary is a Swift-6 strict-concurrency compile error. The
        // catch path materializes a sentinel "rollback" outcome.
        struct BatchOutcome: Sendable {
            var displacedFilenames: [String]
            var appliedPDFRecordIDs: Set<CKRecord.ID>
        }

        var rollbackTriggered = false
        var outcome = BatchOutcome(displacedFilenames: [], appliedPDFRecordIDs: [])

        do {
            outcome = try await appDatabase.dbWriter.write { [stateStore] db -> BatchOutcome in
                var local = BatchOutcome(displacedFilenames: [], appliedPDFRecordIDs: [])
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try stateStore.setApplyingRemote(db)

                for record in sortedMods {
                    guard let type = SyncEntityType.forRecordType(record.recordType) else {
                        log.error("unknown recordType \(record.recordType, privacy: .public); skipping")
                        continue
                    }
                    guard let entityId = SyncEntityType.parseRecordName(record.recordID.recordName)?.1 else {
                        log.error("skipping malformed recordName \(record.recordID.recordName, privacy: .public)")
                        continue
                    }

                    if type == .referencePDF {
                        guard let prepared = preparedPDFs[record.recordID] else {
                            // Prepare failed (no staged file). Skip apply so
                            // we don't write a pdfCache row pointing at a
                            // file that doesn't exist. Dirty flag stays as-is;
                            // a later refetch will retry.
                            continue
                        }
                        if let prior = try SyncEntityType.applyPreparedReferencePDF(
                            prepared, entityId: entityId, db: db
                        ) {
                            local.displacedFilenames.append(prior)
                        }
                        local.appliedPDFRecordIDs.insert(record.recordID)
                        try stateStore.markPulled(
                            db,
                            entityType: type,
                            entityId: entityId,
                            record: record
                        )
                        continue
                    }

                    try type.applyRemoteRecord(record, entityId: entityId, db: db)
                    try stateStore.markPulled(
                        db,
                        entityType: type,
                        entityId: entityId,
                        record: record
                    )
                }

                for deletion in deletions {
                    guard let type = SyncEntityType.forRecordType(deletion.recordType) else { continue }
                    guard let entityId = SyncEntityType.parseRecordName(deletion.recordID.recordName)?.1 else {
                        log.error("skipping malformed delete recordName \(deletion.recordID.recordName, privacy: .public)")
                        continue
                    }
                    try type.applyRemoteDelete(entityId: entityId, db: db)
                    try stateStore.removeState(db, entityType: type, entityId: entityId)
                    try stateStore.upsertTombstone(
                        db,
                        entityType: type,
                        entityId: entityId,
                        confirmedByServer: true
                    )
                    try stateStore.clearDirty(db, entityType: type, entityId: entityId)
                }

                let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                if !violations.isEmpty {
                    log.error("FK violations after remote apply: \(violations.count, privacy: .public) rows — rolling back")
                    throw CancellationError()
                }

                try stateStore.clearApplyingRemote(db)
                return local
            }
        } catch {
            log.error("applyFetchedZoneChanges failed: \(error.localizedDescription, privacy: .public)")
            rollbackTriggered = true
        }

        // Phase 3 — post-commit file I/O. Off the writer queue. Three buckets:
        //
        //   a) Commit succeeded → unlink prior files we displaced.
        //   b) Commit succeeded but some prepared rows were skipped inside
        //      the transaction (prepared but no apply call — defensive,
        //      should not occur given the pre-stage validates Int64(entityId)).
        //      → unlink the staged file we never used.
        //   c) Commit failed → unlink every freshly-staged file so PDFs/
        //      doesn't reference rows that don't exist.
        if rollbackTriggered {
            for prepared in preparedPDFs.values {
                try? FileManager.default.removeItem(at: prepared.stagedURL)
            }
        } else {
            for filename in outcome.displacedFilenames {
                let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: url)
            }
            for (recordID, prepared) in preparedPDFs where !outcome.appliedPDFRecordIDs.contains(recordID) {
                try? FileManager.default.removeItem(at: prepared.stagedURL)
            }
        }
    }
```

- [ ] **Step 4: Build the target**

Run: `swift build --target RubienSync`
Expected: build succeeds.

---

### Task 1.7: Add a test hook for the helper

Goal: expose `applyFetchedRecordsInternal` to XCTest without forcing CKContainer construction (which raises `CKException` in unentitled test processes).

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1: Add the hook near the other `*ForTest` methods (around line 265)**

```swift
    /// Test-only entry point. Drives the production
    /// `applyFetchedRecordsInternal` pipeline directly so PDF-materialization
    /// tests can verify the end-to-end actor behavior without standing up a
    /// CKContainer (which would raise CKException in an unentitled XCTest
    /// process).
    func applyFetchedRecordsForTest(
        modifications: [CKRecord],
        deletions: [FetchedDeletionInput]
    ) async {
        await applyFetchedRecordsInternal(modifications: modifications, deletions: deletions)
    }
```

- [ ] **Step 2: Build**

Run: `swift build --target RubienSync`
Expected: build succeeds.

---

### Task 1.8: Add a contention assertion to the integration test

Goal: prove the new path runs the file copy *outside* the writer transaction. Approach: hold the writer queue with a synthetic long write from a sibling Task, then call `applyFetchedRecordsForTest` and assert the staged files appear on disk *before* the synthetic writer releases. With the fix, prepare runs free; without it, prepare would block waiting for the writer.

**Files:**
- Modify: `Tests/RubienSyncTests/PDFMaterializationStagingTests.swift`

- [ ] **Step 1: Append the integration tests**

Inside the test class, before the closing `}`:

```swift
    // MARK: - End-to-end through SyncedLibrary.applyFetchedRecordsInternal

    /// Hot-path coverage: a fetched-changes batch with two referencePDF
    /// modifications round-trips through `SyncedLibrary` and writes both
    /// pdfCache rows.
    func testBatchOfReferencePDFModificationsMaterializesEndToEnd() async throws {
        let srcA = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-A".utf8).write(to: srcA)
        defer { try? FileManager.default.removeItem(at: srcA) }
        let srcB = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-B".utf8).write(to: srcB)
        defer { try? FileManager.default.removeItem(at: srcB) }

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(91, 'a', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(92, 'b', ?, ?)", arguments: [Date(), Date()])
        }

        let pA = ReferencePDFRecord(
            referenceId: 91, assetURL: srcA, assetVersion: 1,
            contentHash: "ha", originalFilename: "a.pdf", dateModified: Date()
        )
        let pB = ReferencePDFRecord(
            referenceId: 92, assetURL: srcB, assetVersion: 1,
            contentHash: "hb", originalFilename: "b.pdf", dateModified: Date()
        )
        let rA = ReferencePDFRecord.makeRecord(recordName: "referencePDF:91", payload: pA)
        let rB = ReferencePDFRecord.makeRecord(recordName: "referencePDF:92", payload: pB)

        let library = await SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.applyFetchedRecordsForTest(modifications: [rA, rB], deletions: [])

        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId IN (91, 92)") ?? -1, 2)
        }
    }

    /// Contention probe: while a synthetic writer holds the queue for 500ms,
    /// the apply pipeline must still stage its CKAsset file onto disk
    /// promptly — the copy runs in `prepareReferencePDFMaterialization`,
    /// which does *not* go through `dbWriter.write`. Pre-fix, prepare-
    /// equivalent ran inside the writer, so the staged file wouldn't appear
    /// until the synthetic writer released.
    func testApplyPipelineStagesFilesWhileWriterQueueIsHeld() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-while-writer-busy".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(95, 'r', ?, ?)", arguments: [Date(), Date()])
        }

        let payload = ReferencePDFRecord(
            referenceId: 95, assetURL: src, assetVersion: 1,
            contentHash: "h", originalFilename: "busy.pdf", dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:95", payload: payload)

        let library = await SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )

        // Snapshot PDFs/ contents BEFORE running the pipeline so the
        // poll below can diff against a fixed baseline. Without this,
        // a stale `*_busy.pdf` from a prior run in the shared PDFs/
        // directory would false-positive the contention assertion.
        let baseline = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: AppDatabase.pdfStorageURL.path)) ?? []
        )

        // Hold the writer queue for 500ms in a sibling Task.
        let writerStarted = expectation(description: "writer-busy started")
        let writerDone = expectation(description: "writer-busy done")
        let blocker = Task.detached { [db] in
            try await db!.dbWriter.write { db in
                writerStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.5)
                try db.execute(sql: "UPDATE reference SET title='still here' WHERE id=95")
            }
            writerDone.fulfill()
        }
        await fulfillment(of: [writerStarted], timeout: 1.0)

        // Apply the batch. Prepare should stage the file promptly even
        // while the writer is busy.
        let applyTask = Task { await library.applyFetchedRecordsForTest(modifications: [record], deletions: []) }

        // Poll the PDFs/ dir up to 200ms for a NEW staged file matching
        // this test's `busy.pdf` originalFilename suffix. With the fix,
        // it appears within tens of ms (prepare runs without DB access).
        // Without the fix, no new file would appear until ~500ms.
        let deadline = Date().addingTimeInterval(0.2)
        var observedStagedFileWhileBusy = false
        while Date() < deadline {
            let current = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: AppDatabase.pdfStorageURL.path)) ?? []
            )
            let added = current.subtracting(baseline)
            if added.contains(where: { $0.hasSuffix("_busy.pdf") }) {
                observedStagedFileWhileBusy = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observedStagedFileWhileBusy,
                      "staged PDF must appear on disk while the writer queue is held — proves copy is outside the transaction")

        await fulfillment(of: [writerDone], timeout: 2.0)
        try await blocker.value
        await applyTask.value
    }
```

- [ ] **Step 2: Build and run the new tests, verify they pass**

Run: `swift test --filter PDFMaterializationStagingTests`
Expected: all seven pass (two prepare + three apply + two integration).

Run: `swift test --filter RubienSyncTests`
Expected: pre-existing tests still pass (the refactor of `applyFetchedZoneChanges` into `applyFetchedRecordsInternal` is observationally a no-op for the existing wire-format inputs).

---

### Task 1.9: Rewire `handleServerRecordChanged` to use the two-step pipeline

Goal: the `.serverRecordChanged` conflict path currently calls `applyRemoteRecord(.referencePDF, …)` inside its own `dbWriter.write` (`SyncedLibrary.swift:768-779`). That keeps a multi-MB `copyItem` inside the writer for every PDF merge collision. Replace the `.referencePDF` branch in that path with prepare-then-apply, and defer the prior-file unlink to *after* the outer commit.

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1: Replace the body of `handleServerRecordChanged`**

In `Sources/RubienSync/SyncedLibrary.swift`, locate `handleServerRecordChanged` (currently lines 755-783) and replace its body with:

```swift
    private func handleServerRecordChanged(
        type: SyncEntityType,
        entityId: String,
        error: CKError
    ) async {
        guard let serverRecord = error.serverRecord else {
            log.error("serverRecordChanged without serverRecord — re-fetch to recover")
            Task { [engine] in
                _ = try? await engine.fetchChanges()
            }
            return
        }

        // referencePDF: pre-stage the bytes outside the transaction. Mirrors
        // applyFetchedRecordsInternal so the writer queue is never held by
        // a large copyItem during conflict resolution. Validate the
        // entityId-Int64 round-trip BEFORE staging so a malformed name
        // never produces an orphaned file.
        //
        // Built via a `var` inside the if-branch (so prepare's throw can
        // return early) then frozen into a `let` so the dbWriter.write
        // closure below (which is @Sendable under Swift 6 strict
        // concurrency) captures an immutable value.
        let preparedPDF: SyncEntityType.PreparedReferencePDFMaterialization?
        if type == .referencePDF {
            guard Int64(entityId) != nil else {
                log.error("serverRecordChanged: malformed entityId \(entityId, privacy: .public); skipping merge")
                return
            }
            let staged: SyncEntityType.PreparedReferencePDFMaterialization?
            do {
                staged = try SyncEntityType.prepareReferencePDFMaterialization(record: serverRecord)
            } catch {
                log.error("serverRecordChanged prepare failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            // No staged file → no asset to apply. The CKRecord without an
            // asset is meaningless for a referencePDF row; skip merge.
            guard let staged else { return }
            preparedPDF = staged
        } else {
            preparedPDF = nil
        }

        // The closure RETURNS its `displacedFilename` to avoid mutating
        // captured locals across the @Sendable boundary (Swift-6 strict
        // concurrency). `commitFailed` is only ever assigned in the catch
        // block — outside the closure — so it can stay a `var`.
        var commitFailed = false
        var displacedFilename: String? = nil

        do {
            displacedFilename = try await appDatabase.dbWriter.write { [stateStore] db -> String? in
                try stateStore.setApplyingRemote(db)
                let displaced: String?
                if type == .referencePDF, let prepared = preparedPDF {
                    displaced = try SyncEntityType.applyPreparedReferencePDF(
                        prepared, entityId: entityId, db: db
                    )
                } else {
                    try type.applyRemoteRecord(serverRecord, entityId: entityId, db: db)
                    displaced = nil
                }
                try stateStore.markPulled(
                    db,
                    entityType: type,
                    entityId: entityId,
                    record: serverRecord
                )
                try stateStore.clearApplyingRemote(db)
                return displaced
            }
        } catch {
            log.error("serverRecordChanged merge failed: \(error.localizedDescription, privacy: .public)")
            commitFailed = true
        }

        // Post-commit file I/O (off the writer queue). On commit success
        // the staged file is now owned by `pdfCache` (the apply call
        // succeeded because pre-stage validated the entityId), so we
        // only need to unlink the displaced prior file (if any). On commit
        // failure we unlink the staged file we never promoted.
        if commitFailed {
            if let staged = preparedPDF?.stagedURL {
                try? FileManager.default.removeItem(at: staged)
            }
        } else if let displaced = displacedFilename {
            let url = AppDatabase.pdfStorageURL.appendingPathComponent(displaced)
            try? FileManager.default.removeItem(at: url)
        }
    }
```

- [ ] **Step 2: Build and run the full RubienSync target**

Run: `swift build --target RubienSync`
Expected: build succeeds.

Run: `swift test --filter RubienSyncTests`
Expected: all tests pass — `handleServerRecordChanged` is only triggered by `.serverRecordChanged` errors, which aren't exercised by the existing tests, so the refactor is observationally inert for them.

---

### Task 1.10: Commit Phase 1

- [ ] **Step 1: Stage and commit**

```bash
git add \
  Sources/RubienSync/SyncEntityDispatch.swift \
  Sources/RubienSync/SyncedLibrary.swift \
  Tests/RubienSyncTests/PDFMaterializationStagingTests.swift

git commit -m "$(cat <<'EOF'
sync: pre-stage PDF asset materialization outside the writer transaction

CKAsset bytes are copied into PDFs/ before opening the dbWriter.write that
applies a fetched batch — or that runs serverRecordChanged conflict merges
— so the GRDB writer queue is no longer held for the duration of a
multi-MB FileManager.copyItem. PDF reader rendering stays responsive while
sync pulls remote assets or resolves conflicts.

Splits SyncEntityType.applyRemoteRecord(.referencePDF) into a two-step
prepare → apply pipeline keyed by the recordName-derived entityId.
applyFetchedRecordsInternal (factored out of applyFetchedZoneChanges, with
a public test hook) pre-stages every referencePDF modification, applies
each as a tiny upsert, and unlinks prior + skipped + rolled-back staged
files post-commit. handleServerRecordChanged takes the same shape so
conflict-resolution doesn't drag a copyItem through the writer either.

The single-shot applyRemoteRecord(.referencePDF) wrapper is preserved as a
fallback for SyncEntityDispatchTests; no production hot path calls it
anymore.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Verify with status**

Run: `git status`
Expected: clean working tree.

---

## Phase 2 — Push-side: never let the engine see a `contentHash='pending'` row

Six tasks, one commit at the end. The strategy is two-layered:

1. **Startup catch-up**: `resolvePendingPDFContentHashes()` runs at `start()` *before* `_ = engine` so the engine literally cannot be asked for a push of a pending row at construction time.
2. **Per-import flow**: `drainPDFUploadQueueIntoSyncState` resolves the SHA-256 for each row *before* it inserts the `syncState` dirty marker, so a freshly-imported PDF's hash is real by the time the engine ever learns the row exists.

After these two layers the inline `contentHash == "pending"` branch in `buildPushRecord(.referencePDF)` is *unreachable through any current code path*: the `guard FileManager.default.fileExists(…)` check that precedes it returns nil for missing-file rows before the pending check is even evaluated, and both the startup resolver and the drainer's per-import resolve step run before any 'pending' row can be marked dirty in `syncState`. Kept as defense-in-depth only, in case a future code change marks a 'pending' row dirty by bypassing the drainer.

### Task 2.1: Write a failing test for the startup resolver

**Files:**
- Create: `Tests/RubienSyncTests/PendingPDFHashResolverTests.swift`

- [ ] **Step 1: Create the test file**

```swift
#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

/// Phase 2 contract: pending contentHash values are resolved *outside* any
/// transaction, and the engine never sees a 'pending' row.
final class PendingPDFHashResolverTests: XCTestCase {

    private var db: AppDatabase!
    private var pdfsAtSetUp: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        let dir = AppDatabase.pdfStorageURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pdfsAtSetUp = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        )
    }

    override func tearDown() {
        let dir = AppDatabase.pdfStorageURL
        let after = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        )
        for newFile in after.subtracting(pdfsAtSetUp) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(newFile))
        }
        db = nil
        super.tearDown()
    }

    private func seedPDFCacheRow(referenceId: Int64, contentHash: String, contents: String) throws -> String {
        let filename = "\(UUID().uuidString)_test.pdf"
        let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        try Data(contents.utf8).write(to: url)
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, 'r', ?, ?)", arguments: [referenceId, Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, ?, 1, ?, ?)
            """, arguments: [referenceId, filename, contentHash, Date(), Date()])
        }
        return filename
    }

    func testResolverReplacesPendingHashesWithRealSHA256() async throws {
        _ = try seedPDFCacheRow(referenceId: 1, contentHash: "pending", contents: "%PDF-1")
        _ = try seedPDFCacheRow(referenceId: 2, contentHash: "pending", contents: "%PDF-2-other")
        _ = try seedPDFCacheRow(referenceId: 3, contentHash: "deadbeef", contents: "%PDF-3-already-hashed")

        let library = await SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.resolvePendingPDFContentHashesForTest()

        try db.dbWriter.read { db in
            let h1 = try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
            let h2 = try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=2")
            let h3 = try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=3")
            XCTAssertNotEqual(h1, "pending", "row 1 should be resolved")
            XCTAssertNotEqual(h2, "pending", "row 2 should be resolved")
            XCTAssertNotEqual(h1, h2, "different bytes → different hashes")
            XCTAssertEqual(h3, "deadbeef", "non-pending rows untouched")
        }
    }

    func testResolverIsIdempotent() async throws {
        _ = try seedPDFCacheRow(referenceId: 1, contentHash: "pending", contents: "%PDF-1")
        let library = await SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.resolvePendingPDFContentHashesForTest()
        let firstHash = try db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
        }
        await library.resolvePendingPDFContentHashesForTest()
        let secondHash = try db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertEqual(firstHash, secondHash, "second pass is a no-op — no pending rows remain")
    }

    func testResolverTolerantOfMissingLocalFile() async throws {
        let filename = try seedPDFCacheRow(referenceId: 1, contentHash: "pending", contents: "%PDF-1")
        try FileManager.default.removeItem(at: AppDatabase.pdfStorageURL.appendingPathComponent(filename))

        let library = await SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.resolvePendingPDFContentHashesForTest()

        // Missing file → row stays 'pending'. The drainer's per-import
        // resolver path (Task 2.4) and the safety-net branch in
        // buildPushRecord both cover this anomaly path.
        let h = try db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertEqual(h, "pending")
    }
}
#endif
```

- [ ] **Step 2: Run, verify all three fail with "undefined" errors**

Run: `swift test --filter PendingPDFHashResolverTests`
Expected: FAIL — `resolvePendingPDFContentHashesForTest` is undefined.

---

### Task 2.2: Implement the startup resolver

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1: Add the resolver method and its test hook**

Append immediately after the existing `drainPDFUploadQueueIntoSyncState` method (around line 207 in `SyncedLibrary.swift`):

```swift
    // MARK: - Pending PDF content-hash resolver

    /// Walk `pdfCache` for rows still tagged with the migration sentinel
    /// `contentHash = 'pending'` and replace each with the real SHA-256 of
    /// the on-disk file. Runs as the FIRST step of `start()` so the engine
    /// is never constructed (and thus never auto-scheduled) while pending
    /// rows still exist.
    ///
    /// **No transaction wraps the SHA-256 compute.** Each row gets two tiny
    /// `dbWriter.read` / `dbWriter.write` hops: one to read the filename, one
    /// to write the resolved hash. Between them, `PDFContentHasher.sha256`
    /// streams the file with the writer queue free.
    ///
    /// Missing files are tolerated (logged + skipped). Leaving such a row
    /// at `contentHash='pending'` is safe: `buildPushRecord(.referencePDF)`
    /// returns nil for missing-file rows via an earlier `fileExists` guard,
    /// so no inline-hash branch is ever reached for them.
    func resolvePendingPDFContentHashes() async {
        let pendingIds: [Int64]
        do {
            pendingIds = try await appDatabase.dbWriter.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT referenceId FROM pdfCache
                    WHERE contentHash = 'pending' AND materializedAt IS NOT NULL
                """)
            }
        } catch {
            log.error("resolvePendingPDFContentHashes: failed to read pending list: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !pendingIds.isEmpty else { return }
        for id in pendingIds {
            await resolvePendingHashForReference(id)
        }
    }

    /// Resolve a single pdfCache row's pending hash. Used both by the
    /// startup catch-up (`resolvePendingPDFContentHashes`) and by the
    /// drainer's per-import path (Task 2.4). Idempotent for non-pending
    /// rows (WHERE contentHash = 'pending' guard on the UPDATE).
    func resolvePendingHashForReference(_ referenceId: Int64) async {
        let filename: String?
        do {
            filename = try await appDatabase.dbWriter.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ? AND contentHash = 'pending'",
                    arguments: [referenceId]
                )
            }
        } catch {
            log.error("resolvePendingHashForReference: read failed for \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let filename else { return }
        let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.info("resolvePendingHashForReference: file missing for \(referenceId, privacy: .public), leaving 'pending'")
            return
        }
        let hash: String
        do {
            hash = try PDFContentHasher.sha256(of: url)
        } catch {
            log.error("resolvePendingHashForReference: hash failed for \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try await appDatabase.dbWriter.write { db in
                try db.execute(
                    sql: "UPDATE pdfCache SET contentHash = ? WHERE referenceId = ? AND contentHash = 'pending'",
                    arguments: [hash, referenceId]
                )
            }
        } catch {
            log.error("resolvePendingHashForReference: write failed for \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Test hook for the bulk resolver.
    func resolvePendingPDFContentHashesForTest() async {
        await resolvePendingPDFContentHashes()
    }
```

- [ ] **Step 2: Run the resolver tests, verify they pass**

Run: `swift test --filter PendingPDFHashResolverTests`
Expected: all three pass.

---

### Task 2.3: Reorder `start()` so the resolver runs before the engine is constructed

Goal: today's `start()` builds the engine first (`_ = engine`) and then runs `ingestPendingChanges` and `drainPDFUploadQueue`. With auto-scheduling on, the engine can be asked for `nextRecordZoneChangeBatch` between any of those awaits. Move the resolver to the very top so the engine never sees a pending row.

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1: Replace the body of `start()`**

In `Sources/RubienSync/SyncedLibrary.swift` around lines 101-114, replace:

```swift
    public func start() async {
        _ = engine
        await performInitialBaselineIfNeeded()
        await compactStaleTombstones()
        await ingestPendingChanges()
        await drainPDFUploadQueue()
    }
```

with:

```swift
    public func start() async {
        // Step 1 — resolve any 'pending' contentHash rows BEFORE the engine
        // is constructed. Auto-scheduling means the engine can request a
        // push batch immediately after `_ = engine`; doing the resolver
        // first guarantees no in-flight push ever sees a pending row at
        // start. Self-gated on the feature flag — when PDF asset sync is
        // disabled, leaving rows 'pending' is harmless since no push code
        // reads them.
        if pdfAssetSyncEnabledProvider() {
            await resolvePendingPDFContentHashes()
        }

        _ = engine
        await performInitialBaselineIfNeeded()
        await compactStaleTombstones()
        await ingestPendingChanges()
        await drainPDFUploadQueue()
    }
```

- [ ] **Step 2: Build and run the full RubienSync target**

Run: `swift build --target RubienSync`
Expected: build succeeds.

Run: `swift test --filter RubienSyncTests`
Expected: all tests pass.

---

### Task 2.4: Eager-resolve pending hashes inside `drainPDFUploadQueueIntoSyncState`

Goal: freshly-imported PDFs (`AppDatabase.attachImportedPDFs`, `attachPDFInTransaction`) write `contentHash='pending'` and immediately enqueue an upload via `PDFUploadQueueBroadcaster`. The broadcaster wakes `drainPDFUploadQueue` (`SyncCoordinator.swift:278-281`). Resolve each row's hash here, *before* `syncState` ever sees the dirty marker, so the engine cannot pick up a pending row at any point in the import → push pipeline.

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1: Write a failing test for the eager-resolve contract**

Append to `Tests/RubienSyncTests/PendingPDFHashResolverTests.swift`, before the closing `}`:

```swift
    func testDrainerResolvesPendingHashBeforeMarkingDirty() async throws {
        let filename = try seedPDFCacheRow(referenceId: 1, contentHash: "pending", contents: "%PDF-drainer")
        _ = filename

        // Seed the upload queue so the drainer sees referenceId=1.
        let queue = PDFUploadQueue(db: db)
        try await queue.enqueue(referenceId: 1, localFilename: filename)

        let library = await SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        let drained = await library.drainPDFUploadQueueIntoSyncStateForTest()
        XCTAssertEqual(drained, [1])

        try db.dbWriter.read { db in
            // The drainer must have resolved the hash *before* the dirty
            // marker hit syncState.
            let hash = try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
            XCTAssertNotEqual(hash, "pending",
                              "drainer must resolve pending hash before marking syncState dirty")
            let dirty = try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState WHERE entityType='referencePDF' AND entityId='1'
            """)
            XCTAssertEqual(dirty, 1, "drainer should still mark the row dirty after resolving the hash")
        }
    }
```

Run: `swift test --filter PendingPDFHashResolverTests/testDrainerResolvesPendingHashBeforeMarkingDirty`
Expected: FAIL — `drainPDFUploadQueueIntoSyncStateForTest` doesn't exist, and the production drainer doesn't yet resolve hashes before marking dirty.

- [ ] **Step 2: Add the drainer's per-row hash resolution + test hook**

Edit `drainPDFUploadQueueIntoSyncState` (currently at `SyncedLibrary.swift:169-208`) to call `resolvePendingHashForReference` for each pending id *before* the bulk mark-dirty transaction. Replace the body with:

```swift
    func drainPDFUploadQueueIntoSyncState() async -> [Int64] {
        guard pdfAssetSyncEnabledProvider() else { return [] }

        let pendingIds: [Int64]
        do {
            pendingIds = try await pdfUploadQueue.pendingReferenceIds()
        } catch {
            log.error("drainPDFUploadQueue: failed to read queue: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard !pendingIds.isEmpty else { return [] }

        // Resolve each row's pending hash *outside* the upcoming mark-dirty
        // transaction. By the time the engine is told the row is dirty, its
        // pdfCache.contentHash is a real SHA-256 — the inline hash branch
        // in buildPushRecord(.referencePDF) is no longer the routine path
        // for fresh imports.
        for id in pendingIds {
            await resolvePendingHashForReference(id)
        }

        do {
            try await appDatabase.dbWriter.write { db in
                for id in pendingIds {
                    try db.execute(sql: """
                        INSERT INTO syncState(entityType, entityId, isDirty)
                            VALUES(?, ?, 1)
                            ON CONFLICT(entityType, entityId)
                                DO UPDATE SET isDirty = 1
                    """, arguments: [SyncEntityType.referencePDF.rawValue, String(id)])
                    try db.execute(
                        sql: "DELETE FROM pdfUploadQueue WHERE referenceId = ?",
                        arguments: [id]
                    )
                }
            }
        } catch {
            log.error("drainPDFUploadQueue: mark-dirty/clear write failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return pendingIds
    }
```

Then add a test hook below it:

```swift
    /// Test hook for the drainer's DB-side half. Production callers go
    /// through `drainPDFUploadQueue`, which additionally hands the IDs to
    /// the engine; the engine path raises CKException in an unentitled
    /// XCTest process, so tests use this hook.
    func drainPDFUploadQueueIntoSyncStateForTest() async -> [Int64] {
        await drainPDFUploadQueueIntoSyncState()
    }
```

- [ ] **Step 3: Run the drainer test, verify it passes**

Run: `swift test --filter PendingPDFHashResolverTests/testDrainerResolvesPendingHashBeforeMarkingDirty`
Expected: PASS.

- [ ] **Step 4: Run the full RubienSync target**

Run: `swift test --filter RubienSyncTests`
Expected: all tests pass.

---

### Task 2.5: Update the inline-hash branch comment in `buildPushRecord`

Goal: the inline branch is now defense-in-depth only — it's not reachable through any current code path (missing-file rows return nil from an earlier `fileExists` guard, and both resolver layers run before any 'pending' row can be marked dirty in `syncState`). Update the comment so future readers don't fall into the old assumption that this is normal-path code.

**Files:**
- Modify: `Sources/RubienSync/SyncEntityDispatch.swift`

- [ ] **Step 1: Update the comment block on the `contentHash == "pending"` branch**

In `Sources/RubienSync/SyncEntityDispatch.swift` around lines 171-185, replace the comment block (lines 171-177) with:

```swift
            // SAFETY NET — defense-in-depth only.
            //
            // Normal-path coverage:
            //   - migration backfill 'pending' rows: resolved at start()
            //     by SyncedLibrary.resolvePendingPDFContentHashes, BEFORE
            //     the engine is constructed;
            //   - freshly-imported 'pending' rows: resolved per-row by
            //     SyncedLibrary.drainPDFUploadQueueIntoSyncState, BEFORE
            //     the syncState dirty marker is written.
            //
            // Note: the early `guard FileManager.default.fileExists(...)
            // else { return nil }` above this block means this branch is
            // ALSO not reachable for rows whose local file has vanished —
            // the missing-file case returns nil before reaching the
            // 'pending' check. The only remaining reachability path is a
            // future code change that bypasses both resolver layers and
            // marks a 'pending' row dirty in syncState directly. Kept for
            // that defense-in-depth scenario only.
```

- [ ] **Step 2: Build**

Run: `swift build --target RubienSync`
Expected: build succeeds.

---

### Task 2.6: Commit Phase 2

- [ ] **Step 1: Stage and commit**

```bash
git add \
  Sources/RubienSync/SyncEntityDispatch.swift \
  Sources/RubienSync/SyncedLibrary.swift \
  Tests/RubienSyncTests/PendingPDFHashResolverTests.swift

git commit -m "$(cat <<'EOF'
sync: resolve PDF content hashes off the writer queue, never let the engine see 'pending'

Two-layer fix so the inline SHA-256 branch in buildPushRecord(.referencePDF)
stops being the routine path:

1. SyncedLibrary.start() now resolves pending pdfCache rows FIRST — before
   _ = engine — so the engine cannot be auto-scheduled to push a pending
   row at construction time. This pays the v2 migration backfill cost once,
   off any DB transaction.

2. SyncedLibrary.drainPDFUploadQueueIntoSyncState resolves each row's
   pending hash before writing the syncState dirty marker. Freshly-imported
   PDFs (attachImportedPDFs / attachPDFInTransaction write 'pending') now
   flow through hash resolution → mark dirty → engine push without ever
   queueing a hashable row at the engine layer.

The inline 'pending' branch in buildPushRecord survives as defense-in-depth
only — no current code path can reach it (missing-file rows already
short-circuit via an earlier fileExists guard, and both resolver layers
run before any 'pending' row reaches syncState).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Verify**

Run: `git status`
Expected: clean working tree.

---

## Phase 3 — Main-thread fix: fire-and-forget `markReferenceRead`

Three tasks, one commit at the end.

### Task 3.1: Update existing `ReaderWindowManagerTests` to poll for the async stamp

Goal: today's tests (`Tests/RubienTests/ReaderWindowManagerTests.swift:23-86`) read `lastReadAt` / `readCount` synchronously immediately after `recordReaderOpen` / `openPDFReader` / `openWebReader`. After Phase 3 dispatches the stamp onto a detached Task, those assertions race the async write. Replace each immediate read with a small polling helper that waits up to a generous timeout for the expected stamp/count.

**Files:**
- Modify: `Tests/RubienTests/ReaderWindowManagerTests.swift`

- [ ] **Step 1: Add a polling helper at the bottom of the test class**

Just before the closing `}` of `ReaderWindowManagerTests`, add:

```swift
    /// Polls `readState` until `expectation(state)` returns true or `timeout`
    /// elapses. Phase 3 dispatches `markReferenceRead` onto a detached Task,
    /// so reads immediately after `recordReaderOpen` race the write. Tests
    /// that observe the post-stamp state need to wait for it.
    private func waitForState(
        refId: Int64,
        in db: AppDatabase,
        timeout: TimeInterval = 1.0,
        until predicate: ((lastReadAt: Date?, readCount: Int)) -> Bool,
        line: UInt = #line
    ) throws -> (lastReadAt: Date?, readCount: Int) {
        let deadline = Date().addingTimeInterval(timeout)
        var last: (lastReadAt: Date?, readCount: Int) = (nil, 0)
        while Date() < deadline {
            last = try readState(refId: refId, in: db)
            if predicate(last) { return last }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("waitForState timed out; last observed state = \(last)", line: line)
        return last
    }
```

- [ ] **Step 2: Rewrite the affected tests to use the helper**

Replace `testRecordReaderOpenStampsLastReadAtAndBumpsCount` (lines 23-32):

```swift
    func testRecordReaderOpenStampsLastReadAtAndBumpsCount() throws {
        let db = try makeDatabase()
        let refId = try insertReference(in: db)

        ReaderWindowManager.shared.recordReaderOpen(referenceId: refId, db: db)

        let state = try waitForState(refId: refId, in: db) { $0.readCount == 1 }
        XCTAssertNotNil(state.lastReadAt, "recordReaderOpen must stamp lastReadAt")
        XCTAssertEqual(state.readCount, 1, "first stamp must bump readCount to 1")
    }
```

Replace `testOpenPDFReaderStampsReadOnFreshOpen` (lines 44-55):

```swift
    func testOpenPDFReaderStampsReadOnFreshOpen() throws {
        let db = try makeDatabase()
        let refId = try insertReference(in: db)
        try attachPDFCacheRow(refId: refId, in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openPDFReader(for: reference, db: db)

        let state = try waitForState(refId: refId, in: db) { $0.readCount == 1 }
        XCTAssertNotNil(state.lastReadAt, "openPDFReader must call recordReaderOpen on a fresh open")
        XCTAssertEqual(state.readCount, 1)
    }
```

Replace `testReopeningAlreadyOpenPDFWindowDoesNotRestamp` (lines 70-86):

```swift
    func testReopeningAlreadyOpenPDFWindowDoesNotRestamp() throws {
        let db = try makeDatabase()
        let refId = try insertReference(in: db)
        try attachPDFCacheRow(refId: refId, in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openPDFReader(for: reference, db: db)
        let firstState = try waitForState(refId: refId, in: db) { $0.readCount == 1 }

        ReaderWindowManager.shared.openPDFReader(for: reference, db: db)
        // Second open is a no-op; give the detached Task a moment to NOT
        // fire, then assert idempotency.
        Thread.sleep(forTimeInterval: 0.1)
        let secondState = try readState(refId: refId, in: db)

        XCTAssertEqual(secondState.readCount, firstState.readCount,
                       "refocusing an open PDF reader must not bump readCount")
        XCTAssertEqual(secondState.lastReadAt, firstState.lastReadAt,
                       "refocusing an open PDF reader must not re-advance lastReadAt")
    }
```

Replace `testOpenWebReaderStampsReadOnFreshOpen` (lines 90-100):

```swift
    func testOpenWebReaderStampsReadOnFreshOpen() throws {
        let db = try makeDatabase()
        let refId = try insertWebpageReference(in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openWebReader(for: reference, db: db)

        let state = try waitForState(refId: refId, in: db) { $0.readCount == 1 }
        XCTAssertNotNil(state.lastReadAt, "openWebReader must call recordReaderOpen on a fresh open")
        XCTAssertEqual(state.readCount, 1)
    }
```

Replace `testReopeningAlreadyOpenWebWindowDoesNotRestamp` (lines 115-130):

```swift
    func testReopeningAlreadyOpenWebWindowDoesNotRestamp() throws {
        let db = try makeDatabase()
        let refId = try insertWebpageReference(in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openWebReader(for: reference, db: db)
        let firstState = try waitForState(refId: refId, in: db) { $0.readCount == 1 }

        ReaderWindowManager.shared.openWebReader(for: reference, db: db)
        Thread.sleep(forTimeInterval: 0.1)
        let secondState = try readState(refId: refId, in: db)

        XCTAssertEqual(secondState.readCount, firstState.readCount,
                       "refocusing an open web reader must not bump readCount")
        XCTAssertEqual(secondState.lastReadAt, firstState.lastReadAt,
                       "refocusing an open web reader must not re-advance lastReadAt")
    }
```

The early-return tests (`testRecordReaderOpenSilentlyTolerantOfMissingReference`, `testOpenPDFReaderEarlyReturnsWhenNoPDFCached`, `testOpenWebReaderEarlyReturnsWhenCannotOpen`) keep their current shape — they assert *non-occurrence*, and a short sleep + read is equivalent to the prior synchronous check. Add a 100 ms sleep before the read in each of those three:

```swift
        Thread.sleep(forTimeInterval: 0.1)
        let state = try readState(refId: refId, in: db)
```

- [ ] **Step 3: Run the updated suite, expect it to still fail until the implementation lands**

Run: `swift test --filter ReaderWindowManagerTests`
Expected: tests using `waitForState` continue to pass because the current implementation IS synchronous (the polling helper trivially succeeds on the first poll). The suite stays green through the implementation change.

---

### Task 3.2: Write a failing test for non-blocking reader-open

**Files:**
- Create: `Tests/RubienTests/ReaderWindowManagerMainThreadTests.swift`

- [ ] **Step 1: Check whether the file already exists**

Run: `ls Tests/RubienTests/ | grep ReaderWindow`
Expected: only `ReaderWindowManagerTests.swift`.

- [ ] **Step 2: Create the new test file**

```swift
#if os(macOS)
import XCTest
import GRDB
@testable import Rubien
@testable import RubienCore

/// Phase 3 contract: opening a PDF reader never synchronously blocks the
/// main thread on a dbWriter.write. The mark-read bookkeeping is dispatched
/// onto a background Task so the writer queue being briefly busy with a
/// sync write doesn't translate into a UI freeze.
@MainActor
final class ReaderWindowManagerMainThreadTests: XCTestCase {

    func testRecordReaderOpenReturnsImmediatelyEvenWhenWriterIsBusy() async throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
        }

        // Synthetic writer-busy condition: occupy the writer queue with a
        // slow async write, then assert that recordReaderOpen returns before
        // it completes.
        let writerBusy = expectation(description: "writer-busy long task started")
        let writerDone = expectation(description: "writer-busy long task done")
        let blockerTask = Task.detached {
            try await db.dbWriter.write { db in
                writerBusy.fulfill()
                Thread.sleep(forTimeInterval: 0.4)
                try db.execute(sql: "UPDATE reference SET title='busy' WHERE id=1")
            }
            writerDone.fulfill()
        }
        await fulfillment(of: [writerBusy], timeout: 1.0)

        // Now invoke recordReaderOpen — it must return promptly.
        let start = Date()
        ReaderWindowManager.shared.recordReaderOpen(referenceId: 1, db: db)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05,
                          "recordReaderOpen must not synchronously wait on the writer queue (took \(elapsed)s)")

        // Drain the blocker so the test exits cleanly.
        await fulfillment(of: [writerDone], timeout: 2.0)
        try await blockerTask.value
    }
}
#endif
```

- [ ] **Step 3: Run, verify it fails**

Run: `swift test --filter ReaderWindowManagerMainThreadTests`
Expected: FAIL — `elapsed` exceeds 0.05s because the current implementation synchronously calls `db.markReferenceRead`.

---

### Task 3.3: Implement the fire-and-forget dispatch

**Files:**
- Modify: `Sources/Rubien/Views/ReaderWindowManager.swift`

- [ ] **Step 1: Update `recordReaderOpen`**

In `Sources/Rubien/Views/ReaderWindowManager.swift`, locate `recordReaderOpen` (currently lines 125-137) and replace the body with:

```swift
    func recordReaderOpen(referenceId: Int64, db: AppDatabase) {
        // Fire-and-forget on a background Task. markReferenceRead is a
        // dbWriter.write; when sync is actively applying remote changes the
        // writer queue may be briefly held by a small upsert (PDF asset I/O
        // no longer runs inside it after Phase 1/2 of the 2026-05-21
        // contention plan, but scalar batches still serialize). Synchronously
        // waiting on the queue from the main actor turns "tap to open" into
        // a perceptible freeze. The stamp is a usage metric — strictly
        // ordered persistence is not required for correctness.
        Task.detached(priority: .utility) {
            do {
                try db.markReferenceRead(id: referenceId)
            } catch {
                readerWindowLog.error(
                    "markReferenceRead failed for reference \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
```

- [ ] **Step 2: Run the new test, verify it passes**

Run: `swift test --filter ReaderWindowManagerMainThreadTests`
Expected: PASS.

- [ ] **Step 3: Run the full RubienTests target to confirm no regressions**

Run: `swift test --filter RubienTests`
Expected: all tests pass, including the rewritten `ReaderWindowManagerTests` from Task 3.1.

---

### Task 3.4: Commit Phase 3

- [ ] **Step 1: Stage and commit**

```bash
git add \
  Sources/Rubien/Views/ReaderWindowManager.swift \
  Tests/RubienTests/ReaderWindowManagerTests.swift \
  Tests/RubienTests/ReaderWindowManagerMainThreadTests.swift

git commit -m "$(cat <<'EOF'
reader: dispatch markReferenceRead off the main thread

Opening a PDF reader used to synchronously call db.markReferenceRead from
the main actor, which is a dbWriter.write. With the writer queue briefly
held by a sync batch upsert (even after pulling PDF I/O out of transactions
in the prior commits), this translated to a sub-second UI freeze on open.

Stamping last-read is a usage metric — strict-ordering is not required.
Fire it on a detached background Task instead. Existing
ReaderWindowManagerTests are updated to poll for the now-async stamp.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Verify**

Run: `git status`
Expected: clean working tree.

Run: `git log --oneline -3`
Expected: three new commits matching the three phases, in order.

---

## Post-implementation manual verification

The unit tests cover the architectural invariant (no file I/O inside writes) and end-state correctness. Verify the user-visible symptom is gone with a manual pass:

- [ ] **Step 1: Build the dev DMG**

Run: `./scripts/build-app.sh`
Expected: `build/Rubien.app` produced.

- [ ] **Step 2: Launch with sync ON and a library that has multiple PDFs**

If your dev signing setup is wired up (see `scripts/dev-launch.sh`), run it. Otherwise launch the bundle directly. Enable sync in Settings if not already, and ensure at least 3-5 references with attached PDFs exist locally.

- [ ] **Step 3: Trigger active sync**

Add or modify a reference on a peer device (or `rubien-cli` push from another sandbox) so the active device starts pulling. Watch Console.app for the "Rubien › SyncedLibrary" category — confirm `applyFetchedZoneChanges` is firing.

- [ ] **Step 4: Open a PDF reader during active sync**

Click a reference with an attached PDF. Confirm:
- The window appears immediately (no perceptible delay from click → window).
- The first page renders without showing the checkered blank state.
- Scrolling through pages does not stall — every page renders within a normal time budget.

- [ ] **Step 5: Decide whether to revert any phase**

If a phase regressed something, `git revert <sha>` for that commit only — each phase is intentionally independent. The diagnosis document is the reference for which symptom maps to which phase.
