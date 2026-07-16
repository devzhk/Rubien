import Foundation
import GRDB
import XCTest

/// Black-box contract coverage for `stats` and `stats-clear`.
///
/// Each test gives the CLI its own library root, so command validation and
/// reset behavior never touch the developer's live Rubien library.
final class StatsCommandTests: XCTestCase {
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
            .appendingPathComponent("rubien-stats-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: testLibraryRoot)
        super.tearDown()
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run `swift build` first.")
        }
    }

    @discardableResult
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

    private func stdoutJSON(
        _ result: (stdout: String, stderr: String, exitCode: Int32)
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            "stdout was not a JSON object: \(result.stdout)"
        )
    }

    private func addReference() throws -> Int64 {
        let result = try runCLI(["add", "--title", "Stats Contract Paper"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        let reference = (json["items"] as? [[String: Any]])?.first?["reference"] as? [String: Any]
        return try XCTUnwrap((reference?["id"] as? NSNumber)?.int64Value)
    }

    /// Inserts retained facts directly because activity capture is app-only.
    /// Calling `add` first also initializes the isolated database through the
    /// same production migrations the commands use.
    private func seedActivity(
        referenceId: Int64,
        readingRows: [(day: String, seconds: Int64)],
        assistantSessions: Int = 1
    ) throws {
        let databaseURL = testLibraryRoot.appendingPathComponent("library.sqlite")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            let readingEpoch = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT revision, generation FROM activityEpoch WHERE kind='reading'")
            )
            let assistantEpoch = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT revision, generation FROM activityEpoch WHERE kind='assistant'")
            )
            let readingRevision: Int = readingEpoch["revision"]
            let readingGeneration: String = readingEpoch["generation"]
            let assistantRevision: Int = assistantEpoch["revision"]
            let assistantGeneration: String = assistantEpoch["generation"]

            for (index, row) in readingRows.enumerated() {
                let timestamp = Date(timeIntervalSince1970: 1_735_689_600 + Double(index))
                try db.execute(
                    sql: """
                        INSERT INTO readingActivity
                            (installationId, referenceId, localDay, epochRevision, generation,
                             activeSeconds, lastActiveAt, dateModified)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "stats-test-\(index)", referenceId, row.day, readingRevision,
                        readingGeneration, row.seconds, timestamp, timestamp,
                    ]
                )
            }

            for index in 0 ..< assistantSessions {
                let timestamp = Date(timeIntervalSince1970: 1_735_689_700 + Double(index))
                try db.execute(
                    sql: """
                        INSERT INTO assistantActivity
                            (id, provider, epochRevision, generation, startedAt, localDay, dateModified)
                        VALUES (?, 'codex', ?, ?, ?, '2025-01-01', ?)
                        """,
                    arguments: [
                        "stats-conversation-\(index)", assistantRevision,
                        assistantGeneration, timestamp, timestamp,
                    ]
                )
            }
        }
    }

    func testStatsEmitsSharedJSONContractAndYearOnlySelectsCalendarSlice() throws {
        try skipIfBinaryMissing()
        let referenceId = try addReference()
        try seedActivity(
            referenceId: referenceId,
            readingRows: [("2025-01-01", 120), ("2026-01-01", 60)]
        )

        let result = try runCLI(["stats", "--year", "2025"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty)
        let json = try stdoutJSON(result)

        let asOfLocalDay = try XCTUnwrap(json["asOfLocalDay"] as? String)
        XCTAssertEqual(asOfLocalDay.count, 10)
        XCTAssertEqual(asOfLocalDay[asOfLocalDay.index(asOfLocalDay.startIndex, offsetBy: 4)], "-")
        XCTAssertEqual(asOfLocalDay[asOfLocalDay.index(asOfLocalDay.startIndex, offsetBy: 7)], "-")
        let totals = try XCTUnwrap(json["trackedTotals"] as? [String: Any])
        XCTAssertEqual((totals["papersRead"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((totals["estimatedActiveSeconds"] as? NSNumber)?.int64Value, 180)
        XCTAssertEqual((totals["assistantSessions"] as? NSNumber)?.intValue, 1)

        let yearActivity = try XCTUnwrap(json["yearActivity"] as? [String: Any])
        XCTAssertEqual((yearActivity["year"] as? NSNumber)?.intValue, 2025)
        let daily = try XCTUnwrap(yearActivity["dailyActivity"] as? [[String: Any]])
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily.first?["localDay"] as? String, "2025-01-01")
        XCTAssertEqual((daily.first?["paperCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((daily.first?["estimatedActiveSeconds"] as? NSNumber)?.int64Value, 120)

        XCTAssertNotNil(json["currentWeek"] as? [String: Any])
        XCTAssertNotNil(json["streaks"] as? [String: Any])
        XCTAssertNotNil(json["recentPapers"] as? [[String: Any]])
        let coverage = try XCTUnwrap(json["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["trackingIntroducedInVersion"] as? String, "0.4.0")
        XCTAssertTrue(coverage.keys.contains("readingResetAt"))
        XCTAssertTrue(coverage.keys.contains("assistantResetAt"))
    }

    func testStatsRejectsOutOfRangeYearBeforeOpeningTheLibrary() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["stats", "--year", "1969"])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("--year must be between 1970 and 9999"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: testLibraryRoot.appendingPathComponent("library.sqlite").path
        ))
    }

    func testStatsClearRequiresConfirmationAndRejectsUnknownKindWithoutMutation() throws {
        try skipIfBinaryMissing()
        let referenceId = try addReference()
        try seedActivity(referenceId: referenceId, readingRows: [("2025-01-01", 60)])

        let unconfirmed = try runCLI(["stats-clear", "--kind", "reading"])
        XCTAssertNotEqual(unconfirmed.exitCode, 0)
        XCTAssertTrue(unconfirmed.stdout.isEmpty)
        XCTAssertTrue(unconfirmed.stderr.contains("stats-clear requires --yes"), unconfirmed.stderr)

        let invalid = try runCLI(["stats-clear", "--kind", "everything", "--yes"])
        XCTAssertNotEqual(invalid.exitCode, 0)
        XCTAssertTrue(invalid.stdout.isEmpty)
        XCTAssertTrue(invalid.stderr.contains("--kind must be 'reading' or 'assistant'"), invalid.stderr)

        let afterErrors = try runCLI(["stats", "--year", "2025"])
        XCTAssertEqual(afterErrors.exitCode, 0, afterErrors.stderr)
        let totals = try XCTUnwrap(
            (try stdoutJSON(afterErrors))["trackedTotals"] as? [String: Any]
        )
        XCTAssertEqual((totals["papersRead"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((totals["assistantSessions"] as? NSNumber)?.intValue, 1)
    }

    func testStatsClearReturnsJSONAndClearsOnlyTheSelectedCategory() throws {
        try skipIfBinaryMissing()
        let referenceId = try addReference()
        try seedActivity(referenceId: referenceId, readingRows: [("2025-01-01", 60)])

        let clearedReading = try runCLI(["stats-clear", "--kind", "reading", "--yes"])
        XCTAssertEqual(clearedReading.exitCode, 0, clearedReading.stderr)
        XCTAssertTrue(clearedReading.stderr.isEmpty)
        XCTAssertEqual(try stdoutJSON(clearedReading)["cleared"] as? String, "reading")

        let afterReadingClear = try runCLI(["stats", "--year", "2025"])
        XCTAssertEqual(afterReadingClear.exitCode, 0, afterReadingClear.stderr)
        let afterReadingJSON = try stdoutJSON(afterReadingClear)
        let readingTotals = try XCTUnwrap(afterReadingJSON["trackedTotals"] as? [String: Any])
        XCTAssertEqual((readingTotals["papersRead"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((readingTotals["estimatedActiveSeconds"] as? NSNumber)?.int64Value, 0)
        XCTAssertEqual((readingTotals["assistantSessions"] as? NSNumber)?.intValue, 1)
        let coverage = try XCTUnwrap(afterReadingJSON["coverage"] as? [String: Any])
        XCTAssertTrue(coverage["readingResetAt"] is String)
        XCTAssertTrue(coverage["assistantResetAt"] is NSNull)

        let clearedAssistant = try runCLI(["stats-clear", "--kind", "assistant", "--yes"])
        XCTAssertEqual(clearedAssistant.exitCode, 0, clearedAssistant.stderr)
        XCTAssertEqual(try stdoutJSON(clearedAssistant)["cleared"] as? String, "assistant")

        let afterBoth = try runCLI(["stats", "--year", "2025"])
        let finalTotals = try XCTUnwrap(
            (try stdoutJSON(afterBoth))["trackedTotals"] as? [String: Any]
        )
        XCTAssertEqual((finalTotals["assistantSessions"] as? NSNumber)?.intValue, 0)
    }
}
