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
        let referenceSyncId = "42"
        let syncId = "generation-a/mac-a/\(referenceSyncId)/2026-07-15"
        let activity = ReadingActivity(
            syncId: syncId,
            installationId: "mac-a",
            referenceId: 42,
            referenceSyncId: referenceSyncId,
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
        let syncId = "\(generation)/remote-mac/\(reference.syncId)/2026-07-15"
        let activity = ReadingActivity(
            syncId: syncId,
            installationId: "remote-mac",
            referenceId: referenceId,
            referenceSyncId: reference.syncId,
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

    func testV13MigrationBackfillsHistoricalQuarantineAndReplaysIt() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV12DatabaseForTesting(on: queue)

        let referenceId: Int64 = 42
        let activity = ReadingActivity(
            installationId: "remote-mac",
            referenceId: referenceId,
            localDay: try day(),
            epochRevision: 0,
            generation: "reading-v7-initial",
            activeSeconds: 120,
            lastActiveAt: Date(timeIntervalSince1970: 400),
            dateModified: Date(timeIntervalSince1970: 401)
        )
        let recordName = SyncEntityType.readingActivity.qualifiedRecordName(
            entityId: activity.entityId
        )
        let recordData = try JSONEncoder().encode(activity)

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reference(id, title, dateAdded, dateModified)
                    VALUES(?, 'Late parent', ?, ?)
                    """,
                arguments: [referenceId, Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO activityQuarantine (
                        recordName, entityType, reason, epochRevision,
                        generation, referenceId, recordData, receivedAt
                    ) VALUES (?, 'readingActivity', 'reference', 0, ?, ?, ?, ?)
                    """,
                arguments: [
                    recordName,
                    activity.generation,
                    referenceId,
                    recordData,
                    Date(timeIntervalSince1970: 402),
                ]
            )
        }

        let database = try AppDatabase(queue)
        try database.dbWriter.write { db in
            let quarantinedReferenceSyncId = try String.fetchOne(
                db,
                sql: "SELECT referenceSyncId FROM activityQuarantine"
            )
            let referenceSyncId = try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT syncId FROM reference WHERE id = ?",
                arguments: [referenceId]
            ))
            XCTAssertEqual(quarantinedReferenceSyncId, referenceSyncId)
            try SyncEntityType.replayQuarantinedActivity(
                referenceSyncIds: [referenceSyncId],
                db: db
            )

            let activeSeconds = try Int.fetchOne(
                db,
                sql: "SELECT activeSeconds FROM readingActivity"
            )
            XCTAssertEqual(activeSeconds, 120)
            let quarantineCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM activityQuarantine"
            )
            XCTAssertEqual(quarantineCount, 0)
            XCTAssertTrue(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations"
                ).contains("v13")
            )
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

    func testActivityDeletionRequeuesPreviouslyConfirmedTombstone() throws {
        let database = try AppDatabase(DatabaseQueue())
        let stateStore = SyncStateStore()
        let entityId = "generation/mac/42/2026-07-15"
        let recordName = SyncEntityType.readingActivity.qualifiedRecordName(
            entityId: entityId
        )

        try database.dbWriter.write { db in
            try stateStore.upsertTombstone(
                db,
                entityType: .readingActivity,
                entityId: entityId,
                confirmedByServer: true
            )

            try SyncEntityType.queueActivityDeletion(
                type: .readingActivity,
                entityId: entityId,
                recordName: recordName,
                stateStore: stateStore,
                db: db
            )

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT confirmedByServer FROM tombstone
                        WHERE entityType = 'readingActivity'
                          AND entityId = ?
                        """,
                    arguments: [entityId]
                ),
                0
            )
            XCTAssertTrue(
                try stateStore.tombstones(db).contains {
                    $0.0 == .readingActivity && $0.1 == entityId
                }
            )
        }
    }

    func testLateReadingActivityCanonicalizesAliasedReferenceIdentity() async throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(syncId: "reference-winner", title: "Paper")
        try database.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let referenceSyncId = reference.syncId
        let context = try database.activityCaptureContext(for: .reading)
        let losingReference = "reference-loser"
        try await database.dbWriter.write { db in
            try SyncIdentityAliasStore.record(
                entityType: .reference,
                losingId: losingReference,
                winningId: referenceSyncId,
                db: db
            )
        }
        let localDay = try day("2026-08-14")
        let observedIdentity =
            "\(context.generation)/late-mac/\(losingReference)/\(localDay.rawValue)"
        let canonicalIdentity =
            "\(context.generation)/late-mac/\(referenceSyncId)/\(localDay.rawValue)"
        let incoming = ReadingActivity(
            syncId: observedIdentity,
            installationId: "late-mac",
            referenceId: 0,
            referenceSyncId: losingReference,
            localDay: localDay,
            epochRevision: context.revision,
            generation: context.generation,
            activeSeconds: 75,
            lastActiveAt: Date(timeIntervalSince1970: 1_000),
            dateModified: Date(timeIntervalSince1970: 1_001)
        )
        let record = ReadingActivity.makeRecord(
            recordName: "readingActivity:\(observedIdentity)",
            activity: incoming
        )
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let library = SyncedLibrary(
            appDatabase: database,
            stateFileURL: stateURL
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await database.dbWriter.read { db in
            let stored = try XCTUnwrap(ReadingActivity.fetchOne(
                db,
                sql: "SELECT * FROM readingActivity WHERE syncId = ?",
                arguments: [canonicalIdentity]
            ))
            XCTAssertEqual(stored.referenceId, referenceId)
            XCTAssertEqual(stored.referenceSyncId, referenceSyncId)
            XCTAssertEqual(stored.activeSeconds, 75)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState
                WHERE entityType = 'readingActivity' AND entityId = ?
                """, arguments: [canonicalIdentity]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isPushEligible FROM tombstone
                WHERE entityType = 'readingActivity' AND entityId = ?
                """, arguments: [observedIdentity]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM readingActivity WHERE syncId = ?
                """, arguments: [observedIdentity]), 0)
        }
    }
}
#endif
