import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class MetadataIntakeRecordTests: XCTestCase {

    private let recordName = "intake-1"

    func testRoundTrip() {
        let original = MetadataIntake(
            sourceKind: .importedPDF,
            verificationStatus: .candidate,
            title: "Foundations of X",
            originalInput: "10.1234/foo",
            sourceURL: "https://example.com/paper",
            pdfPath: "abc_Foundations.pdf",
            seedJSON: "{\"a\":1}",
            fallbackReferenceJSON: nil,
            currentReferenceJSON: nil,
            candidatesJSON: "[]",
            statusMessage: "awaiting review",
            linkedReferenceId: 42,
            evidenceBundleHash: "sha256",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_010_000)
        )
        let record = MetadataIntake.makeRecord(recordName: recordName, intake: original)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.metadataIntake)

        let decoded = MetadataIntake(record: record)
        XCTAssertEqual(decoded.sourceKind, .importedPDF)
        XCTAssertEqual(decoded.verificationStatus, .candidate)
        XCTAssertEqual(decoded.title, "Foundations of X")
        XCTAssertEqual(decoded.originalInput, "10.1234/foo")
        XCTAssertEqual(decoded.sourceURL, "https://example.com/paper")
        XCTAssertEqual(decoded.pdfPath, "abc_Foundations.pdf")
        XCTAssertEqual(decoded.seedJSON, "{\"a\":1}")
        XCTAssertEqual(decoded.linkedReferenceId, 42)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.updatedAt, original.updatedAt)
    }

    func testUnknownSourceKindFallsBackToManualEntry() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.metadataIntake,
            recordName: recordName
        )
        record[MetadataIntake.RecordField.title]              = "x"
        record[MetadataIntake.RecordField.sourceKind]         = "futureKind"
        record[MetadataIntake.RecordField.verificationStatus] = VerificationStatus.legacy.rawValue

        XCTAssertEqual(MetadataIntake(record: record).sourceKind, .manualEntry)
    }

    func testUnknownVerificationStatusFallsBackToLegacy() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.metadataIntake,
            recordName: recordName
        )
        record[MetadataIntake.RecordField.title]              = "x"
        record[MetadataIntake.RecordField.sourceKind]         = MetadataIntakeSourceKind.manualEntry.rawValue
        record[MetadataIntake.RecordField.verificationStatus] = "superVerified"

        XCTAssertEqual(MetadataIntake(record: record).verificationStatus, .legacy)
    }

    func testLocalIDIsNotEncoded() {
        let intake = MetadataIntake(
            id: 7,
            sourceKind: .manualEntry,
            verificationStatus: .legacy,
            title: "x"
        )
        let record = MetadataIntake.makeRecord(recordName: recordName, intake: intake)
        XCTAssertNil(record["id"])
    }

    func testLinkedReferenceIdIsEncodedAsInt64() {
        let intake = MetadataIntake(
            sourceKind: .manualEntry,
            verificationStatus: .legacy,
            title: "x",
            linkedReferenceId: 42
        )
        let record = MetadataIntake.makeRecord(recordName: recordName, intake: intake)
        XCTAssertTrue(record[MetadataIntake.RecordField.linkedReferenceId] is Int64)
    }
}
