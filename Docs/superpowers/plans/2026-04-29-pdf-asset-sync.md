# PDF asset sync (B8) — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync PDF binaries across devices via a sibling `CDReferencePDF` CKRecord carrying a `CKAsset`. Establish the architectural invariant *"synced tables hold no local-only columns"* and enforce it with a CI test, so the local-only-column-blanking class of bug we hit on 2026-04-29 cannot recur.

**Architecture:** New `CDReferencePDF` CKRecord (1:1 with Reference, recordName `referencePDF:<refId>`). Per-device materialization state lives in a new local-only `pdfCache` table; "yet-to-push" state lives in a new local-only `pdfUploadQueue` table. Both never sync; neither has a CKRecord; neither is observed by the dirty-tracking triggers. `Reference.pdfPath` is dropped — file path lookup goes through `pdfCache`. Mac mirrors eagerly on pull; iOS receives the lightweight record and fetches the asset on user-tap. LRU eviction skips rows still in the upload queue (don't lose unsynced work).

**Tech Stack:** Swift 5.10+, SwiftUI, GRDB 7, CKSyncEngine + `CKAsset`, swift-argument-parser (CLI), XCTest.

**Spec:** `Docs/superpowers/specs/2026-04-29-pdf-asset-sync-design.md`. Refer to it for design rationale on every choice below.

---

## File Structure

**Create:**
- `Sources/RubienCore/Services/PDFContentHasher.swift` — pure SHA-256-of-file utility (separable for unit testing)
- `Sources/RubienCore/Services/PDFAssetCache.swift` — actor over `pdfCache` table (materialize / pathFor / metadataFor / markOpened / dematerialize / evictIfOverCap)
- `Sources/RubienSync/ReferencePDFRecord.swift` — `populate` / `init` / `makeRecord` / `RecordField` / `allFieldNames` mirroring existing record-file pattern
- `Sources/RubienSync/PDFUploadQueue.swift` — actor that drains `pdfUploadQueue` rows by enqueuing `CDReferencePDF` pushes through the engine
- `Sources/Rubien/Views/PDFAvailability.swift` — `PDFAvailabilityState` enum + `.pdfAvailability(refId)` view modifier
- `Tests/RubienCoreTests/MigrationV2Tests.swift`
- `Tests/RubienCoreTests/PDFContentHasherTests.swift`
- `Tests/RubienCoreTests/PDFAssetCacheTests.swift`
- `Tests/RubienSyncTests/ReferencePDFRecordTests.swift`
- `Tests/RubienSyncTests/PDFUploadQueueTests.swift`
- `Tests/RubienSyncTests/SyncSchemaInvariantTests.swift`

**Modify:**
- `Sources/RubienCore/Database/AppDatabase.swift` — add v2 migration block; remove `pdfPath`-touching helpers; add `pdfFilename(for: id)` lookup
- `Sources/RubienCore/Models/Reference.swift` — drop `pdfPath` Swift property; drop column from `Columns` enum and the encode/decode + Hashable/Equatable references
- `Sources/RubienSync/SyncConstants.swift` — add `RecordType.referencePDF = "CDReferencePDF"`
- `Sources/RubienSync/SyncEntityType.swift` — add `.referencePDF` case
- `Sources/RubienSync/SyncEntityDispatch.swift` — add `.referencePDF` to `buildPushRecord` and `applyRemoteRecord` and `applyRemoteDelete`
- `Sources/RubienSync/SyncedLibrary.swift` — own a `PDFUploadQueue` instance; expose `pushReferencePDF(refId:)` and `fetchAsset(refId:)`
- `Sources/RubienSync/TagRecord.swift`, `PDFAnnotationRecord+CloudKit.swift`, `WebAnnotationRecord+CloudKit.swift`, `PropertyDefinitionRecord.swift`, `PropertyValueRecord.swift` — add `dateModified` field; add `static var allFieldNames: [String]`
- `Sources/RubienSync/ReferenceRecord.swift` — add `static var allFieldNames: [String]` (already includes `dateModified`)
- `Sources/RubienSync/MetadataIntakeRecord.swift`, `MetadataEvidenceRecord.swift`, `DatabaseViewRecord.swift`, `ReferenceTagRecord.swift` — add `static var allFieldNames: [String]`
- `Sources/Rubien/Views/*.swift` (8 files) — replace `reference.pdfPath` reads with cache lookups
- `Sources/Rubien/Views/RubienSettingsView.swift` — Sync section gains cache-used + backfill-progress visibility
- `Sources/RubienCLI/RubienCLI.swift` — add `pdf status <id>` subcommand; extend `sync status` JSON with `pdfBackfillRemaining`
- `Sources/RubienCore/Services/RubienPreferences.swift` — add `pdfAssetSyncEnabled: Bool` flag (default false until C5)
- `CLAUDE.md` — new "PDF asset sync" subsection under the sync description
- `Docs/Sync-Runbook.md` — manual smoke test for asset sync

**Drop:**
- `Reference.pdfPath` Swift property (every callsite migrates to cache lookup; see Phase A Task 8)
- `reference.pdfPath` DB column (in v2 migration, after data is copied to `pdfCache`)

---

## Phase A — Schema + local cache plumbing (commit C1)

This phase ships invisible to the user: the schema migrates, the `PDFAssetCache` exists and works, but no CloudKit sync of assets happens yet.

### Task 1: v2 migration creates `pdfCache` + `pdfUploadQueue` tables

**Files:**
- Modify: `Sources/RubienCore/Database/AppDatabase.swift` (v1 migration block ends ~line 510; add v2 below it)
- Test: `Tests/RubienCoreTests/MigrationV2Tests.swift`

- [ ] **Step 1: Write the failing test**

Path: `Tests/RubienCoreTests/MigrationV2Tests.swift`

```swift
import XCTest
import GRDB
@testable import RubienCore

final class MigrationV2Tests: XCTestCase {

    func testV2CreatesPdfCacheTable() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let cols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('pdfCache')")
                .map { $0["name"] as String }
            XCTAssertEqual(
                Set(cols),
                Set(["referenceId", "localFilename", "contentHash", "assetVersion", "materializedAt", "lastOpenedAt"]),
                "pdfCache schema must match the spec"
            )
        }
    }

    func testV2CreatesPdfUploadQueueTable() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let cols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('pdfUploadQueue')")
                .map { $0["name"] as String }
            XCTAssertEqual(
                Set(cols),
                Set(["referenceId", "localFilename", "queuedAt"]),
                "pdfUploadQueue schema must match the spec"
            )
        }
    }
}
```

- [ ] **Step 2: Run test to confirm failure**

Run: `swift test --filter MigrationV2Tests/testV2CreatesPdfCacheTable`

Expected: FAIL — `pdfCache` table doesn't exist.

- [ ] **Step 3: Add v2 migration block**

In `Sources/RubienCore/Database/AppDatabase.swift`, after the closing brace of `migrator.registerMigration("v1") { ... }`, before `return migrator`, add:

```swift
        migrator.registerMigration("v2") { db in
            // Per-device PDF cache. NOT in syncedTables — never observed by
            // dirty-tracking triggers, never has a CKRecord. The architectural
            // invariant the schema-invariant test enforces: synced tables hold
            // no local-only columns. Per-device materialization state is here,
            // not on `reference`.
            try db.create(table: "pdfCache") { t in
                t.column("referenceId", .integer)
                    .primaryKey()
                    .references("reference", onDelete: .cascade)
                t.column("localFilename", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("assetVersion", .integer).notNull().defaults(to: 1)
                t.column("materializedAt", .datetime)
                t.column("lastOpenedAt", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }
            try db.create(index: "pdfCache_lastOpenedAt", on: "pdfCache", columns: ["lastOpenedAt"])

            // Per-device "yet to push" queue. Drained by PDFUploadQueue actor
            // when sync is enabled. Same architectural rule as pdfCache:
            // local-only, never synced.
            try db.create(table: "pdfUploadQueue") { t in
                t.column("referenceId", .integer)
                    .primaryKey()
                    .references("reference", onDelete: .cascade)
                t.column("localFilename", .text).notNull()
                t.column("queuedAt", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }
            try db.create(index: "pdfUploadQueue_queuedAt", on: "pdfUploadQueue", columns: ["queuedAt"])
        }
```

- [ ] **Step 4: Run test to confirm pass**

Run: `swift test --filter MigrationV2Tests`

Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Database/AppDatabase.swift \
        Tests/RubienCoreTests/MigrationV2Tests.swift
git commit -m "add v2 migration: pdfCache + pdfUploadQueue tables (B8 schema)"
```

---

### Task 2: v2 migration backfills existing `pdfPath` data into `pdfCache`

**Files:**
- Modify: `Sources/RubienCore/Database/AppDatabase.swift` (extend the v2 block)
- Modify: `Tests/RubienCoreTests/MigrationV2Tests.swift`

- [ ] **Step 1: Write the failing backfill test**

Append to `Tests/RubienCoreTests/MigrationV2Tests.swift`:

```swift
    /// Pre-v2 references with a populated pdfPath must end up with a pdfCache row
    /// AND a pdfUploadQueue row after migration. Cache row's contentHash is a
    /// placeholder ("pending") because we hash lazily on first read or upload —
    /// hashing during migration would block app launch on a large library.
    func testV2BackfillsPdfPathIntoCacheAndQueue() throws {
        // Build a v1-shaped DB by hand (we can't roll back the migrator, so we
        // fake the v1 layout in-memory + then run only v2 manually).
        let queue = DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE reference (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    dateAdded TEXT NOT NULL,
                    dateModified TEXT NOT NULL,
                    pdfPath TEXT,
                    referenceType TEXT NOT NULL DEFAULT 'Journal Article',
                    verificationStatus TEXT NOT NULL DEFAULT 'legacy',
                    readingStatus TEXT NOT NULL DEFAULT 'unread',
                    authorsNormalized TEXT NOT NULL DEFAULT ''
                )
            """)
            try db.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified, pdfPath)
                VALUES
                  (1, 'with-pdf',  '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'PDFs/abc.pdf'),
                  (2, 'no-pdf',    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL),
                  (3, 'empty-pdf', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '')
            """)
        }

        // Run only the v2 part of the AppDatabase migrator. (We can do this by
        // calling AppDatabase.makeMigrator with a fake mark; in practice this
        // helper is added in the implementation step below.)
        try AppDatabase.runV2MigrationForTesting(on: queue)

        try queue.read { db in
            let cacheCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache") ?? -1
            XCTAssertEqual(cacheCount, 1, "only ref 1 had a non-empty pdfPath")

            let cached = try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=1")!
            XCTAssertEqual(cached["localFilename"] as String?, "PDFs/abc.pdf")
            XCTAssertEqual(cached["contentHash"] as String?, "pending")
            XCTAssertEqual(cached["assetVersion"] as Int64?, 1)
            XCTAssertNotNil(cached["materializedAt"] as String?)

            let queueCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? -1
            XCTAssertEqual(queueCount, 1, "ref 1 needs to be pushed up to CloudKit on next sync")

            let queued = try Row.fetchOne(db, sql: "SELECT * FROM pdfUploadQueue WHERE referenceId=1")!
            XCTAssertEqual(queued["localFilename"] as String?, "PDFs/abc.pdf")
        }
    }
```

- [ ] **Step 2: Run test to confirm failure**

Run: `swift test --filter MigrationV2Tests/testV2BackfillsPdfPathIntoCacheAndQueue`

Expected: FAIL — `runV2MigrationForTesting` doesn't exist; the existing v2 doesn't backfill.

- [ ] **Step 3: Extend the v2 migration with backfill + add the test helper**

In `Sources/RubienCore/Database/AppDatabase.swift`, extend the `migrator.registerMigration("v2", ...)` block (immediately after the `db.create(index: "pdfUploadQueue_queuedAt", ...)` line):

```swift
            // Backfill: every Reference with a non-empty pdfPath gets a
            // pdfCache row (hash = "pending"; recomputed on first open) and
            // a pdfUploadQueue row (so first-launch sync pushes the asset).
            // We don't try to compute SHA-256 here — could be 50MB files,
            // would block the migrator. Hash is lazy.
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                SELECT id, pdfPath, 'pending', 1, dateModified, dateModified
                FROM reference
                WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)

            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                SELECT id, pdfPath, dateModified
                FROM reference
                WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)
        }
```

Then, after the closing brace of the migrator definition (just before `return migrator`), add the test helper as a static func:

```swift
    /// Test-only: applies the v2 schema/backfill steps to an arbitrary
    /// queue that already carries a v1-shaped `reference` table. Used by
    /// `MigrationV2Tests` to verify backfill without driving the full
    /// AppDatabase init path.
    public static func runV2MigrationForTesting(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v2") { db in
            try db.create(table: "pdfCache") { t in
                t.column("referenceId", .integer).primaryKey()
                t.column("localFilename", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("assetVersion", .integer).notNull().defaults(to: 1)
                t.column("materializedAt", .datetime)
                t.column("lastOpenedAt", .datetime).notNull().defaults(sql: "datetime('now')")
            }
            try db.create(table: "pdfUploadQueue") { t in
                t.column("referenceId", .integer).primaryKey()
                t.column("localFilename", .text).notNull()
                t.column("queuedAt", .datetime).notNull().defaults(sql: "datetime('now')")
            }
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                SELECT id, pdfPath, 'pending', 1, dateModified, dateModified
                FROM reference WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                SELECT id, pdfPath, dateModified
                FROM reference WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)
        }
        try migrator.migrate(queue)
    }
