#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class ActivityRecordTests: XCTestCase {
    private func day(_ value: String = "2026-07-15") throws -> LocalDay {
        try XCTUnwrap(LocalDay(rawValue: value))
    }

    func testReadingActivityRoundTripsEveryField() throws {
        let activity = ReadingActivity(
            installationId: "mac-a",
            referenceId: 42,
            localDay: try day(),
            epochRevision: 3,
            generation: "generation-a",
            activeSeconds: 901,
            lastActiveAt: Date(timeIntervalSince1970: 100),
            dateModified: Date(timeIntervalSince1970: 120)
        )
        let recordName = SyncEntityType.readingActivity.qualifiedRecordName(entityId: activity.entityId)
        let record = ReadingActivity.makeRecord(recordName: recordName, activity: activity)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.readingActivity)
        XCTAssertEqual(ReadingActivity(record: record), activity)
    }

    func testAssistantActivityPreservesUnknownProvider() throws {
        let activity = AssistantActivity(
            id: "rubien-conversation",
            provider: "future-provider",
            epochRevision: 2,
            generation: "generation-b",
            startedAt: Date(timeIntervalSince1970: 200),
            localDay: try day(),
            dateModified: Date(timeIntervalSince1970: 210)
        )
        let recordName = SyncEntityType.assistantActivity.qualifiedRecordName(entityId: activity.id)
        let record = AssistantActivity.makeRecord(recordName: recordName, activity: activity)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.assistantActivity)
        XCTAssertEqual(AssistantActivity(record: record, id: activity.id), activity)
    }

    func testEpochRoundTripAndForwardInvalidKindFailsSafely() {
        let epoch = ActivityEpoch(
            kind: .reading,
            revision: 4,
            generation: "generation-c",
            resetAt: Date(timeIntervalSince1970: 300),
            dateModified: Date(timeIntervalSince1970: 301)
        )
        let record = ActivityEpoch.makeRecord(
            recordName: SyncEntityType.activityEpoch.qualifiedRecordName(entityId: "reading"),
            epoch: epoch
        )
        XCTAssertEqual(ActivityEpoch(record: record), epoch)

        record[ActivityEpoch.RecordField.kind] = "future-kind"
        XCTAssertNil(ActivityEpoch(record: record))
    }

    func testFactArrivingBeforeEpochIsQuarantinedThenReplayed() throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(title: "Remote activity")
        try database.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let generation = "remote-generation"
        let activity = ReadingActivity(
            installationId: "remote-mac",
            referenceId: referenceId,
            localDay: try day(),
            epochRevision: 1,
            generation: generation,
            activeSeconds: 120,
            lastActiveAt: Date(timeIntervalSince1970: 400),
            dateModified: Date(timeIntervalSince1970: 401)
        )
        let entityId = activity.entityId
        let activityRecord = ReadingActivity.makeRecord(
            recordName: SyncEntityType.readingActivity.qualifiedRecordName(entityId: entityId),
            activity: activity
        )

        try database.dbWriter.write { db in
            let applied = try SyncEntityType.readingActivity.applyRemoteRecord(
                activityRecord,
                entityId: entityId,
                db: db
            )
            XCTAssertTrue(applied)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM readingActivity"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activityQuarantine"), 1)
        }

        let epoch = ActivityEpoch(
            kind: .reading,
            revision: 1,
            generation: generation,
            resetAt: Date(timeIntervalSince1970: 350),
            dateModified: Date(timeIntervalSince1970: 350)
        )
        let epochRecord = ActivityEpoch.makeRecord(
            recordName: SyncEntityType.activityEpoch.qualifiedRecordName(entityId: "reading"),
            epoch: epoch
        )
        try database.dbWriter.write { db in
            let applied = try SyncEntityType.activityEpoch.applyRemoteRecord(
                epochRecord,
                entityId: "reading",
                db: db
            )
            XCTAssertTrue(applied)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT activeSeconds FROM readingActivity"), 120)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activityQuarantine"), 0)
        }
    }

    func testReadingCounterConflictMergesByMaximum() throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(title: "Merge activity")
        try database.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let context = try database.activityCaptureContext(for: .reading)
        let local = try database.saveReadingActivityCounter(
            installationId: "same-installation",
            referenceId: referenceId,
            localDay: try day(),
            cumulativeActiveSeconds: 180,
            lastActiveAt: Date(timeIntervalSince1970: 500),
            context: context
        )
        guard case .saved(let savedLocal) = local else { return XCTFail("local write failed") }

        var remote = savedLocal
        remote.activeSeconds = 120
        remote.lastActiveAt = Date(timeIntervalSince1970: 550)
        remote.dateModified = Date(timeIntervalSince1970: 560)
        let record = ReadingActivity.makeRecord(
            recordName: SyncEntityType.readingActivity.qualifiedRecordName(entityId: remote.entityId),
            activity: remote
        )
        try database.dbWriter.write { db in
            XCTAssertFalse(try SyncEntityType.readingActivity.applyRemoteRecord(
                record,
                entityId: remote.entityId,
                db: db
            ))
            let merged = try XCTUnwrap(ReadingActivity.fetchOne(
                db,
                sql: "SELECT * FROM readingActivity"
            ))
            XCTAssertEqual(merged.activeSeconds, 180)
            XCTAssertEqual(merged.lastActiveAt, remote.lastActiveAt)
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: """
                    SELECT isDirty FROM syncState
                    WHERE entityType = 'readingActivity' AND entityId = ?
                    """,
                arguments: [remote.entityId]
            ), 1, "the larger local grow-only value must be repushed")
            XCTAssertNotNil(try Data.fetchOne(
                db,
                sql: """
                    SELECT systemFields FROM syncState
                    WHERE entityType = 'readingActivity' AND entityId = ?
                    """,
                arguments: [remote.entityId]
            ), "the retry must adopt the server record's current change tag")
        }
    }

    func testConcurrentClearRebasesIntentFactsAndSyncIdentity() throws {
        let database = try AppDatabase(DatabaseQueue())
        let stateStore = SyncStateStore()
        var reference = Reference(title: "Post-clear activity")
        try database.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)

        let resetAt = Date(timeIntervalSince1970: 700)
        let losing = try database.clearActivity(kind: .reading, now: resetAt)
        let losingContext = try database.activityCaptureContext(for: .reading)
        guard case .saved(let losingFact) = try database.saveReadingActivityCounter(
            installationId: "mac-a",
            referenceId: referenceId,
            localDay: try day(),
            cumulativeActiveSeconds: 120,
            lastActiveAt: Date(timeIntervalSince1970: 720),
            context: losingContext
        ) else { return XCTFail("post-clear write failed") }

        let incoming = ActivityEpoch(
            kind: .reading,
            revision: losing.revision,
            generation: "competing-generation",
            resetAt: Date(timeIntervalSince1970: 710),
            dateModified: Date(timeIntervalSince1970: 711)
        )
        let incomingRecord = ActivityEpoch.makeRecord(
            recordName: SyncEntityType.activityEpoch.qualifiedRecordName(entityId: "reading"),
            epoch: incoming
        )

        try database.dbWriter.write { db in
            try stateStore.setApplyingRemote(db)
            XCTAssertFalse(try SyncEntityType.activityEpoch.applyRemoteRecord(
                incomingRecord,
                entityId: "reading",
                db: db,
                stateStore: stateStore
            ))
            try stateStore.clearApplyingRemote(db)

            let pending = try XCTUnwrap(ActivityPendingClear.fetchOne(db, key: "reading"))
            let rebased = try XCTUnwrap(ActivityEpoch.fetchOne(db, key: "reading"))
            XCTAssertEqual(pending.intentId, losingContext.pendingClearIntentId)
            XCTAssertEqual(pending.resetAt, resetAt)
            XCTAssertEqual(rebased.resetAt, resetAt)
            XCTAssertEqual(rebased.revision, losing.revision + 1)
            XCTAssertEqual(rebased.generation, pending.generation)
            XCTAssertNotEqual(rebased.generation, losing.generation)
            XCTAssertNotEqual(rebased.generation, incoming.generation)

            let fact = try XCTUnwrap(ReadingActivity.fetchOne(
                db,
                sql: "SELECT * FROM readingActivity"
            ))
            XCTAssertEqual(fact.activeSeconds, losingFact.activeSeconds)
            XCTAssertEqual(fact.epochRevision, rebased.revision)
            XCTAssertEqual(fact.generation, rebased.generation)
            XCTAssertNil(try Row.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM syncState
                    WHERE entityType = 'readingActivity' AND entityId = ?
                    """,
                arguments: [losingFact.entityId]
            ))
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: """
                    SELECT isDirty FROM syncState
                    WHERE entityType = 'readingActivity' AND entityId = ?
                    """,
                arguments: [fact.entityId]
            ), 1)
            XCTAssertFalse(try SyncEntityType.readingActivity.activityFactIsPushEligible(
                db: db,
                entityId: fact.entityId
            ))
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: """
                    SELECT isDirty FROM syncState
                    WHERE entityType = 'activityEpoch' AND entityId = 'reading'
                    """
            ), 1)
            XCTAssertNotNil(try Data.fetchOne(
                db,
                sql: """
                    SELECT systemFields FROM syncState
                    WHERE entityType = 'activityEpoch' AND entityId = 'reading'
                    """
            ))
        }
    }
}
#endif
