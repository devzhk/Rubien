import Foundation
import GRDB
import XCTest
@testable import RubienCore

final class MigrationV17Tests: XCTestCase {
    func testUpgradePreservesLocalAttachmentAndExistingSyncState() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV14DatabaseForTesting(on: queue)
        try queue.write { db in
            try AppDatabase.applyV15AttachmentSchema(db)
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v15')")
            var parent = Reference(title: "Existing paper")
            try parent.insert(db)
            parent.id = db.lastInsertedRowID
            try ReferenceAttachment(syncId: SyncIdentifier.random(), referenceId: parent.id,
                referenceSyncId: parent.syncId, kind: "markdown", originalFilename: "notes.md", displayName: "Keep me",
                byteCount: 5, contentHash: String(repeating: "a", count: 64), dateCreated: Date(), dateModified: Date(), deletedAt: nil).insert(db)
        }
        // V16 is a column-only migration. Existing rows must survive the new
        // sync sidecars and trigger installation without being marked clean.
        let before = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }
        _ = try AppDatabase(queue)
        XCTAssertEqual(try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }, before)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT displayName FROM referenceAttachment") }, "Keep me")
        for table in ["attachmentSyncScope", "attachmentServerState", "attachmentReferenceDeletion", "attachmentQuarantineScope", "attachmentDownload", "attachmentRecovery", "attachmentCleanup", "attachmentTransferError"] {
            XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }, 0)
        }
        _ = try AppDatabase(queue)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1") }, AppDatabase.currentSchemaVersion)
    }

    func testTransferStatusAndRetryUseOnlyActiveScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentTransfer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(DatabaseQueue())
        var parent = Reference(title: "Primary")
        try database.saveReference(&parent)
        let files = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in })
        let source = root.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: source)
        let item = try files.importFile(at: source, referenceId: parent.id!).attachment
        XCTAssertEqual(try files.status(syncId: item.syncId).syncStatus, "notEnabled")
        try database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO syncSession(key,value) VALUES('attachmentSyncScope','a'),('attachmentSyncEnabled','1')")
            for scope in ["a", "b"] {
                try db.execute(sql: "INSERT INTO attachmentSyncScope(scopeID,accountID,environment,zoneName,zoneOwner,featureVersion,inventoryComplete) VALUES(?,?,'Development','Library','owner',1,1)", arguments: [scope,scope])
                try db.execute(sql: "INSERT INTO attachmentDownload(scopeID,attachmentSyncId,contentHash,byteCount,attempts,error) VALUES(?,?,?,?,3,'Offline')", arguments: [scope,item.syncId,item.contentHash,item.byteCount])
            }
        }
        XCTAssertEqual(try files.status(syncId: item.syncId).syncStatus, "error")
        try files.retrySync(syncId: item.syncId)
        XCTAssertEqual(try files.status(syncId: item.syncId).syncStatus, "pendingDownload")
        XCTAssertEqual(try database.dbWriter.read { try String.fetchOne($0, sql: "SELECT error FROM attachmentDownload WHERE scopeID='b'") }, "Offline")
        // Holding a reader lease must not stall or reject another import.
        let lease = try files.acquireFileLease()
        XCTAssertTrue(try files.importFile(at: source, referenceId: parent.id!).wasDuplicate)
        withExtendedLifetime(lease) {}
    }
}
