import XCTest
import Foundation
import GRDB

/// Contract tests for `rubien-cli read text` / `read annotations` — the
/// kind-agnostic read family (spec: Docs/superpowers/specs/2026-07-11-…).
/// Black-box like the rest of RubienCLITests: drive the built binary with an
/// isolated RUBIEN_LIBRARY_ROOT. Web content / annotations / pdfCache states
/// have no CLI write path, so they are seeded directly into the test library
/// via GRDB (the same SQLite file the CLI opens).
final class ReadCommandTests: XCTestCase {

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
            .appendingPathComponent("rubien-read-test-\(UUID().uuidString)", isDirectory: true)
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
    /// (`add` has no `--authors` option — only --identifier/--bibtex/--title;
    /// authors are irrelevant to these tests, so a bare `--title` suffices.)
    private func addReference(title: String = "Read Test") throws -> Int64 {
        let result = try runCLI(["add", "--title", title])
        XCTAssertEqual(result.exitCode, 0, "add failed: \(result.stderr)")
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        let ref = json?["reference"] as? [String: Any]
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

    // MARK: read text — web routing

    func testReadTextWebOnlyReference() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "Hello from the clipped web page body.")
        let result = try runCLI(["read", "text", "\(id)"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual(json["source"] as? String, "web")
        XCTAssertEqual(json["available"] as? [String], ["web"])
        XCTAssertEqual(json["content"] as? String, "Hello from the clipped web page body.")
        XCTAssertEqual(json["contentFormat"] as? String, "markdown")
        XCTAssertEqual((json["contentLength"] as? NSNumber)?.intValue, 37)
        XCTAssertEqual((json["start"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(json["truncated"] as? Bool, false)
    }

    func testReadTextWebWindowingAndPastEnd() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "0123456789")
        let win = try runCLI(["read", "text", "\(id)", "--start", "4", "--max-chars", "3"])
        XCTAssertEqual(win.exitCode, 0, win.stderr)
        let winJson = try stdoutJSON(win)
        XCTAssertEqual(winJson["content"] as? String, "456")
        XCTAssertEqual(winJson["truncated"] as? Bool, true)
        XCTAssertEqual((winJson["returnedChars"] as? NSNumber)?.intValue, 3)
        let past = try runCLI(["read", "text", "\(id)", "--start", "99"])
        XCTAssertEqual(past.exitCode, 0)
        let pastJson = try stdoutJSON(past)
        XCTAssertEqual(pastJson["content"] as? String, "")
        XCTAssertEqual(pastJson["truncated"] as? Bool, false)
    }

    // MARK: read text — availability errors

    func testReadTextMissingReference() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["read", "text", "999999999"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("not found"), stderrError(result))
    }

    func testReadTextNeitherSourceAvailable() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        let result = try runCLI(["read", "text", "\(id)"])
        XCTAssertNotEqual(result.exitCode, 0)
        let msg = stderrError(result)
        XCTAssertTrue(msg.contains("no readable content"), msg)
        XCTAssertTrue(msg.contains("no PDF attached"), msg)
        XCTAssertTrue(msg.contains("web: none"), msg)
    }

    func testReadTextNotMaterializedPdfAlone() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedPdfCacheRow(refId: id, filename: "ghost.pdf", materialized: false)
        let result = try runCLI(["read", "text", "\(id)"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("not materialized"), stderrError(result))
    }

