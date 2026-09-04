#if os(macOS)
import XCTest
import CloudKit
import GRDB
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, iOS 17.0, *)
final class SyncFailureRecoveryTests: XCTestCase {
    private func error(_ code: CKError.Code) -> CKError {
        CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: code.rawValue
        ))
    }

    func testFailedSendRemainsVisibleUntilLaterSuccessfulCycle() async {
        let database = try! AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        var iterator = library.statusStream.makeAsyncIterator()
        let failure = error(.invalidArguments)

        await library.beginSendCycleForTest()
        await library.noteSendFailureForTest(failure)
        await library.finishSendCycleForTest()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual(first, .syncing)
        XCTAssertEqual(second, .error(failure))
        XCTAssertEqual(third, .error(failure))

        // A later fetch does not prove that the failed send recovered.
        await library.noteFetch(inFlight: true)
        await library.noteFetch(inFlight: false)
        let fourth = await iterator.next()
        let fifth = await iterator.next()
        XCTAssertEqual(fourth, .syncing)
        XCTAssertEqual(fifth, .error(failure))

        await library.beginSendCycleForTest()
        await library.finishSendCycleForTest()
        let sixth = await iterator.next()
        let seventh = await iterator.next()
        XCTAssertEqual(sixth, .syncing)
        XCTAssertEqual(seventh, .idle)
    }

    func testRepeatedInvalidArgumentsFailuresAreAggregatedWithScope() {
        let invalid = error(.invalidArguments)
        let network = error(.networkUnavailable)

        let summaries = SyncSendFailureSummarizer.summarize([
            .init(error: invalid, entityType: "tag"),
            .init(error: invalid, entityType: "reference"),
            .init(error: invalid, entityType: "tag"),
            .init(error: network, entityType: "referencePDF"),
        ])

        let invalidSummary = summaries.first {
            $0.error.code == .invalidArguments
        }
        XCTAssertEqual(invalidSummary?.count, 3)
        XCTAssertEqual(invalidSummary?.entityTypes, ["reference", "tag"])
        let networkSummary = summaries.first {
            $0.error.code == .networkUnavailable
        }
        XCTAssertEqual(networkSummary?.count, 1)
        XCTAssertEqual(networkSummary?.entityTypes, ["referencePDF"])
    }

    func testServerRecordChangedDoesNotResurrectLocallyDeletedSave() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let id = "save-then-delete"
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Local', '#fff', ?)
                """, arguments: [id, Date()])
            XCTAssertTrue(try SyncStateStore().markPushInFlight(
                db,
                entityType: .tag,
                entityId: id
            ))
            try db.execute(
                sql: "DELETE FROM tag WHERE syncId=?",
                arguments: [id]
            )
        }
        let server = Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: id),
            tag: Tag(syncId: id, name: "Server Version", color: "#007AFF")
        )

        let recovered = await library.mergeServerRecordChangedForTest(
            type: .tag,
            entityId: id,
            serverRecord: server
        )
        XCTAssertTrue(recovered)

        try await database.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tag WHERE syncId=?
                """, arguments: [id]), 0)
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]))
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType='tag' AND entityId=?
                  AND confirmedByServer=0 AND isPushEligible=1
                """, arguments: [id]), 1)
        }
    }

    func testServerRecordChangedMergeReportsRecoveryAndClearsDurableIntent() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let id = "resolved-server-conflict"
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Local Version', '#fff', ?)
                """, arguments: [id, Date()])
            XCTAssertTrue(try SyncStateStore().markPushInFlight(
                db,
                entityType: .tag,
                entityId: id
            ))
        }
        let server = Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: id),
            tag: Tag(syncId: id, name: "Server Version", color: "#007AFF")
        )

        let recovered = await library.mergeServerRecordChangedForTest(
            type: .tag,
            entityId: id,
            serverRecord: server
        )

        XCTAssertTrue(recovered)
        try await database.dbWriter.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT name FROM tag WHERE syncId=?
                """, arguments: [id]), "Server Version")
            let state = try Row.fetchOne(db, sql: """
                SELECT isDirty, pushInFlight, systemFields IS NOT NULL AS hasServerState
                FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id])
            XCTAssertEqual(state?["isDirty"] as Int?, 0)
            XCTAssertEqual(state?["pushInFlight"] as Int?, 0)
            XCTAssertEqual(state?["hasServerState"] as Int?, 1)
        }
    }

    func testUnknownPDFDeleteRemovesOnlyExactTypeTombstone() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let id = "shared-reference-id"
        try await database.dbWriter.write { db in
            let store = SyncStateStore()
            try store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: id
            )
            try store.upsertTombstone(
                db,
                entityType: .referencePDF,
                entityId: id
            )
        }

        await library.removeUnknownItemDeleteTombstoneForTest(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.referencePDF
                    .qualifiedRecordName(entityId: id)
            )
        )

        try await database.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType='reference' AND entityId=?
                """, arguments: [id]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType='referencePDF' AND entityId=?
                """, arguments: [id]), 0)
        }
    }

    func testUnknownItemSavePreparesFreshCreateAndForcesPendingRefresh() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let id = "stale-server-record"
        let store = SyncStateStore()
        let record = Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: id),
            tag: Tag(syncId: id, name: "Local", color: "#fff")
        )

        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Local', '#fff', ?)
                """, arguments: [id, Date()])
            try store.markPushed(
                db,
                entityType: .tag,
                entityId: id,
                record: record
            )
            try store.queueSave(db, entityType: .tag, entityId: id)
            XCTAssertTrue(try store.markPushInFlight(
                db,
                entityType: .tag,
                entityId: id
            ))
        }

        let visibleError = await library.recoverUnknownItemSaveFailure(
            type: .tag,
            entityId: id,
            error: error(.unknownItem)
        )
        XCTAssertNil(visibleError)

        try await database.dbWriter.read { db in
            let state = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT systemFields, isDirty, pushInFlight
                FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]))
            XCTAssertNil(state["systemFields"] as Data?)
            XCTAssertEqual(state["isDirty"] as Int?, 1)
            XCTAssertEqual(state["pushInFlight"] as Int?, 0)
        }
        let refreshes = await library.pendingIntentRefreshesForTest
        XCTAssertEqual(refreshes, [
            .init(type: .tag, entityId: id, operation: .save),
        ])
    }

    func testDeleteAcknowledgementFinalizesRematerializedLocalRow() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let id = "rematerialized-delete"
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Fetched Again', '#fff', ?)
                """, arguments: [id, Date()])
            try SyncStateStore().queueDelete(
                db,
                entityType: .tag,
                entityId: id
            )
        }

        try await library.finalizeDeleteOutcomeForTest(
            entityType: .tag,
            entityId: id,
            retainConfirmedTombstone: true
        )
        try await database.dbWriter.write { db in
            _ = try SyncStateStore().repairDurableIntent(db)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tag WHERE syncId=?
                """, arguments: [id]), 0)
            XCTAssertNil(try Row.fetchOne(db, sql: """
                SELECT 1 FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]))
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT confirmedByServer FROM tombstone
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]), 1)
        }
    }

    func testUnknownItemDeleteFinalizesRematerializedLocalRow() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let id = "already-absent-delete"
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Fetched Again', '#fff', ?)
                """, arguments: [id, Date()])
            try SyncStateStore().queueDelete(
                db,
                entityType: .tag,
                entityId: id
            )
        }

        await library.removeUnknownItemDeleteTombstoneForTest(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.tag
                    .qualifiedRecordName(entityId: id)
            )
        )

        try await database.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tag WHERE syncId=?
                """, arguments: [id]), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]), 0)
        }
    }

    func testDeleteAcknowledgementPreservesNewerLiveDirtyRecreation() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = SyncedLibrary(appDatabase: database)
        let id = "newer-recreation"
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES(?, 'Recreated', '#fff', ?)
                """, arguments: [id, Date()])
            try SyncStateStore().queueDelete(
                db,
                entityType: .tag,
                entityId: id
            )
            // Model an inconsistent retained tombstone beside the newer
            // dirty recreation; finalization must follow the same live+dirty
            // rule as the resolver and startup repair.
            try SyncStateStore().queueSave(
                db,
                entityType: .tag,
                entityId: id
            )
            try SyncStateStore().upsertTombstone(
                db,
                entityType: .tag,
                entityId: id
            )
        }

        try await library.finalizeDeleteOutcomeForTest(
            entityType: .tag,
            entityId: id,
            retainConfirmedTombstone: true
        )

        try await database.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tag WHERE syncId=?
                """, arguments: [id]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType='tag' AND entityId=?
                """, arguments: [id]), 0)
        }
    }
}
#endif
