import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class PDFAnnotationCKRecordTests: XCTestCase {

    private let recordName = "pdfann-1"

    func testRoundTrip() {
        let original = PDFAnnotationRecord(
            referenceId: 42,
            type: .highlight,
            selectedText: "Hello world",
            noteText: "a note",
            color: "#FFDE59",
            pageIndex: 3,
            rects: [CGRect(x: 10, y: 20, width: 100, height: 14)]
        )
        let record = PDFAnnotationRecord.makeRecord(
            recordName: recordName,
            annotation: original
        )

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.pdfAnnotation)
        XCTAssertEqual(record.recordID.recordName, recordName)
        XCTAssertEqual(record.recordID.zoneID, SyncConstants.libraryZoneID)

        let decoded = PDFAnnotationRecord(record: record)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.referenceId, 42)
        XCTAssertEqual(decoded?.type, .highlight)
        XCTAssertEqual(decoded?.selectedText, "Hello world")
        XCTAssertEqual(decoded?.noteText, "a note")
        XCTAssertEqual(decoded?.pageIndex, 3)
        XCTAssertEqual(decoded?.rectsData, original.rectsData,
                       "rectsData must survive round-trip byte-for-byte so peers don't see fake movement")
        XCTAssertEqual(decoded?.boundsX, original.boundsX)
        XCTAssertEqual(decoded?.boundsWidth, original.boundsWidth)
    }

    func testLocalIDIsNotEncoded() {
        let ann = PDFAnnotationRecord(
            id: 99,
            referenceId: 1,
            type: .note,
            pageIndex: 0,
            rects: [.zero]
        )
        let record = PDFAnnotationRecord.makeRecord(recordName: recordName, annotation: ann)
        XCTAssertNil(record["id"])
    }

    func testDecodedLocalIDIsNil() {
        let record = PDFAnnotationRecord.makeRecord(
            recordName: recordName,
            annotation: PDFAnnotationRecord(
                id: 7,
                referenceId: 1,
                type: .highlight,
                pageIndex: 0,
                rects: [.zero]
            )
        )
        let decoded = PDFAnnotationRecord(record: record)
        XCTAssertNil(decoded?.id, "decode must leave local rowID nil; caller resolves it")
    }

    func testDecodeReturnsNilWhenReferenceIdMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.pdfAnnotation,
            recordName: recordName
        )
        record[PDFAnnotationRecord.RecordField.type]      = AnnotationType.highlight.rawValue
        record[PDFAnnotationRecord.RecordField.pageIndex] = Int64(0)
        // referenceId intentionally omitted

        XCTAssertNil(
            PDFAnnotationRecord(record: record),
            "orphan annotation (no FK) would violate pdfAnnotation.referenceId NOT NULL — refuse to decode"
        )
    }

    func testUnknownTypeFallsBackToHighlight() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.pdfAnnotation,
            recordName: recordName
        )
        record[PDFAnnotationRecord.RecordField.referenceId] = Int64(5)
        record[PDFAnnotationRecord.RecordField.type]        = "sparkle"  // future case
        record[PDFAnnotationRecord.RecordField.pageIndex]   = Int64(0)

        let decoded = PDFAnnotationRecord(record: record)
        XCTAssertEqual(
            decoded?.type,
            .highlight,
            "unknown enum rawValues must not crash an older decoder"
        )
    }

    func testFKIsEncodedAsInt64NotCKReference() {
        let ann = PDFAnnotationRecord(referenceId: 42, type: .highlight, pageIndex: 0, rects: [.zero])
        let record = PDFAnnotationRecord.makeRecord(recordName: recordName, annotation: ann)
        XCTAssertTrue(record[PDFAnnotationRecord.RecordField.referenceId] is Int64)
    }
}
