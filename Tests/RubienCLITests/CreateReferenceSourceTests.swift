import XCTest
import Foundation

/// Black-box §9 routing matrix for `add --source` (spec §5): drives the built
/// CLI binary and asserts the unified envelope + exit-code contract. Network
/// routes (identifier / paper-URL resolution) aren't exercised offline; the
/// route *classification* is unit-tested in `RubienCoreTests.ImportRouterTests`.
final class CreateReferenceSourceTests: XCTestCase {

    private var cliBinaryPath: String {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // RubienCLITests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // project root
            .appendingPathComponent(".build/debug/rubien-cli")
            .path
    }

    private lazy var testLibraryRoot: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rubien-src-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private lazy var workDir: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rubien-src-work-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: testLibraryRoot)
        try? FileManager.default.removeItem(at: workDir)
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run `swift build` first.")
        }
    }

    @discardableResult
    private func runCLI(
        _ arguments: [String],
        stdin: String? = nil,
        currentDirectory: URL? = nil
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        if stdin != nil { process.standardInput = stdinPipe }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter(); queue.async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); queue.async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        try process.run()
        if let stdin {
            let h = stdinPipe.fileHandleForWriting
            h.write(Data(stdin.utf8))
            try h.close()
        }
        process.waitUntilExit()
        group.wait()
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    private func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    private func write(_ contents: String, to name: String) throws -> String {
        let url = workDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - File route

    func testSourceExistingBibFileBatchesWithProvenance() throws {
        try skipIfBinaryMissing()
        let path = try write(
            """
            @article{a, title={First}, author={Smith, J}, year={2020}, doi={10.1/a}}
            @article{b, title={Second}, author={Jones, A}, year={2021}, doi={10.1/b}}
            """, to: "refs.bib")
        let result = try runCLI(["add", "--source", path])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0["status"] as? String }, ["created", "created"])
        XCTAssertEqual(items.map { $0["input"] as? String }, ["\(path)#bibtex[0]", "\(path)#bibtex[1]"])
        let summary = try XCTUnwrap(obj["summary"] as? [String: Any])
        XCTAssertEqual(summary["created"] as? Int, 2)
    }

    func testSourceZeroParsedEntriesFailsNonzero() throws {
        try skipIfBinaryMissing()
        let path = try write("this is not bibtex", to: "junk.bib")
        let result = try runCLI(["add", "--source", path])
        XCTAssertNotEqual(result.exitCode, 0)
        // All-failed envelope goes to stderr.
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "stdout must be empty on the all-failed path; got: \(result.stdout)")
        let obj = try json(result.stderr)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["status"] as? String, "failed")
        XCTAssertNotNil(items[0]["error"])
    }

    func testSourceIntraBatchDuplicateYieldsTwoItemsOneReference() throws {
        try skipIfBinaryMissing()
        let path = try write(
            """
            @article{a, title={T1}, doi={10.9/dup}}
            @article{b, title={T2}, doi={10.9/dup}}
            """, to: "dup.bib")
        let obj = try json(try runCLI(["add", "--source", path]).stdout)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["created", "existing"])
        let id0 = (items[0]["reference"] as? [String: Any])?["id"] as? Int
        let id1 = (items[1]["reference"] as? [String: Any])?["id"] as? Int
        XCTAssertNotNil(id0)
        XCTAssertEqual(id0, id1, "both items point at one reference")
    }

    /// Paths win over identifier-looking strings: a relative file named exactly
    /// like an arXiv id imports as a file (the `doi.org` / `./name` escapes exist
    /// for the reverse).
    func testSourcePathBeatsIdentifier() throws {
        try skipIfBinaryMissing()
        _ = try write("@article{p, title={PathWins}, doi={10.7/pw}}", to: "2501.07888")
        let result = try runCLI(["add", "--source", "2501.07888", "--format", "bib"], currentDirectory: workDir)
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual((items.first?["reference"] as? [String: Any])?["title"] as? String, "PathWins")
    }

    // MARK: - Folder route

    func testSourceMarkdownFolderStampsAndReportsPerFile() throws {
        try skipIfBinaryMissing()
        let folder = workDir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# One\n\nBody".write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# Two\n\nBody".write(to: folder.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        let result = try runCLI(["add", "--source", folder.path, "--property", "Tags", "--value", "batch1"])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        let summary = try XCTUnwrap(obj["summary"] as? [String: Any])
        XCTAssertEqual(summary["created"] as? Int, 2)
        let diag = try XCTUnwrap(obj["diagnostics"] as? [String: Any])
        XCTAssertEqual(diag["property"] as? String, "Tags")
        XCTAssertEqual(diag["value"] as? String, "batch1")
        XCTAssertEqual(diag["file"] as? String, folder.path)
    }

    /// Per-file read failures continue past (a `chmod 000` file becomes a
    /// `failed` item) while a readable sibling succeeds → partial success,
    /// exit 0. Skipped if the unreadable file is still readable (e.g. root).
    func testSourceMarkdownFolderPartialFailureExitsZero() throws {
        try skipIfBinaryMissing()
        let folder = workDir.appendingPathComponent("mixed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Good\n\nBody".write(to: folder.appendingPathComponent("good.md"), atomically: true, encoding: .utf8)
        let bad = folder.appendingPathComponent("bad.md")
        try "# Bad".write(to: bad, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bad.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad.path) }
        // Guard: if we can still read it (root/CI), the partial-failure premise
        // doesn't hold — skip rather than assert a false expectation.
        if (try? String(contentsOf: bad, encoding: .utf8)) != nil {
            throw XCTSkip("unreadable-file premise doesn't hold in this environment")
        }
        let result = try runCLI(["add", "--source", folder.path])
        XCTAssertEqual(result.exitCode, 0, "partial success exits 0; stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        let summary = try XCTUnwrap(obj["summary"] as? [String: Any])
        XCTAssertEqual(summary["created"] as? Int, 1)
        XCTAssertEqual(summary["failed"] as? Int, 1)
    }

    // MARK: - stdin route (CLI only)

    func testSourceStdinRis() throws {
        try skipIfBinaryMissing()
        let ris = "TY  - JOUR\nTI  - RIS Paper\nAU  - Doe, Jane\nPY  - 2019\nER  -\n"
        let result = try runCLI(["add", "--source", "-", "--format", "ris"], stdin: ris)
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["input"] as? String, "ris[0]")
        XCTAssertEqual(items[0]["status"] as? String, "created")
    }

    func testSourceStdinRequiresFormat() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--source", "-"], stdin: "whatever")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("--format"), "stderr should name the missing --format; got: \(result.stderr)")
    }

    // MARK: - Unroutable + option applicability

    func testSourceUnroutableFailsToStderr() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--source", "not an identifier @@@"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let obj = try json(result.stderr)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["status"] as? String, "failed")
    }

    func testDownloadPdfRejectedOnFileRoute() throws {
        try skipIfBinaryMissing()
        let path = try write("@article{a, title={T}, doi={10.1/a}}", to: "one.bib")
        let result = try runCLI(["add", "--source", path, "--download-pdf"])
        XCTAssertNotEqual(result.exitCode, 0)
        let obj = try json(result.stderr)
        XCTAssertTrue((obj["error"] as? String ?? "").contains("identifier or paper-URL source"),
                      "stderr should reject downloadPdf on a non-resolver route; got: \(result.stderr)")
    }

    func testNoDownloadPdfRejectedOnFileRoute() throws {
        try skipIfBinaryMissing()
        let path = try write("@article{a, title={T}, doi={10.1/a}}", to: "two.bib")
        let result = try runCLI(["add", "--source", path, "--no-download-pdf"])
        XCTAssertNotEqual(result.exitCode, 0, "explicit --no-download-pdf on a file route is rejected too")
    }

    func testPropertyRejectedOnFileRoute() throws {
        try skipIfBinaryMissing()
        let path = try write("@article{a, title={T}, doi={10.1/a}}", to: "three.bib")
        let result = try runCLI(["add", "--source", path, "--property", "Tags", "--value", "x"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("folder"), "stderr should say --property/--value apply to folders; got: \(result.stderr)")
    }

    // MARK: - Legacy paths still work (additive rule)

    func testLegacyBibtexEnvelopeUnchanged() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--bibtex", "@article{x, title={Legacy}, doi={10.5/z}}"])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        // Legacy --bibtex still emits a JSON ARRAY of {reference,status,pdfDownload}.
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(arr.first?["status"] as? String, "created")
        XCTAssertNotNil(arr.first?["reference"])
    }

    func testLegacyTitleEnvelopeUnchanged() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--title", "Legacy Title \(UUID().uuidString.prefix(6))"])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        XCTAssertEqual(obj["status"] as? String, "created")
        XCTAssertNotNil(obj["reference"])
        XCTAssertTrue(obj.keys.contains("pdfDownload"), "legacy envelope always carries pdfDownload")
    }
}
