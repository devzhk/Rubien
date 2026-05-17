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
                if result.year == nil { result.year = parseYear(content) }
            case "citation_year":
                result.year = parseYear(content) ?? result.year
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

        // Match <meta ... name="X" ... content="Y"> and the reversed attribute order.
        let patterns = [
            #"<meta\s+[^>]*name\s*=\s*["']([^"']+)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*/?>"#,
            #"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*name\s*=\s*["']([^"']+)["'][^>]*/?>"#,
        ]

        var tags: [MetaTag] = []
        for (idx, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
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

    private static func parseYear(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try bare 4-digit year first.
        if trimmed.count == 4, let n = Int(trimmed), (1500...2200).contains(n) { return n }
        // Else extract the first 4-digit substring.
        let pattern = #"(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let yearRange = Range(match.range(at: 1), in: trimmed),
              let year = Int(trimmed[yearRange]),
              (1500...2200).contains(year) else { return nil }
        return year
    }

    private static func resolveAbsolute(_ rawURL: String, baseURL: URL) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url.absoluteString }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteString
    }
}