```

(The helper duplicates a few lines from the real migrator; that's the cost of being able to test backfill in isolation. The duplication is intentional — the real migrator needs FK references and indexes which would over-constrain the test.)

- [ ] **Step 4: Run test to confirm pass**

Run: `swift test --filter MigrationV2Tests`

Expected: all tests PASS, including the backfill test.

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Database/AppDatabase.swift \
        Tests/RubienCoreTests/MigrationV2Tests.swift
git commit -m "v2 migration: backfill reference.pdfPath into pdfCache + pdfUploadQueue"
```

---

### Task 3: v2 migration drops `reference.pdfPath` column

**Files:**
- Modify: `Sources/RubienCore/Database/AppDatabase.swift` (extend v2 again)
- Modify: `Tests/RubienCoreTests/MigrationV2Tests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/RubienCoreTests/MigrationV2Tests.swift`:

```swift
    func testV2DropsPdfPathColumn() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let refCols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('reference')")
                .map { $0["name"] as String }
            XCTAssertFalse(
                refCols.contains("pdfPath"),
                "pdfPath column must be dropped from reference; lookups go through pdfCache"
            )
        }
    }
```

- [ ] **Step 2: Run test to confirm failure**

Run: `swift test --filter MigrationV2Tests/testV2DropsPdfPathColumn`

Expected: FAIL — `pdfPath` still in the table.

- [ ] **Step 3: Drop the column**

In the real v2 migration block in `AppDatabase.swift`, append after the two `INSERT INTO ... SELECT` statements:

```swift
            // Drop the now-orphan column. SQLite 3.35+ supports this directly.
            // macOS 14 ships SQLite 3.41+; we're well past the support floor.
            try db.execute(sql: "ALTER TABLE reference DROP COLUMN pdfPath")
```

- [ ] **Step 4: Run test**

Run: `swift test --filter MigrationV2Tests`

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Database/AppDatabase.swift \
        Tests/RubienCoreTests/MigrationV2Tests.swift
git commit -m "v2 migration: drop reference.pdfPath column (lookup now via pdfCache)"
```

---

### Task 4: `PDFContentHasher` utility (SHA-256 of file)

**Files:**
- Create: `Sources/RubienCore/Services/PDFContentHasher.swift`
- Test: `Tests/RubienCoreTests/PDFContentHasherTests.swift`

- [ ] **Step 1: Write the failing test**

Path: `Tests/RubienCoreTests/PDFContentHasherTests.swift`

```swift
import XCTest
@testable import RubienCore

final class PDFContentHasherTests: XCTestCase {

    func testHashesKnownContent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hasher-\(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = try PDFContentHasher.sha256(of: tmp)

        // Known SHA-256 of "hello world" (lowercase hex).
        XCTAssertEqual(hash, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    func testHashesEmptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hasher-\(UUID().uuidString).bin")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = try PDFContentHasher.sha256(of: tmp)
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testRejectsNonexistentFile() {
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try PDFContentHasher.sha256(of: bogus))
    }
}
```

- [ ] **Step 2: Run test to confirm failure**

Run: `swift test --filter PDFContentHasherTests`

Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

Path: `Sources/RubienCore/Services/PDFContentHasher.swift`

```swift
import Foundation
import CryptoKit

/// SHA-256 of a file's contents, returned as lowercase hex.
///
/// Streams the file in 1MB chunks rather than `Data(contentsOf:)` so a 50MB
/// PDF doesn't allocate 50MB. Used by `PDFAssetCache` for content-addressed
/// asset versioning and by sync push to detect "no actual change" uploads.
public enum PDFContentHasher {

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1_048_576
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: chunkSize),
                  !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run test**

Run: `swift test --filter PDFContentHasherTests`

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Services/PDFContentHasher.swift \
        Tests/RubienCoreTests/PDFContentHasherTests.swift
git commit -m "add PDFContentHasher: streaming SHA-256 of files"
```

---

### Task 5: `PDFAssetCache` actor

**Files:**
- Create: `Sources/RubienCore/Services/PDFAssetCache.swift`
- Test: `Tests/RubienCoreTests/PDFAssetCacheTests.swift`

- [ ] **Step 1: Write failing tests**

Path: `Tests/RubienCoreTests/PDFAssetCacheTests.swift`

```swift
import XCTest
import GRDB
@testable import RubienCore

final class PDFAssetCacheTests: XCTestCase {

    private var db: AppDatabase!
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pdfcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        db = nil
        try super.tearDownWithError()
    }

