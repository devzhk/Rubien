import XCTest
@testable import RubienCore

private actor InvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class MetadataFetcherTests: XCTestCase {
    func testHuggingFacePaperURLExtractsCanonicalArXivIdentifier() {
        XCTAssertEqual(
            MetadataFetcher.extractIdentifier(
                from: "https://huggingface.co/papers/2607.09657"
            ),
            .arxiv("2607.09657")
        )
        XCTAssertEqual(
            MetadataFetcher.extractIdentifier(
                from: "https://www.huggingface.co/papers/2607.09657v2/?ref=daily"
            ),
            .arxiv("2607.09657")
        )
    }

    func testOtherHuggingFaceURLsDoNotExtractArXivIdentifiers() {
        XCTAssertNil(MetadataFetcher.extractIdentifier(from: "https://huggingface.co/papers"))
        XCTAssertNil(
            MetadataFetcher.extractIdentifier(
                from: "https://huggingface.co/papers/2607.09657/discussion"
            )
        )
        XCTAssertNil(
            MetadataFetcher.extractIdentifier(
                from: "https://huggingface.co/models/2607.09657"
            )
        )
        XCTAssertNil(
            MetadataFetcher.extractIdentifier(
                from: "https://user:pass@huggingface.co/papers/2607.09657"
            )
        )
    }

    func testParsePubMedResponseSetsPMIDAndPMCID() throws {
        let json = """
        {
          "result": {
            "uids": ["12345"],
            "12345": {
              "title": "Sample PubMed Article.",
              "pubdate": "2024 Jan 02",
              "source": "Journal of Tests",
              "volume": "12",
              "issue": "3",
              "pages": "100-120",
              "authors": [
                { "name": "Smith J" },
                { "name": "Doe J" }
              ],
              "articleids": [
                { "idtype": "doi", "value": "10.1000/test-doi" },
                { "idtype": "pmc", "value": "PMC999999" }
              ]
            }
          }
        }
        """.data(using: .utf8)!

        let reference = try MetadataFetcher.parsePubMedResponse(json, pmid: "12345")

        XCTAssertEqual(reference.title, "Sample PubMed Article")
        XCTAssertEqual(reference.pmid, "12345")
        XCTAssertEqual(reference.pmcid, "PMC999999")
        XCTAssertEqual(reference.doi, "10.1000/test-doi")
        XCTAssertEqual(reference.year, 2024)
    }

    func testParsePubMedPIISearchResponseRequiresSingleExactMatch() throws {
        let match = """
        {
          "esearchresult": {
            "count": "1",
            "idlist": ["42392073"]
          }
        }
        """.data(using: .utf8)!
        XCTAssertEqual(
            try MetadataFetcher.parsePubMedPIISearchResponse(match),
            "42392073"
        )

        let noMatch = """
        {"esearchresult":{"count":"0","idlist":[]}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try MetadataFetcher.parsePubMedPIISearchResponse(noMatch)) { error in
            guard case MetadataFetcher.FetchError.unsupported(let message) = error else {
                return XCTFail("Expected unsupported error, got \(error)")
            }
            XCTAssertTrue(message.contains("No PubMed record"))
        }

        let multipleMatches = """
        {"esearchresult":{"count":"2","idlist":["42392073","42392074"]}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(
            try MetadataFetcher.parsePubMedPIISearchResponse(multipleMatches)
        ) { error in
            guard case MetadataFetcher.FetchError.unsupported(let message) = error else {
                return XCTFail("Expected unsupported error, got \(error)")
            }
            XCTAssertTrue(message.contains("Multiple PubMed records"))
        }
    }

    func testParseArXivResponseUsesIdentifierForCanonicalURL() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <id>http://arxiv.org/abs/2301.07041v2</id>
            <published>2023-01-17T00:00:00Z</published>
            <title>  Example   arXiv   Title  </title>
            <summary>  Example abstract. </summary>
            <author><name>Doe, Jane</name></author>
          </entry>
        </feed>
        """.data(using: .utf8)!

        let reference = try MetadataFetcher.parseArXivResponse(xml, arxivId: "2301.07041")

        XCTAssertEqual(reference.title, "Example arXiv Title")
        XCTAssertEqual(reference.url, "https://arxiv.org/abs/2301.07041")
        XCTAssertEqual(reference.year, 2023)
        XCTAssertEqual(reference.authors, [AuthorName.parse("Doe, Jane")])
    }

    // MARK: - CrossRef parsing

    func testParseCrossrefResponseNormalizesPrettyPrintedJATSScripts() throws {
        let rawAbstract = """
        <jats:p>
            Gas permeabilities of H
            <jats:sub>2</jats:sub>
            , O
            <jats:sub>2</jats:sub>
            , CO
            <jats:sub>2</jats:sub>
            , and CH
            <jats:sub>4</jats:sub>
            exceed 10
            <jats:sup>4</jats:sup>
            and 10
            <jats:sup>5</jats:sup>
            Barrers.
        </jats:p>
        """
        let payload: [String: Any] = [
            "status": "ok",
            "message": [
                "DOI": "10.1126/sciadv.abn9545",
                "type": "journal-article",
                "title": ["A Test Paper"],
                "author": [["given": "Test", "family": "Author"]],
                "abstract": rawAbstract,
                "published-print": ["date-parts": [[2022]]]
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)

        let reference = try MetadataFetcher.parseCrossrefResponse(
            json,
            doi: "10.1126/sciadv.abn9545"
        )

        XCTAssertEqual(
            reference.abstract,
            "Gas permeabilities of H₂, O₂, CO₂, and CH₄ exceed 10⁴ and 10⁵ Barrers."
        )
    }

    // MARK: - CrossRef CJK Author Name Tests

    func testParseCrossrefResponseSwapsCJKAuthorNames() throws {
        // CrossRef returns given/family swapped for Chinese authors:
        // {"given":"Wu","family":"Haoyun"} should become given:"Haoyun", family:"Wu"
        let json = """
        {
          "status": "ok",
          "message": {
            "DOI": "10.18307/2023.0320",
            "type": "journal-article",
            "title": ["Research on multi-objective driven dispatching water level of Lake Taihu"],
            "author": [
              {"given": "Wu", "family": "Haoyun", "sequence": "first"},
              {"given": "Liu", "family": "Min", "sequence": "additional"},
              {"given": "Jin", "family": "Ke", "sequence": "additional"}
            ],
            "container-title": ["Journal of Lake Sciences"],
            "published-print": {"date-parts": [[2023]]},
            "volume": "35",
            "issue": "3",
            "page": "1009-1021"
          }
        }
        """.data(using: .utf8)!

        let reference = try MetadataFetcher.parseCrossrefResponse(json, doi: "10.18307/2023.0320")

        // After correction: "Wu" (2 chars, likely family) should be in family field
        XCTAssertEqual(reference.authors.count, 3)
        XCTAssertEqual(reference.authors[0].family, "Wu")
        XCTAssertEqual(reference.authors[0].given, "Haoyun")
        // "Liu"/"Min" are equal-length (3 chars each) — ambiguous, not swapped.
        XCTAssertEqual(reference.authors[1].given, "Liu")
        XCTAssertEqual(reference.authors[1].family, "Min")
        XCTAssertEqual(reference.title, "Research on multi-objective driven dispatching water level of Lake Taihu")
        XCTAssertEqual(reference.doi, "10.18307/2023.0320")
    }

    func testParseCrossrefResponseKeepsWesternAuthorNamesUnchanged() throws {
        // Western names with longer given names should NOT be swapped
        let json = """
        {
          "status": "ok",
          "message": {
            "DOI": "10.1002/test",
            "type": "journal-article",
            "title": ["A Test Paper"],
            "author": [
              {"given": "John William", "family": "Smith", "sequence": "first"},
              {"given": "Alice", "family": "Johnson", "sequence": "additional"}
            ],
            "published-print": {"date-parts": [[2024]]}
          }
        }
        """.data(using: .utf8)!

        let reference = try MetadataFetcher.parseCrossrefResponse(json, doi: "10.1002/test")

        XCTAssertEqual(reference.authors[0].given, "John William")
        XCTAssertEqual(reference.authors[0].family, "Smith")
        XCTAssertEqual(reference.authors[1].given, "Alice")
        XCTAssertEqual(reference.authors[1].family, "Johnson")
    }

    func testParseCrossrefResponseHandlesOrganizationAuthor() throws {
        // CrossRef sometimes has organization names in "name" field
        let json = """
        {
          "status": "ok",
          "message": {
            "DOI": "10.1002/org",
            "type": "journal-article",
            "title": ["Org Paper"],
            "author": [
              {"name": "World Health Organization"},
              {"given": "Test", "family": "Author"}
            ],
            "published-print": {"date-parts": [[2024]]}
          }
        }
        """.data(using: .utf8)!

        let reference = try MetadataFetcher.parseCrossrefResponse(json, doi: "10.1002/org")

        XCTAssertEqual(reference.authors.count, 2)
        // "Test"(4 chars) / "Author"(6 chars): given > 3 chars, NOT treated as CJK swap
        XCTAssertEqual(reference.authors[1].given, "Test")
        XCTAssertEqual(reference.authors[1].family, "Author")
    }

    // MARK: - Retry/Error Classification

    func testHTTP429IsRetryable() {
        let error = MetadataFetcher.FetchError.httpError(429)
        XCTAssertTrue(error.isRetryable, "429 rate-limit errors should be retryable")
    }

    func testHTTP500IsRetryable() {
        let error = MetadataFetcher.FetchError.httpError(500)
        XCTAssertTrue(error.isRetryable, "500 server errors should be retryable")
    }

    func testHTTP404IsNotRetryable() {
        let error = MetadataFetcher.FetchError.httpError(404)
        XCTAssertFalse(error.isRetryable, "404 not-found errors should not be retryable")
    }

    // MARK: - arXiv source race

    func testRaceArxivWinsWhenOpenAlexSlow() async throws {
        let result = try await MetadataFetcher.raceArxivSources(
            arxivId: "2410.08260",
            arxivFetch: { id in
                try await Task.sleep(nanoseconds: 20_000_000)
                return Reference(title: "From arXiv", url: "https://arxiv.org/abs/\(id)")
            },
            abstractFetch: { _ in
                try await Task.sleep(nanoseconds: 300_000_000)
                return Reference(title: "From abstract page")
            },
            openAlexFetch: { _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return Reference(title: "From OpenAlex")
            }
        )
        XCTAssertEqual(result.title, "From arXiv")
        XCTAssertEqual(result.url, "https://arxiv.org/abs/2410.08260")
    }

    func testRaceOpenAlexWinsWhenArxivStalls() async throws {
        let result = try await MetadataFetcher.raceArxivSources(
            arxivId: "2410.08260",
            arxivFetch: { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return Reference(title: "Should not win")
            },
            abstractFetch: { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return Reference(title: "Should not win")
            },
            openAlexFetch: { _ in
                try await Task.sleep(nanoseconds: 10_000_000)
                return Reference(title: "From OpenAlex")
            }
        )
        XCTAssertEqual(result.title, "From OpenAlex")
        XCTAssertEqual(result.url, "https://arxiv.org/abs/2410.08260")
    }

    func testRaceAllFailRethrowsArxivError() async {
        struct ArxivErr: Error {}
        struct AbstractErr: Error {}
        struct OAErr: Error {}
        do {
            _ = try await MetadataFetcher.raceArxivSources(
                arxivId: "2410.08260",
                waitBeforeStartingAbstractFallback: {},
                arxivFetch: { _ in throw ArxivErr() },
                abstractFetch: { _ in throw AbstractErr() },
                openAlexFetch: { _ in throw OAErr() }
            )
            XCTFail("expected throw")
        } catch is ArxivErr {
            // expected — arXiv error preserved when all sources fail
        } catch {
            XCTFail("expected ArxivErr, got \(error)")
        }
    }

    func testRaceOpenAlexNilDoesNotMaskArxivSuccess() async throws {
        let result = try await MetadataFetcher.raceArxivSources(
            arxivId: "2410.08260",
            arxivFetch: { id in
                try await Task.sleep(nanoseconds: 20_000_000)
                return Reference(title: "From arXiv", url: "https://arxiv.org/abs/\(id)")
            },
            abstractFetch: { _ in throw URLError(.cannotParseResponse) },
            openAlexFetch: { _ in nil /* OpenAlex 404 / not yet indexed */ }
        )
        XCTAssertEqual(result.title, "From arXiv")
    }

    func testRaceAbstractPageWinsForFreshPaper() async throws {
        let result = try await MetadataFetcher.raceArxivSources(
            arxivId: "2607.14935",
            waitBeforeStartingAbstractFallback: {},
            arxivFetch: { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return Reference(title: "Stalled Atom API")
            },
            abstractFetch: { id in
                Reference(title: "Fresh abstract page", url: "https://arxiv.org/abs/\(id)")
            },
            openAlexFetch: { _ in nil /* DOI not indexed yet */ }
        )
        XCTAssertEqual(result.title, "Fresh abstract page")
        XCTAssertEqual(result.url, "https://arxiv.org/abs/2607.14935")
    }

    func testPendingPrimaryWinsBeforeAbstractFallbackStarts() async throws {
        let primaryMayFinish = AsyncGate()
        let fallbackDelayStarted = AsyncGate()
        let abstractRequests = InvocationCounter()
        let resolution = Task {
            try await MetadataFetcher.raceArxivSources(
                arxivId: "2607.14935",
                waitBeforeStartingAbstractFallback: {
                    await fallbackDelayStarted.open()
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                },
                arxivFetch: { id in
                    await primaryMayFinish.wait()
                    return Reference(title: "Preferred Atom result", url: "https://arxiv.org/abs/\(id)")
                },
                abstractFetch: { _ in
                    await abstractRequests.increment()
                    return Reference(title: "Unexpected fallback")
                },
                openAlexFetch: { _ in nil /* starts the fallback */ }
            )
        }

        await fallbackDelayStarted.wait()
        await primaryMayFinish.open()
        let result = try await resolution.value
        XCTAssertEqual(result.title, "Preferred Atom result")
        let requestCount = await abstractRequests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testCallerCancellationWhileFallbackDelayIsPendingPropagates() async {
        let fallbackDelayStarted = AsyncGate()
        let resolution = Task {
            try await MetadataFetcher.raceArxivSources(
                arxivId: "2607.14935",
                waitBeforeStartingAbstractFallback: {
                    await fallbackDelayStarted.open()
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                },
                arxivFetch: { _ in
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    return Reference(title: "Stalled Atom")
                },
                abstractFetch: { id in
                    Reference(title: "Fallback abstract page", url: "https://arxiv.org/abs/\(id)")
                },
                openAlexFetch: { _ in nil /* starts the fallback */ }
            )
        }

        await fallbackDelayStarted.wait()
        resolution.cancel()
        do {
            _ = try await resolution.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testFastPrimarySourceDoesNotStartAbstractPageFallback() async throws {
        let abstractRequests = InvocationCounter()
        let result = try await MetadataFetcher.raceArxivSources(
            arxivId: "2410.08260",
            arxivFetch: { id in
                Reference(title: "From arXiv", url: "https://arxiv.org/abs/\(id)")
            },
            abstractFetch: { _ in
                await abstractRequests.increment()
                return Reference(title: "Unexpected abstract request")
            },
            openAlexFetch: { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return Reference(title: "Slow OpenAlex")
            }
        )

        XCTAssertEqual(result.title, "From arXiv")
        let requestCount = await abstractRequests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testRaceSimultaneousSuccessReturnsOneWithoutDeadlock() async throws {
        // Atom and OpenAlex resolve on the same scheduling tick — exercises
        // the for-await loop when outcomes pile up. Either may win.
        let result = try await MetadataFetcher.raceArxivSources(
            arxivId: "2410.08260",
            arxivFetch: { id in
                try await Task.sleep(nanoseconds: 10_000_000)
                return Reference(title: "From arXiv", url: "https://arxiv.org/abs/\(id)")
            },
            abstractFetch: { _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return Reference(title: "From abstract page")
            },
            openAlexFetch: { _ in
                try await Task.sleep(nanoseconds: 10_000_000)
                return Reference(title: "From OpenAlex")
            }
        )
        XCTAssertTrue(["From arXiv", "From OpenAlex"].contains(result.title))
    }

    func testParseArXivAbstractPageUsesCitationMetadata() throws {
        let html = """
        <html><head>
        <meta name="citation_title" content="VideoChat3: Fully Open Video MLLM">
        <meta name="citation_author" content="Li, Xinhao">
        <meta name="citation_author" content="Zhu, Yuhan">
        <meta name="citation_date" content="2026/07/16">
        <meta name="citation_doi" content="10.1234/published-version">
        <meta name="citation_pdf_url" content="https://arxiv.org/pdf/2607.14935">
        <meta name="citation_arxiv_id" content="2607.14935">
        <meta name="citation_abstract" content="A fresh paper available before API propagation.">
        </head></html>
        """.data(using: .utf8)!

        let reference = try MetadataFetcher.parseArXivAbstractPage(html, arxivId: "2607.14935")

        XCTAssertEqual(reference.title, "VideoChat3: Fully Open Video MLLM")
        XCTAssertEqual(reference.authors.map(\.family), ["Li", "Zhu"])
        XCTAssertEqual(reference.year, 2026)
        XCTAssertEqual(reference.doi, "10.1234/published-version")
        XCTAssertEqual(reference.url, "https://arxiv.org/abs/2607.14935")
        XCTAssertEqual(reference.abstract, "A fresh paper available before API propagation.")
    }

    func testParseArXivAbstractPageRejectsMismatchedIdentifier() {
        let html = """
        <html><head>
        <meta name="citation_title" content="Wrong Paper">
        <meta name="citation_author" content="Author, Example">
        <meta name="citation_arxiv_id" content="9999.99999">
        </head></html>
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try MetadataFetcher.parseArXivAbstractPage(html, arxivId: "2607.14935")
        )
    }
}
