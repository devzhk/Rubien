import XCTest
import GRDB
@testable import RubienCore

/// v5 (2026-05): seed PropertyDefinitions for the v4 reader-activity columns
/// (`lastReadAt` and `readCount`) so they surface in the Property Manager,
/// the column-visibility picker, and the detail view's property list.
final class MigrationV5Tests: XCTestCase {

    /// Build a minimal v4-shaped `propertyDefinition` table — just the
    /// columns the v5 INSERT touches, plus the UNIQUE(name) constraint that
    /// makes `INSERT OR IGNORE` idempotent.
    private func makeV4ShapedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE propertyDefinition (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE,
                    type TEXT NOT NULL,
                    optionsJSON TEXT NOT NULL DEFAULT '[]',
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    isDefault INTEGER NOT NULL DEFAULT 0,
                    defaultFieldKey TEXT,
                    isVisible INTEGER NOT NULL DEFAULT 1,
                    dateModified TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
                )
            """)
            // Seed a handful of pre-existing rows so sortOrder ends up after them.
            try db.execute(
                sql: "INSERT INTO propertyDefinition(name, type, sortOrder, isDefault, defaultFieldKey, isVisible) VALUES (?, ?, ?, 1, ?, 1)",
                arguments: ["Type", "singleSelect", 0, "referenceType"]
            )
            try db.execute(
                sql: "INSERT INTO propertyDefinition(name, type, sortOrder, isDefault, defaultFieldKey, isVisible) VALUES (?, ?, ?, 1, ?, 0)",
                arguments: ["PMID", "string", 27, "pmid"]
            )
        }
        return queue
    }

    func testV5SeedsLastReadPropertyDefinition() throws {
        let queue = try makeV4ShapedQueue()
        try AppDatabase.runV5MigrationForTesting(on: queue)

        try queue.read { db in
            let row = try XCTUnwrap(
                try Row.fetchOne(
                    db,
                    sql: "SELECT name, type, isDefault, defaultFieldKey, isVisible FROM propertyDefinition WHERE defaultFieldKey = ?",
                    arguments: ["lastReadAt"]
                )
            )
            XCTAssertEqual(row["name"] as String?, "Last Read")
            XCTAssertEqual(row["type"] as String?, PropertyType.date.rawValue)
            XCTAssertEqual(row["isDefault"] as Int?, 1, "v5 seeds must be flagged isDefault=1")
            XCTAssertEqual(row["isVisible"] as Int?, 0, "v5 seeds must be hidden by default (user opts in)")
        }
    }

    func testV5SeedsReadCountPropertyDefinition() throws {
        let queue = try makeV4ShapedQueue()
        try AppDatabase.runV5MigrationForTesting(on: queue)

        try queue.read { db in
            let row = try XCTUnwrap(
                try Row.fetchOne(
                    db,
                    sql: "SELECT name, type, isDefault, defaultFieldKey, isVisible FROM propertyDefinition WHERE defaultFieldKey = ?",
                    arguments: ["readCount"]
                )
            )
            XCTAssertEqual(row["name"] as String?, "Read Count")
            XCTAssertEqual(row["type"] as String?, PropertyType.number.rawValue)
            XCTAssertEqual(row["isDefault"] as Int?, 1)
            XCTAssertEqual(row["isVisible"] as Int?, 0)
        }
    }

    /// Re-running v5 must not duplicate rows — `INSERT OR IGNORE` on the
    /// UNIQUE(name) constraint guarantees idempotency.
    func testV5IsIdempotent() throws {
        let queue = try makeV4ShapedQueue()
        try AppDatabase.runV5MigrationForTesting(on: queue)
        try AppDatabase.runV5MigrationForTesting(on: queue)

        try queue.read { db in
            let lastRead = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM propertyDefinition WHERE defaultFieldKey = 'lastReadAt'"
            )
            let readCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM propertyDefinition WHERE defaultFieldKey = 'readCount'"
            )
            XCTAssertEqual(lastRead, 1, "re-running v5 must not insert a duplicate Last Read row")
            XCTAssertEqual(readCount, 1, "re-running v5 must not insert a duplicate Read Count row")
        }
    }

    /// If a user already has a custom property called "Last Read" (rare but
    /// possible — name is the only matching key), v5 must NOT clobber it.
    /// `INSERT OR IGNORE` silently skips the seeded row in that case.
    func testV5DoesNotClobberPreExistingNamedRow() throws {
        let queue = try makeV4ShapedQueue()
        let userSortOrder = 99
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO propertyDefinition(name, type, sortOrder, isDefault, defaultFieldKey, isVisible) VALUES (?, ?, ?, 0, NULL, 1)",
                arguments: ["Last Read", "string", userSortOrder]
            )
        }

        try AppDatabase.runV5MigrationForTesting(on: queue)

        try queue.read { db in
            let row = try XCTUnwrap(
                try Row.fetchOne(
                    db,
                    sql: "SELECT type, isDefault, defaultFieldKey, sortOrder FROM propertyDefinition WHERE name = ?",
                    arguments: ["Last Read"]
                )
            )
            // Pre-existing row survives unchanged — its user-set fields remain.
            XCTAssertEqual(row["type"] as String?, "string", "user's custom Last Read type must survive")
            XCTAssertEqual(row["isDefault"] as Int?, 0, "user's custom row must stay non-default")
            XCTAssertNil(row["defaultFieldKey"] as String?, "user's custom row must keep its NULL fieldKey")
            XCTAssertEqual(row["sortOrder"] as Int?, userSortOrder, "user's custom row keeps its sortOrder")
        }
    }

    /// Full migration through AppDatabase produces a v5 schema and the
    /// `currentSchemaVersion` constant matches.
    func testCurrentSchemaVersionIsV5() throws {
        XCTAssertEqual(AppDatabase.currentSchemaVersion, "v5")
    }

    /// Full-stack migration seeds both new PropertyDefinitions alongside the
    /// existing v1 defaults.
    func testFullStackMigrationProducesV5PropertyDefinitions() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let fieldKeys: [String] = try String.fetchAll(
                db,
                sql: "SELECT defaultFieldKey FROM propertyDefinition WHERE defaultFieldKey IS NOT NULL"
            )
            XCTAssertTrue(fieldKeys.contains("lastReadAt"), "Last Read must be seeded after a full migration")
            XCTAssertTrue(fieldKeys.contains("readCount"), "Read Count must be seeded after a full migration")
        }
    }
}
