#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Spec §2 (markdown-import design): `optionsJSON` syncs verbatim, so an
/// old peer pushing the six-option Type definition would silently remove
/// the "Markdown" option and the v6 migration never reruns. The apply path
/// must heal enum-backed options — without dirtying the record.
final class TypeOptionsReconciliationTests: XCTestCase {
    private var db: AppDatabase!
    private let store = SyncStateStore()

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    private let sixOptions: [SelectOption] = [
        .init(value: "Journal Article",  color: "#007AFF"),
        .init(value: "Conference Paper", color: "#AF52DE"),
        .init(value: "Book",             color: "#34C759"),
        .init(value: "Thesis",           color: "#FF9500"),
        .init(value: "Web Page",         color: "#30B0C7"),
        .init(value: "Other",            color: "#8E8E93"),
    ]

    func testRemoteSixOptionTypeDefinitionIsHealed() throws {
        let localId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='referenceType'")
        })

        let def = PropertyDefinition(
            id: localId, name: "Type", type: .singleSelect, options: sixOptions,
            sortOrder: 0, isDefault: true, defaultFieldKey: "referenceType", isVisible: true
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(localId)),
            definition: def
        )

        try db.dbWriter.write { d in
            // Start from a clean slate so the dirty assertion below observes
            // only the apply path, not earlier migration/seed writes.
            try d.execute(sql: "DELETE FROM syncState", arguments: [])
            try self.store.setApplyingRemote(d)
            _ = try SyncEntityType.propertyDefinition.applyRemoteRecord(
                record, entityId: String(localId), db: d
            )
            try self.store.clearApplyingRemote(d)
        }

        let stored = try db.dbWriter.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey='referenceType'"
            ) ?? ""
        }
        XCTAssertTrue(stored.contains(#""Markdown""#), "reconciliation re-appends the enum-backed option")
        XCTAssertTrue(stored.contains("Journal Article"), "incoming options preserved")

        let dirty = try db.dbWriter.read { d in
            try Int.fetchOne(
                d,
                sql: """
                    SELECT COUNT(*) FROM syncState
                    WHERE entityType = 'propertyDefinition' AND entityId = ? AND isDirty = 1
                    """,
                arguments: [String(localId)]
            ) ?? 0
        }
        XCTAssertEqual(dirty, 0, "healing must not push back")
    }

    /// Non-Type built-ins must pass through untouched (no accidental healing).
    func testNonTypeBuiltinIsNotTouched() throws {
        let localId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'")
        })
        let def = PropertyDefinition(
            id: localId, name: "Last Read", type: .date, options: [],
            sortOrder: 9, isDefault: true, defaultFieldKey: "lastReadAt", isVisible: false
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(localId)),
            definition: def
        )
        try db.dbWriter.write { d in
            try self.store.setApplyingRemote(d)
            _ = try SyncEntityType.propertyDefinition.applyRemoteRecord(
                record, entityId: String(localId), db: d
            )
            try self.store.clearApplyingRemote(d)
        }
        let stored = try db.dbWriter.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"
            ) ?? ""
        }
        XCTAssertFalse(stored.contains("Markdown"))
    }
}
#endif
