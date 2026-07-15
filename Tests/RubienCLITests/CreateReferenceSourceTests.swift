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

    /// Exactly one input among `--source` / `--bibtex` / `--title` (spec §5.1,
    /// CLI half) — any pair is rejected.
    func testSourceCannotCombineWithLegacyInput() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--source", "10.1/x", "--title", "T"])
        XCTAssertNotEqual(result.exitCode, 0)
        let obj = try json(result.stderr)
        XCTAssertTrue((obj["error"] as? String ?? "").contains("cannot be combined"),
                      "stderr should reject combining --source with another input; got: \(result.stderr)")
    }

    /// Phase-D: `--bibtex` + `--title` is rejected too (the old form silently
    /// let `--bibtex` win).
    func testBibTeXAndTitleCannotCombine() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--bibtex", "@article{x, title={T}}", "--title", "T"])
        XCTAssertNotEqual(result.exitCode, 0)
        let obj = try json(result.stderr)
        XCTAssertTrue((obj["error"] as? String ?? "").contains("cannot be combined"),
                      "stderr should reject combining --bibtex with --title; got: \(result.stderr)")
    }

    /// The route-scoped flags apply to `--source` routes only (§5.1): stray
    /// `--property` / `--format` / `--value` on an inline route is rejected,
    /// not silently ignored.
    func testRouteFlagsRequireSource() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--title", "T \(UUID().uuidString.prefix(6))", "--property", "Tags"])
        XCTAssertNotEqual(result.exitCode, 0)
        let obj = try json(result.stderr)
        XCTAssertTrue((obj["error"] as? String ?? "").contains("require --source"),
                      "stderr should name the constraint; got: \(result.stderr)")
    }

    /// Multi-entry inline BibTeX: one item per parsed entry with
    /// `bibtex[<ordinal>]` provenance (§5.3), tallied in the summary.
    func testInlineBibTeXMultiEntryOrdinalProvenance() throws {
        try skipIfBinaryMissing()
        let bib = """
        @article{ma, title={Multi A}, doi={10.90/ma}}
        @article{mb, title={Multi B}, doi={10.90/mb}}
        """
        let result = try runCLI(["add", "--bibtex", bib])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.compactMap { $0["input"] as? String }, ["bibtex[0]", "bibtex[1]"])
        XCTAssertEqual((obj["summary"] as? [String: Any])?["created"] as? Int, 2)
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

    // MARK: - Inline routes (phase-D cutover: unified envelope on --bibtex / --title)

    func testInlineBibTeXEmitsUnifiedEnvelope() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--bibtex", "@article{x, title={Inline-\(UUID().uuidString.prefix(6))}, doi={10.5/inl-\(UUID().uuidString.prefix(6))}}"])
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        let obj = try json(result.stdout)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["status"] as? String, "created")
        XCTAssertEqual(items[0]["input"] as? String, "bibtex[0]",
                       "inline entries carry ordinal provenance (§5.3)")
        XCTAssertNotNil(items[0]["reference"])
        let summary = try XCTUnwrap(obj["summary"] as? [String: Any])
        XCTAssertEqual(summary["created"] as? Int, 1)
    }

    /// Zero parsed entries is a FAILURE (blessed product call): non-zero exit,
    /// the envelope on stderr with one synthetic failed item whose `input` is
    /// the constant `bibtex` — never the (arbitrarily large) payload itself.
    func testInlineBibTeXZeroEntriesFailsWithEnvelope() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["add", "--bibtex", "not bibtex at all"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "stdout must be empty on the all-failed path; got: \(result.stdout)")
        let obj = try json(result.stderr)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["status"] as? String, "failed")
        XCTAssertEqual(items[0]["input"] as? String, "bibtex")
        XCTAssertNotNil(items[0]["error"])
        XCTAssertEqual((obj["summary"] as? [String: Any])?["failed"] as? Int, 1)
    }

    /// Re-review regression: a forced-format folder that lacks the requested
    /// type is a source-level failure → the unified `items`/`summary` envelope on
    /// stderr, NOT a raw `{"error"}` (matches the unforced empty-folder branch).
    func testForcedFormatEmptyFolderEmitsFailedItemEnvelope() throws {
        try skipIfBinaryMissing()
        let empty = workDir.appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let result = try runCLI(["add", "--source", empty.path, "--format", "bib"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "stdout must be empty on the all-failed path; got: \(result.stdout)")
        let obj = try json(result.stderr)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["status"] as? String, "failed")
        XCTAssertNotNil(items[0]["error"])
        let summary = try XCTUnwrap(obj["summary"] as? [String: Any])
        XCTAssertEqual(summary["failed"] as? Int, 1)
    }
}
