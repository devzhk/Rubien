import XCTest
import Foundation
import GRDB

/// Contract tests for `rubien-cli grep` — the kind-agnostic body-text search
/// family (spec: Docs/specs/2026-07-11-…). Black-box like the rest
/// of RubienCLITests: drive the built binary with an isolated
/// RUBIEN_LIBRARY_ROOT. Web content / pdfCache states have no CLI write path,
/// so they are seeded directly into the test library via GRDB (the same SQLite
/// file the CLI opens). Harness copied verbatim from ReadCommandTests.
final class GrepCommandTests: XCTestCase {

    private var cliBinaryPath: String {
        let debugPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/rubien-cli").path
        if FileManager.default.isExecutableFile(atPath: debugPath) { return debugPath }
        return debugPath
    }

    private lazy var testLibraryRoot: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rubien-grep-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: testLibraryRoot)
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run `swift build` first.")
        }
    }

    @discardableResult
    private func runCLI(_ arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                process.terminationStatus)
    }

    // MARK: seeding

    /// Add a bare manual reference via the CLI; returns its id.
    /// (`add` has no `--authors` option — only --source/--bibtex/--title;
    /// authors are irrelevant to these tests, so a bare `--title` suffices.)
    private func addReference(title: String = "Read Test") throws -> Int64 {
        let result = try runCLI(["add", "--title", title])
        XCTAssertEqual(result.exitCode, 0, "add failed: \(result.stderr)")
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        let ref = (json?["items"] as? [[String: Any]])?.first?["reference"] as? [String: Any]
        return try XCTUnwrap((ref?["id"] as? NSNumber)?.int64Value, "no id in add envelope")
    }

    private func openTestDB() throws -> DatabaseQueue {
        try DatabaseQueue(path: testLibraryRoot.appendingPathComponent("library.sqlite").path)
    }

    private func seedWebContent(refId: Int64, body: String) throws {
        let db = try openTestDB()
        try db.write { db in
            try db.execute(sql: "UPDATE reference SET webContent = ?, url = ?, siteName = ? WHERE id = ?",
                           arguments: [body, "https://example.com/x", "example.com", refId])
        }
    }

    /// Insert a pdfCache row directly (materializedAt nil ⇒ notMaterialized state).
    /// contentHash + lastOpenedAt are NOT NULL (AppDatabase v2 migration) — an
    /// explicit NULL bypasses the column default, so both get real values.
    private func seedPdfCacheRow(refId: Int64, filename: String, materialized: Bool) throws {
        let db = try openTestDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES (?, ?, 'seed-hash', 1, ?, ?)
                """, arguments: [refId, filename, materialized ? Date() : nil, Date()])
        }
    }

    private func stderrError(_ result: (stdout: String, stderr: String, exitCode: Int32)) -> String {
        let json = (try? JSONSerialization.jsonObject(with: Data(result.stderr.utf8))) as? [String: Any]
        return json?["error"] as? String ?? result.stderr
    }

    private func stdoutJSON(_ result: (stdout: String, stderr: String, exitCode: Int32)) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                      "stdout was not a JSON object: \(result.stdout)")
    }

    #if canImport(PDFKit)
    /// Zotero-import a 3-page fixture PDF (same pattern as MCPServerTests.importFixturePDF).
    private func importFixturePDF() throws -> Int64 {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RubienPDFKitTests/Fixtures/PDFs/linear-3pages-text.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "fixture PDF missing at \(fixture.path)")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("read-zotero-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("RL", isDirectory: true)
        let filesDir = folder.appendingPathComponent("files/1", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: fixture, to: filesDir.appendingPathComponent("paper.pdf"))
        let bib = """
        @article{paper1,
            title = {Linear Three Pages},
            author = {Test, Author},
            file = {PDF:files/1/paper.pdf:application/pdf},
        }
        """
        try bib.write(to: folder.appendingPathComponent("RL.bib"), atomically: true, encoding: .utf8)
        let importResult = try runCLI(["add", "--source", folder.path])
        XCTAssertEqual(importResult.exitCode, 0, "zotero import failed: \(importResult.stderr)")
        let list = try runCLI(["list", "--limit", "1"])
        let arr = try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]]
        return try XCTUnwrap((arr?.first?["id"] as? NSNumber)?.int64Value, "no reference after import")
    }
    #endif

    // MARK: web grep

    func testGrepWebLiteralWithExactOffsets() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "alpha needle beta needle gamma")
        let result = try runCLI(["grep", "\(id)", "needle"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual(json["source"] as? String, "web")
        XCTAssertEqual(json["available"] as? [String], ["web"])
        XCTAssertEqual((json["totalMatches"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((json["contentLength"] as? NSNumber)?.intValue, 30)
        let matches = try XCTUnwrap(json["matches"] as? [[String: Any]])
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual((matches[0]["start"] as? NSNumber)?.intValue, 6)
    }

    func testGrepWebOffsetFeedsReadTextStart() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: String(repeating: "x", count: 500) + " the needle sentence " + String(repeating: "y", count: 500))
        let grep = try runCLI(["grep", "\(id)", "needle"])
        XCTAssertEqual(grep.exitCode, 0, grep.stderr)
        let start = try XCTUnwrap(((try stdoutJSON(grep))["matches"] as? [[String: Any]])?.first?["start"] as? NSNumber).intValue
        let read = try runCLI(["read", "text", "\(id)", "--start", "\(max(0, start - 10))", "--max-chars", "40"])
        XCTAssertEqual(read.exitCode, 0, read.stderr)
        let window = (try stdoutJSON(read))["content"] as? String ?? ""
        XCTAssertTrue(window.contains("needle"), "read text window must contain the match; got: \(window)")
    }

    func testGrepWebOffsetFeedsReadTextStartOnHTMLBody() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        // decodeWebContent sniffs the html marker prefix — build an html-format body
        let html = "<!-- rubien:web-content:html -->\n<p>before <em>needle</em> after</p>"
        try seedWebContent(refId: id, body: html)
        let grep = try runCLI(["grep", "\(id)", "needle"])
        XCTAssertEqual(grep.exitCode, 0, grep.stderr)
        let json = try stdoutJSON(grep)
        let start = try XCTUnwrap((json["matches"] as? [[String: Any]])?.first?["start"] as? NSNumber).intValue
        let read = try runCLI(["read", "text", "\(id)", "--start", "\(start)", "--max-chars", "6"])
        XCTAssertEqual((try stdoutJSON(read))["content"] as? String, "needle")
    }

    func testGrepWebRegexAndCaseInsensitivity() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "Cat hat CAT")
        let literal = try runCLI(["grep", "\(id)", "cat"])
        XCTAssertEqual(((try stdoutJSON(literal))["totalMatches"] as? NSNumber)?.intValue, 2)
        let rx = try runCLI(["grep", "\(id)", "[ch]at", "--regex"])
        XCTAssertEqual(((try stdoutJSON(rx))["totalMatches"] as? NSNumber)?.intValue, 3)
    }

    func testGrepWebMaxMatchesEntryCapAndTotals() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        let spread = (0..<5).map { _ in "needle" + String(repeating: " z", count: 200) }.joined()
        try seedWebContent(refId: id, body: spread)
        let result = try runCLI(["grep", "\(id)", "needle", "--max-matches", "2"])
        let json = try stdoutJSON(result)
        XCTAssertEqual((json["matches"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((json["totalMatches"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((json["totalEntries"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual(json["truncated"] as? Bool, true)
    }

    func testGrepWebNoMatchesIsSuccess() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "nothing to see")
        let result = try runCLI(["grep", "\(id)", "absent"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual((json["totalMatches"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((json["matches"] as? [[String: Any]])?.count, 0)
    }

    // MARK: routing + validation

    func testGrepRoutingMatrix() throws {
        try skipIfBinaryMissing()
        // missing ref
        let missing = try runCLI(["grep", "999999999", "x"])
        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertTrue(stderrError(missing).contains("not found"), stderrError(missing))
        // neither source
        let bare = try addReference()
        let neither = try runCLI(["grep", "\(bare)", "x"])
        XCTAssertNotEqual(neither.exitCode, 0)
        XCTAssertTrue(stderrError(neither).contains("no readable content"), stderrError(neither))
        // web-only + explicit pdf
        let webRef = try addReference()
        try seedWebContent(refId: webRef, body: "text body")
        let forcedPdf = try runCLI(["grep", "\(webRef)", "text", "--source", "pdf"])
        XCTAssertNotEqual(forcedPdf.exitCode, 0)
        XCTAssertTrue(stderrError(forcedPdf).contains("no PDF attached"), stderrError(forcedPdf))
        XCTAssertTrue(stderrError(forcedPdf).contains("available: [\"web\"]"), stderrError(forcedPdf))
        // pdf-family param on web-only ref implies pdf → unavailable
        let implied = try runCLI(["grep", "\(webRef)", "text", "--max-pages", "5"])
        XCTAssertNotEqual(implied.exitCode, 0)
        XCTAssertTrue(stderrError(implied).contains("no PDF attached"), stderrError(implied))
        // notMaterialized pdf falls back to web by default
        try seedPdfCacheRow(refId: webRef, filename: "ghost.pdf", materialized: false)
        let fallback = try runCLI(["grep", "\(webRef)", "text"])
        XCTAssertEqual(fallback.exitCode, 0, fallback.stderr)
        XCTAssertEqual((try stdoutJSON(fallback))["source"] as? String, "web")
    }

    func testGrepMixedFamiliesError() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "body")
        let result = try runCLI(["grep", "\(id)", "x", "--max-pages", "5", "--max-matches", "5"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("mutually exclusive"), stderrError(result))
    }

    func testGrepExplicitSourceContradictsFamilyError() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "body")
        let r1 = try runCLI(["grep", "\(id)", "x", "--source", "web", "--max-pages", "5"])
        XCTAssertNotEqual(r1.exitCode, 0)
        XCTAssertTrue(stderrError(r1).contains("require a PDF source"), stderrError(r1))
        let r2 = try runCLI(["grep", "\(id)", "x", "--source", "pdf", "--max-matches", "5"])
        XCTAssertNotEqual(r2.exitCode, 0)
        XCTAssertTrue(stderrError(r2).contains("requires a web source"), stderrError(r2))
    }

    func testGrepEmptyQueryAndInvalidRegexAndBounds() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "body")
        let empty = try runCLI(["grep", "\(id)", "   "])
        XCTAssertNotEqual(empty.exitCode, 0)
        XCTAssertTrue(stderrError(empty).contains("query must not be empty"), stderrError(empty))
        let badRx = try runCLI(["grep", "\(id)", "([unclosed", "--regex"])
        XCTAssertNotEqual(badRx.exitCode, 0)
        XCTAssertTrue(stderrError(badRx).contains("invalid-regex"), stderrError(badRx))
        for (flag, bad) in [("--context-chars", "0"), ("--context-chars", "2001"),
                            ("--max-pages", "0"), ("--max-pages", "201"),
                            ("--snippets-per-page", "0"), ("--snippets-per-page", "21"),
                            ("--max-matches", "0"), ("--max-matches", "201")] {
            let r = try runCLI(["grep", "\(id)", "x", flag, bad])
            XCTAssertNotEqual(r.exitCode, 0, "\(flag) \(bad) must be rejected")
            XCTAssertTrue(stderrError(r).contains(flag), "\(flag) \(bad): \(stderrError(r))")
        }
    }

    // MARK: PDF grep (real extraction)

    #if canImport(PDFKit)
    func testGrepPdfWinsOnBothAndSourceWebFlips() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        try seedWebContent(refId: id, body: "web needle body")
        let pdf = try runCLI(["grep", "\(id)", "page"])
        XCTAssertEqual(pdf.exitCode, 0, pdf.stderr)
        let pdfJson = try stdoutJSON(pdf)
        XCTAssertEqual(pdfJson["source"] as? String, "pdf")
        XCTAssertEqual(pdfJson["available"] as? [String], ["pdf", "web"])
        XCTAssertNotNil(pdfJson["pages"])
        XCTAssertNotNil(pdfJson["hasTextLayer"])
        let web = try runCLI(["grep", "\(id)", "needle", "--source", "web"])
        XCTAssertEqual((try stdoutJSON(web))["source"] as? String, "web")
    }

    func testGrepPdfPagesScopeAndMaxMatchesImpliesWebError() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        let scoped = try runCLI(["grep", "\(id)", "page", "--pages", "2"])
        XCTAssertEqual(scoped.exitCode, 0, scoped.stderr)
        let hits = (try stdoutJSON(scoped))["pages"] as? [[String: Any]] ?? []
        XCTAssertTrue(hits.allSatisfy { ($0["page"] as? NSNumber)?.intValue == 2 })
        // --max-matches implies web; web unavailable on pdf-only ref
        let implied = try runCLI(["grep", "\(id)", "page", "--max-matches", "3"])
        XCTAssertNotEqual(implied.exitCode, 0)
        XCTAssertTrue(stderrError(implied).contains("web"), stderrError(implied))
    }

    func testGrepPdfInvalidPageRangePassesThroughExtractError() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        let result = try runCLI(["grep", "\(id)", "page", "--pages", "abc"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("invalid-page-range"), stderrError(result))
        let outOfRange = try runCLI(["grep", "\(id)", "page", "--pages", "999"])
        XCTAssertNotEqual(outOfRange.exitCode, 0)
        XCTAssertTrue(stderrError(outOfRange).contains("page-out-of-range"), stderrError(outOfRange))
    }
    #endif
}
