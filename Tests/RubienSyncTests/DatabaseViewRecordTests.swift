#if canImport(RubienSync)
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class DatabaseViewRecordTests: XCTestCase {

    private let recordName = "view-1"

    func testRoundTrip() {
        let original = DatabaseView(
            name: "All References",
            icon: "books.vertical",
            scope: .all,
            columns: ColumnConfig.defaultColumns,
            filters: [],
            sorts: [.defaultSort],
            groupBy: nil,
            columnWraps: ["title", "custom_42"],
            isDefault: true,
            displayOrder: 0
        )
        let record = DatabaseView.makeRecord(recordName: recordName, view: original)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.databaseView)

        let decoded = DatabaseView(record: record)
        XCTAssertEqual(decoded.name, "All References")
        XCTAssertEqual(decoded.icon, "books.vertical")
        XCTAssertTrue(decoded.isDefault)
        XCTAssertEqual(decoded.displayOrder, 0)
        XCTAssertEqual(
            decoded.scopeJSON,
            original.scopeJSON,
            "JSON blobs must ship verbatim so a peer's shape additions aren't lost"
        )
        XCTAssertEqual(decoded.columnsJSON, original.columnsJSON)
        XCTAssertEqual(decoded.filtersJSON, original.filtersJSON)
        XCTAssertEqual(decoded.sortsJSON, original.sortsJSON)
        XCTAssertEqual(decoded.columnWrapsJSON, original.columnWrapsJSON)
        XCTAssertEqual(decoded.parsedColumnWraps, Set(["title", "custom_42"]))
    }

    func testColumnWrapsJSONOmittedByPeerFallsBackToDefault() {
        // Older peer wrote no columnWrapsJSON field. Local decode must not
        // crash or drop silently — we fall back to the "[]" default baked
        // into the memberwise init.
        let record = CKRecord(
            recordType: SyncConstants.RecordType.databaseView,
            recordID: CKRecord.ID(
                recordName: recordName,
                zoneID: SyncConstants.libraryZoneID
            )
        )
        record[DatabaseView.RecordField.name] = "Partial"
        // columnWrapsJSON intentionally not set

        let decoded = DatabaseView(record: record)
        XCTAssertEqual(decoded.columnWrapsJSON, "[]")
        XCTAssertTrue(decoded.parsedColumnWraps.isEmpty)
    }

    func testGroupByJSONNilRoundTrip() {
        let original = DatabaseView(name: "x", groupBy: nil)
        let record = DatabaseView.makeRecord(recordName: recordName, view: original)
        let decoded = DatabaseView(record: record)
        XCTAssertNil(decoded.groupByJSON, "nil groupBy must not be reanimated as an empty group")
    }

    func testLocalIDIsNotEncoded() {
        let view = DatabaseView(id: 42, name: "x")
        let record = DatabaseView.makeRecord(recordName: recordName, view: view)
        XCTAssertNil(record["id"])
    }

    func testDatesRoundTrip() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_700_001_000)
        let view = DatabaseView(name: "x", dateCreated: created, dateModified: modified)
        let record = DatabaseView.makeRecord(recordName: recordName, view: view)

        let decoded = DatabaseView(record: record)
        XCTAssertEqual(decoded.dateCreated, created)
        XCTAssertEqual(decoded.dateModified, modified)
    }
}
#endif
