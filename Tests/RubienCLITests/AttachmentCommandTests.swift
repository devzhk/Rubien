import Foundation
import GRDB
#if canImport(Network)
import Network
#endif
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

    #if canImport(Network)
    func testURLInputsDownloadNameAndReportPerInputErrors() throws {
        let reference = try seed()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RubienPDFKitTests/Fixtures/PDFs/linear-3pages-text.pdf")
        let pdf = try Data(contentsOf: fixture)
        let server = try LoopbackFileServer(routes: [
            "/papers/speediff_supp.pdf": .init(status: 200, contentType: "application/pdf", body: pdf),
            "/papers/notes.md": .init(status: 200, contentType: "text/markdown", body: Data("# Supplement\n".utf8)),
            "/papers/missing.pdf": .init(status: 404, contentType: "text/html", body: Data("Not found".utf8)),
            "/papers/landing.pdf": .init(status: 200, contentType: "text/html",
                                         body: Data("<html><body>Sign in</body></html>".utf8)),
        ])
        defer { server.stop() }
        let supp = try XCTUnwrap(server.url("/papers/speediff_supp.pdf")).absoluteString
        let notes = try XCTUnwrap(server.url("/papers/notes.md")).absoluteString
        let missing = try XCTUnwrap(server.url("/papers/missing.pdf")).absoluteString
        let landing = try XCTUnwrap(server.url("/papers/landing.pdf")).absoluteString
        let temporaryBefore = Self.importTemporaryDirectories()

        // One named URL input: added with the display name, URL basename kept.
        let named = try runCLI(["attachment", "add", String(reference), "--name", "  SpeeDiff — Supplementary Material ",
                                "--", supp])
        XCTAssertEqual(named.exitCode, 0, named.stderr)
        let namedResults = try array(named.stdout)
        XCTAssertEqual(namedResults.count, 1)
        XCTAssertEqual(Set(namedResults[0].keys), ["file", "outcome", "status"])
        XCTAssertEqual(namedResults[0]["file"] as? String, supp)
        XCTAssertEqual(namedResults[0]["outcome"] as? String, "added")
        let attachment = try XCTUnwrap((namedResults[0]["status"] as? [String: Any])?["attachment"] as? [String: Any])
        XCTAssertEqual(attachment["displayName"] as? String, "SpeeDiff — Supplementary Material")
        XCTAssertEqual(attachment["originalFilename"] as? String, "speediff_supp.pdf")
        XCTAssertEqual(attachment["kind"] as? String, "pdf")
        XCTAssertEqual(attachment["byteCount"] as? Int, pdf.count)
        let id = try XCTUnwrap(attachment["syncId"] as? String)

        // Batch: repeat URL is a duplicate (name untouched), Markdown URL is
        // added, and HTTP / payload failures are per-input errors.
        let batch = try runCLI(["attachment", "add", String(reference), "--", supp, notes, missing, landing])
        XCTAssertEqual(batch.exitCode, 0, batch.stderr)
        let results = try array(batch.stdout)
        XCTAssertEqual(results.compactMap { $0["file"] as? String }, [supp, notes, missing, landing])
        XCTAssertEqual(results.compactMap { $0["outcome"] as? String }, ["duplicate", "added", "error", "error"])
        let duplicate = try XCTUnwrap((results[0]["status"] as? [String: Any])?["attachment"] as? [String: Any])
        XCTAssertEqual(duplicate["syncId"] as? String, id)
        XCTAssertEqual(duplicate["displayName"] as? String, "SpeeDiff — Supplementary Material")
        XCTAssertEqual(((results[1]["status"] as? [String: Any])?["attachment"] as? [String: Any])?["displayName"] as? String,
                       "notes.md")
        for failure in results[2...] {
            XCTAssertEqual(Set(failure.keys), ["file", "outcome", "error"])
            XCTAssertNotNil(failure["error"] as? String)
        }
        XCTAssertTrue((results[2]["error"] as? String)?.contains("404") == true, "\(results[2])")
        XCTAssertEqual(try array(runCLI(["attachment", "list", String(reference)]).stdout).count, 2)
        XCTAssertEqual(Self.importTemporaryDirectories().subtracting(temporaryBefore), [],
                       "URL inputs must always remove their download directory")
    }
    #endif

    func testNameRequiresExactlyOneInputAndValidName() throws {
        let reference = try seed()
        let first = testLibraryRoot.appendingPathComponent("a.md")
        let second = testLibraryRoot.appendingPathComponent("b.md")
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)
        let two = try runCLI(["attachment", "add", String(reference), "--name", "Both", "--", first.path, second.path])
        XCTAssertNotEqual(two.exitCode, 0)
        XCTAssertTrue(two.stderr.contains("--name"), two.stderr)
        for name in [" ", String(repeating: "x", count: 256)] {
            let invalid = try runCLI(["attachment", "add", String(reference), "--name", name, "--", first.path])
            XCTAssertNotEqual(invalid.exitCode, 0)
            XCTAssertNotNil(try object(invalid.stderr)["error"])
        }
        XCTAssertTrue(try array(runCLI(["attachment", "list", String(reference)]).stdout).isEmpty)
        let named = try runCLI(["attachment", "add", String(reference), "--name", "Local supplement", "--", first.path])
        XCTAssertEqual(named.exitCode, 0, named.stderr)
        let attachment = try XCTUnwrap((try array(named.stdout).first?["status"] as? [String: Any])?["attachment"] as? [String: Any])
        XCTAssertEqual(attachment["displayName"] as? String, "Local supplement")
        XCTAssertEqual(attachment["originalFilename"] as? String, "a.md")
    }

    private static func importTemporaryDirectories() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("RubienImport-") })
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

#if canImport(Network)
/// Minimal loopback HTTP/1.1 file server for CLI download tests. The CLI runs
/// as a separate process, so URLProtocol stubs cannot intercept its requests.
/// One response per connection (`Connection: close`).
private final class LoopbackFileServer {
    struct Route {
        let status: Int
        let contentType: String
        let body: Data
    }

    private let listener: NWListener
    private let routes: [String: Route]
    private let queue = DispatchQueue(label: "com.rubien.tests.attachment-loopback-server")

    init(routes: [String: Route]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            listener.cancel()
            throw XCTSkip("Loopback listener did not start")
        }
    }

    func url(_ path: String) -> URL? {
        guard let port = listener.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(on: connection, buffer: Data())
    }

    private func receiveHeaders(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var received = buffer
            if let data { received.append(data) }
            if received.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete {
                self.receiveHeaders(on: connection, buffer: received)
                return
            }
            self.respond(on: connection, request: String(decoding: received, as: UTF8.self))
        }
    }

    private func respond(on connection: NWConnection, request: String) {
        let requestLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let route = routes[path] ?? Route(status: 404, contentType: "text/plain", body: Data("Not found".utf8))
        let head = "HTTP/1.1 \(route.status) Status\r\n"
            + "Content-Type: \(route.contentType)\r\n"
            + "Content-Length: \(route.body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(route.body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
