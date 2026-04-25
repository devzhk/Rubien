import XCTest
import GRDB
@testable import RubienCore

/// Exercises `AppDatabase.migrateLegacyLibraryIfNeeded` with injectable
/// legacy roots so the real `~/Library/...` paths are never touched.
final class AppDatabaseMigrationTests: XCTestCase {

    private var sandboxRoot: URL!
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandboxRoot = fm.temporaryDirectory
            .appendingPathComponent("RubienMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: sandboxRoot)
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// Writes a non-empty SQLite DB plus the expected sidecar files at the
    /// given root. Returns the root URL for convenience.
    @discardableResult
    private func seedLegacyLibrary(at root: URL, titleMarker: String = "Legacy Title") throws -> URL {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("library.sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE marker (id INTEGER PRIMARY KEY, title TEXT)")
            try db.execute(sql: "INSERT INTO marker (title) VALUES (?)", arguments: [titleMarker])
        }
        // Close the pool so the migration can open its own handle later.
        // DatabasePool deallocates when it goes out of scope.

        try Data("sync-state-bytes".utf8).write(to: root.appendingPathComponent("sync-engine-state.bin"))
        try fm.createDirectory(at: root.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
        try Data("fake-pdf".utf8).write(to: root.appendingPathComponent("PDFs/paper.pdf"))
        try fm.createDirectory(at: root.appendingPathComponent("MetadataArtifacts"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("MetadataArtifacts/probe.json"))
        return root
    }

    private func readMarkerTitle(at dbURL: URL) throws -> String? {
        let pool = try DatabasePool(path: dbURL.path)
        return try pool.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM marker LIMIT 1")
        }
    }

    // MARK: Tests

    func testNoOpWhenDestinationAlreadyHasLibrary() throws {
        let destination = sandboxRoot.appendingPathComponent("dest", isDirectory: true)
        try seedLegacyLibrary(at: destination, titleMarker: "Destination")

        // Even with a legacy source present, existing destination wins.
        let legacy = sandboxRoot.appendingPathComponent("legacy", isDirectory: true)
        try seedLegacyLibrary(at: legacy, titleMarker: "Legacy")

        AppDatabase.migrateLegacyLibraryIfNeeded(destination: destination, legacyRoots: [legacy])

        let title = try readMarkerTitle(at: destination.appendingPathComponent("library.sqlite"))
        XCTAssertEqual(title, "Destination", "Existing destination DB must not be overwritten")
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("library.sqlite").path),
                      "Legacy source must remain untouched when destination exists")
    }

    func testMigratesForwardFromLegacyRoot() throws {
        let destination = sandboxRoot.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let legacy = sandboxRoot.appendingPathComponent("legacy", isDirectory: true)
        try seedLegacyLibrary(at: legacy, titleMarker: "Migrated")

        AppDatabase.migrateLegacyLibraryIfNeeded(destination: destination, legacyRoots: [legacy])

        let dstDB = destination.appendingPathComponent("library.sqlite")
        XCTAssertTrue(fm.fileExists(atPath: dstDB.path), "Destination library.sqlite must exist post-migration")
        XCTAssertEqual(try readMarkerTitle(at: dstDB), "Migrated")

        // Sidecars moved.
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("sync-engine-state.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("PDFs/paper.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("MetadataArtifacts/probe.json").path))

        // Source cleaned up after successful migration.
        XCTAssertFalse(fm.fileExists(atPath: legacy.appendingPathComponent("library.sqlite").path),
                       "Source library.sqlite should be deleted once migration verifies")
        XCTAssertFalse(fm.fileExists(atPath: legacy.appendingPathComponent("PDFs/paper.pdf").path),
                       "Source sidecars should be deleted once migration verifies")

        // No staging leftovers.
        let stagingGlob = try fm.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".migrating") }
        XCTAssertTrue(stagingGlob.isEmpty, "No .migrating-<pid> scratch dir should remain")
    }

    func testPrefersFirstLegacyRootThatHasLibrary() throws {
        let destination = sandboxRoot.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let firstLegacy = sandboxRoot.appendingPathComponent("first", isDirectory: true)
        let secondLegacy = sandboxRoot.appendingPathComponent("second", isDirectory: true)
        try seedLegacyLibrary(at: firstLegacy, titleMarker: "FirstWin")
        try seedLegacyLibrary(at: secondLegacy, titleMarker: "SecondLoss")

        AppDatabase.migrateLegacyLibraryIfNeeded(
            destination: destination,
            legacyRoots: [firstLegacy, secondLegacy]
        )

        let title = try readMarkerTitle(at: destination.appendingPathComponent("library.sqlite"))
        XCTAssertEqual(title, "FirstWin", "First legacy root with library.sqlite must win")

        // Second legacy must still have its data — we never touched it.
        XCTAssertTrue(fm.fileExists(atPath: secondLegacy.appendingPathComponent("library.sqlite").path))
    }

    func testSkipsLegacyRootMissingLibrary() throws {
        let destination = sandboxRoot.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // First legacy exists but has no library.sqlite → skip.
        let emptyLegacy = sandboxRoot.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: emptyLegacy, withIntermediateDirectories: true)

        let realLegacy = sandboxRoot.appendingPathComponent("real", isDirectory: true)
        try seedLegacyLibrary(at: realLegacy, titleMarker: "RealLegacy")

        AppDatabase.migrateLegacyLibraryIfNeeded(
            destination: destination,
            legacyRoots: [emptyLegacy, realLegacy]
        )

        let title = try readMarkerTitle(at: destination.appendingPathComponent("library.sqlite"))
        XCTAssertEqual(title, "RealLegacy")
    }

    func testIsIdempotentAcrossRepeatedCalls() throws {
        let destination = sandboxRoot.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let legacy = sandboxRoot.appendingPathComponent("legacy", isDirectory: true)
        try seedLegacyLibrary(at: legacy, titleMarker: "Once")

        AppDatabase.migrateLegacyLibraryIfNeeded(destination: destination, legacyRoots: [legacy])
        // Seed a new legacy after migration; a second call must NOT overwrite.
        let lateLegacy = sandboxRoot.appendingPathComponent("late", isDirectory: true)
        try seedLegacyLibrary(at: lateLegacy, titleMarker: "LateShouldNotApply")
        AppDatabase.migrateLegacyLibraryIfNeeded(destination: destination, legacyRoots: [lateLegacy])

        let title = try readMarkerTitle(at: destination.appendingPathComponent("library.sqlite"))
        XCTAssertEqual(title, "Once", "Second call must be no-op when destination already has library.sqlite")
        XCTAssertTrue(fm.fileExists(atPath: lateLegacy.appendingPathComponent("library.sqlite").path),
                      "Second legacy must remain untouched")
    }

    func testSimulatedLostRaceLeavesExistingDestinationIntact() throws {
        // Simulate the "another process already completed" path by
        // pre-populating the destination with a library.sqlite that
        // different legacy data would otherwise overwrite.
        let destination = sandboxRoot.appendingPathComponent("dest", isDirectory: true)
        try seedLegacyLibrary(at: destination, titleMarker: "WinnerMarker")

        let legacy = sandboxRoot.appendingPathComponent("legacy", isDirectory: true)
        try seedLegacyLibrary(at: legacy, titleMarker: "LoserMarker")

        AppDatabase.migrateLegacyLibraryIfNeeded(destination: destination, legacyRoots: [legacy])

        // Destination still carries the "winner" data.
        let title = try readMarkerTitle(at: destination.appendingPathComponent("library.sqlite"))
        XCTAssertEqual(title, "WinnerMarker")

        // Legacy source remains untouched — we don't delete on a no-op exit.
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("library.sqlite").path),
                      "Legacy data must be preserved when migration is a no-op")
    }

    func testMigrationDoesNotRunWhenDestinationEqualsSource() throws {
        // If somehow destination == one of the legacy roots, the migration
        // must not try to copy files onto themselves.
        let shared = sandboxRoot.appendingPathComponent("shared", isDirectory: true)
        try seedLegacyLibrary(at: shared, titleMarker: "Shared")

        AppDatabase.migrateLegacyLibraryIfNeeded(destination: shared, legacyRoots: [shared])

        // The destination-exists guard short-circuits before the self-check,
        // but the test asserts the end state is intact either way.
        let title = try readMarkerTitle(at: shared.appendingPathComponent("library.sqlite"))
        XCTAssertEqual(title, "Shared")
    }
}
