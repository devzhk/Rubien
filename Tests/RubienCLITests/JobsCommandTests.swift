import Foundation
import GRDB
import XCTest

final class JobsCommandTests: XCTestCase {
    private var cliBinaryPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/rubien-cli")
            .path
    }

    private lazy var testLibraryRoot: URL = {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rubien-jobs-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: testLibraryRoot)
        super.tearDown()
    }

    func testCreateListUpdateAndDeleteContract() throws {
        try skipIfBinaryMissing()
        let created = try runCLI([
            "jobs", "create",
            "--name", "Morning papers",
            "--prompt", "Find new papers",
            "--weekdays", "weekdays",
            "--time", "08:30",
            "--provider", "claude",
        ])
        XCTAssertEqual(created.exitCode, 0, created.stderr)
        let createdJSON = try object(created.stdout)
        let id = try XCTUnwrap(createdJSON["id"] as? String)
        XCTAssertEqual(createdJSON["localTime"] as? String, "08:30")
        XCTAssertEqual(createdJSON["weekdays"] as? [String], ["mon", "tue", "wed", "thu", "fri"])
        XCTAssertEqual(createdJSON["enabled"] as? Bool, true)

        let updated = try runCLI(["jobs", "update", id, "--enabled", "false"])
        XCTAssertEqual(updated.exitCode, 0, updated.stderr)
        XCTAssertEqual(try object(updated.stdout)["enabled"] as? Bool, false)

        let listed = try runCLI(["jobs", "list"])
        XCTAssertEqual(listed.exitCode, 0, listed.stderr)
        let rows = try array(listed.stdout)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as? String, id)

        let deleted = try runCLI(["jobs", "delete", id])
        XCTAssertEqual(deleted.exitCode, 0, deleted.stderr)
        XCTAssertEqual(try object(deleted.stdout)["deleted"] as? String, id)
    }

    func testRunsStartsEmptyAndInvalidTimeFails() throws {
        try skipIfBinaryMissing()
        let runs = try runCLI(["jobs", "runs"])
        XCTAssertEqual(runs.exitCode, 0, runs.stderr)
        XCTAssertTrue(try array(runs.stdout).isEmpty)

        let invalid = try runCLI([
            "jobs", "create",
            "--name", "Bad time",
            "--prompt", "Find papers",
            "--weekdays", "daily",
            "--time", "8am",
        ])
        XCTAssertNotEqual(invalid.exitCode, 0)
        XCTAssertTrue(invalid.stderr.contains("HH:mm"), invalid.stderr)
    }

    func testDeleteRunHidesTerminalHistoryAndClearsProviderLink() throws {
        try skipIfBinaryMissing()
        let created = try runCLI([
            "jobs", "create",
            "--name", "History",
            "--prompt", "Find papers",
            "--weekdays", "daily",
            "--time", "08:00",
        ])
        XCTAssertEqual(created.exitCode, 0, created.stderr)
        let jobID = try XCTUnwrap(try object(created.stdout)["id"] as? String)
        let runID = "run-to-delete"
        let databaseURL = testLibraryRoot.appendingPathComponent("library.sqlite")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduledJobRun (
                        id, jobId, trigger, occurrenceKey, scheduledFor,
                        startedAt, finishedAt, status, provider,
                        providerSessionId, isUnread
                    ) VALUES (?, ?, 'manual', 'manual/delete-test', ?, ?, ?,
                              'succeeded', 'claude', 'provider-session', 1)
                    """,
                arguments: [runID, jobID, Date(), Date(), Date()]
            )
        }

        let deleted = try runCLI(["jobs", "delete-run", runID])
        XCTAssertEqual(deleted.exitCode, 0, deleted.stderr)
        XCTAssertEqual(try object(deleted.stdout)["deletedRun"] as? String, runID)

        let runs = try runCLI(["jobs", "runs"])
        XCTAssertEqual(runs.exitCode, 0, runs.stderr)
        XCTAssertTrue(try array(runs.stdout).isEmpty)
        try queue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT hiddenAt, trigger, status, provider, providerSessionId, isUnread
                    FROM scheduledJobRun WHERE id = ?
                    """,
                arguments: [runID]
            ))
            XCTAssertNotNil(row["hiddenAt"] as Date?)
            XCTAssertEqual(row["trigger"] as String?, "deleted")
            XCTAssertEqual(row["status"] as String?, "cancelled")
            XCTAssertEqual(row["provider"] as String?, "deleted")
            XCTAssertNil(row["providerSessionId"] as String?)
            XCTAssertEqual(row["isUnread"] as Bool?, false)
        }
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run swift build first.")
        }
    }

    private func runCLI(_ arguments: [String]) throws -> (
        stdout: String,
        stderr: String,
        exitCode: Int32
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(decoding: output, as: UTF8.self),
            String(decoding: errors, as: UTF8.self),
            process.terminationStatus
        )
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            "Expected JSON object, got: \(json)"
        )
    }

    private func array(_ json: String) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
            "Expected JSON array, got: \(json)"
        )
    }
}
