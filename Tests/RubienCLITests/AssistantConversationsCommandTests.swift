import Foundation
import GRDB
import RubienCore
import XCTest

final class AssistantConversationsCommandTests: XCTestCase {
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
            .appendingPathComponent("rubien-assistant-cli-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: testLibraryRoot)
        super.tearDown()
    }

    func testListGetDeleteAndClearContracts() throws {
        try skipIfBinaryMissing()
        XCTAssertEqual(try runCLI(["assistant-conversations", "list"]).exitCode, 0)
        let queue = try DatabaseQueue(
            path: testLibraryRoot.appendingPathComponent("library.sqlite").path
        )
        let now = Date()
        let managedAttachment = testLibraryRoot
            .appendingPathComponent(AssistantAttachmentFiles.directoryName, isDirectory: true)
            .appendingPathComponent("conversation-1", isDirectory: true)
            .appendingPathComponent("attachment-1", isDirectory: true)
            .appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(
            at: managedAttachment.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("note".utf8).write(to: managedAttachment)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO assistantConversation (
                        id, provider, origin, workspaceIdentityHash, contextKind,
                        createdAt, lastActivityAt
                    ) VALUES ('conversation-1', 'codex', 'rubien', 'workspace',
                              'library', ?, ?)
                    """,
                arguments: [now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO assistantTurn (
                        id, conversationId, ordinal, status, dateModified
                    ) VALUES ('turn-1', 'conversation-1', 1, 'succeeded', ?)
                    """,
                arguments: [now]
            )
            try db.execute(
                sql: """
                    INSERT INTO assistantTranscriptEntry (
                        id, turnId, sequence, kind, body, payloadVersion,
                        searchText, status, createdAt, dateModified
                    ) VALUES ('entry-user', 'turn-1', 0, 'user',
                              'Summarize this paper', 1,
                              'summarize this paper', 'completed', ?, ?)
                    """,
                arguments: [now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO assistantTranscriptEntry (
                        id, turnId, sequence, kind, body, payloadVersion,
                        searchText, status, createdAt, dateModified
                    ) VALUES ('entry-1', 'turn-1', 1, 'assistant',
                              'Encoder free architecture', 1,
                              'encoder free architecture', 'completed', ?, ?)
                    """,
                arguments: [now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO assistantAttachment (
                        id, entryId, displayName, kind, relativePath, mediaType,
                        byteCount, createdAt
                    ) VALUES ('attachment-1', 'entry-1', 'note.txt', 'text',
                              'attachment-1/note.txt', 'text/plain', 4, ?)
                    """,
                arguments: [now]
            )
        }

        let listed = try runCLI([
            "assistant-conversations", "list",
            "--provider", "codex", "--search", "encoder",
        ])
        XCTAssertEqual(listed.exitCode, 0, listed.stderr)
        let summary = try XCTUnwrap(try array(listed.stdout).first)
        XCTAssertEqual(summary["preview"] as? String, "Summarize this paper")
        XCTAssertEqual(summary["turnCount"] as? Int, 1)
        XCTAssertEqual(
            (summary["conversation"] as? [String: Any])?["id"] as? String,
            "conversation-1"
        )

        let fetched = try runCLI(["assistant-conversations", "get", "conversation-1"])
        XCTAssertEqual(fetched.exitCode, 0, fetched.stderr)
        let detail = try object(fetched.stdout)
        XCTAssertEqual((detail["entries"] as? [[String: Any]])?.count, 2)
        let attachments = try XCTUnwrap(detail["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["relativePath"] as? String, "attachment-1/note.txt")
        XCTAssertNil(attachments.first?["absolutePath"])

        let missingConfirmation = try runCLI(["assistant-conversations", "clear"])
        XCTAssertNotEqual(missingConfirmation.exitCode, 0)
        XCTAssertTrue(missingConfirmation.stderr.contains("--confirm"))

        let deleted = try runCLI([
            "assistant-conversations", "delete", "conversation-1",
        ])
        XCTAssertEqual(deleted.exitCode, 0, deleted.stderr)
        XCTAssertEqual(try object(deleted.stdout)["deleted"] as? String, "conversation-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedAttachment.path))

        let cleared = try runCLI(["assistant-conversations", "clear", "--confirm"])
        XCTAssertEqual(cleared.exitCode, 0, cleared.stderr)
        XCTAssertEqual(try object(cleared.stdout)["cleared"] as? Int, 0)
    }

    func testReadsRemainAvailableWhileMutationsReturnStableBusyError() throws {
        try skipIfBinaryMissing()
        XCTAssertEqual(try runCLI(["assistant-conversations", "list"]).exitCode, 0)
        let lock = try XCTUnwrap(AssistantLibraryExecutionLock.tryAcquire(
            libraryRoot: testLibraryRoot,
            ownerDescription: "cli-lock-test"
        ))
        defer { lock.release() }

        let read = try runCLI(["assistant-conversations", "list"])
        XCTAssertEqual(read.exitCode, 0, read.stderr)

        let mutation = try runCLI([
            "assistant-conversations", "delete", "conversation-1",
        ])
        XCTAssertNotEqual(mutation.exitCode, 0)
        XCTAssertEqual(
            try object(mutation.stderr)["error"] as? String,
            "assistant-execution-busy"
        )
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
