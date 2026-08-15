#if os(macOS)
import XCTest
import CloudKit
import GRDB
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

    func testPortableIdentityJSONResolvesToDifferentLocalRowIDs() throws {
        let source = try AppDatabase(DatabaseQueue())
        var sourceTag = Tag(
            syncId: "11111111-1111-4111-8111-111111111111",
            name: "Portable tag",
            color: "#ff0000"
        )
        try source.saveTag(&sourceTag)
        var sourceProperty = PropertyDefinition(
            syncId: "22222222-2222-4222-8222-222222222222",
            name: "Portable property",
            type: .string
        )
        try source.savePropertyDefinition(&sourceProperty)
        let sourceTagID = try XCTUnwrap(sourceTag.id)
        let sourcePropertyID = try XCTUnwrap(sourceProperty.id)
        var sourceView = DatabaseView(
            syncId: "33333333-3333-4333-8333-333333333333",
            name: "Portable view",
            scope: .tag(sourceTagID),
            filters: [.init(
                target: .builtin(.tags),
                op: .isAnyOf,
                value: .selectKeys([String(sourceTagID)])
            )],
            sorts: [.init(target: .custom(sourcePropertyID), ascending: true)],
            groupBy: .init(
                target: .builtin(.tags),
                customOrder: [String(sourceTagID)],
                collapsed: [String(sourceTagID)]
            ),
            columnWraps: ["custom_\(sourcePropertyID)"]
        )
        try source.saveDatabaseView(&sourceView)

        let record = try source.dbWriter.write { db in
            try XCTUnwrap(SyncEntityType.databaseView.buildPushRecord(
                db: db,
                entityId: sourceView.syncId,
                systemFields: nil
            ))
        }
        XCTAssertNotNil(record[DatabaseView.RecordField.scopeSyncJSON])
        XCTAssertNil(
            record[DatabaseView.RecordField.scopeJSON],
            "UUID dependencies must not overwrite a legacy peer's local-ID JSON"
        )

        let target = try AppDatabase(DatabaseQueue())
        var dummyTag = Tag(name: "dummy", color: "#000000")
        try target.saveTag(&dummyTag)
        var targetTag = Tag(
            syncId: sourceTag.syncId,
            name: "Portable tag",
            color: "#ff0000"
        )
        try target.saveTag(&targetTag)
        var dummyProperty = PropertyDefinition(
            name: "dummy property",
            type: .string
        )
        try target.savePropertyDefinition(&dummyProperty)
        var targetProperty = PropertyDefinition(
            syncId: sourceProperty.syncId,
            name: "Portable property",
            type: .string
        )
        try target.savePropertyDefinition(&targetProperty)
        let targetTagID = try XCTUnwrap(targetTag.id)
        let targetPropertyID = try XCTUnwrap(targetProperty.id)
        XCTAssertNotEqual(sourceTagID, targetTagID)
        XCTAssertNotEqual(sourcePropertyID, targetPropertyID)

        try target.dbWriter.write { db in
            let store = SyncStateStore()
            try store.setApplyingRemote(db)
            XCTAssertEqual(
                try SyncEntityType.databaseView.remoteDependencyStatus(
                    for: record,
                    entityId: sourceView.syncId,
                    db: db
                ),
                .ready
            )
            XCTAssertTrue(try SyncEntityType.databaseView.applyRemoteRecord(
                record,
                entityId: sourceView.syncId,
                db: db
            ))
            try store.clearApplyingRemote(db)

            let pulled = try XCTUnwrap(DatabaseView
                .filter(Column("syncId") == sourceView.syncId)
                .fetchOne(db))
            XCTAssertEqual(pulled.parsedScope, .tag(targetTagID))
            XCTAssertEqual(
                pulled.parsedFilters,
                [.init(
                    target: .builtin(.tags),
                    op: .isAnyOf,
                    value: .selectKeys([String(targetTagID)])
                )]
            )
            XCTAssertEqual(
                pulled.parsedSorts,
                [.init(target: .custom(targetPropertyID), ascending: true)]
            )
            XCTAssertEqual(
                pulled.parsedGroupBy,
                .init(
                    target: .builtin(.tags),
                    customOrder: [String(targetTagID)],
                    collapsed: [String(targetTagID)]
                )
            )
            XCTAssertEqual(
                pulled.parsedColumnWraps,
                ["custom_\(targetPropertyID)"]
            )
        }
    }

    func testPortableViewResolvesRetiredParentIdentityThroughAlias() throws {
        let source = try AppDatabase(DatabaseQueue())
        var retiredTag = Tag(syncId: "retired-tag", name: "Portable tag")
        try source.saveTag(&retiredTag)
        var sourceView = DatabaseView(
            syncId: "alias-view",
            name: "Aliased view",
            scope: .tag(try XCTUnwrap(retiredTag.id))
        )
        try source.saveDatabaseView(&sourceView)
        let record = try source.dbWriter.read { db in
            try XCTUnwrap(SyncEntityType.databaseView.buildPushRecord(
                db: db,
                entityId: sourceView.syncId,
                systemFields: nil
            ))
        }

        let target = try AppDatabase(DatabaseQueue())
        var winner = Tag(syncId: "winner-tag", name: "Portable tag")
        try target.saveTag(&winner)
        let winnerId = try XCTUnwrap(winner.id)
        try target.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO syncIdentityAlias(
                    entityType, losingId, winningId, createdAt
                ) VALUES('tag', 'retired-tag', 'winner-tag', ?)
                """, arguments: [Date()])
            let store = SyncStateStore()
            try store.setApplyingRemote(db)
            XCTAssertEqual(try SyncEntityType.databaseView.remoteDependencyStatus(
                for: record,
                entityId: sourceView.syncId,
                db: db
            ), .ready)
            XCTAssertTrue(try SyncEntityType.databaseView.applyRemoteRecord(
                record,
                entityId: sourceView.syncId,
                db: db
            ))
            try store.clearApplyingRemote(db)
        }

        let pulled = try target.dbWriter.read { db in
            try XCTUnwrap(DatabaseView
                .filter(Column("syncId") == sourceView.syncId)
                .fetchOne(db))
        }
        XCTAssertEqual(pulled.parsedScope, .tag(winnerId))
    }
}
#endif