    func testReadTextNotMaterializedPdfFallsBackToWeb() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedPdfCacheRow(refId: id, filename: "ghost.pdf", materialized: false)
        try seedWebContent(refId: id, body: "fallback body")
        let result = try runCLI(["read", "text", "\(id)"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual(json["source"] as? String, "web")
        XCTAssertEqual(json["available"] as? [String], ["web"])
        // explicit pdf request must error with the state
        let forced = try runCLI(["read", "text", "\(id)", "--source", "pdf"])
        XCTAssertNotEqual(forced.exitCode, 0)
        XCTAssertTrue(stderrError(forced).contains("not materialized"), stderrError(forced))
        XCTAssertTrue(stderrError(forced).contains("available: [\"web\"]"), stderrError(forced))
    }

    func testReadTextMissingFileState() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedPdfCacheRow(refId: id, filename: "definitely-not-on-disk.pdf", materialized: true)
        let result = try runCLI(["read", "text", "\(id)"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("missing on disk"), stderrError(result))
    }

    func testReadTextMissingFilePdfFallsBackToWeb() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedPdfCacheRow(refId: id, filename: "definitely-not-on-disk.pdf", materialized: true)
        try seedWebContent(refId: id, body: "web wins here")
        let result = try runCLI(["read", "text", "\(id)"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual(json["source"] as? String, "web")
        XCTAssertEqual(json["available"] as? [String], ["web"])
        let forced = try runCLI(["read", "text", "\(id)", "--source", "pdf"])
        XCTAssertNotEqual(forced.exitCode, 0)
        XCTAssertTrue(stderrError(forced).contains("missing on disk"), stderrError(forced))
        XCTAssertTrue(stderrError(forced).contains("available: [\"web\"]"), stderrError(forced))
    }

    // MARK: read text — param-implied source + validation

    func testPagesImpliesPdfOnWebOnlyReferenceErrors() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "web body")
        let result = try runCLI(["read", "text", "\(id)", "--pages", "1-2"])
        XCTAssertNotEqual(result.exitCode, 0)
        let msg = stderrError(result)
        XCTAssertTrue(msg.contains("no PDF attached"), msg)
    }

    func testStartImpliesWebOnMissingWebErrors() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        let result = try runCLI(["read", "text", "\(id)", "--start", "5"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("web"), stderrError(result))
    }

