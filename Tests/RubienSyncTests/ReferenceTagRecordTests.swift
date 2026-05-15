#if os(macOS)
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class ReferenceTagRecordTests: XCTestCase {

    func testRecordNameMatchesTriggerFormat() {
        // Must stay "refId/tagId" to match the synthetic entityId emitted by
        // `referenceTag_ai` / `_au` / `_ad` triggers in AppDatabase.swift.
        XCTAssertEqual(ReferenceTag.recordName(referenceId: 42, tagId: 7), "42/7")

        let pivot = ReferenceTag(referenceId: 101, tagId: 202)
        XCTAssertEqual(pivot.recordName, "101/202")
    }

    func testRoundTrip() {
        let pivot = ReferenceTag(referenceId: 42, tagId: 7)
        let record = ReferenceTag.makeRecord(referenceTag: pivot)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.referenceTag)
        XCTAssertEqual(record.recordID.recordName, "42/7")
        XCTAssertEqual(record.recordID.zoneID, SyncConstants.libraryZoneID)

        let decoded = ReferenceTag(record: record)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.referenceId, 42)
        XCTAssertEqual(decoded?.tagId, 7)
    }

    func testDecodeReturnsNilWhenReferenceIdMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.referenceTag,
            recordName: "x/y"
        )
        record[ReferenceTag.RecordField.tagId] = Int64(7)
        // referenceId intentionally omitted

        XCTAssertNil(
            ReferenceTag(record: record),
            "pivot without both FKs is malformed; must not decode to a zero-populated row"
        )
    }

    func testDecodeReturnsNilWhenTagIdMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.referenceTag,
            recordName: "x/y"
        )
        record[ReferenceTag.RecordField.referenceId] = Int64(42)

        XCTAssertNil(ReferenceTag(record: record))
    }

    func testFKsAreEncodedAsInt64NotCKReference() {
        let pivot = ReferenceTag(referenceId: 42, tagId: 7)
        let record = ReferenceTag.makeRecord(referenceTag: pivot)
        // CKRecord.Reference triggers CloudKit-managed cascade semantics we don't want —
        // we enforce referential integrity via SQLite FKs on the receive side.
        XCTAssertTrue(record[ReferenceTag.RecordField.referenceId] is Int64)
        XCTAssertTrue(record[ReferenceTag.RecordField.tagId] is Int64)
    }
}
#endif
