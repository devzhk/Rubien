import XCTest
@testable import RubienCore

/// Live smoke tests against real publisher URLs. Skipped in CI by default.
/// Run with `RUBIEN_LIVE_TESTS=1 swift test --filter PaperURLLiveSmokeTests`.
final class PaperURLLiveSmokeTests: XCTestCase {

    /// Resolves `s` and asserts the result has a non-empty title and authors.
    /// Pass a non-empty `expectedTitleContains` to also assert the title substring;
    /// pass `""` to skip the contains-check (opt-out convention for URLs whose
    /// title text may change over time).
    private func smokeURL(_ s: String, expectedTitleContains: String, file: StaticString = #file, line: UInt = #line) async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RUBIEN_LIVE_TESTS"] != "1",
                      "Set RUBIEN_LIVE_TESTS=1 to run live smoke tests")
        let url = URL(string: s)!
        let outcome = try await PaperURLResolver.resolve(url)
        XCTAssertFalse(outcome.reference.title.isEmpty, file: file, line: line)
        if !expectedTitleContains.isEmpty {
            XCTAssertTrue(outcome.reference.title.lowercased().contains(expectedTitleContains.lowercased()),
                          "Expected title to contain '\(expectedTitleContains)', got '\(outcome.reference.title)'",
                          file: file, line: line)
        }
        XCTAssertFalse(outcome.reference.authors.isEmpty, file: file, line: line)
    }

    // EDITOR: Update these URLs (and expected titles) with real, stable
    // landing pages before shipping. Synthetic placeholders here.

    func testOpenReviewLive() async throws {
        try await smokeURL(
            "https://openreview.net/forum?id=YicbFdNTTy",  // a real "Attention is all you need"-style ID
            expectedTitleContains: "attention"
        )
    }

    func testACLAnthologyLive() async throws {
        try await smokeURL(
            "https://aclanthology.org/2023.acl-long.1/",  // pick a real stable URL
            expectedTitleContains: ""  // skip text assertion if URL is unstable
        )
    }

    func testAPSLive() async throws {
        try await smokeURL(
            "https://journals.aps.org/prl/abstract/10.1103/3v91-5pzf",
            expectedTitleContains: "directional photocurrent"
        )
    }

    func testScienceLive() async throws {
        try await smokeURL(
            "https://www.science.org/doi/full/10.1126/sciadv.abn9545",
            expectedTitleContains: "machine learning enables interpretable discovery"
        )
    }

    func testACSLive() async throws {
        try await smokeURL(
            "https://pubs.acs.org/doi/full/10.1021/acscentsci.3c01275",
            expectedTitleContains: "opportunities and challenges"
        )
    }

    func testAANDALive() async throws {
        try await smokeURL(
            "https://www.aanda.org/articles/aa/full_html/2026/02/aa57022-25/aa57022-25.html",
            expectedTitleContains: "probing jet base emission"
        )
    }

    func testELifeLive() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RUBIEN_LIVE_TESTS"] != "1",
                      "Set RUBIEN_LIVE_TESTS=1 to run live smoke tests")
        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://elifesciences.org/articles/29515")!
        )
        XCTAssertTrue(outcome.reference.title.lowercased().contains("theta-burst microstimulation"))
        XCTAssertFalse(outcome.reference.authors.isEmpty)
        XCTAssertEqual(outcome.reference.doi, "10.7554/eLife.29515")
        XCTAssertNotNil(outcome.scrapedPDFURL)
        let pdfURL = try await PDFDownloadService.resolvePDFURL(for: outcome.reference)
        XCTAssertEqual(pdfURL.absoluteString, "https://elifesciences.org/articles/29515.pdf")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienELifeLive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let downloaded = try await PDFDownloadService.downloadTemporary(
            from: pdfURL,
            suggestedFilename: "elife-29515.pdf",
            destinationDirectory: destination
        )
        let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 4)
    }

    // Add similar smokeURL calls for the remaining hosts when stable URLs
    // are identified. See Scripts/refresh-citation-fixtures.sh for the
    // capture-and-update workflow.
}
