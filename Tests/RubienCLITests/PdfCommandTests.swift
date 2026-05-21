import XCTest
import Foundation

/// Surface-level CLI contract tests for the `pdf` subcommands and the new
/// `search --in` / `--op` flags. These run against the compiled CLI binary and
/// don't require any fixture references — they verify argument parsing, help
/// text, and error envelope shapes for missing resources.
final class PdfCommandTests: XCTestCase {

    private var cliBinaryPath: String {
        let debugPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/rubien-cli")
            .path
        if FileManager.default.isExecutableFile(atPath: debugPath) {
            return debugPath
        }
        return debugPath
    }

    /// Per-test temp dir used as `RUBIEN_LIBRARY_ROOT` for CLI isolation.
    /// See identical pattern in SwiftLibCLITests.swift.
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

    private func runCLI(_ args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        return (
            stdout: String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run `swift build` first.")
        }
    }

    // MARK: - pdf parent help

#if canImport(PDFKit)
    func testPdfHelpListsAllSubcommands() throws {
        try skipIfBinaryMissing()
        let r = try runCLI(["pdf", "--help"])
        XCTAssertEqual(r.exitCode, 0)
        let out = r.stdout + r.stderr
        XCTAssertTrue(out.contains("info"))
        XCTAssertTrue(out.contains("text"))
        XCTAssertTrue(out.contains("page-image"))
    }

    // MARK: - pdf info

    func testPdfInfoRequiresReferenceId() throws {
        try skipIfBinaryMissing()
        let r = try runCLI(["pdf", "info"])
        XCTAssertNotEqual(r.exitCode, 0, "Missing required <id> should fail")
    }

    func testPdfInfoOnUnknownReferenceEmitsErrorEnvelope() throws {
        try skipIfBinaryMissing()
        let r = try runCLI(["pdf", "info", "999999999"])
        XCTAssertNotEqual(r.exitCode, 0)
        // stderr should be JSON with `error` key per CLI contract.
        let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(stderr.isEmpty, "Expected error envelope on stderr")
        if let data = stderr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertNotNil(obj["error"])
        } else {
            XCTFail("stderr was not valid JSON: \(stderr)")
        }
    }

    // MARK: - pdf text

    func testPdfTextRejectsBothPagesAndSection() throws {
        try skipIfBinaryMissing()
        let r = try runCLI([
            "pdf", "text", "1",
            "--pages", "1-2",
            "--section", "Introduction"
        ])
        XCTAssertNotEqual(r.exitCode, 0)
        let stderr = r.stderr
        XCTAssertTrue(
            stderr.contains("mutually exclusive") || stderr.lowercased().contains("error"),
            "Expected mutual-exclusion error, got: \(stderr)"
        )
    }

    func testPdfTextHelpDocumentsBothModes() throws {
        try skipIfBinaryMissing()
        let r = try runCLI(["pdf", "text", "--help"])
        XCTAssertEqual(r.exitCode, 0)
        let out = r.stdout + r.stderr
        XCTAssertTrue(out.contains("--pages"))
        XCTAssertTrue(out.contains("--section"))
        XCTAssertTrue(out.contains("--max-chars"))
    }

    // MARK: - pdf page-image

    func testPdfPageImageHelpDocumentsFormatFlag() throws {
        try skipIfBinaryMissing()
        let r = try runCLI(["pdf", "page-image", "--help"])
        XCTAssertEqual(r.exitCode, 0)
        let out = r.stdout + r.stderr
        XCTAssertTrue(out.contains("--page"))
        XCTAssertTrue(out.contains("--scale"))
        XCTAssertTrue(out.contains("--format"))
    }

    func testPdfPageImageRejectsUnknownFormat() throws {
        try skipIfBinaryMissing()
        let r = try runCLI([
            "pdf", "page-image", "1",
            "--page", "1",
            "--format", "tiff"
        ])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(
            r.stderr.contains("format") || r.stderr.lowercased().contains("error"),
            "Expected format error, got: \(r.stderr)"
        )
    }
#endif // canImport(PDFKit)

    // MARK: - search --in / --op

    func testSearchAcceptsInFlag() throws {
        try skipIfBinaryMissing()
        // Use a query that's unlikely to match. The point is that --in parses
        // and the command exits 0 with an empty array (or a small array if
        // the dev library happens to contain matches).
        let r = try runCLI([
            "search", "zzzzzunlikelytokenzzz",
            "--in", "title,abstract",
            "--limit", "1"
        ])
        XCTAssertEqual(r.exitCode, 0, "stderr=\(r.stderr)")
        // Output should be a JSON array.
        let trimmed = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("["), "Expected JSON array, got: \(trimmed.prefix(40))")
    }

    func testSearchRejectsUnknownOpValue() throws {
        try skipIfBinaryMissing()
        let r = try runCLI([
            "search", "anything",
            "--op", "xor",
            "--limit", "1"
        ])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(
            r.stderr.contains("--op") || r.stderr.lowercased().contains("error"),
            "Expected --op validation error, got: \(r.stderr)"
        )
    }

    func testSearchRejectsUnknownInColumn() throws {
        // Regression guard: a typo in --in (e.g. "titel") used to be silently
        // dropped by the internal sanitizer, which then meant filter.keywordFields
        // ended up empty and the search fell back to ALL columns — the opposite of
        // what the caller asked for. The CLI now validates and errors on unknowns.
        try skipIfBinaryMissing()
        let r = try runCLI([
            "search", "anything",
            "--in", "titel",
            "--limit", "1"
        ])
        XCTAssertNotEqual(r.exitCode, 0,
                          "Unknown --in column should fail the command, not silently broaden")
        XCTAssertTrue(
            r.stderr.contains("titel") || r.stderr.lowercased().contains("unknown"),
            "Expected error envelope mentioning the bad column, got: \(r.stderr)"
        )
    }

    func testSearchRejectsTypoEvenAlongsideValidColumn() throws {
        // Mixed case: one valid + one invalid column. Still must error — silent
        // partial acceptance would mask typos.
        try skipIfBinaryMissing()
        let r = try runCLI([
            "search", "anything",
            "--in", "title,abstrct",
            "--limit", "1"
        ])
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(
            r.stderr.contains("abstrct") || r.stderr.lowercased().contains("unknown"),
            "Expected error envelope mentioning the bad column, got: \(r.stderr)"
        )
    }
}