    func testMixedParamFamiliesError() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "web body")
        let result = try runCLI(["read", "text", "\(id)", "--pages", "1", "--start", "0"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("mutually exclusive"), stderrError(result))
    }

    func testPagesAndSectionsMutuallyExclusive() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        let result = try runCLI(["read", "text", "\(id)", "--pages", "1", "--section", "Intro"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("mutually exclusive"), stderrError(result))
    }

    func testExplicitSourceContradictsParamErrors() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "web body")
        let result = try runCLI(["read", "text", "\(id)", "--source", "web", "--pages", "1"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("require a PDF source"), stderrError(result))
        XCTAssertTrue(stderrError(result).contains("available: [\"web\"]"), stderrError(result))
        let result2 = try runCLI(["read", "text", "\(id)", "--source", "pdf", "--start", "1"])
        XCTAssertNotEqual(result2.exitCode, 0)
        XCTAssertTrue(stderrError(result2).contains("requires a web source"), stderrError(result2))
        XCTAssertTrue(stderrError(result2).contains("available: [\"web\"]"), stderrError(result2))
    }

    func testMaxCharsRejectsOutOfBounds() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "web body")
        for bad in ["0", "-3", "500001"] {
            let result = try runCLI(["read", "text", "\(id)", "--max-chars", bad])
            XCTAssertNotEqual(result.exitCode, 0, "--max-chars \(bad) should be rejected")
            XCTAssertTrue(stderrError(result).contains("--max-chars"), stderrError(result))
        }
        let ok = try runCLI(["read", "text", "\(id)", "--max-chars", "500000"])
        XCTAssertEqual(ok.exitCode, 0, ok.stderr)
    }

    // MARK: read text — PDF routing (needs a real PDF; PDFKit-gated like existing tests)

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
        let importResult = try runCLI(["import", folder.path])
        XCTAssertEqual(importResult.exitCode, 0, "zotero import failed: \(importResult.stderr)")
        let list = try runCLI(["list", "--limit", "1"])
        let arr = try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]]
        return try XCTUnwrap((arr?.first?["id"] as? NSNumber)?.int64Value, "no reference after import")
    }

    func testReadTextPdfOnlyReference() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        let result = try runCLI(["read", "text", "\(id)", "--pages", "1"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual(json["source"] as? String, "pdf")
        XCTAssertEqual(json["available"] as? [String], ["pdf"])
        XCTAssertEqual((json["pageCount"] as? NSNumber)?.intValue, 3)
        let pages = try XCTUnwrap(json["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual((pages.first?["index"] as? NSNumber)?.intValue, 1)
        XCTAssertNotNil(pages.first?["text"] as? String)
        XCTAssertNotNil(json["hasTextLayer"] as? Bool)
        XCTAssertNotNil(json["selection"] as? [String: Any])
    }

    func testReadTextBothPrefersPdfAndSourceWebOverrides() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        try seedWebContent(refId: id, body: "the web version")
        let pdf = try runCLI(["read", "text", "\(id)"])
        XCTAssertEqual(pdf.exitCode, 0, pdf.stderr)
        let pdfJson = try stdoutJSON(pdf)
        XCTAssertEqual(pdfJson["source"] as? String, "pdf")
        XCTAssertEqual(pdfJson["available"] as? [String], ["pdf", "web"])
        let web = try runCLI(["read", "text", "\(id)", "--source", "web"])
        XCTAssertEqual(web.exitCode, 0, web.stderr)
        let webJson = try stdoutJSON(web)
        XCTAssertEqual(webJson["source"] as? String, "web")
        XCTAssertEqual(webJson["available"] as? [String], ["pdf", "web"])
        XCTAssertEqual(webJson["content"] as? String, "the web version")
        // bare --start on a both-ref implies web (spec §4 rule 2)
        let implied = try runCLI(["read", "text", "\(id)", "--start", "4"])
        XCTAssertEqual(implied.exitCode, 0, implied.stderr)
        XCTAssertEqual((try stdoutJSON(implied))["source"] as? String, "web")
    }

    func testReadTextPdfSectionsOnOutlinelessPdfErrorsNoOutline() throws {
        // linear-3pages-text.pdf is a synthetic fixture with no outline. If this
        // assumption ever breaks (stderr stops mentioning "outline"), switch the
        // assertion to a bogus --section title and expect unmatched-section handling.
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        let result = try runCLI(["read", "text", "\(id)", "--section", "Introduction"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).lowercased().contains("outline"), stderrError(result))
    }

    func testReadTextPdfMaxCharsPageBoundarySemantics() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        // Tiny cap: PDF truncation is page-granular and always returns the first
        // selected page, so the single returned page may EXCEED maxChars (spec §5).
        let tiny = try runCLI(["read", "text", "\(id)", "--max-chars", "10"])
        XCTAssertEqual(tiny.exitCode, 0, tiny.stderr)
        let tinyJson = try stdoutJSON(tiny)
        let tinyPages = try XCTUnwrap(tinyJson["pages"] as? [[String: Any]])
        XCTAssertEqual(tinyPages.count, 1)
        XCTAssertEqual(tinyJson["truncated"] as? Bool, true)
        XCTAssertGreaterThan((tinyPages[0]["text"] as? String)?.count ?? 0, 10,
                             "first page should be returned whole even past the cap")
        // Huge cap: everything fits, no truncation.
        let full = try runCLI(["read", "text", "\(id)", "--max-chars", "500000"])
        XCTAssertEqual(full.exitCode, 0, full.stderr)
        let fullJson = try stdoutJSON(full)
        XCTAssertEqual((fullJson["pages"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(fullJson["truncated"] as? Bool, false)
    }
    #endif

    // MARK: read annotations

    private func seedPdfAnnotation(refId: Int64, page: Int, selected: String, created: Date) throws {
        let db = try openTestDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO pdfAnnotation(referenceId, type, selectedText, noteText, color,
                    pageIndex, boundsX, boundsY, boundsWidth, boundsHeight, rectsData,
                    dateCreated, dateModified)
                VALUES (?, 'highlight', ?, NULL, '#FFEB3B', ?, 0, 0, 10, 10, '[]', ?, ?)
                """, arguments: [refId, selected, page, created, created])
        }
    }

    /// webAnnotation.selectedText is NOT NULL (legacy column; the model mirrors
    /// anchorText into it) — bind the anchor to both columns.
    private func seedWebAnnotation(refId: Int64, anchor: String, created: Date) throws {
        let db = try openTestDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO webAnnotation(referenceId, type, selectedText, noteText, color,
                    anchorText, prefixText, suffixText, dateCreated, dateModified)
                VALUES (?, 'highlight', ?, NULL, '#FFEB3B', ?, 'before ', ' after', ?, ?)
                """, arguments: [refId, anchor, anchor, created, created])
        }
    }

    private func stdoutArray(_ result: (stdout: String, stderr: String, exitCode: Int32)) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]],
                      "stdout was not a JSON array: \(result.stdout)")
    }

    func testReadAnnotationsMissingReferenceIsEmptyArray() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["read", "annotations", "999999999"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try stdoutArray(result).count, 0)
    }

    func testReadAnnotationsMergesBothKindsInOrder() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        let early = Date(timeIntervalSince1970: 1_000_000)
        let late = Date(timeIntervalSince1970: 2_000_000)
        // pdf: page-2 pair exercises the (pageIndex, id) tie-break (autoincrement
        // ids ascend in insertion order); page 5 comes last despite earlier date.
        try seedPdfAnnotation(refId: id, page: 5, selected: "pdf page5", created: early)
        try seedPdfAnnotation(refId: id, page: 2, selected: "pdf tie A", created: late)
        try seedPdfAnnotation(refId: id, page: 2, selected: "pdf tie B", created: late)
        // web: same-date pair exercises the (dateCreated, id) tie-break.
        try seedWebAnnotation(refId: id, anchor: "web tie A", created: early)
        try seedWebAnnotation(refId: id, anchor: "web tie B", created: early)
        try seedWebAnnotation(refId: id, anchor: "web late", created: late)
        let result = try runCLI(["read", "annotations", "\(id)"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let items = try stdoutArray(result)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map { $0["source"] as? String },
                       ["pdf", "pdf", "pdf", "web", "web", "web"])
        XCTAssertEqual(items[0]["selectedText"] as? String, "pdf tie A")
        XCTAssertEqual(items[1]["selectedText"] as? String, "pdf tie B")
        XCTAssertEqual(items[2]["selectedText"] as? String, "pdf page5")
        XCTAssertEqual(items[3]["anchorText"] as? String, "web tie A")
        XCTAssertEqual(items[4]["anchorText"] as? String, "web tie B")
        XCTAssertEqual(items[5]["anchorText"] as? String, "web late")
        // union fields: kind-foreign anchors are OMITTED, not null
        XCTAssertNil(items[0]["anchorText"])
        XCTAssertNil(items[3]["pageIndex"])
        // ids and dates present on every item
        XCTAssertTrue(items.allSatisfy { $0["id"] is NSNumber }, "\(items)")
        XCTAssertTrue(items.allSatisfy { $0["dateCreated"] != nil })
    }

    func testReadAnnotationsSourceFilter() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedPdfAnnotation(refId: id, page: 1, selected: "pdf one", created: Date())
        try seedWebAnnotation(refId: id, anchor: "web one", created: Date())
        let pdfOnly = try runCLI(["read", "annotations", "\(id)", "--source", "pdf"])
        XCTAssertEqual(try stdoutArray(pdfOnly).map { $0["source"] as? String }, ["pdf"])
        let webOnly = try runCLI(["read", "annotations", "\(id)", "--source", "web"])
        XCTAssertEqual(try stdoutArray(webOnly).map { $0["source"] as? String }, ["web"])
    }
}
