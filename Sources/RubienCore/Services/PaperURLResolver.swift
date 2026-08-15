import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Public API

/// Resolves paper-landing-page URLs to authoritative Reference records.
/// Stateless enum, callable from any actor context.
public enum PaperURLResolver {
    public struct Outcome: Sendable {
        public let reference: Reference
        public let scrapedPDFURL: String?
    }

    public enum ResolveError: Error, Sendable {
        case unknownHost
        case unsupportedScheme
        case fetchFailed(statusCode: Int, host: String)
        case redirectedAwayFromAllowlist(finalHost: String)
        case unexpectedContentType(String)
        case insufficientMetadata
        /// Empty `Reference.authors` after merge. Payload includes the
        /// partially-scraped Reference so the caller can construct a
        /// CandidateEnvelope for user review per spec §4. scrapedPDFURL
        /// is included for completeness but the caller will discard it
        /// (preferredPDFURL is .verified-only).
        case noAuthorsAvailable(reference: Reference, scrapedPDFURL: String?)
        case timedOut
        case networkUnavailable
    }

    /// Returns the canonical landing URL for a supported paper URL, including
    /// PDF variants. Callers can compare these URLs before associating
    /// page-controlled download metadata with the active article.
    public static func canonicalLandingURL(for url: URL) -> URL? {
        guard let canonical = canonicalize(url),
              let host = KnownPaperHost.classify(canonical) else {
            return nil
        }
        return rewritePDFURLToLanding(canonical, host: host)
    }

    /// Returns true when a publisher PDF URL identifies the same paper as an
    /// article URL. Most publishers have a direct PDF-to-landing rewrite;
    /// Oxford Academic and GeoscienceWorld use mutable PDF asset IDs, so their
    /// PDFs are compared by stable journal/issue locators (or an Oxford DOI).
    public static func publisherPDFURL(_ pdfURL: URL, matches articleURL: URL) -> Bool {
        guard pdfURL.pathExtension.lowercased() == "pdf",
              articleURL.pathExtension.lowercased() != "pdf" else {
            return false
        }

        let articleIsOxford = isOxfordAcademicHost(articleURL)
        let pdfIsOxford = isOxfordAcademicHost(pdfURL)
        if articleIsOxford || pdfIsOxford {
            guard articleIsOxford,
                  pdfIsOxford,
                  let article = oxfordAcademicArticle(from: articleURL),
                  let pdfIdentity = oxfordAcademicPDFIdentity(from: pdfURL) else {
                return false
            }
            return article.identity == pdfIdentity
        }

        let articleIsGeoscienceWorld = isGeoscienceWorldHost(articleURL)
        let pdfIsGeoscienceWorld = isGeoscienceWorldHost(pdfURL)
        if articleIsGeoscienceWorld || pdfIsGeoscienceWorld {
            guard articleIsGeoscienceWorld,
                  pdfIsGeoscienceWorld,
                  let article = geoscienceWorldArticle(from: articleURL),
                  let pdfIdentity = geoscienceWorldPDFIdentity(from: pdfURL) else {
                return false
            }
            return article.assignedIssueIdentity == pdfIdentity
        }

        if let articleLandingURL = canonicalLandingURL(for: articleURL),
           let pdfLandingURL = canonicalLandingURL(for: pdfURL),
           articleLandingURL == pdfLandingURL {
            return true
        }
        return false
    }

    public static func resolve(
        _ url: URL,
        session: URLSession = .shared,
        doiHint: String? = nil,
        publisherPDFURLHint: String? = nil,
        // Wrapped in an explicit @Sendable closure rather than passing
        // `MetadataFetcher.fetchFromDOI` directly: Swift 6 can't auto-infer
        // Sendable for static funcs on a type with mutable static state
        // (MetadataFetcher.contactEmail). The closure captures nothing and
        // is trivially Sendable.
        crossrefFetcher: @Sendable (String) async throws -> Reference = { try await MetadataFetcher.fetchFromDOI($0) }
    ) async throws -> Outcome {
        // 1. Canonicalize.
        guard let canonical = canonicalize(url) else {
            throw ResolveError.unsupportedScheme
        }

        // 2. Classify.
        guard let host = KnownPaperHost.classify(canonical) else {
            throw ResolveError.unknownHost
        }

        // 3. Rewrite PDF URL → landing URL if applicable.
        let landingURL = rewritePDFURLToLanding(canonical, host: host)
        let matchedPublisherPDFURL: String? = publisherPDFURLHint
            .flatMap(URL.init(string:))
            .flatMap { pdfURL in
                guard pdfURL.scheme?.lowercased() == "https",
                      pdfURL.user == nil,
                      pdfURL.password == nil,
                      pdfURL.port == nil || pdfURL.port == 443,
                      Self.publisherPDFURL(pdfURL, matches: landingURL) else {
                    return nil
                }
                return pdfURL.absoluteString
            }

        // 4. Resolve publisher metadata. APS, Science, and ACS URLs carry an
        // authoritative DOI in the path, so resolve them through CrossRef
        // without fetching publisher pages that commonly reject automated
        // clients. Oxford Academic's landing pages are similarly protected;
        // its Silverchair minimal page bridges numeric article IDs to DOIs.
        // eLife exposes a stable, keyless JSON API; the remaining hosts use
        // the generic citation_* scraper.
        let (sourceReference, publisherPDFURL): (Reference, String?)
        if host == .aps {
            (sourceReference, publisherPDFURL) = try await resolveAPS(
                landingURL: landingURL,
                crossrefFetcher: crossrefFetcher
            )
        } else if host == .science || host == .acs {
            (sourceReference, publisherPDFURL) = try await resolveDOIPublisher(
                landingURL: landingURL,
                host: host,
                crossrefFetcher: crossrefFetcher
            )
        } else if host == .oxfordAcademic {
            (sourceReference, publisherPDFURL) = try await resolveOxfordAcademic(
                landingURL: landingURL,
                session: session,
                doiHint: doiHint,
                crossrefFetcher: crossrefFetcher
            )
        } else if host == .geoscienceWorld {
            (sourceReference, publisherPDFURL) = try await resolveGeoscienceWorld(
                landingURL: landingURL,
                session: session,
                doiHint: doiHint,
                matchedPublisherPDFURL: matchedPublisherPDFURL,
                crossrefFetcher: crossrefFetcher
            )
        } else if host == .eLife {
            (sourceReference, publisherPDFURL) = try await resolveELife(
                landingURL: landingURL,
                session: session
            )
        } else if host == .cellPress {
            (sourceReference, publisherPDFURL) = try await resolveCellPress(
                landingURL: landingURL,
                session: session
            )
        } else {
            (sourceReference, publisherPDFURL) = try await resolveCitationMeta(
                landingURL: landingURL,
                host: host,
                session: session
            )
        }

        // 5. Normalize source metadata through CrossRef when it carries a DOI.
        // DOI-bearing publisher paths already resolved directly in step 4.
        var finalReference = sourceReference
        if host != .aps, host != .science, host != .acs, host != .oxfordAcademic,
           host != .geoscienceWorld,
           let doi = sourceReference.doi?.trimmingCharacters(in: .whitespacesAndNewlines),
           !doi.isEmpty {
            do {
                let crossref = try await crossrefFetcher(doi)
                let sourceTitle = sourceReference.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let crossrefTitle = crossref.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let score = MetadataResolution.titleSimilarity(sourceTitle, crossrefTitle)
                if score >= 0.80 {
                    finalReference = MetadataResolution.mergeReference(primary: crossref, fallback: sourceReference)
                    // Force canonical landing URL — CrossRef may have populated url with doi.org redirect.
                    finalReference.url = landingURL.absoluteString
                    // Preserve the per-host metadataSource assigned by the
                    // source path (.cvfOpenAccess for CVF,
                    // .publisherCitationMeta for citation-meta pages):
                    // the user pasted a publisher URL, so provenance reflects
                    // that path rather than CrossRef.
                    finalReference.metadataSource = sourceReference.metadataSource
                } else {
                    // Title mismatch (chapter-vs-book scenario) — keep scraper-only.
                    // Log via existing logger if available; spec uses resolverTrace which lives in
                    // the resolver layer; here we silently keep the scraper-only Reference.
                }
            } catch {
                // CrossRef failure is non-fatal — keep scraper-only Reference.
            }
        }

        // 6. No-author safeguard. Throw with payload so the caller can build
        // a CandidateEnvelope from the partial Reference (spec §4 requires
        // .candidate, not .rejected).
        if finalReference.authors.isEmpty {
            throw ResolveError.noAuthorsAvailable(
                reference: finalReference,
                scrapedPDFURL: publisherPDFURL
            )
        }

        return Outcome(reference: finalReference, scrapedPDFURL: publisherPDFURL)
    }

