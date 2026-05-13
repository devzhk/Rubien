import XCTest
import Foundation
import GRDB
@testable import RubienCore

final class SyncStatusCommandTests: XCTestCase {

    private var cliURL: URL {
        URL(fileURLWithPath: ".build/debug/rubien-cli")
    }

    func testSyncStatusReturnsJSONWithExpectedFields() throws {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["sync", "status"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)

        // Required fields per spec.
        for key in [
            "enabled", "containerIdentifier", "entitlementPresent",
            "iCloudAccountAvailable", "appLockHeld", "baselineState",
            "dirtyByEntityType", "tombstoneCount", "syncEngineState",
            "schemaVersion"
        ] {
            XCTAssertNotNil(json?[key], "missing field '\(key)' in JSON output")
        }

        // schemaVersion must reflect the current AppDatabase migration tag.
        XCTAssertEqual(json?["schemaVersion"] as? String, "v5",
                       "schemaVersion should match AppDatabase.currentSchemaVersion")
    }

    /// Regression test for the B8 review finding: `pdfBackfillRemaining`
    /// must count `syncState` rows with `entityType='referencePDF' AND
    /// isDirty=1`, NOT `pdfUploadQueue` rows. The queue empties at
    /// drainer hand-off — long before CKSyncEngine confirms the upload
    /// — so the prior measure under-reported in-flight work.
    ///
    /// Uses `RUBIEN_LIBRARY_ROOT` to point the CLI subprocess at an
    /// isolated temp directory; otherwise the test would race against
    /// (and lie about) the dev's real library.
    func testSyncStatusPdfBackfillRemainingCountsDirtyReferencePDFSyncState() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // Stand up a fresh DB at the tmp location via AppDatabase migrator
        // (so the schema matches what the CLI expects), seed one dirty
        // referencePDF syncState row, then release the pool so the CLI
        // subprocess can open the same SQLite file.
        let dbPath = tmpRoot.appendingPathComponent("library.sqlite").path
        do {
            let pool = try DatabasePool(path: dbPath)
            let appDB = try AppDatabase(pool)
            try appDB.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                    VALUES('referencePDF', '42', 1, 0)
                """)
                // pdfUploadQueue intentionally empty: this is the post-drainer-
                // handoff state where the prior implementation reported 0 even
                // though the engine hadn't actually pushed yet.
            }
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["sync", "status"]
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = tmpRoot.path
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("CLI did not emit valid JSON")
            return
        }

        XCTAssertEqual(json["pdfBackfillRemaining"] as? Int, 1,
                       "pdfBackfillRemaining must count dirty referencePDF syncState rows, not pdfUploadQueue rows")

        // Sanity: dirtyByEntityType already counts the same thing via the
        // entity-type loop. Both should agree.
        let dirty = json["dirtyByEntityType"] as? [String: Int]
        XCTAssertEqual(dirty?["referencePDF"], 1)
    }
}
