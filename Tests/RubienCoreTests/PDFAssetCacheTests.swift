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
