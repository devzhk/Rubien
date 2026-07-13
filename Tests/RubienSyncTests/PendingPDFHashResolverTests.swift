#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

/// Pending pdfCache.contentHash values are resolved *outside* any
/// transaction, and the drainer resolves before marking syncState dirty so
/// the engine never sees a 'pending' row at push time.
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

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.resolvePendingPDFContentHashes()

        try await db.dbWriter.read { db in
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
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.resolvePendingPDFContentHashes()
        let firstHash = try await db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
        }
        await library.resolvePendingPDFContentHashes()
        let secondHash = try await db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertEqual(firstHash, secondHash, "second pass is a no-op — no pending rows remain")
    }

    func testResolverTolerantOfMissingLocalFile() async throws {
        let filename = try seedPDFCacheRow(referenceId: 1, contentHash: "pending", contents: "%PDF-1")
        try FileManager.default.removeItem(at: AppDatabase.pdfStorageURL.appendingPathComponent(filename))

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.resolvePendingPDFContentHashes()

        // Missing file → row stays 'pending'. Safe because
        // buildPushRecord(.referencePDF) returns nil for missing-file rows
        // via an earlier fileExists guard, so no inline-hash branch is hit.
        let h = try await db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM pdfCache WHERE referenceId=1")
        }
        XCTAssertEqual(h, "pending")
    }

    func testResolverDoesNotApplyOldHashAfterAttachmentReplacement() async throws {
        let originalFilename = try seedPDFCacheRow(
            referenceId: 1,
            contentHash: "pending",
            contents: "%PDF-original"
        )
        let replacementFilename = "\(UUID().uuidString)_replacement.pdf"
        let replacementURL = AppDatabase.pdfStorageURL.appendingPathComponent(replacementFilename)
        try Data("%PDF-replacement".utf8).write(to: replacementURL)
        let database = try XCTUnwrap(db)

        let library = SyncedLibrary(
            appDatabase: database,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfContentHasher: { url in
                XCTAssertEqual(url.lastPathComponent, originalFilename)
                let replacedFilename = try database.replaceImportedPDF(
                    referenceId: 1,
                    filename: replacementFilename
                )
                XCTAssertEqual(replacedFilename, originalFilename)
                return "hash-of-original"
            },
            pdfAssetSyncEnabledProvider: { true }
        )

        await library.resolvePendingHashForReference(1)

        let status = try XCTUnwrap(try database.pdfCacheStatus(for: 1))
        XCTAssertEqual(status.localFilename, replacementFilename)
        XCTAssertEqual(status.assetVersion, 2)
        XCTAssertEqual(
            status.contentHash,
            "pending",
            "a hash computed from the prior file must not be written onto its replacement"
        )
    }

    func testDrainerResolvesPendingHashBeforeMarkingDirty() async throws {
        let filename = try seedPDFCacheRow(referenceId: 1, contentHash: "pending", contents: "%PDF-drainer")

        // Production import path: `AppDatabase.attachImportedPDFs` enqueues
        // here after `PDFService.importPDF`. We bypass it to isolate the
        // drainer's resolve-then-mark-dirty ordering.
        let queue = PDFUploadQueue(db: db)
        try await queue.enqueue(referenceId: 1, localFilename: filename)

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).engine-state"),
            pdfAssetSyncEnabledProvider: { true }
        )
        let drained = await library.drainPDFUploadQueueIntoSyncState()
        XCTAssertEqual(drained, [1])

        try await db.dbWriter.read { db in
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
}
#endif
