import XCTest
@testable import RubienCore

final class CitationMetaScraperParseTests: XCTestCase {

    private func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: "CitationMeta/\(name)", withExtension: "html")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    private func baseURL(_ s: String) -> URL { URL(string: s)! }

    // MARK: - OpenReview

    func testOpenReviewExtraction() {
        let html = loadFixture("openreview-forum")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://openreview.net/forum?id=EXAMPLE")
        )
        XCTAssertEqual(result.title, "Attention Is All You Need")
        XCTAssertEqual(result.authors.count, 2)
        XCTAssertEqual(result.authors[0].family, "Vaswani")
        XCTAssertEqual(result.authors[1].family, "Shazeer")
        XCTAssertEqual(result.year, 2017)
        XCTAssertEqual(result.conferenceTitle, "NeurIPS 2017")
        XCTAssertEqual(result.pdfURL, "https://openreview.net/pdf?id=EXAMPLE")
        XCTAssertNil(result.doi)
    }

    // MARK: - ACL with DOI

    func testACLExtractionWithDOI() {
        let html = loadFixture("aclanthology-paper")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://aclanthology.org/2024.acl-long.123/")
        )
        XCTAssertEqual(result.title, "A Sample ACL Paper")
        XCTAssertEqual(result.authors.count, 2)
        XCTAssertEqual(result.doi, "10.18653/v1/2024.acl-long.123")
        XCTAssertEqual(result.firstPage, "100")
        XCTAssertEqual(result.lastPage, "115")
        XCTAssertEqual(result.conferenceTitle, "ACL 2024")
    }

    // MARK: - Relative citation_pdf_url

    func testRelativePDFURL() {
        let html = loadFixture("relative-pdf-url")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://dl.acm.org/doi/10.1145/foo.bar")
        )
        XCTAssertEqual(result.pdfURL, "https://dl.acm.org/doi/pdf/10.1145/foo.bar")
    }

    // MARK: - No citation_* tags

    func testNoCitationMeta() {
        let html = loadFixture("no-citation-meta")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://example.com/")
        )
        XCTAssertNil(result.title)
        XCTAssertTrue(result.authors.isEmpty)
        XCTAssertNil(result.doi)
        XCTAssertNil(result.pdfURL)
    }

    // MARK: - Paywall page (citation_* absent)

    func testPaywallExtractsNothing() {
        let html = loadFixture("paywall-login-page")
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://www.sciencedirect.com/login")
        )
        // The scraper does NOT fall back to <title>; result.title is nil.
        XCTAssertNil(result.title)
        XCTAssertTrue(result.authors.isEmpty)
    }

    // MARK: - Year parsing variants

    func testYearFromFullDate() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_publication_date" content="2024/06/12">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.year, 2024)
    }

    func testYearFromBareYear() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_year" content="2023">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.year, 2023)
    }

    func testYearFromISODate() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_publication_date" content="2024-06-12">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.year, 2024)
    }

    // MARK: - Multiple citation_author tags collected in order

    func testMultipleAuthorsInOrder() {
        let html = """
        <html><head>
        <meta name="citation_title" content="X">
        <meta name="citation_author" content="First, A.">
        <meta name="citation_author" content="Second, B.">
        <meta name="citation_author" content="Third, C.">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.authors.count, 3)
        XCTAssertEqual(result.authors.map(\.family), ["First", "Second", "Third"])
    }
}
