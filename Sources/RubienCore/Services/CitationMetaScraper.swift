import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CitationMetaResult: Sendable, Equatable {
    public var title: String?
    public var authors: [AuthorName]
    public var year: Int?
    public var journal: String?
    public var conferenceTitle: String?
    public var volume: String?
    public var issue: String?
    public var firstPage: String?
    public var lastPage: String?
    public var doi: String?
    public var isbn: String?
    public var issn: String?
    public var abstract: String?
    public var pdfURL: String?
    public var publisher: String?

    public init() {
        self.authors = []
    }
}

public enum CitationMetaScraper {
    public static func fetch(
        _ url: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) async throws -> CitationMetaResult {
        let response = try await PaperURLResolver.fetchHTML(url: url, session: session, timeout: timeout)
        let html = String(data: response.data, encoding: .utf8) ?? ""
        return parse(html: html, baseURL: response.finalURL)
    }

    public static func parse(html: String, baseURL: URL) -> CitationMetaResult {
        var result = CitationMetaResult()
        let tags = extractMetaTags(from: html)

        // Multi-value tags
        let authorValues = tags.filter { $0.name == "citation_author" }.map(\.content)
        // citation_author is typically one name per tag, but some sites concatenate
        // multiple authors with "and" in a single tag — parseList handles both shapes.
        result.authors = authorValues.flatMap { AuthorName.parseList($0) }

        // Single-value tags
        for (name, content) in tags.map({ ($0.name, $0.content) }) {
            switch name {
            case "citation_title":             result.title = content
            case "citation_journal_title":     result.journal = content
            case "citation_conference_title":  result.conferenceTitle = content
            case "citation_volume":            result.volume = content
            case "citation_issue":             result.issue = content
            case "citation_firstpage":         result.firstPage = content
            case "citation_lastpage":          result.lastPage = content
            case "citation_doi":               result.doi = content
            case "citation_isbn":              result.isbn = content
            case "citation_issn":              result.issn = content
            case "citation_publisher":         result.publisher = content
            case "citation_abstract":          result.abstract = content
            case "citation_publication_date":
                if result.year == nil { result.year = MetadataResolution.extractYear(fromMetadataText: content) }
            case "citation_year":
                result.year = MetadataResolution.extractYear(fromMetadataText: content) ?? result.year
            case "citation_pdf_url":
                result.pdfURL = resolveAbsolute(content, baseURL: baseURL)
            case "og:description":
                if result.abstract == nil { result.abstract = content }
            default:
                break
            }
        }

        return result
    }

    // MARK: - Internals

    private struct MetaTag {
        let name: String
        let content: String
    }

    /// Patterns for <meta name="..." content="..."> in name-first and content-first attribute order.
    private static let metaTagRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"<meta\s+[^>]*name\s*=\s*["']([^"']+)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*/?>"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*name\s*=\s*["']([^"']+)["'][^>]*/?>"#,
            options: [.caseInsensitive]
        ),
    ]

    /// Scans the <head> section for <meta name="..." content="..."> tags.
    /// Pattern is generous about attribute order and quoting style.
    private static func extractMetaTags(from html: String) -> [MetaTag] {
        // Restrict to <head>...</head> if present; fall back to whole document.
        let scope: String = {
            if let headStart = html.range(of: "<head", options: .caseInsensitive),
               let headEnd = html.range(of: "</head>", options: .caseInsensitive, range: headStart.upperBound..<html.endIndex) {
                return String(html[headStart.lowerBound..<headEnd.upperBound])
            }
            return html
        }()

        var tags: [MetaTag] = []
        for (idx, regex) in metaTagRegexes.enumerated() {
            let range = NSRange(scope.startIndex..., in: scope)
            regex.enumerateMatches(in: scope, options: [], range: range) { match, _, _ in
                guard let match = match,
                      let r1 = Range(match.range(at: 1), in: scope),
                      let r2 = Range(match.range(at: 2), in: scope) else { return }
                let (name, content) = idx == 0
                    ? (String(scope[r1]).lowercased(), String(scope[r2]))
                    : (String(scope[r2]).lowercased(), String(scope[r1]))
                tags.append(MetaTag(name: name, content: decodeHTMLEntities(content)))
            }
        }
        return tags
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func resolveAbsolute(_ rawURL: String, baseURL: URL) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url.absoluteString }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteString
    }
}
