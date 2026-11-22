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
            baseURL: baseURL("https://aclanthology.org/2025.acl-long.1141/")
        )
        // ACL Anthology serves HTML5-style unquoted attribute values with
        // content-before-name order — the parser must handle both directions
        // and all three HTML5 quoting forms (double, single, unquoted).
        XCTAssertEqual(result.title, "Language Models Resist Alignment: Evidence From Data Compression")
        XCTAssertEqual(result.authors.count, 10)
        XCTAssertEqual(result.authors.first?.family, "Ji")
        XCTAssertEqual(result.doi, "10.18653/v1/2025.acl-long.1141")
        XCTAssertEqual(result.year, 2025)
        XCTAssertEqual(result.firstPage, "23411")
        XCTAssertEqual(result.lastPage, "23432")
        XCTAssertTrue(result.conferenceTitle?.contains("Annual Meeting of the Association for Computational Linguistics") == true)
        XCTAssertEqual(result.pdfURL, "https://aclanthology.org/2025.acl-long.1141.pdf")
    }

    // MARK: - HTML5 unquoted attribute values (regression for ACL Anthology shape)

    func testUnquotedAttributeValues() {
        // Bare HTML5: `name=foo` and `content=bar` with no quotes. Plus
        // content-first attribute order. Both are valid HTML5.
        let html = """
        <html><head>
        <meta content=Hello name=citation_title>
        <meta content=Smith name=citation_author>
        <meta content=2024 name=citation_year>
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.title, "Hello")
        XCTAssertEqual(result.authors.count, 1)
        XCTAssertEqual(result.year, 2024)
    }

    func testMixedQuotingStyles() {
        // Some attrs quoted, some not, mixed in one document.
        let html = """
        <html><head>
        <meta name="citation_title" content="Quoted Title">
        <meta name='citation_author' content='Single, Q.'>
        <meta name=citation_publication_date content=2023>
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/"))
        XCTAssertEqual(result.title, "Quoted Title")
        XCTAssertEqual(result.authors.count, 1)
        XCTAssertEqual(result.authors.first?.family, "Single")
        XCTAssertEqual(result.year, 2023)
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

    func testArXivDateAndIdentifierAliases() {
        let html = """
        <html><head>
        <meta name="citation_title" content="A Fresh arXiv Paper">
        <meta name="citation_date" content="2026/07/16">
        <meta name="citation_arxiv_id" content="2607.14935">
        </head></html>
        """
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://arxiv.org/abs/2607.14935")
        )
        XCTAssertEqual(result.year, 2026)
        XCTAssertEqual(result.arxivID, "2607.14935")
    }

    func testYearFieldPrecedenceDoesNotDependOnTagOrder() {
        let html = """
        <html><head>
        <meta name="citation_year" content="2024">
        <meta name="citation_publication_date" content="2025/06/12">
        <meta name="citation_date" content="2026/07/16">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com"))
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

    // MARK: - Entity-encoded author names (Nature shape)

    func testEntityEncodedFamilyGivenAuthorsStayWhole() {
        // Nature writes accented letters as numeric references and names as
        // "Family, Given", including multi-word family names. The entity's `;` and the
        // comma must not split a name (s41586-020-2649-2, s41586-021-03819-2).
        let html = """
        <html><head>
        <meta name="citation_title" content="Array programming with NumPy &#8211; a review &amp; more"/>
        <meta name="citation_author" content="Millman, K. Jarrod"/>
        <meta name="citation_author" content="van der Walt, St&#233;fan J."/>
        <meta name="citation_author" content="van Kerkwijk, Marten H."/>
        <meta name="citation_author" content="del R&#237;o, Jaime Fern&#225;ndez"/>
        <meta name="citation_author" content="G&#233;rard-Marchant, Pierre"/>
        <meta name="citation_author" content="&#381;&#237;dek, Augustin"/>
        <meta name="citation_author" content="M&uuml;ller, J&ouml;rg"/>
        <meta name="citation_author" content="Travis E. Oliphant"/>
        </head></html>
        """
        let result = CitationMetaScraper.parse(
            html: html,
            baseURL: baseURL("https://www.nature.com/articles/s41586-020-2649-2")
        )
        XCTAssertEqual(result.title, "Array programming with NumPy – a review & more")
        XCTAssertEqual(result.authors, [
            AuthorName(given: "K. Jarrod", family: "Millman"),
            AuthorName(given: "Stéfan J.", family: "van der Walt"),
            AuthorName(given: "Marten H.", family: "van Kerkwijk"),
            AuthorName(given: "Jaime Fernández", family: "del Río"),
            AuthorName(given: "Pierre", family: "Gérard-Marchant"),
            AuthorName(given: "Augustin", family: "Žídek"),
            AuthorName(given: "Jörg", family: "Müller"),
            AuthorName(given: "Travis E.", family: "Oliphant"),
        ])
    }

    func testAuthorListsInsideCitationAuthorStillSplit() {
        func authors(_ contents: [String]) -> [AuthorName] {
            let tags = contents.map { "<meta name=\"citation_author\" content=\"\($0)\">" }
            let html = "<html><head>\(tags.joined(separator: "\n"))</head></html>"
            return CitationMetaScraper.parse(html: html, baseURL: baseURL("https://example.com/")).authors
        }
        let smith = AuthorName(given: "Jane", family: "Smith")
        let doe = AuthorName(given: "John", family: "Doe")
        let walt = AuthorName(given: "Stéfan", family: "van der Walt")

        // A lone tag may carry the whole list.
        XCTAssertEqual(authors(["Jane Smith, John Doe"]), [smith, doe])
        XCTAssertEqual(authors(["Jane Smith and John Doe"]), [smith, doe])
        // Explicit separators split even when the page repeats the tag.
        XCTAssertEqual(authors(["Smith, Jane; van der Walt, St&#233;fan", "Doe, John"]), [smith, walt, doe])
        XCTAssertEqual(authors(["Jane Smith and John Doe", "van der Walt, St&#233;fan"]), [smith, doe, walt])
    }
}
