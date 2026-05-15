#if canImport(RubienSync)
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class MetadataEvidenceRecordTests: XCTestCase {

    private let recordName = "evidence-1"

    func testRoundTrip() {
        let original = MetadataEvidence(
            intakeId: 3,
            referenceId: 42,
            bundleHash: "deadbeef",
            source: .translationServer,
            recordKey: "abc",
            sourceURL: "https://example.com",
            fetchMode: .identifier,
            payloadJSON: "{}",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let record = MetadataEvidence.makeRecord(recordName: recordName, evidence: original)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.metadataEvidence)

        let decoded = MetadataEvidence(record: record)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.intakeId, 3)
        XCTAssertEqual(decoded?.referenceId, 42)
        XCTAssertEqual(decoded?.bundleHash, "deadbeef")
        XCTAssertEqual(decoded?.source, .translationServer)
        XCTAssertEqual(decoded?.recordKey, "abc")
        XCTAssertEqual(decoded?.sourceURL, "https://example.com")
        XCTAssertEqual(decoded?.fetchMode, .identifier)
        XCTAssertEqual(decoded?.payloadJSON, "{}")
    }

    func testDecodeReturnsNilWhenBundleHashMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.metadataEvidence,
            recordName: recordName
        )
        record[MetadataEvidence.RecordField.payloadJSON] = "{}"
        // bundleHash omitted — the dedup key; row is useless without it.
        XCTAssertNil(MetadataEvidence(record: record))
    }

    func testDecodeReturnsNilWhenPayloadMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.metadataEvidence,
            recordName: recordName
        )
        record[MetadataEvidence.RecordField.bundleHash] = "deadbeef"
        // payloadJSON omitted — the whole point of evidence
        XCTAssertNil(MetadataEvidence(record: record))
    }

    func testUnknownFetchModeFallsBackToManual() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.metadataEvidence,
            recordName: recordName
        )
        record[MetadataEvidence.RecordField.bundleHash]  = "deadbeef"
        record[MetadataEvidence.RecordField.payloadJSON] = "{}"
        record[MetadataEvidence.RecordField.source]      = MetadataSource.translationServer.rawValue
        record[MetadataEvidence.RecordField.fetchMode]   = "teleport"

        XCTAssertEqual(MetadataEvidence(record: record)?.fetchMode, .manual)
    }

    func testNilFKsAreAllowed() {
        // Evidence can exist before intake is linked or after intake is
        // deleted — neither FK is required on the CK side.
        let ev = MetadataEvidence(
            intakeId: nil,
            referenceId: nil,
            bundleHash: "h",
            source: .translationServer,
            fetchMode: .manual,
            payloadJSON: "{}"
        )
        let record = MetadataEvidence.makeRecord(recordName: recordName, evidence: ev)
        let decoded = MetadataEvidence(record: record)
        XCTAssertNil(decoded?.intakeId)
        XCTAssertNil(decoded?.referenceId)
    }
}
#endif
