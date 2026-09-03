#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

final class SyncRepairParityTests: XCTestCase {
    private func makeFixture() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV13DatabaseForTesting(on: queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES
                    ('live-tag', 'Live', '#fff', ?),
                    ('fetched-delete', 'Fetched Again', '#fff', ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                DELETE FROM syncState
                WHERE entityType='tag' AND entityId='fetched-delete'
                """)
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES
                    ('tag', 'live-tag', 0, 1),
                    ('tag', 'fetched-delete', 0, 1),
                    ('tag', 'deleted-tag', 0, 1),
                    ('assistantActivity', 'retired-activity', 0, 0),
                    ('activityEpoch', 'assistant', 0, 0)
                """)
            try db.execute(sql: """
                UPDATE syncState SET isDirty=0, pushInFlight=0
                WHERE entityType='activityEpoch' AND entityId='assistant'
                """)
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('tag', 'deleted-tag', 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES
                    (42, 'reference-uuid', 'PDF', ?, ?),
                    (-1, 'negative-reference-uuid', 'Negative PDF', ?, ?)
                """, arguments: [Date(), Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash,
                    assetVersion, materializedAt
                ) VALUES
                    (42, 'paper.pdf', 'hash', 1, ?),
                    (-1, 'negative.pdf', 'negative-hash', 1, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES
                    ('referencePDF', '42', 1, 0),
                    ('referencePDF', '-1', 1, 0)
                """)
        }
        return queue
    }

    private func snapshot(_ queue: DatabaseQueue) throws -> [[String]] {
        try queue.read { db in
            let states = try Row.fetchAll(db, sql: """
                SELECT entityType, entityId, isDirty, pushInFlight
                FROM syncState
                WHERE entityId IN (
                    'live-tag', 'fetched-delete', 'deleted-tag', 'retired-activity',
                    'assistant',
                    '42', 'reference-uuid', '-1', 'negative-reference-uuid'
                )
                ORDER BY entityType, entityId
                """).map { row in
                    [
                        row["entityType"] as String,
                        row["entityId"] as String,
                        String(row["isDirty"] as Int),
                        String(row["pushInFlight"] as Int),
                    ]
                }
            let tombstones = try Row.fetchAll(db, sql: """
                SELECT entityType, entityId, confirmedByServer, isPushEligible
                FROM tombstone
                WHERE entityId IN (
                    'live-tag', 'fetched-delete', 'deleted-tag', 'retired-activity',
                    'assistant',
                    '42', 'reference-uuid', '-1', 'negative-reference-uuid'
                )
                ORDER BY entityType, entityId
                """).map { row in
                    [
                        "tombstone:\(row["entityType"] as String)",
                        row["entityId"] as String,
                        String(row["confirmedByServer"] as Int),
                        String(row["isPushEligible"] as Int),
                    ]
                }
            return states + tombstones
        }
    }

    func testFrozenV14AndRuntimeRepairAgreeOnSharedRules() throws {
        let migrated = try makeFixture()
        let repaired = try makeFixture()

        _ = try AppDatabase(migrated)
        try repaired.write { db in
            _ = try SyncStateStore().repairDurableIntent(db)
        }

        XCTAssertEqual(try snapshot(migrated), try snapshot(repaired))
    }
}
#endif
