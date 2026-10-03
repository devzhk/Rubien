import Foundation
import GRDB
import XCTest
@testable import RubienCore

final class MigrationV16Tests: XCTestCase {
    func testUpgradePreservesExistingConversationAndSyncIntent() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV14DatabaseForTesting(on: queue)
        try queue.write { db in
            try AppDatabase.applyV15AttachmentSchema(db)
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v15')")
            try db.execute(sql: """
                INSERT INTO assistantConversation
                  (id, provider, origin, workspaceIdentityHash, contextKind, createdAt, lastActivityAt)
                VALUES ('old-chat', 'claude', 'rubien', 'workspace', 'library', ?, ?)
                """, arguments: [Date(), Date()])
        }
        let before = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }
        let database = try AppDatabase(queue)
        let conversation = try XCTUnwrap(database.fetchAssistantConversation(id: "old-chat"))
        XCTAssertEqual(conversation.contextKind, .library)
        XCTAssertNil(conversation.attachmentSyncId)
        XCTAssertEqual(try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }, before)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1") }, AppDatabase.currentSchemaVersion)
        _ = try AppDatabase(queue)
        XCTAssertNotNil(try database.fetchAssistantConversation(id: "old-chat"))
    }
}
