import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Automatic metadata fetching from DOI, PMID, arXiv identifiers
/// Uses free public APIs — no API keys required
public enum MetadataFetcher {

    /// Contact email for CrossRef / OpenAlex polite pool.
    /// Set this from the app layer (e.g. from user preferences) at launch.
    /// CrossRef grants faster rate limits to callers who provide a real mailto.
    public static var contactEmail: String = ""

    // MARK: - Response Cache

    /// In-memory cache for fetched references (keyed by identifier string).
    /// Avoids duplicate API calls during batch import or repeated lookups.
    private static let responseCache: NSCache<NSString, CachedReference> = {
        let cache = NSCache<NSString, CachedReference>()
        cache.countLimit = 50
        return cache
    }()
    private static let cacheTTL: TimeInterval = 300 // 5 minutes

    private final class CachedReference {
        let reference: Reference
        let timestamp: Date
        init(_ ref: Reference) { self.reference = ref; self.timestamp = Date() }
    }

    private static func cachedReference(for key: String) -> Reference? {
        guard let entry = responseCache.object(forKey: key as NSString) else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > cacheTTL {
            responseCache.removeObject(forKey: key as NSString)
            return nil
        }
        return entry.reference
    }

    private static func cacheReference(_ ref: Reference, for key: String) {
        responseCache.setObject(CachedReference(ref), forKey: key as NSString)
    }

    /// User-Agent header value. Includes mailto when a contact email is configured.
    internal static var userAgent: String {
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty || !email.contains("@") {
            return "Rubien/1.0"
        }
        return "Rubien/1.0 (mailto:\(email))"
    }

    // MARK: - Identifier Detection

    public enum Identifier: Equatable {
        case doi(String)
        case pmid(String)
        case arxiv(String)
        case isbn(String)
        case pmcid(String)
        /// Paper landing-page URL on a known host (resolved via `PaperURLResolver`).
        case paperURL(URL)
    }

    /// Parse raw text input and detect identifier type (priority: DOI > arXiv > ISBN > PMCID > PMID)
    public static func extractIdentifier(from text: String) -> Identifier? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // PMCID URL: pmc.ncbi.nlm.nih.gov / www.ncbi.nlm.nih.gov articles path.
        // Checked before DOI so a `pmc.ncbi.nlm.nih.gov/articles/PMC.../doi:...` URL
        // (rare but possible) doesn't accidentally route through DOI extraction.
        if let pmcid = extractPMCIDFromURL(trimmed) {
            return .pmcid(pmcid)
        }

        // Paper landing-page URL on a known host with a known path shape.
        // Placed before DOI extraction so URLs like
        //   https://link.springer.com/article/10.1007/s11042-024-12345-6
        // route through PaperURLResolver (preserves landing URL on Reference.url)
        // rather than the bare DOI extractor (which would route to CrossRef and
        // lose publisher-page context).
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           KnownPaperHost.classify(url) != nil {
            return .paperURL(url)
        }

        // DOI: 10.XXXX/... (most specific)
        if let doi = cleanDOI(trimmed) {
            // arXiv DataCite DOIs (10.48550/arXiv.YYMM.NNNNN) aren't indexed by
            // CrossRef — extract the bare arXiv ID and route to the arXiv resolver.
            if let arxivID = arxivIDFromDataCiteDOI(doi) {
                return .arxiv(arxivID)
            }
            return .doi(doi)
        }

        // PMCID bare form: `PMC1234567` (case-insensitive). Anchored to the whole
        // trimmed input so substrings like "see PMC1234567 above" don't trigger
        // identifier routing and bypass title search. Must come before the PMID
        // bare-digit check below since PMID accepts the digit suffix alone.
        if let pmcid = extractPMCIDBare(trimmed) {
            return .pmcid(pmcid)
        }

