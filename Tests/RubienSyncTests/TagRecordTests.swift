#if os(macOS)
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class TagRecordTests: XCTestCase {

    private let recordName = "tag-1"

    func testRoundTrip() {
        let original = Tag(id: 5, name: "Research", color: "#FF0000")
        let record = Tag.makeRecord(recordName: recordName, tag: original)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.tag)
        XCTAssertEqual(record.recordID.recordName, recordName)
        XCTAssertEqual(record.recordID.zoneID, SyncConstants.libraryZoneID)

        let decoded = Tag(record: record)
        XCTAssertEqual(decoded.name, "Research")
        XCTAssertEqual(decoded.color, "#FF0000")
    }

    func testLocalIDIsNotEncoded() {
        let original = Tag(id: 42, name: "x", color: "#000000")
        let record = Tag.makeRecord(recordName: recordName, tag: original)
        XCTAssertNil(record["id"])
    }

    func testDecodedTagHasNilLocalID() {
        let record = Tag.makeRecord(
            recordName: recordName,
            tag: Tag(id: 9, name: "x", color: "#000000")
        )
        let decoded = Tag(record: record)
        XCTAssertNil(decoded.id, "decode must leave local rowID nil; caller resolves it")
    }

    func testMissingColorFallsBackToDefault() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.tag,
            recordName: recordName
        )
        record[Tag.RecordField.name] = "OnlyName"
        // color intentionally omitted — model a record written by a peer that
        // doesn't set it (forward-compat)

        let decoded = Tag(record: record)
        XCTAssertEqual(decoded.name, "OnlyName")
        XCTAssertEqual(
            decoded.color,
            Tag(name: "probe").color,
            "missing color falls back to Tag's initializer default — read from the struct so the test tracks drift"
        )
    }

    func testPopulateMutatesProvidedRecord() {
        let existing = makeTestRecord(
            recordType: SyncConstants.RecordType.tag,
            recordName: recordName
        )
        var tag = Tag(name: "Initial", color: "#111111")

        tag.populate(record: existing)
        XCTAssertEqual(existing[Tag.RecordField.name] as? String, "Initial")

        tag.name = "Updated"
        tag.populate(record: existing)
        XCTAssertEqual(existing[Tag.RecordField.name] as? String, "Updated")
        XCTAssertEqual(
            existing.recordID.recordName,
            recordName,
            "populate must mutate in place, never allocate a new record"
        )
    }
}
#endif
