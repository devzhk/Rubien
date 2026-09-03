#if os(macOS)
import XCTest
import CloudKit
import GRDB
@testable import RubienCore
@testable import RubienSync

final class SyncPendingIntentTests: XCTestCase {
    private let store = SyncStateStore()

    func testPurePlannerRemovesOppositeIntentAndAddsMissingIntent() {
        let save = PendingSyncIdentity(
            type: .tag,
            entityId: "tag-1",
            operation: .save
        )
        let delete = PendingSyncIdentity(
            type: .tag,
            entityId: "tag-1",
            operation: .delete
        )
        let missing = PendingSyncIdentity(
            type: .reference,
            entityId: "reference-1",
            operation: .save
        )

        let plan = SyncPendingIntentPlanner.plan(
            current: [save, delete],
            desired: [save, missing]
        )

        XCTAssertEqual(plan.removals, [delete])
        XCTAssertEqual(plan.additions, [missing])
    }

    func testResolverDeduplicatesContradictionWithLiveSaveWinning() throws {
        let database = try AppDatabase(DatabaseQueue())
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let save = PendingSyncIdentity(type: .tag, entityId: id, operation: .save)
        let delete = PendingSyncIdentity(type: .tag, entityId: id, operation: .delete)

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Live', '#fff', ?)
                """, arguments: [id, Date()])
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES('tag', ?, 0, 1)
                """, arguments: [id])

