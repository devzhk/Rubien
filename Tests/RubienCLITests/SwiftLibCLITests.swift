import XCTest
import Foundation

/// Integration tests for the `rubien-cli` CLI binary.
/// These tests invoke the compiled CLI executable and verify its output.
/// Requires the CLI to be built first: `swift build --product rubien-cli`
final class RubienCLITests: XCTestCase {

    /// Path to the built CLI binary
    private var cliBinaryPath: String {
        let debugPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // RubienCLITests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent(".build/debug/rubien-cli")
            .path

        if FileManager.default.isExecutableFile(atPath: debugPath) {
            return debugPath
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rubien-cli") {
            return "/usr/local/bin/rubien-cli"
        }
        return debugPath
    }

    /// Per-test temp directory used as `RUBIEN_LIBRARY_ROOT` so every test
    /// method gets a fresh, isolated library. Without this, parallel CLI
    /// tests collide on the default storage path (Application Support or
    /// the App Group container) and intermittently fail.
    /// `lazy` evaluates once per test instance, and XCTest creates a fresh
    /// instance per test method.
    private lazy var testLibraryRoot: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rubien-cli-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: testLibraryRoot)
    }

    private func runCLI(_ arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain pipes concurrently on dedicated background threads. The OS
        // pipe buffer is ~64KB; if we wait for exit before reading, a child
        // that writes more than that blocks on fwrite and we deadlock —
        // `export --format json` on a populated fixture is the pathological
        // case. `readDataToEndOfFile` blocks until EOF, so each thread
        // returns exactly the full content of its pipe.
        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue.global(qos: .userInitiated)

        readGroup.enter()
        readQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        readQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        try process.run()
        process.waitUntilExit()
        // Both reader threads see EOF once the child's pipe ends are closed,
        // which happens on exit. Wait for them to finish so the captured
        // Data values are fully populated before we read them.
        readGroup.wait()

        return (
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Overload of `runCLI` that feeds `stdin` to the child's standard input.
    /// The write handle is written in full then closed (signalling EOF)
    /// *before* `waitUntilExit`, so a child reading stdin to end-of-file
    /// unblocks. stdout/stderr are drained on background threads exactly as
    /// the no-stdin overload to avoid the ~64KB pipe-buffer deadlock.
    private func runCLI(_ arguments: [String], stdin: String) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue.global(qos: .userInitiated)

        readGroup.enter()
        readQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        readQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        try process.run()
        // Write the payload in full, then close the write end to send EOF so
        // the child's `readDataToEndOfFile` on stdin returns. Do this before
        // waiting for exit.
        let writeHandle = stdinPipe.fileHandleForWriting
        writeHandle.write(Data(stdin.utf8))
        try writeHandle.close()

        process.waitUntilExit()
        readGroup.wait()

        return (
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run `swift build` first.")
        }
    }

    // MARK: - Help

    func testHelpOutput() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        let output = result.stdout + result.stderr
        XCTAssertTrue(output.lowercased().contains("subcommand") || output.contains("SUBCOMMANDS"),
                      "Help should list subcommands")
    }

    // MARK: - Version

    /// The marketing version the CLI must report, read from the repo's VERSION
    /// file so it never goes stale on a release bump. Asserts the real invariant
    /// — `--version` reflects VERSION (guards the old 1.0.0-placeholder
    /// regression) — instead of a hardcoded literal that must be hand-bumped.
    private func expectedMarketingVersion() throws -> String {
        let versionURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/RubienCLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("VERSION")
        return try String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testVersionOutput() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["--version"])
        XCTAssertEqual(result.exitCode, 0)
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, try expectedMarketingVersion(),
                       "--version must reflect the VERSION file, not the old 1.0.0 placeholder")
    }

    func testVersionSubcommandJSON() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["version"])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let data = Data(result.stdout.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj, "version output should be a JSON object")
        let version = obj?["version"] as? String
        let build = obj?["build"] as? Int
        XCTAssertNotNil(version, "version field must be a string")
        XCTAssertNotNil(build, "build field must be an integer")
        XCTAssertEqual(obj?.count, 2, "version JSON must have exactly two keys: version and build")
        // Build is the monotonic integer the MCP guard compares against.
        XCTAssertGreaterThanOrEqual(build ?? 0, 8)
        XCTAssertEqual(version, try expectedMarketingVersion())
    }

    // MARK: - List

    func testListCommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["list"])
        XCTAssertEqual(result.exitCode, 0)
        // Verify output is valid JSON array
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "List output should be a JSON array")
    }

    func testListWithLimit() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["list", "--limit", "5"])
        XCTAssertEqual(result.exitCode, 0)
        let data = Data(result.stdout.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertNotNil(arr)
        XCTAssertLessThanOrEqual(arr?.count ?? 0, 5, "List with --limit 5 should return at most 5")
    }

    func testListWithOffset() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["list", "--offset", "0"])
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Search

    func testSearchCommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["search", "test"])
        XCTAssertEqual(result.exitCode, 0)
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Search output should be a JSON array")
    }

    // MARK: - Tags (retired — tags now flow through `properties` against the built-in Tags property)

    /// The standalone `tags` subcommand was removed when tag operations were
    /// folded into `properties` against the built-in Tags property
    /// (defaultFieldKey == "tags"). Invoking it must exit non-zero.
    func testTagsSubcommandIsRetired() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["tags"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "`rubien-cli tags` should exit non-zero — operations moved to `properties` against the built-in Tags property")
    }

    /// The built-in Tags PropertyDefinition must surface in `properties` and
    /// expose its options inline (one per Tag row, with stable id as `value`
    /// and tag name as `label`).
    func testTagsPropertyAppearsInPropertiesListWithInlineOptions() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["properties", "--name", "Tags"])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertEqual(arr.count, 1, "--name Tags should return exactly one definition")
        guard let tagsDef = arr.first else { return }
        XCTAssertEqual(tagsDef["defaultFieldKey"] as? String, "tags")
        XCTAssertEqual(tagsDef["type"] as? String, "multiSelect")
        // Options array must be an array of objects with value/label/color keys.
        // (Empty is OK on a fresh library; the shape is what matters here.)
        if let options = tagsDef["options"] as? [[String: Any]], let first = options.first {
            XCTAssertNotNil(first["value"], "option must have value")
            XCTAssertNotNil(first["label"], "option must have label")
            XCTAssertNotNil(first["color"], "option must have color")
        }
    }

    // MARK: - Export

    func testExportJSON() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "json"])
        XCTAssertEqual(result.exitCode, 0)
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Export JSON should produce a JSON array")
    }

    func testExportBibTeX() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "bibtex"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExportRIS() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "ris"])
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Subcommand Help

    func testSearchHelp() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["search", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCiteHelp() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["cite", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testImportHelp() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["import", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Invalid Subcommand

    func testInvalidSubcommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["nonexistent"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "Invalid subcommand should return non-zero exit code")
    }

    // MARK: - Get Non-existent Reference

    func testGetNonExistentReference() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["get", "999999999"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "Getting a non-existent reference should fail")
        // Error should be in stderr as JSON
        let errData = Data(result.stderr.utf8)
        if let errJson = try? JSONSerialization.jsonObject(with: errData) as? [String: Any] {
            XCTAssertNotNil(errJson["error"], "Error output should contain 'error' key")
        }
    }

    // MARK: - Delete requires --force in non-interactive

    func testDeleteWithoutForceInNonInteractive() throws {
        try skipIfBinaryMissing()
        // When run as a subprocess (non-tty), delete without --force should still work
        // because isatty returns 0 for piped stdin
        let result = try runCLI(["delete", "999999999", "--force"])
        _ = result
        // May fail because the reference doesn't exist, but should not hang waiting for input
        // The important thing is it doesn't block
    }

    // MARK: - Add → Get → Delete lifecycle

    func testAddGetDeleteLifecycle() throws {
        try skipIfBinaryMissing()

        // Add by title
        let addResult = try runCLI(["add", "--title", "CLI Test Reference \(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0, "Add should succeed")
        let addData = Data(addResult.stdout.utf8)
        let addJson = try JSONSerialization.jsonObject(with: addData) as? [String: Any]
        XCTAssertNotNil(addJson, "Add output should be a JSON envelope")
        let refDict = addJson?["reference"] as? [String: Any]
        guard let refId = refDict?["id"] as? Int64 ?? (refDict?["id"] as? Int).map(Int64.init) else {
            XCTFail("Add envelope should contain reference.id")
            return
        }

        // Get the reference back
        let getResult = try runCLI(["get", "\(refId)"])
        XCTAssertEqual(getResult.exitCode, 0, "Get should succeed")
        let getData = Data(getResult.stdout.utf8)
        let getJson = try JSONSerialization.jsonObject(with: getData) as? [String: Any]
        XCTAssertNotNil(getJson?["title"], "Get output should contain 'title'")

        // Delete it (with --force to skip confirmation)
        let deleteResult = try runCLI(["delete", "\(refId)", "--force"])
        XCTAssertEqual(deleteResult.exitCode, 0, "Delete should succeed")

        // Verify it's gone
        let verifyResult = try runCLI(["get", "\(refId)"])
        XCTAssertNotEqual(verifyResult.exitCode, 0, "Get after delete should fail")
    }

    // MARK: - PDF download rejection paths
    //
    // Success paths require live network (stable arXiv id 2106.04561 makes a
    // good manual smoke test) and aren't covered here. The three tests below
    // exercise the offline rejection envelope: each must exit non-zero with
    // stderr parsing to `{"error": ...}` per the CLI/MCP contract.

    func testAddDownloadPdfRequiresIdentifier() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--title", "X \(UUID().uuidString)", "--download-pdf"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "--download-pdf without --identifier should fail")
        let errJson = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        let message = errJson?["error"] as? String ?? ""
        XCTAssertTrue(message.contains("--download-pdf requires --identifier"),
                      "stderr error message did not name the constraint; got: \(message)")
    }

#if canImport(PDFKit)
    func testPdfDownloadReferenceNotFound() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["pdf", "download", "999999999"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "pdf download for a missing reference should fail")
        let errJson = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        let message = errJson?["error"] as? String ?? ""
        XCTAssertTrue(message.contains("not found"),
                      "stderr error message did not contain 'not found'; got: \(message)")
    }

    func testPdfDownloadIncapableReference() throws {
        try skipIfBinaryMissing()

        // Manual-entry reference has no DOI/arXiv URL, so canDownloadPDF is false.
        let addResult = try runCLI(["add", "--title", "Incapable \(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0)
        let addJson = try JSONSerialization.jsonObject(with: Data(addResult.stdout.utf8)) as? [String: Any]
        let refDict = addJson?["reference"] as? [String: Any]
        guard let refId = refDict?["id"] as? Int64 ?? (refDict?["id"] as? Int).map(Int64.init) else {
            XCTFail("Add envelope should contain reference.id")
            return
        }
        defer { _ = try? runCLI(["delete", "\(refId)", "--force"]) }

        let result = try runCLI(["pdf", "download", "\(refId)"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "pdf download on an incapable reference should fail")
        let errJson = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        let message = errJson?["error"] as? String ?? ""
        XCTAssertTrue(message.contains("No DOI or arXiv identifier"),
                      "stderr error message did not explain the cause; got: \(message)")
    }
#endif // canImport(PDFKit)

    // MARK: - Web subcommand
    //
    // Like the PDF download tests above, the happy path requires a known
    // web-clipped reference in the live dev library and can't be set up via
    // the CLI alone (`webContent` has no `add`/`update` flag — it's written
    // only by the in-app WebReader). The tests below cover the error
    // envelopes and the DTO-shape contract instead.

    func testWebGetReferenceNotFound() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["web", "get", "999999999"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "web get for a missing reference should fail")
        let errJson = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        let message = errJson?["error"] as? String ?? ""
        XCTAssertTrue(message.contains("not found"),
                      "stderr error did not say 'not found'; got: \(message)")
    }

    func testWebGetReferenceWithoutWebContent() throws {
        try skipIfBinaryMissing()

        // Manual-entry references have no webContent — exercises the
        // "row exists but webContent is NULL" branch that `fetchWebContent`
        // can't distinguish on its own.
        let addResult = try runCLI(["add", "--title", "NoWeb \(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0)
        let addJson = try JSONSerialization.jsonObject(with: Data(addResult.stdout.utf8)) as? [String: Any]
        let refDict = addJson?["reference"] as? [String: Any]
        guard let refId = refDict?["id"] as? Int64 ?? (refDict?["id"] as? Int).map(Int64.init) else {
            XCTFail("Add envelope should contain reference.id")
            return
        }
        defer { _ = try? runCLI(["delete", "\(refId)", "--force"]) }

        let result = try runCLI(["web", "get", "\(refId)"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "web get on a reference with no webContent should fail")
        let errJson = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        let message = errJson?["error"] as? String ?? ""
        XCTAssertTrue(message.contains("no web content"),
                      "stderr error did not say 'no web content'; got: \(message)")
    }

    func testWebGetRejectsInvalidMaxChars() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["web", "get", "1", "--max-chars", "0"])
        XCTAssertNotEqual(result.exitCode, 0)
        let errJson = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        let message = errJson?["error"] as? String ?? ""
        XCTAssertTrue(message.contains("--max-chars"),
                      "stderr error did not name --max-chars; got: \(message)")
    }

    func testWebGetRejectsNegativeStart() throws {
        try skipIfBinaryMissing()
        // swift-argument-parser treats `-1` as a separate flag token, so the
        // `--start=-1` form is the only way to pass a negative integer
        // through the parser into our explicit `>= 0` check.
        let result = try runCLI(["web", "get", "1", "--start=-1"])
        XCTAssertNotEqual(result.exitCode, 0)
        let errJson = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
        let message = errJson?["error"] as? String ?? ""
        XCTAssertTrue(message.contains("--start"),
                      "stderr error did not name --start; got: \(message)")
    }

    func testWebAnnotationsEmptyForNonexistentReference() throws {
        try skipIfBinaryMissing()
        // Matches the PDF `annotations` subcommand: missing IDs are not
        // errors; they just return [].
        let result = try runCLI(["web", "annotations", "999999999"])
        XCTAssertEqual(result.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [Any]
        XCTAssertNotNil(arr, "web annotations should return a JSON array")
        XCTAssertEqual(arr?.count ?? -1, 0,
                       "web annotations on a nonexistent reference should be []")
    }

    func testReferenceDTOOmitsSiteNameWhenNil() throws {
        try skipIfBinaryMissing()

        // Manual-entry references have nil `siteName`. Optional + synthesized
        // Encodable means the key must be absent (not `null`) so existing
        // PDF-only scripting clients stay unaffected.
        let addResult = try runCLI(["add", "--title", "NoSite \(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0)
        let addJson = try JSONSerialization.jsonObject(with: Data(addResult.stdout.utf8)) as? [String: Any]
        let refDict = addJson?["reference"] as? [String: Any]
        guard let refId = refDict?["id"] as? Int64 ?? (refDict?["id"] as? Int).map(Int64.init) else {
            XCTFail("Add envelope should contain reference.id")
            return
        }
        defer { _ = try? runCLI(["delete", "\(refId)", "--force"]) }

        let getResult = try runCLI(["get", "\(refId)"])
        XCTAssertEqual(getResult.exitCode, 0)
        let getJson = try JSONSerialization.jsonObject(with: Data(getResult.stdout.utf8)) as? [String: Any]
        XCTAssertFalse(getJson?.keys.contains("siteName") ?? true,
                       "siteName key should be omitted when nil; got dict with key present")
    }

    // MARK: - Import Help mentions stdin

    func testImportHelpMentionsStdin() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["import", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let output = result.stdout + result.stderr
        XCTAssertTrue(output.contains("-") || output.contains("stdin"),
                      "Import help should mention stdin support")
    }

    // MARK: - Cite invalid style

    func testCiteInvalidStyleFails() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["cite", "1", "--style", "nonexistent-style"])
        XCTAssertNotEqual(result.exitCode, 0, "Invalid citation style should fail")
    }

    // MARK: - Properties

    /// Read an integer id out of a JSON object emitted by the CLI.
    /// Handles both the `add` envelope shape (`reference.id`) and the
    /// flat shape used by other CLI commands (`properties --create`, etc).
    private func parseId(from data: Data) -> Int64? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let container = (obj["reference"] as? [String: Any]) ?? obj
        if let s = container["id"] as? String { return Int64(s) }
        if let i = container["id"] as? Int64 { return i }
        if let i = container["id"] as? Int { return Int64(i) }
        return nil
    }

    func testPropertiesListCommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["properties"])
        XCTAssertEqual(result.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [Any]
        XCTAssertNotNil(arr, "properties should emit a JSON array")
        XCTAssertGreaterThan(arr?.count ?? 0, 0, "Seeded default properties should appear")
    }

    func testPropertiesListVisibleIsSubset() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [Any] ?? []
        let visible = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties", "--visible"]).stdout.utf8)) as? [Any] ?? []
        XCTAssertLessThanOrEqual(visible.count, all.count, "--visible must be a subset of all")
    }

    func testPropertiesCreateStringAndDelete() throws {
        try skipIfBinaryMissing()
        let uniqueName = "cli-string-\(UUID().uuidString.prefix(8))"

        let created = try runCLI(["properties", "--create", "--name", uniqueName, "--type", "string"])
        XCTAssertEqual(created.exitCode, 0, "create should succeed")
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create output should contain numeric id")
            return
        }

        let listed = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertTrue(listed.contains { ($0["name"] as? String) == uniqueName }, "created prop should appear in list")

        let deleted = try runCLI(["properties", "--delete", String(propId)])
        XCTAssertEqual(deleted.exitCode, 0, "delete should succeed")

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(after.contains { ($0["name"] as? String) == uniqueName }, "prop should be gone after delete")
    }

    func testPropertiesCreateSingleSelectWithOptions() throws {
        try skipIfBinaryMissing()
        let uniqueName = "cli-status-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["properties", "--create", "--name", uniqueName, "--type", "singleSelect", "--options", "todo,doing,done"])
        XCTAssertEqual(created.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any]
        let options = obj?["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(options.count, 3, "should have 3 options")
        let colors = options.compactMap { $0["color"] as? String }
        XCTAssertEqual(Set(colors).count, colors.count, "auto-assigned colors should be unique")

        if let propId = parseId(from: Data(created.stdout.utf8)) {
            _ = try runCLI(["properties", "--delete", String(propId)])
        }
    }

    func testPropertiesRename() throws {
        try skipIfBinaryMissing()
        let original = "cli-rename-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["properties", "--create", "--name", original, "--type", "string"])
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let renamed = original + "-renamed"
        let result = try runCLI(["properties", "--rename", "--id", String(propId), "--name", renamed])
        XCTAssertEqual(result.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["name"] as? String, renamed)
    }

    func testPropertiesShowHide() throws {
        try skipIfBinaryMissing()
        let created = try runCLI(["properties", "--create", "--name", "cli-vis-\(UUID().uuidString.prefix(8))", "--type", "string"])
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let hidden = try runCLI(["properties", "--hide", "--id", String(propId)])
        XCTAssertEqual(hidden.exitCode, 0)
        let hiddenObj = try JSONSerialization.jsonObject(with: Data(hidden.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(hiddenObj?["isVisible"] as? Bool, false)

        let shown = try runCLI(["properties", "--show", "--id", String(propId)])
        XCTAssertEqual(shown.exitCode, 0)
        let shownObj = try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(shownObj?["isVisible"] as? Bool, true)
    }

    func testPropertiesAddOption() throws {
        try skipIfBinaryMissing()
        let created = try runCLI(["properties", "--create", "--name", "cli-addopt-\(UUID().uuidString.prefix(8))", "--type", "singleSelect", "--options", "a,b"])
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let added = try runCLI(["properties", "--add-option", "--id", String(propId), "--value", "c"])
        XCTAssertEqual(added.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(added.stdout.utf8)) as? [String: Any]
        let options = obj?["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(options.count, 3, "should now have 3 options")
        XCTAssertTrue(options.contains { ($0["value"] as? String) == "c" })
    }

    func testPropertiesSetAndClearValueRoundTrip() throws {
        try skipIfBinaryMissing()

        // Create a reference
        let addResult = try runCLI(["add", "--title", "CLI Prop Test \(UUID().uuidString.prefix(8))"])
        XCTAssertEqual(addResult.exitCode, 0)
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        // Create a custom property
        let propResult = try runCLI(["properties", "--create", "--name", "cli-val-\(UUID().uuidString.prefix(8))", "--type", "string"])
        guard let propId = parseId(from: Data(propResult.stdout.utf8)) else {
            XCTFail("create prop failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        // Set a value
        let setResult = try runCLI(["properties", "--set", "--reference", String(refId), "--id", String(propId), "--value", "hello"])
        XCTAssertEqual(setResult.exitCode, 0)

        // Read back via --reference listing
        let listed = try runCLI(["properties", "--reference", String(refId)])
        XCTAssertEqual(listed.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertTrue(arr.contains { ($0["value"] as? String) == "hello" && ($0["propertyId"] as? String) == String(propId) })

        // Verify get includes customProperties
        let getResult = try runCLI(["get", String(refId)])
        XCTAssertEqual(getResult.exitCode, 0)
        let getObj = try JSONSerialization.jsonObject(with: Data(getResult.stdout.utf8)) as? [String: Any]
        let custom = getObj?["customProperties"] as? [[String: Any]] ?? []
        XCTAssertTrue(custom.contains { ($0["value"] as? String) == "hello" })

        // Clear and confirm
        let clearResult = try runCLI(["properties", "--clear", "--reference", String(refId), "--id", String(propId)])
        XCTAssertEqual(clearResult.exitCode, 0)
        let afterClear = try runCLI(["properties", "--reference", String(refId)])
        let afterArr = try JSONSerialization.jsonObject(with: Data(afterClear.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(afterArr.contains { ($0["propertyId"] as? String) == String(propId) })
    }

    func testDeleteDefaultPropertyIsRefused() throws {
        try skipIfBinaryMissing()
        // Find a default property (isDefault == true)
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let defaultProp = all.first(where: { ($0["isDefault"] as? Bool) == true }),
              let idStr = defaultProp["id"] as? String else {
            XCTFail("No default property found to test against")
            return
        }

        let result = try runCLI(["properties", "--delete", idStr])
        XCTAssertNotEqual(result.exitCode, 0, "Deleting a built-in property should fail")

        // Ensure it still exists
        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertTrue(after.contains { ($0["id"] as? String) == idStr })
    }

    func testPropertiesRenameDefaultPropertyIsRefused() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let defaultProp = all.first(where: { ($0["isDefault"] as? Bool) == true }),
              let idStr = defaultProp["id"] as? String,
              let originalName = defaultProp["name"] as? String else {
            XCTFail("No default property seeded")
            return
        }

        let result = try runCLI(["properties", "--rename", "--id", idStr, "--name", "Hijacked"])
        XCTAssertNotEqual(result.exitCode, 0, "--rename on a built-in property should fail")

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        let stillThere = after.first { ($0["id"] as? String) == idStr }
        XCTAssertEqual(stillThere?["name"] as? String, originalName, "name must be unchanged")
    }

    /// Type is permanently locked from option mutations because it drives
    /// BibTeX/RIS export buckets. The error message must point users at the
    /// alternatives (Tags or custom singleSelect properties).
    func testPropertiesAddOptionToTypeIsRefused() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let typeProp = all.first(where: { ($0["defaultFieldKey"] as? String) == "referenceType" }),
              let idStr = typeProp["id"] as? String else {
            XCTFail("Type PropertyDefinition not seeded")
            return
        }
        let originalCount = (typeProp["options"] as? [Any])?.count ?? 0

        let result = try runCLI(["properties", "--add-option", "--id", idStr, "--value", "Bogus"])
        XCTAssertNotEqual(result.exitCode, 0, "--add-option on Type must fail")
        // printJSONError writes the JSON error envelope to stderr, not stdout.
        XCTAssertTrue(
            result.stderr.contains("BibTeX") || result.stderr.contains("Tags"),
            "error must point user at the right alternative (Tags or custom property): stderr=\(result.stderr) stdout=\(result.stdout)"
        )

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        let stillThere = after.first { ($0["id"] as? String) == idStr }
        let nowCount = (stillThere?["options"] as? [Any])?.count ?? 0
        XCTAssertEqual(nowCount, originalCount, "options list must be unchanged")
    }

    /// Status is user-extensible post-Phase-2: --add-option must succeed on it.
    /// We add a unique option, verify it lands, and clean up via --delete-option
    /// so the test can run multiple times without drift.
    func testPropertiesAddOptionToStatusSucceeds() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let statusProp = all.first(where: { ($0["defaultFieldKey"] as? String) == "readingStatus" }),
              let idStr = statusProp["id"] as? String else {
            XCTFail("Status PropertyDefinition not seeded")
            return
        }
        let testValue = "TestStatus-\(UUID().uuidString.prefix(8))"
        defer { _ = try? runCLI(["properties", "--delete-option", "--id", idStr, "--value", testValue]) }

        let result = try runCLI(["properties", "--add-option", "--id", idStr, "--value", testValue])
        XCTAssertEqual(result.exitCode, 0, "Status options are user-extensible: \(result.stderr)")

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        let updated = after.first { ($0["id"] as? String) == idStr }
        let optionValues = (updated?["options"] as? [[String: Any]])?.compactMap { $0["value"] as? String } ?? []
        XCTAssertTrue(optionValues.contains(testValue), "added option must appear in the live options list")
    }

    /// Renaming a Status option via the CLI bulk-updates the affected
    /// reference rows. Smoke-tests the round-trip end-to-end against the
    /// real binary.
    func testPropertiesRenameOptionRoundTrip() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let statusProp = all.first(where: { ($0["defaultFieldKey"] as? String) == "readingStatus" }),
              let idStr = statusProp["id"] as? String else {
            XCTFail("Status PropertyDefinition not seeded")
            return
        }
        let original = "RenameTest-\(UUID().uuidString.prefix(8))"
        let renamed = "RenameTest-\(UUID().uuidString.prefix(8))"
        defer {
            _ = try? runCLI(["properties", "--delete-option", "--id", idStr, "--value", original])
            _ = try? runCLI(["properties", "--delete-option", "--id", idStr, "--value", renamed])
        }
        _ = try runCLI(["properties", "--add-option", "--id", idStr, "--value", original])

        let result = try runCLI([
            "properties", "--rename-option", "--id", idStr,
            "--from", original, "--to", renamed,
        ])
        XCTAssertEqual(result.exitCode, 0, "rename must succeed: \(result.stderr)")

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        let updated = after.first { ($0["id"] as? String) == idStr }
        let optionValues = (updated?["options"] as? [[String: Any]])?.compactMap { $0["value"] as? String } ?? []
        XCTAssertFalse(optionValues.contains(original), "old option name must be gone")
        XCTAssertTrue(optionValues.contains(renamed), "new option name must be present")
    }

    /// --delete-option --clear-in-use removes an in-use option (which would
    /// otherwise error with optionInUse) and clears it from affected
    /// references. Round-trips against a throwaway custom singleSelect property.
    func testPropertiesDeleteOptionClearInUseClearsReferenceValues() throws {
        try skipIfBinaryMissing()
        let propName = "ClearInUse-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["properties", "--create", "--name", propName, "--type", "singleSelect", "--options", "Alpha,Beta"])
        XCTAssertEqual(created.exitCode, 0, "create failed: \(created.stderr)")
        guard let createdJSON = try JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any],
              let propId = createdJSON["id"] as? String else {
            XCTFail("could not parse created property id from \(created.stdout)")
            return
        }
        let addRef = try runCLI(["add", "--title", "ClearInUse Ref \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addRef.stdout.utf8)) else {
            XCTFail("add reference failed: \(addRef.stderr)")
            return
        }
        defer {
            _ = try? runCLI(["delete", String(refId), "--force"])
            _ = try? runCLI(["properties", "--delete", propId])
        }

        let setResult = try runCLI(["properties", "--set", "--reference", String(refId), "--id", propId, "--value", "Alpha"])
        XCTAssertEqual(setResult.exitCode, 0, "set failed: \(setResult.stderr)")

        let del = try runCLI(["properties", "--delete-option", "--id", propId, "--value", "Alpha", "--clear-in-use"])
        XCTAssertEqual(del.exitCode, 0, "clear-in-use delete must succeed on an in-use option: \(del.stderr)")

        let afterProps = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        let updated = afterProps.first { ($0["id"] as? String) == propId }
        let optionValues = (updated?["options"] as? [[String: Any]])?.compactMap { $0["value"] as? String } ?? []
        XCTAssertFalse(optionValues.contains("Alpha"), "deleted option must be gone")
        XCTAssertTrue(optionValues.contains("Beta"), "other options must survive")

        let refValues = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties", "--reference", String(refId)]).stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(refValues.contains { ($0["propertyId"] as? String) == propId }, "reference value must be cleared")
    }

    /// --clear-in-use and --replace-with are conflicting dispositions; passing
    /// both fails with a clear message rather than silently picking one.
    func testPropertiesDeleteOptionClearAndReplaceConflict() throws {
        try skipIfBinaryMissing()
        let propName = "ClearConflict-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["properties", "--create", "--name", propName, "--type", "singleSelect", "--options", "Alpha,Beta"])
        XCTAssertEqual(created.exitCode, 0, "create failed: \(created.stderr)")
        guard let createdJSON = try JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any],
              let propId = createdJSON["id"] as? String else {
            XCTFail("could not parse created property id")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", propId]) }

        let result = try runCLI(["properties", "--delete-option", "--id", propId, "--value", "Alpha", "--replace-with", "Beta", "--clear-in-use"])
        XCTAssertNotEqual(result.exitCode, 0, "conflicting dispositions must fail")
        XCTAssertTrue(
            (result.stdout + result.stderr).lowercased().contains("either"),
            "error should explain the conflict: \(result.stdout) \(result.stderr)"
        )
    }

    func testPropertiesSetDefaultPropertyIsRefused() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "CLI Default Guard \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        // Pick a default property OTHER than Tags. Tags routes through
        // setTags transparently and is intentionally writable via --set;
        // the guard must still fire for column-backed defaults like DOI/Year.
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let defaultProp = all.first(where: {
                  ($0["isDefault"] as? Bool) == true
                      && ($0["defaultFieldKey"] as? String) != "tags"
              }),
              let defaultIdStr = defaultProp["id"] as? String else {
            XCTFail("No non-Tags default property seeded")
            return
        }

        let setResult = try runCLI(["properties", "--set",
                                    "--reference", String(refId),
                                    "--id", defaultIdStr,
                                    "--value", "bogus"])
        XCTAssertNotEqual(setResult.exitCode, 0, "--set on a column-backed built-in must fail")

        let listed = try runCLI(["properties", "--reference", String(refId)])
        let arr = try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(arr.contains { ($0["propertyId"] as? String) == defaultIdStr },
                       "built-in property must not be stored as a propertyValue row")
    }

    // MARK: - Properties: --id / --name selectors

    /// Selectors filter the list to a subset, in sortOrder. Empty selectors
    /// fall back to "return all".
    func testPropertiesIdNameSelectorsReturnSubset() throws {
        try skipIfBinaryMissing()
        // Read a couple of known defaults to use as targets.
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let typeProp = all.first(where: { ($0["defaultFieldKey"] as? String) == "referenceType" }),
              let typeIdStr = typeProp["id"] as? String,
              let typeId = Int64(typeIdStr) else {
            XCTFail("Type property not seeded")
            return
        }
        let result = try runCLI(["properties", "--id", String(typeId), "--name", "Tags"])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] ?? []
        let names = Set(arr.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["Type", "Tags"])
    }

    /// Unresolved selectors must exit non-zero with an `unresolved-selectors`
    /// error envelope so scripts notice missing inputs.
    func testPropertiesUnresolvedSelectorErrorsLoudly() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["properties", "--name", "DefinitelyNotAProperty-\(UUID().uuidString.prefix(6))"])
        XCTAssertNotEqual(result.exitCode, 0)
        let env = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(env?["error"] as? String, "unresolved-selectors")
        let names = env?["names"] as? [String] ?? []
        XCTAssertFalse(names.isEmpty, "unresolved names must surface in the error envelope")
    }

    /// Explicit selectors win over `--visible` filtering — the caller asked
    /// for the property by id/name, so the hidden state shouldn't drop it.
    func testPropertiesIdSelectorOverridesVisibleFilter() throws {
        try skipIfBinaryMissing()
        // Create a hidden custom property.
        let unique = "cli-vis-override-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["properties", "--create", "--name", unique, "--type", "string"])
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }
        _ = try runCLI(["properties", "--hide", "--id", String(propId)])

        // --visible alone hides it.
        let visibleOnly = try runCLI(["properties", "--visible"])
        let visArr = try JSONSerialization.jsonObject(with: Data(visibleOnly.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(visArr.contains { ($0["id"] as? String) == String(propId) })

        // --id <hidden> + --visible still returns it.
        let withId = try runCLI(["properties", "--visible", "--id", String(propId)])
        XCTAssertEqual(withId.exitCode, 0, "stderr=\(withId.stderr)")
        let arr = try JSONSerialization.jsonObject(with: Data(withId.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr.first?["id"] as? String, String(propId))
    }

    // MARK: - Properties: --add-value / --remove-value (Tags + custom multiSelect)

    /// Tags-property additive/subtractive flow end-to-end against the binary.
    /// Verifies idempotency (re-adding a tag is a no-op) and that the result
    /// flows back into `properties --reference`'s value.
    func testPropertiesAddRemoveValueOnTagsProperty() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "CLI Tag-via-prop \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }

        // Locate the seeded Tags PropertyDefinition.
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let tagsDef = all.first(where: { ($0["defaultFieldKey"] as? String) == "tags" }),
              let tagsIdStr = tagsDef["id"] as? String else {
            XCTFail("Tags PropertyDefinition not seeded")
            return
        }

        // Create two fresh tags via --add-option (creates Tag rows, returns ids as `value`).
        let nameA = "cli-tag-a-\(UUID().uuidString.prefix(6))"
        let nameB = "cli-tag-b-\(UUID().uuidString.prefix(6))"
        let addA = try runCLI(["properties", "--add-option", "--id", tagsIdStr, "--value", nameA])
        XCTAssertEqual(addA.exitCode, 0, "stderr=\(addA.stderr)")
        let addB = try runCLI(["properties", "--add-option", "--id", tagsIdStr, "--value", nameB])
        XCTAssertEqual(addB.exitCode, 0, "stderr=\(addB.stderr)")

        // Re-fetch to learn the new tag ids (they are returned as `value`).
        let afterAdd = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties", "--name", "Tags"]).stdout.utf8)) as? [[String: Any]] ?? []
        let optionsA = (afterAdd.first?["options"] as? [[String: Any]]) ?? []
        guard let aId = optionsA.first(where: { ($0["label"] as? String) == nameA })?["value"] as? String,
              let bId = optionsA.first(where: { ($0["label"] as? String) == nameB })?["value"] as? String else {
            XCTFail("created tags not visible as inline options on the Tags property")
            return
        }
        // Single combined cleanup with explicit ordering so we don't rely on
        // defer LIFO semantics (which would otherwise try to delete the tags
        // while the reference still pins them, fail with optionInUse, and
        // leak the test tags into the developer's real library).
        defer {
            _ = try? runCLI(["delete", String(refId), "--force"])
            _ = try? runCLI(["properties", "--delete-option", "--id", tagsIdStr, "--value", aId])
            _ = try? runCLI(["properties", "--delete-option", "--id", tagsIdStr, "--value", bId])
        }

        // Helper: read the Tags-property value out of `properties --reference <ref>`.
        // The CLI surface for "what tags does this ref have?" is the same for
        // tags and any other multi-select property — that's the whole point
        // of the unification.
        func currentTagIds() throws -> Set<String> {
            let listed = try runCLI(["properties", "--reference", String(refId)])
            XCTAssertEqual(listed.exitCode, 0)
            let arr = try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] ?? []
            guard let entry = arr.first(where: { ($0["propertyId"] as? String) == tagsIdStr }),
                  let storedJSON = entry["value"] as? String,
                  let decoded = try JSONSerialization.jsonObject(with: Data(storedJSON.utf8)) as? [String] else {
                return []
            }
            return Set(decoded)
        }

        // --add-value: assign both tags to the reference (additive).
        let assigned = try runCLI([
            "properties", "--set", "--add-value",
            "--reference", String(refId),
            "--id", tagsIdStr,
            "--value", "\(aId),\(bId)",
        ])
        XCTAssertEqual(assigned.exitCode, 0, "stderr=\(assigned.stderr)")
        let after1 = try currentTagIds()
        XCTAssertTrue(after1.contains(aId), "ref should carry tag A after --add-value")
        XCTAssertTrue(after1.contains(bId), "ref should carry tag B after --add-value")

        // Idempotent: re-adding aId is a no-op.
        let again = try runCLI([
            "properties", "--set", "--add-value",
            "--reference", String(refId),
            "--id", tagsIdStr,
            "--value", aId,
        ])
        XCTAssertEqual(again.exitCode, 0)
        let after2 = try currentTagIds()
        XCTAssertEqual(after2, after1, "re-adding an existing tag must be idempotent")

        // --remove-value: drop one tag, keep the other.
        let removed = try runCLI([
            "properties", "--set", "--remove-value",
            "--reference", String(refId),
            "--id", tagsIdStr,
            "--value", aId,
        ])
        XCTAssertEqual(removed.exitCode, 0)
        let after3 = try currentTagIds()
        XCTAssertFalse(after3.contains(aId), "tag A must be gone after --remove-value")
        XCTAssertTrue(after3.contains(bId), "tag B must remain")

        // Idempotent: removing absent tag is a no-op.
        let removeAgain = try runCLI([
            "properties", "--set", "--remove-value",
            "--reference", String(refId),
            "--id", tagsIdStr,
            "--value", aId,
        ])
        XCTAssertEqual(removeAgain.exitCode, 0)
    }

    func testPropertiesSetMultiSelectEncodesJSON() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "CLI Multi Test \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        let propResult = try runCLI(["properties", "--create",
                                     "--name", "cli-multi-\(UUID().uuidString.prefix(8))",
                                     "--type", "multiSelect",
                                     "--options", "todo,doing,done"])
        guard let propId = parseId(from: Data(propResult.stdout.utf8)) else {
            XCTFail("create prop failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        // Pass comma-separated values; CLI must store them as JSON-encoded [String]
        // so the app's multi-select decoder can read them.
        let setResult = try runCLI(["properties", "--set",
                                    "--reference", String(refId),
                                    "--id", String(propId),
                                    "--value", "todo,doing"])
        XCTAssertEqual(setResult.exitCode, 0)

        let listed = try runCLI(["properties", "--reference", String(refId)])
        let arr = try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] ?? []
        guard let entry = arr.first(where: { ($0["propertyId"] as? String) == String(propId) }),
              let storedJSON = entry["value"] as? String,
              let decoded = try JSONSerialization.jsonObject(with: Data(storedJSON.utf8)) as? [String] else {
            XCTFail("stored multiSelect value should decode as a JSON string array; got \(arr)")
            return
        }
        XCTAssertEqual(decoded, ["todo", "doing"])
    }

    func testPropertiesClearUnknownPropertyIsRefused() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "CLI Clear Guard \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        let result = try runCLI(["properties", "--clear",
                                 "--reference", String(refId),
                                 "--id", "999999999"])
        XCTAssertNotEqual(result.exitCode, 0, "--clear with an unknown property id must fail")
        let errData = Data(result.stderr.utf8)
        if let errJson = try? JSONSerialization.jsonObject(with: errData) as? [String: Any] {
            XCTAssertNotNil(errJson["error"], "stderr should be a JSON error object")
        }
    }

    func testAddBibTeXDedupePreservesExistingCustomProperties() throws {
        try skipIfBinaryMissing()

        // 1. Create a reference, attach a custom property value to it.
        let title = "CLI Add Dedupe \(UUID().uuidString.prefix(8))"
        let bib = """
        @article{cli-dedupe-\(UUID().uuidString.prefix(6)),
          title = {\(title)},
          author = {Smith, John},
          year = {2024},
          doi = {10.9999/cli-dedupe-\(UUID().uuidString.prefix(6))}
        }
        """

        let firstAdd = try runCLI(["add", "--bibtex", bib])
        XCTAssertEqual(firstAdd.exitCode, 0)
        let firstArr = try JSONSerialization.jsonObject(with: Data(firstAdd.stdout.utf8)) as? [[String: Any]] ?? []
        guard let firstObj = firstArr.first,
              let firstRef = firstObj["reference"] as? [String: Any],
              let refIdInt = firstRef["id"] as? Int64 ?? (firstRef["id"] as? Int).map(Int64.init) else {
            XCTFail("first add should return JSON array of envelopes with reference.id")
            return
        }
        XCTAssertEqual(firstObj["status"] as? String, "created",
                       "first add should report status=created")
        let refId = refIdInt
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        let propResult = try runCLI(["properties", "--create",
                                     "--name", "cli-dedupe-prop-\(UUID().uuidString.prefix(8))",
                                     "--type", "string"])
        guard let propId = parseId(from: Data(propResult.stdout.utf8)) else {
            XCTFail("create prop failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let setResult = try runCLI(["properties", "--set",
                                    "--reference", String(refId),
                                    "--id", String(propId),
                                    "--value", "preserve-me"])
        XCTAssertEqual(setResult.exitCode, 0)

        // 2. Re-add the same BibTeX entry. saveReference should dedupe onto the
        // existing row; the echoed ReferenceDTO must surface the existing
        // customProperties, not an empty array.
        let secondAdd = try runCLI(["add", "--bibtex", bib])
        XCTAssertEqual(secondAdd.exitCode, 0)
        let secondArr = try JSONSerialization.jsonObject(with: Data(secondAdd.stdout.utf8)) as? [[String: Any]] ?? []
        guard let secondObj = secondArr.first,
              let secondRef = secondObj["reference"] as? [String: Any] else {
            XCTFail("second add should return JSON array of envelopes")
            return
        }
        XCTAssertEqual(secondObj["status"] as? String, "existing",
                       "re-add of duplicate BibTeX must report status=existing")
        let custom = secondRef["customProperties"] as? [[String: Any]] ?? []
        XCTAssertTrue(custom.contains { ($0["value"] as? String) == "preserve-me" },
                      "dedup-add output must echo existing custom properties; got \(custom)")
    }

    func testAddTitleEmitsCreatedStatus() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "Created-Status \(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0)
        let json = try JSONSerialization.jsonObject(with: Data(addResult.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "created",
                       "title-add should always report status=created")
        guard let refDict = json?["reference"] as? [String: Any],
              let refId = refDict["id"] as? Int64 ?? (refDict["id"] as? Int).map(Int64.init) else {
            XCTFail("Add envelope should contain reference.id")
            return
        }
        _ = try runCLI(["delete", "\(refId)", "--force"])
    }

    func testAddIdentifierStatusEnvelopeShape() throws {
        try skipIfBinaryMissing()

        // Use --title to avoid network. Asserts envelope contract:
        //   - top-level keys: reference, status, pdfDownload
        //   - pdfDownload is explicit null (not key-absent) when --download-pdf not set
        let addResult = try runCLI(["add", "--title", "Envelope-Shape \(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0)
        let json = try JSONSerialization.jsonObject(with: Data(addResult.stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(json?["reference"], "envelope must have reference key")
        XCTAssertNotNil(json?["status"], "envelope must have status key")
        XCTAssertTrue(json?.keys.contains("pdfDownload") ?? false,
                      "envelope must have pdfDownload key, even when --download-pdf not set")
        XCTAssertTrue(json?["pdfDownload"] is NSNull,
                      "pdfDownload should be explicit null (NSNull) when --download-pdf not set; got \(String(describing: json?["pdfDownload"]))")
        if let refDict = json?["reference"] as? [String: Any],
           let refId = refDict["id"] as? Int64 ?? (refDict["id"] as? Int).map(Int64.init) {
            _ = try runCLI(["delete", "\(refId)", "--force"])
        }
    }

    func testExportJSONIncludesCustomPropertiesField() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "json"])
        XCTAssertEqual(result.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] ?? []
        if let first = arr.first {
            XCTAssertNotNil(first["customProperties"], "every reference should carry a customProperties array")
            XCTAssertTrue(first["customProperties"] is [Any], "customProperties must be an array")
        }
    }

    /// Fresh references must always carry `readCount: 0` and must NOT carry a
    /// `lastReadAt` key at all (Swift `Date?` → key omitted when nil). This
    /// pins the JSON contract that the MCP server's zod schema relies on.
    func testGetIncludesReaderActivityFields() throws {
        try skipIfBinaryMissing()
        let addResult = try runCLI(["add", "--title", "ReaderActivity-\(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0)
        let addObj = try JSONSerialization.jsonObject(with: Data(addResult.stdout.utf8)) as? [String: Any]
        guard let refDict = addObj?["reference"] as? [String: Any],
              let refId = refDict["id"] as? Int64 ?? (refDict["id"] as? Int).map(Int64.init) else {
            XCTFail("add envelope must contain reference.id")
            return
        }
        defer { _ = try? runCLI(["delete", "\(refId)", "--force"]) }

        let getResult = try runCLI(["get", "\(refId)"])
        XCTAssertEqual(getResult.exitCode, 0)
        let getObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(getResult.stdout.utf8)) as? [String: Any]
        )

        XCTAssertEqual(getObj["readCount"] as? Int, 0,
                       "fresh references must report readCount=0 in JSON output")
        XCTAssertFalse(getObj.keys.contains("lastReadAt"),
                       "never-opened references must omit lastReadAt entirely (Swift Date? → absent key)")
    }

    /// `export --format json` must emit the same reader-activity fields for
    /// every reference. Spot-check the first row.
    func testExportIncludesReaderActivityFields() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "json"])
        XCTAssertEqual(result.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] ?? []
        guard let first = arr.first else {
            // No references in the library; nothing to assert against.
            return
        }
        XCTAssertNotNil(first["readCount"], "every exported reference must carry readCount (non-optional in JSON)")
    }

    // MARK: - Views
    //
    // These tests lock the JSON contract for the `views` subcommand:
    // the tagged-union shapes for FieldTarget / FilterValue / GroupConfig,
    // the DTO fields emitted on create/list/rename, and the default-view
    // protections. Scripts depend on this wire format.

    private func parseInt64(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    private func defaultViewId() throws -> Int64? {
        let result = try runCLI(["views"])
        guard result.exitCode == 0,
              let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]],
              let def = arr.first(where: { ($0["isDefault"] as? Bool) == true }) else {
            return nil
        }
        return parseInt64(def["id"])
    }

    func testViewsListIncludesDefault() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["views"])
        XCTAssertEqual(result.exitCode, 0, "views list should succeed; stderr=\(result.stderr)")
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] ?? []
        let defaultView = arr.first { ($0["isDefault"] as? Bool) == true }
        XCTAssertNotNil(defaultView, "a default view must be seeded by the migration")
        XCTAssertEqual(defaultView?["name"] as? String, "All References")
        XCTAssertTrue(defaultView?["filters"] is [Any], "filters must be an array")
        XCTAssertTrue(defaultView?["sorts"] is [Any], "sorts must be an array")
        // groupBy may be null or an object — the user can group on any view.
        // Just verify it's one of those shapes (i.e., the key is always present).
        XCTAssertTrue(defaultView?.keys.contains("groupBy") ?? false,
                      "groupBy must be present in DTO (null or object)")
    }

    func testViewsCreateWithStructuredFilters() throws {
        try skipIfBinaryMissing()
        let viewName = "cli-view-\(UUID().uuidString.prefix(8))"
        let filters = """
            [{"target":{"kind":"builtin","value":"readingStatus"},\
            "op":"isAnyOf",\
            "value":{"kind":"selectKeys","value":["reading","read"]}}]
            """
        let sorts = """
            [{"target":{"kind":"builtin","value":"dateAdded"},"ascending":false}]
            """
        let result = try runCLI(["views", "--create", "--name", viewName,
                                 "--filters", filters, "--sorts", sorts])
        XCTAssertEqual(result.exitCode, 0, "create should succeed; stderr=\(result.stderr)")
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        defer {
            if let id = parseInt64(obj?["id"]) { _ = try? runCLI(["views", "--delete", String(id)]) }
        }
        XCTAssertEqual(obj?["name"] as? String, viewName)

        let roundTripFilters = obj?["filters"] as? [[String: Any]] ?? []
        XCTAssertEqual(roundTripFilters.count, 1)
        let target = roundTripFilters.first?["target"] as? [String: Any]
        XCTAssertEqual(target?["kind"] as? String, "builtin")
        XCTAssertEqual(target?["value"] as? String, "readingStatus")
        XCTAssertEqual(roundTripFilters.first?["op"] as? String, "isAnyOf")
        let filterValue = roundTripFilters.first?["value"] as? [String: Any]
        XCTAssertEqual(filterValue?["kind"] as? String, "selectKeys")
        XCTAssertEqual(filterValue?["value"] as? [String], ["reading", "read"])

        let roundTripSorts = obj?["sorts"] as? [[String: Any]] ?? []
        XCTAssertEqual(roundTripSorts.count, 1)
        let sortTarget = roundTripSorts.first?["target"] as? [String: Any]
        XCTAssertEqual(sortTarget?["kind"] as? String, "builtin")
        XCTAssertEqual(sortTarget?["value"] as? String, "dateAdded")
        XCTAssertEqual(roundTripSorts.first?["ascending"] as? Bool, false)
    }

    func testViewsCreateWithGroupBy() throws {
        try skipIfBinaryMissing()
        let viewName = "cli-view-group-\(UUID().uuidString.prefix(8))"
        let groupBy = """
            {"target":{"kind":"builtin","value":"dateAdded"},\
            "dateBin":"month","collapsed":[],"showEmpty":false}
            """
        let result = try runCLI(["views", "--create", "--name", viewName, "--group-by", groupBy])
        XCTAssertEqual(result.exitCode, 0, "create should succeed; stderr=\(result.stderr)")
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        defer {
            if let id = parseInt64(obj?["id"]) { _ = try? runCLI(["views", "--delete", String(id)]) }
        }

        let group = obj?["groupBy"] as? [String: Any]
        XCTAssertNotNil(group, "groupBy must round-trip")
        XCTAssertEqual(group?["dateBin"] as? String, "month")
        XCTAssertEqual(group?["showEmpty"] as? Bool, false)
        let target = group?["target"] as? [String: Any]
        XCTAssertEqual(target?["kind"] as? String, "builtin")
        XCTAssertEqual(target?["value"] as? String, "dateAdded")
    }

    func testViewsCreateWithInvalidFiltersJSONFails() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["views", "--create",
                                 "--name", "cli-invalid-\(UUID().uuidString.prefix(8))",
                                 "--filters", "not-valid-json"])
        XCTAssertNotEqual(result.exitCode, 0, "malformed JSON should exit non-zero")
        XCTAssertTrue(result.stderr.contains("--filters") || result.stdout.contains("\"error\""),
                      "error output should mention the offending flag or be a JSON error object")
    }

    func testViewsRename() throws {
        try skipIfBinaryMissing()
        let original = "cli-rename-view-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["views", "--create", "--name", original])
        XCTAssertEqual(created.exitCode, 0)
        let createdObj = try JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any]
        guard let id = parseInt64(createdObj?["id"]) else {
            XCTFail("create did not return an id")
            return
        }
        defer { _ = try? runCLI(["views", "--delete", String(id)]) }

        let renamed = original + "-renamed"
        let result = try runCLI(["views", "--rename", String(id), "--name", renamed])
        XCTAssertEqual(result.exitCode, 0, "rename should succeed; stderr=\(result.stderr)")
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["name"] as? String, renamed)
    }

    func testViewsDeleteDefaultIsRefused() throws {
        try skipIfBinaryMissing()
        guard let id = try defaultViewId() else {
            XCTFail("default view not found")
            return
        }
        let result = try runCLI(["views", "--delete", String(id)])
        XCTAssertNotEqual(result.exitCode, 0, "deleting the default view must be refused")
    }

    func testViewsQueryReturnsReferenceArray() throws {
        try skipIfBinaryMissing()
        guard let id = try defaultViewId() else {
            XCTFail("default view not found")
            return
        }
        let result = try runCLI(["views", "--query", String(id), "--limit", "5"])
        XCTAssertEqual(result.exitCode, 0, "query should succeed; stderr=\(result.stderr)")
        let refs = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
        XCTAssertNotNil(refs, "query output should be a JSON array of references")
    }

    // MARK: - Import: Markdown files and --format md stdin

    func testImportMarkdownFile() throws {
        // Sentinel of a different type so the --type filters below can't
        // pass vacuously.
        let addResult = try runCLI(["add", "--title", "Sentinel Article"])
        XCTAssertEqual(addResult.exitCode, 0, addResult.stderr)

        let md = """
        ---
        title: "Clip Title"
        source: "https://example.com/clip"
        published: 2026-06-13
        ---
        Clip body.
        """
        let file = testLibraryRoot.appendingPathComponent("clip.md")
        try md.write(to: file, atomically: true, encoding: .utf8)

        let result = try runCLI(["import", file.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1")

        let list = try runCLI(["list", "--type", "Web Page"])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 1, "only the clip is a Web Page; sentinel filtered out")
        XCTAssertEqual(rows.first?["title"] as? String, "Clip Title")
        XCTAssertEqual(rows.first?["referenceType"] as? String, "Web Page")
    }

    func testImportMarkdownStdinTitlesUntitled() throws {
        let result = try runCLI(["import", "-", "--format", "md"], stdin: "no frontmatter body")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let list = try runCLI(["list", "--type", "Markdown"])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        XCTAssertTrue(list.stdout.contains("Untitled"))
    }

    func testStdinWithoutFormatMentionsMd() throws {
        let result = try runCLI(["import", "-"], stdin: "x")
        XCTAssertNotEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("md"), "error text must list md as a valid format: \(combined)")
    }

    func testImportMarkdownNoteGetsMarkdownType() throws {
        _ = try runCLI(["add", "--title", "Sentinel Article"])
        let file = testLibraryRoot.appendingPathComponent("note.md")
        try "# Plain Note\nBody".write(to: file, atomically: true, encoding: .utf8)
        let imported = try runCLI(["import", file.path])
        XCTAssertEqual(imported.exitCode, 0, imported.stderr)

        let list = try runCLI(["list", "--type", "Markdown"])
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["title"] as? String, "Plain Note")
    }

    func testImportNonUTF8MarkdownEmitsJSONError() throws {
        let file = testLibraryRoot.appendingPathComponent("latin1.md")
        let latin1 = Data([0x23, 0x20, 0xE9, 0xE8, 0xFF])   // "# " + Latin-1 bytes, invalid UTF-8
        try latin1.write(to: file)
        let result = try runCLI(["import", file.path])
        XCTAssertNotEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("error"), "JSON error contract expected: \(combined)")
        XCTAssertTrue(combined.contains("latin1.md"), "error names the file")
    }

    /// Spec §10 export mappings: Markdown → BibTeX @misc, RIS TY GEN.
    func testMarkdownTypeExportMappings() throws {
        let file = testLibraryRoot.appendingPathComponent("note.md")
        try "# Export Me\nBody".write(to: file, atomically: true, encoding: .utf8)
        let imported = try runCLI(["import", file.path])
        XCTAssertEqual(imported.exitCode, 0, imported.stderr)

        let bib = try runCLI(["export", "--format", "bibtex"])
        XCTAssertEqual(bib.exitCode, 0, bib.stderr)
        XCTAssertTrue(bib.stdout.contains("@misc{"), bib.stdout)

        let ris = try runCLI(["export", "--format", "ris"])
        XCTAssertEqual(ris.exitCode, 0, ris.stderr)
        XCTAssertTrue(ris.stdout.contains("TY  - GEN"), ris.stdout)
    }

    // MARK: - Markdown folder import (Task 9)

    private func makeClippingsFolder(_ name: String, files: [String: String]) throws -> URL {
        let dir = testLibraryRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (filename, content) in files {
            try content.write(
                to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8
            )
        }
        return dir
    }

    /// Resolve the built-in Tags option id for a tag name (label), or nil.
    /// `list --tag` filters by numeric tag id, so we look the id up through
    /// `properties --name Tags` inline options exactly like the sibling
    /// multi-select tests (each option's `value` is the stringified tag id).
    private func tagOptionId(label: String) throws -> String? {
        let defs = try JSONSerialization.jsonObject(
            with: Data(try runCLI(["properties", "--name", "Tags"]).stdout.utf8)
        ) as? [[String: Any]] ?? []
        let options = (defs.first?["options"] as? [[String: Any]]) ?? []
        return options.first { ($0["label"] as? String) == label }?["value"] as? String
    }

    func testImportMarkdownFolderStampsTagsWithBasename() throws {
        let dir = try makeClippingsFolder("Clippings", files: [
            "a.md": "# Note A\nBody A",
            "b.md": "# Note B\nBody B",
        ])
        let result = try runCLI(["import", dir.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "2")
        XCTAssertEqual(obj["failed"], "")
        XCTAssertEqual(obj["property"], "Tags")
        XCTAssertEqual(obj["value"], "Clippings")

        // Stamping must be REAL, not just reported: resolve the "Clippings"
        // tag's numeric id, then confirm the referenceTag pivot actually pins
        // both notes via `list --tag` (a name-only echo would leave it empty).
        let tagId = try XCTUnwrap(
            try tagOptionId(label: "Clippings"), "stamp must create a 'Clippings' tag"
        )
        let list = try runCLI(["list", "--tag", tagId])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        XCTAssertTrue(list.stdout.contains("Note A"))
        XCTAssertTrue(list.stdout.contains("Note B"))
    }

    func testImportMarkdownFolderPropertyValueOverride() throws {
        let dir = try makeClippingsFolder("Clips2", files: ["c.md": "# Note C\nBody"])
        let result = try runCLI([
            "import", dir.path, "--property", "Tags", "--value", "custom-tag",
        ])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["value"], "custom-tag")
        let tagId = try XCTUnwrap(try tagOptionId(label: "custom-tag"))
        let list = try runCLI(["list", "--tag", tagId])
        XCTAssertTrue(list.stdout.contains("Note C"))
    }

    func testImportMarkdownFolderReportsFailedFiles() throws {
        let dir = try makeClippingsFolder("Mixed2", files: ["good.md": "# Good\nBody"])
        let bad = Data([0x23, 0x20, 0xE9, 0xE8, 0xFF])   // invalid UTF-8
        try bad.write(to: dir.appendingPathComponent("bad.md"))

        let result = try runCLI(["import", dir.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1", "valid file still imports")
        XCTAssertEqual(obj["failed"], "bad.md")
    }

    func testAmbiguousFolderErrorsAndFormatForces() throws {
        let dir = try makeClippingsFolder("Ambiguous", files: [
            "refs.bib": "@article{k, title={T}, year={2020}}",
            "note.md": "# N\nB",
        ])
        let ambiguous = try runCLI(["import", dir.path])
        XCTAssertNotEqual(ambiguous.exitCode, 0)
        let combined = ambiguous.stdout + ambiguous.stderr
        XCTAssertTrue(combined.contains("Ambiguous folder"), combined)

        let forced = try runCLI(["import", dir.path, "--format", "md"])
        XCTAssertEqual(forced.exitCode, 0, forced.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(forced.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1")
    }

    func testEmptyFolderErrors() throws {
        let dir = try makeClippingsFolder("Empty", files: [:])
        let result = try runCLI(["import", dir.path])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - Markdown folder import (Phase-2 error-contract fixes)

    /// Fix 1: stamping the folder name onto a number/date/checkbox property is
    /// unsupported. The markdown folder path must report it through the JSON
    /// error contract (exactly like the Zotero path) instead of letting the
    /// throw escape to ArgumentParser as bare usage text. `Year` is a built-in
    /// number property, so `--property Year` exercises the incompatible-type arm.
    func testImportMarkdownFolderIncompatiblePropertyTypeEmitsJSONError() throws {
        let dir = try makeClippingsFolder("YearStamp", files: ["a.md": "# Note A\nBody"])
        let result = try runCLI(["import", dir.path, "--property", "Year"])
        XCTAssertNotEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        // A JSON {"error":…} envelope on stderr, not ArgumentParser usage text.
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: String],
            "expected a JSON error envelope, got: \(combined)"
        )
        XCTAssertNotNil(obj["error"], "error envelope must carry an `error` key")
        XCTAssertFalse(
            combined.lowercased().contains("usage:"),
            "must be the JSON error contract, not ArgumentParser usage text: \(combined)"
        )
    }

    /// Fix 2: a folder whose only .md files all fail to read (here: invalid
    /// UTF-8) must exit non-zero — consistent with single-file mode, where one
    /// unreadable .md already exits non-zero — instead of silently printing a
    /// success envelope with imported:"0".
    func testImportMarkdownFolderAllUnreadableExitsNonZero() throws {
        let dir = try makeClippingsFolder("AllBad", files: [:])
        let bad = Data([0x23, 0x20, 0xE9, 0xE8, 0xFF])   // "# " + invalid UTF-8
        try bad.write(to: dir.appendingPathComponent("bad.md"))

        let result = try runCLI(["import", dir.path])
        XCTAssertNotEqual(result.exitCode, 0)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: String],
            "expected a JSON error envelope, got stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        let message = try XCTUnwrap(obj["error"], "error envelope must carry an `error` key")
        XCTAssertTrue(message.contains("bad.md"), "error must name the failed file: \(message)")
    }

    /// Fix 3: routing and import share one enumeration of top-level regular
    /// files, so a *subdirectory* literally named `nested.md` is filtered out of
    /// both — it neither hijacks routing nor lands in `failed`. The real note
    /// beside it still imports.
    func testImportMarkdownFolderIgnoresSubdirectoryNamedMd() throws {
        let dir = try makeClippingsFolder("SubdirMd", files: ["real.md": "# Real Note\nBody"])
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("nested.md", isDirectory: true),
            withIntermediateDirectories: true
        )
        let result = try runCLI(["import", dir.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1", "only the real note imports")
        XCTAssertEqual(obj["failed"], "", "the subdirectory is filtered out, not a failed file")
    }

    /// Fix 3: hidden files (leading dot) are skipped by the shared enumeration
    /// (`.skipsHiddenFiles`, matching ZoteroFolderImporter), so `.hidden.md`
    /// neither imports nor lands in `failed`. Titles are distinctive so the
    /// discriminating `list` check cannot collide with the stamped folder name.
    func testImportMarkdownFolderSkipsHiddenFiles() throws {
        let dir = try makeClippingsFolder("DotfileSkip", files: [
            ".hidden.md": "# HiddenOnlyTitle\nBody",
            "real.md": "# VisibleOnlyTitle\nBody",
        ])
        let result = try runCLI(["import", dir.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1", "only the non-hidden note imports")
        XCTAssertEqual(obj["failed"], "", "hidden file is skipped, not a failed read")

        let list = try runCLI(["list", "--type", "Markdown"])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        XCTAssertTrue(list.stdout.contains("VisibleOnlyTitle"), "the visible note imported")
        XCTAssertFalse(
            list.stdout.contains("HiddenOnlyTitle"),
            "the hidden note must not import: \(list.stdout)"
        )
    }
}
