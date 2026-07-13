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

    /// Captures the attribute string inside each <meta ...> tag.
    /// Each match's group 1 is everything between `<meta ` and `>` (or `/>`),
    /// which is then parsed by `parseAttributes` to handle all three HTML5
    /// attribute-value quoting styles (double-quoted, single-quoted, unquoted).
    ///
    /// Known limitation: attribute values containing a literal `>` (e.g.
    /// `content="A > B"`) will be truncated by the `[^>]` capture. This does
    /// not arise in practice for `citation_*` tag content (paper titles,
    /// author names, DOIs, URLs), and the previous two-regex approach had
    /// the same limitation.
    private static let metaTagRegex = try! NSRegularExpression(
        pattern: #"<meta\s+([^>]+?)\s*/?>"#,
        options: [.caseInsensitive]
    )

    /// Scans the <head> section for `<meta name="…" content="…">` tags.
    /// Accepts attribute order in either direction (`name`-first or
    /// `content`-first) and any HTML5 attribute-value form: `name="X"`,
    /// `name='X'`, or unquoted `name=X` (used by ACL Anthology and other
    /// Hugo-generated sites).
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
        let range = NSRange(scope.startIndex..., in: scope)
        metaTagRegex.enumerateMatches(in: scope, options: [], range: range) { match, _, _ in
            guard let match = match,
                  let attrsRange = Range(match.range(at: 1), in: scope) else { return }
            let attrs = parseAttributes(String(scope[attrsRange]))
            guard let name = attrs["name"]?.lowercased(),
                  let content = attrs["content"] else { return }
            tags.append(MetaTag(name: name, content: decodeHTMLEntities(content)))
        }
        return tags
    }

    /// Parse an HTML tag attribute string into a `[key: value]` map. Handles
    /// the three HTML5 attribute-value forms — double-quoted, single-quoted,
    /// and unquoted. Keys are lowercased; values preserve case.
    ///
    /// Examples:
    ///   `name="foo" content="bar baz"`     -> ["name": "foo", "content": "bar baz"]
    ///   `name='foo' content='bar'`         -> ["name": "foo", "content": "bar"]
    ///   `name=foo content=bar`             -> ["name": "foo", "content": "bar"]
    ///   `content="X" name=citation_title`  -> ["content": "X", "name": "citation_title"]
    private static func parseAttributes(_ attrs: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(attrs)
        var i = 0
        while i < chars.count {
            // Skip whitespace
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }

            // Read attribute name (until '=' or whitespace)
            let nameStart = i
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=" { i += 1 }
            let name = String(chars[nameStart..<i]).lowercased()
            if name.isEmpty { i += 1; continue }

            // Skip whitespace before '='
            while i < chars.count, chars[i].isWhitespace { i += 1 }

            // Attribute with no value (e.g., `disabled`).
            guard i < chars.count, chars[i] == "=" else {
                result[name] = ""
                continue
            }
            i += 1

            // Skip whitespace after '='
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { result[name] = ""; break }

            // Read value (quoted or unquoted)
            if chars[i] == "\"" || chars[i] == "'" {
                let quote = chars[i]
                i += 1
                let valueStart = i
                while i < chars.count, chars[i] != quote { i += 1 }
                result[name] = String(chars[valueStart..<i])
                if i < chars.count { i += 1 } // consume closing quote
            } else {
                let valueStart = i
                while i < chars.count, !chars[i].isWhitespace { i += 1 }
                result[name] = String(chars[valueStart..<i])
            }
        }
        return result
    }

    internal static func decodeHTMLEntities(_ s: String) -> String {
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
