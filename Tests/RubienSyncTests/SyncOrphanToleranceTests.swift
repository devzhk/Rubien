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
/// arrive in a batch *before* its parent `reference`/`tag`. Pre-fix,
/// `applyFetchedRecordsInternal` ran `PRAGMA foreign_key_check` and threw on
/// any violation, rolling the batch back forever (the change token never
/// advanced → CloudKit redelivered the same failing batch). The fix tolerates
/// transient orphans in **delete-free** batches while leaving the delete path
/// strict so `ON DELETE CASCADE` still drops children.
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
        await library.applyFetchedRecordsForTest(modifications: [child], deletions: [])
        let afterOrphan = try await pivotCount()
        XCTAssertEqual(afterOrphan, 1,
                       "orphan pivot must commit in a delete-free batch (pre-fix: rolled back to 0)")

        // Parents arrive in a later batch → the library is now FK-consistent.
        await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceRecord(id: 1, title: "R1"),
                            makeTagRecord(id: 2, name: "T2")],
            deletions: [])
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
        await library.applyFetchedRecordsForTest(
            modifications: [makeReferenceRecord(id: 1, title: "R1"),
                            makeTagRecord(id: 2, name: "T2"),
                            makeReferenceTagRecord(referenceId: 1, tagId: 2)],
            deletions: [])
        let before = try await pivotCount()
        XCTAssertEqual(before, 1)

        // A batch carrying a deletion keeps FK ON → deleting the parent
        // reference cascades to the pivot via ON DELETE CASCADE.
        let deletion = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(entityId: "1"),
                zoneID: SyncConstants.libraryZoneID),
            recordType: SyncConstants.RecordType.reference)
        await library.applyFetchedRecordsForTest(modifications: [], deletions: [deletion])

        let after = try await pivotCount()
        XCTAssertEqual(after, 0,
                       "deleting the parent reference must cascade-delete the pivot (FK delete path unchanged)")
    }
}
#endif
