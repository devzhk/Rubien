import Foundation
import GRDB

/// Pruned 2026-05 (v3) from 21 cases to 6; `markdown` added 2026-07 for
/// imported markdown notes. Type maps 1:1 to BibTeX entry types;
/// categorization beyond that goes to Tags or custom singleSelect
/// properties. The web reader opens for ANY type with stored `webContent`
/// (`Reference.canOpenWebReader`); `webpage` additionally gets URL-only
/// live mode.
public enum ReferenceType: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case journalArticle  = "Journal Article"
    case conferencePaper = "Conference Paper"
    case book            = "Book"
    case thesis          = "Thesis"
    case webpage         = "Web Page"
    case markdown        = "Markdown"
    case other           = "Other"

    public var icon: String {
        switch self {
        case .journalArticle:  return "doc.text"
        case .conferencePaper: return "person.3"
        case .book:            return "book.closed"
        case .thesis:          return "graduationcap"
        case .webpage:         return "globe"
        case .markdown:        return "doc.plaintext"
        case .other:           return "doc"
        }
    }

    /// Tolerant decode: a newer peer may write rawValues this binary doesn't
    /// know. Fall back to `.other` instead of throwing — Reference is embedded
    /// in persisted JSON (pending metadata-intake queue) and synced records.
    /// Encoding stays the synthesized rawValue encode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReferenceType(rawValue: raw) ?? .other
    }
}

public struct AuthorName: Codable, Hashable, Sendable {
    public var given: String
    public var family: String

    public init(given: String, family: String) {
        self.given = given
        self.family = family
    }

    /// "Given Family" display form
    public var displayName: String {
        given.isEmpty ? family : "\(given) \(family)"
    }

    /// "Family, G." short form
    public var shortName: String {
        let initials = given.components(separatedBy: " ")
            .map { String($0.prefix(1)) + "." }
            .joined(separator: " ")
        return initials.isEmpty ? family : "\(family), \(initials)"
    }

    /// Parse a free-text name like "John Smith" → AuthorName(given: "John", family: "Smith")
    /// Also handles "Smith, John" (comma-separated family-first).
    ///
    /// BibTeX brace-protected groups are honored: a comma/space inside `{…}` is not a
    /// given/family boundary (so `{International Brain Lab}` stays one corporate family
    /// name), and protection braces are stripped from the result.
    public static func parse(_ text: String) -> AuthorName {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // A comma at brace depth 0 separates "Family, Given" (BibTeX/CSL convention).
        let commaParts = splitRespectingBraces(trimmed, on: ",")
        if commaParts.count >= 2 {
            let family = strippedName(commaParts[0])
            let given = strippedName(commaParts[1...].joined(separator: ","))
            return AuthorName(given: given, family: family)
        }
        // No top-level comma: the last whitespace-delimited token (at depth 0) is the family.
        let parts = splitRespectingBraces(trimmed, on: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            let given = strippedName(parts.dropLast().joined(separator: " "))
            let family = strippedName(parts.last!)
            return AuthorName(given: given, family: family)
        }
        return AuthorName(given: "", family: strippedName(trimmed))
    }

