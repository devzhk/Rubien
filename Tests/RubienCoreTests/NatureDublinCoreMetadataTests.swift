import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RubienCore

/// Nature magazine pages (news, Research Highlights) carry Dublin Core / PRISM
/// tags but no `citation_*` tags. Fixtures are trimmed captures of real pages.
final class NatureDublinCoreMetadataTests: XCTestCase {
    private let highlightURL = "https://www.nature.com/articles/d41586-026-03638-3"
    private let highlightDOI = "10.1038/d41586-026-03638-3"
    private let highlightTitle = "Found: a protein that drives ageing without unleashing inflammation"
    private let newsURL = "https://www.nature.com/articles/d41586-026-03672-1"
    private let newsDOI = "10.1038/d41586-026-03672-1"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func fixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: "CitationMeta/\(name)", withExtension: "html")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    /// `PaperURLResolver` fetches the canonical landing URL (no `www.`).
    private func stubPage(_ pageURL: String, fixture name: String) {
        StubURLProtocol.stub(
            pageURL.replacingOccurrences(of: "://www.", with: "://"),
            body: fixture(name)
        )
    }

    private func crossrefHighlight() -> Reference {
        Reference(
            title: highlightTitle,
            authors: [],
            year: 2026,
            journal: "Nature",
            volume: "659",
            issue: "8141",
            pages: "565-565",
            doi: highlightDOI,
            url: "https://doi.org/\(highlightDOI)",
            referenceType: .journalArticle,
            publisher: "Springer Science and Business Media LLC"
        )
    }

    // MARK: - Scraper

    func testResearchHighlightReadsDublinCoreAndPRISM() {
        let result = CitationMetaScraper.parse(
            html: fixture("nature-research-highlight"),
            baseURL: URL(string: highlightURL)!
        )

        XCTAssertTrue(result.usedDublinCoreFallback)
        XCTAssertEqual(result.title, highlightTitle)
        XCTAssertEqual(result.doi, highlightDOI)
        XCTAssertTrue(result.authors.isEmpty)
        XCTAssertEqual(result.journal, "Nature")
        XCTAssertEqual(result.volume, "659")
        XCTAssertEqual(result.issue, "8141")
        XCTAssertEqual(result.firstPage, "565")
        XCTAssertEqual(result.lastPage, "565")
        XCTAssertEqual(result.year, 2026)
        XCTAssertEqual(result.publisher, "Nature Publishing Group")
        XCTAssertEqual(result.issn, "1476-4687")
        XCTAssertNil(result.pdfURL)
    }

    func testSignedNewsReadsDublinCoreCreatorAndSkipsBlankPages() {
        let result = CitationMetaScraper.parse(
            html: fixture("nature-news-signed"),
            baseURL: URL(string: newsURL)!
        )

        XCTAssertTrue(result.usedDublinCoreFallback)
        XCTAssertEqual(result.doi, newsDOI)
        XCTAssertEqual(result.authors.map(\.family), ["Witze"])
        XCTAssertEqual(result.authors.first?.given, "Alexandra")
        XCTAssertNil(result.firstPage, "An empty prism.startingPage is not a page number")
    }

    func testCitationMetadataPageIgnoresItsDublinCoreTags() {
        let html = fixture("nature-article-citation-and-dc")
        let withoutDublinCore = html
            .components(separatedBy: "\n")
            .filter { !$0.contains("name=\"dc.") && !$0.contains("name=\"prism.") }
            .joined(separator: "\n")
        let baseURL = URL(string: "https://www.nature.com/articles/s41586-020-2649-2")!

        let result = CitationMetaScraper.parse(html: html, baseURL: baseURL)

        XCTAssertFalse(result.usedDublinCoreFallback)
        XCTAssertEqual(result.title, "Array programming with NumPy")
        XCTAssertEqual(result.authors.first?.family, "Harris")
        XCTAssertEqual(result.pdfURL, "https://www.nature.com/articles/s41586-020-2649-2.pdf")
        XCTAssertEqual(
            result,
            CitationMetaScraper.parse(html: withoutDublinCore, baseURL: baseURL),
            "Pages with citation_title must parse exactly as they did before the fallback"
        )
    }

    func testDublinCoreFallbackRequiresADOI() {
        let html = """
        <html><head>
        <meta name="dc.title" content="A page without an identifier">
        <meta name="dc.identifier" content="https://www.nature.com/articles/foo">
        <meta name="dc.identifier" content="urn:ISSN:1476-4687">
        <meta name="prism.publicationName" content="Nature">
        <meta name="dc.date" content="2026-11-12">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: URL(string: "https://nature.com/articles/foo")!)

        XCTAssertFalse(result.usedDublinCoreFallback)
        XCTAssertNil(result.title)
        XCTAssertNil(result.journal)
        XCTAssertNil(result.year)
    }

    func testDublinCoreFallbackAcceptsDOIURLIdentifierAndKeepsCitationValues() {
        let html = """
        <html><head>
        <meta name="citation_volume" content="12">
        <meta name="dc.title" content="Identifier forms">
        <meta name="dc.identifier" content="urn:ISSN:1476-4687">
        <meta name="dc.identifier" content="https://doi.org/10.1038/example-1">
        <meta name="prism.volume" content="99">
        </head></html>
        """
        let result = CitationMetaScraper.parse(html: html, baseURL: URL(string: "https://nature.com/articles/foo")!)

        XCTAssertTrue(result.usedDublinCoreFallback)
        XCTAssertEqual(result.title, "Identifier forms")
        XCTAssertEqual(result.doi, "10.1038/example-1")
        XCTAssertEqual(result.volume, "12", "A citation_* value wins over its PRISM counterpart")
    }

    // MARK: - Resolver

    func testResearchHighlightResolvesToAuthorlessRecordWithNaturePDF() async {
        stubPage(highlightURL, fixture: "nature-research-highlight")
        let crossref = crossrefHighlight()

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: highlightURL)!,
                session: StubURLProtocol.makeSession(),
                crossrefFetcher: { doi in
                    XCTAssertEqual(doi, "10.1038/d41586-026-03638-3")
                    return crossref
                }
            )
            XCTFail("Expected noAuthorsAvailable")
        } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let reference, let pdfURL) {
            XCTAssertEqual(reference.title, highlightTitle)
            XCTAssertEqual(reference.doi, highlightDOI)
            XCTAssertTrue(reference.authors.isEmpty)
            XCTAssertEqual(reference.journal, "Nature")
            XCTAssertEqual(reference.volume, "659")
            XCTAssertEqual(reference.issue, "8141")
            XCTAssertEqual(reference.pages, "565-565")
            XCTAssertEqual(reference.year, 2026)
            XCTAssertEqual(reference.referenceType, .journalArticle)
            XCTAssertEqual(reference.metadataSource, .publisherCitationMeta)
            XCTAssertEqual(reference.url, "https://nature.com/articles/d41586-026-03638-3")
            XCTAssertEqual(pdfURL, "https://www.nature.com/articles/d41586-026-03638-3.pdf")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testResearchHighlightKeepsPageMetadataWhenCrossrefFails() async {
        stubPage(highlightURL, fixture: "nature-research-highlight")

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: highlightURL)!,
                session: StubURLProtocol.makeSession(),
                crossrefFetcher: { _ in throw URLError(.notConnectedToInternet) }
            )
            XCTFail("Expected noAuthorsAvailable")
        } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let reference, let pdfURL) {
            XCTAssertEqual(reference.doi, highlightDOI)
            XCTAssertEqual(reference.journal, "Nature")
            XCTAssertEqual(reference.pages, "565-565")
            XCTAssertEqual(pdfURL, "https://www.nature.com/articles/d41586-026-03638-3.pdf")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testSignedNewsResolvesWithCrossrefAuthorAndNaturePDF() async throws {
        stubPage(newsURL, fixture: "nature-news-signed")
        let crossref = Reference(
            title: "Voyager 1 achieves a cosmic first: one ‘light day’ from Earth",
            authors: [AuthorName(given: "Alexandra", family: "Witze")],
            year: 2026,
            journal: "Nature",
            doi: newsDOI,
            referenceType: .journalArticle
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: newsURL)!,
            session: StubURLProtocol.makeSession(),
            crossrefFetcher: { _ in crossref }
        )

        XCTAssertEqual(outcome.reference.doi, newsDOI)
        XCTAssertEqual(outcome.reference.authors.map(\.family), ["Witze"])
        XCTAssertEqual(outcome.scrapedPDFURL, "https://www.nature.com/articles/d41586-026-03672-1.pdf")
    }

    func testSignedArticleKeepsItsCitationPDFAndAuthors() async throws {
        let articleURL = "https://www.nature.com/articles/s41586-020-2649-2"
        stubPage(articleURL, fixture: "nature-article-citation-and-dc")

        let outcome = try await PaperURLResolver.resolve(
            URL(string: articleURL)!,
            session: StubURLProtocol.makeSession(),
            crossrefFetcher: { _ in throw URLError(.notConnectedToInternet) }
        )

        XCTAssertEqual(outcome.reference.title, "Array programming with NumPy")
        XCTAssertEqual(outcome.reference.authors.first?.family, "Harris")
        XCTAssertEqual(outcome.reference.doi, "10.1038/s41586-020-2649-2")
        XCTAssertEqual(outcome.scrapedPDFURL, "https://www.nature.com/articles/s41586-020-2649-2.pdf")
    }

    func testNaturePDFURLOnlyForSingleSegmentArticlePaths() {
        XCTAssertEqual(
            PaperURLResolver.natureArticlePDFURL(for: URL(string: "https://nature.com/articles/d41586-026-03638-3")!)?.absoluteString,
            "https://www.nature.com/articles/d41586-026-03638-3.pdf"
        )
        XCTAssertNil(PaperURLResolver.natureArticlePDFURL(for: URL(string: "https://nature.com/articles/foo/figures/1")!))
        XCTAssertNil(PaperURLResolver.natureArticlePDFURL(for: URL(string: "https://nature.com/articles/foo.pdf")!))
        XCTAssertNil(PaperURLResolver.natureArticlePDFURL(for: URL(string: "https://nature.com/news/foo")!))
    }

    // MARK: - Pipeline and CLI entry point

    func testNoAuthorsOutcomeKeepsReviewCandidateAndExposesAuthorlessRecord() throws {
        var partial = crossrefHighlight()
        partial.url = "https://nature.com/articles/d41586-026-03638-3"
        partial.metadataSource = .publisherCitationMeta
        let captured = Reference(
            title: "\(highlightTitle) | Nature",
            authors: [AuthorName(given: "Nature", family: "Staff")],
            url: highlightURL,
            siteName: "Nature",
            referenceType: .journalArticle
        )

        let outcome = MetadataResolutionPipeline.noAuthorsOutcome(
            partialReference: partial,
            scrapedPDFURL: "https://www.nature.com/articles/d41586-026-03638-3.pdf",
            seed: nil,
            fallback: captured
        )

        guard case .candidate(let envelope) = outcome.result else {
            return XCTFail("Automatic resolution must still queue an authorless record")
        }
        XCTAssertEqual(envelope.currentReference?.doi, highlightDOI)
        XCTAssertNil(outcome.preferredPDFURL)

        let record = try XCTUnwrap(outcome.authorlessRecord)
        XCTAssertEqual(record.reference.title, highlightTitle)
        XCTAssertTrue(record.reference.authors.isEmpty, "A captured byline is not citation metadata")
        XCTAssertEqual(record.reference.siteName, "Nature")
        XCTAssertEqual(record.pdfURL, "https://www.nature.com/articles/d41586-026-03638-3.pdf")

        let confirmed = MetadataResolutionPipeline.manuallyConfirmedEnvelope(
            for: record,
            reviewedBy: "browser-clipper"
        )
        XCTAssertEqual(confirmed.reference.verificationStatus, .verifiedManual)
        XCTAssertEqual(confirmed.reference.reviewedBy, "browser-clipper")
        XCTAssertEqual(confirmed.reference.recordKey, highlightDOI)
        XCTAssertEqual(confirmed.evidence.recordKey, highlightDOI)
        XCTAssertTrue(confirmed.evidence.verificationHints.exactIdentifierMatch)
        XCTAssertFalse(confirmed.evidence.verificationHints.hasStructuredAuthors)
    }

    func testFetcherReturnsAuthorlessPaperURLOnlyWhenAccepted() async throws {
        stubPage(highlightURL, fixture: "nature-research-highlight")
        let crossref = crossrefHighlight()

        let (reference, pdfURL) = try await MetadataFetcher.fetchWithScrapedPDFURL(
            from: highlightURL,
            acceptingAuthorlessPaperURL: true,
            paperURLSession: StubURLProtocol.makeSession(),
            crossrefFetcher: { _ in crossref }
        )
        XCTAssertEqual(reference.doi, highlightDOI)
        XCTAssertTrue(reference.authors.isEmpty)
        XCTAssertEqual(pdfURL, "https://www.nature.com/articles/d41586-026-03638-3.pdf")

        do {
            _ = try await MetadataFetcher.fetchWithScrapedPDFURL(
                from: highlightURL,
                paperURLSession: StubURLProtocol.makeSession(),
                crossrefFetcher: { _ in crossref }
            )
            XCTFail("Callers that have not opted in must not receive an authorless record")
        } catch MetadataFetcher.FetchError.unsupported(let message) {
            XCTAssertTrue(message.contains("no authors"))
        }
    }
}
