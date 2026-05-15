#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Exercises the Task-14 drainer that bridges the local-only
/// `pdfUploadQueue` actor to the engine's pending-changes pipeline.
///
/// XCTest runs unentitled, so touching `CKSyncEngine.state` (which the
/// public `drainPDFUploadQueue()` does after the DB writes) raises
/// `CKException`. We split that engine.state.add step into the public
/// method and exercise the DB-only half via the internal
/// `drainPDFUploadQueueIntoSyncState()` helper. The flag-off / empty-queue
/// cases short-circuit before any engine access and are safe to call
/// through the public entrypoint.
///
/// We assert the DB invariants: drainer marks `referencePDF` rows dirty
/// in `syncState` (so the existing startup-reconciliation pipeline
/// rediscovers them even if the engine drops the in-flight push) and
/// clears `pdfUploadQueue` rows in the same transaction.
@available(macOS 14.0, iOS 17.0, *)
final class PDFUploadDrainerTests: XCTestCase {

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

    // MARK: - Flag-off behavior

    func testDrainSkipsWhenFlagOff() async throws {
        // Seed a queued row.
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified)
                VALUES(1, 'r', ?, ?)
            """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                VALUES(1, 'a.pdf', ?)
            """, arguments: [Date()])
        }

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile,
            pdfAssetSyncEnabledProvider: { false }
        )
        await library.drainPDFUploadQueue()

        // Queue row must still be present — drainer is a no-op while the
        // feature flag is off (the gate that holds C2→C5 in dark launch).
        let count = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? -1
        }
        XCTAssertEqual(count, 1, "drainer must skip when flag is off")

        // syncState must not have a referencePDF dirty row created by us.
        // (The migration won't seed one — pdfCache row was never inserted.)
        let dirty = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE entityType='referencePDF' AND entityId='1' AND isDirty=1
            """) ?? -1
        }
        XCTAssertEqual(dirty, 0, "drainer must not mark dirty when flag is off")
    }

    // MARK: - Flag-on behavior

    func testDrainMarksReferencePDFDirtyAndClearsQueueWhenFlagOn() async throws {
        try await db.dbWriter.write { db in
            for i: Int64 in [1, 2] {
                try db.execute(sql: """
                    INSERT INTO reference(id, title, dateAdded, dateModified)
                    VALUES(?, 'r', ?, ?)
                """, arguments: [i, Date(), Date()])
                try db.execute(sql: """
                    INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                    VALUES(?, ?, ?)
                """, arguments: [i, "f\(i).pdf", Date()])
                try db.execute(sql: """
                    INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                    VALUES(?, ?, 'h', 1, ?, ?)
                """, arguments: [i, "f\(i).pdf", Date(), Date()])
            }
            // Clear out any syncState rows that the v2-backfill insertion
            // may have triggered (we want a clean slate for the assertion).
            try db.execute(sql: "DELETE FROM syncState WHERE entityType='referencePDF'")
        }

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile,
            pdfAssetSyncEnabledProvider: { true }
        )
        // Use the DB-only helper so we don't trigger CKSyncEngine init in
        // an unentitled XCTest process.
        let drained = await library.drainPDFUploadQueueIntoSyncState()
        XCTAssertEqual(drained.sorted(), [1, 2], "drainer returns the IDs it processed")

        // Queue must be empty — drainer eagerly removes after marking the
        // syncState row dirty. The dirty row is the durable "needs push"
        // marker: if the engine drops the in-flight push, startup
        // reconciliation will rediscover it on next launch.
        let queueCount = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? -1
        }
        XCTAssertEqual(queueCount, 0, "drainer must clear queue when enabled")

        // Both referencePDF entries must now be dirty in syncState.
        let dirtyIds = try await db.dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT entityId FROM syncState
                WHERE entityType='referencePDF' AND isDirty=1
                ORDER BY entityId
            """)
        }
        XCTAssertEqual(
            dirtyIds, ["1", "2"],
            "both referencePDF rows must be marked dirty so the engine — or, on engine drop, the next startup reconciliation — picks them up"
        )
    }

    func testDrainIsIdempotentOnEmptyQueue() async throws {
        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile,
            pdfAssetSyncEnabledProvider: { true }
        )
        // First call on an empty queue must succeed silently.
        await library.drainPDFUploadQueue()
        // Second call must also succeed (no double-state, no errors).
        await library.drainPDFUploadQueue()

        let queueCount = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? -1
        }
        XCTAssertEqual(queueCount, 0)
    }

    /// Calling drain twice for the same row must not re-mark or
    /// double-process. The first call moves the row out of pdfUploadQueue
    /// and into syncState dirty. The second call sees an empty queue and
    /// no-ops — the existing dirty row is left alone (the engine handles
    /// dedup on its side via `pendingRecordZoneChanges`).
    func testDrainTwiceForSameRowDoesNotDoublePush() async throws {
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified)
                VALUES(1, 'r', ?, ?)
            """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                VALUES(1, 'a.pdf', ?)
            """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(1, 'a.pdf', 'h', 1, ?, ?)
            """, arguments: [Date(), Date()])
            try db.execute(sql: "DELETE FROM syncState WHERE entityType='referencePDF'")
        }

        let library = SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFile,
            pdfAssetSyncEnabledProvider: { true }
        )
        let firstPass = await library.drainPDFUploadQueueIntoSyncState()
        XCTAssertEqual(firstPass, [1])
        let secondPass = await library.drainPDFUploadQueueIntoSyncState()
        XCTAssertEqual(secondPass, [], "second drain on the now-empty queue must return nothing")

        let dirtyCount = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE entityType='referencePDF' AND entityId='1' AND isDirty=1
            """) ?? -1
        }
        XCTAssertEqual(dirtyCount, 1, "second drain on the now-empty queue must not insert a duplicate row")
    }
}
#endif