    private func makeRef(id: Int64) throws {
        try db.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, 'r', ?, ?)",
                arguments: [id, Date(), Date()]
            )
        }
    }

    private func makeFakePDF(name: String, contents: String = "%PDF-fake") throws -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testMaterializeWritesCacheRowAndCopiesFile() async throws {
        try makeRef(id: 1)
        let src = try makeFakePDF(name: "src.pdf")
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)

        let result = try await cache.materialize(
            referenceId: 1,
            sourceURL: src,
            originalFilename: "paper.pdf",
            assetVersion: 1
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.localURL.path))
        let row = try await db.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["assetVersion"] as Int64?, 1)
        XCTAssertNotNil(row?["materializedAt"] as String?)
    }

    func testPathForReturnsNilWhenNotMaterialized() async throws {
        try makeRef(id: 1)
        // Insert a cache row with materializedAt = NULL (the iOS post-pull state).
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(1, 'x.pdf', 'h', 1, NULL)
            """)
        }
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)
        let url = try await cache.pathFor(referenceId: 1)
        XCTAssertNil(url, "row exists but materializedAt is NULL — file not on this device")
    }

    func testPathForReturnsURLWhenMaterialized() async throws {
        try makeRef(id: 1)
        let src = try makeFakePDF(name: "src.pdf")
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)
        _ = try await cache.materialize(referenceId: 1, sourceURL: src, originalFilename: "p.pdf", assetVersion: 1)

        let url = try await cache.pathFor(referenceId: 1)
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
    }

    func testMarkOpenedBumpsLastOpenedAt() async throws {
        try makeRef(id: 1)
        let src = try makeFakePDF(name: "src.pdf")
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)
        _ = try await cache.materialize(referenceId: 1, sourceURL: src, originalFilename: "p.pdf", assetVersion: 1)

        let before = try await db.dbWriter.read { db in
            try Date.fetchOne(db, sql: "SELECT lastOpenedAt FROM pdfCache WHERE referenceId=1")
        }!
        try await Task.sleep(nanoseconds: 10_000_000)
        try await cache.markOpened(referenceId: 1)
        let after = try await db.dbWriter.read { db in
            try Date.fetchOne(db, sql: "SELECT lastOpenedAt FROM pdfCache WHERE referenceId=1")
        }!
        XCTAssertGreaterThan(after, before)
    }

    func testDematerializeRemovesFileButKeepsRow() async throws {
        try makeRef(id: 1)
        let src = try makeFakePDF(name: "src.pdf")
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)
        let mat = try await cache.materialize(referenceId: 1, sourceURL: src, originalFilename: "p.pdf", assetVersion: 1)

        try await cache.dematerialize(referenceId: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mat.localURL.path))
        let row = try await db.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertNotNil(row, "row preserved so a future tap can re-fetch")
        XCTAssertNil(row?["materializedAt"] as String?)
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `swift test --filter PDFAssetCacheTests`

Expected: FAIL — `PDFAssetCache` doesn't exist.

- [ ] **Step 3: Implement the actor**

Path: `Sources/RubienCore/Services/PDFAssetCache.swift`

```swift
import Foundation
import GRDB

/// Per-device materialization state for PDF binaries.
///
/// Lives in the `pdfCache` DB table — a local-only table never observed by
/// sync triggers, never registered in `SyncEntityType`, never has a CKRecord.
/// This is the architectural defense against the local-only-column-clobber
/// bug class: assets that are device-local stay completely off the synced
/// schema. `Reference` has zero columns the CKRecord doesn't carry, so
/// remote pulls cannot wipe device-local state.
///
/// Materialization model:
/// - `materializedAt != NULL` → file exists at `storageRoot/localFilename`.
/// - `materializedAt == NULL` → metadata known (we've seen the asset record
///   on pull), but the file isn't on this device. Used for iOS on-demand.
public actor PDFAssetCache {

    private let db: AppDatabase
    private let storageRoot: URL

    public init(db: AppDatabase, storageRoot: URL) {
        self.db = db
        self.storageRoot = storageRoot
    }

    public struct MaterializeResult: Sendable {
        public let localURL: URL
        public let localFilename: String
        public let contentHash: String
    }

    public struct CacheEntry: Sendable {
        public let referenceId: Int64
        public let localFilename: String
        public let contentHash: String
        public let assetVersion: Int64
        public let materializedAt: Date?
        public let lastOpenedAt: Date
    }

    /// Copy `sourceURL` into our PDFs/ dir (under a fresh UUID-prefixed name
    /// modeled after `PDFService.importPDF`), upsert the cache row, and
    /// return the local URL + the file's SHA-256.
    ///
    /// Caller is responsible for ensuring `referenceId` exists in `reference`.
    public func materialize(
        referenceId: Int64,
        sourceURL: URL,
        originalFilename: String,
        assetVersion: Int64
    ) throws -> MaterializeResult {
        // Mirror PDFService.importPDF naming so the two paths are interchangeable.
        let localFilename = "\(UUID().uuidString)_\(originalFilename)"
        let dest = storageRoot.appendingPathComponent(localFilename)
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        let hash = try PDFContentHasher.sha256(of: dest)

        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(referenceId) DO UPDATE SET
                    localFilename = excluded.localFilename,
                    contentHash = excluded.contentHash,
                    assetVersion = excluded.assetVersion,
                    materializedAt = excluded.materializedAt,
                    lastOpenedAt = excluded.lastOpenedAt
            """, arguments: [referenceId, localFilename, hash, assetVersion, Date(), Date()])
        }

        return MaterializeResult(localURL: dest, localFilename: localFilename, contentHash: hash)
    }

    /// Resolve a Reference's local file URL if the asset is materialized on
    /// this device. Nil if the row is missing OR if `materializedAt` is NULL
    /// (iOS on-demand state) OR if the file vanished since materialization.
    public func pathFor(referenceId: Int64) throws -> URL? {
        let row = try db.dbWriter.read { db -> (filename: String, materialized: Bool)? in
            guard let r = try Row.fetchOne(db,
                sql: "SELECT localFilename, materializedAt FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            ) else { return nil }
            let filename: String = r["localFilename"]
            let mat: Date? = r["materializedAt"]
            return (filename, mat != nil)
        }
        guard let row, row.materialized else { return nil }
        let url = storageRoot.appendingPathComponent(row.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Return the cache row even if not materialized (used for iOS metadata-only state).
    public func metadataFor(referenceId: Int64) throws -> CacheEntry? {
        try db.dbWriter.read { db in
            guard let r = try Row.fetchOne(db,
                sql: "SELECT * FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            ) else { return nil }
            return CacheEntry(
                referenceId: r["referenceId"],
                localFilename: r["localFilename"],
                contentHash: r["contentHash"],
                assetVersion: r["assetVersion"],
                materializedAt: r["materializedAt"],
                lastOpenedAt: r["lastOpenedAt"]
            )
        }
    }

    /// Bump `lastOpenedAt`. Reader calls this on each open. LRU eviction
    /// orders by this column ascending.
    public func markOpened(referenceId: Int64) throws {
        try db.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE pdfCache SET lastOpenedAt = ? WHERE referenceId = ?",
                arguments: [Date(), referenceId]
            )
        }
    }

    /// Delete the local file but keep the row so a future tap can re-fetch.
    /// Used by both LRU eviction (Task 22) and explicit user "remove cached PDF".
    public func dematerialize(referenceId: Int64) throws {
        let filename: String? = try db.dbWriter.read { db in
            try String.fetchOne(db,
                sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }
        if let filename {
            let url = storageRoot.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        try db.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE pdfCache SET materializedAt = NULL WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PDFAssetCacheTests`

Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Services/PDFAssetCache.swift \
        Tests/RubienCoreTests/PDFAssetCacheTests.swift
git commit -m "add PDFAssetCache actor: per-device materialization state over pdfCache"
```

---

### Task 6: `AppDatabase.pdfFilename(for:)` lookup helper

**Files:**
- Modify: `Sources/RubienCore/Database/AppDatabase.swift`

- [ ] **Step 1: Write the helper**

In `Sources/RubienCore/Database/AppDatabase.swift`, alongside the existing helpers (e.g. near `updateReferencePDFPath`, which we'll remove in a later step), add:

```swift
    /// Resolve a Reference's local PDF filename via the cache. Returns nil
    /// if this device has never seen the asset (no `pdfCache` row) OR if the
    /// row exists but the file isn't materialized locally (iOS on-demand
    /// state — caller should treat this as "needs download").
    ///
    /// For the full URL, callers should compose with `pdfStorageURL` or use
    /// `PDFAssetCache.pathFor(referenceId:)` which also checks file existence.
    public func pdfFilename(for referenceId: Int64) throws -> String? {
        try dbWriter.read { db in
            try String.fetchOne(db, sql: """
                SELECT localFilename FROM pdfCache
                WHERE referenceId = ? AND materializedAt IS NOT NULL
            """, arguments: [referenceId])
        }
    }
```

- [ ] **Step 2: Build to verify**

Run: `swift build --target RubienCore 2>&1 | tail -5`

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienCore/Database/AppDatabase.swift
git commit -m "add AppDatabase.pdfFilename(for:) — cache-table lookup replacing Reference.pdfPath"
```

---

### Task 7: Remove `Reference.pdfPath` Swift property + Columns case + encode/decode

**Files:**
- Modify: `Sources/RubienCore/Models/Reference.swift`

This task is mechanical but spans several places where `pdfPath` is mentioned in the model. It does NOT yet update app callsites — Task 8 does that. After this task, `RubienCore` compiles but `Sources/Rubien/` won't.

- [ ] **Step 1: Remove the stored property**

In `Sources/RubienCore/Models/Reference.swift`, find and remove:

```swift
    public var pdfPath: String?
```

(at line ~202 in the version reviewed during planning)

- [ ] **Step 2: Remove the initializer parameter**

Find the initializer with `pdfPath: String? = nil` (~line 265) and remove that parameter and its assignment (`self.pdfPath = pdfPath`, ~line 317).

- [ ] **Step 3: Remove from Equatable / Hashable**

Remove `lhs.pdfPath == rhs.pdfPath,` from the `==` operator (~line 414).

Remove `hasher.combine(pdfPath)` from `hash(into:)` (~line 476).

- [ ] **Step 4: Remove from Columns enum and lightColumns**

In the `Columns` enum (~line 871), remove `pdfPath` from the case list. The line currently reads:

```swift
        case pdfPath, notes, webContent, siteName, favicon, referenceType, metadataSource
```

Change to:

```swift
        case notes, webContent, siteName, favicon, referenceType, metadataSource
```

In `lightColumns: [any SQLSelectable]` (~line 510), remove `Columns.pdfPath,`.

In `Reference.databaseSelection` if it's defined (search the file), remove `Columns.pdfPath` from any list.

- [ ] **Step 5: Remove from row decoding**

Find `pdfPath = row["pdfPath"]` (~line 763) and remove it.

- [ ] **Step 6: Remove from encode**

Find `container["pdfPath"] = pdfPath` (~line 827) and remove it.

- [ ] **Step 7: Remove from CodingKeys**

In the `CodingKeys` enum (~line 873), the `pdfPath` symbol appears in:

```swift
        case pdfPath, notes, webContent, siteName, favicon, referenceType, metadataSource
```

Change to:

```swift
        case notes, webContent, siteName, favicon, referenceType, metadataSource
```

- [ ] **Step 8: Build RubienCore to verify**

Run: `swift build --target RubienCore 2>&1 | tail -5`

Expected: `Build complete!`. (RubienSync compiles too — it only references `pdfPath` in commit and test fixtures we're updating later.)

- [ ] **Step 9: Build full app — expected to fail**

Run: `swift build 2>&1 | tail -25`

Expected: errors in `Sources/Rubien/Views/...` for every callsite that reads `reference.pdfPath`. This is intentional — Task 8 fixes them.

- [ ] **Step 10: Commit**

```bash
git add Sources/RubienCore/Models/Reference.swift
git commit -m "drop Reference.pdfPath property — file lookup moves to PDFAssetCache (B8)"
```

---

### Task 8: Migrate app callsites from `Reference.pdfPath` to cache lookup

**Files:**
- Modify: `Sources/Rubien/Views/ReferenceListView.swift`
- Modify: `Sources/Rubien/Views/ReferenceDetailView.swift`
- Modify: `Sources/Rubien/Views/PDFReaderView.swift`
- Modify: `Sources/Rubien/Views/ReaderWindowManager.swift`
- Modify: `Sources/Rubien/Views/AddReferenceView.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`
- Modify: `Sources/Rubien/Views/SearchReferenceView.swift`
- Modify: `Sources/Rubien/Views/PDFOutlineSidebarView.swift`
- Modify: `Sources/Rubien/Services/MetadataResolver.swift`

Each callsite is a "does this reference have a PDF?" check. The new convention: **the source of truth is the cache row's existence**, not a `pdfPath` field. We add a small `Reference.hasCachedPDF(in: AppDatabase)` helper for the synchronous check that's most common in views.

- [ ] **Step 1: Add the helper to RubienCore**

In `Sources/RubienCore/Models/Reference.swift`, alongside the model:

```swift
public extension Reference {
    /// True iff this device has a cache row for the reference, regardless of
    /// whether the file is currently materialized. Use for "show a PDF chip"
    /// UI — the chip is meaningful even when the file isn't downloaded yet
    /// (iOS on-demand state); the actual open path checks materialization.
    func hasPDFInCache(in db: AppDatabase) -> Bool {
        guard let id else { return false }
        return (try? db.dbWriter.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT 1 FROM pdfCache WHERE referenceId = ? LIMIT 1
            """, arguments: [id]) ?? false
        }) ?? false
    }
}
```

- [ ] **Step 2: Substitute callsites — `ReferenceListView`**

In `Sources/Rubien/Views/ReferenceListView.swift`:

Line ~290 (Equatable check):
```swift
        lhs.reference.pdfPath == rhs.reference.pdfPath &&
```
Replace with:
```swift
        lhs.hasPDF == rhs.hasPDF &&
```

Add a `var hasPDF: Bool` to whatever the surrounding row-equatable struct is — populate it from `reference.hasPDFInCache(in: db)` at construction time. (Reading the cache during Equatable would block — pre-compute.)

Line ~342:
```swift
            if reference.pdfPath != nil {
```
Replace with:
```swift
            if reference.hasPDFInCache(in: db) {
```

(`db` here must be in scope; it's an `@EnvironmentObject` or passed prop on the surrounding view. If not in scope yet, plumb it through; the surrounding view already needs it for other queries.)

- [ ] **Step 3: Substitute callsites — `ReferenceDetailView`**

In `Sources/Rubien/Views/ReferenceDetailView.swift` — five callsites:

Line ~66:
```swift
                if reference.pdfPath != nil { pdfCard }
```
→
```swift
                if reference.hasPDFInCache(in: db) { pdfCard }
```

Line ~75:
```swift
            if editingField == nil, reference.pdfPath != nil {
```
→
```swift
            if editingField == nil, reference.hasPDFInCache(in: db) {
```

Line ~194:
```swift
                if editedRef.pdfPath != nil {
```
→
```swift
                if editedRef.hasPDFInCache(in: db) {
```

Line ~200 — this is a `pdfPath = nil` assignment to indicate "remove PDF". Replace with a call into the cache:
```swift
                            editedRef.pdfPath = nil
```
→
```swift
                            try? db.dbWriter.write { db in
                                try db.execute(sql: "DELETE FROM pdfCache WHERE referenceId = ?", arguments: [editedRef.id])
                                try db.execute(sql: "DELETE FROM pdfUploadQueue WHERE referenceId = ?", arguments: [editedRef.id])
                            }
```

Line ~211 — assigning a path on a successful import. Was:
```swift
                            editedRef.pdfPath = path
```
This was paired with `PDFService.importPDF` returning a string filename. The whole flow now goes through `PDFAssetCache.materialize(...)`. Replace the import flow with:
```swift
                            // PDFService.prepareImportedPDF still produces the
                            // local file; we then push it into the cache so
                            // future loads + sync know about it.
                            let prep = try PDFService.prepareImportedPDF(from: fileURL)
                            try await pdfAssetCache.materialize(
                                referenceId: editedRef.id ?? 0,
                                sourceURL: URL(fileURLWithPath: AppDatabase.pdfStorageURL.appendingPathComponent(prep.pdfPath).path),
                                originalFilename: fileURL.lastPathComponent,
                                assetVersion: 1
                            )
                            // Enqueue for upload (sync will push if enabled)
                            try db.dbWriter.write { db in
                                try db.execute(sql: """
                                    INSERT OR REPLACE INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                                    VALUES (?, ?, ?)
                                """, arguments: [editedRef.id, prep.pdfPath, Date()])
                            }
```

(`pdfAssetCache: PDFAssetCache` becomes an `@EnvironmentObject`-style dependency on this view. Plumb it from `RubienApp`.)

Line ~890, ~1025-1030, ~1081 — same pattern. Wherever code reads `reference.pdfPath`, swap for `hasPDFInCache(in: db)` (boolean check) or `pdfAssetCache.pathFor(referenceId:)` (URL needed). Wherever it writes, route through the cache + queue.

- [ ] **Step 4: Substitute callsites — `PDFReaderView`**

`Sources/Rubien/Views/PDFReaderView.swift` line ~132:
```swift
        self.pdfURL = PDFService.pdfURL(for: reference.pdfPath ?? "")
```
Replace with an async lookup at view init:
```swift
        // Fail-fast: caller must only present this view when the PDF is
        // materialized; the SwiftUI host applies .pdfAvailability and only
        // navigates to PDFReaderView for the .materialized state. (See
        // PDFAvailability.swift in Phase C.)
        self.pdfURL = pdfAssetCache.cachedURLForReader(referenceId: reference.id ?? 0)
```

Add a sync helper on `PDFAssetCache` for this purpose (since it's called from a SwiftUI view init which can't be async). The helper does the same lookup as `pathFor` but without checking file existence:

```swift
    public nonisolated func cachedURLForReader(referenceId: Int64) -> URL {
        // Fast best-effort sync; storage path is stable so we just compose.
        // The file's existence is guaranteed by the .materialized state of
        // the upstream view modifier — if it's missing here, that's a bug.
        let filename = (try? db.dbWriter.read { db in
            try String.fetchOne(db, sql:
                "SELECT localFilename FROM pdfCache WHERE referenceId = ? AND materializedAt IS NOT NULL",
                arguments: [referenceId]
            )
        }) ?? ""
        return storageRoot.appendingPathComponent(filename)
    }
```

(Note: making `cachedURLForReader` `nonisolated` is safe because the actor's `db` is itself thread-safe via GRDB's `DatabaseQueue`, and `storageRoot` is `let`. This is the only nonisolated method on the actor; everything else stays actor-isolated for write coherence.)

- [ ] **Step 5: Substitute callsites — `ReaderWindowManager`**

`Sources/Rubien/Views/ReaderWindowManager.swift` line ~36:
```swift
        guard let refId = reference.id, reference.pdfPath != nil else { return }
```
→
```swift
        guard let refId = reference.id, reference.hasPDFInCache(in: db) else { return }
```

- [ ] **Step 6: Substitute callsites — `AddReferenceView`**

In `Sources/Rubien/Views/AddReferenceView.swift`, three sites at ~34, ~128, ~132, ~159, ~181. The view-local `@State private var pdfPath: String?` is *part of the local form state* — it's not reading `Reference.pdfPath`, so it stays. But the path it carries needs to be threaded into the cache when "Save" is tapped. Find the save flow and after the new Reference row is inserted, call:

```swift
        if let pdfPath {
            let storage = AppDatabase.pdfStorageURL.appendingPathComponent(pdfPath)
            try await pdfAssetCache.materialize(
                referenceId: newRefId,
                sourceURL: storage,
                originalFilename: pdfPath,    // "best-effort"; real name is lost by here
                assetVersion: 1
            )
            try db.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                    VALUES (?, ?, ?)
                """, arguments: [newRefId, pdfPath, Date()])
            }
        }
```

The pre-existing `pdfPath = try? PDFService.importPDF(from: fileURL)` line at ~181 stays — it places the file under the storage dir. The cache call above adopts that file.

- [ ] **Step 7: Substitute callsites — `ContentView`, `SearchReferenceView`, `PDFOutlineSidebarView`**

`ContentView.swift`:
- Line ~322 (`db.deleteReferencesReturningPDFPaths(ids:)`): this returns the file paths to clean up. Change the underlying `AppDatabase` method to query `pdfCache` instead of `reference.pdfPath`. Since the column is gone, this method must be renamed/rewritten:

```swift
    /// Delete references and return the list of cached local files to
    /// remove from disk. The caller is responsible for cleanup; we don't
    /// own the file system. Cascade FK to pdfCache means rows are gone
    /// already; we capture filenames before delete.
    public func deleteReferencesReturningCachedPDFFilenames(ids: [Int64]) throws -> [String] {
        try dbWriter.write { db in
            let filenames = try String.fetchAll(db, sql: """
                SELECT localFilename FROM pdfCache WHERE referenceId IN (\(ids.map { "\($0)" }.joined(separator: ",")))
            """)
            try db.execute(sql: """
                DELETE FROM reference WHERE id IN (\(ids.map { "\($0)" }.joined(separator: ",")))
            """)
            return filenames
        }
    }
```

- Line ~349 (`db.updateReferencePDFPath(id:pdfPath:)`): remove the method entirely (already obsolete — write through `PDFAssetCache.materialize` now). Find any other callers and route them through the cache too.
- Line ~1027 (intake assignment): `preferredPDFPath: intake.pdfPath` becomes a parameter that drives a post-save `PDFAssetCache.materialize` call. The `MetadataIntake` table still has its own `pdfPath` column — we're not touching that, only `Reference`'s.
- Line ~1214 (`reference.pdfPath = fallbackReference.pdfPath`): the fallback Reference's path is itself a stale concept post-B8. Read the fallback's cache row instead:
```swift
                    if let filename = try db.pdfFilename(for: fallbackReference.id ?? 0) {
                        // adopt the fallback's already-cached file by re-binding the cache row
                        let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
                        try await pdfAssetCache.materialize(
                            referenceId: reference.id ?? 0,
                            sourceURL: url,
                            originalFilename: filename,
                            assetVersion: 1
                        )
                    }
```

`SearchReferenceView.swift` line ~732 and `PDFOutlineSidebarView.swift` lines 151-152: same `reference.pdfPath != nil` → `hasPDFInCache(in: db)` and `PDFService.pdfURL(for: pdfPath)` → `pdfAssetCache.cachedURLForReader(referenceId:)` substitutions.

- [ ] **Step 8: Substitute callsites — `MetadataResolver`**

`Sources/Rubien/Services/MetadataResolver.swift` line ~512:
```swift
            ref.pdfPath = fallback.pdfPath
```
This is operating on a Reference value type that's about to be inserted. Since `Reference.pdfPath` is gone, this line is dead. Remove it. The cache adoption logic above (Step 7's "ContentView line ~1214") replaces the actual functionality.

- [ ] **Step 9: Build the full app**

Run: `swift build 2>&1 | tail -10`

Expected: `Build complete!`. If errors remain, they're remaining `pdfPath` callsites — fix using the same patterns above.

- [ ] **Step 10: Run the full test suite**

Run: `swift test 2>&1 | tail -10`

Expected: all tests pass except possibly some that explicitly reference `Reference.pdfPath` in fixtures — update those tests by removing the field, since the migration removes it.

- [ ] **Step 11: Commit**

```bash
git add Sources/Rubien/Views/ Sources/Rubien/Services/MetadataResolver.swift \
        Sources/RubienCore/Models/Reference.swift Sources/RubienCore/Database/AppDatabase.swift
git commit -m "migrate app callsites from Reference.pdfPath to PDFAssetCache (B8)"
```

---

### Task 9: C1 phase checkpoint — full build and test

**Files:** none (verification only)

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 2: Full test suite**

Run: `swift test 2>&1 | tail -5`

Expected: all tests pass. Note pass count for comparison after subsequent phases.

- [ ] **Step 3: Smoke run the app**

Run: `swift run Rubien` and verify:
- App launches
- Existing references show their PDF chips (if their pdfCache rows backfilled correctly)
- Opening a PDF still renders it
- Importing a new PDF still works (file ends up in PDFs/ dir, cache row created)

If anything's off, debug + fix; do not advance to Phase B with broken local behavior.

- [ ] **Step 4: Build the signed app and smoke test**

Run: `./scripts/build-app.sh && open build/Rubien.app`

Verify the same flows as Step 3 with the signed bundle.

- [ ] **Step 5: Verify the C1 phase commits are clean**

Run: `git log --oneline -8`

Expected: 8 commits since Task 1, all clean (no fix-ups). If there are dirty fix-ups, squash interactively (or just leave; squashing is optional).

---

## Phase B — Push path (commit C2)

This phase wires the upload side. Behind the `pdfAssetSyncEnabled` feature flag (off by default) until Phase E, so production users see no behavior change yet; tests cover the dispatch case end-to-end.

### Task 10: Register `CDReferencePDF` record type + create `ReferencePDFRecord.swift`

**Files:**
- Modify: `Sources/RubienSync/SyncConstants.swift`
- Create: `Sources/RubienSync/ReferencePDFRecord.swift`
- Test: `Tests/RubienSyncTests/ReferencePDFRecordTests.swift`

- [ ] **Step 1: Register the record type in SyncConstants**

In `Sources/RubienSync/SyncConstants.swift`, find the comment block "Note: CDReferencePDF (sibling asset record) is deferred to B8…". Replace that comment with:

```swift
        public static let referencePDF       = "CDReferencePDF"
```

The block now has 11 record types instead of 10 + a comment.

- [ ] **Step 2: Write the failing round-trip test**

Path: `Tests/RubienSyncTests/ReferencePDFRecordTests.swift`

```swift
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, *)
final class ReferencePDFRecordTests: XCTestCase {

    func testRoundTripPreservesAllFields() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-fake".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = ReferencePDFRecord(
            referenceId: 42,
            assetURL: tmp,
            assetVersion: 7,
            contentHash: "abc123",
            originalFilename: "paper.pdf",
            dateModified: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let ckRecord = ReferencePDFRecord.makeRecord(recordName: "referencePDF:42", payload: original)
        let decoded = ReferencePDFRecord(record: ckRecord)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.referenceId, 42)
        XCTAssertEqual(decoded?.assetVersion, 7)
        XCTAssertEqual(decoded?.contentHash, "abc123")
        XCTAssertEqual(decoded?.originalFilename, "paper.pdf")
        XCTAssertEqual(decoded?.dateModified, Date(timeIntervalSince1970: 1_700_000_000))
        // Asset URL post-decode points at CKAsset's downloaded file, not the
        // original tmp path. We don't assert path equality, only existence.
        XCTAssertNotNil(decoded?.assetURL)
    }

    func testInitFailsWithoutReferenceId() {
        let record = CKRecord(recordType: "CDReferencePDF", recordID: CKRecord.ID(recordName: "referencePDF:99"))
        // No referenceId field set — orphan record; init should fail.
        XCTAssertNil(ReferencePDFRecord(record: record))
    }

    func testAllFieldNamesIsComplete() {
        // The schema-invariant test (Task 29) introspects this list.
        // Every CKRecord field key declared in RecordField must appear here.
        let expected: Set<String> = [
            "referenceId", "asset", "assetVersion",
            "contentHash", "originalFilename", "dateModified"
        ]
        XCTAssertEqual(Set(ReferencePDFRecord.allFieldNames), expected)
    }
}
```

- [ ] **Step 3: Run test to confirm failure**

Run: `swift test --filter ReferencePDFRecordTests`

Expected: FAIL — `ReferencePDFRecord` doesn't exist.

- [ ] **Step 4: Implement**

Path: `Sources/RubienSync/ReferencePDFRecord.swift`

```swift
import Foundation
import CloudKit
import RubienCore

/// CKRecord ↔ payload mapping for `CDReferencePDF` — the sibling record that
/// carries a Reference's attached PDF as a `CKAsset`.
///
/// The local "where is this file on disk" state lives in `pdfCache` (a
/// device-local table); this struct is the wire-format only. The dispatch
/// layer (`SyncEntityDispatch`) is responsible for moving `pdfCache` rows
/// onto/off of CKRecord-shaped payloads.
public struct ReferencePDFRecord: Sendable {
    public let referenceId: Int64
    public let assetURL: URL?
    public let assetVersion: Int64
    public let contentHash: String
    public let originalFilename: String
    public let dateModified: Date

    public init(
        referenceId: Int64,
        assetURL: URL?,
        assetVersion: Int64,
        contentHash: String,
        originalFilename: String,
        dateModified: Date
    ) {
        self.referenceId = referenceId
        self.assetURL = assetURL
        self.assetVersion = assetVersion
        self.contentHash = contentHash
        self.originalFilename = originalFilename
        self.dateModified = dateModified
    }
}

extension ReferencePDFRecord {

    public enum RecordField {
        public static let referenceId      = "referenceId"
        public static let asset            = "asset"
        public static let assetVersion     = "assetVersion"
        public static let contentHash      = "contentHash"
        public static let originalFilename = "originalFilename"
        public static let dateModified     = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    public static let allFieldNames: [String] = [
        RecordField.referenceId,
        RecordField.asset,
        RecordField.assetVersion,
        RecordField.contentHash,
        RecordField.originalFilename,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.referenceId]      = referenceId
        if let assetURL { record[RecordField.asset] = CKAsset(fileURL: assetURL) }
        record[RecordField.assetVersion]     = assetVersion
        record[RecordField.contentHash]      = contentHash
        record[RecordField.originalFilename] = originalFilename
        record[RecordField.dateModified]     = dateModified
    }

    public static func makeRecord(recordName: String, payload: ReferencePDFRecord) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.referencePDF, recordID: id)
        payload.populate(record: record)
        return record
    }

    /// Failable: a record without `referenceId` is meaningless (no FK target).
    public init?(record: CKRecord) {
        guard let referenceId = record[RecordField.referenceId] as? Int64 else {
            return nil
        }
        self.referenceId = referenceId
        self.assetURL = (record[RecordField.asset] as? CKAsset)?.fileURL
        self.assetVersion = (record[RecordField.assetVersion] as? Int64) ?? 1
        self.contentHash = (record[RecordField.contentHash] as? String) ?? ""
        self.originalFilename = (record[RecordField.originalFilename] as? String) ?? "asset.pdf"
        self.dateModified = (record[RecordField.dateModified] as? Date) ?? Date()
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter ReferencePDFRecordTests`

Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RubienSync/SyncConstants.swift \
        Sources/RubienSync/ReferencePDFRecord.swift \
        Tests/RubienSyncTests/ReferencePDFRecordTests.swift
git commit -m "add ReferencePDFRecord: CKRecord <-> payload for CDReferencePDF (B8 push)"
```

---

### Task 11: Add `.referencePDF` case to `SyncEntityType` + dispatch

**Files:**
- Modify: `Sources/RubienSync/SyncEntityType.swift`
- Modify: `Sources/RubienSync/SyncEntityDispatch.swift`
- Modify: `Tests/RubienSyncTests/SyncEntityDispatchTests.swift`

- [ ] **Step 1: Add the enum case**

In `Sources/RubienSync/SyncEntityType.swift`, after `case databaseView`:

```swift
    case referencePDF       = "referencePDF"
```

Then add the matching `recordType` mapping (find the existing `recordType` switch in the same file or in `SyncConstants.swift` extension; add):

```swift
        case .referencePDF:       return SyncConstants.RecordType.referencePDF
```

- [ ] **Step 2: Write the failing dispatch test**

Append to `Tests/RubienSyncTests/SyncEntityDispatchTests.swift`:

```swift
    func testApplyRemoteReferencePDFMaterializesAssetOnMac() throws {
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-fake".utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(11, 'r', ?, ?)", arguments: [Date(), Date()])

            try self.store.setApplyingRemote(db)

            let payload = ReferencePDFRecord(
                referenceId: 11,
                assetURL: tmpFile,
                assetVersion: 1,
                contentHash: "deadbeef",
                originalFilename: "paper.pdf",
                dateModified: Date()
            )
            let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:11", payload: payload)

            try SyncEntityType.referencePDF.applyRemoteRecord(record, entityId: "11", db: db)

            try self.store.clearApplyingRemote(db)

            let cacheCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=11") ?? -1
            XCTAssertEqual(cacheCount, 1)

            let row = try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=11")!
            XCTAssertEqual(row["assetVersion"] as Int64?, 1)
            XCTAssertEqual(row["contentHash"] as String?, "deadbeef")
            #if !os(iOS)
            // Mac eagerly materializes — file should be on disk under PDFs/.
            XCTAssertNotNil(row["materializedAt"] as String?, "Mac should materialize on pull")
            #endif
        }
    }

    func testApplyRemoteReferencePDFDeleteRemovesCacheRow() throws {
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(11, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(11, 'x.pdf', 'h', 1, ?)
            """, arguments: [Date()])

            try self.store.setApplyingRemote(db)
            try SyncEntityType.referencePDF.applyRemoteDelete(entityId: "11", db: db)
            try self.store.clearApplyingRemote(db)

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=11") ?? -1,
                0
            )
        }
    }
```

- [ ] **Step 3: Run test to confirm failure**

Run: `swift test --filter SyncEntityDispatchTests/testApplyRemoteReferencePDFMaterializesAssetOnMac`

Expected: FAIL — switch doesn't have `.referencePDF` case (Swift compiler will error or runtime fatalError).

- [ ] **Step 4: Implement dispatch cases**

In `Sources/RubienSync/SyncEntityDispatch.swift`, add to `buildPushRecord(...)` switch (alongside existing cases):

```swift
        case .referencePDF:
            guard let id = Int64(entityId) else { return nil }
            // Read pdfCache + the actual file on disk; build a payload.
            let row: Row? = try Row.fetchOne(db,
                sql: "SELECT * FROM pdfCache WHERE referenceId = ? AND materializedAt IS NOT NULL",
                arguments: [id])
            guard let row else { return nil }
            let filename: String = row["localFilename"]
            let assetURL = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: assetURL.path) else { return nil }
            let payload = ReferencePDFRecord(
                referenceId: id,
                assetURL: assetURL,
                assetVersion: row["assetVersion"],
                contentHash: row["contentHash"],
                originalFilename: filename,
                dateModified: row["lastOpenedAt"]
            )
            let record = Self.rehydrateOrNew(
                systemFields: systemFields,
                recordType: recordType,
                recordName: qualifiedRecordName(entityId: entityId)
            )
            payload.populate(record: record)
            return record
```

Add to `applyRemoteRecord(...)` switch:

```swift
        case .referencePDF:
            guard let id = Int64(entityId), let payload = ReferencePDFRecord(record: record) else { return }
            #if os(iOS)
            // iOS: store metadata only; the asset bytes are already in the
            // CKAsset cache (CloudKit had to download to deliver the record),
            // but we don't promote them to permanent storage. User-tap kicks
            // off a fresh fetch that materializes (see Phase C).
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, ?, ?, NULL, ?)
                ON CONFLICT(referenceId) DO UPDATE SET
                    localFilename = excluded.localFilename,
                    contentHash = excluded.contentHash,
                    assetVersion = excluded.assetVersion,
                    materializedAt = NULL
            """, arguments: [id, payload.originalFilename, payload.contentHash, payload.assetVersion, Date()])
            #else
            // Mac: materialize. Copy CKAsset's file into our PDFs/ dir.
            guard let srcURL = payload.assetURL else { return }
            let localFilename = "\(UUID().uuidString)_\(payload.originalFilename)"
            let dest = AppDatabase.pdfStorageURL.appendingPathComponent(localFilename)
            try FileManager.default.createDirectory(at: AppDatabase.pdfStorageURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: srcURL, to: dest)
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(referenceId) DO UPDATE SET
                    localFilename = excluded.localFilename,
                    contentHash = excluded.contentHash,
                    assetVersion = excluded.assetVersion,
                    materializedAt = excluded.materializedAt
            """, arguments: [id, localFilename, payload.contentHash, payload.assetVersion, Date(), Date()])
            #endif
```

Add to `applyRemoteDelete(...)` switch:

```swift
        case .referencePDF:
            if let id = Int64(entityId) {
                // Capture filename before delete, then drop the row.
                let filename = try String.fetchOne(db,
                    sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                    arguments: [id])
                try db.execute(sql: "DELETE FROM pdfCache WHERE referenceId = ?", arguments: [id])
                if let filename {
                    let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: url)
                }
            }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter SyncEntityDispatchTests`

Expected: all PASS, including the two new ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/RubienSync/SyncEntityType.swift \
        Sources/RubienSync/SyncEntityDispatch.swift \
        Tests/RubienSyncTests/SyncEntityDispatchTests.swift
git commit -m "wire CDReferencePDF into SyncEntityDispatch (push + apply + delete)"
```

---

### Task 12: `PDFUploadQueue` actor

**Files:**
- Create: `Sources/RubienSync/PDFUploadQueue.swift`
- Test: `Tests/RubienSyncTests/PDFUploadQueueTests.swift`

- [ ] **Step 1: Write failing tests**

Path: `Tests/RubienSyncTests/PDFUploadQueueTests.swift`

```swift
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

final class PDFUploadQueueTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testEnqueueInsertsRow() async throws {
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
        }
        let queue = PDFUploadQueue(db: db)
        try await queue.enqueue(referenceId: 1, localFilename: "abc.pdf")

        let count = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue WHERE referenceId=1") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testRemoveByReferenceIdDeletesRow() async throws {
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt) VALUES(1, 'x.pdf', ?)
            """, arguments: [Date()])
        }
        let queue = PDFUploadQueue(db: db)
        try await queue.remove(referenceId: 1)

        let count = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func testPendingReferenceIdsReturnsAllInQueueOrder() async throws {
        try db.dbWriter.write { db in
            for i: Int64 in [1, 2, 3] {
                try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, 'r', ?, ?)", arguments: [i, Date(), Date()])
                try db.execute(sql: """
                    INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                    VALUES(?, ?, ?)
                """, arguments: [i, "f\(i).pdf", Date(timeIntervalSince1970: 1_000_000 + Double(i))])
            }
        }
        let queue = PDFUploadQueue(db: db)
        let ids = try await queue.pendingReferenceIds()
        XCTAssertEqual(ids, [1, 2, 3])
    }

    func testCountReturnsRowCount() async throws {
        let queue = PDFUploadQueue(db: db)
        let initialCount = try await queue.count()
        XCTAssertEqual(initialCount, 0)

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt) VALUES(1, 'x.pdf', ?)
            """, arguments: [Date()])
        }
        XCTAssertEqual(try await queue.count(), 1)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter PDFUploadQueueTests`

Expected: FAIL — `PDFUploadQueue` doesn't exist.

- [ ] **Step 3: Implement**

Path: `Sources/RubienSync/PDFUploadQueue.swift`

```swift
import Foundation
import GRDB
import RubienCore