    // MARK: - APS DOI path

    private static func resolveAPS(
        landingURL: URL,
        crossrefFetcher: @Sendable (String) async throws -> Reference
    ) async throws -> (Reference, String?) {
        guard let article = apsArticle(from: landingURL) else {
            throw ResolveError.insufficientMetadata
        }

        var reference = try await crossrefFetcher(article.doi)
        // Preserve the publisher page the user supplied instead of CrossRef's
        // doi.org/link.aps.org URL. PDF inputs have already been rewritten to
        // the corresponding abstract page.
        reference.url = landingURL.absoluteString

        // Accepted-paper pages do not consistently expose a version-of-record
        // PDF yet. Published abstract pages have the stable sibling /pdf/ URL.
        let pdfURL = article.pageKind == .abstract
            ? apsURL(for: article, pageKind: .pdf)?.absoluteString
            : nil
        return (reference, pdfURL)
    }

    // MARK: - DOI-bearing publisher paths

    private static func resolveDOIPublisher(
        landingURL: URL,
        host: KnownPaperHost,
        crossrefFetcher: @Sendable (String) async throws -> Reference
    ) async throws -> (Reference, String?) {
        guard let article = doiPublisherArticle(from: landingURL, host: host),
              let pdfURL = doiPublisherURL(for: article, pageKind: .pdf) else {
            throw ResolveError.insufficientMetadata
        }

        var reference = try await crossrefFetcher(article.doi)
        // Preserve the publisher page instead of CrossRef's doi.org URL. PDF
        // and ePDF inputs have already been rewritten to the canonical landing.
        reference.url = landingURL.absoluteString
        return (reference, pdfURL.absoluteString)
    }

    // MARK: - Oxford Academic numeric article ID

    private static func resolveOxfordAcademic(
        landingURL: URL,
        session: URLSession,
        doiHint: String?,
        crossrefFetcher: @Sendable (String) async throws -> Reference
    ) async throws -> (Reference, String?) {
        guard let article = oxfordAcademicArticle(from: landingURL) else {
            throw ResolveError.insufficientMetadata
        }

        if article.doi == nil,
           let hinted = try await validatedDOIHint(
            doiHint,
            crossrefFetcher: crossrefFetcher,
            validation: { reference, hint in
                oxfordAcademicReference(reference, matches: article, expectedDOI: hint)
            }
           ) {
            var reference = hinted
            reference.url = landingURL.absoluteString
            return (reference, nil)
        }

        let doi: String
        if let pathDOI = article.doi {
            doi = pathDOI
        } else {
            guard let minimalURL = URL(
                string: "https://oup.silverchair-cdn.com/article-minimal/\(article.resourceID)"
            ) else {
                throw ResolveError.insufficientMetadata
            }
            let response = try await fetchHTML(
                url: minimalURL,
                session: session,
                permittedFinalHosts: ["oup.silverchair-cdn.com"]
            )
            guard let pageDOI = parseOxfordAcademicDOI(response.data) else {
                throw ResolveError.insufficientMetadata
            }
            doi = pageDOI
        }

        var reference = try await crossrefFetcher(doi)
        reference.url = landingURL.absoluteString
        // Oxford's PDF URLs contain a separate, mutable asset ID. Let the
        // normal DOI/OpenAlex download path locate an accessible copy rather
        // than synthesizing a brittle publisher URL.
        return (reference, nil)
    }

    // MARK: - GeoscienceWorld numeric article ID

    private static func resolveGeoscienceWorld(
        landingURL: URL,
        session: URLSession,
        doiHint: String?,
        matchedPublisherPDFURL: String?,
        crossrefFetcher: @Sendable (String) async throws -> Reference
    ) async throws -> (Reference, String?) {
        guard let article = geoscienceWorldArticle(from: landingURL) else {
            throw ResolveError.insufficientMetadata
        }

        let hinted = try await validatedDOIHint(
            doiHint,
            crossrefFetcher: crossrefFetcher,
            validation: { reference, hint in
                geoscienceWorldReference(reference, matches: article, expectedDOI: hint)
            }
        )
        if let hinted, let matchedPublisherPDFURL {
            var reference = hinted
            reference.url = landingURL.absoluteString
            return (reference, matchedPublisherPDFURL)
        }

        let candidate: GeoscienceWorldCrossrefCandidate?
        do {
            candidate = try await fetchGeoscienceWorldCrossrefCandidate(
                for: article,
                expectedDOI: hinted?.doi,
                session: session
            )
        } catch {
            if error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                throw error
            }
            if var reference = hinted {
                reference.url = landingURL.absoluteString
                return (reference, nil)
            }
            throw error
        }
        guard let candidate else {
            if var reference = hinted {
                reference.url = landingURL.absoluteString
                return (reference, nil)
            }
            throw ResolveError.insufficientMetadata
        }

