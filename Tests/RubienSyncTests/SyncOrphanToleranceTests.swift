#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Regression coverage for cross-batch parent/child ordering during pull.
///
/// v13 never persists a child with device-local foreign keys guessed from the
/// wire. It archives the complete CKRecord in `syncOrphan`, retries the fixed
/// point after every fetched batch, and retires a still-unresolved record only
/// at a successful full-history boundary.
final class SyncOrphanToleranceTests: XCTestCase {

    private var db: AppDatabase!
    private var engineStateURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        for url in engineStateURLs { try? FileManager.default.removeItem(at: url) }
        engineStateURLs = []
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

    private func makeReferenceRecord(syncId: String, title: String) -> CKRecord {
        var reference = Reference(title: title)
        reference.syncId = syncId
        return Reference.makeRecord(
            recordName: SyncEntityType.reference.qualifiedRecordName(entityId: syncId),
            reference: reference
        )
    }

    private func makeTagRecord(syncId: String, name: String) -> CKRecord {
        let tag = Tag(syncId: syncId, name: name)
        return Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: syncId),
            tag: tag
        )
    }

    private func makeReferenceTagRecord(
        referenceSyncId: String,
        tagSyncId: String
    ) -> CKRecord {
        let entityId = "\(referenceSyncId)/\(tagSyncId)"
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.referenceTag,
            recordName: SyncEntityType.referenceTag.qualifiedRecordName(entityId: entityId)
        )
        ReferenceTag(
            syncId: entityId,
            referenceId: 0,
            tagId: 0,
            referenceSyncId: referenceSyncId,
            tagSyncId: tagSyncId
        ).populate(record: record)
        return record
    }

    private func makeDeletion(
        type: SyncEntityType,
        entityId: String
    ) -> SyncedLibrary.FetchedDeletionInput {
        SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: type.qualifiedRecordName(entityId: entityId),
                zoneID: SyncConstants.libraryZoneID
            ),
            recordType: type.recordType
        )
    }

    private func pivotCount() throws -> Int {
        try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM referenceTag") ?? -1
        }
    }

    private func orphanCount() throws -> Int {
        try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncOrphan") ?? -1
        }
    }

    // MARK: - Tests

    func testChildBeforeParentsIsQuarantinedThenReplayed() async throws {
        let library = makeLibrary()
        let child = makeReferenceTagRecord(
            referenceSyncId: "ref-one",
            tagSyncId: "tag-two"
        )

        let childApplied = await library.applyFetchedRecordsForTest(
            modifications: [child],
            deletions: []
        )
        XCTAssertTrue(childApplied)
        XCTAssertEqual(try pivotCount(), 0)
        XCTAssertEqual(try orphanCount(), 1)

        let parentsApplied = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceRecord(syncId: "ref-one", title: "R1"),
                makeTagRecord(syncId: "tag-two", name: "T2"),
            ],
            deletions: []
        )
        XCTAssertTrue(parentsApplied)

        let resolved = try db.dbWriter.read { db in
            try Row.fetchOne(db, sql: """
                SELECT rt.syncId, r.syncId AS referenceSyncId,
                       t.syncId AS tagSyncId
                FROM referenceTag rt
                JOIN reference r ON r.id = rt.referenceId
                JOIN tag t ON t.id = rt.tagId
                """)
        }
        XCTAssertEqual(resolved?["syncId"], "ref-one/tag-two")
        XCTAssertEqual(resolved?["referenceSyncId"], "ref-one")
        XCTAssertEqual(resolved?["tagSyncId"], "tag-two")
        XCTAssertEqual(try orphanCount(), 0)
        let violations = try db.dbWriter.read {
            try Row.fetchAll($0, sql: "PRAGMA foreign_key_check")
        }
        XCTAssertTrue(violations.isEmpty)
    }

    func testParentDeletionStillCascadesMaterializedChild() async throws {
        let library = makeLibrary()
        let seeded = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceRecord(syncId: "ref-one", title: "R1"),
                makeTagRecord(syncId: "tag-two", name: "T2"),
                makeReferenceTagRecord(
                    referenceSyncId: "ref-one",
                    tagSyncId: "tag-two"
                ),
            ],
            deletions: []
        )
        XCTAssertTrue(seeded)
        XCTAssertEqual(try pivotCount(), 1)

        let deleted = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [makeDeletion(type: .reference, entityId: "ref-one")]
        )
        XCTAssertTrue(deleted)
        XCTAssertEqual(try pivotCount(), 0)
    }

    func testDeletionCommitsWhileEarlierWireOrphanRemains() async throws {
        let library = makeLibrary()
        var doomed = Reference(title: "Doomed")
        try db.saveReference(&doomed)
        let doomedSyncId = doomed.syncId

        let orphanApplied = await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceTagRecord(
                referenceSyncId: "missing-reference",
                tagSyncId: "missing-tag"
            )],
            deletions: []
        )
        XCTAssertTrue(orphanApplied)

        let deletionApplied = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [makeDeletion(type: .reference, entityId: doomedSyncId)]
        )
        XCTAssertTrue(deletionApplied)

        let remainingReference = try await db.dbWriter.read {
            try Int.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM reference WHERE syncId = ?",
                arguments: [doomedSyncId]
            ) ?? -1
        }
        XCTAssertEqual(remainingReference, 0)
        XCTAssertEqual(try pivotCount(), 0)
        XCTAssertEqual(try orphanCount(), 1)
    }

    func testMixedBatchCascadesDeletionAndQuarantinesNewChild() async throws {
        let library = makeLibrary()
        let seeded = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceRecord(syncId: "doomed-ref", title: "Doomed"),
                makeTagRecord(syncId: "existing-tag", name: "Existing"),
                makeReferenceTagRecord(
                    referenceSyncId: "doomed-ref",
                    tagSyncId: "existing-tag"
                ),
            ],
            deletions: []
        )
        XCTAssertTrue(seeded)

        let mixedApplied = await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceTagRecord(
                referenceSyncId: "future-ref",
                tagSyncId: "future-tag"
            )],
            deletions: [makeDeletion(type: .reference, entityId: "doomed-ref")]
        )
        XCTAssertTrue(mixedApplied)

        XCTAssertEqual(try pivotCount(), 0)
        XCTAssertEqual(try orphanCount(), 1)
        let violations = try db.dbWriter.read {
            try Row.fetchAll($0, sql: "PRAGMA foreign_key_check")
        }
        XCTAssertTrue(violations.isEmpty)
    }

    func testSameEventDeletionWinsOverNewChildModification() async throws {
        let library = makeLibrary()
        let seeded = await library.applyFetchedRecordsForTest(
            modifications: [
                makeReferenceRecord(syncId: "doomed-ref", title: "Doomed"),
                makeTagRecord(syncId: "existing-tag", name: "Existing"),
            ],
            deletions: []
        )
        XCTAssertTrue(seeded)

        let mixedApplied = await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceTagRecord(
                referenceSyncId: "doomed-ref",
                tagSyncId: "existing-tag"
            )],
            deletions: [makeDeletion(type: .reference, entityId: "doomed-ref")]
        )
        XCTAssertTrue(mixedApplied)

        XCTAssertEqual(try pivotCount(), 0)
        XCTAssertEqual(try orphanCount(), 0)
    }

    func testIncrementalBoundaryPreservesOrphanAndFullHistoryRetiresIt() async throws {
        let library = makeLibrary()
        let child = makeReferenceTagRecord(
            referenceSyncId: "missing-reference",
            tagSyncId: "missing-tag"
        )
        let entityId = "missing-reference/missing-tag"

        let childApplied = await library.applyFetchedRecordsForTest(
            modifications: [child],
            deletions: []
        )
        XCTAssertTrue(childApplied)
        let incrementallyReconciled = await library.reconcileFetchedZoneForTest(
            includeTerminalOrphans: false
        )
        XCTAssertTrue(incrementallyReconciled)
        XCTAssertEqual(try orphanCount(), 1)
        let incrementalTombstoneCount = try await db.dbWriter.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType = 'referenceTag' AND entityId = ?
                """, arguments: [entityId]) ?? -1
        }
        XCTAssertEqual(incrementalTombstoneCount, 0)

        let fullyReconciled = await library.reconcileFetchedZoneForTest()
        XCTAssertTrue(fullyReconciled)
        let terminal: (Int, Row?) = try db.dbWriter.read { db in
            return (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOrphan") ?? -1,
                try Row.fetchOne(db, sql: """
                    SELECT confirmedByServer, isPushEligible FROM tombstone
                    WHERE entityType = 'referenceTag' AND entityId = ?
                    """, arguments: [entityId])
            )
        }
        XCTAssertEqual(terminal.0, 0)
        XCTAssertEqual(terminal.1?["confirmedByServer"], 0)
        XCTAssertEqual(terminal.1?["isPushEligible"], 1)
    }

    func testReadingActivityMissingParentUsesWireQuarantine() async throws {
        let library = makeLibrary()
        let referenceSyncId = "missing-reference"
        let entityId = "reading-v7-initial/remote-mac/\(referenceSyncId)/2026-07-15"
        let activity = ReadingActivity(
            syncId: entityId,
            installationId: "remote-mac",
            referenceId: 0,
            referenceSyncId: referenceSyncId,
            localDay: try XCTUnwrap(LocalDay(rawValue: "2026-07-15")),
            epochRevision: 0,
            generation: "reading-v7-initial",
            activeSeconds: 120,
            lastActiveAt: Date(timeIntervalSince1970: 400),
            dateModified: Date(timeIntervalSince1970: 401)
        )
        let record = ReadingActivity.makeRecord(
            recordName: SyncEntityType.readingActivity.qualifiedRecordName(
                entityId: entityId
            ),
            activity: activity
        )

        let activityApplied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(activityApplied)
        let initial: (Int, Int, Int) = try await db.dbWriter.read { db in
            return (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOrphan") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activityQuarantine") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM readingActivity") ?? -1
            )
        }
        XCTAssertEqual(initial.0, 1)
        XCTAssertEqual(initial.1, 0)
        XCTAssertEqual(initial.2, 0)

        let incrementallyReconciled = await library.reconcileFetchedZoneForTest(
            includeTerminalOrphans: false
        )
        XCTAssertTrue(incrementallyReconciled)
        XCTAssertEqual(try orphanCount(), 1)

        let fullyReconciled = await library.reconcileFetchedZoneForTest()
        XCTAssertTrue(fullyReconciled)
        let terminal: (Int, Int) = try await db.dbWriter.read { db in
            return (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOrphan") ?? -1,
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM tombstone
                    WHERE entityType = 'readingActivity' AND entityId = ?
                      AND confirmedByServer = 0 AND isPushEligible = 1
                    """, arguments: [entityId]) ?? -1
            )
        }
        XCTAssertEqual(terminal.0, 0)
        XCTAssertEqual(terminal.1, 1)
    }

    func testMetadataIntakeReplaysAfterLinkedReferenceArrives() async throws {
        let library = makeLibrary()
        let intake = MetadataIntake(
            syncId: "intake-one",
            sourceKind: .manualEntry,
            verificationStatus: .verifiedManual,
            title: "Keep me",
            linkedReferenceId: 0,
            linkedReferenceSyncId: "reference-one"
        )
        let record = MetadataIntake.makeRecord(
            recordName: SyncEntityType.metadataIntake.qualifiedRecordName(
                entityId: intake.syncId
            ),
            intake: intake
        )

        let intakeApplied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(intakeApplied)
        XCTAssertEqual(try orphanCount(), 1)

        let parentApplied = await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceRecord(
                syncId: "reference-one",
                title: "Parent"
            )],
            deletions: []
        )
        XCTAssertTrue(parentApplied)

        let resolved = try db.dbWriter.read { db in
            try Row.fetchOne(db, sql: """
                SELECT mi.syncId, mi.linkedReferenceSyncId,
                       r.syncId AS resolvedReferenceSyncId
                FROM metadataIntake mi
                JOIN reference r ON r.id = mi.linkedReferenceId
                WHERE mi.syncId = 'intake-one'
                """)
        }
        XCTAssertEqual(resolved?["syncId"], "intake-one")
        XCTAssertEqual(resolved?["linkedReferenceSyncId"], "reference-one")
        XCTAssertEqual(resolved?["resolvedReferenceSyncId"], "reference-one")
        XCTAssertEqual(try orphanCount(), 0)
    }
}
#endif
