import Foundation

/// A parsed BibTeX entry with any attachment paths extracted from the `file` field.
public struct BibTeXEntry: Equatable {
    public let reference: Reference
    /// Relative PDF paths accepted from the `file` field. Absolute paths are routed to
    /// `rejectedAttachmentPaths` so the caller can report them to the user.
    public let attachmentPaths: [String]
    /// Paths the parser saw but rejected (currently: absolute paths from linked-file Zotero libraries).
    public let rejectedAttachmentPaths: [String]

    public init(
        reference: Reference,
        attachmentPaths: [String],
        rejectedAttachmentPaths: [String] = []
    ) {
        self.reference = reference
        self.attachmentPaths = attachmentPaths
        self.rejectedAttachmentPaths = rejectedAttachmentPaths
    }
}

/// High-performance BibTeX parser for bulk import
public enum BibTeXImporter {
    /// Parse BibTeX string into Reference array — optimized for large files.
    /// Attachment paths from the `file` field are discarded; use `parseWithAttachments` to keep them.
    public static func parse(_ bibtex: String) -> [Reference] {
        parseWithAttachments(bibtex).map(\.reference)
    }

    /// Parse BibTeX string into entries that carry the `file`-field attachment paths alongside each Reference.
    public static func parseWithAttachments(_ bibtex: String) -> [BibTeXEntry] {
        var entries: [BibTeXEntry] = []
        entries.reserveCapacity(1000)

        let scanner = Scanner(string: bibtex)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            guard scanner.scanUpToString("@") != nil || scanner.scanString("@") != nil else {
                break
            }
            if scanner.scanString("@") == nil && scanner.isAtEnd { break }

            guard let entryType = scanner.scanUpToString("{")?.lowercased().trimmingCharacters(in: .whitespaces) else { continue }
            _ = scanner.scanString("{")
            _ = scanner.scanUpToString(",") // citation key
            _ = scanner.scanString(",")

            var fields: [String: String] = [:]
            var braceDepth = 1

            while braceDepth > 0 && !scanner.isAtEnd {
                // Skip whitespace
                _ = scanner.scanCharacters(from: .whitespacesAndNewlines)

                if scanner.scanString("}") != nil {
                    braceDepth -= 1
                    continue
                }

                guard let key = scanner.scanUpToString("=")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { break }
                _ = scanner.scanString("=")
                _ = scanner.scanCharacters(from: .whitespaces)

                var value = ""
                if scanner.scanString("{") != nil {
                    var depth = 1
                    let maxDepth = 50
                    var chars: [Character] = []
                    while depth > 0 && !scanner.isAtEnd {
                        if let c = scanner.scanCharacter() {
                            if c == "{" {
                                depth += 1
                                if depth > maxDepth {
                                    // Abort: excessively nested braces — skip to end of value
                                    while depth > 0 && !scanner.isAtEnd {
                                        if let skip = scanner.scanCharacter() {
                                            if skip == "{" { depth += 1 }
                                            else if skip == "}" { depth -= 1 }
                                        }
                                    }
                                    break
                                }
                                chars.append(c)
                            }
                            else if c == "}" { depth -= 1; if depth > 0 { chars.append(c) } }
                            else { chars.append(c) }
                        }
                    }
                    value = String(chars)
                } else if scanner.scanString("\"") != nil {
                    value = scanner.scanUpToString("\"") ?? ""
                    _ = scanner.scanString("\"")
                } else {
                    value = scanner.scanUpToString(",") ?? ""
                }

                fields[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = scanner.scanString(",")
            }

            // Strip BibTeX capitalization-protection braces (e.g. `{EPFL}` → `EPFL`) from
            // display-text fields so they don't leak into titles/journals/etc. The scanner
            // removes only the outermost `{…}` delimiter; inner protection braces survive
            // until here. `author`/`editor` are skipped so `AuthorName.parseList` still sees
            // brace-grouped names (a protected `and` must not be split); `file` is skipped
            // because attachment paths can contain literal braces.
            for key in Array(fields.keys) where key != "author" && key != "editor" && key != "file" {
                if let value = fields[key] {
                    fields[key] = BibTeXBraces.strip(value)
                }
            }

            let refType: ReferenceType = {
                switch entryType {
                case "article": return .journalArticle
                case "book": return .book
                // @inbook / @incollection collapsed into Book post-v3 prune.
                case "inbook", "incollection": return .book
                case "inproceedings", "conference": return .conferencePaper
                case "phdthesis", "mastersthesis": return .thesis
                // @misc / @online flow into Web Page so the in-app web reader
                // (which gates on .webpage) can pick them up.
                case "misc", "online": return .webpage
                // @techreport collapsed into Other post-v3 prune.
                default: return .other
                }
            }()

            // Parse month to integer if present
            let issuedMonth = parseMonth(fields["month"])

            // Parse editors (BibTeX uses "and" separator like authors)
            let editorsJson = Reference.encodeNames(AuthorName.parseList(fields["editor"] ?? ""))

            // Genre for thesis types
            let genre: String? = {
                switch entryType {
                case "phdthesis": return "Doctoral dissertation"
                case "mastersthesis": return "Master's thesis"
                default: return fields["type"]
                }
            }()

            let ref = Reference(
                title: fields["title"] ?? "Untitled",
                authors: AuthorName.parseList(fields["author"] ?? ""),
                year: fields["year"].flatMap { Int($0) },
                journal: fields["journal"] ?? fields["booktitle"],
                volume: fields["volume"],
                issue: fields["number"],
                pages: fields["pages"],
                doi: fields["doi"],
                url: fields["url"],
                abstract: fields["abstract"],
                referenceType: refType,
                // Extended metadata (P0)
                publisher: fields["publisher"],
                publisherPlace: fields["address"],
                edition: fields["edition"],
                editors: editorsJson,
                isbn: fields["isbn"],
                issn: fields["issn"],
                issuedMonth: issuedMonth,
                // Extended metadata (P1)
                eventTitle: (refType == .conferencePaper) ? fields["booktitle"] : nil,
                eventPlace: fields["location"],
                genre: genre,
                number: fields["number"],
                collectionTitle: fields["series"],
                numberOfPages: fields["numpages"],
                // Extended metadata (P2)
                language: fields["language"]
            )
            let (accepted, rejected) = parseFileFieldDetailed(fields["file"])
            entries.append(BibTeXEntry(
                reference: ref,
                attachmentPaths: accepted,
                rejectedAttachmentPaths: rejected
            ))
        }

        return entries
    }

