#if canImport(RubienSync)
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class PropertyValueRecordTests: XCTestCase {

    private let recordName = "propvalue-1"

    func testRoundTrip() {
        let original = PropertyValue(referenceId: 42, propertyId: 7, value: "Reading")
        let record = PropertyValue.makeRecord(recordName: recordName, propertyValue: original)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.propertyValue)

        let decoded = PropertyValue(record: record)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.referenceId, 42)
        XCTAssertEqual(decoded?.propertyId, 7)
        XCTAssertEqual(decoded?.value, "Reading")
    }

    func testNilValueRoundTrips() {
        // A nil value is the canonical "deleted" state for multi-select — it
        // must survive round-trip so peers don't reanimate empty rows.
        let original = PropertyValue(referenceId: 1, propertyId: 2, value: nil)
        let record = PropertyValue.makeRecord(recordName: recordName, propertyValue: original)

        let decoded = PropertyValue(record: record)
        XCTAssertNil(decoded?.value)
    }

    func testDecodeReturnsNilWhenReferenceIdMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.propertyValue,
            recordName: recordName
        )
        record[PropertyValue.RecordField.propertyId] = Int64(7)
        XCTAssertNil(PropertyValue(record: record))
    }

    func testDecodeReturnsNilWhenPropertyIdMissing() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.propertyValue,
            recordName: recordName
        )
        record[PropertyValue.RecordField.referenceId] = Int64(42)
        XCTAssertNil(PropertyValue(record: record))
    }

    func testFKsAreEncodedAsInt64() {
        let pv = PropertyValue(referenceId: 42, propertyId: 7, value: nil)
        let record = PropertyValue.makeRecord(recordName: recordName, propertyValue: pv)
        XCTAssertTrue(record[PropertyValue.RecordField.referenceId] is Int64)
        XCTAssertTrue(record[PropertyValue.RecordField.propertyId] is Int64)
    }
}
#endif
