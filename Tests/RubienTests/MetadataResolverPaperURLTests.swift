#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

/// URLProtocol-based stub for injecting fake HTTP responses.
///
/// `StubURLProtocol` also lives in `RubienCoreTests/PaperURLResolverTests.swift`,
/// but that target is a separate Swift module — internal types from two
/// modules can coexist when linked into the same `RubienPackageTests.xctest`
/// bundle without symbol collision. Duplicating here keeps the test
/// self-contained: this target (`RubienTests`) does not depend on
/// `RubienCoreTests`.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubs: [URL: (data: Data, response: HTTPURLResponse)] = [:]
    nonisolated(unsafe) static var failures: [URL: Error] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
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

@MainActor
final class MetadataResolverPaperURLTests: XCTestCase {

    // These integration tests rely on the resolver's URLSession singletons. For now,
    // verify the contract on the easy paths (rejected on malformed inputs etc.) and
    // defer full stubbing to PaperURLResolverTests which already covers the network
    // behavior. End-to-end integration with a stubbed session would require
    // dependency injection into MetadataResolver — out of scope for this task.

    func testEmptyInputRejected() async {
        let resolver = MetadataResolver()
        let outcome = await resolver.resolveManualEntry("")
        XCTAssertNil(outcome.preferredPDFURL)
        if case .rejected = outcome.result { /* ok */ } else { XCTFail("Expected .rejected") }
    }

    func testBareDOIStillWorks() async throws {
        // Network-dependent; skip in CI by default.
        try XCTSkipIf(ProcessInfo.processInfo.environment["RUBIEN_LIVE_TESTS"] != "1",
                       "Set RUBIEN_LIVE_TESTS=1 to run")
        let resolver = MetadataResolver()
        let outcome = await resolver.resolveManualEntry("10.18653/v1/2024.acl-long.123")
        XCTAssertNil(outcome.preferredPDFURL)  // bare DOI path doesn't yield a scraped URL
        switch outcome.result {
        case .verified, .candidate: break
        default: XCTFail("Expected .verified or .candidate, got \(outcome.result)")
        }
    }

    func testPreferredPDFURLNilOnNonVerified() async throws {
        // Network-dependent: the resolver's URLSession isn't injectable, so this
        // dial-out hits real DNS. Skip in CI; the invariant is also enforced
        // structurally by resolveIdentifierLocally (forces effectiveScrapedPDFURL
        // to nil on any non-.verified outcome).
        try XCTSkipIf(ProcessInfo.processInfo.environment["RUBIEN_LIVE_TESTS"] != "1",
                       "Set RUBIEN_LIVE_TESTS=1 to run")
        let resolver = MetadataResolver()
        // Use a paper URL that will fail (no matching stub / DNS error etc.)
        let outcome = await resolver.resolveManualEntry("https://openreview.net/forum?id=DOES-NOT-EXIST-9999")
        XCTAssertNil(outcome.preferredPDFURL,
                     "preferredPDFURL must be nil for non-.verified outcomes")
    }

    /// Integration test: PaperURLResolver throws .noAuthorsAvailable, and the
    /// catch handler in MetadataResolver.resolveIdentifierLocally converts the
    /// throw into a .candidate result with a single-element [MetadataCandidate].
    ///
    /// This requires injecting a stubbed URLSession into PaperURLResolver's
    /// call chain. Since PaperURLResolver.resolve accepts a session parameter
    /// (default .shared), the test needs MetadataResolver to forward an
    /// injected session — which it does NOT currently do. Two ways to land
    /// this test:
    ///
    /// (a) Refactor MetadataResolver to accept an injectable URLSession on
    ///     init or on resolveManualEntry. Modest API change.
    /// (b) Move this test to the PaperURLResolver layer: call
    ///     PaperURLResolver.resolve directly with the stubbed session, catch
    ///     ResolveError.noAuthorsAvailable, then construct the expected
    ///     CandidateEnvelope inline and verify the conversion logic via a
    ///     small helper extracted from resolveIdentifierLocally. (No
    ///     end-to-end MetadataResolver path, but exercises the conversion.)
    ///
    /// Option (b) is the smaller change. Implementation note: extract the
    /// no-author -> .candidate conversion into a static helper on
    /// MetadataResolver (e.g. `static func candidateEnvelope(forNoAuthors:
    /// partialRef:)`) and have both the catch handler in
    /// resolveIdentifierLocally AND this test call it.
    func testNoAuthorsResolverProducesCandidate() async throws {
        let session = StubURLProtocol.makeSession()
        StubURLProtocol.stub(
            "https://ieeexplore.ieee.org/document/8888",
            body: """
            <html><head>
            <meta name="citation_title" content="Author-less IEEE Paper">
            <meta name="citation_doi" content="10.1109/zzz.99999999">
            <meta name="citation_publication_date" content="2024">
            </head></html>
            """
        )
        defer { StubURLProtocol.reset() }

        // Call PaperURLResolver directly to capture the throw payload.
        // Stub the crossrefFetcher to throw — matches PaperURLResolverTests'
        // noAuthors test pattern so we don't hit the real CrossRef API.
        var caughtPayload: (Reference, String?)?
        do {
            _ = try await PaperURLResolver.resolve(
                URL(string: "https://ieeexplore.ieee.org/document/8888")!,
                session: session,
                crossrefFetcher: { _ in throw URLError(.notConnectedToInternet) }
            )
            XCTFail("Expected noAuthorsAvailable")
            return
        } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let ref, let pdf) {
            caughtPayload = (ref, pdf)
        } catch {
            XCTFail("Wrong error: \(error)")
            return
        }

        let (partialRef, _) = caughtPayload!
        XCTAssertEqual(partialRef.title, "Author-less IEEE Paper")
        XCTAssertTrue(partialRef.authors.isEmpty)

        // Exercise the REAL production conversion path. Task 4 step 7a
        // extracts candidateEnvelopeForNoAuthors as a static helper that
        // resolveIdentifierLocally's catch handler also calls — so this
        // test cannot silently drift from production.
        let envelope = MetadataResolver.candidateEnvelopeForNoAuthors(
            partialRef: partialRef,
            seed: nil,
            fallback: nil
        )
        XCTAssertEqual(envelope.candidates.count, 1)
        let candidate = envelope.candidates[0]
        XCTAssertEqual(candidate.title, "Author-less IEEE Paper")
        XCTAssertEqual(candidate.sourceRecordID, "10.1109/zzz.99999999")
        XCTAssertTrue(candidate.authors.isEmpty)
        XCTAssertEqual(candidate.score, 1.0)
        XCTAssertEqual(envelope.currentReference?.title, "Author-less IEEE Paper")
    }
}
#endif
