import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, *)
final class ReferencePDFRecordTests: XCTestCase {

    func testRoundTripPreservesAllFields() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-fake".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = ReferencePDFRecord(
            referenceId: 42,
            assetURL: tmp,
            assetVersion: 7,
            contentHash: "abc123",
            originalFilename: "paper.pdf",
            dateModified: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let ckRecord = ReferencePDFRecord.makeRecord(recordName: "referencePDF:42", payload: original)
        let decoded = ReferencePDFRecord(record: ckRecord)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.referenceId, 42)
        XCTAssertEqual(decoded?.assetVersion, 7)
        XCTAssertEqual(decoded?.contentHash, "abc123")
        XCTAssertEqual(decoded?.originalFilename, "paper.pdf")
        XCTAssertEqual(decoded?.dateModified, Date(timeIntervalSince1970: 1_700_000_000))
        // Asset URL post-decode points at CKAsset's downloaded file, not the
        // original tmp path. We don't assert path equality, only existence of the URL property.
        XCTAssertNotNil(decoded?.assetURL)
    }

    func testInitFailsWithoutReferenceId() {
        let record = CKRecord(recordType: "CDReferencePDF", recordID: CKRecord.ID(recordName: "referencePDF:99"))
        // No referenceId field set — orphan record; init should fail.
        XCTAssertNil(ReferencePDFRecord(record: record))
    }

    func testAllFieldNamesIsComplete() {
        // The schema-invariant test (Phase E Task 29) introspects this list.
        // Every CKRecord field key declared in RecordField must appear here.
        let expected: Set<String> = [
            "referenceId", "asset", "assetVersion",
            "contentHash", "originalFilename", "dateModified"
        ]
        XCTAssertEqual(Set(ReferencePDFRecord.allFieldNames), expected)
    }
}
