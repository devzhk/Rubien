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

    private func referenceDeletion(
        id: Int64
    ) -> SyncedLibrary.FetchedDeletionInput {
        SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(
                    entityId: String(id)
                ),
                zoneID: SyncConstants.libraryZoneID
            ),
            recordType: SyncConstants.RecordType.reference
        )
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

    func testFullReplayReusesUnchangedLivePDF() throws {
        var reference = Reference(syncId: "pdf-parent", title: "Paper")
        try db.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let liveFilename = "\(UUID().uuidString)-live.pdf"
        let liveURL = AppDatabase.pdfStorageURL.appendingPathComponent(liveFilename)
        try Data("%PDF-live".utf8).write(to: liveURL)

        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash,
                    assetVersion, materializedAt, lastOpenedAt
                ) VALUES (?, ?, 'same-hash', 4, ?, ?)
                """, arguments: [referenceId, liveFilename, Date(), Date()])
        }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-redelivered".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = ReferencePDFRecord(
            referenceId: referenceId,
            referenceSyncId: reference.syncId,
            assetURL: source,
            assetVersion: 4,
            contentHash: "same-hash",
            originalFilename: "incoming.pdf",
            dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(
            recordName: "referencePDF:\(reference.syncId)",
            payload: payload
        )
        var prepared = try XCTUnwrap(
            try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        )

        let outcome = try db.dbWriter.write { db in
            let hint = try XCTUnwrap(
                SyncEntityType.referencePDFReuseHint(for: prepared, db: db)
            )
            prepared = prepared.withReuseHint(hint)
            return try SyncEntityType
                .applyPreparedReferencePDFPreservingUnchanged(prepared, db: db)
        }

        XCTAssertTrue(outcome.reusedExistingFile)
        XCTAssertNil(outcome.displacedFilename)
        XCTAssertEqual(try db.dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }, liveFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagedURL.path))
        try? FileManager.default.removeItem(at: prepared.stagedURL)
    }

    func testFullReplayHintRaceFallsBackToStagedAsset() throws {
        var reference = Reference(syncId: "pdf-race-parent", title: "Paper")
        try db.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let priorFilename = "\(UUID().uuidString)-prior.pdf"
        let priorURL = AppDatabase.pdfStorageURL.appendingPathComponent(priorFilename)
        try Data("%PDF-prior".utf8).write(to: priorURL)
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash,
                    assetVersion, materializedAt, lastOpenedAt
                ) VALUES (?, ?, 'same-hash', 4, ?, ?)
                """, arguments: [referenceId, priorFilename, Date(), Date()])
        }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-incoming".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let record = ReferencePDFRecord.makeRecord(
            recordName: "referencePDF:\(reference.syncId)",
            payload: .init(
                referenceId: referenceId,
                referenceSyncId: reference.syncId,
                assetURL: source,
                assetVersion: 4,
                contentHash: "same-hash",
                originalFilename: "incoming.pdf",
                dateModified: Date()
            )
        )
        var prepared = try XCTUnwrap(
            try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        )
        let outcome = try db.dbWriter.write { db in
            prepared = prepared.withReuseHint(try XCTUnwrap(
                SyncEntityType.referencePDFReuseHint(for: prepared, db: db)
            ))
            try db.execute(
                sql: "UPDATE pdfCache SET assetVersion = 5 WHERE referenceId = ?",
                arguments: [referenceId]
            )
            return try SyncEntityType
                .applyPreparedReferencePDFPreservingUnchanged(prepared, db: db)
        }

        XCTAssertFalse(outcome.reusedExistingFile)
        XCTAssertEqual(outcome.displacedFilename, priorFilename)
        XCTAssertEqual(try db.dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }, prepared.stagedFilename)
    }

    func testPrepareUsesRecordNameAsCanonicalEntityIdNotPayloadReferenceId() throws {
        // Even if the wire payload's referenceId differs from the recordName-
        // derived entityId, prepare must extract entityId from recordName
        // (the engine's canonical identity) and apply writes via that key.
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-mismatch".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let payload = ReferencePDFRecord(
            referenceId: 999,  // deliberately wrong
            referenceSyncId: "81",
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
        XCTAssertEqual(
            prepared.referenceSyncId,
            "81",
            "prepare must use the recordName-derived sync ID, not the payload's local row ID"
        )

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, syncId, title, dateAdded, dateModified) VALUES(81, '81', 'r', ?, ?)", arguments: [Date(), Date()])
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
            try db.execute(sql: "INSERT INTO reference(id, syncId, title, dateAdded, dateModified) VALUES(82, '82', 'r', ?, ?)", arguments: [Date(), Date()])
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
        // A record-name/payload identity mismatch must short-circuit prepare
        // so no file is ever staged on disk.
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let payload = ReferencePDFRecord(
            referenceId: 83, assetURL: src, assetVersion: 1,
            contentHash: "h", originalFilename: "z.pdf", dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(recordName: "referencePDF:not-an-int", payload: payload)
        let prepared = try SyncEntityType.prepareReferencePDFMaterialization(record: record)
        XCTAssertNil(prepared, "identity mismatch → prepare returns nil, no staged file")
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
            try db.execute(sql: "INSERT INTO reference(id, syncId, title, dateAdded, dateModified) VALUES(91, '91', 'a', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO reference(id, syncId, title, dateAdded, dateModified) VALUES(92, '92', 'b', ?, ?)", arguments: [Date(), Date()])
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

    func testNewerQuarantinedPDFReplacesAndUnlinksPriorStagedAsset() async throws {
        let firstSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-first.pdf")
        let secondSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-second.pdf")
        try Data("%PDF-first".utf8).write(to: firstSource)
        try Data("%PDF-second".utf8).write(to: secondSource)
        defer {
            try? FileManager.default.removeItem(at: firstSource)
            try? FileManager.default.removeItem(at: secondSource)
        }

        let parentSyncId = "missing-pdf-parent"
        func record(source: URL, version: Int64, hash: String) -> CKRecord {
            ReferencePDFRecord.makeRecord(
                recordName: "referencePDF:\(parentSyncId)",
                payload: .init(
                    referenceId: 0,
                    referenceSyncId: parentSyncId,
                    assetURL: source,
                    assetVersion: version,
                    contentHash: hash,
                    originalFilename: "paper.pdf",
                    dateModified: Date()
                )
            )
        }

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        let firstApplied = await library.applyFetchedRecordsForTest(
            modifications: [record(source: firstSource, version: 1, hash: "first")],
            deletions: []
        )
        XCTAssertTrue(firstApplied)
        let firstStaged = try await db.dbWriter.read {
            try XCTUnwrap(String.fetchOne(
                $0,
                sql: "SELECT stagedFilename FROM syncOrphan WHERE recordName = ?",
                arguments: ["referencePDF:\(parentSyncId)"]
            ))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppDatabase.pdfStorageURL
                .appendingPathComponent(firstStaged).path
        ))

        let secondApplied = await library.applyFetchedRecordsForTest(
            modifications: [record(source: secondSource, version: 2, hash: "second")],
            deletions: []
        )
        XCTAssertTrue(secondApplied)
        let secondStaged = try await db.dbWriter.read {
            try XCTUnwrap(String.fetchOne(
                $0,
                sql: "SELECT stagedFilename FROM syncOrphan WHERE recordName = ?",
                arguments: ["referencePDF:\(parentSyncId)"]
            ))
        }
        XCTAssertNotEqual(firstStaged, secondStaged)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppDatabase.pdfStorageURL
                .appendingPathComponent(firstStaged).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppDatabase.pdfStorageURL
                .appendingPathComponent(secondStaged).path
        ))
    }

    func testTransientAssetCopyFailureMakesFetchedBatchNonDurable() async throws {
        let missingSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingSource.path))

        try await db.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reference(id, syncId, title, dateAdded, dateModified)
                    VALUES(93, '93', 'r', ?, ?)
                    """,
                arguments: [Date(), Date()]
            )
        }

        let payload = ReferencePDFRecord(
            referenceId: 93,
            assetURL: missingSource,
            assetVersion: 1,
            contentHash: "missing",
            originalFilename: "missing.pdf",
            dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(
            recordName: "referencePDF:93",
            payload: payload
        )
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )

        XCTAssertFalse(
            applied,
            "transient staging failure must block cursor persistence and retry"
        )
        let cacheCount = try await db.dbWriter.read {
            try Int.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId = 93"
            ) ?? -1
        }
        XCTAssertEqual(cacheCount, 0)
    }

    func testPermanentlyMissingAssetIsSkippedWithoutReplayLoop() async throws {
        try await db.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reference(id, syncId, title, dateAdded, dateModified)
                    VALUES(94, '94', 'r', ?, ?)
                    """,
                arguments: [Date(), Date()]
            )
        }

        let payload = ReferencePDFRecord(
            referenceId: 94,
            assetURL: nil,
            assetVersion: 1,
            contentHash: "missing",
            originalFilename: "missing.pdf",
            dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(
            recordName: "referencePDF:94",
            payload: payload
        )
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )

        XCTAssertTrue(
            applied,
            "a permanently malformed asset-less record must not replay forever"
        )
    }

    func testCommittedReferenceDeletionUnlinksPDFPostCommit() async throws {
        let filename = "\(UUID().uuidString)-committed-delete.pdf"
        let fileURL = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        try Data("%PDF-committed".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await db.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reference(id, syncId, title, dateAdded, dateModified)
                    VALUES(96, '96', 'r', ?, ?)
                    """,
                arguments: [Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO pdfCache(
                        referenceId, localFilename, contentHash,
                        assetVersion, materializedAt
                    ) VALUES(96, ?, 'h', 1, ?)
                    """,
                arguments: [filename, Date()]
            )
        }

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        let applied = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [referenceDeletion(id: 96)]
        )

        XCTAssertTrue(applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let counts = try await db.dbWriter.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM reference WHERE id = 96"
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId = 96"
                ) ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testRolledBackReferenceDeletionKeepsPDFAndDatabaseRows() async throws {
        let filename = "\(UUID().uuidString)-rolled-back-delete.pdf"
        let fileURL = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        try Data("%PDF-rollback".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await db.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reference(id, syncId, title, dateAdded, dateModified)
                    VALUES(97, '97', 'r', ?, ?)
                    """,
                arguments: [Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO pdfCache(
                        referenceId, localFilename, contentHash,
                        assetVersion, materializedAt
                    ) VALUES(97, ?, 'h', 1, ?)
                    """,
                arguments: [filename, Date()]
            )
            try db.execute(sql: """
                CREATE TRIGGER test_abort_reference_tombstone
                BEFORE INSERT ON tombstone
                WHEN NEW.entityType = 'reference' AND NEW.entityId = '97'
                BEGIN
                    SELECT RAISE(ABORT, 'forced deletion rollback');
                END
                """)
        }

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        let applied = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [referenceDeletion(id: 97)]
        )

        XCTAssertFalse(applied)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "a rolled-back transaction must not delete the still-referenced PDF"
        )
        let counts = try await db.dbWriter.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM reference WHERE id = 97"
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId = 97"
                ) ?? -1
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
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
            try db.execute(sql: "INSERT INTO reference(id, syncId, title, dateAdded, dateModified) VALUES(95, '95', 'r', ?, ?)", arguments: [Date(), Date()])
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
        _ = await applyTask.value
    }

    func testLatePDFAfterParentAliasMaterializesUnderWinner() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-aliased.pdf")
        try Data("%PDF-aliased-parent".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var reference = Reference(syncId: "reference-winner", title: "Winner")
        try db.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let referenceSyncId = reference.syncId
        let losingIdentity = "reference-loser"
        try await db.dbWriter.write { db in
            try SyncIdentityAliasStore.record(
                entityType: .reference,
                losingId: losingIdentity,
                winningId: referenceSyncId,
                db: db
            )
        }
        let payload = ReferencePDFRecord(
            referenceId: 0,
            referenceSyncId: losingIdentity,
            assetURL: source,
            assetVersion: 4,
            contentHash: "aliased-hash",
            originalFilename: "aliased.pdf",
            dateModified: Date()
        )
        let record = ReferencePDFRecord.makeRecord(
            recordName: "referencePDF:\(losingIdentity)",
            payload: payload
        )
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(applied)

        let storedFilename = try await db.dbWriter.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT pc.localFilename, pc.contentHash, r.syncId
                FROM pdfCache pc
                JOIN reference r ON r.id = pc.referenceId
                WHERE pc.referenceId = ?
                """, arguments: [referenceId]))
            XCTAssertEqual(row["syncId"] as String?, referenceSyncId)
            XCTAssertEqual(row["contentHash"] as String?, "aliased-hash")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState
                WHERE entityType = 'referencePDF' AND entityId = ?
                """, arguments: [referenceSyncId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isPushEligible FROM tombstone
                WHERE entityType = 'referencePDF' AND entityId = ?
                """, arguments: [losingIdentity]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE entityType = 'referencePDF' AND entityId = ?
                """, arguments: [losingIdentity]), 0)
            return row["localFilename"] as String
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppDatabase.pdfStorageURL
                .appendingPathComponent(storedFilename).path
        ))
    }
}
#endif