    /// Parse a plain-text authors string into structured array.
    /// Handles separators: "and", ";", and smart comma handling.
    public static func parseList(_ text: String) -> [AuthorName] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // First split by ";" or " and ". Both detection AND splitting honor BibTeX
        // brace-protected groups, so a separator that appears only inside `{…}` (e.g. the
        // " and " in `{Barnes and Noble}`) neither selects a mode nor splits authors —
        // the two must agree or the chosen mode can yield a single un-split segment.
        // " and " detection is case-insensitive (matching the historical behavior) while
        // the split stays case-sensitive on the original text.
        let segments: [String]
        let semicolonParts = splitRespectingBraces(trimmed, on: ";")
        if semicolonParts.count > 1 {
            segments = semicolonParts.map { $0.trimmingCharacters(in: .whitespaces) }
        } else if splitRespectingBraces(trimmed.lowercased(), on: " and ").count > 1 {
            // Detection runs on the lowercased copy (case-insensitive) while the split stays
            // case-sensitive on the original; the two inputs differ, so this is not redundant.
            segments = splitRespectingBraces(trimmed, on: " and ").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            // Comma-separated: could be "Smith, John, Doe, Jane" (family-first pairs)
            // or "John Smith, Jane Doe" (full names). Detect by checking if first segment
            // looks like a single word (family name). Empty fields (leading/trailing/double
            // commas) are dropped to match the previous `split(separator:)` semantics so the
            // pair-grouping count is unaffected by a stray trailing comma.
            let parts = splitRespectingBraces(trimmed, on: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                // A "Family, Given" pair has a single-token family; a comma-separated list of
                // full names ("John Smith, Jane Doe") does not. The token check is brace-aware
                // so a protected multi-word family (`{de la Vega}`) still counts as one token.
                let looksLikeFamilyGivenPairs =
                    (parts.count == 2 && isSingleNameToken(parts[0])) ||
                    (parts.count.isMultiple(of: 2) &&
                        stride(from: 0, to: parts.count, by: 2).allSatisfy { isSingleNameToken(parts[$0]) })

                if looksLikeFamilyGivenPairs {
                    // Likely "Family, Given" pairs — group by twos
                    var result: [AuthorName] = []
                    var i = 0
                    while i < parts.count {
                        if i + 1 < parts.count {
                            result.append(AuthorName(
                                given: strippedName(parts[i + 1]),
                                family: strippedName(parts[i])
                            ))
                            i += 2
                        } else {
                            result.append(AuthorName(given: "", family: strippedName(parts[i])))
                            i += 1
                        }
                    }
                    return result.filter { !$0.family.isEmpty }
                }

                // Otherwise each comma-separated part is a full name
                segments = parts
            } else {
                segments = parts
            }
        }

        return segments
            .filter { !$0.isEmpty }
            .map { parse($0) }
            .filter { !$0.family.isEmpty }
    }

    /// Strip BibTeX protection braces from a name component and trim whitespace the braces
    /// may have padded (`{ Smith }` → `Smith`). Brace-free input is only trimmed.
    private static func strippedName(_ name: String) -> String {
        BibTeXBraces.strip(name).trimmingCharacters(in: .whitespaces)
    }

    /// True when `name` is a single name token — it has no space at BibTeX brace depth 0.
    /// A brace-protected multi-word group like `{de la Vega}` counts as one token because its
    /// inner spaces are protected, so `{de la Vega}, Maria` is recognized as a Family/Given
    /// pair rather than two separate authors.
    private static func isSingleNameToken(_ name: String) -> Bool {
        splitRespectingBraces(name, on: " ").count <= 1
    }

    /// Split `text` on `separator`, honoring it only at BibTeX brace depth 0 so a
    /// brace-protected group (`{Barnes and Noble}`) is never broken apart. Matches
    /// `components(separatedBy:)` semantics (empty fields preserved) so the callers'
    /// existing trim/filter passes behave identically. Escaped braces (`\{`, `\}`) do not
    /// affect depth.
    private static func splitRespectingBraces(_ text: String, on separator: String) -> [String] {
        // Fast path: no braces → plain split. Keeps every non-BibTeX caller byte-for-byte
        // identical to the previous behavior (and allocation-light).
        guard text.contains("{") else { return text.components(separatedBy: separator) }

        let sep = Array(separator)
        let chars = Array(text)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                // Escaped char (e.g. `\{`): copy both bytes verbatim, no depth change.
                current.append(c)
                current.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "{" {
                depth += 1; current.append(c); i += 1; continue
            }
            if c == "}" {
                if depth > 0 { depth -= 1 }
                current.append(c); i += 1; continue
            }
            if depth == 0, c == sep[0], i + sep.count <= chars.count, Array(chars[i ..< i + sep.count]) == sep {
                parts.append(current)
                current = ""
                i += sep.count
                continue
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return parts
    }
}