        // arXiv: YYMM.NNNNN or category/NNNNNNN. Must precede the ISBN digit-count
        // heuristic — a URL like "https://arxiv.org/abs/2501.07888v3" reduces to
        // exactly 10 digits ("2501078883") after stripping non-[0-9X] chars and
        // would otherwise be misclassified as ISBN.
        let arxivPatterns = [
            #"(\d{4}\.\d{4,5})(v\d+)?"#,
            #"([a-z\-]+/\d{7})"#,
            #"arXiv:(.+)"#
        ]
        for pattern in arxivPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return .arxiv(String(trimmed[range]))
            }
        }

        // ISBN: 10 or 13 digits
        let digitsOnly = trimmed.replacingOccurrences(of: "[^0-9X]", with: "", options: .regularExpression)
        if digitsOnly.count == 10 || digitsOnly.count == 13 {
            if digitsOnly.count == 13 && (digitsOnly.hasPrefix("978") || digitsOnly.hasPrefix("979")) {
                return .isbn(digitsOnly)
            }
            if digitsOnly.count == 10 {
                return .isbn(digitsOnly)
            }
        }

        // PMID: bare number (1-9 digits, last resort)
        if let _ = Int(trimmed), trimmed.count >= 1 && trimmed.count <= 9 {
            return .pmid(trimmed)
        }

        return nil
    }

    /// If `doi` is an arXiv DataCite DOI (e.g. `10.48550/arXiv.1706.03762` or
    /// `10.48550/arXiv.cs/0501001`), return the bare arXiv ID. Otherwise nil.
    private static func arxivIDFromDataCiteDOI(_ doi: String) -> String? {
        let lowered = doi.lowercased()
        let prefix = "10.48550/arxiv."
        guard lowered.hasPrefix(prefix) else { return nil }
        let id = String(doi.dropFirst(prefix.count))
        // Strip any trailing version suffix (`v2`, `v10`, etc.)
        let stripped = id.replacingOccurrences(
            of: #"v\d+$"#,
            with: "",
            options: .regularExpression
        )
        return stripped.isEmpty ? nil : stripped
    }

    /// Extract canonical PMCID (e.g. `PMC1234567`) from a bare-string input.
    /// Anchored: the whole trimmed input must be `PMC` + digits (case-insensitive),
    /// optionally with surrounding whitespace. Returns nil otherwise.
    /// Versioned PMCIDs (`PMC1234567.1`) are intentionally rejected — see
    /// fetchFromPMCID for the rationale.
    private static func extractPMCIDBare(_ input: String) -> String? {
        let pattern = #"^\s*PMC(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let digitsRange = Range(match.range(at: 1), in: input)
        else { return nil }
        return "PMC\(input[digitsRange])"
    }

    /// Extract canonical PMCID from a PMC article URL. Returns nil unless the URL
    /// host is `pmc.ncbi.nlm.nih.gov` or `www.ncbi.nlm.nih.gov` and the path
    /// contains `articles/PMC\d+` (case-insensitive match on `PMC`).
    private static func extractPMCIDFromURL(_ input: String) -> String? {
        guard let components = URLComponents(string: input),
              let host = components.host?.lowercased() else { return nil }
        let validHosts: Set<String> = ["pmc.ncbi.nlm.nih.gov", "www.ncbi.nlm.nih.gov"]
        guard validHosts.contains(host) else { return nil }
        // URLComponents.path already strips query/fragment. Split into segments
        // and look for `articles` followed immediately by a PMC\d+ segment.
        let segments = components.path.split(separator: "/").map(String.init)
        guard let articlesIdx = segments.firstIndex(of: "articles"),
              articlesIdx + 1 < segments.count else { return nil }
        let candidate = segments[articlesIdx + 1]
        let pattern = #"^PMC(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
              let digitsRange = Range(match.range(at: 1), in: candidate)
        else { return nil }
        return "PMC\(candidate[digitsRange])"
    }

    /// Clean and extract DOI from various formats (URL, bare DOI, etc.)
    private static func cleanDOI(_ input: String) -> String? {
        var text = input
        // Handle doi.org URLs
        if let range = text.range(of: "doi.org/") {
            text = String(text[range.upperBound...])
        }
        // Handle "doi:" prefix
        if text.lowercased().hasPrefix("doi:") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        // Match DOI pattern: 10.XXXX/...
        let pattern = #"(10\.\d{4,}\/[^\s]+[^\s\.,;\]\)])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    // MARK: - DOI → Crossref API

    /// Fetch metadata from DOI via Crossref REST API
    public static func fetchFromDOI(_ doi: String) async throws -> Reference {
        let cacheKey = "doi:\(doi)"
        if let cached = cachedReference(for: cacheKey) { return cached }

        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doi
        let urlString = "https://api.crossref.org/works/\(encoded)"
        guard let url = URL(string: urlString) else {
            throw FetchError.invalidURL
        }

        var ref = try await withRetry {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw FetchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return try parseCrossrefResponse(data, doi: doi)
        }

        // Crossref often lacks abstract (Nature, etc.) — fetch from S2 and OpenAlex in parallel, take first success
        if ref.abstract == nil || ref.abstract?.isEmpty == true {
            async let s2Abstract = try? fetchAbstractFromSemanticScholar(doi: doi)
            async let oaAbstract = try? fetchAbstractFromOpenAlex(doi: doi)

            let (s2, oa) = await (s2Abstract, oaAbstract)
            // Prefer Semantic Scholar (tends to be higher quality for STEM)
            ref.abstract = s2 ?? oa
        }

        cacheReference(ref, for: cacheKey)
        return ref
    }

    // MARK: - OpenAlex Abstract Fallback

    /// Fetch abstract from Semantic Scholar using DOI (Excellent for Computer Science and Modern STEM)
    public static func fetchAbstractFromSemanticScholar(doi: String) async throws -> String? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doi
        let urlString = "https://api.semanticscholar.org/graph/v1/paper/DOI:\(encoded)?fields=abstract"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let abstract = json["abstract"] as? String, !abstract.isEmpty else {
            return nil
        }
        return abstract
    }

    /// Fetch abstract from OpenAlex (free, no API key, covers ~250M works)
    public static func fetchAbstractFromOpenAlex(doi: String) async throws -> String? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doi
        let urlString = "https://api.openalex.org/works/doi:\(encoded)?select=abstract_inverted_index"
        return try await fetchOpenAlexAbstract(urlString)
    }

    /// Fetch abstract from OpenAlex using Title fallback
    public static func fetchAbstractFromOpenAlex(title: String) async throws -> String? {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let urlString = "https://api.openalex.org/works?search=\(encoded)&select=abstract_inverted_index&per-page=1"
        return try await fetchOpenAlexAbstract(urlString, isSearch: true)
    }

    private static func fetchOpenAlexAbstract(_ urlString: String, isSearch: Bool = false) async throws -> String? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let workData: [String: Any]?
        if isSearch {
            guard let results = json["results"] as? [[String: Any]], let first = results.first else {
                return nil
            }
            workData = first
        } else {
            workData = json
        }

        guard let work = workData else { return nil }
        return decodeOpenAlexAbstract(from: work)
    }

    /// Reconstruct an abstract from OpenAlex's `abstract_inverted_index` shape
    /// (`{word: [position, ...]}`). Returns nil when the field is missing or empty.
    private static func decodeOpenAlexAbstract(from work: [String: Any]) -> String? {
        guard let invertedIndex = work["abstract_inverted_index"] as? [String: [Int]] else { return nil }
        var positions: [Int: String] = [:]
        for (word, indices) in invertedIndex {
            for idx in indices { positions[idx] = word }
        }
        guard !positions.isEmpty else { return nil }
        let abstract = positions.keys.sorted().compactMap { positions[$0] }.joined(separator: " ")
        return abstract.isEmpty ? nil : abstract
    }

    static func parseCrossrefResponse(_ data: Data, doi: String) throws -> Reference {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw FetchError.parseError
        }

        let result = message

        // Title
        let title: String = {
            let titles = result["title"] as? [String]
            var t = titles?.first ?? "Untitled"
            if let subtitles = result["subtitle"] as? [String], let sub = subtitles.first, !sub.isEmpty {
                t += ": " + sub
            }
            return t
        }()

        // Authors
        let authors: [AuthorName] = {
            guard let authorList = result["author"] as? [[String: Any]] else { return [] }
            return authorList.compactMap { author -> AuthorName? in
                if let name = author["name"] as? String {
                    return AuthorName.parse(name)
                }
                let given = author["given"] as? String ?? ""
                let family = author["family"] as? String ?? ""
                if family.isEmpty { return nil }
                // CrossRef often swaps given/family for CJK names (e.g. given:"Wu" family:"Haoyun"
                // instead of given:"Haoyun" family:"Wu"). Detect and correct this.
                if Self.looksLikeCJKName(given: given, family: family) {
                    return AuthorName(given: family, family: given)
                }
                return AuthorName(given: given, family: family)
            }
        }()

        // Year
        let year: Int? = {
            for key in ["published-print", "published-online", "issued", "created"] {
                if let dateInfo = result[key] as? [String: Any],
                   let dateParts = dateInfo["date-parts"] as? [[Int]],
                   let firstPart = dateParts.first,
                   let y = firstPart.first {
                    return y
                }
            }
            return nil
        }()

        // Reference type — collapsed to the v3 6-bucket set.
        let referenceType: ReferenceType = {
            guard let type = result["type"] as? String else { return .journalArticle }
            switch type {
            case "journal-article", "newspaper-article", "magazine-article":
                return .journalArticle
            case "book", "monograph", "edited-book", "book-chapter", "book-section":
                return .book
            case "proceedings-article":
                return .conferencePaper
            case "dissertation":
                return .thesis
            // CrossRef has no "webpage" type. "posted-content" (preprints) folds
            // into Journal Article per Scholar convention.
            case "posted-content":
                return .journalArticle
            default:
                return .other
            }
        }()

        // Abstract (strip JATS XML tags)
        let abstract: String? = {
            guard let raw = result["abstract"] as? String else { return nil }
            let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        // Journal
        let journal: String? = {
            (result["container-title"] as? [String])?.first
        }()

        return Reference(
            title: title,
            authors: authors,
            year: year,
            journal: journal,
            volume: result["volume"] as? String,
            issue: result["issue"] as? String,
            pages: (result["page"] as? String) ?? (result["article-number"] as? String),
            doi: doi,
            url: (result["resource"] as? [String: Any]).flatMap { ($0["primary"] as? [String: Any])?["URL"] as? String },
            abstract: abstract,
            referenceType: referenceType
        )
    }

    // MARK: - PMID → PubMed API

    /// Fetch metadata from PMID via NCBI efetch API
    public static func fetchFromPMID(_ pmid: String) async throws -> Reference {
        let cacheKey = "pmid:\(pmid)"
        if let cached = cachedReference(for: cacheKey) { return cached }

        let urlString = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=\(pmid)&retmode=json"
        guard let url = URL(string: urlString) else {
            throw FetchError.invalidURL
        }

        let ref = try await withRetry {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw FetchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            return try parsePubMedResponse(data, pmid: pmid)
        }

        cacheReference(ref, for: cacheKey)
        return ref
    }

    static func parsePubMedResponse(_ data: Data, pmid: String) throws -> Reference {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let article = result[pmid] as? [String: Any] else {
            throw FetchError.parseError
        }

        let title = (article["title"] as? String)?.trimmingCharacters(in: .init(charactersIn: ".")) ?? "Untitled"

        let authors: [AuthorName] = {
            guard let authorList = article["authors"] as? [[String: Any]] else { return [] }
            return authorList.compactMap { entry -> AuthorName? in
                guard let name = entry["name"] as? String else { return nil }
                return AuthorName.parse(name)
            }
        }()

        let year: Int? = {
            if let pubDate = article["pubdate"] as? String {
                let components = pubDate.components(separatedBy: " ")
                return components.first.flatMap { Int($0) }
            }
            return nil
        }()

        let articleIDs = article["articleids"] as? [[String: Any]] ?? []

        let doi: String? = {
            articleIDs.first(where: { ($0["idtype"] as? String) == "doi" })?["value"] as? String
        }()

        let pmcid: String? = {
            articleIDs.first(where: { ($0["idtype"] as? String) == "pmc" })?["value"] as? String
        }()

        return Reference(
            title: title,
            authors: authors,
            year: year,
            journal: article["source"] as? String,
            volume: article["volume"] as? String,
            issue: article["issue"] as? String,
            pages: article["pages"] as? String,
            doi: doi,
            referenceType: .journalArticle,
            pmid: pmid,
            pmcid: pmcid
        )
    }

    // MARK: - PMCID → NCBI ID converter → PubMed/CrossRef

    /// Fetch metadata for a PMCID by converting it to a PMID (preferred) or DOI
    /// via the NCBI ID converter, then delegating to the existing PubMed or
    /// CrossRef resolver. The PubMed path already populates `pmcid`, so a
    /// PMCID→PMID→PubMed round-trip preserves the input ID in the result.
    ///
    /// Versioned PMCIDs (`PMC1234567.1`) are out of scope: extractIdentifier
    /// rejects them, and this function sends the bare ID without `versions=yes`,
    /// so the converter returns the article-level (latest version) record.
    public static func fetchFromPMCID(_ pmcid: String) async throws -> Reference {
        let normalized = pmcid.uppercased()
        let cacheKey = "pmcid:\(normalized)"
        if let cached = cachedReference(for: cacheKey) { return cached }

        let (pmid, doi, warning) = try await withRetry {
            try await fetchPMCIDConverterMapping(normalized)
        }

        if let pmid = pmid {
            var ref = try await fetchFromPMID(pmid)
            // Ensure pmcid is populated even if PubMed's articleids didn't echo it
            if ref.pmcid == nil { ref.pmcid = normalized }
            cacheReference(ref, for: cacheKey)
            return ref
        }
        if let doi = doi {
            var ref = try await fetchFromDOI(doi)
            ref.pmcid = normalized
            cacheReference(ref, for: cacheKey)
            return ref
        }
        let suffix = warning.map { " (\($0))" } ?? ""
        throw FetchError.unsupported("Could not resolve \(normalized) via NCBI ID converter\(suffix)")
    }

    /// Hit NCBI's ID converter and parse `(pmid, doi, warning)` from the
    /// response. The legacy `www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/`
    /// endpoint is still live. If it ever deprecates, swap the host to
    /// `pmc.ncbi.nlm.nih.gov/tools/idconv/api/v1/articles/` — the parser is
    /// tolerant of both response shapes.
    private static func fetchPMCIDConverterMapping(
        _ normalized: String
    ) async throws -> (pmid: String?, doi: String?, warning: String?) {
        var components = URLComponents(string: "https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "ids", value: normalized),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "tool", value: "Rubien"),
        ]
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty, email.contains("@") {
            items.append(URLQueryItem(name: "email", value: email))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw FetchError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try parsePMCIDConverterResponse(data)
    }

    /// Internal so tests can drive the parser against synthetic JSON without
    /// needing a network stub. Accepts `pmid` / `pmcid` as String OR Int.
    internal static func parsePMCIDConverterResponse(
        _ data: Data
    ) throws -> (pmid: String?, doi: String?, warning: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.parseError
        }

        // Top-level error envelope (e.g. malformed request)
        if let topStatus = (json["status"] as? String)?.lowercased(), topStatus == "error" {
            let msg = (json["errmsg"] as? String) ?? "NCBI converter returned error status"
            throw FetchError.unsupported(msg)
        }

        guard let records = json["records"] as? [[String: Any]], let record = records.first else {
            throw FetchError.parseError
        }

        // Per-record error
        if let recStatus = (record["status"] as? String)?.lowercased(), recStatus == "error" {
            let msg = (record["errmsg"] as? String) ?? "NCBI converter could not resolve PMCID"
            throw FetchError.unsupported(msg)
        }

        let pmid = stringOrInt(record["pmid"])
        let doi = record["doi"] as? String

        // Soft warning — embargoed / not-yet-live records may still convert.
        var warning: String? = nil
        if let live = record["live"] as? Bool, live == false {
            warning = "record marked live=false (embargoed?)"
        } else if let liveStr = (record["live"] as? String)?.lowercased(), liveStr == "false" {
            warning = "record marked live=false (embargoed?)"
        }

        return (pmid: pmid, doi: doi, warning: warning)
    }

    /// Coerce a JSON value that may be a String or a numeric type into a
    /// non-empty String. Returns nil for missing/empty/unrecognized shapes.
    private static func stringOrInt(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let i = value as? Int { return String(i) }
        if let i = value as? Int64 { return String(i) }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - arXiv ID → arXiv API

    /// Fetch metadata for an arXiv ID by racing the arXiv Atom API against an
    /// OpenAlex DataCite-DOI lookup. First success wins; the loser is cancelled.
    /// arXiv's `export.arxiv.org` is fronted by Fastly and has occasional POP
    /// stalls where TCP connects but no HTTP response arrives — sequential
    /// fallback would force the full URLSession timeout before recovering. The
    /// race bounds user-visible latency at `min(arXiv, OpenAlex)`.
    public static func fetchFromArXiv(_ arxivId: String) async throws -> Reference {
        let cacheKey = "arxiv:\(arxivId)"
        if let cached = cachedReference(for: cacheKey) { return cached }

        let winner = try await raceArxivAndOpenAlex(
            arxivId: arxivId,
            arxivFetch: { id in try await Self.fetchFromArXivAPI(id) },
            openAlexFetch: { doi in try await Self.fetchFromOpenAlexByDOI(doi) }
        )
        cacheReference(winner, for: cacheKey)
        return winner
    }

    /// Race arXiv and OpenAlex for the same arXiv ID. Internal so tests can
    /// drive it deterministically with closures rather than URLSession stubs.
    /// On dual failure, throws the arXiv error to preserve prior semantics.
    internal static func raceArxivAndOpenAlex(
        arxivId: String,
        arxivFetch: @Sendable @escaping (String) async throws -> Reference,
        openAlexFetch: @Sendable @escaping (String) async throws -> Reference?
    ) async throws -> Reference {
        enum Outcome {
            case arxiv(Result<Reference, Error>)
            case openAlex(Result<Reference, Error>)
        }

        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .arxiv(.success(try await arxivFetch(arxivId))) }
                catch { return .arxiv(.failure(error)) }
            }
            group.addTask {
                do {
                    guard let ref = try await openAlexFetch("10.48550/arXiv.\(arxivId)") else {
                        return .openAlex(.failure(FetchError.parseError))
                    }
                    var stamped = ref
                    stamped.url = "https://arxiv.org/abs/\(arxivId)"
                    return .openAlex(.success(stamped))
                } catch {
                    return .openAlex(.failure(error))
                }
            }

            var arxivError: Error?
            var openAlexError: Error?
            for try await outcome in group {
                switch outcome {
                case .arxiv(.success(let ref)), .openAlex(.success(let ref)):
                    group.cancelAll()
                    return ref
                case .arxiv(.failure(let err)):
                    arxivError = err
                case .openAlex(.failure(let err)):
                    openAlexError = err
                }
            }
            throw arxivError ?? openAlexError ?? FetchError.parseError
        }
    }

    /// One-shot — no `withRetry`. arXiv's 429 ("Rate exceeded") is shared server
    /// capacity, not per-IP usage, so exponential backoff buys nothing; the
    /// race against OpenAlex above is the actual recovery path. The 8 s ceiling
    /// is just an upper bound for cases where OpenAlex doesn't have the paper
    /// AND arXiv hangs — both unusual.
    private static func fetchFromArXivAPI(_ arxivId: String) async throws -> Reference {
        let urlString = "https://export.arxiv.org/api/query?id_list=\(arxivId)&max_results=1"
        guard let url = URL(string: urlString) else {
            throw FetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try parseArXivResponse(data, arxivId: arxivId)
    }

    static func parseArXivResponse(_ data: Data, arxivId: String) throws -> Reference {
        let parser = ArXivXMLParser(data: data)
        guard var entry = parser.parse() else {
            throw FetchError.parseError
        }
        entry.url = "https://arxiv.org/abs/\(arxivId)"
        return entry
    }

    // MARK: - OpenAlex Full Metadata (title search + DOI lookup)

    /// Search OpenAlex by title and return a full Reference (for articles without identifiers)
    public static func fetchFromOpenAlexByTitle(_ title: String) async throws -> Reference? {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let urlString = "https://api.openalex.org/works?search=\(encoded)&select=\(openAlexWorkSelect)&per-page=1"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let work = results.first else {
            return nil
        }
        return parseOpenAlexWork(work)
    }

    /// Fallback for arXiv API outages via the DataCite DOI form `10.48550/arXiv.<id>`.
    public static func fetchFromOpenAlexByDOI(_ doi: String) async throws -> Reference? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doi
        let urlString = "https://api.openalex.org/works/doi:\(encoded)?select=\(openAlexWorkSelect)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard let work = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseOpenAlexWork(work)
    }

    private static let openAlexWorkSelect = "id,doi,title,authorships,publication_year,primary_location,biblio,abstract_inverted_index,type"

    private static func parseOpenAlexWork(_ work: [String: Any]) -> Reference? {
        let fetchedTitle = work["title"] as? String ?? "Untitled"
        let year = work["publication_year"] as? Int

        let authors: [AuthorName] = {
            guard let authorships = work["authorships"] as? [[String: Any]] else { return [] }
            return authorships.compactMap { authorship -> AuthorName? in
                guard let author = authorship["author"] as? [String: Any],
                      let name = author["display_name"] as? String else { return nil }
                return AuthorName.parse(name)
            }
        }()

        let doi: String? = {
            guard let raw = work["doi"] as? String else { return nil }
            if let range = raw.range(of: "doi.org/") {
                return String(raw[range.upperBound...])
            }
            return raw
        }()

        let journal: String? = {
            guard let location = work["primary_location"] as? [String: Any],
                  let source = location["source"] as? [String: Any] else { return nil }
            return source["display_name"] as? String
        }()

        let biblio = work["biblio"] as? [String: Any]
        let volume = biblio?["volume"] as? String
        let issue = biblio?["issue"] as? String
        let firstPage = biblio?["first_page"] as? String
        let lastPage = biblio?["last_page"] as? String
        let pages: String? = {
            guard let f = firstPage else { return nil }
            if let l = lastPage, l != f { return "\(f)-\(l)" }
            return f
        }()

        let abstract = decodeOpenAlexAbstract(from: work)

        // OpenAlex type → v3 6-bucket set. Preprints fold into Journal Article
        // per Scholar convention; reports and book chapters fold into Other/Book.
        let referenceType: ReferenceType = {
            switch work["type"] as? String {
            case "journal-article", "article", "preprint", "posted-content":
                return .journalArticle
            case "book", "monograph", "edited-book", "book-chapter", "book-section":
                return .book
            case "proceedings-article":
                return .conferencePaper
            case "dissertation":
                return .thesis
            default:
                return .other
            }
        }()

        return Reference(
            title: fetchedTitle,
            authors: authors,
            year: year,
            journal: journal,
            volume: volume,
            issue: issue,
            pages: pages,
            doi: doi,
            abstract: abstract,
            referenceType: referenceType
        )
    }

    // MARK: - ISBN → Open Library + Google Books

    /// Fetch book metadata from ISBN via Open Library (primary) with Google Books fallback.
    public static func fetchFromISBN(_ isbn: String) async throws -> Reference {
        let cacheKey = "isbn:\(isbn)"
        if let cached = cachedReference(for: cacheKey) { return cached }

        // Open Library: free, no API key, dedicated book database
        if let ref = try? await fetchFromOpenLibrary(isbn: isbn) {
            cacheReference(ref, for: cacheKey)
            return ref
        }

        // Fallback: Google Books (1000 req/day unauthenticated)
        if let ref = try? await fetchFromGoogleBooks(isbn: isbn) {
            cacheReference(ref, for: cacheKey)
            return ref
        }

        throw FetchError.httpError(404)
    }

    private static func fetchFromOpenLibrary(isbn: String) async throws -> Reference? {
        let urlString = "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bookData = json["ISBN:\(isbn)"] as? [String: Any],
              let title = bookData["title"] as? String else { return nil }

        let authors: [AuthorName] = {
            guard let authorList = bookData["authors"] as? [[String: Any]] else { return [] }
            return authorList.compactMap { entry -> AuthorName? in
                guard let name = entry["name"] as? String else { return nil }
                return AuthorName.parse(name)
            }
        }()

        let publisher: String? = {
            guard let publishers = bookData["publishers"] as? [[String: Any]] else { return nil }
            return publishers.compactMap { $0["name"] as? String }.first
        }()

        let year: Int? = {
            guard let publishDate = bookData["publish_date"] as? String else { return nil }
            let pattern = #"(\d{4})"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: publishDate, range: NSRange(publishDate.startIndex..., in: publishDate)),
                  let range = Range(match.range(at: 1), in: publishDate) else { return nil }
            return Int(publishDate[range])
        }()

        let numberOfPages: String? = {
            guard let n = bookData["number_of_pages"] as? Int else { return nil }
            return String(n)
        }()

        return Reference(
            title: title,
            authors: authors,
            year: year,
            referenceType: .book,
            publisher: publisher,
            isbn: isbn,
            numberOfPages: numberOfPages
        )
    }

    private static func fetchFromGoogleBooks(isbn: String) async throws -> Reference? {
        let urlString = "https://www.googleapis.com/books/v1/volumes?q=isbn:\(isbn)&maxResults=1"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let volumeInfo = first["volumeInfo"] as? [String: Any],
              let title = volumeInfo["title"] as? String else { return nil }

        let authors: [AuthorName] = {
            guard let authorList = volumeInfo["authors"] as? [String] else { return [] }
            return authorList.map { AuthorName.parse($0) }
        }()

        let year: Int? = {
            guard let publishedDate = volumeInfo["publishedDate"] as? String else { return nil }
            return Int(publishedDate.prefix(4))
        }()

        let numberOfPages: String? = {
            guard let n = volumeInfo["pageCount"] as? Int else { return nil }
            return String(n)
        }()

        return Reference(
            title: title,
            authors: authors,
            year: year,
            abstract: volumeInfo["description"] as? String,
            referenceType: .book,
            publisher: volumeInfo["publisher"] as? String,
            isbn: isbn,
            numberOfPages: numberOfPages
        )
    }

    // MARK: - Book Title Search

    /// Search for book metadata by title when no ISBN is available.
    /// Queries Open Library first, then Google Books as fallback.
    /// Returns nil if no result meets the title similarity threshold.
    public static func searchBookByTitle(_ title: String) async throws -> Reference? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let cacheKey = "book-title:\(normalized.lowercased())"
        if let cached = cachedReference(for: cacheKey) { return cached }

        if let ref = try? await searchOpenLibraryByTitle(normalized) {
            cacheReference(ref, for: cacheKey)
            return ref
        }

        if let ref = try? await searchGoogleBooksByTitle(normalized) {
            cacheReference(ref, for: cacheKey)
            return ref
        }

        return nil
    }

    private static func searchOpenLibraryByTitle(_ title: String) async throws -> Reference? {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://openlibrary.org/search.json?title=\(encoded)&limit=3&fields=key,title,author_name,first_publish_year,isbn,publisher,number_of_pages_median") else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]],
              let firstDoc = docs.first,
              let resultTitle = firstDoc["title"] as? String,
              bookTitleSimilarity(title, resultTitle) >= 0.5 else { return nil }

        // Prefer a full ISBN-based fetch for richer data
        if let isbns = firstDoc["isbn"] as? [String],
           let bestISBN = isbns.first(where: { $0.count == 13 }) ?? isbns.first(where: { $0.count == 10 }),
           let ref = try? await fetchFromOpenLibrary(isbn: bestISBN) {
            return ref
        }

        // Fallback: use search result fields directly
        let authors: [AuthorName] = {
            guard let names = firstDoc["author_name"] as? [String] else { return [] }
            return names.map { AuthorName.parse($0) }
        }()
        let year = firstDoc["first_publish_year"] as? Int
        let publisher = (firstDoc["publisher"] as? [String])?.first
        let numberOfPages = (firstDoc["number_of_pages_median"] as? Int).map(String.init)
        return Reference(
            title: resultTitle,
            authors: authors,
            year: year,
            referenceType: .book,
            publisher: publisher,
            numberOfPages: numberOfPages
        )
    }

    private static func searchGoogleBooksByTitle(_ title: String) async throws -> Reference? {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=intitle:\(encoded)&maxResults=1") else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let volumeInfo = first["volumeInfo"] as? [String: Any],
              let resultTitle = volumeInfo["title"] as? String,
              bookTitleSimilarity(title, resultTitle) >= 0.5 else { return nil }

        let authors: [AuthorName] = {
            guard let authorList = volumeInfo["authors"] as? [String] else { return [] }
            return authorList.map { AuthorName.parse($0) }
        }()
        let year: Int? = {
            guard let publishedDate = volumeInfo["publishedDate"] as? String else { return nil }
            return Int(publishedDate.prefix(4))
        }()
        let numberOfPages: String? = {
            guard let n = volumeInfo["pageCount"] as? Int else { return nil }
            return String(n)
        }()
        let isbn: String? = {
            guard let identifiers = volumeInfo["industryIdentifiers"] as? [[String: Any]] else { return nil }
            let isbn13 = identifiers.first(where: { $0["type"] as? String == "ISBN_13" })?["identifier"] as? String
            let isbn10 = identifiers.first(where: { $0["type"] as? String == "ISBN_10" })?["identifier"] as? String
            return isbn13 ?? isbn10
        }()
        return Reference(
            title: resultTitle,
            authors: authors,
            year: year,
            abstract: volumeInfo["description"] as? String,
            referenceType: .book,
            publisher: volumeInfo["publisher"] as? String,
            isbn: isbn,
            numberOfPages: numberOfPages
        )
    }

    /// Word-overlap Jaccard similarity between two titles (0–1).
    private static func bookTitleSimilarity(_ a: String, _ b: String) -> Double {
        let tokenize: (String) -> Set<String> = { s in
            Set(
                s.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .flatMap { $0.components(separatedBy: .punctuationCharacters) }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count > 1 }
            )
        }
        let wordsA = tokenize(a)
        let wordsB = tokenize(b)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let intersection = Double(wordsA.intersection(wordsB).count)
        let union = Double(wordsA.union(wordsB).count)
        return intersection / union
    }

    // MARK: - Unified Fetch

    /// Auto-detect identifier and fetch metadata.
    public static func fetch(from text: String) async throws -> Reference {
        let (ref, _) = try await fetchWithScrapedPDFURL(from: text)
        return ref
    }

    /// Auto-detect identifier and fetch metadata; also surfaces a scraped PDF URL
    /// when the identifier was a `.paperURL` and the host's landing page exposed
    /// `citation_pdf_url` (e.g. OpenReview, CVF, PMLR — papers without DOIs that
    /// would otherwise be unreachable for auto-download).
    ///
    /// Existing callers of `fetch(from:)` see no change; the CLI's `add --download-pdf`
    /// path uses this entry point so it can forward the URL to
    /// `PDFDownloadService.downloadPDF(overrideURL:)`.
    public static func fetchWithScrapedPDFURL(
        from text: String
    ) async throws -> (Reference, scrapedPDFURL: String?) {
        guard let identifier = extractIdentifier(from: text) else {
            throw FetchError.unrecognizedIdentifier
        }

        switch identifier {
        case .doi(let doi):
            return (try await fetchFromDOI(doi), nil)
        case .pmid(let pmid):
            return (try await fetchFromPMID(pmid), nil)
        case .arxiv(let id):
            return (try await fetchFromArXiv(id), nil)
        case .isbn(let isbn):
            return (try await fetchFromISBN(isbn), nil)
        case .pmcid(let pmcid):
            return (try await fetchFromPMCID(pmcid), nil)
        case .paperURL(let url):
            do {
                let outcome = try await PaperURLResolver.resolve(url)
                return (outcome.reference, outcome.scrapedPDFURL)
            } catch PaperURLResolver.ResolveError.noAuthorsAvailable {
                // The Mac app routes no-author through MetadataResolver's catch handler
                // which produces a .candidate envelope for user review. CLI / direct
                // callers of fetch() have no candidate channel — throw a typed error
                // so they don't silently save a no-author Reference (the schema accepts
                // empty authors as TEXT NOT NULL DEFAULT "", so nothing rejects it).
                throw FetchError.unsupported(
                    "Paper URL resolved but no authors were found. Review the page or paste a DOI."
                )
            } catch let error as PaperURLResolver.ResolveError {
                throw FetchError.unsupported(String(describing: error))
            } catch {
                throw FetchError.unsupported(error.localizedDescription)
            }
        }
    }

    // MARK: - CJK Author Name Correction

    /// Detect when CrossRef has swapped given/family for a CJK author name.
    /// CrossRef often returns `{"given":"Wu","family":"Haoyun"}` for Chinese authors
    /// when the correct mapping is `given:"Haoyun", family:"Wu"` (family name is the
    /// shorter, single-character-like segment for Chinese names romanized).
    private static func looksLikeCJKName(given: String, family: String) -> Bool {
        let g = given.trimmingCharacters(in: .whitespaces)
        let f = family.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty, !f.isEmpty else { return false }
        // Only apply heuristic when both parts are ASCII (romanized CJK).
        let bothAscii = g.allSatisfy { $0.isASCII } && f.allSatisfy { $0.isASCII }
        guard bothAscii else { return false }
        // Heuristic: Chinese family names romanized are very short (2-3 chars: Wu, Li, Liu, Gan).
        // If "given" is a single short word (≤3 chars) and "family" is strictly longer,
        // the fields are likely swapped. Conservative threshold to avoid false positives
        // on Western names like "Test"/"Author".
        let gWords = g.components(separatedBy: " ").filter { !$0.isEmpty }
        return gWords.count == 1 && g.count <= 3 && f.count > g.count
    }

    // MARK: - Errors

    public enum FetchError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case parseError
        case unrecognizedIdentifier
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .httpError(429): return "Rate-limited by the metadata source. Please wait a minute and try again."
            case .httpError(let code): return "HTTP error \(code)"
            case .parseError: return "Failed to parse response"
            case .unrecognizedIdentifier: return "Could not recognize identifier (DOI, arXiv, PMID, PMCID, or ISBN)"
            case .unsupported(let msg): return msg
            }
        }

        /// Whether this error is transient and may succeed on retry (5xx, timeout, rate-limited)
        var isRetryable: Bool {
            switch self {
            case .httpError(let code): return code >= 500 || code == 429
            default: return false
            }
        }
    }

    // MARK: - Retry Helper

    /// Execute an async operation with up to 3 retries and exponential backoff.
    /// Retries on 5xx HTTP errors, 429 rate-limiting, and network timeouts.
    private static func withRetry<T>(
        maxAttempts: Int = 3,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch let error as FetchError where error.isRetryable {
                lastError = error
                // For 429, use longer backoff
                let baseDelay: UInt64 = {
                    if case .httpError(429) = error { return 3_000_000_000 } // 3s base for rate-limit
                    return 1_000_000_000 // 1s base for server errors
                }()
                let delay = baseDelay * UInt64(1 << attempt) // exponential: 1s, 2s, 4s or 3s, 6s, 12s
                if attempt + 1 < maxAttempts {
                    try await Task.sleep(nanoseconds: delay)
                }
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                lastError = error
                let delay: UInt64 = 1_000_000_000 * UInt64(1 << attempt)
                if attempt + 1 < maxAttempts {
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError!
    }
}

// MARK: - arXiv Atom XML Parser

private class ArXivXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var result: Reference?

    private var currentElement = ""
    private var currentText = ""
    private var title = ""
    private var abstract = ""
    private var authors: [AuthorName] = []
    private var currentAuthor = ""
    private var published = ""
    private var doi: String?
    private var inEntry = false
    private var inAuthor = false

    init(data: Data) {
        self.data = data
    }

    func parse() -> Reference? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "entry" { inEntry = true }
        if elementName == "author" { inAuthor = true; currentAuthor = "" }
        if elementName == "link" && inEntry {
            if attributes["title"] == "doi", let href = attributes["href"] {
                // Extract DOI from URL like https://doi.org/10.xxxx/xxx
                if let range = href.range(of: "doi.org/") {
                    doi = String(href[range.upperBound...])
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inEntry {
            switch elementName {
            case "title":
                title = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            case "summary":
                abstract = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            case "name":
                if inAuthor { currentAuthor = text }
            case "author":
                inAuthor = false
                if !currentAuthor.isEmpty { authors.append(AuthorName.parse(currentAuthor)) }
            case "published":
                published = text
            case "entry":
                inEntry = false
                let year = Int(published.prefix(4))
                result = Reference(
                    title: title,
                    authors: authors,
                    year: year,
                    doi: doi,
                    url: nil,
                    abstract: abstract,
                    referenceType: .journalArticle
                )
            default:
                break
            }
        }

        currentElement = ""
    }
}
