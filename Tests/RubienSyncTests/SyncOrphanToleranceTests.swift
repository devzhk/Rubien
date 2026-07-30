#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Regression coverage for the cross-batch initial-pull wedge.
///
/// `CKSyncEngine` delivers a zone's records across multiple fetch batches with
/// no cross-batch FK ordering, so a child (e.g. a `referenceTag` pivot) can
/// arrive in a batch *before* its parent `reference`/`tag`. Modification
/// transactions tolerate those transient orphans even when their fetched event
/// also carries deletions. The deletion transaction still keeps
/// `ON DELETE CASCADE` active.
final class SyncOrphanToleranceTests: XCTestCase {

    private var db: AppDatabase!
    private var engineStateURLs: [URL] = []
    private var pdfURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        for url in engineStateURLs { try? FileManager.default.removeItem(at: url) }
        for url in pdfURLs { try? FileManager.default.removeItem(at: url) }
        engineStateURLs = []
        pdfURLs = []
        db = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeLibrary() -> SyncedLibrary {
        let stateFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        engineStateURLs.append(stateFileURL)
        return SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFileURL,
            pdfAssetSyncEnabledProvider: { true }
        )
    }

    private func makeReferenceRecord(id: Int64, title: String) -> CKRecord {
        let name = SyncEntityType.reference.qualifiedRecordName(entityId: String(id))
        return Reference.makeRecord(recordName: name, reference: Reference(title: title))
    }

    private func makeTagRecord(id: Int64, name: String) -> CKRecord {
        let recordName = SyncEntityType.tag.qualifiedRecordName(entityId: String(id))
        return Tag.makeRecord(recordName: recordName, tag: Tag(name: name))
    }

    /// Build a `referenceTag` pivot CKRecord with the QUALIFIED recordName the
    /// apply path expects (`"referenceTag:<refId>/<tagId>"`) and the CKRecord
    /// type `CDReferenceTag`. The typed `ReferenceTag.makeRecord` emits the
    /// *unqualified* `"<refId>/<tagId>"` name (no `<type>:` prefix), so we
    /// assemble the qualified name here and reuse `populate` for field fidelity
    /// — the FKs land as `Int64` (a plain `Int` would decode to nil in
    /// `ReferenceTag(record:)` and the pivot would be silently skipped).
    private func makeReferenceTagRecord(referenceId: Int64, tagId: Int64) -> CKRecord {
        let entityId = ReferenceTag.recordName(referenceId: referenceId, tagId: tagId)
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.referenceTag,
            recordName: SyncEntityType.referenceTag.qualifiedRecordName(entityId: entityId))
        ReferenceTag(referenceId: referenceId, tagId: tagId).populate(record: record)
        return record
    }

    private func pivotCount() async throws -> Int {
        try await db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM referenceTag") ?? -1 }
    }

    // MARK: - Tests

    func testOrphanChildCommitsInDeleteFreeBatch() async throws {
        let library = makeLibrary()

        // A referenceTag child arrives alone — its parents (reference 1, tag 2)
        // are in a later batch. Pre-fix this rolled the batch back to 0.
        let child = makeReferenceTagRecord(referenceId: 1, tagId: 2)
        let childApplied = await library.applyFetchedRecordsForTest(
            modifications: [child],
            deletions: []
        )
        XCTAssertTrue(childApplied)
        let afterOrphan = try await pivotCount()
        XCTAssertEqual(afterOrphan, 1,
                       "orphan pivot must commit in a delete-free batch (pre-fix: rolled back to 0)")

        // Parents arrive in a later batch → the library is now FK-consistent.
        let parentsApplied = await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceRecord(id: 1, title: "R1"),
                            makeTagRecord(id: 2, name: "T2")],
            deletions: [])
        XCTAssertTrue(parentsApplied)
        let violations = try db.dbWriter.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }
        XCTAssertTrue(violations.isEmpty, "once the parents arrive the orphan resolves — no FK violations")

        // The FK-off apply must have restored `foreign_keys = ON` on the
        // writer: a normal write inserting an orphan pivot must now be rejected.
        do {
            try await db.dbWriter.write { db in
                try db.execute(
                    sql: "INSERT INTO referenceTag(referenceId, tagId, dateModified) VALUES (777, 888, ?)",
                    arguments: [Date()])
            }
            XCTFail("expected an FK violation — foreign_keys was not restored to ON after the FK-off apply")
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            // expected: FK enforcement is back on for ordinary local writes.
            // A non-FK error would propagate and fail the test rather than pass green.
        }
    }

    func testDeleteStillCascades() async throws {
        let library = makeLibrary()

        // Apply parents + pivot together (well-ordered within the batch).
        let seeded = await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceRecord(id: 1, title: "R1"),
                            makeTagRecord(id: 2, name: "T2"),
                            makeReferenceTagRecord(referenceId: 1, tagId: 2)],
            deletions: [])
        XCTAssertTrue(seeded)
        let before = try await pivotCount()
        XCTAssertEqual(before, 1)

        // A batch carrying a deletion keeps FK ON → deleting the parent
        // reference cascades to the pivot via ON DELETE CASCADE.
        let deletion = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(entityId: "1"),
                zoneID: SyncConstants.libraryZoneID),
            recordType: SyncConstants.RecordType.reference)
        let deleted = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [deletion]
        )
        XCTAssertTrue(deleted)

        let after = try await pivotCount()
        XCTAssertEqual(after, 0,
                       "deleting the parent reference must cascade-delete the pivot (FK delete path unchanged)")
    }

    /// A full-zone replay can commit an orphan child in one delete-free batch,
    /// then receive a later batch containing unrelated deletions before the
    /// orphan's parents arrive. The later batch must not roll back merely
    /// because `foreign_key_check` still sees the pre-existing orphan.
    ///
    /// This is the exact sequence observed on a 0.7.1 receiving device:
    /// batch 1 tolerated transient orphans, then a deletion-bearing batch
    /// rolled back and CKSyncEngine advanced past it.
    func testDeletionBatchCommitsWhileEarlierBatchHasTransientOrphan() async throws {
        let library = makeLibrary()

        var doomed = Reference(title: "Doomed")
        try db.saveReference(&doomed)
        let doomedID = try XCTUnwrap(doomed.id)

        let orphan = makeReferenceTagRecord(referenceId: 1001, tagId: 1002)
        let orphanApplied = await library.applyFetchedRecordsForTest(
            modifications: [orphan],
            deletions: []
        )
        XCTAssertTrue(orphanApplied)
        let orphanCount = try await pivotCount()
        XCTAssertEqual(orphanCount, 1)

        let deletion = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(
                    entityId: String(doomedID)
                ),
                zoneID: SyncConstants.libraryZoneID
            ),
            recordType: SyncConstants.RecordType.reference
        )
        let deletionApplied = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [deletion]
        )
        XCTAssertTrue(deletionApplied)

        let doomedCount = try await db.dbWriter.read {
            try Int.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM reference WHERE id = ?",
                arguments: [doomedID]
            ) ?? -1
        }
        XCTAssertEqual(
            doomedCount,
            0,
            "an unrelated deletion must commit despite transient FK violations from an earlier batch"
        )
        let orphanCountAfterDeletion = try await pivotCount()
        XCTAssertEqual(
            orphanCountAfterDeletion,
            1,
            "the deletion batch must preserve the pre-existing transient orphan"
        )
    }

    /// CKSyncEngine may put an orphan-producing modification and an unrelated
    /// deletion in the same fetched event. The modification must commit for a
    /// later parent to resolve, while the deletion must still cascade its
    /// already-materialized children.
    func testMixedBatchCascadesDeletionAndCommitsNewTransientOrphan() async throws {
        let library = makeLibrary()

        let seeded = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceRecord(id: 1, title: "Doomed"),
                makeTagRecord(id: 2, name: "Existing"),
                makeReferenceTagRecord(referenceId: 1, tagId: 2)
            ],
            deletions: []
        )
        XCTAssertTrue(seeded)
        let seededPivotCount = try await pivotCount()
        XCTAssertEqual(seededPivotCount, 1)

        let deletion = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(entityId: "1"),
                zoneID: SyncConstants.libraryZoneID
            ),
            recordType: SyncConstants.RecordType.reference
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceTagRecord(referenceId: 2001, tagId: 2002)
            ],
            deletions: [deletion]
        )

        XCTAssertTrue(applied)
        let doomedCount = try await db.dbWriter.read {
            try Int.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM reference WHERE id = ?",
                arguments: [1]
            ) ?? -1
        }
        XCTAssertEqual(
            doomedCount,
            0,
            "the deletion phase must commit with FK enforcement enabled"
        )
        let pivotCountAfterMixedBatch = try await pivotCount()
        XCTAssertEqual(
            pivotCountAfterMixedBatch,
            1,
            "the old pivot must cascade while the new cross-batch orphan remains"
        )

        let violations = try db.dbWriter.read {
            try Row.fetchAll($0, sql: "PRAGMA foreign_key_check")
        }
        XCTAssertEqual(
            violations.count,
            2,
            "the one transient pivot is missing both its reference and tag parents"
        )
    }

    /// Preserve the pre-split event ordering: modifications apply before
    /// deletions, so a parent deletion in the same event wins and cascades a
    /// newly fetched child instead of leaving it orphaned.
    func testMixedBatchDeletionWinsOverNewChildModification() async throws {
        let library = makeLibrary()

        let seeded = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceRecord(id: 1, title: "Doomed"),
                makeTagRecord(id: 2, name: "Existing")
            ],
            deletions: []
        )
        XCTAssertTrue(seeded)

        let deletion = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(entityId: "1"),
                zoneID: SyncConstants.libraryZoneID
            ),
            recordType: SyncConstants.RecordType.reference
        )
        let applied = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceTagRecord(referenceId: 1, tagId: 2)
            ],
            deletions: [deletion]
        )

        XCTAssertTrue(applied)
        let pivots = try await pivotCount()
        XCTAssertEqual(
            pivots,
            0,
            "the deletion phase must cascade the child committed by the modification phase"
        )
    }

    /// The receiving-device failure captured a stale CDReferenceTag and
    /// CDReferencePDF for the same deleted Reference (1548). Once the zone
    /// fetch is complete, both children are terminal: remove the local rows,
    /// unlink the materialized PDF after commit, and queue server tombstones
    /// so the next device never downloads them.
    func testSuccessfulZoneFetchReconcilesStaleTagAndPDFChildren() async throws {
        let library = makeLibrary()
        let filename = "\(UUID().uuidString)-stale.pdf"
        let pdfURL = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        pdfURLs.append(pdfURL)
        try FileManager.default.createDirectory(
            at: AppDatabase.pdfStorageURL,
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: pdfURL)

        try await db.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                try db.execute(
                    sql: """
                        INSERT INTO tag(id, name, color, dateModified)
                        VALUES(156, 'Stale tag', '#007AFF', ?)
                        """,
                    arguments: [Date()]
                )
                try db.execute(
                    sql: """
                        INSERT INTO referenceTag(referenceId, tagId, dateModified)
                        VALUES(1548, 156, ?)
                        """,
                    arguments: [Date()]
                )
                try db.execute(
                    sql: """
                        INSERT INTO pdfCache(
                            referenceId, localFilename, contentHash,
                            assetVersion, materializedAt, lastOpenedAt
                        ) VALUES(1548, ?, 'hash', 1, ?, ?)
                        """,
                    arguments: [filename, Date(), Date()]
                )
                try db.execute(
                    sql: """
                        UPDATE syncState
                        SET isDirty = 0, pushInFlight = 0
                        WHERE entityType = 'referenceTag'
                          AND entityId = '1548/156';
                        INSERT INTO syncState(
                            entityType, entityId, isDirty, pushInFlight
                        ) VALUES('referencePDF', '1548', 0, 0);
                        """
                )
                try db.execute(
                    sql: """
                        INSERT INTO syncSession(key, value)
                        VALUES('fullHistoryReplayPending', '1')
                        """
                )
                return .commit
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let violationCountBefore = try await db.dbWriter.read {
            try Int.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
            )
        }
        XCTAssertEqual(violationCountBefore, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))

        let reconciled = await library.reconcileFetchedZoneForTest()
        XCTAssertTrue(reconciled)

        let state = try db.dbWriter.read { db in
            return (
                pivotCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM referenceTag"
                ) ?? -1,
                pdfCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM pdfCache"
                ) ?? -1,
                violations: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
                ) ?? -1,
                tombstones: try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entityType, entityId, confirmedByServer
                        FROM tombstone
                        WHERE (entityType = 'referenceTag' AND entityId = '1548/156')
                           OR (entityType = 'referencePDF' AND entityId = '1548')
                        ORDER BY entityType
                        """
                ),
                replayMarkerCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM syncSession
                        WHERE key = 'fullHistoryReplayPending'
                        """
                ) ?? -1
            )
        }
        XCTAssertEqual(state.pivotCount, 0)
        XCTAssertEqual(state.pdfCount, 0)
        XCTAssertEqual(state.violations, 0)
        XCTAssertEqual(state.tombstones.count, 2)
        XCTAssertEqual(
            state.replayMarkerCount,
            1,
            "terminal cleanup must not clear the marker before the fetch cursor is durable"
        )
        XCTAssertTrue(state.tombstones.allSatisfy {
            let confirmed: Int = $0["confirmedByServer"]
            return confirmed == 0
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdfURL.path))

        let finalized = await library.finalizeFullHistoryReplayForTest()
        XCTAssertTrue(finalized)
        let markerCountAfterDurableState = try await db.dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM syncSession
                    WHERE key = 'fullHistoryReplayPending'
                    """
            ) ?? -1
        }
        XCTAssertEqual(markerCountAfterDurableState, 0)
    }

    /// An incremental delta is not a complete CloudKit snapshot. A parent
    /// missing locally may predate an old, incorrectly advanced cursor and
    /// still exist on the server, so never infer that its child is terminal.
    func testIncrementalFetchPreservesOrphanWithoutQueuingServerDeletion() async throws {
        let library = makeLibrary()

        try await db.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                try db.execute(
                    sql: """
                        INSERT INTO tag(id, name, color, dateModified)
                        VALUES(156, 'Possibly valid tag', '#007AFF', ?)
                        """,
                    arguments: [Date()]
                )
                try db.execute(
                    sql: """
                        INSERT INTO referenceTag(referenceId, tagId, dateModified)
                        VALUES(1548, 156, ?)
                        """,
                    arguments: [Date()]
                )
                return .commit
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let reconciled = await library.reconcileFetchedZoneForTest(
            includeTerminalOrphans: false
        )
        XCTAssertTrue(reconciled)

        let state = try await db.dbWriter.read { db in
            return (
                pivotCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM referenceTag
                        WHERE referenceId = 1548 AND tagId = 156
                        """
                ) ?? -1,
                tombstoneCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM tombstone
                        WHERE entityType = 'referenceTag'
                          AND entityId = '1548/156'
                        """
                ) ?? -1
            )
        }
        XCTAssertEqual(state.pivotCount, 1)
        XCTAssertEqual(state.tombstoneCount, 0)
    }

    func testIncrementalFetchPreservesQuarantinedActivityWithMissingParent() async throws {
        let library = makeLibrary()
        let activity = ReadingActivity(
            installationId: "remote-mac",
            referenceId: 1548,
            localDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-15")),
            epochRevision: 0,
            generation: "reading-v7-initial",
            activeSeconds: 120,
            lastActiveAt: Date(timeIntervalSince1970: 400),
            dateModified: Date(timeIntervalSince1970: 401)
        )
        let entityId = activity.entityId
        let record = ReadingActivity.makeRecord(
            recordName: SyncEntityType.readingActivity.qualifiedRecordName(
                entityId: entityId
            ),
            activity: activity
        )

        try await db.dbWriter.write { db in
            let applied = try SyncEntityType.readingActivity.applyRemoteRecord(
                record,
                entityId: entityId,
                db: db
            )
            XCTAssertTrue(applied)
        }

        let incrementallyReconciled = await library.reconcileFetchedZoneForTest(
            includeTerminalOrphans: false
        )
        XCTAssertTrue(incrementallyReconciled)

        let incrementalState = try await db.dbWriter.read { db in
            return (
                quarantineCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM activityQuarantine
                        WHERE recordName = ?
                        """,
                    arguments: [record.recordID.recordName]
                ) ?? -1,
                tombstoneCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM tombstone
                        WHERE entityType = 'readingActivity'
                          AND entityId = ?
                        """,
                    arguments: [entityId]
                ) ?? -1
            )
        }
        XCTAssertEqual(incrementalState.quarantineCount, 1)
        XCTAssertEqual(incrementalState.tombstoneCount, 0)

        let fullyReconciled = await library.reconcileFetchedZoneForTest()
        XCTAssertTrue(fullyReconciled)

        let fullReplayState = try await db.dbWriter.read { db in
            return (
                quarantineCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM activityQuarantine
                        WHERE recordName = ?
                        """,
                    arguments: [record.recordID.recordName]
                ) ?? -1,
                unconfirmedTombstoneCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM tombstone
                        WHERE entityType = 'readingActivity'
                          AND entityId = ?
                          AND confirmedByServer = 0
                        """,
                    arguments: [entityId]
                ) ?? -1
            )
        }
        XCTAssertEqual(fullReplayState.quarantineCount, 0)
        XCTAssertEqual(fullReplayState.unconfirmedTombstoneCount, 1)
    }

    func testPostFetchReconciliationPreservesMetadataIntakeByClearingLink() async throws {
        let library = makeLibrary()

        try await db.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                try db.execute(
                    sql: """
                        INSERT INTO metadataIntake(
                            id, sourceKind, verificationStatus, title,
                            linkedReferenceId, createdAt, updatedAt
                        ) VALUES(90, 'doi', 'accepted', 'Keep me', 999, ?, ?)
                        """,
                    arguments: [Date(), Date()]
                )
                return .commit
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let reconciled = await library.reconcileFetchedZoneForTest()
        XCTAssertTrue(reconciled)

        let repaired = try await db.dbWriter.read { db in
            return (
                linkedReferenceID: try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT linkedReferenceId
                        FROM metadataIntake
                        WHERE id = 90
                        """
                ),
                dirty: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT isDirty FROM syncState
                        WHERE entityType = 'metadataIntake'
                          AND entityId = '90'
                        """
                ),
                violations: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
                )
            )
        }
        XCTAssertNil(repaired.linkedReferenceID)
        XCTAssertEqual(repaired.dirty, 1)
        XCTAssertEqual(repaired.violations, 0)
    }

    /// If a future schema adds an FK-bearing table without a reconciliation
    /// policy, fail the fetch and roll back known cleanup. In particular, do
    /// not unlink a PDF whose DB deletion did not commit.
    func testUnknownOrphanRollsBackKnownCleanupAndKeepsPDFFile() async throws {
        let library = makeLibrary()
        let filename = "\(UUID().uuidString)-rollback.pdf"
        let pdfURL = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        pdfURLs.append(pdfURL)
        try FileManager.default.createDirectory(
            at: AppDatabase.pdfStorageURL,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: pdfURL)

        try await db.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                try db.execute(sql: """
                    CREATE TABLE futureChild(
                        id INTEGER PRIMARY KEY,
                        referenceId INTEGER NOT NULL
                            REFERENCES reference(id) ON DELETE CASCADE
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO futureChild(id, referenceId) VALUES(1, 999)"
                )
                try db.execute(
                    sql: """
                        INSERT INTO pdfCache(
                            referenceId, localFilename, contentHash,
                            assetVersion, materializedAt, lastOpenedAt
                        ) VALUES(1548, ?, 'hash', 1, ?, ?)
                        """,
                    arguments: [filename, Date(), Date()]
                )
                try db.execute(
                    sql: """
                        INSERT INTO syncSession(key, value)
                        VALUES('fullHistoryReplayPending', '1')
                        """
                )
                return .commit
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let reconciled = await library.reconcileFetchedZoneForTest()
        XCTAssertFalse(reconciled)

        let rolledBackState = try await db.dbWriter.read { db in
            return (
                pdfCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM pdfCache
                        WHERE referenceId = 1548
                        """
                ) ?? -1,
                replayMarkerCount: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM syncSession
                        WHERE key = 'fullHistoryReplayPending'
                        """
                ) ?? -1
            )
        }
        XCTAssertEqual(rolledBackState.pdfCount, 1)
        XCTAssertEqual(rolledBackState.replayMarkerCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
    }
}
#endif