    // MARK: - `file` field (Zotero attachment paths)

    /// Parse the Zotero-style `file` field value into accepted relative PDF paths.
    /// Absolute paths (linked-file libraries) and non-PDF attachments are rejected.
    internal static func parseFileField(_ raw: String?) -> [String] {
        parseFileFieldDetailed(raw).accepted
    }

    /// Detailed variant that returns both accepted relative PDF paths and absolute-path
    /// rejections (so the caller can surface linked-file attachments as "missing").
    ///
    /// Format: `description:relativePath:mimeType`, with backslash-escaped `:` / `;` / `\`.
    /// Multiple attachments are separated by *unescaped* `;`. Non-PDF attachments are
    /// filtered out entirely (not reported).
    internal static func parseFileFieldDetailed(
        _ raw: String?
    ) -> (accepted: [String], rejected: [String]) {
        guard let raw, !raw.isEmpty else { return ([], []) }
        var accepted: [String] = []
        var rejected: [String] = []
        for piece in splitUnescaped(raw, separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let segments = splitUnescaped(trimmed, separator: ":")
            guard segments.count >= 2 else { continue }
            let path = unescape(segments[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let mime: String = segments.count >= 3
                ? unescape(segments[2]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                : ""
            guard !path.isEmpty else { continue }
            let isPDF = mime == "application/pdf" || path.lowercased().hasSuffix(".pdf")
            guard isPDF else { continue }
            if isAbsolutePath(path) {
                rejected.append(path)
            } else {
                accepted.append(path)
            }
        }
        return (accepted, rejected)
    }

    private static func splitUnescaped(_ input: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escape = false
        for ch in input {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escape = true
                continue
            }
            if ch == separator {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    private static func unescape(_ input: String) -> String {
        // Zotero only escapes `:`, `;`, and `\`. Any other `\X` stays literal (keep the backslash).
        var result = ""
        result.reserveCapacity(input.count)
        var escape = false
        for ch in input {
            if escape {
                if ch == ":" || ch == ";" || ch == "\\" {
                    result.append(ch)
                } else {
                    result.append("\\")
                    result.append(ch)
                }
                escape = false
                continue
            }
            if ch == "\\" {
                escape = true
                continue
            }
            result.append(ch)
        }
        if escape { result.append("\\") }
        return result
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        // Windows-style drive letter: e.g. "C:\\Users\\..."
        if path.count >= 2 {
            let chars = Array(path)
            if chars[0].isLetter && chars[1] == ":" { return true }
        }
        return false
    }

    /// Parse BibTeX month field to integer (1-12)
    private static func parseMonth(_ raw: String?) -> Int? {
        guard let m = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !m.isEmpty else {
            return nil
        }
        // Numeric month
        if let n = Int(m), (1...12).contains(n) { return n }
        // BibTeX standard month abbreviations
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
                      "january": 1, "february": 2, "march": 3, "april": 4,
                      "june": 6, "july": 7, "august": 8, "september": 9,
                      "october": 10, "november": 11, "december": 12]
        return months[m]
    }
}