extension Array where Element == AuthorName {
    /// Display string for UI: "Given Family, Given Family"
    public var displayString: String {
        if isEmpty { return "" }
        return map { $0.displayName }.joined(separator: ", ")
    }

    /// Lowercased, whitespace-normalized author string for search/dedup.
    public var normalizedSearchString: String {
        map { $0.displayName.lowercased() }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reading status is now free-form: `Reference.readingStatus` is `String` and
/// the live option set is driven by the Status PropertyDefinition (seeded in
/// `AppDatabase.swift` and editable by users post-Phase-2). This namespace
/// exposes the 4 seeded built-in values as compile-time constants for use in
/// fixtures, defaults, and sync forward-compat fallbacks. The UI renders a
/// Notion-style colored chip per option (color comes from `SelectOption.color`),
/// so no icon glyph is needed.
public enum ReadingStatus {
    public static let unread  = "Unread"
    public static let reading = "Reading"
    public static let skimmed = "Skimmed"
    public static let read    = "Read"

    /// Values seeded by the v1 migration. The runtime option set is whatever
    /// lives in the Status PropertyDefinition's `optionsJSON` and may include
    /// user-added or user-removed values; consumers that need the *live* set
    /// should fetch it from `PropertyDefinition`, not this list. `reading` is
    /// kept as a compile-time constant for tests and forward-compat with
    /// pre-Phase-4 libraries that may still have it as a value.
    public static let builtIn: [String] = [unread, skimmed, read]
}

public struct Reference: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var title: String
    public var authors: [AuthorName]
    public var year: Int?
    public var journal: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var doi: String?
    public var url: String?
    public var abstract: String?
    public var dateAdded: Date
    public var dateModified: Date
    public var notes: String?
    public var webContent: String?
    public var siteName: String?
    public var favicon: String?
    public var referenceType: ReferenceType
    public var metadataSource: MetadataSource?
    public var verificationStatus: VerificationStatus
    public var acceptedByRuleID: String?
    public var recordKey: String?
    public var verificationSourceURL: String?
    public var evidenceBundleHash: String?
    public var verifiedAt: Date?
    public var reviewedBy: String?
    // MARK: - User workflow fields
    /// Free-form post-Phase-2: holds any string the Status PropertyDefinition
    /// has an option for. Built-in values are seeded as `ReadingStatus.unread`
    /// etc.; users can add/rename/delete options via the property manager.
    public var readingStatus: String

    // MARK: - Reader activity (v4)
    /// Most-recent reader-open timestamp, written by `AppDatabase.markReferenceRead`.
    /// Always advances (monotonic); `nil` until the user first opens a reader
    /// post-v4. Synced — recently-read state aggregates across devices.
    public var lastReadAt: Date?
    /// Approximate number of distinct reading sessions (10-minute debounce
    /// inside `markReferenceRead` keeps quick re-opens from inflating it).
    /// Synced. CloudKit conflicts are last-writer-wins, so a concurrent
    /// peer push may drop an increment; acceptable for a usage metric.
    public var readCount: Int

    // MARK: - Extended metadata (P0)
    public var publisher: String?
    public var publisherPlace: String?
    public var edition: String?
    /// JSON-encoded array of AuthorName: [{"given":"John","family":"Smith"}]
    public var editors: String?
    public var isbn: String?
    public var issn: String?
    /// ISO 8601 date string for "accessed" date
    public var accessedDate: String?
    public var issuedMonth: Int?
    public var issuedDay: Int?

    // MARK: - Extended metadata (P1)
    /// JSON-encoded array of AuthorName for translators
    public var translators: String?
    public var eventTitle: String?
    public var eventPlace: String?
    /// e.g. "Doctoral dissertation", "Master's thesis"
    public var genre: String?
    public var institution: String?
    /// Report/patent number
    public var number: String?
    public var collectionTitle: String?
    public var numberOfPages: String?

    // MARK: - Extended metadata (P2)
    /// ISO 639-1 language code
    public var language: String?
    public var pmid: String?
    public var pmcid: String?

    public init(
        id: Int64? = nil,
        title: String,
        authors: [AuthorName] = [],
        year: Int? = nil,
        journal: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        url: String? = nil,
        abstract: String? = nil,
        dateAdded: Date = Date(),
        dateModified: Date = Date(),
        notes: String? = nil,
        webContent: String? = nil,
        siteName: String? = nil,
        favicon: String? = nil,
        referenceType: ReferenceType = .journalArticle,
        metadataSource: MetadataSource? = nil,
        verificationStatus: VerificationStatus = .legacy,
        acceptedByRuleID: String? = nil,
        recordKey: String? = nil,
        verificationSourceURL: String? = nil,
        evidenceBundleHash: String? = nil,
        verifiedAt: Date? = nil,
        reviewedBy: String? = nil,
        readingStatus: String = ReadingStatus.unread,
        // Reader activity (v4)
        lastReadAt: Date? = nil,
        readCount: Int = 0,
        // Extended metadata (P0)
        publisher: String? = nil,
        publisherPlace: String? = nil,
        edition: String? = nil,
        editors: String? = nil,
        isbn: String? = nil,
        issn: String? = nil,
        accessedDate: String? = nil,
        issuedMonth: Int? = nil,
        issuedDay: Int? = nil,
        // Extended metadata (P1)
        translators: String? = nil,
        eventTitle: String? = nil,
        eventPlace: String? = nil,
        genre: String? = nil,
        institution: String? = nil,
        number: String? = nil,
        collectionTitle: String? = nil,
        numberOfPages: String? = nil,
        // Extended metadata (P2)
        language: String? = nil,
        pmid: String? = nil,
        pmcid: String? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.journal = journal
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.doi = doi
        self.url = url
        self.abstract = abstract
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.notes = notes
        self.webContent = webContent
        self.siteName = siteName
        self.favicon = favicon
        self.referenceType = referenceType
        self.metadataSource = metadataSource
        self.verificationStatus = verificationStatus
        self.acceptedByRuleID = acceptedByRuleID
        self.recordKey = recordKey
        self.verificationSourceURL = verificationSourceURL
        self.evidenceBundleHash = evidenceBundleHash
        self.verifiedAt = verifiedAt
        self.reviewedBy = reviewedBy
        self.readingStatus = readingStatus
        // Reader activity (v4)
        self.lastReadAt = lastReadAt
        self.readCount = readCount
        // Extended metadata (P0)
        self.publisher = publisher
        self.publisherPlace = publisherPlace
        self.edition = edition
        self.editors = editors
        self.isbn = isbn
        self.issn = issn
        self.accessedDate = accessedDate
        self.issuedMonth = issuedMonth
        self.issuedDay = issuedDay
        // Extended metadata (P1)
        self.translators = translators
        self.eventTitle = eventTitle
        self.eventPlace = eventPlace
        self.genre = genre
        self.institution = institution
        self.number = number
        self.collectionTitle = collectionTitle
        self.numberOfPages = numberOfPages
        // Extended metadata (P2)
        self.language = language
        self.pmid = pmid
        self.pmcid = pmcid
    }

    // MARK: - Parsed name helpers

    /// Decode editors JSON string into [AuthorName]
    public var parsedEditors: [AuthorName] {
        guard let json = editors, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AuthorName].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Decode translators JSON string into [AuthorName]
    public var parsedTranslators: [AuthorName] {
        guard let json = translators, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AuthorName].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Encode [AuthorName] to JSON string for storage
    public static func encodeNames(_ names: [AuthorName]) -> String? {
        guard !names.isEmpty,
              let data = try? JSONEncoder().encode(names),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}

extension Reference {
    /// True when an open-access PDF can plausibly be located for this reference.
    /// Today the download pipeline (`PDFDownloadService`) supports two sources:
    /// arXiv (matched via the abstract URL) and any DOI (looked up against
    /// OpenAlex's best-OA-location). Anything else is unreachable and callers
    /// should hide the download affordance.
    public var canDownloadPDF: Bool {
        if let doi, !doi.isEmpty { return true }
        if let url, url.range(of: "arxiv.org/abs/", options: .caseInsensitive) != nil { return true }
        return false
    }

    public static func == (lhs: Reference, rhs: Reference) -> Bool {
        guard lhs.id == rhs.id else { return false }
        guard lhs.title == rhs.title,
              lhs.authors == rhs.authors,
              lhs.year == rhs.year,
              lhs.journal == rhs.journal,
              lhs.volume == rhs.volume,
              lhs.issue == rhs.issue,
              lhs.pages == rhs.pages,
              lhs.doi == rhs.doi,
              lhs.url == rhs.url,
              lhs.abstract == rhs.abstract,
              lhs.dateAdded == rhs.dateAdded,
              lhs.dateModified == rhs.dateModified,
              lhs.notes == rhs.notes,
              lhs.webContent == rhs.webContent,
              lhs.siteName == rhs.siteName,
              lhs.favicon == rhs.favicon,
              lhs.referenceType == rhs.referenceType,
              lhs.metadataSource == rhs.metadataSource,
              lhs.verificationStatus == rhs.verificationStatus,
              lhs.acceptedByRuleID == rhs.acceptedByRuleID,
              lhs.recordKey == rhs.recordKey,
              lhs.verificationSourceURL == rhs.verificationSourceURL,
              lhs.evidenceBundleHash == rhs.evidenceBundleHash,
              lhs.verifiedAt == rhs.verifiedAt,
              lhs.reviewedBy == rhs.reviewedBy,
              lhs.readingStatus == rhs.readingStatus,
              lhs.lastReadAt == rhs.lastReadAt,
              lhs.readCount == rhs.readCount else {
            return false
        }

        guard lhs.publisher == rhs.publisher,
              lhs.publisherPlace == rhs.publisherPlace,
              lhs.edition == rhs.edition,
              lhs.editors == rhs.editors,
              lhs.isbn == rhs.isbn,
              lhs.issn == rhs.issn,
              lhs.accessedDate == rhs.accessedDate,
              lhs.issuedMonth == rhs.issuedMonth,
              lhs.issuedDay == rhs.issuedDay,
              lhs.translators == rhs.translators,
              lhs.eventTitle == rhs.eventTitle,
              lhs.eventPlace == rhs.eventPlace,
              lhs.genre == rhs.genre,
              lhs.institution == rhs.institution,
              lhs.number == rhs.number,
              lhs.collectionTitle == rhs.collectionTitle,
              lhs.numberOfPages == rhs.numberOfPages,
              lhs.language == rhs.language,
              lhs.pmid == rhs.pmid,
              lhs.pmcid == rhs.pmcid else {
            return false
        }

        return true
    }

    public func hash(into hasher: inout Hasher) {
        if let id {
            hasher.combine(id)
            return
        }

        hasher.combine(title)
        hasher.combine(authors)
        hasher.combine(year)
        hasher.combine(journal)
        hasher.combine(volume)
        hasher.combine(issue)
        hasher.combine(pages)
        hasher.combine(doi)
        hasher.combine(url)
        hasher.combine(abstract)
        hasher.combine(dateAdded)
        hasher.combine(dateModified)
        hasher.combine(notes)
        hasher.combine(webContent)
        hasher.combine(siteName)
        hasher.combine(favicon)
        hasher.combine(referenceType)
        hasher.combine(metadataSource)
        hasher.combine(verificationStatus)
        hasher.combine(acceptedByRuleID)
        hasher.combine(recordKey)
        hasher.combine(verificationSourceURL)
        hasher.combine(evidenceBundleHash)
        hasher.combine(verifiedAt)
        hasher.combine(reviewedBy)
        hasher.combine(readingStatus)
        hasher.combine(lastReadAt)
        hasher.combine(readCount)
        hasher.combine(publisher)
        hasher.combine(publisherPlace)
        hasher.combine(edition)
        hasher.combine(editors)
        hasher.combine(isbn)
        hasher.combine(issn)
        hasher.combine(accessedDate)
        hasher.combine(issuedMonth)
        hasher.combine(issuedDay)
        hasher.combine(translators)
        hasher.combine(eventTitle)
        hasher.combine(eventPlace)
        hasher.combine(genre)
        hasher.combine(institution)
        hasher.combine(number)
        hasher.combine(collectionTitle)
        hasher.combine(numberOfPages)
        hasher.combine(language)
        hasher.combine(pmid)
        hasher.combine(pmcid)
    }
}

extension Reference {
    public static let lightColumns: [any SQLSelectable] = [
        Columns.id,
        Columns.title,
        Columns.authors,
        Columns.year,
        Columns.journal,
        Columns.volume,
        Columns.issue,
        Columns.pages,
        Columns.doi,
        Columns.url,
        Columns.abstract,
        Columns.dateAdded,
        Columns.dateModified,
        Columns.notes,
        Columns.siteName,
        Columns.favicon,
        Columns.referenceType,
        Columns.metadataSource,
        Columns.verificationStatus,
        Columns.acceptedByRuleID,
        Columns.recordKey,
        Columns.verificationSourceURL,
        Columns.evidenceBundleHash,
        Columns.verifiedAt,
        Columns.reviewedBy,
        Columns.readingStatus,
        Columns.lastReadAt,
        Columns.readCount,
        Columns.publisher,
        Columns.publisherPlace,
        Columns.edition,
        Columns.editors,
        Columns.isbn,
        Columns.issn,
        Columns.accessedDate,
        Columns.issuedMonth,
        Columns.issuedDay,
        Columns.translators,
        Columns.eventTitle,
        Columns.eventPlace,
        Columns.genre,
        Columns.institution,
        Columns.number,
        Columns.collectionTitle,
        Columns.numberOfPages,
        Columns.language,
        Columns.pmid,
        Columns.pmcid,
    ]

    public var authorsNormalized: String {
        authors.normalizedSearchString
    }

    public enum WebContentFormat: String, Codable, Hashable {
        case markdown
        case html
    }

    public struct DecodedWebContent: Hashable {
        public var body: String
        public var format: WebContentFormat

        public init(body: String, format: WebContentFormat) {
            self.body = body
            self.format = format
        }
    }

    private static let htmlWebContentPrefix = "<!-- rubien:web-content:html -->"

    public static func encodeWebContent(_ body: String?, format: WebContentFormat) -> String? {
        guard let raw = body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        switch format {
        case .markdown:
            return raw
        case .html:
            return htmlWebContentPrefix + "\n" + raw
        }
    }

    public static func decodeWebContent(_ raw: String?) -> DecodedWebContent? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix(htmlWebContentPrefix) {
            let body = trimmed
                .dropFirst(htmlWebContentPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return DecodedWebContent(body: body, format: .html)
        }

        if looksLikeHTMLWebContent(trimmed) {
            return DecodedWebContent(body: trimmed, format: .html)
        }

        return DecodedWebContent(body: trimmed, format: .markdown)
    }

    public var decodedWebContent: DecodedWebContent? {
        Self.decodeWebContent(webContent)
    }

    public var canEnterFeedback: Bool {
        verificationStatus == .verifiedAuto || verificationStatus == .verifiedManual
    }

    public var canAutoFeedback: Bool {
        verificationStatus == .verifiedAuto
            && acceptedByRuleID?.rubien_nilIfBlank != nil
            && evidenceBundleHash?.rubien_nilIfBlank != nil
    }

    private static func looksLikeHTMLWebContent(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") {
            return true
        }
        let markers = [
            "<article", "<section", "<div", "<p", "<figure", "<img", "<blockquote",
            "<details", "<iframe", "<ul", "<ol", "<table", "<h1", "<h2", "<h3"
        ]
        let markerHits = markers.reduce(into: 0) { partialResult, marker in
            if lower.contains(marker) {
                partialResult += 1
            }
        }
        return markerHits >= 2 || (lower.hasPrefix("<") && lower.contains("</"))
    }

    /// 在线阅读可用的原文链接：优先 `url`，否则尝试 `siteName` / `journal`（剪藏模板常把链接写在 `source` 并落入 siteName）。
    public func resolvedWebReaderURLString() -> String? {
        for raw in [url, siteName, journal] {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { continue }
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased() else { continue }
            guard scheme == "http" || scheme == "https" else { continue }
            return s
        }
        return nil
    }

    /// 是否可打开内置网页阅读器：有剪藏正文即可打开（任意类型）；仅 `webpage` 类型才有仅凭链接的在线阅读。
    public var canOpenWebReader: Bool {
        let clip = webContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !clip.isEmpty { return true }
        guard referenceType == .webpage else { return false }
        let urlStr = resolvedWebReaderURLString()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !urlStr.isEmpty && URL(string: urlStr) != nil
    }

}

// MARK: - GRDB Record
extension Reference: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "reference"

