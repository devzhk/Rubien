#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// PDF asset materialization is a two-step pipeline: `prepare` copies the
/// CKAsset bytes onto disk (no DB touch); `apply` runs the small `pdfCache`
/// upsert inside the caller's transaction (no file I/O). Tests verify both
/// halves in isolation plus the SyncedLibrary integration that drives them.
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

    // MARK: - Apply step

    func testPrepareUsesRecordNameAsCanonicalEntityIdNotPayloadReferenceId() throws {
        // Even if the wire payload's referenceId differs from the recordName-
        // derived entityId, prepare must extract entityId from recordName
        // (the engine's canonical identity) and apply writes via that key.
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
        XCTAssertEqual(prepared.entityId, 81, "prepare must use recordName-derived entityId, not payload.referenceId")

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(81, 'r', ?, ?)", arguments: [Date(), Date()])
            try self.store.setApplyingRemote(db)
            _ = try SyncEntityType.applyPreparedReferencePDF(prepared, db: db)
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
            _ = try SyncEntityType.applyPreparedReferencePDF(prep1, db: db)
            let prior = try SyncEntityType.applyPreparedReferencePDF(prep2, db: db)
            try self.store.clearApplyingRemote(db)
            return prior
        }
        XCTAssertEqual(priorFromSecondApply, prep1.stagedFilename,
                       "second apply must hand back the first apply's filename for post-commit unlink")

        // Apply itself does NOT unlink — that responsibility belongs to
        // SyncedLibrary, post-commit.
        XCTAssertTrue(FileManager.default.fileExists(atPath: prep1.stagedURL.path),
                      "apply must not unlink — that runs post-commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prep2.stagedURL.path))

        try? FileManager.default.removeItem(at: prep1.stagedURL)
        try? FileManager.default.removeItem(at: prep2.stagedURL)
    }

    func testPrepareReturnsNilForUnparseableRecordName() throws {
        // A non-Int64 entityId in the recordName must short-circuit prepare
        // so no file is ever staged on disk. Strictly stronger than the
        // pre-refactor contract, where apply could be reached with a bad
        // entityId and would silently no-op (leaving a staged orphan).
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let payload = ReferencePDFRecord(
            referenceId: 83, assetURL: src, assetVersion: 1,
            contentHash: "h", originalFilename: "z.pdf", dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:not-an-int", payload: payload)
        let prepared = try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        XCTAssertNil(prepared, "unparseable recordName → prepare returns nil, no staged file")
    }

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

        try await db.dbWriter.write { db in
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

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.applyFetchedRecordsForTest(modifications: [rA, rB], deletions: [])

        try await db.dbWriter.read { db in
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

        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(95, 'r', ?, ?)", arguments: [Date(), Date()])
        }

        let payload = ReferencePDFRecord(
            referenceId: 95, assetURL: src, assetVersion: 1,
            contentHash: "h", originalFilename: "busy.pdf", dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:95", payload: payload)

        let library = SyncedLibrary(
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
}
#endif
