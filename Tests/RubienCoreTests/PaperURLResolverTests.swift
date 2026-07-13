import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLProtocol, URLSessionConfiguration, HTTPURLResponse
#endif
@testable import RubienCore

/// URLProtocol-based stub for injecting fake HTTP responses.
/// Static state is reset in setUp + tearDown to prevent cross-test leakage.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubs: [URL: (data: Data, response: HTTPURLResponse)] = [:]
    nonisolated(unsafe) static var failures: [URL: Error] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        StubURLProtocol.requests.append(request)
        if let err = StubURLProtocol.failures[url] {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        if let stub = StubURLProtocol.stubs[url] {
            client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
    }

    override func stopLoading() {}

    static func reset() {
        stubs = [:]
        failures = [:]
        requests = []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func stub(_ urlString: String, status: Int = 200, contentType: String = "text/html", body: String) {
        let url = URL(string: urlString)!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        stubs[url] = (body.data(using: .utf8)!, response)
    }
}

final class PaperURLResolverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: "CitationMeta/\(name)", withExtension: "html")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - OpenReview success path (no DOI)

    func testOpenReviewLandingProducesConferencePaper() async throws {
        StubURLProtocol.stub(
            "https://openreview.net/forum?id=EXAMPLE",
            body: loadFixture("openreview-forum")
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://openreview.net/forum?id=EXAMPLE")!,
            session: StubURLProtocol.makeSession()
        )

        XCTAssertEqual(outcome.reference.title, "Attention Is All You Need")
        XCTAssertEqual(outcome.reference.referenceType, .conferencePaper)
        XCTAssertEqual(outcome.reference.metadataSource, .publisherCitationMeta)
        XCTAssertEqual(outcome.reference.url, "https://openreview.net/forum?id=EXAMPLE")
        XCTAssertEqual(outcome.scrapedPDFURL, "https://openreview.net/pdf?id=EXAMPLE")
    }

    // MARK: - Content-Type rejection

    func testNonHTMLContentTypeRejected() async {
        StubURLProtocol.stub(
            "https://openreview.net/forum?id=EXAMPLE",
            contentType: "application/pdf",
            body: ""
        )

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://openreview.net/forum?id=EXAMPLE")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected unexpectedContentType")
        } catch PaperURLResolver.ResolveError.unexpectedContentType {
            // expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Strong evidence gate (paywall)

    func testInsufficientCitationMetaRejected() async {
        // Stub at the canonical URL (no www.) since the resolver fetches the
        // canonicalized form, not the original input.
        StubURLProtocol.stub(
            "https://sciencedirect.com/science/article/pii/SXXXX",
            body: loadFixture("paywall-login-page")
        )

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://www.sciencedirect.com/science/article/pii/SXXXX")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected insufficientMetadata")
        } catch PaperURLResolver.ResolveError.insufficientMetadata {
            // expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - CVF citation_* path

    func testCVFLandingExtractsFromCitationMeta() async throws {
        let url = "https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html"
        StubURLProtocol.stub(url, body: loadFixture("cvf-paper"))

        let outcome = try await PaperURLResolver.resolve(
            URL(string: url)!,
            session: StubURLProtocol.makeSession()
        )

        XCTAssertEqual(outcome.reference.title, "VGGT: Visual Geometry Grounded Transformer")
        XCTAssertEqual(outcome.reference.referenceType, .conferencePaper)
        XCTAssertEqual(outcome.reference.metadataSource, .cvfOpenAccess)
        XCTAssertEqual(outcome.reference.authors.count, 6)
        XCTAssertEqual(outcome.reference.authors.first?.family, "Wang")
        XCTAssertEqual(outcome.reference.year, 2025)
        XCTAssertEqual(outcome.reference.pages, "5294-5306")
        XCTAssertEqual(outcome.scrapedPDFURL, "https://openaccess.thecvf.com/content/CVPR2025/papers/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.pdf")
    }

    // MARK: - eLife official API path

    func testELifeArticleResolvesMetadataAndPDFThroughOfficialAPI() async throws {
        StubURLProtocol.stub(
            "https://api.elifesciences.org/articles/29515",
            contentType: "application/vnd.elife.article-vor+json; version=8",
            body: """
            {
              "status": "vor",
              "id": "29515",
              "version": 1,
              "type": "research-article",
              "doi": "10.7554/eLife.29515",
              "title": "Theta-burst microstimulation in the human entorhinal area improves memory specificity",
              "published": "2017-10-24T00:00:00Z",
              "volume": 6,
              "elocationId": "e29515",
              "pdf": "https://cdn.elifesciences.org/articles/29515/elife-29515-v1.pdf",
              "abstract": {
                "content": [
                  {"type": "paragraph", "text": "The <i>hippocampus</i> is critical for episodic memory."}
                ]
              },
              "authors": [
                {"type": "person", "name": {"index": "Titiz, Ali S", "preferred": "Ali S Titiz"}},
                {"type": "person", "name": {"index": "Hill, Michael R H", "preferred": "Michael R H Hill"}}
              ]
            }
            """
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://www.elifesciences.org/articles/29515.pdf")!,
            session: StubURLProtocol.makeSession(),
            crossrefFetcher: { _ in throw URLError(.notConnectedToInternet) }
        )

        XCTAssertEqual(outcome.reference.title, "Theta-burst microstimulation in the human entorhinal area improves memory specificity")
        XCTAssertEqual(outcome.reference.authors.count, 2)
        XCTAssertEqual(outcome.reference.authors[0], AuthorName(given: "Ali S", family: "Titiz"))
        XCTAssertEqual(outcome.reference.year, 2017)
        XCTAssertEqual(outcome.reference.journal, "eLife")
        XCTAssertEqual(outcome.reference.volume, "6")
        XCTAssertEqual(outcome.reference.pages, "e29515")
        XCTAssertEqual(outcome.reference.doi, "10.7554/eLife.29515")
        XCTAssertEqual(outcome.reference.url, "https://elifesciences.org/articles/29515")
        XCTAssertEqual(outcome.reference.abstract, "The hippocampus is critical for episodic memory.")
        XCTAssertEqual(outcome.reference.referenceType, .journalArticle)
        XCTAssertEqual(outcome.reference.metadataSource, .publisherCitationMeta)
        XCTAssertEqual(outcome.scrapedPDFURL, "https://cdn.elifesciences.org/articles/29515/elife-29515-v1.pdf")
        XCTAssertNil(
            StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Accept"),
            "eLife rejects generic JSON Accept headers with HTTP 406"
        )
    }

    func testELifeGroupAuthorIsPreserved() async throws {
        StubURLProtocol.stub(
            "https://api.elifesciences.org/articles/99998",
            contentType: "application/vnd.elife.article-rp+json; version=8",
            body: """
            {
              "id": "99998",
              "title": "A consortium study",
              "published": "2026-01-02T00:00:00Z",
              "authors": [
                {"type": "group", "name": "The Example Research Consortium"}
              ]
            }
            """
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://elifesciences.org/articles/99998")!,
            session: StubURLProtocol.makeSession()
        )

        XCTAssertEqual(
            outcome.reference.authors,
            [AuthorName(given: "", family: "The Example Research Consortium")]
        )
    }

    func testELifeRejectsUnexpectedPDFHostFromAPI() async throws {
        StubURLProtocol.stub(
            "https://api.elifesciences.org/articles/99999",
            contentType: "application/vnd.elife.article-vor+json; version=8",
            body: """
            {
              "id": "99999",
              "title": "An article with an unsafe PDF URL",
              "published": "2026-01-02T00:00:00Z",
              "pdf": "https://downloads.example.com/article.pdf",
              "authors": [
                {"type": "person", "name": {"index": "Smith, Jane", "preferred": "Jane Smith"}}
              ]
            }
            """
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://elifesciences.org/articles/99999")!,
            session: StubURLProtocol.makeSession()
        )

        XCTAssertNil(outcome.scrapedPDFURL)
    }

    func testELifeRejectsNonJSONMediaType() async {
        StubURLProtocol.stub(
            "https://api.elifesciences.org/articles/99997",
            contentType: "text/notjson",
            body: #"{"id":"99997","title":"Not actually JSON media"}"#
        )

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://elifesciences.org/articles/99997")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected unexpectedContentType")
        } catch PaperURLResolver.ResolveError.unexpectedContentType(let contentType) {
            XCTAssertEqual(contentType, "text/notjson")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Canonical Reference.url after canonicalization

    func testCanonicalURLOnReference() async throws {
        StubURLProtocol.stub(
            "https://nature.com/articles/foo",
            body: """
            <html><head>
            <meta name="citation_title" content="Nature Paper">
            <meta name="citation_author" content="Smith, J.">
            <meta name="citation_journal_title" content="Nature">
            <meta name="citation_publication_date" content="2024">
            </head></html>
            """
        )

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "HTTPS://WWW.NATURE.COM/articles/foo")!,
            session: StubURLProtocol.makeSession()
        )

        // Canonical: lowercase scheme + host, no www.
        XCTAssertEqual(outcome.reference.url, "https://nature.com/articles/foo")
    }

    // MARK: - No-author safeguard

    func testNoAuthorsReturnsCandidate() async {
        // Hypothetical: citation_title + citation_doi only, no citation_author.
        // CrossRef stub will also fail (no stub registered for crossref endpoint).
        StubURLProtocol.stub(
            "https://ieeexplore.ieee.org/document/1234",
            body: """
            <html><head>
            <meta name="citation_title" content="IEEE Doc Without Authors">
            <meta name="citation_doi" content="10.1109/foo.bar.99999999">
            <meta name="citation_publication_date" content="2024">
            </head></html>
            """
        )

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://ieeexplore.ieee.org/document/1234")!,
                session: StubURLProtocol.makeSession(),
                crossrefFetcher: { _ in throw URLError(.notConnectedToInternet) }
            )
            XCTFail("Expected noAuthorsAvailable")
        } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let partialRef, _) {
            // Verify the payload carries the partial Reference so the caller
            // can build a CandidateEnvelope from it.
            XCTAssertEqual(partialRef.title, "IEEE Doc Without Authors")
            XCTAssertEqual(partialRef.doi, "10.1109/foo.bar.99999999")
            XCTAssertTrue(partialRef.authors.isEmpty)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - HTTP 503 retried

    func testHTTPServerErrorRetries() async throws {
        // First request 503, second 200 — needs a counter-based stub.
        // Use a custom URLProtocol subclass for this test:
        final class CountingStub: URLProtocol {
            nonisolated(unsafe) static var attemptCount = 0
            nonisolated(unsafe) static var html = ""
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.attemptCount += 1
                let url = request.url!
                if Self.attemptCount == 1 {
                    let r = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
                    client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                } else {
                    let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
                    client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Self.html.data(using: .utf8)!)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        CountingStub.attemptCount = 0
        CountingStub.html = loadFixture("openreview-forum")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingStub.self]
        let session = URLSession(configuration: config)

        let outcome = try await PaperURLResolver.resolve(
            URL(string: "https://openreview.net/forum?id=EXAMPLE")!,
            session: session
        )
        XCTAssertEqual(CountingStub.attemptCount, 2)
        XCTAssertEqual(outcome.reference.title, "Attention Is All You Need")
    }

    // MARK: - HTTP 404 does not retry

    func testHTTP404DoesNotRetry() async {
        StubURLProtocol.stub("https://openreview.net/forum?id=DEAD", status: 404, body: "")

        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://openreview.net/forum?id=DEAD")!,
                session: StubURLProtocol.makeSession()
            )
            XCTFail("Expected fetchFailed")
        } catch PaperURLResolver.ResolveError.fetchFailed(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
