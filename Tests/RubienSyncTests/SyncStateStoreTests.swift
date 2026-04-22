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

    func testMarkPushedArchivesSystemFieldsAndClearsDirty() throws {
        let record = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(
                recordName: "1",
                zoneID: SyncConstants.libraryZoneID
            )
        )

        try db.dbWriter.write { db in
            // Prime a dirty row via the insert trigger, then push.
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 't', '#000')")

            try self.store.markPushed(
                db,
                entityType: .tag,
                entityId: "1",
                record: record
            )

            let isDirty = try Int.fetchOne(
                db,
                sql: "SELECT isDirty FROM syncState WHERE entityType='tag' AND entityId='1'"
            )
            XCTAssertEqual(isDirty, 0, "markPushed must clear isDirty")

            let blob = try self.store.loadSystemFields(db, entityType: .tag, entityId: "1")
            XCTAssertNotNil(blob, "markPushed must archive system fields for next-push rehydrate")
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

    func testCompactTombstonesByCutoff() throws {
        try db.dbWriter.write { db in
            let oldDate = Date(timeIntervalSince1970: 1_000_000)
            let freshDate = Date()

            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "1",
                deletedAt: oldDate
            )
            try self.store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "2",
                deletedAt: freshDate
            )

            try self.store.compactTombstones(db, olderThan: Date(timeIntervalSince1970: 2_000_000))

            let remaining = try String.fetchAll(
                db,
                sql: "SELECT entityId FROM tombstone ORDER BY entityId"
            )
            XCTAssertEqual(remaining, ["2"], "compaction must keep fresh tombstones, evict stale")
        }
    }

    // MARK: - Dirty + tombstone scan

    func testDirtyEntitiesReflectsTriggerActivity() throws {
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 'a', '#fff')")
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(2, 'b', '#fff')")

            let dirty = try self.store.dirtyEntities(db)
            let ids = dirty.map { $0.1 }.sorted()
            XCTAssertEqual(ids, ["1", "2"])
            XCTAssertTrue(dirty.allSatisfy { $0.0 == .tag })
        }
    }
}