    public static let referenceTagPivot = hasMany(ReferenceTag.self)
    public static let tags = hasMany(Tag.self, through: referenceTagPivot, using: ReferenceTag.tag)
    public var tags: QueryInterfaceRequest<Tag> {
        request(for: Reference.tags)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Custom row decoding: handles both legacy plain-text and JSON-array authors
    public init(row: Row) {
        id = row["id"]
        title = row["title"]

        // Authors: try JSON array first, fall back to legacy plain text
        if let jsonStr = row["authors"] as String?,
           let data = jsonStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AuthorName].self, from: data) {
            authors = decoded
        } else if let plain = row["authors"] as String? {
            authors = AuthorName.parseList(plain)
        } else {
            authors = []
        }

        year = row["year"]
        journal = row["journal"]
        volume = row["volume"]
        issue = row["issue"]
        pages = row["pages"]
        doi = row["doi"]
        url = row["url"]
        abstract = row["abstract"]
        dateAdded = row["dateAdded"]
        dateModified = row["dateModified"]
        notes = row["notes"]
        webContent = row["webContent"]
        siteName = row["siteName"]
        favicon = row["favicon"]
        // Tolerant decode: unknown rawValue (newer binary wrote this library) → .other,
        // mirroring ReferenceRecord's CKRecord fallback. The plain subscript would trap.
        let referenceTypeRaw: String? = row["referenceType"]
        referenceType = referenceTypeRaw.flatMap(ReferenceType.init(rawValue:)) ?? .other
        metadataSource = row["metadataSource"]
        verificationStatus = row["verificationStatus"] ?? .legacy
        acceptedByRuleID = row["acceptedByRuleID"]
        recordKey = row["recordKey"]
        verificationSourceURL = row["verificationSourceURL"]
        evidenceBundleHash = row["evidenceBundleHash"]
        verifiedAt = row["verifiedAt"]
        reviewedBy = row["reviewedBy"]
        readingStatus = row["readingStatus"] ?? ReadingStatus.unread

