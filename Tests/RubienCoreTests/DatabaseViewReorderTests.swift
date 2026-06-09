import XCTest
import GRDB
@testable import RubienCore

/// Coverage for `AppDatabase.reorderDatabaseViews` — the persistence half of the
/// sidebar drag-to-reorder feature: order rewrite, sync dirty-tracking, the
/// only-touch-moved-rows no-op guard, and that user reordering never disturbs the
/// migration-seeded default ("All References") view.
final class DatabaseViewReorderTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    @discardableResult
    private func seedView(_ db: AppDatabase, name: String, displayOrder: Int) throws -> DatabaseView {
        var view = DatabaseView(name: name, isDefault: false, displayOrder: displayOrder)
        try db.saveDatabaseView(&view)
        return view
    }

    private func isDirty(_ db: AppDatabase, entityId: Int64) throws -> Int? {
        try db.dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT isDirty FROM syncState WHERE entityType = 'databaseView' AND entityId = ?",
                arguments: [String(entityId)]
            )
        }
    }

    /// Simulate a clean post-push state so a later reorder's re-dirtying is observable.
    private func clearDirty(_ db: AppDatabase) throws {
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE syncState SET isDirty = 0")
        }
    }

    // MARK: - Happy path

    func testReorderRewritesDisplayOrderAndMarksDirty() throws {
        let db = try makeDatabase()
        let a = try seedView(db, name: "A", displayOrder: 1)
        let b = try seedView(db, name: "B", displayOrder: 2)
        let c = try seedView(db, name: "C", displayOrder: 3)
        try clearDirty(db)

        // Full reversal so every row actually moves.
        try db.reorderDatabaseViews([c.id!, b.id!, a.id!])

        let userViews = try db.fetchAllDatabaseViews().filter { !$0.isDefault }
        XCTAssertEqual(userViews.map(\.name), ["C", "B", "A"])
        XCTAssertEqual(userViews.map(\.displayOrder), [0, 1, 2])
        for v in [a, b, c] {
            XCTAssertEqual(try isDirty(db, entityId: v.id!), 1, "\(v.name) should be dirtied by reorder")
        }
    }

    // MARK: - No-op guard (displayOrder <> ? )

    func testReorderWithUnchangedOrderIsNoOp() throws {
        let db = try makeDatabase()
        let a = try seedView(db, name: "A", displayOrder: 0)
        let b = try seedView(db, name: "B", displayOrder: 1)
        let c = try seedView(db, name: "C", displayOrder: 2)
        let modifiedBefore = try db.fetchDatabaseView(id: b.id!)!.dateModified
        try clearDirty(db)

        try db.reorderDatabaseViews([a.id!, b.id!, c.id!])  // already in this order

        for v in [a, b, c] {
            XCTAssertEqual(try isDirty(db, entityId: v.id!), 0, "no row may be dirtied when nothing moves")
        }
        XCTAssertEqual(
            try db.fetchDatabaseView(id: b.id!)!.dateModified, modifiedBefore,
            "dateModified must not churn on a no-op reorder"
        )
    }

    // MARK: - Edge cases

    func testReorderEmptyIsNoOp() throws {
        let db = try makeDatabase()
        XCTAssertNoThrow(try db.reorderDatabaseViews([]))
    }

    func testReorderSingleView() throws {
        let db = try makeDatabase()
        let only = try seedView(db, name: "Only", displayOrder: 1)
        try clearDirty(db)

        try db.reorderDatabaseViews([only.id!])  // moves 1 -> 0

        XCTAssertEqual(try db.fetchDatabaseView(id: only.id!)!.displayOrder, 0)
        XCTAssertEqual(try isDirty(db, entityId: only.id!), 1)
    }

    // MARK: - Default view isolation + deterministic tie-break

    func testReorderLeavesDefaultViewUntouched() throws {
        let db = try makeDatabase()
        let defaultBefore = try db.fetchDefaultDatabaseView()!
        let a = try seedView(db, name: "A", displayOrder: 1)
        let b = try seedView(db, name: "B", displayOrder: 2)
        try clearDirty(db)

        try db.reorderDatabaseViews([b.id!, a.id!])  // B -> 0 (A stays at 1)

        let defaultAfter = try db.fetchDefaultDatabaseView()!
        XCTAssertEqual(defaultAfter.displayOrder, defaultBefore.displayOrder, "default displayOrder unchanged")
        XCTAssertEqual(defaultAfter.dateModified, defaultBefore.dateModified, "default dateModified unchanged")
        XCTAssertNotEqual(try isDirty(db, entityId: defaultAfter.id!), 1, "default view must not be dirtied")

        // B now collides with the default at displayOrder 0; the (displayOrder, id)
        // tie-breaker must still produce a deterministic, stable total order.
        let all = try db.fetchAllDatabaseViews()
        XCTAssertEqual(all.map(\.name), ["All References", "B", "A"])
    }
}
