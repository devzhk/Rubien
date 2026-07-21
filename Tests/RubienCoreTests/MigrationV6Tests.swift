import XCTest
import GRDB
@testable import RubienCore

final class MigrationV6Tests: XCTestCase {

    /// The `currentSchemaVersion` constant must track the latest registered
    /// migration (v9). Its value surfaces in `rubien-cli sync status` JSON.
    func testCurrentSchemaVersionIsV9() throws {
        XCTAssertEqual(AppDatabase.currentSchemaVersion, "v9")
    }

    /// The realistic v5-era six-option state (v3 prune output), plus one
    /// forward-compat unknown field that must survive structurally.
    private let sixOptionsJSON = ##"[{"value":"Journal Article","color":"#007AFF"},{"value":"Conference Paper","color":"#AF52DE"},{"value":"Book","color":"#34C759"},{"value":"Thesis","color":"#FF9500"},{"value":"Web Page","color":"#30B0C7"},{"value":"Other","color":"#8E8E93","futureField":"keep-me"}]"##

    private func typeOptionsJSON(_ db: AppDatabase) throws -> String {
        try db.dbWriter.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey = 'referenceType'"
            ) ?? ""
        }
    }

    private func markdownCount(in json: String) -> Int {
        json.components(separatedBy: "\"Markdown\"").count - 1
    }

    /// Sets the Type options fixture WITHOUT leaving dirty syncState behind:
    /// the fixture write itself trips the dirty trigger, so clear syncState
    /// afterwards — the assertions must observe only the subject under test.
    private func setTypeOptionsFixture(_ db: AppDatabase, json: String) throws {
        try db.dbWriter.write { d in
            try d.execute(
                sql: "UPDATE propertyDefinition SET optionsJSON = ? WHERE defaultFieldKey = 'referenceType'",
                arguments: [json]
            )
            try d.execute(sql: "DELETE FROM syncState", arguments: [])
        }
    }

    private func typeDefinitionId(_ db: AppDatabase) throws -> Int64 {
        try db.dbWriter.read { d in
            try Int64.fetchOne(
                d,
                sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey = 'referenceType'"
            ) ?? -1
        }
    }

    func testFreshDatabaseHasMarkdownOptionOnce() throws {
        let db = try AppDatabase(DatabaseQueue())
        XCTAssertEqual(markdownCount(in: try typeOptionsJSON(db)), 1)
    }

    func testAppendIsIdempotentAndPreservesExistingOptions() throws {
        let db = try AppDatabase(DatabaseQueue())
        try setTypeOptionsFixture(db, json: sixOptionsJSON)
        guard let queue = db.dbWriter as? DatabaseQueue else { return XCTFail("expected queue") }

        try AppDatabase.runV6MigrationForTesting(on: queue)
        var json = try typeOptionsJSON(db)
        XCTAssertEqual(markdownCount(in: json), 1)
        XCTAssertTrue(json.contains("Journal Article"), "existing options preserved")
        XCTAssertTrue(json.contains("#30B0C7"), "existing colors preserved")
        XCTAssertTrue(json.contains("futureField"), "unknown JSON fields preserved")

        try AppDatabase.runV6MigrationForTesting(on: queue)   // idempotence
        json = try typeOptionsJSON(db)
        XCTAssertEqual(markdownCount(in: json), 1)
    }

    func testMalformedOptionsJSONLeftUntouched() throws {
        let db = try AppDatabase(DatabaseQueue())
        try setTypeOptionsFixture(db, json: "not json")
        guard let queue = db.dbWriter as? DatabaseQueue else { return XCTFail("expected queue") }
        try AppDatabase.runV6MigrationForTesting(on: queue)
        XCTAssertEqual(try typeOptionsJSON(db), "not json", "fail-safe no-op on undecodable data")
    }

    /// The applyingRemote guard must suppress dirty-tracking for the Type row:
    /// migrations are local normalization, not user edits.
    func testMigrationEmitsNoDirtySyncStateForTypeRow() throws {
        let db = try AppDatabase(DatabaseQueue())
        try setTypeOptionsFixture(db, json: sixOptionsJSON)   // also clears syncState
        guard let queue = db.dbWriter as? DatabaseQueue else { return XCTFail("expected queue") }
        try AppDatabase.runV6MigrationForTesting(on: queue)

        let typeId = try typeDefinitionId(db)
        let dirty = try db.dbWriter.read { d in
            try Int.fetchOne(
                d,
                sql: """
                    SELECT COUNT(*) FROM syncState
                    WHERE entityType = 'propertyDefinition' AND entityId = ? AND isDirty = 1
                    """,
                arguments: [String(typeId)]
            ) ?? 0
        }
        XCTAssertEqual(dirty, 0)
    }
}
