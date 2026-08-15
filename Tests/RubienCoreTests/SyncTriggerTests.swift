import XCTest
import GRDB
@testable import RubienCore

/// Tests for the A-infra sync bookkeeping layer: dirty-tracking triggers,
/// tombstone creation on delete, FK cascade propagation, and the
/// applyingRemote suppression mechanism used by the pull path.
final class SyncTriggerTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    // MARK: - Helpers

    private func syncStateRow(
        db: AppDatabase,
        entityType: String,
        entityId: String
    ) throws -> (isDirty: Int, hasSystemFields: Bool)? {
        try db.dbWriter.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT isDirty, systemFields
                    FROM syncState
                    WHERE entityType = ? AND entityId = ?
                    """,
                arguments: [entityType, entityId]
            ) else { return nil }
            let isDirty: Int = row["isDirty"]
            let blob: Data? = row["systemFields"]
            return (isDirty, blob != nil)
        }
    }

    private func tombstoneExists(
        db: AppDatabase,
        entityType: String,
        entityId: String
    ) throws -> Bool {
        try db.dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tombstone WHERE entityType = ? AND entityId = ?",
                arguments: [entityType, entityId]
            ) ?? 0
        } > 0
    }

    // MARK: - Insert / update / delete trigger basics

    func testInsertOnTagMarksDirty() throws {
        let db = try makeDatabase()
        let tagSyncId = SyncIdentifier.random()
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [tagSyncId, "Research", "#FF0000"])
        }

        let state = try syncStateRow(db: db, entityType: "tag", entityId: tagSyncId)
        XCTAssertNotNil(state, "tag insert should have created a syncState row")
        XCTAssertEqual(state?.isDirty, 1)
        XCTAssertEqual(state?.hasSystemFields, false, "new row has no server state yet")
    }

    func testUpdateOnTagMarksDirty() throws {
        let db = try makeDatabase()
        let tagSyncId = SyncIdentifier.random()
        let tagID: Int64 = try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [tagSyncId, "Research", "#FF0000"])
            return db.lastInsertedRowID
        }
        // Simulate a clean syncState row (as if we'd just pushed it).
        try db.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE syncState SET isDirty = 0 WHERE entityType = 'tag' AND entityId = ?",
                arguments: [tagSyncId]
            )
        }
        // Now update the tag — trigger should flip isDirty back to 1.
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE tag SET color = ? WHERE id = ?",
                           arguments: ["#00FF00", tagID])
        }

        let state = try syncStateRow(db: db, entityType: "tag", entityId: tagSyncId)
        XCTAssertEqual(state?.isDirty, 1, "update must re-dirty")
    }

    func testUpdateDoesNotCreateTombstone() throws {
        let db = try makeDatabase()
        let tagSyncId = SyncIdentifier.random()
        let tagID: Int64 = try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [tagSyncId, "Research", "#FF0000"])
            return db.lastInsertedRowID
        }
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE tag SET color = ? WHERE id = ?",
                           arguments: ["#00FF00", tagID])
        }

        XCTAssertFalse(
            try tombstoneExists(db: db, entityType: "tag", entityId: tagSyncId),
            "UPDATE must not produce a tombstone — only DELETE does"
        )
    }

    func testDeleteOnTagProducesTombstoneAndClearsSyncState() throws {
        let db = try makeDatabase()
        let tagSyncId = SyncIdentifier.random()
        let tagID: Int64 = try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [tagSyncId, "Research", "#FF0000"])
            return db.lastInsertedRowID
        }
        try db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [tagID])
        }

        let state = try syncStateRow(db: db, entityType: "tag", entityId: tagSyncId)
        XCTAssertNil(state, "syncState row should be removed on delete")
        XCTAssertTrue(try tombstoneExists(db: db, entityType: "tag", entityId: tagSyncId))
    }

    // MARK: - applyingRemote suppression

    func testApplyingRemoteSuppressesInsertTrigger() throws {
        let db = try makeDatabase()
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO syncSession(key, value) VALUES('applyingRemote', '1')")
            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [SyncIdentifier.random(), "Remote", "#0000FF"])
            try db.execute(sql: "DELETE FROM syncSession WHERE key = 'applyingRemote'")
        }

        let count = try db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='tag'") ?? -1
        }
        XCTAssertEqual(count, 0, "syncState must be empty when trigger was suppressed")
    }

    func testApplyingRemoteSuppressesDeleteTrigger() throws {
        let db = try makeDatabase()
        let tagSyncId = SyncIdentifier.random()
        let tagID: Int64 = try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [tagSyncId, "WillBeDeletedRemotely", "#0000FF"])
            return db.lastInsertedRowID
        }
        // Clear syncState as the push loop would.
        try db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState WHERE entityType='tag' AND entityId = ?",
                           arguments: [tagSyncId])
            // Remote delete arrives: we apply it under applyingRemote.
            try db.execute(sql: "INSERT INTO syncSession(key, value) VALUES('applyingRemote', '1')")
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [tagID])
            try db.execute(sql: "DELETE FROM syncSession WHERE key = 'applyingRemote'")
        }

        XCTAssertFalse(
            try tombstoneExists(db: db, entityType: "tag", entityId: tagSyncId),
            "remote-applied deletes must NOT produce a local tombstone"
        )
    }

    // MARK: - FK cascade propagation

    func testDeletingReferenceCascadesTombstonesToChildren() throws {
        let db = try makeDatabase()
        let referenceSyncId = SyncIdentifier.random()
        let tagSyncId = SyncIdentifier.random()
        let annotationSyncId = SyncIdentifier.random()
        let pivotSyncId = "\(referenceSyncId)/\(tagSyncId)"

        // Build a reference with a tag link and a PDF annotation.
        let refID: Int64 = try db.dbWriter.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO reference(syncId, title, authors, authorsNormalized, dateAdded, dateModified, verificationStatus, readingStatus, referenceType)
                VALUES(?, 'Parent Ref', '', '', ?, ?, 'verifiedManual', 'unread', 'Journal Article')
                """, arguments: [referenceSyncId, now, now])
            let refID = db.lastInsertedRowID

            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [tagSyncId, "Cascade", "#AABBCC"])
            let tagID = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO referenceTag(syncId, referenceId, tagId, referenceSyncId, tagSyncId)
                VALUES(?, ?, ?, ?, ?)
                """, arguments: [pivotSyncId, refID, tagID, referenceSyncId, tagSyncId])

            try db.execute(sql: """
                INSERT INTO pdfAnnotation(syncId, referenceId, referenceSyncId, type, color, pageIndex, boundsX, boundsY, boundsWidth, boundsHeight, dateCreated)
                VALUES(?, ?, ?, 'highlight', '#FFFF00', 0, 0, 0, 10, 10, ?)
                """, arguments: [annotationSyncId, refID, referenceSyncId, now])
            return refID
        }

        // Delete the reference. FK CASCADE deletes children; their triggers
        // should also fire and produce their own tombstones.
        try db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM reference WHERE id = ?", arguments: [refID])
        }

        XCTAssertTrue(try tombstoneExists(db: db, entityType: "reference", entityId: referenceSyncId))
        XCTAssertTrue(
            try tombstoneExists(db: db, entityType: "pdfAnnotation", entityId: annotationSyncId),
            "cascade-deleted pdfAnnotation must leave its own tombstone"
        )
        XCTAssertTrue(
            try tombstoneExists(db: db, entityType: "referenceTag",
                                entityId: pivotSyncId),
            "cascade-deleted referenceTag uses global parent identities"
        )
    }

    // MARK: - Composite key formatting

    func testReferenceTagEntityIdUsesCompositeKey() throws {
        let db = try makeDatabase()
        let referenceSyncId = SyncIdentifier.random()
        let tagSyncId = SyncIdentifier.random()
        let pivotSyncId = "\(referenceSyncId)/\(tagSyncId)"
        try db.dbWriter.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO reference(syncId, title, authors, authorsNormalized, dateAdded, dateModified, verificationStatus, readingStatus, referenceType)
                VALUES(?, 'Test', '', '', ?, ?, 'verifiedManual', 'unread', 'Journal Article')
                """, arguments: [referenceSyncId, now, now])
            let refID = db.lastInsertedRowID

            try db.execute(sql: "INSERT INTO tag(syncId, name, color) VALUES(?, ?, ?)",
                           arguments: [tagSyncId, "Pivot", "#DDEEFF"])
            let tagID = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO referenceTag(syncId, referenceId, tagId, referenceSyncId, tagSyncId)
                VALUES(?, ?, ?, ?, ?)
                """, arguments: [pivotSyncId, refID, tagID, referenceSyncId, tagSyncId])
        }

        let state = try syncStateRow(
            db: db,
            entityType: "referenceTag",
            entityId: pivotSyncId
        )
        XCTAssertNotNil(state, "referenceTag insert should use global parent identities")
        XCTAssertEqual(state?.isDirty, 1)
    }
}
