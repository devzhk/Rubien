import Foundation
import GRDB
import XCTest
@testable import RubienCore

final class MigrationV15Tests: XCTestCase {
    func testUpgradePreservesPrimaryContentAndIntent() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV14DatabaseForTesting(on: queue)
        var reference = Reference(title: "Existing paper")
        reference.notes = "Offline note"
        reference.webContent = "Existing clip"
        try queue.write { db in
            try reference.insert(db)
            try db.execute(sql: "INSERT INTO pdfCache(referenceId,localFilename,contentHash,assetVersion,materializedAt,lastOpenedAt) VALUES(?, 'primary.pdf', 'existing-hash', 1, ?, ?)",
                           arguments: [reference.id!, Date(), Date()])
        }
        let before = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM syncState ORDER BY entityType,entityId")
        }
        let database = try AppDatabase(queue)
        try database.dbWriter.read { db in
            let after = try XCTUnwrap(Reference.fetchOne(db, key: reference.id!))
            XCTAssertEqual(after.notes, "Offline note")
            XCTAssertEqual(after.webContent, "Existing clip")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT localFilename FROM pdfCache"), "primary.pdf")
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM syncState ORDER BY entityType,entityId"), before)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceAttachment"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"), AppDatabase.currentSchemaVersion)
        }
        _ = try AppDatabase(queue)
    }

    func testHistoricalFixtureDoesNotInstallAttachments() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV14DatabaseForTesting(on: queue)
        XCTAssertFalse(try queue.read { try $0.tableExists("referenceAttachment") })
    }
}