        var reference = if let hinted {
            hinted
        } else {
            try await crossrefFetcher(candidate.doi)
        }
        reference.url = landingURL.absoluteString
        return (reference, candidate.pdfURL)
    }

    private static func validatedDOIHint(
        _ rawHint: String?,
        crossrefFetcher: @Sendable (String) async throws -> Reference,
        validation: @Sendable (Reference, String) -> Bool
    ) async throws -> Reference? {
        guard let hint = rawHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidDOI(hint) else { return nil }
        do {
            let reference = try await crossrefFetcher(hint)
            return validation(reference, hint) ? reference : nil
        } catch let error as MetadataFetcher.FetchError {
            switch error {
            case .httpError(let statusCode)
                where statusCode == 400 || statusCode == 404 || statusCode == 410:
                return nil
            case .invalidURL, .unrecognizedIdentifier, .unsupported:
                return nil
            case .httpError, .parseError:
                throw error
            }
        } catch let error as URLError where error.code == .badURL {
            return nil
        } catch {
            throw error
        }
    }

    private static func oxfordAcademicReference(
        _ reference: Reference,
        matches article: OxfordAcademicArticle,
        expectedDOI: String
    ) -> Bool {
        guard case .assignedIssue(_, let volume, let issue, let firstPage) = article.identity,
              reference.doi?.caseInsensitiveCompare(expectedDOI) == .orderedSame,
              let rawURL = reference.url,
              let url = URL(string: rawURL),
              let indexedArticle = oxfordAcademicArticle(from: url),
              indexedArticle.resourceID == article.resourceID,
              indexedArticle.identity == article.identity,
              reference.volume?.caseInsensitiveCompare(volume) == .orderedSame,
              reference.issue?.caseInsensitiveCompare(issue) == .orderedSame,
              self.firstPage(reference.pages, matches: firstPage) else {
            return false
        }
        return true
    }

    private static func geoscienceWorldReference(
        _ reference: Reference,
        matches article: GeoscienceWorldArticle,
        expectedDOI: String
    ) -> Bool {
        let identity = article.assignedIssueIdentity
        guard reference.doi?.caseInsensitiveCompare(expectedDOI) == .orderedSame,
              let rawURL = reference.url,
              let url = URL(string: rawURL),
              let indexedArticle = geoscienceWorldArticle(from: url),
              indexedArticle.resourceID == article.resourceID,
              indexedArticle.assignedIssueIdentity == identity,
              reference.volume?.caseInsensitiveCompare(identity.volume) == .orderedSame,
              reference.issue?.caseInsensitiveCompare(identity.issue) == .orderedSame,
              firstPage(reference.pages, matches: identity.firstPage) else {
            return false
        }
        return true
    }

    // MARK: - Cell Press PII path

    private static func resolveCellPress(
        landingURL: URL,
        session: URLSession
    ) async throws -> (Reference, String?) {
        guard let article = cellPressArticle(from: landingURL),
              let piiIdentity = cellPressPIIIdentity(article.pii),
              let pdfURL = cellPressURL(for: article, pageKind: .pdf) else {
            throw ResolveError.insufficientMetadata
        }

        // Cell Press article pages are protected by a browser challenge, so a
        // headless citation-meta scrape is not reliable. Prefer the formatted
        // PII's exact PubMed Publisher-ID match. Physical-science Cell Press
        // journals may not be indexed there, so fall back to the title exposed
        // by Elsevier Linking Hub and require a PII-constrained OpenAlex match.
        let resolvedReference: Reference
        do {
            resolvedReference = try await MetadataFetcher.fetchFromPII(
                article.pii,
                session: session
            )
        } catch {
            let pubMedError = error
            if let fetchError = error as? MetadataFetcher.FetchError,
               case .unsupported(let message) = fetchError,
               message.hasPrefix("Multiple PubMed records") {
                throw error
            }
            guard let linkingHubTitle = try? await fetchCellPressLinkingHubTitle(
                pii: article.pii,
                session: session
            ) else {
                throw pubMedError
            }
            do {
                guard let fallback = try await MetadataFetcher.fetchFromOpenAlexByExactTitle(
                    linkingHubTitle,
                    expectedISSN: piiIdentity.issn,
                    assignmentYearSuffix: piiIdentity.assignmentYearSuffix,
                    session: session
                ) else {
                    throw pubMedError
                }
                resolvedReference = fallback
            } catch {
                throw pubMedError
            }
        }

        // The normal resolver flow will use the DOI, when present, for the same
        // Crossref normalization applied to other publisher sources.
        var reference = resolvedReference
        reference.url = landingURL.absoluteString
        return (reference, pdfURL.absoluteString)
    }

    private static func fetchCellPressLinkingHubTitle(
        pii: String,
        session: URLSession
    ) async throws -> String {
        guard let url = cellPressLinkingHubURL(forPII: pii) else {
            throw ResolveError.insufficientMetadata
        }
        let response = try await fetchHTML(
            url: url,
            session: session,
            permittedFinalHosts: ["linkinghub.elsevier.com"]
        )
        guard let title = parseCellPressLinkingHubTitle(response.data) else {
            throw ResolveError.insufficientMetadata
        }
        return title
    }

    // MARK: - Citation-meta dispatch

    private static func resolveCitationMeta(
        landingURL: URL,
        host: KnownPaperHost,
        session: URLSession
    ) async throws -> (Reference, String?) {
        let meta = try await CitationMetaScraper.fetch(landingURL, session: session)

        // Strong evidence gate: require citation_title + at least 1 other.
        guard let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw ResolveError.insufficientMetadata
        }
        let hasOtherEvidence = !meta.authors.isEmpty
            || (meta.doi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || meta.year != nil
            || (meta.journal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (meta.conferenceTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        guard hasOtherEvidence else {
            throw ResolveError.insufficientMetadata
        }

        let referenceType: ReferenceType = {
            switch host {
            case .cvfOpenAccess, .neurIPS, .neurIPSProceedings, .pmlr:
                return .conferencePaper
            case .openReview:
                return .conferencePaper
            case .aclAnthology:
                return meta.conferenceTitle != nil ? .conferencePaper : .journalArticle
            case .ieeeXplore, .acmDL, .nature, .springer, .scienceDirect, .cellPress,
                 .science, .acs, .aanda, .oxfordAcademic, .geoscienceWorld,
                 .eLife, .eNeuro, .aps:
                if meta.journal != nil { return .journalArticle }
                if meta.conferenceTitle != nil { return .conferencePaper }
                return .journalArticle
            }
        }()

        let pages: String? = {
            if let first = meta.firstPage, let last = meta.lastPage { return "\(first)-\(last)" }
            return meta.firstPage
        }()

        // CVF Open Access papers are labeled with their own source so the UI
        // can distinguish them from generic publisher pages. Every other host
        // labels as .publisherCitationMeta.
        let metadataSource: MetadataSource = (host == .cvfOpenAccess)
            ? .cvfOpenAccess
            : .publisherCitationMeta

        let ref = Reference(
            title: title,
            authors: meta.authors,
            year: meta.year,
            journal: meta.journal ?? meta.conferenceTitle,
            volume: meta.volume,
            issue: meta.issue,
            pages: pages,
            doi: meta.doi,
            url: landingURL.absoluteString,
            abstract: meta.abstract,
            referenceType: referenceType,
            metadataSource: metadataSource,
            publisher: meta.publisher,
            isbn: meta.isbn,
            issn: meta.issn,
            eventTitle: (referenceType == .conferencePaper) ? meta.conferenceTitle : nil
        )
        return (ref, meta.pdfURL)
    }

    // MARK: - eLife official article API

    private static func resolveELife(
        landingURL: URL,
        session: URLSession
    ) async throws -> (Reference, String?) {
        guard let articleID = eLifeArticleID(from: landingURL),
              let apiURL = URL(string: "https://api.elifesciences.org/articles/\(articleID)") else {
            throw ResolveError.insufficientMetadata
        }

        let data = try await withRetry(maxAttempts: 3) {
            var request = URLRequest(url: apiURL)
            request.setValue(MetadataFetcher.userAgent, forHTTPHeaderField: "User-Agent")
            // eLife negotiates versioned vendor media types and rejects a
            // generic `application/json` Accept header with HTTP 406. Leaving
            // Accept unset selects the current public representation.
            request.timeoutInterval = 15

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ResolveError.fetchFailed(statusCode: 0, host: apiURL.host ?? "")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ResolveError.fetchFailed(
                    statusCode: httpResponse.statusCode,
                    host: apiURL.host ?? ""
                )
            }

            let finalHost = (httpResponse.url ?? apiURL).host?.lowercased() ?? ""
            guard finalHost == "api.elifesciences.org" else {
                throw ResolveError.redirectedAwayFromAllowlist(finalHost: finalHost)
            }

            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            let mediaType = contentType
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isJSON = mediaType == "application/json"
                || (mediaType.hasPrefix("application/") && mediaType.hasSuffix("+json"))
            guard isJSON else {
                throw ResolveError.unexpectedContentType(contentType)
            }
            return data
        }

        return try parseELifeArticle(
            data,
            expectedArticleID: articleID,
            landingURL: landingURL
        )
    }

    private static func parseELifeArticle(
        _ data: Data,
        expectedArticleID: String,
        landingURL: URL
    ) throws -> (Reference, String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseID = json["id"] as? String,
              responseID == expectedArticleID,
              let rawTitle = json["title"] as? String else {
            throw ResolveError.insufficientMetadata
        }

        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ResolveError.insufficientMetadata }

        let authors = parseELifeAuthors(json["authors"])
        let published = (json["published"] as? String) ?? (json["versionDate"] as? String)
        let year = published.flatMap { MetadataResolution.extractYear(fromMetadataText: $0) }

        let volume: String? = {
            if let value = json["volume"] as? String { return value }
            if let value = json["volume"] as? NSNumber { return value.stringValue }
            return nil
        }()

        let abstract = plainTextFromELifeContent(json["abstract"])
        let pdfURL: String? = {
            guard let raw = json["pdf"] as? String,
                  let url = URL(string: raw),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  host == "cdn.elifesciences.org" || host == "elifesciences.org" else { return nil }
            return url.absoluteString
        }()

        let reference = Reference(
            title: title,
            authors: authors,
            year: year,
            journal: "eLife",
            volume: volume,
            pages: json["elocationId"] as? String,
            doi: (json["doi"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            url: landingURL.absoluteString,
            abstract: abstract,
            referenceType: .journalArticle,
            metadataSource: .publisherCitationMeta,
            publisher: "eLife Sciences Publications, Ltd"
        )
        return (reference, pdfURL)
    }

    private static func parseELifeAuthors(_ value: Any?) -> [AuthorName] {
        guard let rawAuthors = value as? [[String: Any]] else { return [] }
        return rawAuthors.compactMap { author in
            if let groupName = author["name"] as? String {
                let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : AuthorName(given: "", family: trimmed)
            }
            if let groupNames = author["name"] as? [String] {
                let joined = groupNames
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                return joined.isEmpty ? nil : AuthorName(given: "", family: joined)
            }
            if let personName = author["name"] as? [String: Any] {
                if let indexName = personName["index"] as? String,
                   !indexName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return AuthorName.parse(indexName)
                }
                if let preferredName = personName["preferred"] as? String,
                   !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return AuthorName.parse(preferredName)
                }
            }
            return nil
        }
    }

    private static func plainTextFromELifeContent(_ value: Any?) -> String? {
        let fragments = eLifeTextFragments(value).compactMap { raw -> String? in
            let withoutTags = raw.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            let decoded = CitationMetaScraper.decodeHTMLEntities(withoutTags)
                .replacingOccurrences(of: "&nbsp;", with: " ")
            let normalized = decoded
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return normalized.isEmpty ? nil : normalized
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
    }

    private static func eLifeTextFragments(_ value: Any?) -> [String] {
        if let object = value as? [String: Any] {
            var fragments: [String] = []
            if let text = object["text"] as? String { fragments.append(text) }
            if let content = object["content"] { fragments.append(contentsOf: eLifeTextFragments(content)) }
            return fragments
        }
        if let array = value as? [Any] {
            return array.flatMap { eLifeTextFragments($0) }
        }
        return []
    }
}

