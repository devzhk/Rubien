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

    public static func resolve(
        _ url: URL,
        session: URLSession = .shared,
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

        // 4. Resolve publisher metadata. APS, Science, and ACS URLs carry an
        // authoritative DOI in the path, so resolve them through CrossRef
        // without fetching publisher pages that commonly reject automated
        // clients. eLife exposes a stable, keyless JSON API; the remaining
        // hosts use the generic citation_* scraper.
        let (scrapedReference, scrapedPDFURL): (Reference, String?)
        if host == .aps {
            (scrapedReference, scrapedPDFURL) = try await resolveAPS(
                landingURL: landingURL,
                crossrefFetcher: crossrefFetcher
            )
        } else if host == .science || host == .acs {
            (scrapedReference, scrapedPDFURL) = try await resolveDOIPublisher(
                landingURL: landingURL,
                host: host,
                crossrefFetcher: crossrefFetcher
            )
        } else if host == .eLife {
            (scrapedReference, scrapedPDFURL) = try await resolveELife(
                landingURL: landingURL,
                session: session
            )
        } else {
            (scrapedReference, scrapedPDFURL) = try await resolveCitationMeta(
                landingURL: landingURL,
                host: host,
                session: session
            )
        }

        // 5. Normalize scraper metadata through CrossRef when it carries a DOI.
        // DOI-bearing publisher paths already resolved directly in step 4.
        var finalReference = scrapedReference
        if host != .aps, host != .science, host != .acs,
           let doi = scrapedReference.doi?.trimmingCharacters(in: .whitespacesAndNewlines),
           !doi.isEmpty {
            do {
                let crossref = try await crossrefFetcher(doi)
                let scraperTitle = scrapedReference.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let crossrefTitle = crossref.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let score = MetadataResolution.titleSimilarity(scraperTitle, crossrefTitle)
                if score >= 0.80 {
                    finalReference = MetadataResolution.mergeReference(primary: crossref, fallback: scrapedReference)
                    // Force canonical landing URL — CrossRef may have populated url with doi.org redirect.
                    finalReference.url = landingURL.absoluteString
                    // Preserve the per-host metadataSource the scraper assigned
                    // (.cvfOpenAccess for CVF, .publisherCitationMeta otherwise):
                    // the user pasted a publisher URL, so provenance reflects
                    // that path rather than CrossRef.
                    finalReference.metadataSource = scrapedReference.metadataSource
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
                scrapedPDFURL: scrapedPDFURL
            )
        }

        return Outcome(reference: finalReference, scrapedPDFURL: scrapedPDFURL)
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
            case .ieeeXplore, .acmDL, .nature, .springer, .scienceDirect,
                 .science, .acs, .aanda, .eLife, .eNeuro, .aps:
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
    case pmlr, ieeeXplore, acmDL, nature, springer, scienceDirect
    case science, acs, aanda, eLife, eNeuro, aps

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

    enum APSPageKind: String, Sendable {
        case abstract, accepted, pdf
    }

    struct APSArticle: Sendable {
        let journalSlug: String
        let pageKind: APSPageKind
        let doi: String
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
}

// MARK: - PDF → landing rewrite

internal extension PaperURLResolver {
    /// True when `url` is `host`'s PDF form of an article link. The default
    /// is a `.pdf` path extension; hosts whose PDF URLs lack one override.
    static func isPublisherPDFURL(_ url: URL, host: KnownPaperHost) -> Bool {
        switch host {
        case .aps:
            return apsArticle(from: url)?.pageKind == .pdf
        case .science, .acs:
            guard let article = doiPublisherArticle(from: url, host: host) else { return false }
            return article.pageKind == .pdf || article.pageKind == .epdf
        case .aanda:
            return aandaArticle(from: url)?.pageKind == .pdf
        default:
            return url.pathExtension.lowercased() == "pdf"
        }
    }

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

        case .science, .acs:
            if let article = doiPublisherArticle(from: canonical, host: host) {
                components.host = article.host == .science ? "www.science.org" : "pubs.acs.org"
                if article.pageKind == .pdf || article.pageKind == .epdf {
                    components.path = doiPublisherPath(for: article, pageKind: .canonical)
                }
            }

        case .aanda:
            components.host = "www.aanda.org"
            if let article = aandaArticle(from: canonical), article.pageKind == .pdf {
                components.path = aandaPath(for: article, pageKind: .fullHTML)
            }

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
    /// check against the KnownPaperHost allowlist. Used by CitationMetaScraper
    /// for every allowlisted host (CVF included).
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
        maxAttempts: Int = 3
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
            if let finalHost = finalURL.host?.lowercased(),
               KnownPaperHost.classify(finalURL) == nil {
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
