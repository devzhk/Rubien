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
        case bibtexNotFound
        case bibtexEmpty
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
        crossrefFetcher: @Sendable (String) async throws -> Reference = MetadataFetcher.fetchFromDOI
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

        // 4. Dispatch to host-specific adapter.
        let (scrapedReference, scrapedPDFURL): (Reference, String?)
        if host == .cvfOpenAccess {
            (scrapedReference, scrapedPDFURL) = try await resolveCVF(landingURL: landingURL, session: session)
        } else {
            (scrapedReference, scrapedPDFURL) = try await resolveCitationMeta(landingURL: landingURL, host: host, session: session)
        }

        // 5. If DOI present, re-fetch via CrossRef.
        var finalReference = scrapedReference
        if let doi = scrapedReference.doi?.trimmingCharacters(in: .whitespacesAndNewlines),
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
                    // Keep metadataSource as publisherCitationMeta (the user pasted a publisher URL,
                    // not just a DOI; provenance should reflect that path).
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
            case .ieeeXplore, .acmDL, .nature, .springer, .scienceDirect:
                if meta.journal != nil { return .journalArticle }
                if meta.conferenceTitle != nil { return .conferencePaper }
                return .journalArticle
            }
        }()

        let pages: String? = {
            if let first = meta.firstPage, let last = meta.lastPage { return "\(first)-\(last)" }
            return meta.firstPage
        }()

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
            metadataSource: .publisherCitationMeta,
            publisher: meta.publisher,
            isbn: meta.isbn,
            issn: meta.issn,
            eventTitle: (referenceType == .conferencePaper) ? meta.conferenceTitle : nil
        )
        return (ref, meta.pdfURL)
    }

    // MARK: - CVF BibTeX dispatch

    private static func resolveCVF(
        landingURL: URL,
        session: URLSession
    ) async throws -> (Reference, String?) {
        let response = try await fetchHTML(url: landingURL, session: session)
        let html = String(data: response.data, encoding: .utf8) ?? ""

        // Extract <pre>...</pre> contents.
        let pattern = #"(?s)<pre[^>]*>(.+?)</pre>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw ResolveError.bibtexNotFound
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let bibRange = Range(match.range(at: 1), in: html) else {
            throw ResolveError.bibtexNotFound
        }
        let bibtex = String(html[bibRange])

        let refs = BibTeXImporter.parse(bibtex)
        guard let first = refs.first,
              !first.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResolveError.bibtexEmpty
        }

        // Synthesize PDF URL from landing URL.
        let pdfURL = landingURL.absoluteString
            .replacingOccurrences(of: "/html/", with: "/papers/")
            .replacingOccurrences(of: ".html", with: ".pdf")

        var ref = first
        ref.url = landingURL.absoluteString
        ref.metadataSource = .cvfOpenAccess
        ref.referenceType = .conferencePaper

        return (ref, pdfURL)
    }
}

// MARK: - KnownPaperHost (internal)

internal enum KnownPaperHost: CaseIterable {
    case openReview, aclAnthology, cvfOpenAccess
    case neurIPS, neurIPSProceedings
    case pmlr, ieeeXplore, acmDL, nature, springer, scienceDirect

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
        default:
            return nil
        }
    }

    private static func matches(_ string: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}

// MARK: - URL canonicalization

internal extension PaperURLResolver {
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
        // store as https." All 10 target hosts support https; this also covers
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
}

// MARK: - PDF → landing rewrite

internal extension PaperURLResolver {
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
                let regex = try? NSRegularExpression(
                    pattern: #"(/paper_files/paper/\d+/)file/(.+)-Paper(.*)\.pdf$"#
                )
                let range = NSRange(path.startIndex..., in: path)
                if let match = regex?.firstMatch(in: path, options: [], range: range),
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
    /// check against the KnownPaperHost allowlist. Used by both CitationMetaScraper
    /// and the CVF BibTeX adapter.
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
            request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
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

    private static func userAgent() -> String {
        let email = MetadataFetcher.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty || !email.contains("@") {
            return "Rubien/1.0"
        }
        return "Rubien/1.0 (mailto:\(email))"
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
