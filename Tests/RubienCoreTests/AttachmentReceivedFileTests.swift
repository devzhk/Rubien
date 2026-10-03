import Foundation
import GRDB
import XCTest
@testable import RubienCore

/// Exercises the receive filesystem protocol on both macOS and Linux without CloudKit.
final class AttachmentReceivedFileTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var store: ReferenceAttachmentStore!
    private var source: URL!
    private var item: ReferenceAttachment!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReceivedAttachment-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path))
        store = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in })
        var parent = Reference(title: "Parent")
        try database.saveReference(&parent)
        source = root.appendingPathComponent("source.md")
        try Data("abc".utf8).write(to: source)
        let digest = try ReferenceAttachmentStore.hash(source, limit: 3)
        item = ReferenceAttachment(syncId: SyncIdentifier.random(), referenceId: parent.id,
            referenceSyncId: parent.syncId, kind: "markdown", originalFilename: "source.md", displayName: "Notes",
            byteCount: digest.count, contentHash: digest.hash, dateCreated: Date(), dateModified: Date(), deletedAt: nil)
        try database.dbWriter.write { try item.insert($0) }
    }

    override func tearDownWithError() throws {
        store = nil; database = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testReceiveRollbackAndReopenKeepPublishedBytesRecoverable() throws {
        enum Failure: Error { case interrupted }
        var operation: String?
        XCTAssertThrowsError(try store.withReceivedFile(at: source, attachmentSyncId: item.syncId,
            contentHash: item.contentHash, byteCount: item.byteCount) { db, file in
                operation = file.operationID
                try store.publishReceivedFile(file, for: item, db: db)
                throw Failure.interrupted
            })
        store = nil; database = nil
        database = try AppDatabase(DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path))
        store = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in })
        try store.recoverInterruptedImports()
        try FileManager.default.removeItem(at: source)
        try store.withReceivedFile(at: source, attachmentSyncId: item.syncId,
            contentHash: item.contentHash, byteCount: item.byteCount, resuming: XCTUnwrap(operation)) { db, file in
                try store.publishReceivedFile(file, for: item, db: db)
            }
        XCTAssertEqual(try Data(contentsOf: store.verifiedFileURL(syncId: item.syncId)), Data("abc".utf8))
    }

    func testRetryRepairsUnownedPartialCopy() throws {
        let operation = UUID().uuidString.lowercased()
        let stagedPath = "Attachments/.staging/\(operation)/received.asset"
        let finalPath = "Attachments/\(item.syncId)/received-\(operation).asset"
        let staged = root.appendingPathComponent(stagedPath)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: staged)
        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO attachmentFileJournal(operationId, attachmentSyncId, stagedPath, finalPath, purpose, createdAt)
                VALUES(?, ?, ?, ?, 'receive', ?)
                """, arguments: [operation, item.syncId, stagedPath, finalPath, Date()])
        }
        try store.withReceivedFile(at: source, attachmentSyncId: item.syncId,
            contentHash: item.contentHash, byteCount: item.byteCount, resuming: operation) { db, file in
                try store.publishReceivedFile(file, for: item, db: db)
            }
        XCTAssertEqual(try Data(contentsOf: store.verifiedFileURL(syncId: item.syncId)), Data("abc".utf8))
    }

    func testRemovalDuringCopyPreventsPublication() throws {
        try store.withReceivedFile(at: source, attachmentSyncId: item.syncId,
            contentHash: item.contentHash, byteCount: item.byteCount) { db, file in
                try db.execute(sql: "UPDATE referenceAttachment SET deletedAt=? WHERE syncId=?", arguments: [Date(), item.syncId])
                XCTAssertThrowsError(try store.publishReceivedFile(file, for: item, db: db))
            }
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentCache") }, 0)
    }

    func testReceiptCannotPublishIntoAnotherLibrary() throws {
        let otherRoot = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherStore = ReferenceAttachmentStore(database: database, libraryRoot: otherRoot, validatePDF: { _ in })
        try store.withReceivedFile(at: source, attachmentSyncId: item.syncId,
            contentHash: item.contentHash, byteCount: item.byteCount) { db, file in
                XCTAssertThrowsError(try otherStore.publishReceivedFile(file, for: item, db: db))
            }
    }
}
