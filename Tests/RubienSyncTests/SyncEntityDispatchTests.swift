import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// End-to-end dispatch tests that round-trip through a real in-memory DB.
/// Exercises the push path (DB row → CKRecord) and the pull path
/// (CKRecord → DB row) together so any drift between them surfaces.
final class SyncEntityDispatchTests: XCTestCase {

    private var db: AppDatabase!
    private let store = SyncStateStore()

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    // MARK: - Push path

    func testBuildPushRecordRehydratesCachedSystemFields() throws {
        // recordName must carry the "<type>:" prefix — buildPushRecord
        // rehydrates only when the cached recordName matches the expected
        // prefixed form, otherwise it builds fresh (see the migration-path
        // comment on rehydrateOrNew).
        let cached = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(
                recordName: "tag:1",
                zoneID: SyncConstants.libraryZoneID
            )
        )
        let systemFields = SyncStateStore.archiveSystemFields(of: cached)

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 'Alpha', '#111')")

            let record = try SyncEntityType.tag.buildPushRecord(
                db: db,
                entityId: "1",
                systemFields: systemFields
            )
            XCTAssertNotNil(record)
            XCTAssertEqual(record?.recordID.recordName, "tag:1")
            XCTAssertEqual(record?["name"] as? String, "Alpha")
        }
    }

    func testBuildPushRecordDiscardsPrePrefixCachedSystemFields() throws {
        // Upgrade scenario: a library synced before the prefix fix has
        // cached systemFields with recordName="1" (no "tag:" prefix). On
        // the next push, we MUST treat this as a fresh record (new server
        // identity) — using the cached CKRecord would push under the old
        // colliding name and revive the bug for that row.
        let cached = CKRecord(
            recordType: SyncConstants.RecordType.tag,
            recordID: CKRecord.ID(
                recordName: "1",
                zoneID: SyncConstants.libraryZoneID
            )
        )
        let systemFields = SyncStateStore.archiveSystemFields(of: cached)

        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag(id, name, color) VALUES(1, 'Alpha', '#111')")

            let record = try SyncEntityType.tag.buildPushRecord(
                db: db,
                entityId: "1",
                systemFields: systemFields
            )
            XCTAssertEqual(
                record?.recordID.recordName,
                "tag:1",
                "legacy unprefixed systemFields must be discarded so the push lands under the new prefixed name"
            )
        }
    }

    func testBuildPushRecordReturnsNilForMissingRow() throws {
        try db.dbWriter.read { db in
            let record = try SyncEntityType.tag.buildPushRecord(
                db: db,
                entityId: "999",
                systemFields: nil
            )
            XCTAssertNil(
                record,
                "locally-deleted rows return nil so the push batch skips them; tombstone carries the delete"
            )
        }
    }

    // MARK: - Apply remote (upsert)

    func testApplyRemoteInsertsNewReference() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            let ref = Reference(title: "Synced from Cloud")
            let record = Reference.makeRecord(recordName: "reference:42", reference: ref)

            try SyncEntityType.reference.applyRemoteRecord(record, entityId: "42", db: db)

            try self.store.clearApplyingRemote(db)

            let fetched = try Reference.fetchOne(db, key: 42)
            XCTAssertEqual(fetched?.title, "Synced from Cloud")
            XCTAssertEqual(fetched?.id, 42)
        }
    }

    func testApplyRemoteUpdatesExistingReferenceWithoutRecreating() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            var initial = Reference(title: "initial")
            initial.id = 7
            try initial.insert(db)

            var updated = Reference(title: "updated")
            updated.id = 7
            let record = Reference.makeRecord(recordName: "reference:7", reference: updated)

            try SyncEntityType.reference.applyRemoteRecord(record, entityId: "7", db: db)

            try self.store.clearApplyingRemote(db)

            let fetched = try Reference.fetchOne(db, key: 7)
            XCTAssertEqual(fetched?.title, "updated")
            let totalCount = try Reference.fetchCount(db)
            XCTAssertEqual(
                totalCount,
                1,
                "UPDATE path must not allocate a second row; INSERT OR REPLACE would (and cascade-delete children)"
            )
        }
    }

    func testApplyRemoteUpsertDoesNotCascadeDeleteChildren() throws {
        // The motivating reason we use INSERT + UPDATE instead of
        // INSERT OR REPLACE — replace would trigger the FK cascade and
        // nuke all child annotations on every ref round-trip.
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            var ref = Reference(title: "parent")
            ref.id = 10
            try ref.insert(db)

            var ann = PDFAnnotationRecord(
                referenceId: 10,
                type: .highlight,
                pageIndex: 0,
                rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
            )
            try ann.insert(db)

            var updated = Reference(title: "parent-renamed")
            updated.id = 10
            let record = Reference.makeRecord(recordName: "reference:10", reference: updated)
            try SyncEntityType.reference.applyRemoteRecord(record, entityId: "10", db: db)

            try self.store.clearApplyingRemote(db)

            let annotationCount = try PDFAnnotationRecord
                .filter(Column("referenceId") == 10)
                .fetchCount(db)
            XCTAssertEqual(annotationCount, 1, "child annotations must survive the parent upsert")
        }
    }

    func testApplyRemoteInsertsReferenceTagPivot() throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)

            // Seed parents so FK is satisfiable
            var ref = Reference(id: 1, title: "r")
            var tag = Tag(id: 2, name: "t", color: "#000")
            try ref.insert(db)
            try tag.insert(db)

            let record = ReferenceTag.makeRecord(
                referenceTag: ReferenceTag(referenceId: 1, tagId: 2)
            )
            try SyncEntityType.referenceTag.applyRemoteRecord(record, entityId: "1/2", db: db)

            try self.store.clearApplyingRemote(db)

            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=1 AND tagId=2"
            ) ?? 0
            XCTAssertEqual(count, 1)
        }
    }

    // MARK: - Apply remote delete

    func testApplyRemoteDeleteRemovesRowAndCascades() throws {
        try db.dbWriter.write { db in
            var ref = Reference(id: 5, title: "parent")
            try ref.insert(db)
            var ann = PDFAnnotationRecord(
                referenceId: 5,
                type: .highlight,
                pageIndex: 0,
                rects: [.zero]
            )
            try ann.insert(db)

            try self.store.setApplyingRemote(db)
            try SyncEntityType.reference.applyRemoteDelete(entityId: "5", db: db)
            try self.store.clearApplyingRemote(db)

            XCTAssertNil(try Reference.fetchOne(db, key: 5))
            XCTAssertEqual(
                try PDFAnnotationRecord.filter(Column("referenceId") == 5).fetchCount(db),
                0,
                "FK cascade must carry delete into child tables"
            )
        }
    }

    func testApplyRemoteDeletePivotByCompositeKey() throws {
        try db.dbWriter.write { db in
            var ref = Reference(id: 1, title: "r")
            var tag = Tag(id: 2, name: "t", color: "#000")
            try ref.insert(db)
            try tag.insert(db)
            try ReferenceTag(referenceId: 1, tagId: 2).insert(db)

            try self.store.setApplyingRemote(db)
            try SyncEntityType.referenceTag.applyRemoteDelete(entityId: "1/2", db: db)
            try self.store.clearApplyingRemote(db)

            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM referenceTag"
            ) ?? -1
            XCTAssertEqual(count, 0)
        }
    }
}

private extension Reference {
    init(id: Int64, title: String) {
        self.init(title: title)
        self.id = id
    }
}
