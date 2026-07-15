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
        let row = try await db.dbWriter.read { db -> Row? in
            try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["assetVersion"] as Int64?, 1)
        XCTAssertNotNil(row?["materializedAt"] as String?)
    }

    func testPathForReturnsNilWhenNotMaterialized() async throws {
        try makeRef(id: 1)
        // Insert a cache row with materializedAt = NULL.
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
        let row = try await db.dbWriter.read { db -> Row? in
            try Row.fetchOne(db, sql: "SELECT * FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertNotNil(row, "row preserved so a future tap can re-fetch")
        XCTAssertNil(row?["materializedAt"] as String?)
    }

    func testConditionalDematerializeDoesNotRemoveNewerMaterialization() async throws {
        try makeRef(id: 1)
        let firstSource = try makeFakePDF(name: "first-source.pdf")
        let secondSource = try makeFakePDF(name: "second-source.pdf")
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)
        _ = try await cache.materialize(
            referenceId: 1,
            sourceURL: firstSource,
            originalFilename: "first.pdf",
            assetVersion: 1
        )
        let observedEntry = try await cache.metadataFor(referenceId: 1)
        let observed = try XCTUnwrap(observedEntry)
        let newer = try await cache.materialize(
            referenceId: 1,
            sourceURL: secondSource,
            originalFilename: "second.pdf",
            assetVersion: 2
        )

        let changed = try await cache.dematerializeIfUnchanged(observed)
        let currentPath = try await cache.pathFor(referenceId: 1)

        XCTAssertFalse(changed)
        XCTAssertEqual(currentPath, newer.localURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.localURL.path))
    }

    func testMetadataForReturnsRowEvenWhenNotMaterialized() async throws {
        try makeRef(id: 1)
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(1, 'x.pdf', 'abcdef', 7, NULL)
            """)
        }
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)

        let entry = try await cache.metadataFor(referenceId: 1)

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.referenceId, 1)
        XCTAssertEqual(entry?.localFilename, "x.pdf")
        XCTAssertEqual(entry?.contentHash, "abcdef")
        XCTAssertEqual(entry?.assetVersion, 7)
        XCTAssertNil(entry?.materializedAt, "metadataFor returns the row even with materializedAt NULL")
    }

    func testMetadataForReturnsNilWhenNoRow() async throws {
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)
        let entry = try await cache.metadataFor(referenceId: 999)
        XCTAssertNil(entry)
    }

    // MARK: - Manual attachment transaction

    func testAttachImportedPDFStampsMonotonicallyAndPreservesExistingAttachment() throws {
        try makeRef(id: 1)
        let initialStamp = try XCTUnwrap(try db.dbWriter.read { database in
            try Date.fetchOne(
                database,
                sql: "SELECT dateModified FROM reference WHERE id = 1"
            )
        })

        let attached = try db.attachImportedPDF(
            referenceId: 1,
            filename: "first.pdf"
        )

        XCTAssertTrue(attached)
        XCTAssertEqual(try db.pdfFilename(for: 1), "first.pdf")
        let attachedStamp = try XCTUnwrap(try db.dbWriter.read { database in
            try Date.fetchOne(
                database,
                sql: "SELECT dateModified FROM reference WHERE id = 1"
            )
        })
        XCTAssertGreaterThanOrEqual(attachedStamp, initialStamp)

        let replacementStamp = attachedStamp.addingTimeInterval(60)
        try db.dbWriter.write { database in
            try database.execute(
                sql: "UPDATE reference SET dateModified = ? WHERE id = 1",
                arguments: [replacementStamp]
            )
        }
        let replaced = try db.attachImportedPDF(
            referenceId: 1,
            filename: "replacement.pdf"
        )

        XCTAssertFalse(replaced, "manual attach must not overwrite a concurrently-added PDF")
        XCTAssertEqual(try db.pdfFilename(for: 1), "first.pdf")
        let unchangedStamp = try db.dbWriter.read { database in
            try Date.fetchOne(
                database,
                sql: "SELECT dateModified FROM reference WHERE id = 1"
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(unchangedStamp).timeIntervalSince1970,
            replacementStamp.timeIntervalSince1970,
            accuracy: 0.001
        )

        try makeRef(id: 2)
        let futureMCPStamp = Date().addingTimeInterval(3_600)
        try db.dbWriter.write { database in
            try database.execute(
                sql: "UPDATE reference SET dateModified = ? WHERE id = 2",
                arguments: [futureMCPStamp]
            )
        }

        XCTAssertTrue(try db.attachImportedPDF(referenceId: 2, filename: "second.pdf"))
        let monotonicStamp = try XCTUnwrap(try db.dbWriter.read { database in
            try Date.fetchOne(
                database,
                sql: "SELECT dateModified FROM reference WHERE id = 2"
            )
        })
        XCTAssertEqual(
            monotonicStamp.timeIntervalSince1970,
            futureMCPStamp.timeIntervalSince1970,
            accuracy: 0.001,
            "attachment must not move a newer concurrent metadata timestamp backward"
        )
    }

    func testAttachImportedPDFMaterializesMetadataOnlyPlaceholder() throws {
        try makeRef(id: 1)
        try db.dbWriter.write { database in
            try database.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(1, 'remote-placeholder.pdf', 'remote-hash', 7, NULL, ?)
            """, arguments: [Date()])
        }

        XCTAssertTrue(try db.attachImportedPDF(referenceId: 1, filename: "local.pdf"))

        let status = try XCTUnwrap(try db.pdfCacheStatus(for: 1))
        XCTAssertEqual(status.localFilename, "local.pdf")
        XCTAssertEqual(status.contentHash, "pending")
        XCTAssertEqual(status.assetVersion, 8)
        XCTAssertNotNil(status.materializedAt)
        XCTAssertTrue(status.inUploadQueue)
    }

    func testReplaceImportedPDFSwapsCurrentRowAndIncrementsAssetVersion() throws {
        try makeRef(id: 1)
        let futureMCPStamp = Date().addingTimeInterval(3_600)
        try db.dbWriter.write { database in
            try database.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(1, 'concurrent.pdf', 'concurrent-hash', 11, ?, ?)
            """, arguments: [Date(), Date()])
            try database.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                VALUES(1, 'concurrent.pdf', ?)
            """, arguments: [Date()])
            try database.execute(
                sql: "UPDATE reference SET dateModified = ? WHERE id = 1",
                arguments: [futureMCPStamp]
            )
        }

        let previousFilename = try db.replaceImportedPDF(
            referenceId: 1,
            filename: "replacement.pdf"
        )

        XCTAssertEqual(previousFilename, "concurrent.pdf")
        let status = try XCTUnwrap(try db.pdfCacheStatus(for: 1))
        XCTAssertEqual(status.localFilename, "replacement.pdf")
        XCTAssertEqual(status.contentHash, "pending")
        XCTAssertEqual(status.assetVersion, 12)
        XCTAssertNotNil(status.materializedAt)
        XCTAssertTrue(status.inUploadQueue)
        let queuedFilename = try db.dbWriter.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT localFilename FROM pdfUploadQueue WHERE referenceId = 1"
            )
        }
        XCTAssertEqual(queuedFilename, "replacement.pdf")
        let modifiedAt = try XCTUnwrap(try db.dbWriter.read { database in
            try Date.fetchOne(
                database,
                sql: "SELECT dateModified FROM reference WHERE id = 1"
            )
        })
        XCTAssertEqual(
            modifiedAt.timeIntervalSince1970,
            futureMCPStamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testReplaceImportedPDFFailureRollsBackExistingRows() throws {
        try makeRef(id: 1)
        try db.dbWriter.write { database in
            try database.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(1, 'original.pdf', 'original-hash', 7, ?, ?)
            """, arguments: [Date(), Date()])
            try database.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                VALUES(1, 'original.pdf', ?)
            """, arguments: [Date()])
            try database.execute(sql: """
                CREATE TEMP TRIGGER reject_pdf_replacement_stamp
                BEFORE UPDATE OF dateModified ON reference
                BEGIN
                    SELECT RAISE(ABORT, 'forced replacement failure');
                END
            """)
        }

        XCTAssertThrowsError(
            try db.replaceImportedPDF(referenceId: 1, filename: "replacement.pdf")
        )

        let status = try XCTUnwrap(try db.pdfCacheStatus(for: 1))
        XCTAssertEqual(status.localFilename, "original.pdf")
        XCTAssertEqual(status.contentHash, "original-hash")
        XCTAssertEqual(status.assetVersion, 7)
        XCTAssertNotNil(status.materializedAt)
        XCTAssertTrue(status.inUploadQueue)
        let queuedFilename = try db.dbWriter.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT localFilename FROM pdfUploadQueue WHERE referenceId = 1"
            )
        }
        XCTAssertEqual(queuedFilename, "original.pdf")
    }

    // MARK: - AppDatabase.pdfFilename(for:) sync helper (Task 6)

    func testAppDatabasePdfFilenameReturnsNilWhenNoRow() throws {
        let filename = try db.pdfFilename(for: 999)
        XCTAssertNil(filename)
    }

    func testAppDatabasePdfFilenameReturnsNilWhenNotMaterialized() throws {
        try makeRef(id: 1)
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(1, 'x.pdf', 'h', 1, NULL)
            """)
        }
        let filename = try db.pdfFilename(for: 1)
        XCTAssertNil(filename, "row exists but materializedAt is NULL — caller should treat as 'needs download'")
    }

    func testAppDatabasePdfFilenameReturnsFilenameWhenMaterialized() throws {
        try makeRef(id: 1)
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(1, 'abc-123.pdf', 'h', 1, ?)
            """, arguments: [Date()])
        }
        let filename = try db.pdfFilename(for: 1)
        XCTAssertEqual(filename, "abc-123.pdf")
    }

    func testPdfFilenamesForReferencesBulkLookup() throws {
        try makeRef(id: 1)
        try makeRef(id: 2)
        try makeRef(id: 3)
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES
                  (1, 'one.pdf',   'h1', 1, ?),
                  (2, 'two.pdf',   'h2', 1, NULL),
                  (3, 'three.pdf', 'h3', 1, ?)
            """, arguments: [Date(), Date()])
        }

        let map = try db.pdfFilenames(forReferences: [1, 2, 3, 999])
        XCTAssertEqual(map[1], "one.pdf")
        XCTAssertNil(map[2], "ref 2 has cache row but not materialized — excluded from result")
        XCTAssertEqual(map[3], "three.pdf")
        XCTAssertNil(map[999], "ref 999 has no cache row")
    }

    func testPdfFilenamesForReferencesEmptyInput() throws {
        let map = try db.pdfFilenames(forReferences: [])
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - totalCacheSize (Task 26)

    func testTotalCacheSizeSumsMaterializedFiles() async throws {
        try makeRef(id: 1)
        try makeRef(id: 2)
        try makeRef(id: 3)
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)

        // Two materialized files, one cache row with materializedAt=NULL (not on disk).
        let f1 = try makeFakePDF(name: "src1.pdf", contents: String(repeating: "x", count: 1000))
        let f2 = try makeFakePDF(name: "src2.pdf", contents: String(repeating: "y", count: 500))
        _ = try await cache.materialize(referenceId: 1, sourceURL: f1, originalFilename: "p1.pdf", assetVersion: 1)
        _ = try await cache.materialize(referenceId: 2, sourceURL: f2, originalFilename: "p2.pdf", assetVersion: 1)
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt)
                VALUES(3, 'phantom.pdf', 'h', 1, NULL)
            """)
        }

        let total = try await cache.totalCacheSize()
        XCTAssertEqual(total, 1500, "sum of materialized file sizes only; phantom (materializedAt=NULL) excluded")
    }

    func testTotalCacheSizeIsZeroForEmptyCache() async throws {
        let cache = PDFAssetCache(db: db, storageRoot: tmpRoot)
        let total = try await cache.totalCacheSize()
        XCTAssertEqual(total, 0)
    }
}
