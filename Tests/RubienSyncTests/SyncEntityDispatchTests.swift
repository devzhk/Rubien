#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// End-to-end dispatch tests that round-trip through a real in-memory DB.
/// Exercises the push path (DB row → CKRecord) and the pull path
/// (CKRecord → DB row) together so any drift between them surfaces.
final class SyncEntityDispatchTests: XCTestCase {

    private var db: AppDatabase!
    private let store = SyncStateStore()

    /// Snapshot of `AppDatabase.pdfStorageURL` contents at test start.
    /// `applyRemoteRecord(.referencePDF)` resolves its destination via the
    /// class-load-time static `pdfStorageURL`, so tests that exercise the
    /// pull path write into the dev's real PDFs/ dir on this machine.
    /// Without an after-test sweep, every run leaves behind a
    /// `<UUID>_paper.pdf` 9-byte fake.
    ///
    /// Diffing the dir contents in `setUp` / `tearDown` removes any file
    /// that wasn't there when the test started — belt-and-suspenders for
    /// individual tests that forget to clean up their own copy.
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

    // MARK: - Push path

    func testBuildPushRecordRehydratesCachedSystemFields() throws {
        // recordName must carry the "<type>:" prefix — buildPushRecord
        // rehydrates only when the cached recordName matches the expected
        // prefixed form, otherwise it builds fresh (see the migration-path
        // comment on rehydrateOrNew).
        let cached = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(
                recordName: "tag:1",
                zoneID: SyncConstants.libraryZoneID
            )
        )
        let systemFields = SyncStateStore.archiveSystemFields(of: cached)

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 'Alpha', '#111')")

            let record = try SyncEntityType.tag.buildPushRecord(
                db: db,
                entityId: "1",
                systemFields: systemFields
            )
            XCTAssertNotNil(record)
            XCTAssertEqual(record?.recordID.recordName, "tag:1")
            XCTAssertEqual(record?["name"] as? String, "Alpha")
        }
    }

    func testBuildPushRecordDiscardsPrePrefixCachedSystemFields() throws {
        // Upgrade scenario: a library synced before the prefix fix has
        // cached systemFields with recordName="1" (no "tag:" prefix). On
        // the next push, we MUST treat this as a fresh record (new server
        // identity) — using the cached CKRecord would push under the old
        // colliding name and revive the bug for that row.
        let cached = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(
                recordName: "1",
                zoneID: SyncConstants.libraryZoneID
            )
        )
        let systemFields = SyncStateStore.archiveSystemFields(of: cached)

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 'Alpha', '#111')")

            let record = try SyncEntityType.tag.buildPushRecord(
                db: db,
                entityId: "1",
                systemFields: systemFields
            )
            XCTAssertEqual(
                record?.recordID.recordName,
                "tag:1",
                "legacy unprefixed systemFields must be discarded so the push lands under the new prefixed name"
            )
        }
    }

    func testBuildPushRecordReturnsNilForMissingRow() throws {
        try db.dbWriter.read { db in
            let record = try SyncEntityType.tag.buildPushRecord(
                db: db,
                entityId: "999",
                systemFields: nil
            )
            XCTAssertNil(
                record,
                "locally-deleted rows return nil so the push batch skips them; tombstone carries the delete"
            )
        }
    }

    // MARK: - Apply remote (upsert)

    func testApplyRemoteInsertsNewReference() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            let ref = Reference(title: "Synced from Cloud")
            let record = Reference.makeRecord(recordName: "reference:42", reference: ref)

            try SyncEntityType.reference.applyRemoteRecord(record, entityId: "42", db: db)

            try self.store.clearApplyingRemote(db)

            let fetched = try Reference.fetchOne(db, key: 42)
            XCTAssertEqual(fetched?.title, "Synced from Cloud")
            XCTAssertEqual(fetched?.id, 42)
        }
    }

    func testApplyRemoteUpdatesExistingReferenceWithoutRecreating() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            var initial = Reference(title: "initial")
            initial.id = 7
            try initial.insert(db)

            var updated = Reference(title: "updated")
            updated.id = 7
            let record = Reference.makeRecord(recordName: "reference:7", reference: updated)

            try SyncEntityType.reference.applyRemoteRecord(record, entityId: "7", db: db)

            try self.store.clearApplyingRemote(db)

            let fetched = try Reference.fetchOne(db, key: 7)
            XCTAssertEqual(fetched?.title, "updated")
            let totalCount = try Reference.fetchCount(db)
            XCTAssertEqual(
                totalCount,
                1,
                "UPDATE path must not allocate a second row; INSERT OR REPLACE would (and cascade-delete children)"
            )
        }
    }

    /// pdfPath is gone from Reference (B8). The new structural property:
    /// applying a remote Reference record must not touch the pdfCache row
    /// for that reference — pdfCache is a local-only table never observed
    /// by sync triggers and never present in the CKRecord schema.
    func testApplyRemoteReferenceDoesNotTouchPDFCache() throws {
        try db.dbWriter.write { db in
            // Local state: ref + an existing cache row.
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(11, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(11, 'abc-123_arxiv.pdf', 'h', 1, ?, ?)
            """, arguments: [Date(), Date()])

            try self.store.setApplyingRemote(db)

            var remote = Reference(title: "with-pdf-renamed")
            remote.id = 11
            let record = Reference.makeRecord(recordName: "reference:11", reference: remote)

            try SyncEntityType.reference.applyRemoteRecord(record, entityId: "11", db: db)

            try self.store.clearApplyingRemote(db)

            // Reference scalar updated:
            let fetched = try Reference.fetchOne(db, key: 11)
            XCTAssertEqual(fetched?.title, "with-pdf-renamed")
            // pdfCache row untouched (the structural invariant):
            let cacheFilename = try String.fetchOne(db, sql: "SELECT localFilename FROM pdfCache WHERE referenceId = 11")
            XCTAssertEqual(cacheFilename, "abc-123_arxiv.pdf",
                "Reference apply path must not touch pdfCache — pdfCache is local-only, has no CKRecord schema")
        }
    }

    func testApplyRemoteUpsertDoesNotCascadeDeleteChildren() throws {
        // The motivating reason we use INSERT + UPDATE instead of
        // INSERT OR REPLACE — replace would trigger the FK cascade and
        // nuke all child annotations on every ref round-trip.
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            var ref = Reference(title: "parent")
            ref.id = 10
            try ref.insert(db)

            var ann = PDFAnnotationRecord(
                referenceId: 10,
                type: .highlight,
                pageIndex: 0,
                rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
            )
            try ann.insert(db)

            var updated = Reference(title: "parent-renamed")
            updated.id = 10
            let record = Reference.makeRecord(recordName: "reference:10", reference: updated)
            try SyncEntityType.reference.applyRemoteRecord(record, entityId: "10", db: db)

            try self.store.clearApplyingRemote(db)

            let annotationCount = try PDFAnnotationRecord
                .filter(Column("referenceId") == 10)
                .fetchCount(db)
            XCTAssertEqual(annotationCount, 1, "child annotations must survive the parent upsert")
        }
    }

    func testApplyRemoteInsertsReferenceTagPivot() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            // Seed parents so FK is satisfiable
            var ref = Reference(id: 1, title: "r")
            var tag = Tag(id: 2, name: "t", color: "#000")
            try ref.insert(db)
            try tag.insert(db)

            let record = ReferenceTag.makeRecord(
                referenceTag: ReferenceTag(referenceId: 1, tagId: 2)
            )
            try SyncEntityType.referenceTag.applyRemoteRecord(record, entityId: "1/2", db: db)

            try self.store.clearApplyingRemote(db)

            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=1 AND tagId=2"
            ) ?? 0
            XCTAssertEqual(count, 1)
        }
    }

    // MARK: - Apply remote delete

    func testApplyRemoteDeleteRemovesRowAndCascades() throws {
        try db.dbWriter.write { db in
            var ref = Reference(id: 5, title: "parent")
            try ref.insert(db)
            var ann = PDFAnnotationRecord(
                referenceId: 5,
                type: .highlight,
                pageIndex: 0,
                rects: [.zero]
            )
            try ann.insert(db)

            try self.store.setApplyingRemote(db)
            try SyncEntityType.reference.applyRemoteDelete(entityId: "5", db: db)
            try self.store.clearApplyingRemote(db)

            XCTAssertNil(try Reference.fetchOne(db, key: 5))
            XCTAssertEqual(
                try PDFAnnotationRecord.filter(Column("referenceId") == 5).fetchCount(db),
                0,
                "FK cascade must carry delete into child tables"
            )
        }
    }

    func testApplyRemoteDeletePivotByCompositeKey() throws {
        try db.dbWriter.write { db in
            var ref = Reference(id: 1, title: "r")
            var tag = Tag(id: 2, name: "t", color: "#000")
            try ref.insert(db)
            try tag.insert(db)
            try ReferenceTag(referenceId: 1, tagId: 2).insert(db)

            try self.store.setApplyingRemote(db)
            try SyncEntityType.referenceTag.applyRemoteDelete(entityId: "1/2", db: db)
            try self.store.clearApplyingRemote(db)

            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM referenceTag"
            ) ?? -1
            XCTAssertEqual(count, 0)
        }
    }

    // MARK: - Apply remote (referencePDF, B8)

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
            // Mac eagerly materializes — file should be on disk under PDFs/.
            XCTAssertNotNil(row["materializedAt"] as String?, "Mac should materialize on pull")
        }
    }

    func testApplyRemoteReferencePDFUnlinksPreviousFileOnReDownload() throws {
        // Scenario: device pulls a CDReferencePDF asset, then later pulls a
        // newer assetVersion of the same referenceId. The first file must not
        // remain orphaned in PDFs/ after the second pull updates the row.
        try FileManager.default.createDirectory(at: AppDatabase.pdfStorageURL, withIntermediateDirectories: true)

        let firstSrc = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-v1".utf8).write(to: firstSrc)
        defer { try? FileManager.default.removeItem(at: firstSrc) }

        let secondSrc = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-v2-newer".utf8).write(to: secondSrc)
        defer { try? FileManager.default.removeItem(at: secondSrc) }

        let firstFilename: String = try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(33, 'r', ?, ?)", arguments: [Date(), Date()])
            try self.store.setApplyingRemote(db)

            let p1 = ReferencePDFRecord(
                referenceId: 33, assetURL: firstSrc, assetVersion: 1,
                contentHash: "v1hash", originalFilename: "paper.pdf",
                dateModified: Date()
            )
            try SyncEntityType.referencePDF.applyRemoteRecord(
                ReferencePDFRecord.makeRecord(recordName: "referencePDF:33", payload: p1),
                entityId: "33", db: db
            )
            return try String.fetchOne(db, sql: "SELECT localFilename FROM pdfCache WHERE referenceId=33")!
        }
        let firstURL = AppDatabase.pdfStorageURL.appendingPathComponent(firstFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path), "first pull should have written a file")

        let secondFilename: String = try db.dbWriter.write { db in
            let p2 = ReferencePDFRecord(
                referenceId: 33, assetURL: secondSrc, assetVersion: 2,
                contentHash: "v2hash", originalFilename: "paper.pdf",
                dateModified: Date()
            )
            try SyncEntityType.referencePDF.applyRemoteRecord(
                ReferencePDFRecord.makeRecord(recordName: "referencePDF:33", payload: p2),
                entityId: "33", db: db
            )
            try self.store.clearApplyingRemote(db)
            return try String.fetchOne(db, sql: "SELECT localFilename FROM pdfCache WHERE referenceId=33")!
        }
        XCTAssertNotEqual(firstFilename, secondFilename, "second pull writes under a fresh UUID-prefixed name")

        let secondURL = AppDatabase.pdfStorageURL.appendingPathComponent(secondFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path), "second pull's file must exist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path),
                       "first pull's file must be unlinked once the row points at the second one")

        // Cleanup so other tests don't see leftover files.
        try? FileManager.default.removeItem(at: secondURL)
    }

    /// Mirrors the SyncedLibrary.applyFetchedZoneChanges deletion loop:
    /// setApplyingRemote → applyRemoteDelete(.reference) → removeState
    /// → upsertTombstone(confirmedByServer:true) → clearDirty →
    /// clearApplyingRemote. Asserts that a remote-pull delete of a
    /// Reference cascades to its sibling CDReferencePDF state on this
    /// device:
    /// - parent reference tombstone is marked server-confirmed (so it
    ///   isn't re-pushed on the next cycle — Codex review finding);
    /// - on-disk PDF file is unlinked;
    /// - pdfCache row dropped via FK cascade;
    /// - any orphan syncState/tombstone for the sibling referencePDF
    ///   is cleared (no spurious push back to the cloud).
    func testApplyRemoteDeleteReferenceWrapperCleansUpOrphanReferencePDFState() throws {
        let pdfsDir = AppDatabase.pdfStorageURL
        try FileManager.default.createDirectory(at: pdfsDir, withIntermediateDirectories: true)
        let filename = "remote-delete-\(UUID().uuidString)_x.pdf"
        let fileURL = pdfsDir.appendingPathComponent(filename)
        try Data("%PDF-bytes-to-be-unlinked".utf8).write(to: fileURL)

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(55, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(55, ?, 'h', 1, ?)
            """, arguments: [filename, Date()])
            // Stale sibling syncState + tombstone left over from earlier
            // local activity. Wrapper must clear both so the dead row
            // doesn't re-push.
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                VALUES('referencePDF', '55', 1, 0)
            """)
            try db.execute(sql: """
                INSERT INTO tombstone(entityType, entityId, deletedAt, confirmedByServer)
                VALUES('referencePDF', '55', '2026-01-01T00:00:00.000Z', 0)
            """)

            try self.store.setApplyingRemote(db)
            try SyncEntityType.reference.applyRemoteDelete(entityId: "55", db: db)
            try self.store.removeState(db, entityType: .reference, entityId: "55")
            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "55",
                confirmedByServer: true
            )
            try self.store.clearDirty(db, entityType: .reference, entityId: "55")
            try self.store.clearApplyingRemote(db)

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference WHERE id=55") ?? -1, 0,
                "reference row removed"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=55") ?? -1, 0,
                "pdfCache row dropped via FK cascade"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='referencePDF' AND entityId='55'") ?? -1, 0,
                "orphan referencePDF syncState cleared"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='referencePDF' AND entityId='55'") ?? -1, 0,
                "orphan referencePDF tombstone cleared (remote already authoritatively deleted parent)"
            )
            // Parent reference tombstone must be confirmed so the next push
            // cycle doesn't re-send it as if local-originated.
            let confirmed = try Int.fetchOne(db,
                sql: "SELECT confirmedByServer FROM tombstone WHERE entityType='reference' AND entityId='55'") ?? -1
            XCTAssertEqual(confirmed, 1, "pull-side tombstone must be confirmedByServer=1")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "on-disk PDF must be unlinked even though FK cascade only drops the DB row"
        )
    }

    func testApplyRemoteReferencePDFDeleteRemovesCacheRowAndFile() throws {
        // Create a real file in PDFs/ so we can verify the apply-delete path
        // also nukes the on-disk file (not just the cache row).
        let pdfsDir = AppDatabase.pdfStorageURL
        try FileManager.default.createDirectory(at: pdfsDir, withIntermediateDirectories: true)
        let filename = "delete-test-\(UUID().uuidString)_x.pdf"
        let fileURL = pdfsDir.appendingPathComponent(filename)
        try Data("%PDF-to-be-deleted".utf8).write(to: fileURL)
        // No defer cleanup — the test itself verifies the file is gone.

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(11, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(11, ?, 'h', 1, ?)
            """, arguments: [filename, Date()])

            try self.store.setApplyingRemote(db)
            try SyncEntityType.referencePDF.applyRemoteDelete(entityId: "11", db: db)
            try self.store.clearApplyingRemote(db)

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=11") ?? -1,
                0,
                "cache row dropped"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "apply-delete must also remove the on-disk file, not just the cache row"
        )
    }

    func testBuildPushRecordReferencePDFEmitsRecordWithAssetWhenCachedOnDisk() throws {
        // Set up: a Reference + materialized pdfCache row whose file exists in PDFs/.
        let pdfsDir = AppDatabase.pdfStorageURL
        try FileManager.default.createDirectory(at: pdfsDir, withIntermediateDirectories: true)
        let filename = "test-\(UUID().uuidString)_paper.pdf"
        let fileURL = pdfsDir.appendingPathComponent(filename)
        try Data("%PDF-fake-content".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(20, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(20, ?, 'somehash', 3, ?, ?)
            """, arguments: [filename, Date(), Date()])

            let record = try SyncEntityType.referencePDF.buildPushRecord(
                db: db,
                entityId: "20",
                systemFields: nil
            )
            XCTAssertNotNil(record)
            XCTAssertEqual(record?.recordID.recordName, "referencePDF:20")
            XCTAssertEqual(record?[ReferencePDFRecord.RecordField.referenceId] as? Int64, 20)
            XCTAssertEqual(record?[ReferencePDFRecord.RecordField.assetVersion] as? Int64, 3)
            XCTAssertEqual(record?[ReferencePDFRecord.RecordField.contentHash] as? String, "somehash")
            XCTAssertNotNil(
                record?[ReferencePDFRecord.RecordField.asset] as? CKAsset,
                "asset must be present and decode as a CKAsset when file exists"
            )
        }
    }

    func testBuildPushRecordReferencePDFReturnsNilWhenNoCacheRow() throws {
        try db.dbWriter.read { db in
            let record = try SyncEntityType.referencePDF.buildPushRecord(
                db: db,
                entityId: "999",
                systemFields: nil
            )
            XCTAssertNil(
                record,
                "no pdfCache row → no push (delete propagation goes through tombstones, not push)"
            )
        }
    }

    func testBuildPushRecordReferencePDFRecomputesPendingHash() throws {
        // The v2 migration backfilled existing reference.pdfPath rows into
        // pdfCache with contentHash='pending' (skipped hashing to keep launch
        // fast). On first push, buildPushRecord must recompute the real
        // SHA-256 and persist it, so peers don't receive a placeholder they
        // can't verify against.
        let pdfsDir = AppDatabase.pdfStorageURL
        try FileManager.default.createDirectory(at: pdfsDir, withIntermediateDirectories: true)
        let filename = "pending-\(UUID().uuidString)_paper.pdf"
        let fileURL = pdfsDir.appendingPathComponent(filename)
        let bytes = Data("%PDF-content-with-known-hash-\(UUID().uuidString)".utf8)
        try bytes.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let expectedHash = try PDFContentHasher.sha256(of: fileURL)

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(40, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(40, ?, 'pending', 1, ?, ?)
            """, arguments: [filename, Date(), Date()])

            let record = try SyncEntityType.referencePDF.buildPushRecord(
                db: db,
                entityId: "40",
                systemFields: nil
            )
            XCTAssertNotNil(record)
            let pushedHash = record?[ReferencePDFRecord.RecordField.contentHash] as? String
            XCTAssertEqual(pushedHash, expectedHash, "pushed hash must be the recomputed SHA-256, not 'pending'")
            XCTAssertEqual(pushedHash?.count, 64, "SHA-256 hex digest is 64 chars")

            let storedHash = try String.fetchOne(db,
                sql: "SELECT contentHash FROM pdfCache WHERE referenceId=40")
            XCTAssertEqual(storedHash, expectedHash,
                           "recomputed hash must be persisted so subsequent pushes don't re-hash")
        }
    }

    func testBuildPushRecordReferencePDFReturnsNilWhenFileVanished() throws {
        // Cache row says materialized but file is gone (drift case).
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(21, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(21, 'definitely-not-there-\(UUID().uuidString).pdf', 'h', 1, ?, ?)
            """, arguments: [Date(), Date()])

            let record = try SyncEntityType.referencePDF.buildPushRecord(
                db: db,
                entityId: "21",
                systemFields: nil
            )
            XCTAssertNil(
                record,
                "cache row points at a missing file — better to skip the push than upload a stale/empty asset"
            )
        }
    }
}

private extension Reference {
    init(id: Int64, title: String) {
        self.init(title: title)
        self.id = id
    }
}
#endif
