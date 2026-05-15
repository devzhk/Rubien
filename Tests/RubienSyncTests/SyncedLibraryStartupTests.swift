#if canImport(RubienSync)
import XCTest
import CloudKit
import GRDB
@testable import RubienCore
@testable import RubienSync

/// Exercises `SyncedLibrary.start()` side effects that don't require a
/// real CKContainer: the baseline one-shot and tombstone compaction. The
/// engine itself isn't contacted in these tests — we read the resulting
/// `syncState` / `syncSession` / `tombstone` rows to verify behavior.
@available(macOS 14.0, iOS 17.0, *)
final class SyncedLibraryStartupTests: XCTestCase {

    private var db: AppDatabase!
    private var stateFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
        stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-test-engine-\(UUID().uuidString).bin")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateFile)
        db = nil
        super.tearDown()
    }

    // MARK: - Baseline one-shot

    func testBaselineMarksAllSeedRowsDirtyOnFirstRun() async throws {
        // Migration already seeds 28 property definitions and 1 default
        // databaseView. After baseline, every one of those should be
        // dirty.
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )

        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")  // clear migration-time trigger noise
            try db.execute(sql: "DELETE FROM syncSession")
        }

        await library.performInitialBaselineIfNeeded()

        let (propertyCount, viewCount, sessionValue) = try await db.dbWriter.read { db in
            let props = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState WHERE entityType='propertyDefinition' AND isDirty=1
                """) ?? 0
            let views = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState WHERE entityType='databaseView' AND isDirty=1
                """) ?? 0
            let state = try String.fetchOne(db, sql: """
                SELECT value FROM syncSession WHERE key='baselineState'
                """)
            return (props, views, state)
        }

        XCTAssertEqual(propertyCount, 30, "all 30 seeded property definitions (v1: 28 + v5: 2) must be marked dirty")
        XCTAssertEqual(viewCount, 1, "seeded default view must be marked dirty")
        XCTAssertEqual(sessionValue, "complete", "baselineState must be gated after first run")
    }

    func testBaselineIsOneShot() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )

        await library.performInitialBaselineIfNeeded()

        // Second invocation must be a no-op (no new syncState rows, no
        // INSERT attempts on already-dirty rows). We prove it by manually
        // clearing dirty and re-running — if it weren't gated, baseline
        // would re-dirty everything.
        try await db.dbWriter.write { db in
            try db.execute(sql: "UPDATE syncState SET isDirty = 0")
        }

        await library.performInitialBaselineIfNeeded()

        let stillClean = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE isDirty=1") ?? -1
        }
        XCTAssertEqual(
            stillClean,
            0,
            "second baseline must not re-mark rows — baselineState guard protects against re-runs"
        )
    }

    // MARK: - Tombstone compaction

    func testCompactStaleTombstonesDropsOldConfirmedRows() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile
        )
        let store = SyncStateStore()

        try await db.dbWriter.write { db in
            try store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "ancient-confirmed",
                deletedAt: Date(timeIntervalSince1970: 1_000_000),
                confirmedByServer: true
            )
            try store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "ancient-unconfirmed",
                deletedAt: Date(timeIntervalSince1970: 1_000_000),
                confirmedByServer: false
            )
            try store.upsertTombstone(
                db,
                entityType: .reference,
                entityId: "fresh-confirmed",
                deletedAt: Date(),
                confirmedByServer: true
            )
        }

        await library.compactStaleTombstones()

        let surviving = try await db.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT entityId FROM tombstone ORDER BY entityId")
        }
        XCTAssertEqual(
            surviving,
            ["ancient-unconfirmed", "fresh-confirmed"],
            "compaction evicts only server-confirmed deletes past the 30-day window"
        )
    }
}

#endif
