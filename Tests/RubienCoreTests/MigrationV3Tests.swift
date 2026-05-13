import XCTest
import GRDB
@testable import RubienCore

/// v3 (2026-05): Prune `ReferenceType` from 21 cases down to 6 (Journal Article,
/// Conference Paper, Book, Thesis, Web Page, Other) and capitalize lowercase
/// `readingStatus` raw values so they match the seeded PropertyDefinition labels.
///
/// The Type column stays a free-form TEXT — no schema change. The migration
/// rewrites column values in place, then refreshes the Type PropertyDefinition's
/// optionsJSON to advertise the new 6-option set.
final class MigrationV3Tests: XCTestCase {

    // Build a minimal v2-shaped DB with just the tables v3 touches:
    //   reference, propertyDefinition (the Type seed), syncSession (the
    //   `applyingRemote` guard that v3 toggles to suppress dirty triggers).
    private func makeV2ShapedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE reference (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    dateAdded TEXT NOT NULL,
                    dateModified TEXT NOT NULL,
                    referenceType TEXT NOT NULL DEFAULT 'Journal Article',
                    readingStatus TEXT NOT NULL DEFAULT 'unread',
                    verificationStatus TEXT NOT NULL DEFAULT 'legacy',
                    authorsNormalized TEXT NOT NULL DEFAULT ''
                )
            """)
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
            try db.execute(sql: """
                CREATE TABLE syncSession (
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
            """)
            // Seed the Type PropertyDefinition with the v1 21-option set
            // (only the values matter for the v3 rewrite assertion).
            let v1TypeOptionsJSON = #"""
                [{"value":"Journal Article","color":"#007AFF"},{"value":"Book","color":"#34C759"},{"value":"Book Section","color":"#00C7BE"},{"value":"Conference Paper","color":"#AF52DE"},{"value":"Preprint","color":"#5AC8FA"},{"value":"Thesis","color":"#FF9500"},{"value":"Report","color":"#A2845E"},{"value":"Web Page","color":"#30B0C7"},{"value":"Dataset","color":"#FFCC00"},{"value":"Software","color":"#BF5AF2"},{"value":"Patent","color":"#FF6482"},{"value":"Magazine Article","color":"#64D2FF"},{"value":"Newspaper Article","color":"#8E8E93"},{"value":"Standard","color":"#FF2D55"},{"value":"Manuscript","color":"#A2845E"},{"value":"Interview","color":"#FF3B30"},{"value":"Presentation","color":"#007AFF"},{"value":"Blog Post","color":"#34C759"},{"value":"Forum Post","color":"#5AC8FA"},{"value":"Legal Case","color":"#8E8E93"},{"value":"Legislation","color":"#FF9500"},{"value":"Other","color":"#8E8E93"}]
                """#
            try db.execute(sql: """
                INSERT INTO propertyDefinition(name, type, optionsJSON, sortOrder, isDefault, defaultFieldKey)
                VALUES ('Type', 'singleSelect', ?, 0, 1, 'referenceType')
            """, arguments: [v1TypeOptionsJSON])
        }
        return queue
    }

    /// Each of the 15 dropped types ends up at its target bucket per the migration map.
    func testV3RemapsAllDroppedReferenceTypes() throws {
        let queue = try makeV2ShapedQueue()

        // The migration map: every dropped raw value → its target.
        let mapping: [(from: String, to: String)] = [
            ("Magazine Article",  "Journal Article"),
            ("Newspaper Article", "Journal Article"),
            ("Preprint",          "Journal Article"),
            ("Book Section",      "Book"),
            ("Blog Post",         "Web Page"),
            ("Forum Post",        "Web Page"),
            ("Manuscript",        "Other"),
            ("Dataset",           "Other"),
            ("Software",          "Other"),
            ("Standard",          "Other"),
            ("Interview",         "Other"),
            ("Presentation",      "Other"),
            ("Report",            "Other"),
            ("Legal Case",        "Other"),
            ("Legislation",       "Other"),
            ("Patent",            "Other"),
        ]

        try queue.write { db in
            for (i, pair) in mapping.enumerated() {
                try db.execute(
                    sql: "INSERT INTO reference(id, title, dateAdded, dateModified, referenceType) VALUES(?, ?, ?, ?, ?)",
                    arguments: [i + 1, "ref-\(i)", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", pair.from]
                )
            }
        }

        try AppDatabase.runV3MigrationForTesting(on: queue)

        try queue.read { db in
            for (i, pair) in mapping.enumerated() {
                let actual = try String.fetchOne(
                    db,
                    sql: "SELECT referenceType FROM reference WHERE id = ?",
                    arguments: [i + 1]
                )
                XCTAssertEqual(
                    actual, pair.to,
                    "v3 must remap '\(pair.from)' → '\(pair.to)' (got '\(actual ?? "nil")' for ref id \(i + 1))"
                )
            }
        }
    }

    /// Surviving types are untouched.
    func testV3PreservesSurvivingReferenceTypes() throws {
        let queue = try makeV2ShapedQueue()
        let surviving = ["Journal Article", "Conference Paper", "Book", "Thesis", "Web Page", "Other"]

        try queue.write { db in
            for (i, value) in surviving.enumerated() {
                try db.execute(
                    sql: "INSERT INTO reference(id, title, dateAdded, dateModified, referenceType) VALUES(?, ?, ?, ?, ?)",
                    arguments: [i + 1, "ref-\(i)", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", value]
                )
            }
        }

        try AppDatabase.runV3MigrationForTesting(on: queue)

        try queue.read { db in
            for (i, value) in surviving.enumerated() {
                let actual = try String.fetchOne(
                    db,
                    sql: "SELECT referenceType FROM reference WHERE id = ?",
                    arguments: [i + 1]
                )
                XCTAssertEqual(actual, value, "surviving type '\(value)' must be untouched")
            }
        }
    }

    /// Lowercase legacy status values get capitalized to match the seeded labels
    /// so Phase 2 rename-by-label can find existing rows.
    func testV3CapitalizesLowercaseStatusValues() throws {
        let queue = try makeV2ShapedQueue()
        let pairs: [(from: String, to: String)] = [
            ("unread",   "Unread"),
            ("reading",  "Reading"),
            ("skimmed",  "Skimmed"),
            ("read",     "Read"),
        ]

        try queue.write { db in
            for (i, pair) in pairs.enumerated() {
                try db.execute(
                    sql: "INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus) VALUES(?, ?, ?, ?, ?)",
                    arguments: [i + 1, "ref-\(i)", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", pair.from]
                )
            }
        }

        try AppDatabase.runV3MigrationForTesting(on: queue)

        try queue.read { db in
            for (i, pair) in pairs.enumerated() {
                let actual = try String.fetchOne(
                    db,
                    sql: "SELECT readingStatus FROM reference WHERE id = ?",
                    arguments: [i + 1]
                )
                XCTAssertEqual(
                    actual, pair.to,
                    "v3 must capitalize legacy status '\(pair.from)' → '\(pair.to)'"
                )
            }
        }
    }

    /// Already-capitalized status values survive untouched (i.e. v3 is safe to
    /// re-run after Phase 2 if needed).
    func testV3LeavesAlreadyCapitalizedStatusAlone() throws {
        let queue = try makeV2ShapedQueue()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus) VALUES(1, 'r', ?, ?, 'Reading')",
                arguments: ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"]
            )
            // Custom statuses (added post-Phase-2) must not be normalized.
            try db.execute(
                sql: "INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus) VALUES(2, 'r', ?, ?, 'to-skim')",
                arguments: ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"]
            )
        }

        try AppDatabase.runV3MigrationForTesting(on: queue)

        try queue.read { db in
            let r1 = try String.fetchOne(db, sql: "SELECT readingStatus FROM reference WHERE id = 1")
            XCTAssertEqual(r1, "Reading", "already-capitalized values must not change")
            let r2 = try String.fetchOne(db, sql: "SELECT readingStatus FROM reference WHERE id = 2")
            XCTAssertEqual(r2, "to-skim", "v3 must only touch the 4 lowercase legacy values; custom values pass through")
        }
    }

    /// The Type PropertyDefinition's optionsJSON is rewritten to the 6-option set.
    func testV3UpdatesTypePropertyDefinitionOptions() throws {
        let queue = try makeV2ShapedQueue()
        try AppDatabase.runV3MigrationForTesting(on: queue)

        try queue.read { db in
            let rawJSON = try String.fetchOne(
                db,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey = 'referenceType'"
            )
            XCTAssertNotNil(rawJSON, "Type PropertyDefinition must exist after v3")
            let data = rawJSON!.data(using: .utf8)!
            let options = try JSONDecoder().decode([SelectOption].self, from: data)

            XCTAssertEqual(options.count, 6, "Type must have exactly 6 options post-v3")
            XCTAssertEqual(
                options.map(\.value),
                ["Journal Article", "Conference Paper", "Book", "Thesis", "Web Page", "Other"],
                "Type options must be exactly the 6-bucket set in canonical order"
            )
            // Every option must carry a non-empty color (UI gates on this for chip rendering).
            for opt in options {
                XCTAssertFalse(opt.color.isEmpty, "option '\(opt.value)' must have a color assigned")
            }
        }
    }

    /// Running v3 twice on the same DB is a no-op the second time. Important
    /// because `DatabaseMigrator` will refuse to re-run a registered migration,
    /// but the test helper builds an isolated migrator each call — so we simulate
    /// "v3 already ran" by running v3 twice via two separate helper invocations.
    /// The migration body itself must be idempotent.
    func testV3IsIdempotent() throws {
        let queue = try makeV2ShapedQueue()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO reference(id, title, dateAdded, dateModified, referenceType, readingStatus) VALUES(1, 'r', ?, ?, 'Software', 'unread')",
                arguments: ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"]
            )
        }

        try AppDatabase.runV3MigrationForTesting(on: queue)
        try AppDatabase.runV3MigrationForTesting(on: queue)

        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT referenceType, readingStatus FROM reference WHERE id = 1")!
            XCTAssertEqual(row["referenceType"] as String?, "Other")
            XCTAssertEqual(row["readingStatus"] as String?, "Unread")
            // Type PropertyDefinition still has 6 options (not 12).
            let rawJSON = try String.fetchOne(
                db,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey = 'referenceType'"
            )!
            let options = try JSONDecoder().decode([SelectOption].self, from: rawJSON.data(using: .utf8)!)
            XCTAssertEqual(options.count, 6, "re-running v3 must not duplicate options")
        }
    }

}
