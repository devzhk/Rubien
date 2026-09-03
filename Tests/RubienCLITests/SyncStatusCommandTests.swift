#if os(macOS)
import XCTest
import Foundation
import GRDB
@testable import RubienCore
import RubienSync

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
            "schemaVersion", "identity", "pdfMaterialization"
        ] {
            XCTAssertNotNil(json?[key], "missing field '\(key)' in JSON output")
        }

        // schemaVersion must reflect the current AppDatabase migration tag.
        XCTAssertEqual(json?["schemaVersion"] as? String, AppDatabase.currentSchemaVersion,
                       "schemaVersion should match AppDatabase.currentSchemaVersion")
        let identity = json?["identity"] as? [String: Any]
        XCTAssertEqual(
            identity?["identitySchemaVersion"] as? Int,
            SyncIdentityDiagnostics.identitySchemaVersion
        )
        XCTAssertTrue(json?["pdfMaterialization"] is NSNull)
    }

    func testSyncStatusCanOptInToPDFFileChecks() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-cli-pdf-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let dbPath = tmpRoot.appendingPathComponent("library.sqlite").path
        do {
            let pool = try DatabasePool(path: dbPath)
            let appDB = try AppDatabase(pool)
            try appDB.dbWriter.write { db in
                try db.execute(sql: "DELETE FROM syncState")
                try db.execute(sql: """
                    INSERT INTO reference(
                        syncId, title, dateAdded, dateModified
                    ) VALUES('pdf-check', 'PDF check', ?, ?)
                    """, arguments: [Date(), Date()])
                let referenceID = try XCTUnwrap(Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM reference WHERE syncId='pdf-check'"
                ))
                try db.execute(sql: """
                    INSERT INTO pdfCache(
                        referenceId, localFilename, contentHash,
                        assetVersion, materializedAt
                    ) VALUES(?, 'missing.pdf', 'hash', 1, ?)
                    """, arguments: [referenceID, Date()])
                try db.execute(sql: "DELETE FROM syncState")
                try db.execute(sql: """
                    INSERT INTO syncState(entityType, entityId, isDirty)
                    VALUES('referencePDF', 'pdf-check', 1)
                    """)
            }
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["sync", "status", "--check-pdf-files"]
        var environment = ProcessInfo.processInfo.environment
        environment["RUBIEN_LIBRARY_ROOT"] = tmpRoot.path
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let materialization = try XCTUnwrap(
            json["pdfMaterialization"] as? [String: Any]
        )
        XCTAssertEqual(materialization["checkedDirtyPDFCount"] as? Int, 1)
        XCTAssertEqual(materialization["missingFileCount"] as? Int, 1)
        let issues = try XCTUnwrap(materialization["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.first?["syncId"] as? String, "pdf-check")
        XCTAssertEqual(issues.first?["reason"] as? String, "missingFile")
    }

    func testPDFFileCheckFailsWhenLibraryCannotBeOpened() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rubien-cli-pdf-check-failure-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: tmpRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let blockedRoot = tmpRoot.appendingPathComponent("not-a-directory")
        try Data("file blocks library directory".utf8).write(to: blockedRoot)

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["sync", "status", "--check-pdf-files"]
        var environment = ProcessInfo.processInfo.environment
        environment["RUBIEN_LIBRARY_ROOT"] = blockedRoot.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(
            process.terminationStatus,
            0,
            "an explicit PDF audit must not fabricate a clean result"
        )
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

    func testAcknowledgeWriterUpgradeRequiresExactConfirmationAndPersistsAudit() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-cli-ack-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let dbPath = tmpRoot.appendingPathComponent("library.sqlite").path
        do {
            let pool = try DatabasePool(path: dbPath)
            _ = try AppDatabase(pool)
        }

        func run(_ confirmation: String) throws -> (Int32, Data, Data) {
            let process = Process()
            process.executableURL = cliURL
            process.arguments = [
                "sync", "acknowledge-writer-upgrade",
                "--confirm", confirmation,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["RUBIEN_LIBRARY_ROOT"] = tmpRoot.path
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                stdout.fileHandleForReading.readDataToEndOfFile(),
                stderr.fileHandleForReading.readDataToEndOfFile()
            )
        }

        let refused = try run("yes")
        XCTAssertNotEqual(refused.0, 0)

        let accepted = try run("ALL-WRITERS-UPGRADED")
        XCTAssertEqual(accepted.0, 0, String(data: accepted.2, encoding: .utf8) ?? "")
        let receipt = try JSONSerialization.jsonObject(with: accepted.1) as? [String: Any]
        XCTAssertEqual(receipt?["acknowledged"] as? Bool, true)

        let pool = try DatabasePool(path: dbPath)
        try pool.read { db in
            XCTAssertFalse(try SyncStateStore().writerUpgradeRequired(db))
            XCTAssertNotNil(try String.fetchOne(
                db,
                sql: "SELECT value FROM syncSession WHERE key='writerUpgradeAcknowledgedAt'"
            ))
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM syncSession WHERE key='writerUpgradeAcknowledgedSchemaVersion'"
                ),
                AppDatabase.currentSchemaVersion
            )
        }
    }

    func testAcknowledgeWriterUpgradeRefusesPreV13Library() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-cli-ack-v12-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let dbPath = tmpRoot.appendingPathComponent("library.sqlite").path
        do {
            let queue = try DatabaseQueue(path: dbPath)
            try AppDatabase.makeV12DatabaseForTesting(on: queue)
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = [
            "sync", "acknowledge-writer-upgrade",
            "--confirm", "ALL-WRITERS-UPGRADED",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["RUBIEN_LIBRARY_ROOT"] = tmpRoot.path
        process.environment = environment
        process.standardOutput = Pipe()
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(
            String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.contains("has not completed its v13 identity migration") == true
        )
        let verificationPool = try DatabasePool(path: dbPath)
        XCTAssertFalse(try verificationPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM syncSession
                    WHERE key = 'writerUpgradeAcknowledgedAt'
                )
                """) ?? true
        })
    }
}
#endif
