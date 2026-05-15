import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class WebAnnotationCKRecordTests: XCTestCase {

    private let recordName = "webann-1"

    func testRoundTrip() {
        let original = WebAnnotationRecord(
            referenceId: 42,
            type: .underline,
            noteText: "note",
            color: "#FFDE59",
            anchorText: "Hello world",
            prefixText: "Before ",
            suffixText: " after"
        )
        let record = WebAnnotationRecord.makeRecord(
            recordName: recordName,
            annotation: original
        )

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.webAnnotation)
        XCTAssertEqual(record.recordID.recordName, recordName)
        XCTAssertEqual(record.recordID.zoneID, SyncConstants.libraryZoneID)
        // anchorText mirrored into the legacy selectedText CK field for older
        // peers that haven't dropped the field yet.
        XCTAssertEqual(record[WebAnnotationRecord.RecordField.selectedText] as? String, "Hello world")

        let decoded = WebAnnotationRecord(record: record)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.referenceId, 42)
        XCTAssertEqual(decoded?.type, .underline)
        XCTAssertEqual(decoded?.anchorText, "Hello world")
        XCTAssertEqual(decoded?.prefixText, "Before ")
        XCTAssertEqual(decoded?.suffixText, " after")
    }

    func testLocalIDIsNotEncoded() {
        let ann = WebAnnotationRecord(
            id: 99,
            referenceId: 1,
            type: .note,
            anchorText: "x"
        )
        let record = WebAnnotationRecord.makeRecord(recordName: recordName, annotation: ann)
        XCTAssertNil(record["id"])
    }

    func testDecodeReturnsNilWhenReferenceIdMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.webAnnotation,
            recordName: recordName
        )
        record[WebAnnotationRecord.RecordField.anchorText] = "anchor"
        // referenceId intentionally omitted

        XCTAssertNil(
            WebAnnotationRecord(record: record),
            "orphan web annotation must not decode to a zero-FK row"
        )
    }

    func testDecodeReturnsNilWhenAnchorTextMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.webAnnotation,
            recordName: recordName
        )
        record[WebAnnotationRecord.RecordField.referenceId] = Int64(1)
        // anchorText intentionally omitted — NOT NULL in schema

        XCTAssertNil(WebAnnotationRecord(record: record))
    }

    func testUnknownTypeFallsBackToHighlight() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.webAnnotation,
            recordName: recordName
        )
        record[WebAnnotationRecord.RecordField.referenceId] = Int64(5)
        record[WebAnnotationRecord.RecordField.anchorText]  = "anchor"
        record[WebAnnotationRecord.RecordField.type]        = "sparkle"

        XCTAssertEqual(WebAnnotationRecord(record: record)?.type, .highlight)
    }

    func testFKIsEncodedAsInt64NotCKReference() {
        let ann = WebAnnotationRecord(
            referenceId: 42,
            type: .highlight,
            anchorText: "x"
        )
        let record = WebAnnotationRecord.makeRecord(recordName: recordName, annotation: ann)
        XCTAssertTrue(record[WebAnnotationRecord.RecordField.referenceId] is Int64)
    }

    func testDecodeFallsBackToLegacySelectedTextFieldWhenAnchorTextMissing() {
        // Records written by older peers used only `selectedText`. After model
        // unification we still accept those, treating selectedText as the
        // anchor.
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.webAnnotation,
            recordName: recordName
        )
        record[WebAnnotationRecord.RecordField.referenceId] = Int64(7)
        record[WebAnnotationRecord.RecordField.selectedText] = "legacy anchor"

        XCTAssertEqual(WebAnnotationRecord(record: record)?.anchorText, "legacy anchor")
    }
}
