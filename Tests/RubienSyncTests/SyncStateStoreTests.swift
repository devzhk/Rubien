#if canImport(RubienSync)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class SyncStateStoreTests: XCTestCase {

    private var db: AppDatabase!
    private let store = SyncStateStore()

    override func setUpWithError() throws {
        try super.setUpWithError()
        // In-memory — the v1 migration creates every sync-bookkeeping table
        // we need, so the store has its schema contract satisfied without
        // any fixture work.
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    // MARK: - applyingRemote guard

    func testApplyingRemoteSuppressesInsertTrigger() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try db.execute(sql: """
                INSERT INTO tag(name, color) VALUES('x', '#000000')
                """)
            try self.store.clearApplyingRemote(db)

            let dirtyCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM syncState WHERE entityType='tag'"
            ) ?? -1
            XCTAssertEqual(
                dirtyCount,
                0,
                "apply-remote must suppress the INSERT trigger; otherwise we re-dirty rows we're applying from the cloud"
            )
        }
    }

    func testSessionGuardClearsBetweenTransactions() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try self.store.clearApplyingRemote(db)

            try db.execute(sql: """
                INSERT INTO tag(name, color) VALUES('y', '#000000')
                """)
            let dirty = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM syncState WHERE entityType='tag'"
            ) ?? 0
            XCTAssertEqual(dirty, 1, "after clearApplyingRemote the normal trigger must resume")
        }
    }

    // MARK: - syncState lifecycle

    func testMarkPushedClearsDirtyWhenPushInFlightHeld() throws {
        let record = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(
                recordName: "1",
                zoneID: SyncConstants.libraryZoneID
            )
        )

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 't', '#000')")

            // Simulate a clean push cycle: batch builder stamps pushInFlight,
            // then the ack arrives with no intervening local edits.
            try self.store.markPushInFlight(db, entityType: .tag, entityId: "1")
            try self.store.markPushed(db, entityType: .tag, entityId: "1", record: record)

            let isDirty = try Int.fetchOne(
                db,
                sql: "SELECT isDirty FROM syncState WHERE entityType='tag' AND entityId='1'"
            )
            XCTAssertEqual(isDirty, 0, "clean push cycle must clear isDirty")

            let blob = try self.store.loadSystemFields(db, entityType: .tag, entityId: "1")
            XCTAssertNotNil(blob, "markPushed must archive system fields for next-push rehydrate")
        }
    }

    func testMarkPushedLeavesDirtySetIfLocalEditRaced() throws {
        // Closes codex-rescue Blocker 8: an edit committed between
        // batch-build and save-ack must not be clobbered by markPushed.
        let record = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(recordName: "1", zoneID: SyncConstants.libraryZoneID)
        )

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 'a', '#000')")
            try self.store.markPushInFlight(db, entityType: .tag, entityId: "1")

            // Racing local edit: the UPDATE trigger clears pushInFlight
            // back to 0 and bumps isDirty=1. (It was already 1; the reset
            // of pushInFlight is what matters for the invariant.)
            try db.execute(sql: "UPDATE tag SET name = 'b' WHERE id = 1")

            try self.store.markPushed(db, entityType: .tag, entityId: "1", record: record)

            let isDirty = try Int.fetchOne(
                db,
                sql: "SELECT isDirty FROM syncState WHERE entityType='tag' AND entityId='1'"
            )
            XCTAssertEqual(
                isDirty,
                1,
                "an edit between batch-build and ack must leave isDirty=1 so re-push happens"
            )
        }
    }

    func testClearSystemFieldsPreservesDirtyFlag() throws {
        // Closes codex-rescue Blocker 4: on .unknownItem we drop cached
        // system fields (to force a fresh create on retry) but must NOT
        // touch isDirty. If isDirty were cleared, the retry push never
        // fires and a row intended for sync strands locally.
        try db.dbWriter.write { db in
            // Fresh local row → trigger sets isDirty=1; no systemFields
            // cached yet (we've never synced before).
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 't', '#000')")

            let dirtyBefore = try Int.fetchOne(
                db,
                sql: "SELECT isDirty FROM syncState WHERE entityType='tag' AND entityId='1'"
            )
            XCTAssertEqual(dirtyBefore, 1, "precondition: the insert trigger marks dirty")

            // Arrange a cached system-fields blob the way a prior save
            // would have.
            let record = CKRecord(
                recordType: SyncConstants.RecordType.tag,
                recordID: CKRecord.ID(recordName: "1", zoneID: SyncConstants.libraryZoneID)
            )
            try db.execute(sql: """
                UPDATE syncState SET systemFields = ?
                    WHERE entityType='tag' AND entityId='1'
                """, arguments: [SyncStateStore.archiveSystemFields(of: record)])

            // Server returns .unknownItem → drop cached systemFields.
            try self.store.clearSystemFields(db, entityType: .tag, entityId: "1")

            XCTAssertNil(
                try self.store.loadSystemFields(db, entityType: .tag, entityId: "1"),
                "clearSystemFields must drop the blob so the retry creates a fresh record"
            )
            let dirtyAfter = try Int.fetchOne(
                db,
                sql: "SELECT isDirty FROM syncState WHERE entityType='tag' AND entityId='1'"
            )
            XCTAssertEqual(
                dirtyAfter,
                1,
                "isDirty must remain set so the engine schedules the retry push"
            )
        }
    }

    func testSystemFieldsRoundTrip() {
        let original = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(
                recordName: "42",
                zoneID: SyncConstants.libraryZoneID
            )
        )
        let archived = SyncStateStore.archiveSystemFields(of: original)
        let rehydrated = SyncStateStore.rehydrateRecord(from: archived)

        XCTAssertNotNil(rehydrated)
        XCTAssertEqual(rehydrated?.recordID.recordName, "42")
        XCTAssertEqual(rehydrated?.recordID.zoneID, SyncConstants.libraryZoneID)
        XCTAssertEqual(rehydrated?.recordType, SyncConstants.RecordType.tag)
    }

    // MARK: - tombstone lifecycle

    func testTombstoneUpsertAndRemove() throws {
        try db.dbWriter.write { db in
            try self.store.upsertTombstone(db, entityType: .reference, entityId: "42")
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone") ?? 0
            XCTAssertEqual(count, 1)

            try self.store.removeTombstone(db, entityType: .reference, entityId: "42")
            let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone") ?? -1
            XCTAssertEqual(after, 0)
        }
    }

    func testCompactTombstonesEvictsOldConfirmedKeepsFresh() throws {
        try db.dbWriter.write { db in
            let oldDate = Date(timeIntervalSince1970: 1_000_000)
            let freshDate = Date()

            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "1",
                deletedAt: oldDate,
                confirmedByServer: true
            )
            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "2",
                deletedAt: freshDate,
                confirmedByServer: true
            )

            try self.store.compactTombstones(db, olderThan: Date(timeIntervalSince1970: 2_000_000))

            let remaining = try String.fetchAll(
                db,
                sql: "SELECT entityId FROM tombstone ORDER BY entityId"
            )
            XCTAssertEqual(remaining, ["2"], "compaction must keep fresh tombstones, evict stale confirmed")
        }
    }

    func testCompactTombstonesPreservesUnconfirmed() throws {
        // Closes codex-rescue Blocker 5: evicting an unacknowledged
        // tombstone can let a later server modification of the same
        // recordID resurrect the deleted row ("delete beats edit" needs
        // the marker to still be alive when the edit pull arrives).
        try db.dbWriter.write { db in
            let ancient = Date(timeIntervalSince1970: 0)

            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "unconfirmed",
                deletedAt: ancient,
                confirmedByServer: false
            )

            try self.store.compactTombstones(db, olderThan: Date())

            let surviving = try String.fetchAll(
                db,
                sql: "SELECT entityId FROM tombstone"
            )
            XCTAssertEqual(
                surviving,
                ["unconfirmed"],
                "unconfirmed tombstones must outlive the 30-day window until the server ack's the delete"
            )
        }
    }

    func testMarkTombstoneConfirmedPromotesForCompaction() throws {
        try db.dbWriter.write { db in
            let ancient = Date(timeIntervalSince1970: 0)
            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "7",
                deletedAt: ancient,
                confirmedByServer: false
            )

            try self.store.markTombstoneConfirmed(db, entityId: "7")
            try self.store.compactTombstones(db, olderThan: Date())

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone") ?? -1
            XCTAssertEqual(count, 0, "once server acks delete, tombstone is eligible for compaction")
        }
    }

    func testUpsertTombstoneDoesNotDowngradeConfirmation() throws {
        try db.dbWriter.write { db in
            // Pull-path apply inserts a confirmed tombstone (we learned
            // about the deletion from the server).
            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "9",
                confirmedByServer: true
            )
            // Then — race — a local delete fires the trigger, which
            // upserts with confirmedByServer=false default. The existing
            // confirmed=1 must stick.
            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "9",
                confirmedByServer: false
            )

            let confirmed = try Int.fetchOne(db, sql: """
                SELECT confirmedByServer FROM tombstone WHERE entityId='9'
                """)
            XCTAssertEqual(
                confirmed,
                1,
                "once confirmed by server, later upserts must not downgrade — that would re-open the GC gate prematurely"
            )
        }
    }

    // MARK: - Dirty + tombstone scan

    func testDirtyEntitiesReflectsTriggerActivity() throws {
        try db.dbWriter.write { db in
            // Clear the syncState rows left over from migrations (v1's seeded
            // PropertyDefinitions and v5's Last Read / Read Count seeds all
            // fire the dirty trigger on insert). We're testing the trigger
            // behavior for the two tag inserts that follow.
            try db.execute(sql: "DELETE FROM syncState")

            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 'a', '#fff')")
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(2, 'b', '#fff')")

            let dirty = try self.store.dirtyEntities(db)
            let ids = dirty.map { $0.1 }.sorted()
            XCTAssertEqual(ids, ["1", "2"])
            XCTAssertTrue(dirty.allSatisfy { $0.0 == .tag })
        }
    }
}
#endif