        // Reader activity (v4)
        lastReadAt = row["lastReadAt"]
        readCount = row["readCount"] ?? 0

        // Extended metadata (P0)
        publisher = row["publisher"]
        publisherPlace = row["publisherPlace"]
        edition = row["edition"]
        editors = row["editors"]
        isbn = row["isbn"]
        issn = row["issn"]
        accessedDate = row["accessedDate"]
        issuedMonth = row["issuedMonth"]
        issuedDay = row["issuedDay"]

        // Extended metadata (P1)
        translators = row["translators"]
        eventTitle = row["eventTitle"]
        eventPlace = row["eventPlace"]
        genre = row["genre"]
        institution = row["institution"]
        number = row["number"]
        collectionTitle = row["collectionTitle"]
        numberOfPages = row["numberOfPages"]

        // Extended metadata (P2)
        language = row["language"]
        pmid = row["pmid"]
        pmcid = row["pmcid"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["title"] = title
        // Encode authors as JSON string
        if let data = try? JSONEncoder().encode(authors),
           let json = String(data: data, encoding: .utf8) {
            container["authors"] = json
        } else {
            container["authors"] = ""
        }
        container["authorsNormalized"] = authorsNormalized
        container["year"] = year
        container["journal"] = journal
        container["volume"] = volume
        container["issue"] = issue
        container["pages"] = pages
        container["doi"] = doi
        container["url"] = url
        container["abstract"] = abstract
        container["dateAdded"] = dateAdded
        container["dateModified"] = dateModified
        container["notes"] = notes
        container["webContent"] = webContent
        container["siteName"] = siteName
        container["favicon"] = favicon
        container["referenceType"] = referenceType
        container["metadataSource"] = metadataSource
        container["verificationStatus"] = verificationStatus
        container["acceptedByRuleID"] = acceptedByRuleID
        container["recordKey"] = recordKey
        container["verificationSourceURL"] = verificationSourceURL
        container["evidenceBundleHash"] = evidenceBundleHash
        container["verifiedAt"] = verifiedAt
        container["reviewedBy"] = reviewedBy
        container["readingStatus"] = readingStatus

        // Reader activity (v4)
        container["lastReadAt"] = lastReadAt
        container["readCount"] = readCount

        // Extended metadata (P0)
        container["publisher"] = publisher
        container["publisherPlace"] = publisherPlace
        container["edition"] = edition
        container["editors"] = editors
        container["isbn"] = isbn
        container["issn"] = issn
        container["accessedDate"] = accessedDate
        container["issuedMonth"] = issuedMonth
        container["issuedDay"] = issuedDay

        // Extended metadata (P1)
        container["translators"] = translators
        container["eventTitle"] = eventTitle
        container["eventPlace"] = eventPlace
        container["genre"] = genre
        container["institution"] = institution
        container["number"] = number
        container["collectionTitle"] = collectionTitle
        container["numberOfPages"] = numberOfPages

        // Extended metadata (P2)
        container["language"] = language
        container["pmid"] = pmid
        container["pmcid"] = pmcid
    }

    public enum Columns: String, ColumnExpression {
        case id, title, authors, authorsNormalized, year, journal, volume, issue, pages
        case doi, url, abstract, dateAdded, dateModified
        case notes, webContent, siteName, favicon, referenceType, metadataSource
        case verificationStatus, acceptedByRuleID, recordKey, verificationSourceURL, evidenceBundleHash, verifiedAt, reviewedBy
        case readingStatus
        // Reader activity (v4)
        case lastReadAt, readCount
        // Extended metadata
        case publisher, publisherPlace, edition, editors, isbn, issn
        case accessedDate, issuedMonth, issuedDay
        case translators, eventTitle, eventPlace, genre, institution, number
        case collectionTitle, numberOfPages
        case language, pmid, pmcid
    }
}

public extension Reference {
    /// True iff this device has a *materialized* cache row for the reference.
    /// Use for "show a PDF chip" UI in sync (view-init) contexts. Equivalent
    /// to `db.pdfFilename(for: refId) != nil` but reads more cleanly at
    /// callsites.
    func hasPDFInCache(in db: AppDatabase) -> Bool {
        guard let id else { return false }
        return (try? db.pdfFilename(for: id)) != nil
    }
}
