#if canImport(RubienSync)
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class PropertyDefinitionRecordTests: XCTestCase {

    private let recordName = "prop-1"

    func testRoundTrip() {
        let original = PropertyDefinition(
            name: "Type",
            type: .singleSelect,
            options: [.init(value: "Journal Article", color: "#007AFF")],
            sortOrder: 0,
            isDefault: true,
            defaultFieldKey: "referenceType",
            isVisible: true
        )
        let record = PropertyDefinition.makeRecord(recordName: recordName, definition: original)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.propertyDefinition)
        XCTAssertEqual(record.recordID.zoneID, SyncConstants.libraryZoneID)

        let decoded = PropertyDefinition(record: record)
        XCTAssertEqual(decoded.name, "Type")
        XCTAssertEqual(decoded.type, .singleSelect)
        XCTAssertEqual(decoded.sortOrder, 0)
        XCTAssertTrue(decoded.isDefault)
        XCTAssertEqual(decoded.defaultFieldKey, "referenceType")
        XCTAssertTrue(decoded.isVisible)
        XCTAssertEqual(
            decoded.optionsJSON,
            original.optionsJSON,
            "optionsJSON must survive byte-for-byte so future SelectOption fields aren't dropped"
        )
    }

    func testLocalIDIsNotEncoded() {
        let def = PropertyDefinition(id: 42, name: "x", type: .string)
        let record = PropertyDefinition.makeRecord(recordName: recordName, definition: def)
        XCTAssertNil(record["id"])
    }

    func testDecodedLocalIDIsNil() {
        let record = PropertyDefinition.makeRecord(
            recordName: recordName,
            definition: PropertyDefinition(id: 9, name: "x", type: .string)
        )
        XCTAssertNil(PropertyDefinition(record: record).id)
    }

    func testUnknownPropertyTypeFallsBackToString() {
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.propertyDefinition,
            recordName: recordName
        )
        record[PropertyDefinition.RecordField.name] = "X"
        record[PropertyDefinition.RecordField.type] = "rating"  // future case

        XCTAssertEqual(PropertyDefinition(record: record).type, .string)
    }

    func testMissingIsVisibleDefaultsTrue() {
        // Older wire format that forgot isVisible — default visible keeps
        // the property discoverable instead of silently hiding it.
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.propertyDefinition,
            recordName: recordName
        )
        record[PropertyDefinition.RecordField.name] = "X"
        record[PropertyDefinition.RecordField.type] = PropertyType.string.rawValue

        XCTAssertTrue(PropertyDefinition(record: record).isVisible)
    }

    func testBoolsEncodeAsInt64() {
        let def = PropertyDefinition(name: "x", type: .string, isDefault: true, isVisible: false)
        let record = PropertyDefinition.makeRecord(recordName: recordName, definition: def)
        XCTAssertTrue(record[PropertyDefinition.RecordField.isDefault] is Int64)
        XCTAssertTrue(record[PropertyDefinition.RecordField.isVisible] is Int64)
    }
}
#endif