// MARK: - KnownPaperHost (internal)

internal enum KnownPaperHost: CaseIterable {
    case openReview, aclAnthology, cvfOpenAccess
    case neurIPS, neurIPSProceedings
    case pmlr, ieeeXplore, acmDL, nature, springer, scienceDirect, cellPress
    case science, acs, aanda, oxfordAcademic, geoscienceWorld, eLife, eNeuro, aps

    /// Returns the host bucket if the URL matches both a known host and a
    /// known path shape (landing OR PDF). Returns nil otherwise — callers
    /// fall through to existing identifier extraction.
    static func classify(_ url: URL) -> KnownPaperHost? {
        guard let canonical = PaperURLResolver.canonicalize(url) else { return nil }
        guard let host = canonical.host else { return nil }
        let path = canonical.path
        let query = canonical.query

        switch host {
        case "openreview.net":
            // Requires ?id=... in query.
            guard query?.contains("id=") == true else { return nil }
            if path == "/forum" || path == "/pdf" { return .openReview }
            return nil
        case "aclanthology.org":
            // ACL Anthology paper IDs have the form <year>.<track>-<venue>.<num>
            // (e.g. acl-long, naacl-short, findings-emnlp). Accept either ordering
            // since both "acl-long" and "findings-emnlp" appear in the wild.
            if matches(path, pattern: #"^/\d{4}\.[a-z]+-[a-z]+\.\d+/?$"#) { return .aclAnthology }
            if matches(path, pattern: #"^/\d{4}\.[a-z]+-[a-z]+\.\d+\.pdf$"#) { return .aclAnthology }
            return nil
        case "openaccess.thecvf.com":
            if matches(path, pattern: #"^/content/[^/]+/html/.+\.html$"#) { return .cvfOpenAccess }
            if matches(path, pattern: #"^/content/[^/]+/papers/.+\.pdf$"#) { return .cvfOpenAccess }
            return nil
        case "papers.nips.cc":
            if matches(path, pattern: #"^/paper/\d+/hash/.+\.html$"#) { return .neurIPS }
            if matches(path, pattern: #"^/paper/\d+/file/.+\.pdf$"#) { return .neurIPS }
            return nil
        case "proceedings.neurips.cc":
            if matches(path, pattern: #"^/paper_files/paper/\d+/hash/.+\.html$"#) { return .neurIPSProceedings }
            if matches(path, pattern: #"^/paper_files/paper/\d+/file/.+\.pdf$"#) { return .neurIPSProceedings }
            return nil
        case "proceedings.mlr.press":
            if matches(path, pattern: #"^/v\d+/[^/]+\.html$"#) { return .pmlr }
            if matches(path, pattern: #"^/v\d+/[^/]+/[^/]+\.pdf$"#) { return .pmlr }
            return nil
        case "ieeexplore.ieee.org":
            if matches(path, pattern: #"^/(document|abstract/document)/\d+/?$"#) { return .ieeeXplore }
            if matches(path, pattern: #"^/stamp/stamp\.jsp$"#) { return .ieeeXplore }
            return nil
        case "dl.acm.org":
            if matches(path, pattern: #"^/doi/(abs/)?10\.\d+/.+$"#) { return .acmDL }
            if matches(path, pattern: #"^/doi/pdf/10\.\d+/.+$"#) { return .acmDL }
            return nil
        case "nature.com":
            if matches(path, pattern: #"^/articles/.+\.pdf$"#) { return .nature }
            if matches(path, pattern: #"^/articles/.+$"#) { return .nature }
            return nil
        case "link.springer.com":
            // Landing only — no PDF rewrite for Springer (see spec §2.3.B).
            if matches(path, pattern: #"^/(article|chapter|book|referenceworkentry)/.+$"#) { return .springer }
            return nil
        case "sciencedirect.com":
            if matches(path, pattern: #"^/science/article/.+/pdfft$"#) { return .scienceDirect }
            if matches(path, pattern: #"^/science/article/(pii|abs/pii)/.+$"#) { return .scienceDirect }
            return nil
        case "cell.com":
            return PaperURLResolver.cellPressArticle(from: canonical) == nil ? nil : .cellPress
        case "science.org":
            return PaperURLResolver.doiPublisherArticle(from: canonical, host: .science) == nil
                ? nil
                : .science
        case "pubs.acs.org":
            return PaperURLResolver.doiPublisherArticle(from: canonical, host: .acs) == nil
                ? nil
                : .acs
        case "aanda.org":
            return PaperURLResolver.aandaArticle(from: canonical) == nil ? nil : .aanda
        case "academic.oup.com":
            return PaperURLResolver.oxfordAcademicArticle(from: canonical) == nil
                ? nil
                : .oxfordAcademic
        case "pubs.geoscienceworld.org":
            return PaperURLResolver.geoscienceWorldArticle(from: canonical) == nil
                ? nil
                : .geoscienceWorld
        case "elifesciences.org":
            if PaperURLResolver.eLifeArticleID(from: canonical) != nil { return .eLife }
            return nil
        case "eneuro.org":
            // HighWire article pages are either assigned to an issue or in
            // early release. PDF links insert the site code after /content.
            // Requiring eNeuro's article-ID shape excludes section listings.
            let articleID = #"(?i:ENEURO\.[0-9]{4}-[0-9]{2}\.[0-9]{4})"#
            let variant = #"(?:\.(?:abstract|full|long)|\.full\.pdf)?"#
            let assignedIssue = #"^/content/(?:eneuro/)?[^/]+/[^/]+/\#(articleID)\#(variant)/?$"#
            let earlyRelease = #"^/content/(?:eneuro/)?early/[0-9]{4}/[0-9]{2}/[0-9]{2}/\#(articleID)\#(variant)/?$"#
            if matches(path, pattern: assignedIssue) || matches(path, pattern: earlyRelease) {
                return .eNeuro
            }
            return nil
        case "journals.aps.org":
            return PaperURLResolver.apsArticle(from: canonical) == nil ? nil : .aps
        default:
            return nil
        }
    }

    private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 64
        return cache
    }()

    private static func matches(_ string: String, pattern: String) -> Bool {
        let regex: NSRegularExpression
        if let cached = regexCache.object(forKey: pattern as NSString) {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return false }
            regexCache.setObject(compiled, forKey: pattern as NSString)
            regex = compiled
        }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}

// MARK: - URL canonicalization

internal extension PaperURLResolver {
    enum DOIPublisherPageKind: Sendable {
        case canonical, full, abstract, pdf, epdf
    }

    struct DOIPublisherArticle: Sendable {
        let host: KnownPaperHost
        let pageKind: DOIPublisherPageKind
        let doi: String
    }

    enum AANDAPageKind: Sendable {
        case fullHTML, abstract, pdf
    }

    struct AANDAArticle: Sendable {
        let pageKind: AANDAPageKind
        let year: String
        let issue: String
        let articleID: String
    }

    enum OxfordAcademicArticleIdentity: Sendable, Equatable {
        case assignedIssue(
            journalSlug: String,
            volume: String,
            issue: String,
            firstPage: String
        )
        case doi(journalSlug: String, doi: String)
    }

    struct OxfordAcademicArticle: Sendable {
        let resourceID: String
        let doi: String?
        let identity: OxfordAcademicArticleIdentity
    }

    struct GeoscienceWorldAssignedIssueIdentity: Sendable, Equatable {
        let journalSlug: String
        let volume: String
        let issue: String
        let firstPage: String
    }

    struct GeoscienceWorldArticle: Sendable {
        let assignedIssueIdentity: GeoscienceWorldAssignedIssueIdentity
        let resourceID: String
        let titleQuery: String
    }

    struct GeoscienceWorldCrossrefCandidate: Sendable {
        let doi: String
        let pdfURL: String?
    }

    private static func isOxfordAcademicHost(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host == "academic.oup.com"
    }

    private static func isGeoscienceWorldHost(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host == "pubs.geoscienceworld.org"
    }

    enum APSPageKind: String, Sendable {
        case abstract, accepted, pdf
    }

    struct APSArticle: Sendable {
        let journalSlug: String
        let pageKind: APSPageKind
        let doi: String
    }

    enum CellPressPageKind: String, Sendable {
        case fulltext, abstract, pdf
    }

    struct CellPressArticle: Sendable {
        let journalPath: String
        let pii: String
    }

    static func canonicalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Validate scheme. Reject if not http or https.
        guard let rawScheme = components.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https" else { return nil }

        // Reject embedded credentials.
        if components.user != nil || components.password != nil { return nil }

        // Lowercase host, strip www. for matching.
        guard let rawHost = components.host?.lowercased() else { return nil }
        let strippedHost = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        components.host = strippedHost

        // Upgrade http -> https. Per spec §2.4: "If both work for a publisher,
        // store as https." All target hosts support https; this also covers
        // default-port stripping in one move (an http://...:80 becomes https://...).
        components.scheme = "https"

        // Strip default ports (80 and 443).
        if components.port == 80 || components.port == 443 {
            components.port = nil
        }

        // Strip fragment.
        components.fragment = nil

        return components.url
    }

    /// Parse current Oxford Academic journal URLs. Issue-assigned article
    /// pages carry only a numeric Silverchair resource ID; advance/article
    /// DOI routes also expose the DOI directly in the path.
    static func oxfordAcademicArticle(from url: URL) -> OxfordAcademicArticle? {
        guard let canonical = canonicalize(url),
              canonical.host == "academic.oup.com" else { return nil }

        var path = canonical.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
        guard !segments.contains(where: \.isEmpty),
              let journalSlug = segments.first,
              isSafePublisherSlug(journalSlug, allowsUnderscore: false),
              let resourceID = segments.last,
              isNumericPublisherID(resourceID) else { return nil }

        let issueRoutes = ["article", "article-abstract"]
        let doiRoutes = issueRoutes + ["advance-article", "advance-article-abstract"]
        if segments.count >= 6,
           doiRoutes.contains(segments[1]),
           segments[2] == "doi" {
            let doi = segments[3..<(segments.count - 1)].joined(separator: "/")
            guard isValidDOI(doi) else { return nil }
            return OxfordAcademicArticle(
                resourceID: resourceID,
                doi: doi,
                identity: .doi(
                    journalSlug: journalSlug.lowercased(),
                    doi: doi.lowercased()
                )
            )
        }

        if segments.count == 6,
           issueRoutes.contains(segments[1]) {
            return OxfordAcademicArticle(
                resourceID: resourceID,
                doi: nil,
                identity: .assignedIssue(
                    journalSlug: journalSlug.lowercased(),
                    volume: segments[2].lowercased(),
                    issue: segments[3].lowercased(),
                    firstPage: segments[4].lowercased()
                )
            )
        }
        return nil
    }

    /// Parse Oxford's publisher-PDF routes without classifying them as paper
    /// landing pages. Keeping these URLs out of `KnownPaperHost` preserves the
    /// direct-file import path when a user opens or pastes the PDF itself.
    static func oxfordAcademicPDFIdentity(
        from url: URL
    ) -> OxfordAcademicArticleIdentity? {
        guard let canonical = canonicalize(url),
              canonical.host == "academic.oup.com" else { return nil }

        var path = canonical.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
        guard !segments.contains(where: \.isEmpty),
              let journalSlug = segments.first,
              isSafePublisherSlug(journalSlug, allowsUnderscore: false),
              let filename = segments.last,
              filename.lowercased().hasSuffix(".pdf"),
              segments.count >= 2,
              isNumericPublisherID(segments[segments.count - 2]) else { return nil }

        let doiRoutes = ["article-pdf", "advance-article-pdf"]
        if segments.count >= 7,
           doiRoutes.contains(segments[1]),
           segments[2] == "doi" {
            let doi = segments[3..<(segments.count - 2)].joined(separator: "/")
            guard isValidDOI(doi) else { return nil }
            return .doi(
                journalSlug: journalSlug.lowercased(),
                doi: doi.lowercased()
            )
        }

        if segments.count == 7,
           segments[1] == "article-pdf" {
            return .assignedIssue(
                journalSlug: journalSlug.lowercased(),
                volume: segments[2].lowercased(),
                issue: segments[3].lowercased(),
                firstPage: segments[4].lowercased()
            )
        }
        return nil
    }

    /// Parse GeoscienceWorld landing pages. Current URLs optionally carry a
    /// society prefix before the journal slug; Crossref's primary URLs often
    /// omit it, so identity starts at the journal immediately before the
    /// article route.
    static func geoscienceWorldArticle(from url: URL) -> GeoscienceWorldArticle? {
        guard let canonical = canonicalize(url),
              canonical.host == "pubs.geoscienceworld.org" else { return nil }
        var path = canonical.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return nil }
        let segments = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
        guard !segments.contains(where: \.isEmpty),
              let routeIndex = segments.firstIndex(where: {
            $0 == "article" || $0 == "article-abstract"
        }),
              routeIndex == 1 || routeIndex == 2,
              segments.count == routeIndex + 6 else { return nil }

        let journalSlug = segments[routeIndex - 1]
        let volume = segments[routeIndex + 1]
        let issue = segments[routeIndex + 2]
        let firstPage = segments[routeIndex + 3]
        let resourceID = segments[routeIndex + 4]
        let titleSlug = segments[routeIndex + 5]
        guard (routeIndex == 1 || isSafePublisherSlug(segments[0])),
              isSafePublisherSlug(journalSlug),
              !volume.isEmpty,
              !issue.isEmpty,
              !firstPage.isEmpty,
              isNumericPublisherID(resourceID),
              isSafePublisherSlug(titleSlug) else { return nil }

        let titleQuery = titleSlug
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return GeoscienceWorldArticle(
            assignedIssueIdentity: GeoscienceWorldAssignedIssueIdentity(
                journalSlug: journalSlug.lowercased(),
                volume: volume.lowercased(),
                issue: issue.lowercased(),
                firstPage: firstPage.lowercased()
            ),
            resourceID: resourceID,
            titleQuery: titleQuery
        )
    }

    /// Parse direct GeoscienceWorld PDF URLs without classifying them as paper
    /// landings. Direct PDF pastes therefore keep the existing remote-file
    /// import behavior, while the browser extension can safely associate a
    /// page's citation PDF with its active article.
    static func geoscienceWorldPDFIdentity(
        from url: URL
    ) -> GeoscienceWorldAssignedIssueIdentity? {
        guard let canonical = canonicalize(url),
              canonical.host == "pubs.geoscienceworld.org" else { return nil }
        var path = canonical.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return nil }
        let segments = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
        guard !segments.contains(where: \.isEmpty),
              let routeIndex = segments.firstIndex(of: "article-pdf"),
              routeIndex == 1 || routeIndex == 2,
              segments.count == routeIndex + 6 else { return nil }

        let journalSlug = segments[routeIndex - 1]
        let volume = segments[routeIndex + 1]
        let issue = segments[routeIndex + 2]
        let firstPage = segments[routeIndex + 3]
        let assetID = segments[routeIndex + 4]
        let filename = segments[routeIndex + 5]
        guard (routeIndex == 1 || isSafePublisherSlug(segments[0])),
              isSafePublisherSlug(journalSlug),
              !volume.isEmpty,
              !issue.isEmpty,
              !firstPage.isEmpty,
              isNumericPublisherID(assetID),
              filename.lowercased().hasSuffix(".pdf") else { return nil }
        return GeoscienceWorldAssignedIssueIdentity(
            journalSlug: journalSlug.lowercased(),
            volume: volume.lowercased(),
            issue: issue.lowercased(),
            firstPage: firstPage.lowercased()
        )
    }

    private static func isSafePublisherSlug(
        _ value: String,
        allowsUnderscore: Bool = true
    ) -> Bool {
        let scalars = value.unicodeScalars
        guard let first = scalars.first, isASCIIAlphaNumeric(first) else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar)
                || scalar == "-"
                || (allowsUnderscore && scalar == "_")
        }
    }

    private static func isNumericPublisherID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    static func geoscienceWorldCrossrefSearchURL(
        for article: GeoscienceWorldArticle
    ) -> URL? {
        let identity = article.assignedIssueIdentity
        let bibliographicQuery = [
            article.titleQuery,
            identity.journalSlug,
            identity.volume,
            identity.issue,
            identity.firstPage,
            article.resourceID,
        ].joined(separator: " ")
        var components = URLComponents(string: "https://api.crossref.org/works")
        components?.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: bibliographicQuery),
            URLQueryItem(name: "filter", value: "type:journal-article"),
            URLQueryItem(name: "rows", value: "20"),
            URLQueryItem(
                name: "select",
                value: "DOI,volume,issue,page,resource,link"
            ),
        ]
        return components?.url
    }

    private static func fetchGeoscienceWorldCrossrefCandidate(
        for article: GeoscienceWorldArticle,
        expectedDOI: String? = nil,
        session: URLSession
    ) async throws -> GeoscienceWorldCrossrefCandidate? {
        guard let url = geoscienceWorldCrossrefSearchURL(for: article) else {
            throw ResolveError.insufficientMetadata
        }

        let data = try await withRetry(maxAttempts: 3) {
            var request = URLRequest(url: url)
            request.setValue(MetadataFetcher.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ResolveError.fetchFailed(statusCode: 0, host: url.host ?? "")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ResolveError.fetchFailed(
                    statusCode: httpResponse.statusCode,
                    host: url.host ?? ""
                )
            }
            let finalHost = (httpResponse.url ?? url).host?.lowercased() ?? ""
            guard finalHost == "api.crossref.org" else {
                throw ResolveError.redirectedAwayFromAllowlist(finalHost: finalHost)
            }
            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            guard contentType.isEmpty || contentType.hasPrefix("application/json") else {
                throw ResolveError.unexpectedContentType(contentType)
            }
            return data
        }

        return parseGeoscienceWorldCrossrefCandidate(
            data,
            expectedArticle: article,
            expectedDOI: expectedDOI
        )
    }

    static func parseGeoscienceWorldCrossrefCandidate(
        _ data: Data,
        expectedArticle: GeoscienceWorldArticle,
        expectedDOI: String? = nil
    ) -> GeoscienceWorldCrossrefCandidate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else { return nil }

        var matchesByDOI: [String: GeoscienceWorldCrossrefCandidate] = [:]
        for item in items {
            guard let rawDOI = item["DOI"] as? String else { continue }
            let doi = rawDOI.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesExpectedDOI = expectedDOI.map {
                doi.caseInsensitiveCompare($0) == .orderedSame
            } ?? true
            guard isValidDOI(doi),
                  matchesExpectedDOI,
                  let resource = item["resource"] as? [String: Any],
                  let primary = resource["primary"] as? [String: Any],
                  let primaryURLString = primary["URL"] as? String,
                  let primaryURL = URL(string: primaryURLString),
                  let indexedArticle = geoscienceWorldArticle(from: primaryURL),
                  indexedArticle.resourceID == expectedArticle.resourceID,
                  indexedArticle.assignedIssueIdentity == expectedArticle.assignedIssueIdentity,
                  field(item["volume"], matches: expectedArticle.assignedIssueIdentity.volume),
                  field(item["issue"], matches: expectedArticle.assignedIssueIdentity.issue),
                  firstPage(item["page"], matches: expectedArticle.assignedIssueIdentity.firstPage)
            else { continue }

            let pdfURL = geoscienceWorldPDFURL(
                from: item["link"],
                matching: expectedArticle.assignedIssueIdentity
            )
            matchesByDOI[doi.lowercased()] = GeoscienceWorldCrossrefCandidate(
                doi: doi,
                pdfURL: pdfURL
            )
        }

        guard matchesByDOI.count == 1 else { return nil }
        return matchesByDOI.values.first
    }

    private static func field(_ value: Any?, matches expected: String) -> Bool {
        guard let value = value as? String else { return false }
        return value.lowercased() == expected.lowercased()
    }

    private static func firstPage(_ value: Any?, matches expected: String) -> Bool {
        guard let pages = value as? String else { return false }
        let first = pages.split(
            whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" }
        ).first.map(String.init) ?? pages
        return first.lowercased() == expected.lowercased()
    }

    private static func geoscienceWorldPDFURL(
        from value: Any?,
        matching expectedIdentity: GeoscienceWorldAssignedIssueIdentity
    ) -> String? {
        guard let links = value as? [[String: Any]] else { return nil }
        for link in links {
            guard (link["content-type"] as? String)?.lowercased() == "application/pdf",
                  let rawURL = link["URL"] as? String,
                  let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "https",
                  geoscienceWorldPDFIdentity(from: url) == expectedIdentity else { continue }
            return url.absoluteString
        }
        return nil
    }

    private static let oxfordAcademicPrimaryCitationRegex = try! NSRegularExpression(
        pattern: #"<div\b[^>]*\bclass\s*=\s*[\"'][^\"']*\bww-citation-primary\b[^\"']*[\"'][^>]*>(.*?)</div>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let oxfordAcademicDOIRegex = try! NSRegularExpression(
        pattern: #"https?://doi\.org/(10\.[0-9]{4,9}/[^\s<>\"']+)"#,
        options: [.caseInsensitive]
    )

    private static let fullDOIRegex = try! NSRegularExpression(
        pattern: #"^10\.[0-9]{4,9}/\S+$"#,
        options: [.caseInsensitive]
    )

    private static func isValidDOI(_ doi: String) -> Bool {
        let range = NSRange(doi.startIndex..., in: doi)
        return fullDOIRegex.firstMatch(
            in: doi,
            options: [],
            range: range
        ) != nil
    }

    /// The Silverchair minimal page does not expose citation_* tags, but its
    /// primary citation links the authoritative OUP DOI before article-body
    /// references. Take the DOI from that block and let Crossref provide
    /// metadata. The prefix is intentionally not fixed to 10.1093 because
    /// Oxford hosts journal archives containing legacy publisher DOIs.
    static func parseOxfordAcademicDOI(_ data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let htmlRange = NSRange(html.startIndex..., in: html)
        guard let citationMatch = oxfordAcademicPrimaryCitationRegex.firstMatch(
            in: html,
            options: [],
            range: htmlRange
        ),
        let citationRange = Range(citationMatch.range(at: 1), in: html) else { return nil }
        let citation = String(html[citationRange])
        let citationNSRange = NSRange(citation.startIndex..., in: citation)
        guard let doiMatch = oxfordAcademicDOIRegex.firstMatch(
            in: citation,
            options: [],
            range: citationNSRange
        ),
        let doiRange = Range(doiMatch.range(at: 1), in: citation) else { return nil }
        let encoded = String(citation[doiRange])
        let decoded = encoded.removingPercentEncoding ?? encoded
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
    }

    /// Parse Science and ACS article paths. Both publishers use one DOI suffix
    /// path component and expose canonical, full, abstract, PDF, and ePDF forms.
    static func doiPublisherArticle(
        from url: URL,
        host: KnownPaperHost
    ) -> DOIPublisherArticle? {
        let expectedHost: String
        let registrant: String
        switch host {
        case .science:
            expectedHost = "science.org"
            registrant = "10.1126"
        case .acs:
            expectedHost = "pubs.acs.org"
            registrant = "10.1021"
        default:
            return nil
        }

        guard let canonical = canonicalize(url),
              canonical.host == expectedHost else { return nil }
        var path = canonical.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        if path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)

        let pageKind: DOIPublisherPageKind
        let doiRegistrant: String
        let suffix: String
        if segments.count == 3, segments[0] == "doi" {
            pageKind = .canonical
            doiRegistrant = segments[1]
            suffix = segments[2]
        } else if segments.count == 4, segments[0] == "doi" {
            switch segments[1] {
            case "full": pageKind = .full
            case "abs": pageKind = .abstract
            case "pdf": pageKind = .pdf
            case "epdf": pageKind = .epdf
            default: return nil
            }
            doiRegistrant = segments[2]
            suffix = segments[3]
        } else {
            return nil
        }

        guard doiRegistrant == registrant,
              !suffix.isEmpty,
              suffix != ".",
              suffix != ".." else { return nil }
        return DOIPublisherArticle(
            host: host,
            pageKind: pageKind,
            doi: "\(registrant)/\(suffix)"
        )
    }

    static func doiPublisherPath(
        for article: DOIPublisherArticle,
        pageKind: DOIPublisherPageKind
    ) -> String {
        switch pageKind {
        case .canonical: return "/doi/\(article.doi)"
        case .full: return "/doi/full/\(article.doi)"
        case .abstract: return "/doi/abs/\(article.doi)"
        case .pdf: return "/doi/pdf/\(article.doi)"
        case .epdf: return "/doi/epdf/\(article.doi)"
        }
    }

    static func doiPublisherURL(
        for article: DOIPublisherArticle,
        pageKind: DOIPublisherPageKind
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = article.host == .science ? "www.science.org" : "pubs.acs.org"
        components.path = doiPublisherPath(for: article, pageKind: pageKind)
        if article.host == .science, case .pdf = pageKind {
            components.queryItems = [URLQueryItem(name: "download", value: "true")]
        }
        return components.url
    }

    /// Parse Astronomy & Astrophysics full HTML, abstract, and PDF paths.
    /// HTML paths duplicate the article ID as a directory and filename, while
    /// PDF paths place `<article-id>.pdf` directly under the issue directory.
    static func aandaArticle(from url: URL) -> AANDAArticle? {
        guard let canonical = canonicalize(url),
              canonical.host == "aanda.org" else { return nil }
        var path = canonical.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        if path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
        guard segments.count >= 6,
              segments[0] == "articles",
              segments[1] == "aa" else { return nil }

        let pageKind: AANDAPageKind
        let year: String
        let issue: String
        let articleID: String
        switch segments[2] {
        case "full_html", "abs":
            guard segments.count == 7,
                  segments[6] == "\(segments[5]).html" else { return nil }
            pageKind = segments[2] == "full_html" ? .fullHTML : .abstract
            year = segments[3]
            issue = segments[4]
            articleID = segments[5]
        case "pdf":
            guard segments.count == 6, segments[5].hasSuffix(".pdf") else { return nil }
            pageKind = .pdf
            year = segments[3]
            issue = segments[4]
            articleID = String(segments[5].dropLast(4))
        default:
            return nil
        }

        let isASCIIDigit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
        guard year.count == 4, year.allSatisfy(isASCIIDigit),
              issue.count == 2, issue.allSatisfy(isASCIIDigit),
              articleID.hasPrefix("aa"), articleID.count > 2,
              articleID.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        else { return nil }
        return AANDAArticle(
            pageKind: pageKind,
            year: year,
            issue: issue,
            articleID: articleID
        )
    }

    static func aandaPath(for article: AANDAArticle, pageKind: AANDAPageKind) -> String {
        switch pageKind {
        case .fullHTML:
            return "/articles/aa/full_html/\(article.year)/\(article.issue)/\(article.articleID)/\(article.articleID).html"
        case .abstract:
            return "/articles/aa/abs/\(article.year)/\(article.issue)/\(article.articleID)/\(article.articleID).html"
        case .pdf:
            return "/articles/aa/pdf/\(article.year)/\(article.issue)/\(article.articleID).pdf"
        }
    }

    /// Parse APS Physical Review article URLs such as
    /// `/prl/abstract/10.1103/3v91-5pzf`. APS DOI suffixes are one path
    /// component in both the legacy (`PhysRevLett.133.030001`) and current
    /// opaque-ID formats (`3v91-5pzf`).
    static func apsArticle(from url: URL) -> APSArticle? {
        guard let canonical = canonicalize(url),
              canonical.host == "journals.aps.org" else { return nil }

        // Split preserving empty components so doubled slashes
        // (`/prl//abstract/...`) are rejected rather than collapsed —
        // the abstract/accepted landing URL is persisted verbatim on the
        // Reference. A single trailing slash is tolerated (common paste
        // artifact). `path(percentEncoded: false)` rather than the deprecated
        // `path`, which silently strips trailing slashes on Darwin.
        var path = canonical.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        if path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()  // leading root slash yields an empty first component
            .map(String.init)
        guard segments.count == 4,
              !segments[0].isEmpty,
              segments[0].allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
              let pageKind = APSPageKind(rawValue: segments[1]),
              segments[2] == "10.1103",
              !segments[3].isEmpty,
              segments[3] != ".",
              segments[3] != ".." else { return nil }

        return APSArticle(
            journalSlug: segments[0],
            pageKind: pageKind,
            doi: "10.1103/\(segments[3])"
        )
    }

    /// Single source of the APS path template `/<journal>/<kind>/10.1103/<suffix>`,
    /// shared by `apsURL(for:pageKind:)` and the PDF → landing rewrite.
    static func apsPath(for article: APSArticle, pageKind: APSPageKind) -> String {
        "/\(article.journalSlug)/\(pageKind.rawValue)/\(article.doi)"
    }

    static func apsURL(for article: APSArticle, pageKind: APSPageKind) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "journals.aps.org"
        components.path = apsPath(for: article, pageKind: pageKind)
        return components.url
    }

    static func eLifeArticleID(from url: URL) -> String? {
        guard let canonical = canonicalize(url),
              canonical.host == "elifesciences.org" else { return nil }
        let segments = canonical.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 2, segments[0] == "articles" else { return nil }

        var articleID = String(segments[1])
        if articleID.hasSuffix(".pdf") { articleID.removeLast(4) }
        guard !articleID.isEmpty, articleID.allSatisfy(\.isNumber) else { return nil }
        return articleID
    }

    /// Parse Cell Press article URLs such as
    /// `/neuron/fulltext/S0896-6273(26)00414-9` and their abstract/PDF forms.
    static func cellPressArticle(from url: URL) -> CellPressArticle? {
        guard let canonical = canonicalize(url),
              canonical.host == "cell.com" else { return nil }
        var path = canonical.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        if path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
        guard segments.count >= 3 else { return nil }
        let pageKindIndex = segments.index(segments.endIndex, offsetBy: -2)
        let journalSegments = segments[..<pageKindIndex]
        guard !journalSegments.isEmpty,
              journalSegments.allSatisfy({ segment in
                  !segment.isEmpty && segment.allSatisfy({
                      $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-")
                  })
              }),
              let pageKind = CellPressPageKind(rawValue: segments[pageKindIndex]) else { return nil }

        var pii = segments[segments.index(after: pageKindIndex)]
        if pageKind == .pdf {
            guard pii.lowercased().hasSuffix(".pdf") else { return nil }
            pii.removeLast(4)
        }
        guard pii.range(
            of: #"^S[0-9]{4}-[0-9]{3}[0-9X]\([0-9]{2}\)[0-9]{5}-[0-9X]$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return CellPressArticle(journalPath: journalSegments.joined(separator: "/"), pii: pii)
    }

    private static func cellPressPIIIdentity(
        _ pii: String
    ) -> (issn: String, assignmentYearSuffix: Int)? {
        guard pii.count >= 13 else { return nil }
        let issnStart = pii.index(after: pii.startIndex)
        let issnEnd = pii.index(issnStart, offsetBy: 9)
        let issn = String(pii[issnStart..<issnEnd])
        guard let openingParen = pii.firstIndex(of: "("),
              let closingParen = pii[openingParen...].firstIndex(of: ")"),
              let suffix = Int(pii[pii.index(after: openingParen)..<closingParen]) else {
            return nil
        }
        return (issn, suffix)
    }

    static func cellPressURL(
        for article: CellPressArticle,
        pageKind: CellPressPageKind
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.cell.com"
        let suffix = pageKind == .pdf ? "\(article.pii).pdf" : article.pii
        components.path = "/\(article.journalPath)/\(pageKind.rawValue)/\(suffix)"
        return components.url
    }

    static func cellPressLinkingHubURL(forPII pii: String) -> URL? {
        let compactPII = pii.filter { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
        guard !compactPII.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "linkinghub.elsevier.com"
        components.path = "/retrieve/pii/\(compactPII)"
        return components.url
    }

    static func parseCellPressLinkingHubTitle(_ data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(
                pattern: #"articleName\s*:\s*'((?:\\.|[^'\\])*)'"#
              ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: html) else { return nil }
        let unescaped = String(html[titleRange])
            .replacingOccurrences(of: #"\'"#, with: "'")
            .replacingOccurrences(of: #"\\"#, with: #"\"#)
        let title = CitationMetaScraper.decodeHTMLEntities(unescaped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

// MARK: - PDF → landing rewrite

internal extension PaperURLResolver {
    static let neurIPSRewriteRegex = try! NSRegularExpression(
        pattern: #"(/paper_files/paper/\d+/)file/(.+)-Paper(.*)\.pdf$"#
    )

    static func rewritePDFURLToLanding(_ url: URL, host: KnownPaperHost) -> URL {
        guard let canonical = canonicalize(url),
              var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return url
        }

        let path = components.path

        switch host {
        case .openReview:
            // /pdf?id=X → /forum?id=X
            if path == "/pdf" { components.path = "/forum" }

        case .aclAnthology:
            // /2024.acl-long.123.pdf → /2024.acl-long.123/
            if path.hasSuffix(".pdf") {
                let trimmed = String(path.dropLast(4))
                components.path = trimmed + "/"
            }

        case .cvfOpenAccess:
            // /content/X/papers/Y.pdf → /content/X/html/Y.html
            if path.contains("/papers/") && path.hasSuffix(".pdf") {
                components.path = path
                    .replacingOccurrences(of: "/papers/", with: "/html/")
                    .replacingOccurrences(of: ".pdf", with: ".html")
            }

        case .neurIPS:
            // /paper/<year>/file/<file>.pdf → /paper/<year>/hash/<file>.html
            if path.contains("/file/") && path.hasSuffix(".pdf") {
                components.path = path
                    .replacingOccurrences(of: "/file/", with: "/hash/")
                    .replacingOccurrences(of: ".pdf", with: ".html")
            }

        case .neurIPSProceedings:
            // /paper_files/paper/<year>/file/<hash>-Paper<rest>.pdf
            //   → /paper_files/paper/<year>/hash/<hash>-Abstract<rest>.html
            if path.contains("/file/") && path.hasSuffix(".pdf") {
                let regex = neurIPSRewriteRegex
                let range = NSRange(path.startIndex..., in: path)
                if let match = regex.firstMatch(in: path, options: [], range: range),
                   let r1 = Range(match.range(at: 1), in: path),
                   let r2 = Range(match.range(at: 2), in: path),
                   let r3 = Range(match.range(at: 3), in: path) {
                    components.path = "\(path[r1])hash/\(path[r2])-Abstract\(path[r3]).html"
                }
            }

        case .pmlr:
            // /v200/foo23a/foo23a.pdf → /v200/foo23a.html
            // (strip the duplicate basename segment + swap ext)
            if path.contains("/") && path.hasSuffix(".pdf") {
                let segments = path.split(separator: "/").map(String.init)
                if segments.count >= 3 {
                    let basenamePDF = segments.last ?? ""
                    let basenameLanding = basenamePDF.replacingOccurrences(of: ".pdf", with: "")
                    let prefix = "/" + segments.dropLast(2).joined(separator: "/")
                    components.path = "\(prefix)/\(basenameLanding).html"
                }
            }

        case .ieeeXplore:
            // /stamp/stamp.jsp → leave as-is (no clean landing rewrite)
            // /(document|abstract/document)/N → leave as-is (already landing)
            break

        case .acmDL:
            // /doi/pdf/10.X/Y → /doi/10.X/Y
            if path.hasPrefix("/doi/pdf/") {
                components.path = "/doi/" + String(path.dropFirst("/doi/pdf/".count))
            }

        case .nature:
            // /articles/foo.pdf → /articles/foo
            if path.hasSuffix(".pdf") {
                components.path = String(path.dropLast(4))
            }

        case .springer:
            // No PDF rewrite for Springer — KnownPaperHost.classify rejects PDF URLs.
            break

        case .scienceDirect:
            // /science/article/pii/SXXXX/pdfft → /science/article/pii/SXXXX
            if path.hasSuffix("/pdfft") {
                components.path = String(path.dropLast("/pdfft".count))
            }

        case .cellPress:
            // Normalize fulltext/abstract/PDF variants to the clean fulltext
            // landing page and discard tracking/Linking Hub return parameters.
            if let article = cellPressArticle(from: canonical),
               let landing = cellPressURL(for: article, pageKind: .fulltext),
               let landingComponents = URLComponents(url: landing, resolvingAgainstBaseURL: false) {
                components = landingComponents
            }

        case .science, .acs:
            if let article = doiPublisherArticle(from: canonical, host: host) {
                components.host = article.host == .science ? "www.science.org" : "pubs.acs.org"
                if article.pageKind == .pdf || article.pageKind == .epdf {
                    components.path = doiPublisherPath(for: article, pageKind: .canonical)
                    if article.host == .science {
                        components.queryItems = nil
                    }
                }
            }

        case .aanda:
            components.host = "www.aanda.org"
            if let article = aandaArticle(from: canonical), article.pageKind == .pdf {
                components.path = aandaPath(for: article, pageKind: .fullHTML)
            }

        case .oxfordAcademic:
            // Article and article-abstract pages are already stable landings.
            // Publisher PDF URLs are deliberately handled as remote files.
            break

        case .geoscienceWorld:
            // Remove navigation state such as `redirectedFrom=PDF`; the path
            // itself is the stable article landing identity.
            components.queryItems = nil

        case .eLife:
            // /articles/29515.pdf → /articles/29515
            if path.hasSuffix(".pdf") {
                components.path = String(path.dropLast(4))
            }

        case .eNeuro:
            // eNeuro's bare host does not reliably serve the site, so retain
            // the publisher's working www host. Normalize HighWire variants:
            // /content/9/2/ID.long                 → /content/9/2/ID
            // /content/eneuro/9/2/ID.full.pdf      → /content/9/2/ID
            // /content/eneuro/early/date/ID.full.pdf → /content/early/date/ID
            components.host = "www.eneuro.org"
            var segments = path.split(separator: "/").map(String.init)
            if segments.count > 1, segments[1].lowercased() == "eneuro" {
                segments.remove(at: 1)
            }
            if !segments.isEmpty {
                for suffix in [".full.pdf", ".abstract", ".full", ".long"]
                    where segments[segments.count - 1].hasSuffix(suffix) {
                    segments[segments.count - 1].removeLast(suffix.count)
                    break
                }
                components.path = "/" + segments.joined(separator: "/")
            }

        case .aps:
            // /<journal>/pdf/10.1103/<suffix>
            //   → /<journal>/abstract/10.1103/<suffix>
            if let article = apsArticle(from: canonical), article.pageKind == .pdf {
                components.path = apsPath(for: article, pageKind: .abstract)
            }
        }

        return components.url ?? url
    }
}

// MARK: - Shared HTTP helper

internal struct PaperURLHTTPResponse: Sendable {
    let data: Data
    let finalURL: URL
    let contentType: String?
}

internal extension PaperURLResolver {
    /// Performs an HTTP GET with retry, content-type filtering, and a redirect-host
    /// check against the KnownPaperHost allowlist. Callers for a fixed internal
    /// endpoint outside that registry may instead supply `permittedFinalHosts`.
    /// Used by CitationMetaScraper for every allowlisted host (CVF included).
    ///
    /// Retry contract (matches CitationMetaScraper §2.1):
    /// - URLError.timedOut: retry, 1s base, exponential
    /// - URLError.networkConnectionLost: retry, 1s base, exponential
    /// - HTTP 5xx: retry, 1s base, exponential
    /// - HTTP 429: retry, 3s base, exponential
    /// - Everything else: throw immediately
    static func fetchHTML(
        url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15,
        maxAttempts: Int = 3,
        permittedFinalHosts: Set<String>? = nil
    ) async throws -> PaperURLHTTPResponse {
        try await withRetry(maxAttempts: maxAttempts) {
            var request = URLRequest(url: url)
            request.setValue(MetadataFetcher.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.timeoutInterval = timeout

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ResolveError.fetchFailed(statusCode: 0, host: url.host ?? "")
            }

            // HTTP errors → throw (withRetry decides whether to retry).
            if httpResponse.statusCode >= 400 {
                throw ResolveError.fetchFailed(statusCode: httpResponse.statusCode, host: url.host ?? "")
            }

            // Redirect-host check: response.url is the final URL after redirects.
            let finalURL = httpResponse.url ?? url
            let finalHost = finalURL.host?.lowercased() ?? ""
            let finalHostIsPermitted = permittedFinalHosts?.contains(finalHost)
                ?? (KnownPaperHost.classify(finalURL) != nil)
            if !finalHostIsPermitted {
                throw ResolveError.redirectedAwayFromAllowlist(finalHost: finalHost)
            }

            // Content-type policy: accept text/html, application/xhtml+xml, or missing.
            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !contentType.isEmpty
                && !contentType.hasPrefix("text/html")
                && !contentType.hasPrefix("application/xhtml+xml") {
                throw ResolveError.unexpectedContentType(contentType)
            }

            return PaperURLHTTPResponse(data: data, finalURL: finalURL, contentType: contentType.isEmpty ? nil : contentType)
        }
    }

    /// Retry contract (matches CitationMetaScraper §2.1):
    /// - URLError.timedOut: retry with 1s base, exponential
    /// - URLError.networkConnectionLost: retry with 1s base, exponential
    /// - ResolveError.fetchFailed with status 5xx: retry with 1s base
    /// - ResolveError.fetchFailed with status 429: retry with 3s base
    /// - Everything else: throw immediately (no retry)
    private static func withRetry<T>(
        maxAttempts: Int,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch let error as ResolveError {
                guard case .fetchFailed(let statusCode, _) = error,
                      statusCode == 429 || (500...599).contains(statusCode) else {
                    throw error  // Non-retryable HTTP error (4xx other than 429, etc.)
                }
                lastError = error
                let base: UInt64 = statusCode == 429 ? 3_000_000_000 : 1_000_000_000
                let delay = base * UInt64(1 << attempt)
                if attempt + 1 < maxAttempts {
                    try await Task.sleep(nanoseconds: delay)
                }
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                lastError = error
                let delay: UInt64 = 1_000_000_000 * UInt64(1 << attempt)
                if attempt + 1 < maxAttempts {
                    try await Task.sleep(nanoseconds: delay)
                }
            } catch {
                throw error
            }
        }
        throw lastError ?? ResolveError.fetchFailed(statusCode: -1, host: "")
    }
}
