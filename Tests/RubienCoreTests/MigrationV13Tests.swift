import XCTest
import GRDB
#if canImport(CloudKit)
import CloudKit
#endif
@testable import RubienCore

final class MigrationV13Tests: XCTestCase {
    private func makeV12Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV12DatabaseForTesting(on: queue)
        return queue
    }

    private func insertTag(
        id: Int64,
        name: String,
        on queue: DatabaseQueue
    ) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tag(id, name, color, dateModified)
                VALUES(?, ?, '#007AFF', ?)
                """, arguments: [id, name, Date()])
        }
    }

    #if canImport(CloudKit)
    private func archivedSystemFields(
        recordType: String,
        recordName: String
    ) -> Data {
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: recordName)
        )
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
    #endif

    func testFreshSchemaHasGlobalIdentityColumnsAndInterlockMarkers() throws {
        let database = try AppDatabase(DatabaseQueue())
        try database.dbWriter.read { db in
            let requiredColumns: [String: Set<String>] = [
                "reference": ["syncId"],
                "tag": ["syncId"],
                "referenceTag": ["syncId", "referenceSyncId", "tagSyncId"],
                "pdfAnnotation": ["syncId", "referenceSyncId"],
                "webAnnotation": ["syncId", "referenceSyncId"],
                "metadataIntake": ["syncId", "linkedReferenceSyncId"],
                "metadataEvidence": ["syncId", "intakeSyncId", "referenceSyncId"],
                "propertyDefinition": ["syncId"],
                "propertyValue": ["syncId", "referenceSyncId", "propertySyncId"],
                "databaseView": ["syncId"],
                "readingActivity": ["syncId", "referenceSyncId"],
                "activityQuarantine": ["referenceSyncId"],
                "tombstone": ["isPushEligible"],
            ]
            for (table, expected) in requiredColumns {
                let names = Set(try db.columns(in: table).map(\.name))
                XCTAssertTrue(expected.isSubset(of: names), "\(table) missing \(expected.subtracting(names))")
            }
            XCTAssertTrue(try db.tableExists("syncIdentityAlias"))
            XCTAssertTrue(try db.tableExists("syncLegacyPDFCacheOrphan"))
            XCTAssertTrue(try db.tableExists("syncLegacyPDFUploadQueueOrphan"))
            XCTAssertTrue(try db.tableExists("syncLegacyWebContentCacheOrphan"))

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='fullHistoryReplayPending'"),
                "1"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='writerUpgradeRequired'"),
                "1"
            )
        }
    }

    func testUpgradePreservesTransientForeignKeyOrphanForReplayRepair() throws {
        let queue = try makeV12Queue()
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            do {
                try db.execute(sql: """
                    INSERT INTO referenceTag(referenceId, tagId, dateModified)
                    VALUES(9001, 9002, ?)
                    """, arguments: [Date(timeIntervalSince1970: 1)])
            } catch {
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
                throw error
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        XCTAssertNoThrow(try AppDatabase(queue))

        try queue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT syncId, referenceSyncId, tagSyncId
                FROM referenceTag
                WHERE referenceId = 9001 AND tagId = 9002
                """))
            XCTAssertEqual(row["syncId"] as String?, "9001/9002")
            XCTAssertEqual(row["referenceSyncId"] as String?, "9001")
            XCTAssertEqual(row["tagSyncId"] as String?, "9002")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"),
                2
            )
            XCTAssertTrue(try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations"
            ).contains("v13"))
        }
    }

    func testPreV13DurableJSONDecodesWithoutIdentityKeys() throws {
        let reference = Reference(title: "Legacy intake snapshot")
        var referenceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
                as? [String: Any]
        )
        referenceObject.removeValue(forKey: "syncId")
        let decodedReference = try JSONDecoder().decode(
            Reference.self,
            from: JSONSerialization.data(withJSONObject: referenceObject)
        )
        XCTAssertFalse(decodedReference.syncId.isEmpty)
        XCTAssertEqual(decodedReference.title, reference.title)

        let reading = ReadingActivity(
            installationId: "legacy-mac",
            referenceId: 42,
            localDay: try XCTUnwrap(LocalDay(rawValue: "2026-08-14")),
            epochRevision: 0,
            generation: "reading-v7-initial",
            activeSeconds: 60,
            lastActiveAt: Date(timeIntervalSince1970: 100)
        )
        var readingObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reading))
                as? [String: Any]
        )
        readingObject.removeValue(forKey: "syncId")
        readingObject.removeValue(forKey: "referenceSyncId")
        let decodedReading = try JSONDecoder().decode(
            ReadingActivity.self,
            from: JSONSerialization.data(withJSONObject: readingObject)
        )
        XCTAssertEqual(decodedReading.syncId, "")
        XCTAssertEqual(decodedReading.referenceSyncId, "")
        XCTAssertEqual(decodedReading.entityId, reading.entityId)
    }

    #if canImport(CloudKit)
    func testUpgradePreservesProvenIdentityAndRekeysUnconfirmedRows() throws {
        let queue = try makeV12Queue()
        try insertTag(id: 901, name: "Proven", on: queue)
        try insertTag(id: 902, name: "Local", on: queue)
        let archived = archivedSystemFields(
            recordType: "CDTag",
            recordName: "tag:901"
        )
        try queue.write { db in
            try db.execute(sql: """
                UPDATE syncState
                SET systemFields = ?, isDirty = 0, pushInFlight = 1,
                    lastPushedAt = ?
                WHERE entityType = 'tag' AND entityId = '901'
                """, arguments: [archived, Date(timeIntervalSince1970: 10)])
            try db.execute(sql: """
                INSERT INTO tombstone(entityType, entityId, confirmedByServer)
                VALUES ('tag', '801', 1), ('tag', '802', 0)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE id=901"),
                "901"
            )
            let localSyncId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE id=902")
            )
            XCTAssertFalse(SyncIdentifier.isCanonicalDecimal(localSyncId))

            let proven = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT systemFields, isDirty, pushInFlight
                FROM syncState WHERE entityType='tag' AND entityId='901'
                """))
            XCTAssertEqual(proven["systemFields"] as Data?, archived)
            XCTAssertEqual(proven["isDirty"] as Int?, 0)
            XCTAssertEqual(proven["pushInFlight"] as Int?, 0)

            let local = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT systemFields, isDirty, pushInFlight
                FROM syncState WHERE entityType='tag' AND entityId=?
                """, arguments: [localSyncId]))
            XCTAssertNil(local["systemFields"] as Data?)
            XCTAssertEqual(local["isDirty"] as Int?, 1)
            XCTAssertEqual(local["pushInFlight"] as Int?, 0)
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState WHERE entityType='tag' AND entityId='902'
                """))

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT isPushEligible FROM tombstone WHERE entityId='801'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT isPushEligible FROM tombstone WHERE entityId='802'"),
                0
            )
        }
    }

    func testSingleUnreadableArchiveIsQuarantinedWithinAbsoluteCap() throws {
        let queue = try makeV12Queue()
        try insertTag(id: 910, name: "Unreadable", on: queue)
        try queue.write { db in
            try db.execute(sql: """
                UPDATE syncState SET systemFields = X'010203'
                WHERE entityType='tag' AND entityId='910'
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            let syncId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE id=910")
            )
            XCTAssertFalse(SyncIdentifier.isCanonicalDecimal(syncId))
            XCTAssertNil(try Data.fetchOne(db, sql: """
                SELECT systemFields FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [syncId]))
        }
    }

    func testProvenCompoundRecordPreservesItsParentIdentities() throws {
        let queue = try makeV12Queue()
        let archived = archivedSystemFields(
            recordType: "CDReferenceTag",
            recordName: "referenceTag:951/952"
        )
        try queue.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified)
                VALUES(951, 'Parent proven by pivot', ?, ?)
                """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO tag(id, name, color, dateModified)
                VALUES(952, 'Pivot tag', '#007AFF', ?)
                """, arguments: [now])
            try db.execute(sql: """
                INSERT INTO referenceTag(referenceId, tagId, dateModified)
                VALUES(951, 952, ?)
                """, arguments: [now])
            try db.execute(sql: """
                UPDATE syncState SET systemFields = ?
                WHERE entityType='referenceTag' AND entityId='951/952'
                """, arguments: [archived])
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT syncId FROM reference WHERE id=951"),
                "951"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE id=952"),
                "952"
            )
            let pivot = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT syncId, referenceSyncId, tagSyncId FROM referenceTag
                WHERE referenceId=951 AND tagId=952
                """))
            XCTAssertEqual(pivot["syncId"] as String?, "951/952")
            XCTAssertEqual(pivot["referenceSyncId"] as String?, "951")
            XCTAssertEqual(pivot["tagSyncId"] as String?, "952")
        }
    }

    func testArchiveFailuresAboveCapAbortWithoutChangingV12Schema() throws {
        let queue = try makeV12Queue()
        for id in 920 ... 930 {
            try insertTag(id: Int64(id), name: "Unreadable \(id)", on: queue)
        }
        try queue.write { db in
            try db.execute(sql: """
                UPDATE syncState SET systemFields = X'010203'
                WHERE entityType='tag' AND CAST(entityId AS INTEGER) BETWEEN 920 AND 930
                """)
        }

        XCTAssertThrowsError(try AppDatabase(queue)) { error in
            XCTAssertEqual(
                error as? SyncIdentityMigrationError,
                .identityArchiveClassificationFailed(total: 11, failed: 11)
            )
        }
        try queue.read { db in
            XCTAssertFalse(try db.columns(in: "tag").contains { $0.name == "syncId" })
            XCTAssertFalse(try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations"
            ).contains("v13"))
        }
    }
    #else
    func testLinuxArchivePreflightAbortsWithoutChangingV12Schema() throws {
        let queue = try makeV12Queue()
        try insertTag(id: 901, name: "Archived", on: queue)
        try queue.write { db in
            try db.execute(sql: """
                UPDATE syncState SET systemFields = X'010203'
                WHERE entityType='tag' AND entityId='901'
                """)
        }

        XCTAssertThrowsError(try AppDatabase(queue)) { error in
            XCTAssertEqual(
                error as? SyncIdentityMigrationError,
                .requiresAppleIdentityMigration(archivedRecordCount: 1)
            )
        }
        try queue.read { db in
            XCTAssertFalse(try db.columns(in: "tag").contains { $0.name == "syncId" })
        }
    }
    #endif

    func testNewerSchemaIsRejectedBeforeMigration() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES('v14')")
        }
        XCTAssertThrowsError(try AppDatabase(queue)) { error in
            XCTAssertEqual(
                error as? SyncIdentityMigrationError,
                .databaseSchemaIsNewerThanThisBuild
            )
        }
    }
}
