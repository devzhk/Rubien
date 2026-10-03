import Foundation
import GRDB
import XCTest
@testable import RubienCore

final class MigrationV18Tests: XCTestCase {
    func testUpgradePreservesIntentAndBackfillsDeletionReceiptAndWork() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV14DatabaseForTesting(on: queue)
        let attachmentID = SyncIdentifier.random()
        try queue.write { db in
            try AppDatabase.applyV15AttachmentSchema(db)
            try db.execute(sql: """
                ALTER TABLE assistantConversation ADD COLUMN attachmentSyncId TEXT;
                CREATE INDEX assistantConversation_attachment_history ON assistantConversation(attachmentSyncId,lastActivityAt);
                INSERT INTO grdb_migrations(identifier) VALUES ('v15'),('v16');
                """)
            try AppDatabase.applyV17AttachmentSyncSchema(db)
            try db.execute(sql: """
                INSERT INTO grdb_migrations(identifier) VALUES ('v17');
                INSERT INTO syncSession(key,value) VALUES('attachmentSyncScope','scope');
                INSERT INTO attachmentSyncScope(scopeID,accountID,environment,zoneName,zoneOwner,featureVersion)
                VALUES('scope','account','Production','Library','owner',1);
                """)
            var parent = Reference(title: "Existing reference")
            try parent.insert(db)
            try ReferenceAttachment(syncId: attachmentID, referenceId: db.lastInsertedRowID,
                referenceSyncId: parent.syncId, kind: "markdown", originalFilename: "notes.md", displayName: "Keep metadata",
                byteCount: 5, contentHash: String(repeating: "a", count: 64), dateCreated: Date(), dateModified: Date(), deletedAt: Date()).insert(db)
            try db.execute(sql: "INSERT INTO tombstone(entityType,entityId,deletedAt,confirmedByServer,isPushEligible) VALUES('attachmentAsset',?,?,1,1)", arguments: [attachmentID,Date()])
        }
        let before = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }
        _ = try AppDatabase(queue)
        XCTAssertEqual(try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }, before)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT displayName FROM referenceAttachment") }, "Keep metadata")
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentServerState WHERE scopeID='scope' AND entityType='attachmentAsset' AND physicalDeletedAt IS NOT NULL") }, 1)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT attachmentSyncId FROM attachmentRemovalWork WHERE scopeID='scope'") }, attachmentID)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT confirmedByServer FROM tombstone") }, 1)
        _ = try AppDatabase(queue)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1") }, AppDatabase.currentSchemaVersion)
    }
}
