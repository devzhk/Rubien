#if canImport(PDFKit)
import XCTest
import Foundation

/// Surface-level CLI contract tests for `rubien-cli pdf status <id>`. Verifies
/// the JSON shape for the no-cache-row branch — the only branch we can drive
/// without seeding a known-cached reference into the developer's library.
final class PdfStatusTests: XCTestCase {

    private var cliBinaryPath: String {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/rubien-cli")
            .path
    }

    private func runCLI(_ args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = args

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

    func testPdfStatusListedInPdfHelp() throws {
        try skipIfBinaryMissing()
        let r = try runCLI(["pdf", "--help"])
        XCTAssertEqual(r.exitCode, 0)
        let out = r.stdout + r.stderr
        XCTAssertTrue(out.contains("status"), "Expected `status` to appear in `pdf --help`, got: \(out)")
    }

    func testPdfStatusRequiresReferenceId() throws {
        try skipIfBinaryMissing()
        let r = try runCLI(["pdf", "status"])
        XCTAssertNotEqual(r.exitCode, 0, "Missing required <id> should fail")
    }

    func testPdfStatusEmitsCachedFalseWhenNoRow() throws {
        try skipIfBinaryMissing()
        // 999999999 is well above any plausible reference id in the dev library.
        // If by some accident the dev library does have such a row, this test
        // fails loudly with a clear diagnostic — which is the right outcome.
        let r = try runCLI(["pdf", "status", "999999999"])
        XCTAssertEqual(r.exitCode, 0, "Expected success exit; stderr=\(r.stderr)")

        let trimmed = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected JSON object on stdout, got: \(trimmed)")
            return
        }

        // Numeric ids may decode as Int or Int64 depending on JSONSerialization;
        // accept either by going through NSNumber.
        XCTAssertEqual((json["referenceId"] as? NSNumber)?.int64Value, 999999999)
        XCTAssertEqual(json["cached"] as? Bool, false)

        // When there's no pdfCache row the optional fields must be omitted —
        // callers rely on key presence as a signal.
        XCTAssertNil(json["localFilename"], "filename must be omitted when no row")
        XCTAssertNil(json["contentHash"], "contentHash must be omitted when no row")
        XCTAssertNil(json["assetVersion"], "assetVersion must be omitted when no row")
        XCTAssertNil(json["materializedAt"], "materializedAt must be omitted when no row")
        XCTAssertNil(json["lastOpenedAt"], "lastOpenedAt must be omitted when no row")
        XCTAssertNil(json["inUploadQueue"], "inUploadQueue must be omitted when no row")
    }
}
#endif