/// Per-device queue of "PDFs not yet pushed to CloudKit." Drained by
/// `SyncedLibrary` when sync is enabled; otherwise rows accumulate
/// harmlessly and drain on next enable.
///
/// Local-only — never synced, never observed by dirty-tracking triggers.
public actor PDFUploadQueue {

    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    public func enqueue(referenceId: Int64, localFilename: String) throws {
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                VALUES(?, ?, ?)
            """, arguments: [referenceId, localFilename, Date()])
        }
    }

    public func remove(referenceId: Int64) throws {
        try db.dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM pdfUploadQueue WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }
    }

    /// Reference IDs of all queued rows, oldest-queued first.
    public func pendingReferenceIds() throws -> [Int64] {
        try db.dbWriter.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT referenceId FROM pdfUploadQueue ORDER BY queuedAt ASC
            """)
        }
    }

    public func count() throws -> Int {
        try db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? 0
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PDFUploadQueueTests`

Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienSync/PDFUploadQueue.swift \
        Tests/RubienSyncTests/PDFUploadQueueTests.swift
git commit -m "add PDFUploadQueue actor: device-local 'pending push' tracker"
```

---

### Task 13: Feature flag `pdfAssetSyncEnabled` in `RubienPreferences`

**Files:**
- Modify: `Sources/RubienCore/Services/RubienPreferences.swift`

- [ ] **Step 1: Add the flag**

In `RubienPreferences.swift`, alongside other flags:

```swift
    /// Gates the B8 PDF asset sync (CDReferencePDF push/pull). Default false
    /// from C2 → C5; flipped to true in Phase E once schema invariant test
    /// + dateModified cleanup land.
    public var pdfAssetSyncEnabled: Bool {
        get { defaults.bool(forKey: "rubien.pdfAssetSyncEnabled") }
        set { defaults.set(newValue, forKey: "rubien.pdfAssetSyncEnabled") }
    }
```

(Default `bool(forKey:)` returns `false` for unset keys, which is what we want.)

- [ ] **Step 2: Build to verify**

Run: `swift build --target RubienCore 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienCore/Services/RubienPreferences.swift
git commit -m "add pdfAssetSyncEnabled feature flag (default off until C5)"
```

---

### Task 14: Wire `PDFUploadQueue` drainer into `SyncedLibrary`

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

This task adds a method `drainUploadQueue()` and a `pushReferencePDF(refId:)` helper that the queue drainer calls. The actual scheduling — when does the drainer run? — is a Task spawned at `start()`.

- [ ] **Step 1: Add the upload queue property + drainer**

In `Sources/RubienSync/SyncedLibrary.swift`, add to the actor:

```swift
    private lazy var pdfUploadQueue: PDFUploadQueue = PDFUploadQueue(db: appDatabase)

    /// Push a single CDReferencePDF record for `refId` if its row in
    /// pdfCache is materialized. Called by the queue drainer.
    private func pushReferencePDF(refId: Int64) async throws {
        guard RubienPreferences.shared.pdfAssetSyncEnabled else { return }
        // Mark the entity as dirty so the engine's regular push cycle picks
        // it up alongside scalar dirty-flags. We're using the existing
        // dirty-row mechanism rather than a side-channel — keeps the engine
        // model uniform.
        try await stateStore.markDirty(
            entityType: SyncEntityType.referencePDF,
            entityId: String(refId),
            db: appDatabase
        )
        // Engine.scheduleSendChanges() if not already scheduled
        let engine = try ensureEngine()
        engine.state.add(pendingRecordZoneChanges: [
            .saveRecord(CKRecord.ID(
                recordName: SyncEntityType.referencePDF.qualifiedRecordName(entityId: String(refId)),
                zoneID: SyncConstants.libraryZoneID
            ))
        ])
    }

    /// Iterate all pending uploads and enqueue them with the engine. Idempotent.
    public func drainUploadQueue() async throws {
        guard RubienPreferences.shared.pdfAssetSyncEnabled else { return }
        let ids = try await pdfUploadQueue.pendingReferenceIds()
        for refId in ids {
            try? await pushReferencePDF(refId: refId)
        }
    }
```

(Implementation detail: `stateStore.markDirty(entityType:entityId:db:)` may already exist as a helper; if not, add it as a thin wrapper over the existing dirty-row insert SQL. The engine integration above uses `engine.state.add(pendingRecordZoneChanges:)` which is the API for explicit save schedules.)

- [ ] **Step 2: Hook drain into `start()`**

In `SyncedLibrary.start()` (or wherever the actor's startup code runs after the engine is ready), add a one-shot drain after the existing reconciliation:

```swift
        // Drain any backlog from previous sessions (or from the v2 migration's
        // backfill of existing local PDFs).
        Task { try? await self.drainUploadQueue() }
```

- [ ] **Step 3: Build to verify**

Run: `swift build --target RubienSync 2>&1 | tail -5`

Expected: `Build complete!`. (Some symbols referenced above may not exist verbatim in the actor — adapt to the actual code. The pattern is "call the engine's save-record scheduling API for the referencePDF record name.")

- [ ] **Step 4: Commit**

```bash
git add Sources/RubienSync/SyncedLibrary.swift
git commit -m "wire PDFUploadQueue drainer into SyncedLibrary lifecycle"
```

---

### Task 15: Hook import path to enqueue uploads

**Files:**
- Modify: `Sources/Rubien/Views/AddReferenceView.swift`
- Modify: `Sources/Rubien/Views/ReferenceDetailView.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`

(Most of this was already done in Task 8 via the cache + queue inserts on import.) The remaining work: kick the drainer once after import to push the new file immediately rather than waiting for the next sync cycle.

- [ ] **Step 1: Add drainer kick after each materialize**

After each `pdfAssetCache.materialize(...)` callsite added in Task 8, add:

```swift
        Task { try? await syncCoordinator.libraryActor?.drainUploadQueue() }
```

(Three sites: `AddReferenceView` save, `ReferenceDetailView` "replace PDF", `ContentView` intake commit.)

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/
git commit -m "kick upload-queue drainer after each PDF import"
```

---

### Task 16: C2 phase checkpoint — full build and test

**Files:** none (verification only)

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 2: Full tests**

Run: `swift test 2>&1 | tail -5`

Expected: all tests pass. Pass count should be roughly +6 from the C1 checkpoint (3 ReferencePDFRecord + 2 dispatch + 4 PDFUploadQueue + a few others = ~9 new tests).

- [ ] **Step 3: Verify flag is off in dev**

Run: `swift run Rubien` (no behavior change expected; flag is off; nothing should sync). Open the app, import a PDF, observe that the cache + queue rows are written but no upload happens.

You can verify the queue drained nothing with:
```bash
.build/debug/rubien-cli pdf status <id-of-imported-ref>
```
(That subcommand lands in Phase D Task 24; until then, query the DB directly: `sqlite3 ... "SELECT * FROM pdfUploadQueue"` should show entries that aren't being drained.)

- [ ] **Step 4: Done — Phase C next**

C2 is "code shipped, behavior gated off." Proceed to Phase C for the pull-side UX.

---

## Phase C — Pull path + on-demand UX (commit C3)

### Task 17: `PDFAvailability` view modifier + state enum

**Files:**
- Create: `Sources/Rubien/Views/PDFAvailability.swift`

- [ ] **Step 1: Create the file**

Path: `Sources/Rubien/Views/PDFAvailability.swift`

```swift
import SwiftUI
import RubienCore
import RubienSync

/// State of "do I have this PDF locally and can I render it right now?"
public enum PDFAvailabilityState: Equatable {
    case notUploaded                // no pdfCache row at all (ref has never had a PDF)
    case downloading(progress: Double?)
    case materialized(URL)
    case error(String)
}

/// View modifier that resolves a Reference's PDF availability and exposes
/// it via a binding the host view can switch on.
public struct PDFAvailabilityModifier: ViewModifier {
    let referenceId: Int64?
    @Binding var state: PDFAvailabilityState
    @EnvironmentObject var pdfAssetCache: PDFAssetCache
    @EnvironmentObject var syncCoordinator: SyncCoordinator

    public func body(content: Content) -> some View {
        content
            .task(id: referenceId) {
                await resolve()
            }
    }

    @MainActor
    private func resolve() async {
        guard let referenceId else {
            state = .notUploaded
            return
        }
        if let url = try? await pdfAssetCache.pathFor(referenceId: referenceId) {
            state = .materialized(url)
            return
        }
        // Cache row exists but not materialized → on-demand fetch path.
        if let meta = try? await pdfAssetCache.metadataFor(referenceId: referenceId) {
            state = .downloading(progress: nil)
            do {
                try await syncCoordinator.libraryActor?.fetchAsset(refId: referenceId)
                if let url = try? await pdfAssetCache.pathFor(referenceId: referenceId) {
                    state = .materialized(url)
                } else {
                    state = .error("Asset fetched but file not found on disk")
                }
            } catch {
                state = .error(error.localizedDescription)
            }
            _ = meta
        } else {
            state = .notUploaded
        }
    }
}

public extension View {
    func pdfAvailability(referenceId: Int64?, state: Binding<PDFAvailabilityState>) -> some View {
        modifier(PDFAvailabilityModifier(referenceId: referenceId, state: state))
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`

Expected: `Build complete!`. (`fetchAsset` is added in Task 18; if the reference is unresolved, fix in Task 18.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/PDFAvailability.swift
git commit -m "add PDFAvailabilityState + .pdfAvailability view modifier"
```

---

### Task 18: `SyncedLibrary.fetchAsset(refId:)`

**Files:**
- Modify: `Sources/RubienSync/SyncedLibrary.swift`

- [ ] **Step 1: Add the method**

In `SyncedLibrary`:

```swift
    /// On-demand fetch of a CDReferencePDF asset. Used when the local cache
    /// row says "metadata only" (iOS post-pull state) and the user opens
    /// the PDF.
    ///
    /// Implementation: ask the engine to fetch the specific record, which
    /// triggers the normal `applyRemoteRecord` path on completion (which on
    /// iOS will materialize since this is the on-demand entry point).
    public func fetchAsset(refId: Int64) async throws {
        guard RubienPreferences.shared.pdfAssetSyncEnabled else {
            throw NSError(domain: "Rubien.fetchAsset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Asset sync disabled"])
        }
        let recordID = CKRecord.ID(
            recordName: SyncEntityType.referencePDF.qualifiedRecordName(entityId: String(refId)),
            zoneID: SyncConstants.libraryZoneID
        )
        // Use a one-shot CKFetchRecordsOperation since CKSyncEngine doesn't
        // expose a direct "fetch this record" API — the engine handles
        // ambient pulls, but on-demand needs the lower-level API.
        let container = container()
        let database = container.privateCloudDatabase
        let op = CKFetchRecordsOperation(recordIDs: [recordID])
        op.desiredKeys = nil  // we want all fields, including the asset
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            op.fetchRecordsResultBlock = { result in
                guard !done else { return }
                done = true
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            op.perRecordResultBlock = { id, result in
                if case let .success(record) = result {
                    // Apply through the same dispatch path so the cache write
                    // happens. setApplyingRemote prevents trigger re-dirty.
                    Task {
                        try? await self.appDatabase.dbWriter.write { db in
                            try self.stateStore.setApplyingRemote(db)
                            try? SyncEntityType.referencePDF.applyRemoteRecord(record, entityId: String(refId), db: db)
                            try self.stateStore.clearApplyingRemote(db)
                        }
                    }
                }
            }
            database.add(op)
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build --target RubienSync 2>&1 | tail -5`

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienSync/SyncedLibrary.swift
git commit -m "add SyncedLibrary.fetchAsset(refId:) for on-demand asset materialization"
```

---

### Task 19: Reader integration — gate `PDFReaderView` on availability

**Files:**
- Modify: `Sources/Rubien/Views/ReferenceDetailView.swift` (or wherever `PDFReaderView` is presented)
- Modify: `Sources/Rubien/Views/PDFReaderView.swift`

- [ ] **Step 1: Wrap reader presentation in availability switch**

Find the SwiftUI host that presents `PDFReaderView` (typically `ReferenceDetailView` or `ReaderWindowManager`). Wrap with the new modifier:

```swift
    @State private var pdfAvail: PDFAvailabilityState = .notUploaded

    // ...inside the reader area:
    Group {
        switch pdfAvail {
        case .materialized(let url):
            PDFReaderView(reference: reference, pdfURL: url)
        case .downloading:
            VStack {
                ProgressView()
                Text("Downloading PDF...")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let msg):
            VStack {
                Text("Couldn't load PDF: \(msg)").foregroundStyle(.secondary)
                Button("Retry") {
                    pdfAvail = .notUploaded
                    // task(id:) re-fires; retries the resolve.
                }
            }
        case .notUploaded:
            Text("This reference has no attached PDF.").foregroundStyle(.secondary)
        }
    }
    .pdfAvailability(referenceId: reference.id, state: $pdfAvail)
```

- [ ] **Step 2: Update `PDFReaderView` initializer**

`PDFReaderView` already takes a URL implicitly via `cachedURLForReader` (Task 8 Step 4). With the new gating, the URL is a parameter:

```swift
    init(reference: Reference, pdfURL: URL) {
        self.reference = reference
        self.pdfURL = pdfURL
    }
```

Remove the previous `pdfAssetCache.cachedURLForReader(...)` call from `init` since the host now passes the URL directly.

- [ ] **Step 3: Build & smoke test**

Run: `swift build 2>&1 | tail -3` then `swift run Rubien`. Open a reference with a PDF; confirm the reader still works.

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/Views/
git commit -m "gate PDFReaderView on .pdfAvailability — handles on-demand download UX"
```

---

### Task 20: Detail panel shows annotation count when PDF not materialized

**Files:**
- Modify: `Sources/Rubien/Views/ReferenceDetailView.swift`

- [ ] **Step 1: Decouple annotation count from PDF presence**

Find the annotation count display. If it currently checks `pdfPath != nil` first, change to query annotations directly:

```swift
    let annotationCount: Int = (try? db.dbWriter.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfAnnotation WHERE referenceId = ?", arguments: [reference.id]) ?? 0
    }) ?? 0

    if annotationCount > 0 {
        Label("\(annotationCount) highlight\(annotationCount == 1 ? "" : "s")", systemImage: "highlighter")
    }
```

This now shows even when the PDF isn't downloaded on this device. Tapping the annotations label can open a list view (existing behavior; just don't gate it on PDF presence).

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/ReferenceDetailView.swift
git commit -m "show annotation count in detail panel even when PDF not materialized"
```

---

### Task 21: C3 phase checkpoint — full build, test, manual smoke test

**Files:** none

- [ ] **Step 1: Build + test**

Run: `swift build && swift test 2>&1 | tail -5`

Expected: pass.

- [ ] **Step 2: Manual smoke test on Mac (sync still off; just verify Phase C added no regressions)**

Run: `./scripts/build-app.sh && open build/Rubien.app`

Verify:
- Open a reference with a PDF → reader renders.
- Open a reference without a PDF → "This reference has no attached PDF" message.
- Annotation count shows for refs with annotations regardless of PDF state.

- [ ] **Step 3: Done — Phase D next**

---

## Phase D — Eviction + cap + visibility (commit C4)

### Task 22: `PDFAssetCache.evictIfOverCap()` with skip-upload-queue invariant

**Files:**
- Modify: `Sources/RubienCore/Services/PDFAssetCache.swift`
- Modify: `Tests/RubienCoreTests/PDFAssetCacheTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `PDFAssetCacheTests.swift`:

```swift
    func testEvictRemovesOldestUntilUnderCap() async throws {
        for id: Int64 in 1...3 {
            try makeRef(id: id)
        }
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)

        // Materialize three 100KB files, set cap to 250KB → expect oldest evicted.
        for id: Int64 in 1...3 {
            let src = try makeFakePDF(name: "src\(id).pdf", contents: String(repeating: "x", count: 100_000))
            _ = try await cache.materialize(referenceId: id, sourceURL: src, originalFilename: "p\(id).pdf", assetVersion: 1)
        }
        // Force lastOpenedAt ordering: ref 1 oldest, ref 3 newest
        try await db.dbWriter.write { db in
            try db.execute(sql: "UPDATE pdfCache SET lastOpenedAt = ? WHERE referenceId = 1", arguments: [Date(timeIntervalSinceNow: -300)])
            try db.execute(sql: "UPDATE pdfCache SET lastOpenedAt = ? WHERE referenceId = 2", arguments: [Date(timeIntervalSinceNow: -200)])
            try db.execute(sql: "UPDATE pdfCache SET lastOpenedAt = ? WHERE referenceId = 3", arguments: [Date(timeIntervalSinceNow: -100)])
        }

        try await cache.evictIfOverCap(maxBytes: 250_000)

        let materialized = try await db.dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT referenceId FROM pdfCache WHERE materializedAt IS NOT NULL ORDER BY referenceId")
        }
        XCTAssertEqual(materialized, [2, 3], "ref 1 evicted; refs 2, 3 retained")
    }

    func testEvictSkipsRowsInUploadQueue() async throws {
        for id: Int64 in 1...2 {
            try makeRef(id: id)
        }
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)

        for id: Int64 in 1...2 {
            let src = try makeFakePDF(name: "src\(id).pdf", contents: String(repeating: "x", count: 100_000))
            _ = try await cache.materialize(referenceId: id, sourceURL: src, originalFilename: "p\(id).pdf", assetVersion: 1)
        }
        // Ref 1 is older but is still pending upload — it must NOT be evicted.
        try await db.dbWriter.write { db in
            try db.execute(sql: "UPDATE pdfCache SET lastOpenedAt = ? WHERE referenceId = 1", arguments: [Date(timeIntervalSinceNow: -300)])
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt) VALUES(1, 'src1.pdf', ?)
            """, arguments: [Date()])
        }

        try await cache.evictIfOverCap(maxBytes: 50_000)  // very tight cap

        let materializedSet = try await db.dbWriter.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT referenceId FROM pdfCache WHERE materializedAt IS NOT NULL"))
        }
        XCTAssertTrue(materializedSet.contains(1), "must not evict files in pdfUploadQueue (unsynced work)")
    }
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `swift test --filter PDFAssetCacheTests/testEvictRemovesOldestUntilUnderCap`

Expected: FAIL — `evictIfOverCap` doesn't exist.

- [ ] **Step 3: Implement**

Add to `PDFAssetCache.swift`:

```swift
    /// Cap default. Hidden in v1; user-configurable surfaced as Open follow-up.
    public static let defaultCacheCapBytes: Int64 = 5_000_000_000

    /// Evict least-recently-opened materialized files until total cache size is
    /// at or below `maxBytes`. INVARIANT: never evicts rows still in
    /// `pdfUploadQueue` — those represent unsynced work and would be lost.
    /// If the cap can't be reached without violating the invariant, accept the
    /// overage and log; cap is a soft limit.
    public func evictIfOverCap(maxBytes: Int64 = Self.defaultCacheCapBytes) throws {
        // Snapshot candidates: materialized rows, oldest first, NOT in upload queue.
        let candidates: [(refId: Int64, filename: String)] = try db.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT pdfCache.referenceId AS refId, pdfCache.localFilename AS filename
                FROM pdfCache
                LEFT JOIN pdfUploadQueue ON pdfCache.referenceId = pdfUploadQueue.referenceId
                WHERE pdfCache.materializedAt IS NOT NULL
                  AND pdfUploadQueue.referenceId IS NULL
                ORDER BY pdfCache.lastOpenedAt ASC
            """).map { row in (row["refId"] as Int64, row["filename"] as String) }
        }

        var totalSize: Int64 = try totalCacheSize()
        for (refId, filename) in candidates where totalSize > maxBytes {
            let url = storageRoot.appendingPathComponent(filename)
            let size: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            try? FileManager.default.removeItem(at: url)
            try db.dbWriter.write { db in
                try db.execute(
                    sql: "UPDATE pdfCache SET materializedAt = NULL WHERE referenceId = ?",
                    arguments: [refId]
                )
            }
            totalSize -= size
        }
    }

    /// Sum of byte sizes for currently-materialized files. Used by Settings UX
    /// (Phase D Task 26) and by evictIfOverCap.
    public func totalCacheSize() throws -> Int64 {
        let filenames: [String] = try db.dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT localFilename FROM pdfCache WHERE materializedAt IS NOT NULL
            """)
        }
        var total: Int64 = 0
        for filename in filenames {
            let url = storageRoot.appendingPathComponent(filename)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PDFAssetCacheTests`

Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Services/PDFAssetCache.swift \
        Tests/RubienCoreTests/PDFAssetCacheTests.swift
git commit -m "PDFAssetCache: LRU evictIfOverCap with skip-upload-queue invariant"
```

---

### Task 23: Wire eviction trigger after each materialize

**Files:**
- Modify: `Sources/RubienCore/Services/PDFAssetCache.swift`

- [ ] **Step 1: Call eviction at end of materialize**

In the `materialize(...)` method, just before `return MaterializeResult(...)`:

```swift
        try? evictIfOverCap()
```

(`try?` because eviction failure is non-critical; we materialized successfully, the user can still open the file. A future log statement here is fine but not required.)

- [ ] **Step 2: Build + test**

Run: `swift test --filter PDFAssetCacheTests 2>&1 | tail -3`

Expected: pass — existing tests are happy with the additional eviction call (cap default is 5GB; no test seeds enough data to trigger eviction).

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienCore/Services/PDFAssetCache.swift
git commit -m "wire eviction trigger after each PDFAssetCache.materialize"
```

---

### Task 24: `rubien-cli pdf status <id>`

**Files:**
- Modify: `Sources/RubienCLI/RubienCLI.swift`
- Modify: `Tests/RubienCLITests/...` (or new file)

- [ ] **Step 1: Write failing CLI test**

Path: `Tests/RubienCLITests/PDFStatusTests.swift`

```swift
import XCTest

final class PDFStatusTests: XCTestCase {

    func testPdfStatusReturnsJSONShape() throws {
        // Assumes the developer's test library has at least one ref with
        // a cached PDF. If running in CI, this test should be skipped or
        // the test harness should seed a reference. For now: skip if not.
        let cli = RubienCLITestHelper.binaryURL
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = ["pdf", "status", "1"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("non-JSON CLI output")
            return
        }
        XCTAssertNotNil(json["referenceId"])
        XCTAssertNotNil(json["cached"])
        // Optional fields when cached: localFilename, contentHash, etc.
    }
}
```

(`RubienCLITestHelper.binaryURL` is the existing test helper that returns the path to `.build/debug/rubien-cli`.)

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter PDFStatusTests`

Expected: FAIL — subcommand doesn't exist.

- [ ] **Step 3: Implement**

In `Sources/RubienCLI/RubienCLI.swift`, add a subcommand. Find the `subcommands` array on the main parser and add:

```swift
struct PdfCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "PDF asset operations",
        subcommands: [PdfStatusCommand.self]
    )
}

struct PdfStatusCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show PDF cache state for a reference"
    )

    @Argument(help: "Reference id")
    var referenceId: Int64

    func run() throws {
        let db = try AppDatabase.makeShared()
        let row = try db.dbWriter.read { db -> [String: Any] in
            guard let r = try Row.fetchOne(db,
                sql: "SELECT * FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            ) else {
                return [
                    "referenceId": referenceId,
                    "cached": false,
                ]
            }
            let inQueue = (try Bool.fetchOne(db,
                sql: "SELECT 1 FROM pdfUploadQueue WHERE referenceId = ? LIMIT 1",
                arguments: [referenceId])) ?? false
            return [
                "referenceId": referenceId,
                "cached": r["materializedAt"] != nil,
                "localFilename": r["localFilename"] as String,
                "contentHash": r["contentHash"] as String,
                "assetVersion": (r["assetVersion"] as Int64),
                "materializedAt": (r["materializedAt"] as Date?)?.iso8601String() as Any,
                "lastOpenedAt": (r["lastOpenedAt"] as Date).iso8601String(),
                "inUploadQueue": inQueue,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
```

(`Date.iso8601String()` should exist as a small helper somewhere in the project — if not, add it.)

Then add `PdfCommand.self` to the main parser's `subcommands`.

- [ ] **Step 4: Run test**

Run: `swift build && swift test --filter PDFStatusTests`

Expected: PASS (assuming a ref with id=1 exists in the dev DB).

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCLI/RubienCLI.swift Tests/RubienCLITests/
git commit -m "add 'rubien-cli pdf status <id>' subcommand"
```

---

### Task 25: Extend `rubien-cli sync status` with `pdfBackfillRemaining`

**Files:**
- Modify: `Sources/RubienCLI/RubienCLI.swift`

- [ ] **Step 1: Find the sync-status JSON building**

Locate where `sync status` constructs the JSON dict. Add:

```swift
        let pdfBackfillRemaining = try db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? 0
        }
        // ... existing keys ...
        result["pdfBackfillRemaining"] = pdfBackfillRemaining
```

- [ ] **Step 2: Build + smoke**

Run: `swift build && .build/debug/rubien-cli sync status | grep pdfBackfill`

Expected: `"pdfBackfillRemaining": <number>`

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienCLI/RubienCLI.swift
git commit -m "extend 'rubien-cli sync status' JSON with pdfBackfillRemaining"
```

---

### Task 26: Settings → Sync section: cache used + backfill indicator

**Files:**
- Modify: `Sources/Rubien/Views/RubienSettingsView.swift`

- [ ] **Step 1: Add cache-status subview**

Inside the existing Sync settings section, add:

```swift
    @State private var cacheBytes: Int64 = 0
    @State private var backfillRemaining: Int = 0

    // ... inside the Sync section body:
    HStack {
        Text("PDF cache")
        Spacer()
        Text(ByteCountFormatter().string(fromByteCount: cacheBytes) + " / 5 GB")
            .foregroundStyle(.secondary)
    }
    if backfillRemaining > 0 {
        HStack {
            ProgressView()
            Text("Uploading \(backfillRemaining) PDF\(backfillRemaining == 1 ? "" : "s") to iCloud...")
                .foregroundStyle(.secondary)
        }
    }
    .task {
        cacheBytes = (try? await pdfAssetCache.totalCacheSize()) ?? 0
        backfillRemaining = (try? await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? 0
        }) ?? 0
    }
```

- [ ] **Step 2: Build + smoke test**

Run: `swift build && open build/Rubien.app` (after `./scripts/build-app.sh`).

Open Settings → Sync; verify the cache size and backfill count appear.

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/RubienSettingsView.swift
git commit -m "Settings → Sync: show PDF cache used + backfill progress"
```

---

### Task 27: C4 phase checkpoint

- [ ] **Step 1: Full build + tests**

Run: `swift build && swift test 2>&1 | tail -5`

Expected: pass; pass count up.

- [ ] **Step 2: Smoke test build-app**

Run: `./scripts/build-app.sh && open build/Rubien.app`

Verify Settings shows cache stats. (Sync still off via flag; backfill count stays at whatever pdfUploadQueue has.)

- [ ] **Step 3: Done — Phase E next**

---

## Phase E — Schema invariant + dateModified cleanup + flag flip (commit C5)

### Task 28: Add `static var allFieldNames: [String]` to every existing record extension

**Files:**
- Modify: `Sources/RubienSync/ReferenceRecord.swift`
- Modify: `Sources/RubienSync/TagRecord.swift`
- Modify: `Sources/RubienSync/ReferenceTagRecord.swift`
- Modify: `Sources/RubienSync/PDFAnnotationRecord+CloudKit.swift`
- Modify: `Sources/RubienSync/WebAnnotationRecord+CloudKit.swift`
- Modify: `Sources/RubienSync/MetadataIntakeRecord.swift`
- Modify: `Sources/RubienSync/MetadataEvidenceRecord.swift`
- Modify: `Sources/RubienSync/PropertyDefinitionRecord.swift`
- Modify: `Sources/RubienSync/PropertyValueRecord.swift`
- Modify: `Sources/RubienSync/DatabaseViewRecord.swift`

For each file, immediately after the `RecordField` enum, add a `static let allFieldNames: [String]` array listing every field by name. Example for `TagRecord.swift`:

```swift
extension Tag {
    public enum RecordField {
        public static let name  = "name"
        public static let color = "color"
    }

    public static let allFieldNames: [String] = [
        RecordField.name,
        RecordField.color,
    ]
    // ... rest
}
```

- [ ] **Step 1-10: Add `allFieldNames` to each record file**

Repeat the pattern above for each of the 10 files. The exact field list per file:

- `Reference`: title, authorsJSON, year, journal, volume, issue, pages, doi, url, abstract, dateAdded, dateModified, notes, webContent, siteName, favicon, referenceType, metadataSource, verificationStatus, acceptedByRuleID, recordKey, verificationSourceURL, evidenceBundleHash, verifiedAt, reviewedBy, readingStatus, publisher, publisherPlace, edition, editorsJSON, isbn, issn, accessedDate, issuedMonth, issuedDay, translatorsJSON, eventTitle, eventPlace, genre, institution, number, collectionTitle, numberOfPages, language, pmid, pmcid
- `Tag`: name, color (+ `dateModified` from Task 30)
- `ReferenceTag`: (no scalar fields; pivot — `allFieldNames` returns `[]`)
- `PDFAnnotationRecord`: referenceId, type, selectedText, noteText, color, pageIndex, boundsX, boundsY, boundsWidth, boundsHeight, rectsData, dateCreated (+ `dateModified` from Task 31)
- `WebAnnotationRecord`: referenceId, type, selectedText, noteText, color, anchorText, prefixText, suffixText, dateCreated (+ `dateModified` from Task 32)
- `MetadataIntake`: sourceKind, verificationStatus, title, originalInput, sourceURL, pdfPath, seedJSON, fallbackReferenceJSON, currentReferenceJSON, candidatesJSON, statusMessage, linkedReferenceId, evidenceBundleHash, createdAt, updatedAt
- `MetadataEvidence`: intakeId, referenceId, bundleHash, source, recordKey, sourceURL, fetchMode, payloadJSON, createdAt
- `PropertyDefinition`: name, type, optionsJSON, sortOrder, isDefault, defaultFieldKey, isVisible (+ `dateModified` from Task 33)
- `PropertyValue`: referenceId, propertyId, value (+ `dateModified` from Task 34)
- `DatabaseView`: name, icon, scopeJSON, columnsJSON, filtersJSON, sortsJSON, groupByJSON, columnWrapsJSON, isDefault, displayOrder, dateCreated, dateModified

- [ ] **Step 11: Build**

Run: `swift build --target RubienSync 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 12: Commit**

```bash
git add Sources/RubienSync/
git commit -m "publish allFieldNames on every record extension (precursor to schema-invariant test)"
```

---

### Task 29: `SyncSchemaInvariantTests` — the bug-class defense

**Files:**
- Create: `Tests/RubienSyncTests/SyncSchemaInvariantTests.swift`

- [ ] **Step 1: Write the test**

Path: `Tests/RubienSyncTests/SyncSchemaInvariantTests.swift`

```swift
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

/// THE BUG-CLASS DEFENSE.
///
/// On 2026-04-29 a routine launch of the signed app blanked `pdfPath` on every
/// Reference because the apply path wrote the full row from a CKRecord that
/// didn't carry pdfPath. Root cause shape: a synced table held a column the
/// CKRecord schema didn't carry; the apply path set it to nil; the GRDB UPDATE
/// wrote nil to the DB.
///
/// This test prevents that shape from recurring. For each `SyncEntityType`,
/// it diffs the synced table's persisted columns against the entity's
/// CKRecord field names. Any column on a synced table that isn't represented
/// in the CKRecord schema is a future blanking-bug waiting to happen.
///
/// Allowed exceptions live in `allowedExtraColumns`. The intent: this set is
/// EMPTY. If you find yourself adding a column here, ask whether the column
/// should be on a sibling local-only table instead (like `pdfCache` for
/// per-device PDF state).
final class SyncSchemaInvariantTests: XCTestCase {

    /// Per-table columns we explicitly allow to live on a synced table without
    /// matching CKRecord fields. This set MUST stay empty in mainline; a
    /// non-empty allow-list is acceptable only with a comment explaining why
    /// the column is auto-stamped or otherwise self-healing on apply.
    static let allowedExtraColumns: [String: Set<String>] = [
        // Example (hypothetical): "tag": ["someAutoComputedColumn"]
        :
    ]

    /// Columns we never expect in CKRecord (they're SQL plumbing or computed).
    static let neverInRecord: Set<String> = [
        "id",                 // local rowID; identity is in CKRecord.recordName
        "authorsNormalized",  // computed Swift property; recomputed on every encode
    ]

    func testEverySyncedColumnHasMatchingCKRecordField() throws {
        let db = try AppDatabase(DatabaseQueue())

        for entity in SyncEntityType.allCases {
            try assertSchemaSubset(entity: entity, db: db)
        }
    }

    private func assertSchemaSubset(entity: SyncEntityType, db: AppDatabase) throws {
        let tableName = entity.rawValue
        let columns: Set<String> = try db.dbWriter.read { db in
            Set(try Row.fetchAll(db,
                sql: "SELECT name FROM pragma_table_info(?)",
                arguments: [tableName]
            ).compactMap { $0["name"] as String })
        }
        guard !columns.isEmpty else {
            // If the table doesn't exist for this entity (e.g. .referencePDF
            // refers to no table — its state lives in pdfCache, which IS a
            // synced concept but the cache rows are local-only), skip.
            return
        }

        let fields: Set<String> = Set(allFieldNames(for: entity))
        let allowed: Set<String> = Self.allowedExtraColumns[tableName] ?? []

        let unexpected = columns
            .subtracting(fields)
            .subtracting(Self.neverInRecord)
            .subtracting(allowed)

        XCTAssertTrue(
            unexpected.isEmpty,
            """
            Synced table `\(tableName)` has columns not represented in its CKRecord
            schema: \(unexpected.sorted()).

            This is the shape of the 2026-04-29 pdfPath bug: on remote pull,
            applyRemoteRecord builds a model from the CKRecord (which lacks
            these columns), then row.update(db) writes nil to those columns.
            User data gets blanked silently.

            Fix one of:
              1) Add the column to the CKRecord schema (preferred when the
                 column is user-meaningful and should sync).
              2) Move the column to a dedicated local-only table that ISN'T
                 listed in syncedTables (the pdfCache pattern).
              3) Add the column to `SyncSchemaInvariantTests.allowedExtraColumns`
                 with a comment explaining why it's safe (e.g., auto-stamped
                 dateModified). Strongly discouraged.
            """
        )
    }

    private func allFieldNames(for entity: SyncEntityType) -> [String] {
        switch entity {
        case .reference:          return Reference.allFieldNames
        case .tag:                return Tag.allFieldNames
        case .referenceTag:       return ReferenceTag.allFieldNames
        case .pdfAnnotation:      return PDFAnnotationRecord.allFieldNames
        case .webAnnotation:      return WebAnnotationRecord.allFieldNames
        case .metadataIntake:     return MetadataIntake.allFieldNames
        case .metadataEvidence:   return MetadataEvidence.allFieldNames
        case .propertyDefinition: return PropertyDefinition.allFieldNames
        case .propertyValue:      return PropertyValue.allFieldNames
        case .databaseView:       return DatabaseView.allFieldNames
        case .referencePDF:       return ReferencePDFRecord.allFieldNames
        }
    }
}
```

- [ ] **Step 2: Run — expect failure (because dateModified is missing on five tables)**

Run: `swift test --filter SyncSchemaInvariantTests`

Expected: FAIL with messages naming `dateModified` as the unexpected column on `tag`, `pdfAnnotation`, `webAnnotation`, `propertyDefinition`, `propertyValue`. This is the bug class operating at compile time — exactly what we want.

- [ ] **Step 3: Commit**

```bash
git add Tests/RubienSyncTests/SyncSchemaInvariantTests.swift
git commit -m "add SyncSchemaInvariantTests: enforce 'no local-only columns on synced tables'"
```

---

### Task 30: Add `dateModified` field to `TagRecord`

**Files:**
- Modify: `Sources/RubienSync/TagRecord.swift`

- [ ] **Step 1: Add the field**

In `TagRecord.swift`, extend `RecordField`:

```swift
    public enum RecordField {
        public static let name         = "name"
        public static let color        = "color"
        public static let dateModified = "dateModified"
    }

    public static let allFieldNames: [String] = [
        RecordField.name,
        RecordField.color,
        RecordField.dateModified,
    ]
```

In `populate(record:)`:
```swift
        record[RecordField.dateModified] = dateModified
```

In `init(record:)`:
```swift
        self.dateModified = (record[RecordField.dateModified] as? Date) ?? Date()
```

- [ ] **Step 2: Run invariant test**

Run: `swift test --filter SyncSchemaInvariantTests`

Expected: still fails — but the failure should no longer mention `tag.dateModified`; the other four tables remain.

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienSync/TagRecord.swift
git commit -m "TagRecord: add dateModified field (schema invariant cleanup)"
```

---

### Task 31: Add `dateModified` to `PDFAnnotationRecord+CloudKit`

**Files:**
- Modify: `Sources/RubienSync/PDFAnnotationRecord+CloudKit.swift`

Same pattern as Task 30. Extend `RecordField`, `allFieldNames`, `populate`, `init`.

- [ ] **Step 1: Add the field**

```swift
    public enum RecordField {
        public static let referenceId   = "referenceId"
        public static let type          = "type"
        public static let selectedText  = "selectedText"
        public static let noteText      = "noteText"
        public static let color         = "color"
        public static let pageIndex     = "pageIndex"
        public static let boundsX       = "boundsX"
        public static let boundsY       = "boundsY"
        public static let boundsWidth   = "boundsWidth"
        public static let boundsHeight  = "boundsHeight"
        public static let rectsData     = "rectsData"
        public static let dateCreated   = "dateCreated"
        public static let dateModified  = "dateModified"
    }

    public static let allFieldNames: [String] = [
        RecordField.referenceId, RecordField.type, RecordField.selectedText,
        RecordField.noteText, RecordField.color, RecordField.pageIndex,
        RecordField.boundsX, RecordField.boundsY, RecordField.boundsWidth,
        RecordField.boundsHeight, RecordField.rectsData,
        RecordField.dateCreated, RecordField.dateModified,
    ]
```

In `populate`:
```swift
        record[RecordField.dateModified] = dateModified
```

In `init?`:
```swift
        // Note: dateModified is in PDFAnnotationRecord (the model). The init?
        // above sets it via the convenience initializer; override here so a
        // peer-supplied dateModified survives.
        if let d = record[RecordField.dateModified] as? Date {
            self.dateModified = d
        }
```

- [ ] **Step 2: Test**

Run: `swift test --filter SyncSchemaInvariantTests`

Expected: progress — 3 of 5 dateModified columns still flagged.

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienSync/PDFAnnotationRecord+CloudKit.swift
git commit -m "PDFAnnotationRecord: add dateModified field"
```

---

### Task 32: Add `dateModified` to `WebAnnotationRecord+CloudKit`

Same pattern as Task 31, applied to `WebAnnotationRecord`. Brief:

- [ ] **Step 1: Add `dateModified` to `RecordField`, `allFieldNames`, `populate`, `init?`**

- [ ] **Step 2: Run schema-invariant test**

Expected: 2 of 5 dateModified failures remain.

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienSync/WebAnnotationRecord+CloudKit.swift
git commit -m "WebAnnotationRecord: add dateModified field"
```

---

### Task 33: Add `dateModified` to `PropertyDefinitionRecord`

Same pattern.

- [ ] **Step 1-3: Repeat the field-addition pattern**

Commit:
```bash
git commit -m "PropertyDefinitionRecord: add dateModified field"
```

---

### Task 34: Add `dateModified` to `PropertyValueRecord`

Same pattern.

- [ ] **Step 1-3: Repeat**

Commit:
```bash
git commit -m "PropertyValueRecord: add dateModified field"
```

After this commit, run `swift test --filter SyncSchemaInvariantTests` — it should PASS with an empty allow-list.

---

### Task 35: Flip `pdfAssetSyncEnabled` default to true

**Files:**
- Modify: `Sources/RubienCore/Services/RubienPreferences.swift`

- [ ] **Step 1: Change the default**

```swift
    public var pdfAssetSyncEnabled: Bool {
        get {
            // Treat unset as true once B8 ships; users can opt out by setting false.
            if defaults.object(forKey: "rubien.pdfAssetSyncEnabled") == nil { return true }
            return defaults.bool(forKey: "rubien.pdfAssetSyncEnabled")
        }
        set { defaults.set(newValue, forKey: "rubien.pdfAssetSyncEnabled") }
    }
```

- [ ] **Step 2: Build + run all tests + smoke test**

```bash
swift build && swift test 2>&1 | tail -5
./scripts/build-app.sh && open build/Rubien.app
```

Expected: tests pass; signed app starts uploading the 31 backlog PDFs from the v2 backfill (visible in Settings → Sync as "Uploading X PDFs to iCloud..." which Task 26 added).

- [ ] **Step 3: Commit**

```bash
git add Sources/RubienCore/Services/RubienPreferences.swift
git commit -m "flip pdfAssetSyncEnabled to true (B8 ships)"
```

---

### Task 36: C5 phase checkpoint

- [ ] **Step 1: Full build + tests**

Run: `swift build && swift test 2>&1 | tail -10`

Expected: all pass; `SyncSchemaInvariantTests` reports its single test passes; allow-list is empty.

- [ ] **Step 2: Manual smoke on signed app**

Run: `./scripts/build-app.sh && open build/Rubien.app`

Verify in Settings → Sync that backfill drains over the next minutes (small 5-25MB files, low-tens-of-MB total — should complete in under a minute on home internet).

After drain completes, verify `rubien-cli sync status` reports `"pdfBackfillRemaining": 0`.

- [ ] **Step 3: Done — Phase F next**

---

## Phase F — Polish + docs (commit C6)

### Task 37: Settings backfill UX final polish

**Files:**
- Modify: `Sources/Rubien/Views/RubienSettingsView.swift`

This is iteration on Task 26's UX based on real-world feel after C5 ships. Targets: progress bar instead of bare count once total is known; per-PDF progress is overkill (engine doesn't expose it cleanly); a "Cancel uploads" button is out of scope (no use case yet).

- [ ] **Step 1: Add an initial-count latch + relative progress**

```swift
    @State private var initialBackfillCount: Int? = nil
    @State private var currentBackfill: Int = 0

    // ... inside the section body:
    if let initial = initialBackfillCount, initial > 0 {
        let done = max(0, initial - currentBackfill)
        VStack(alignment: .leading) {
            Text("Uploading PDFs to iCloud (\(done) of \(initial))")
            ProgressView(value: Double(done), total: Double(initial))
        }
    }
    .task {
        repeat {
            let count = (try? await db.dbWriter.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? 0
            }) ?? 0
            if initialBackfillCount == nil, count > 0 {
                initialBackfillCount = count
            }
            currentBackfill = count
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        } while currentBackfill > 0
        initialBackfillCount = nil
    }
```

- [ ] **Step 2: Build + smoke**

```bash
swift build && open build/Rubien.app
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/RubienSettingsView.swift
git commit -m "Settings: progress bar for PDF backfill upload"
```

---

### Task 38: Update CLAUDE.md with PDF asset sync section

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a subsection under the Sync description**

Find the "### Sync (RubienSync)" section. After its existing content, add:

```markdown
**PDF asset sync (B8).** PDF binaries sync as a sibling `CDReferencePDF` record carrying a `CKAsset`. Per-device materialization state lives in the local-only `pdfCache` table (never observed by sync triggers, never has a CKRecord). On Mac, `applyRemoteRecord(.referencePDF)` materializes the asset eagerly. On iOS, the apply path stores metadata only; the file fetch happens lazily on user-tap via `SyncedLibrary.fetchAsset(refId:)`. Eviction is LRU with a 5GB hidden cap, but **never evicts rows still in `pdfUploadQueue`** — that invariant is what protects unsynced work on iPad imports.

The architectural invariant *"synced tables hold no local-only columns"* is enforced by `Tests/RubienSyncTests/SyncSchemaInvariantTests.swift`. If you add a column to a synced table, you must also add the corresponding CKRecord field; otherwise the test fails. The allow-list is empty by design — adding to it requires a justifying comment.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: document PDF asset sync (B8) architecture and invariant"
```

---

### Task 39: Update `Docs/Sync-Runbook.md` with smoke test for asset sync

**Files:**
- Modify: `Docs/Sync-Runbook.md`

- [ ] **Step 1: Add a smoke test section**

Append:

```markdown
## PDF asset sync smoke test (post-B8)

After enabling sync on two Macs:

1. **Mac A:** Import a 5MB PDF onto a new Reference. Watch Settings → Sync → "Uploading 1 PDF" briefly; should clear in <30s.
2. **Mac B:** Wait ~30-60s for pull. Open the same Reference. PDF should render.
3. **Mac A:** Edit the Reference's notes. The CDReferencePDF asset should NOT re-upload (it's a separate record from CDReference; scalar edits don't touch it). Confirm via `rubien-cli sync status`: `pdfBackfillRemaining` stays 0.
4. **Mac A:** Delete the Reference. Mac B should drop both the Reference row AND the local PDF file via tombstone propagation.
5. **iCloud quota smoke:** if you have a small free tier and want to verify quota handling, use a large library — when the engine returns `.quotaExceeded`, the existing sync banner surfaces.

If any step fails, see `Docs/Sync-Runbook.md`'s general failure diagnostics section. Asset-specific diagnostic: `rubien-cli pdf status <id>` shows the cache row state for one Reference.
```

- [ ] **Step 2: Commit**

```bash
git add Docs/Sync-Runbook.md
git commit -m "Sync-Runbook: smoke test for PDF asset sync"
```

---

### Task 40: C6 phase checkpoint + final test run

- [ ] **Step 1: Full build + test**

Run: `swift build && swift test 2>&1 | tail -10`

Expected: all pass.

- [ ] **Step 2: Build signed app + final smoke**

Run: `./scripts/build-app.sh && open build/Rubien.app`

Walk through the smoke test in `Docs/Sync-Runbook.md`. Verify:
- Backfill from C5 has drained.
- Importing a new PDF uploads within seconds.
- (If you have a second Mac available) log in there with the same iCloud account, observe pull, open a PDF.

- [ ] **Step 3: Tag the merge point**

```bash
git log --oneline -50 | head
```

The B8 implementation should now be ~40 commits since Task 1, all clean. If the user wants a single squash-merge into main, do that here; otherwise the per-task commits stand on their own.

---

## Self-review

Spec coverage check (mapping each spec section/requirement to tasks):
- "New CKRecord type CDReferencePDF" → Task 10
- "New local-only DB tables pdfCache + pdfUploadQueue" → Tasks 1, 2
- "v2 schema migration drops pdfPath" → Task 3
- "PDFAssetCache actor" → Tasks 5, 22, 23
- "PDFContentHasher" → Task 4
- "ReferencePDFRecord.swift" → Task 10
- "SyncEntityType.referencePDF case + dispatch" → Task 11
- "PDFUploadQueue actor" → Task 12
- "Feature flag pdfAssetSyncEnabled" → Tasks 13, 35
- "Wire upload-queue drainer into SyncedLibrary" → Task 14
- "Backfill enqueue for existing local PDFs" → Task 2 (migration backfill) + Task 14 (drainer)
- "PDFAvailability view modifier" → Task 17
- "On-demand fetch via SyncedLibrary.fetchAsset" → Task 18
- "Reader integration" → Task 19
- "Detail panel shows annotation count when not materialized" → Task 20
- "LRU eviction with skip-upload-queue invariant" → Task 22
- "Cache cap default 5GB" → Task 22 (defaultCacheCapBytes)
- "rubien-cli pdf status" → Task 24
- "rubien-cli sync status: pdfBackfillRemaining" → Task 25
- "Settings cache used + backfill indicator" → Tasks 26, 37
- "Schema-invariant test" → Tasks 28, 29
- "dateModified cleanup across record types" → Tasks 30-34
- "CLAUDE.md update" → Task 38
- "Sync-Runbook update" → Task 39

All sections covered. The Open Follow-ups (pinning, user-configurable cache, cellular toggle, multi-asset, dedup, annotation drift, recover-from-orphan-files CLI) are out of scope per the spec — not represented as tasks, intentionally.

Placeholder check: no "TBD"/"TODO" in the plan.

Type consistency check:
- `PDFAssetCache.materialize(referenceId:sourceURL:originalFilename:assetVersion:) -> MaterializeResult` — same signature in Tasks 5, 7, 8, 11, 19.
- `PDFAssetCache.pathFor(referenceId:) -> URL?` — same signature throughout.
- `PDFUploadQueue.enqueue(referenceId:localFilename:)` — same in Tasks 12, 8, 15.
- `SyncedLibrary.fetchAsset(refId:)` — same in Tasks 17, 18.
- `SyncEntityType.referencePDF` — added in Task 11, used in 14, 18, 25, 28, 29.
- `Reference.allFieldNames` etc. — added in Task 28, used in Task 29.

No drift detected.

---

## Notes for the implementer

- The plan totals ~40 tasks across 6 phases (~5-10 days of focused work).
- Each phase ends with a checkpoint task that runs the full test suite + smoke test. Don't skip these — sync bugs surface only when the whole stack runs.
- The feature flag (`pdfAssetSyncEnabled`) means C2-C4 ship dormant. You can merge phases independently if you want shorter PRs; the user-visible behavior change happens at C5.
- The bug we're defending against (`pdfPath` blanking) was real and recent. The schema invariant test in Task 29 is the structural defense; if it ever fails with an "allowed exception" being added, push back hard before accepting that diff.
