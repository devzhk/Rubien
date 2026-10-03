import Foundation
import GRDB
import RubienCore
import XCTest

final class AttachmentCommandTests: XCTestCase {
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
            .appendingPathComponent("rubien-attachment-cli-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: testLibraryRoot)
        super.tearDown()
    }

    private func seed() throws -> Int64 {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--title", "Primary paper"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let envelope = try object(result.stdout)
        let reference = (envelope["items"] as? [[String: Any]])?.first?["reference"] as? [String: Any]
        return try XCTUnwrap((reference?["id"] as? NSNumber)?.int64Value)
    }

    private func add(_ files: [String], to reference: Int64) throws -> [[String: Any]] {
        let result = try runCLI(["attachment", "add", String(reference), "--"] + files)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return try array(result.stdout)
    }

    func testMovedLibraryReturnsJSONErrorAndHelpRemainsAvailable() throws {
        try skipIfBinaryMissing()
        let destination = testLibraryRoot.appendingPathComponent("new-location")
        try Data(destination.path.utf8).write(to: testLibraryRoot.appendingPathComponent(".rubien-promoted-to"))
        let result = try runCLI(["list"])
        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty)
        let message = try XCTUnwrap(try object(result.stderr)["error"] as? String)
        XCTAssertTrue(message.contains(destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: testLibraryRoot.appendingPathComponent("library.sqlite").path))
        XCTAssertEqual(try runCLI(["--help"]).exitCode, 0)
        XCTAssertEqual(try runCLI(["version"]).exitCode, 0)
    }

    func testBatchDuplicatesStatusRenameExportAndRemoval() throws {
        let reference = try seed()
        let file = testLibraryRoot.appendingPathComponent("notes with spaces.md")
        let bytes = Data("Supplement only 🐈\nSecond line".utf8)
        try bytes.write(to: file)
        let results = try add([file.path, file.path, testLibraryRoot.appendingPathComponent("missing.pdf").path], to: reference)
        XCTAssertEqual(results.compactMap { $0["outcome"] as? String }, ["added", "duplicate", "error"])
        let status = try XCTUnwrap(results[0]["status"] as? [String: Any])
        let attachment = try XCTUnwrap(status["attachment"] as? [String: Any])
        let id = try XCTUnwrap(attachment["syncId"] as? String)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(attachment["referenceId"] as? Int64, reference)
        XCTAssertEqual(attachment["byteCount"] as? Int, bytes.count)
        XCTAssertEqual(status["localAvailability"] as? String, "available")
        XCTAssertEqual(status["syncStatus"] as? String, "notEnabled")
        let retry = try runCLI(["attachment", "retry", id])
        XCTAssertEqual(retry.exitCode, 0, retry.stderr)
        XCTAssertEqual(try object(retry.stdout)["syncStatus"] as? String, "notEnabled")
        XCTAssertEqual(status["pendingUpload"] as? Bool, true)
        XCTAssertEqual(try array(runCLI(["attachment", "list", String(reference)]).stdout).count, 1)
        let read = try object(runCLI(["attachment", "read", id, "--start", "11", "--max-chars", "6"]).stdout)
        XCTAssertEqual(read["content"] as? String, "only 🐈")
        XCTAssertEqual(read["returnedChars"] as? Int, 6)
        XCTAssertEqual(read["truncated"] as? Bool, true)
        let renamed = try object(runCLI(["attachment", "rename", id, "--name", "My supplement"]).stdout)
        XCTAssertEqual((renamed["attachment"] as? [String: Any])?["displayName"] as? String, "My supplement")
        XCTAssertEqual((renamed["attachment"] as? [String: Any])?["originalFilename"] as? String, file.lastPathComponent)
        let output = testLibraryRoot.appendingPathComponent("exported.md")
        XCTAssertEqual(try runCLI(["attachment", "export", id, "--output", output.path]).exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertNotEqual(try runCLI(["attachment", "export", id, "--output", output.path]).exitCode, 0)
        let removed = try object(runCLI(["attachment", "remove", id]).stdout)
        XCTAssertEqual(removed["localAvailability"] as? String, "removed")
        XCTAssertEqual(removed["pendingUpload"] as? Bool, false)
        XCTAssertNotEqual(try runCLI(["attachment", "read", id]).exitCode, 0)
        XCTAssertTrue(try array(runCLI(["attachment", "list", String(reference)]).stdout).isEmpty)
        XCTAssertEqual(try object(runCLI(["get", String(reference)]).stdout)["title"] as? String, "Primary paper")
    }

    func testPDFReadingAndArgumentErrors() throws {
        let reference = try seed()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RubienPDFKitTests/Fixtures/PDFs/linear-3pages-text.pdf")
        let results = try add([fixture.path], to: reference)
        let status = try XCTUnwrap(results[0]["status"] as? [String: Any])
        let id = try XCTUnwrap((status["attachment"] as? [String: Any])?["syncId"] as? String)
        let read = try object(runCLI(["attachment", "read", id, "--pages", "2"]).stdout)
        XCTAssertEqual(read["source"] as? String, "pdf")
        XCTAssertEqual(read["pageCount"] as? Int, 3)
        let pages = try XCTUnwrap(read["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue((pages[0]["text"] as? String)?.contains("Page 2 body text") == true)
        for arguments in [["read", id, "--start", "0"], ["read", id, "--max-chars", "0"],
                          ["read", id, "--pages", "0"], ["status", "not-a-uuid"], ["rename", id, "--name", " "]] {
            let result = try runCLI(["attachment"] + arguments)
            XCTAssertNotEqual(result.exitCode, 0, arguments.description)
            XCTAssertNotNil(try object(result.stderr)["error"])
        }
    }

    func testMissingAndCorruptFilesNeverReadParentContent() throws {
        let reference = try seed()
        let file = testLibraryRoot.appendingPathComponent("note.md")
        try Data("Original".utf8).write(to: file)
        let results = try add([file.path], to: reference)
        let status = try XCTUnwrap(results[0]["status"] as? [String: Any])
        let id = try XCTUnwrap((status["attachment"] as? [String: Any])?["syncId"] as? String)
        let managed = testLibraryRoot.appendingPathComponent("Attachments/\(id)/content.md")
        try Data("Modified".utf8).write(to: managed)
        let listed = try array(runCLI(["attachment", "list", String(reference)]).stdout)
        XCTAssertEqual(listed.first?["localAvailability"] as? String, "available", "List checks size, not content hashes")
        let corrupt = try object(runCLI(["attachment", "status", id]).stdout)
        XCTAssertEqual(corrupt["localAvailability"] as? String, "error")
        XCTAssertNotEqual(try runCLI(["attachment", "read", id]).exitCode, 0)
        try FileManager.default.removeItem(at: managed)
        let missing = try object(runCLI(["attachment", "status", id]).stdout)
        XCTAssertEqual(missing["localAvailability"] as? String, "unavailable")
        XCTAssertNotEqual(try runCLI(["attachment", "export", id, "--output", file.path + ".copy"]).exitCode, 0)
        XCTAssertEqual(try object(runCLI(["get", String(reference)]).stdout)["title"] as? String, "Primary paper")
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
