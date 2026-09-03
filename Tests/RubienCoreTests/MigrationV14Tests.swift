import XCTest
import GRDB
@testable import RubienCore

final class MigrationV14Tests: XCTestCase {
    private func makeV13Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV13DatabaseForTesting(on: queue)
        return queue
    }

    func testV12FixtureStillStopsBeforeV13AndV14() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV12DatabaseForTesting(on: queue)

        let applied = try queue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations"
            ))
        }
        XCTAssertTrue(applied.contains("v12"))
        XCTAssertFalse(applied.contains("v13"))
        XCTAssertFalse(applied.contains("v14"))
    }

    func testV14RepairsLiveAndAbsentContradictoryIntent() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES('live-tag', 'Live', '#007AFF', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES
                    ('tag', 'live-tag', 1, 0),
                    ('tag', 'absent-tag', 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('tag', 'absent-tag', 1, 1)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId='live-tag'
                """))
            let liveState = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT isDirty, pushInFlight FROM syncState
                WHERE entityType='tag' AND entityId='live-tag'
                """))
            XCTAssertEqual(liveState["isDirty"] as Int?, 1)
            XCTAssertEqual(liveState["pushInFlight"] as Int?, 0)

            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='tag' AND entityId='absent-tag'
                """))
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId='absent-tag'
                """))
        }
    }

    func testV14PreservesActiveDeleteWhenLiveRowHasNoDirtyState() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES('pending-delete', 'Fetched Again', '#007AFF', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                DELETE FROM syncState
                WHERE entityType='tag' AND entityId='pending-delete'
                """)
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES('tag', 'pending-delete', 0, 1)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tag WHERE syncId='pending-delete'
                """))
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='tag' AND entityId='pending-delete'
                """))
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId='pending-delete'
                  AND confirmedByServer=0 AND isPushEligible=1
                """))
        }
    }

    func testReplacementTriggersMakeSaveAndDeleteMutuallyExclusive() throws {
        let database = try AppDatabase(DatabaseQueue())

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES('recreated-tag', 'First', '#007AFF', ?)
                """, arguments: [Date()])
            try db.execute(sql: "DELETE FROM tag WHERE syncId='recreated-tag'")

            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='tag' AND entityId='recreated-tag'
                """))
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId='recreated-tag'
                  AND confirmedByServer=0
                """))

            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES('recreated-tag', 'Second', '#007AFF', ?)
                """, arguments: [Date()])

            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId='recreated-tag'
                """))
            let state = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT isDirty, pushInFlight FROM syncState
                WHERE entityType='tag' AND entityId='recreated-tag'
                """))
            XCTAssertEqual(state["isDirty"] as Int?, 1)
            XCTAssertEqual(state["pushInFlight"] as Int?, 0)
        }
    }

    func testReferenceTagDeleteThenRecreateLeavesOnlyDirtySave() throws {
        let database = try AppDatabase(DatabaseQueue())
        let referenceSyncId = "reference-global-id"
        let tagSyncId = "tag-global-id"
        let pivotSyncId = "\(referenceSyncId)/\(tagSyncId)"

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO reference(
                    syncId, title, dateAdded, dateModified
                ) VALUES(?, 'Reference', ?, ?)
                """, arguments: [referenceSyncId, Date(), Date()])
            let referenceId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Tag', '#007AFF', ?)
                """, arguments: [tagSyncId, Date()])
            let tagId = db.lastInsertedRowID
            let insertPivot = """
                INSERT INTO referenceTag(
                    syncId, referenceId, tagId,
                    referenceSyncId, tagSyncId, dateModified
                ) VALUES(?, ?, ?, ?, ?, ?)
                """
            try db.execute(sql: insertPivot, arguments: [
                pivotSyncId,
                referenceId,
                tagId,
                referenceSyncId,
                tagSyncId,
                Date(),
            ])

            try db.execute(
                sql: "DELETE FROM referenceTag WHERE syncId = ?",
                arguments: [pivotSyncId]
            )
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referenceTag' AND entityId=?
                """, arguments: [pivotSyncId]))
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='referenceTag' AND entityId=?
                """, arguments: [pivotSyncId]))

            try db.execute(sql: insertPivot, arguments: [
                pivotSyncId,
                referenceId,
                tagId,
                referenceSyncId,
                tagSyncId,
                Date(),
            ])

            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='referenceTag' AND entityId=?
                """, arguments: [pivotSyncId]))
            let state = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT isDirty, pushInFlight FROM syncState
                WHERE entityType='referenceTag' AND entityId=?
                """, arguments: [pivotSyncId]))
            XCTAssertEqual(state["isDirty"] as Int?, 1)
            XCTAssertEqual(state["pushInFlight"] as Int?, 0)
        }
    }

    func testNaturalKeyTriggersClearStaleTombstonesAndQueueDeletes() throws {
        let database = try AppDatabase(DatabaseQueue())

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES
                    ('assistantActivity', 'activity-1', 1, 0),
                    ('activityEpoch', 'assistant', 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO assistantActivity(
                    id, provider, epochRevision, generation,
                    startedAt, localDay, dateModified
                ) VALUES(
                    'activity-1', 'codex', 0, 'generation-1',
                    ?, '2026-09-02', ?
                )
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                UPDATE activityEpoch
                SET generation='generation-1', dateModified=?
                WHERE kind='assistant'
                """, arguments: [Date()])

            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE (entityType='assistantActivity' AND entityId='activity-1')
                   OR (entityType='activityEpoch' AND entityId='assistant')
                """), 0)

            try db.execute(sql: "DELETE FROM assistantActivity WHERE id='activity-1'")
            try db.execute(sql: "DELETE FROM activityEpoch WHERE kind='assistant'")

            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE confirmedByServer=0 AND isPushEligible=1
                  AND (
                    (entityType='assistantActivity' AND entityId='activity-1')
                    OR (entityType='activityEpoch' AND entityId='assistant')
                  )
                """), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE (entityType='assistantActivity' AND entityId='activity-1')
                   OR (entityType='activityEpoch' AND entityId='assistant')
                """), 0)
        }
    }

    func testDeleteReopensConfirmedTombstoneForEveryTriggerFamily() throws {
        let database = try AppDatabase(DatabaseQueue())

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES
                    ('tag', 'remote-tag', 1, 1),
                    ('assistantActivity', 'remote-activity', 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO syncSession(key, value)
                VALUES('applyingRemote', '1')
                """)
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES('remote-tag', 'Remote', '#007AFF', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO assistantActivity(
                    id, provider, epochRevision, generation,
                    startedAt, localDay, dateModified
                ) VALUES(
                    'remote-activity', 'codex', 0, 'generation-1',
                    ?, '2026-09-02', ?
                )
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                DELETE FROM syncSession WHERE key='applyingRemote'
                """)

            try db.execute(sql: "DELETE FROM tag WHERE syncId='remote-tag'")
            try db.execute(sql: """
                DELETE FROM assistantActivity WHERE id='remote-activity'
                """)

            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE confirmedByServer=0 AND isPushEligible=1
                  AND (
                    (entityType='tag' AND entityId='remote-tag')
                    OR (
                        entityType='assistantActivity'
                        AND entityId='remote-activity'
                    )
                  )
                """), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE (entityType='tag' AND entityId='remote-tag')
                   OR (
                       entityType='assistantActivity'
                       AND entityId='remote-activity'
                   )
                """), 0)
        }
    }

    func testV14UpgradesUnconfirmedActivityTombstonesToPushEligible() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES
                    ('assistantActivity', 'old-activity', 0, 0),
                    ('activityEpoch', 'retired-epoch', 0, 0)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE confirmedByServer=0 AND isPushEligible=1
                  AND entityType IN ('assistantActivity', 'activityEpoch')
                """), 2)
        }
    }

    func testV14RetiresLegacyIneligibleTombstoneBesideLiveEpoch() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                UPDATE syncState SET isDirty=0, pushInFlight=0
                WHERE entityType='activityEpoch' AND entityId='assistant'
                """)
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES('activityEpoch', 'assistant', 0, 0)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='activityEpoch' AND entityId='assistant'
                """))
            let state = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT isDirty, pushInFlight FROM syncState
                WHERE entityType='activityEpoch' AND entityId='assistant'
                """))
            XCTAssertEqual(state["isDirty"] as Int?, 1)
            XCTAssertEqual(state["pushInFlight"] as Int?, 0)
        }
    }

    func testV14MovesSafeLegacyPDFStateToOwningReferenceIdentity() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES(42, 'reference-uuid', 'PDF owner', ?, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES(42, 'paper.pdf', 'hash', 1, ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('referencePDF', '42', 1, 1)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='42'
                """))
            let moved = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT isDirty, pushInFlight FROM syncState
                WHERE entityType='referencePDF' AND entityId='reference-uuid'
                """))
            XCTAssertEqual(moved["isDirty"] as Int?, 1)
            XCTAssertEqual(moved["pushInFlight"] as Int?, 0)
        }
    }

    func testV14MergesCleanLegacyPDFStateWithoutForcingTargetDirty() throws {
        let queue = try makeV13Queue()
        let pushedAt = Date(timeIntervalSince1970: 1_788_000_000)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES(42, 'reference-uuid', 'PDF owner', ?, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES(42, 'paper.pdf', 'hash', 1, ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, systemFields, lastPushedAt,
                    isDirty, pushInFlight
                ) VALUES
                    ('referencePDF', 'reference-uuid', X'01', ?, 0, 1),
                    ('referencePDF', '42', NULL, NULL, 0, 1)
                """, arguments: [pushedAt])
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='42'
                """))
            let target = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT systemFields, lastPushedAt, isDirty, pushInFlight
                FROM syncState
                WHERE entityType='referencePDF' AND entityId='reference-uuid'
                """))
            let targetPushedAt = try XCTUnwrap(target["lastPushedAt"] as Date?)
            XCTAssertEqual(target["systemFields"] as Data?, Data([1]))
            XCTAssertEqual(
                targetPushedAt.timeIntervalSince1970,
                pushedAt.timeIntervalSince1970,
                accuracy: 0.001
            )
            XCTAssertEqual(target["isDirty"] as Int?, 0)
            XCTAssertEqual(target["pushInFlight"] as Int?, 0)
        }
    }

    func testV14PreservesProvenLegacyPDFState() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES(43, 'reference-uuid', 'PDF owner', ?, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES(43, 'paper.pdf', 'hash', 1, ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, systemFields, lastPushedAt,
                    isDirty, pushInFlight
                ) VALUES('referencePDF', '43', X'01', ?, 1, 1)
                """, arguments: [Date()])
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='43'
                """))
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='reference-uuid'
                """))
        }
    }

    func testV14PreservesCanonicalNumericPDFIdentity() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES(42, '42', 'Legacy PDF owner', ?, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES(42, 'paper.pdf', 'hash', 1, ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('referencePDF', '42', 1, 0)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='42'
                """))
        }
    }

    func testV14PreservesCanonicalNumericPDFIdentityAtDifferentLocalRow() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES(43, '42', 'Canonical PDF owner', ?, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES(43, 'paper.pdf', 'hash', 1, ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('referencePDF', '42', 1, 0)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='42'
                """))
        }
    }

    func testV14PreservesAmbiguousNumericPDFCollision() throws {
        let queue = try makeV13Queue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES
                    (42, 'reference-uuid', 'Legacy interpretation', ?, ?),
                    (43, '42', 'Canonical interpretation', ?, ?)
                """, arguments: [Date(), Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES
                    (42, 'legacy.pdf', 'legacy-hash', 1, ?),
                    (43, 'canonical.pdf', 'canonical-hash', 1, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('referencePDF', '42', 1, 0)
                """)
        }

        _ = try AppDatabase(queue)

        try queue.read { db in
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='42'
                """))
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='referencePDF' AND entityId='reference-uuid'
                """))
        }
    }
}