            let resolution = try self.store.resolveBatchIntents(
                db,
                pendingIdentities: [delete, save, save]
            )
            XCTAssertTrue(resolution.anomalyDetected)
            XCTAssertEqual(resolution.intents, [save])
        }
    }

    func testFetchedModificationDoesNotDisplacePendingLocalDelete() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let id = "pending-local-delete"
        let library = SyncedLibrary(appDatabase: database)

        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Local', '#fff', ?)
                """, arguments: [id, Date()])
            try db.execute(sql: "DELETE FROM tag WHERE syncId = ?", arguments: [id])
        }
        let remote = Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: id),
            tag: Tag(syncId: id, name: "Fetched Again", color: "#007AFF")
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [remote],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await database.dbWriter.write { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tag WHERE syncId = ?
                """, arguments: [id]), 0)
            let beforeRepair = try self.store.desiredPendingIntents(db)
            XCTAssertEqual(beforeRepair.intents.filter {
                $0.type == .tag && $0.entityId == id
            }, [
                .init(type: .tag, entityId: id, operation: .delete),
            ])

            _ = try self.store.repairDurableIntent(db)

            let afterRepair = try self.store.desiredPendingIntents(db)
            XCTAssertEqual(afterRepair.intents.filter {
                $0.type == .tag && $0.entityId == id
            }, [
                .init(type: .tag, entityId: id, operation: .delete),
            ])
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]))
            XCTAssertNotNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId=?
                  AND confirmedByServer=0 AND isPushEligible=1
                """, arguments: [id]))
        }
    }

    func testFetchedModificationReplacesConfirmedHistoricalTombstone() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let id = "server-recreated-tag"
        let library = SyncedLibrary(appDatabase: database)
        try await database.dbWriter.write { db in
            try self.store.upsertTombstone(
                db,
                entityType: .tag,
                entityId: id,
                confirmedByServer: true
            )
        }
        let remote = Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: id),
            tag: Tag(syncId: id, name: "Server Recreation", color: "#007AFF")
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [remote],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await database.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tag WHERE syncId = ?
                """, arguments: [id]), 1)
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM tombstone
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]))
            let state = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT isDirty, systemFields FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]))
            XCTAssertEqual(state["isDirty"] as Int?, 0)
            XCTAssertNotNil(state["systemFields"] as Data?)
        }
    }

    func testResolverRejectsCleanOrOrphanedSave() throws {
        let database = try AppDatabase(DatabaseQueue())
        let cleanID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let orphanID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Clean', '#fff', ?)
                """, arguments: [cleanID, Date()])
            try db.execute(sql: """
                UPDATE syncState SET isDirty=0
                WHERE entityType='tag' AND entityId=?
                """, arguments: [cleanID])
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty)
                VALUES('tag', ?, 1)
                """, arguments: [orphanID])

            let resolution = try self.store.resolveBatchIntents(
                db,
                pendingIdentities: [
                    .init(type: .tag, entityId: cleanID, operation: .save),
                    .init(type: .tag, entityId: orphanID, operation: .save),
                ]
            )
            XCTAssertTrue(resolution.anomalyDetected)
            XCTAssertTrue(resolution.intents.isEmpty)
        }
    }

    func testConfirmedTombstoneDoesNotSuppressRecreatedSave() throws {
        let database = try AppDatabase(DatabaseQueue())
        let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let save = PendingSyncIdentity(type: .tag, entityId: id, operation: .save)

        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Recreated', '#fff', ?)
                """, arguments: [id, Date()])
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES('tag', ?, 1, 1)
                """, arguments: [id])

            let resolution = try self.store.resolveBatchIntents(
                db,
                pendingIdentities: [save]
            )
            XCTAssertFalse(resolution.anomalyDetected)
            XCTAssertEqual(resolution.intents, [save])
        }
    }

    func testWriterGateFiltersUnsafeIdentityAtResolver() throws {
        let database = try AppDatabase(DatabaseQueue())
        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES('referencePDF', '42', 0, 1)
                """)
            let resolution = try self.store.resolveBatchIntents(
                db,
                pendingIdentities: [
                    .init(
                        type: .referencePDF,
                        entityId: "42",
                        operation: .delete
                    ),
                ]
            )
            XCTAssertTrue(resolution.intents.isEmpty)
        }
    }

    func testDirtyPDFWithoutCacheIsDesiredNone() throws {
        let database = try AppDatabase(DatabaseQueue())
        let id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        try database.dbWriter.write { db in
            try self.store.acknowledgeWriterUpgrade(db)
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty)
                VALUES('referencePDF', ?, 1)
                """, arguments: [id])
            let resolution = try self.store.resolveBatchIntents(
                db,
                pendingIdentities: [
                    .init(type: .referencePDF, entityId: id, operation: .save),
                ]
            )
            XCTAssertTrue(resolution.intents.isEmpty)
            XCTAssertTrue(resolution.anomalyDetected)
        }
    }

    func testDesiredIntentsQuietlyExcludePreservedDirtyOrphan() throws {
        let database = try AppDatabase(DatabaseQueue())
        let id = "preserved-dirty-orphan"
        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty)
                VALUES('tag', ?, 1)
                """, arguments: [id])

            let resolution = try self.store.desiredPendingIntents(db)
            XCTAssertFalse(resolution.anomalyDetected)
            XCTAssertFalse(resolution.intents.contains {
                $0.type == .tag && $0.entityId == id
            })
        }
    }

    func testDesiredPendingIntentsHandlesLargeDirtyQueue() throws {
        let database = try AppDatabase(DatabaseQueue())
        let count = 1_000

        try database.dbWriter.write { db in
            for index in 0..<count {
                try db.execute(sql: """
                    INSERT INTO tag(syncId, name, color, dateModified)
                    VALUES(?, ?, '#fff', ?)
                    """, arguments: [
                        "bulk-tag-\(index)",
                        "Bulk \(index)",
                        Date(),
                    ])
            }

            let resolution = try self.store.desiredPendingIntents(db)
            let bulkIntents = resolution.intents.filter {
                $0.type == .tag && $0.entityId.hasPrefix("bulk-tag-")
            }
            XCTAssertFalse(resolution.anomalyDetected)
            XCTAssertEqual(bulkIntents.count, count)
            XCTAssertTrue(bulkIntents.allSatisfy {
                $0.operation == .save
            })
        }
    }

    func testRuntimeCatalogMatchesSyncEntityTypes() {
        XCTAssertEqual(
            Set(SyncLocalEntityCatalog.current.map(\.entityType)),
            Set(SyncEntityType.allCases.map(\.rawValue))
        )
    }

    func testBatchAnomalyDefersReconciliationWithoutConstructingEngine() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)

        let engineBefore = await library.hasEngineForTest
        XCTAssertFalse(engineBefore)
        await library.noteBatchAnomalyForTest()

        let isDeferred = await library.hasDeferredPendingReconciliationForTest
        let engineAfter = await library.hasEngineForTest
        XCTAssertTrue(isDeferred)
        XCTAssertFalse(engineAfter)
    }

    func testBatchAdapterReturnsExactOriginalLibraryZoneChange() {
        let identity = PendingSyncIdentity(
            type: .tag,
            entityId: "same-name",
            operation: .save
        )
        let libraryID = CKRecord.ID(
            recordName: "tag:same-name",
            zoneID: SyncConstants.libraryZoneID
        )
        let foreignID = CKRecord.ID(
            recordName: "tag:same-name",
            zoneID: CKRecordZone.ID(
                zoneName: "ForeignZone",
                ownerName: CKCurrentUserDefaultName
            )
        )
        let libraryChange = CKSyncEngine.PendingRecordZoneChange
            .saveRecord(libraryID)
        let foreignChange = CKSyncEngine.PendingRecordZoneChange
            .saveRecord(foreignID)

        let mapped = SyncedLibrary.originalPendingChanges(
            selected: [identity],
            scopedPending: [foreignChange, libraryChange]
        )
        XCTAssertEqual(mapped.count, 1)
        guard case .saveRecord(let returnedID) = mapped[0] else {
            return XCTFail("expected original save")
        }
        XCTAssertEqual(returnedID, libraryID)

        XCTAssertTrue(SyncedLibrary.originalPendingChanges(
            selected: [identity],
            scopedPending: [foreignChange]
        ).isEmpty)
    }

    func testPendingAdapterLogsUnrecognizedChangeOnceAndPreservesIt() async {
        let database = try! AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let foreignChange = CKSyncEngine.PendingRecordZoneChange.saveRecord(
            CKRecord.ID(
                recordName: "tag:foreign",
                zoneID: CKRecordZone.ID(
                    zoneName: "ForeignZone",
                    ownerName: CKCurrentUserDefaultName
                )
            )
        )

        let first = await library.recognizedPendingIdentitiesForTest(
            from: [foreignChange]
        )
        let second = await library.recognizedPendingIdentitiesForTest(
            from: [foreignChange]
        )
        let loggedCount = await library
            .loggedUnrecognizedPendingChangeCountForTest
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(loggedCount, 1)
    }
}
#endif
