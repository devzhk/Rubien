import Foundation

/// Parses a markdown file (Obsidian Web Clipper output or any plain note)
/// into a `Reference`. Pure — no I/O, no database, Linux-safe.
///
/// Frontmatter is optional enrichment. A leading `---` block is stripped
/// only when it is *plausible YAML mapping* (spec §1): every non-blank line
/// classifies as top-level key / indented list item / indented continuation
/// / comment, and at least one top-level key exists. Anything else — e.g.
/// thematic breaks, bullet lists — is body and preserved verbatim.
public enum MarkdownImporter {

    /// A parsed frontmatter value: scalar or list of scalars.
    enum FrontmatterValue {
        case scalar(String)
        case list([String])
    }

    public static func parse(_ content: String, filename: String?) -> Reference {
        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // Normalize line endings BEFORE splitting. `components(separatedBy: "\n")`
        // is grapheme-aware in swift-corelibs-foundation (Linux): "\r\n" is a
        // single grapheme cluster, so it won't split inside one — a CRLF file
        // would come back as ONE line and frontmatter detection
        // (`lines.first == "---"`) would silently fail (macOS splits on the
        // scalar, so this passed there but broke on Linux CI). Collapsing
        // CRLF/CR → LF first makes the split deterministic on every platform.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        let block = frontmatterBlock(in: lines)
        var bodyLines = block.map { Array(lines[($0.closingIndex + 1)...]) } ?? lines
        let fields = block?.fields ?? [:]

        // Title chain: frontmatter → first-line H1 (removed) → filename → "Untitled".
        var title = scalar(fields["title"])
        if title == nil,
           let idx = bodyLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           bodyLines[idx].hasPrefix("# ") {
            let heading = String(bodyLines[idx].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty {
                title = heading
                bodyLines.remove(at: idx)
            }
        }
        let resolvedTitle = title ?? filename ?? "Untitled"

        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return makeReference(title: resolvedTitle, fields: fields, body: body)
    }

    // MARK: - Frontmatter block

    private struct Block {
        var fields: [String: FrontmatterValue]
        var closingIndex: Int
    }

    /// `key:` / `key: value` at indentation 0. Key charset per spec §1.
    /// Extended `#/…/#` delimiters (not bare `/…/`) so this compiles under
    /// the package's Swift 5 language mode, where bare-slash regex literals
    /// are gated off; typed captures (`match.1`/`match.2`) are unchanged.
    private static let keyPattern = #/^([A-Za-z0-9_-]+):(.*)$/#

    /// Valid block-scalar headers: `|`, `>`, with optional indentation
    /// indicator and/or chomping modifier (`|-`, `>+`, `|2`, `>2-`, …).
    private static let blockScalarPattern = #/^[|>][0-9]*[+-]?$/#

    private static func frontmatterBlock(in lines: [String]) -> Block? {
        guard lines.first == "---" else { return nil }
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var fields: [String: FrontmatterValue] = [:]
        var openListKey: String?                 // key awaiting indented `- item` lines
        var inBlockScalar = false                // consuming `|`/`>` continuations
        var sawKey = false

        for raw in lines[1..<close] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }                       // comment

            let indented = raw.first == " " || raw.first == "\t"

            if indented {
                if inBlockScalar { continue }                            // scalar continuation
                if let key = openListKey, trimmed.hasPrefix("- ") || trimmed == "-" {
                    appendListItem(String(trimmed.dropFirst(1)), to: key, in: &fields)
                    continue
                }
                if sawKey { continue }                                   // nested map / continuation (or list body): opaque
                return nil                                               // indented line with no owner
            }

            // Unindented, non-key, non-comment content (including `- item`
            // bullets — spec requires list items to be indented) makes the
            // candidate implausible: preserve the whole document as body.
            inBlockScalar = false
            guard let match = raw.wholeMatch(of: keyPattern) else { return nil }
            sawKey = true
            openListKey = nil
            let key = String(match.1)
            let rawValue = String(match.2).trimmingCharacters(in: .whitespaces)

            if rawValue.isEmpty {
                openListKey = key                                        // may open a block list
                continue
            }
            if rawValue.wholeMatch(of: blockScalarPattern) != nil {
                inBlockScalar = true                                     // unsupported: consume, no metadata
                continue
            }
            if fields[key] == nil {
                fields[key] = .scalar(rawValue)
            }
        }

        guard sawKey else { return nil }
        return Block(fields: fields, closingIndex: close)
    }

    private static func appendListItem(
        _ raw: String, to key: String, in fields: inout [String: FrontmatterValue]
    ) {
        let item = raw.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        switch fields[key] {
        case .list(var items):
            items.append(item)
            fields[key] = .list(items)
        case .scalar, nil:
            fields[key] = .list([item])
        }
    }

    // MARK: - Scalar helpers

    static func scalar(_ value: FrontmatterValue?) -> String? {
        guard case .scalar(let raw)? = value else { return nil }
        let unquoted = unquote(raw)
        return unquoted.isEmpty ? nil : unquoted
    }

    /// Strip one layer of matching quotes. Double quotes unescape `\"` and
    /// `\\`; single quotes unescape `''`. Unknown escapes stay literal.
    static func unquote(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    // MARK: - Field mapping

    private static func makeReference(
        title: String, fields: [String: FrontmatterValue], body: String
    ) -> Reference {
        var url: String?
        var siteName: String?
        if let source = scalar(fields["source"]),
           let parsed = URL(string: source),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           parsed.host != nil {
            url = source
            siteName = parsed.host
        }

        let published = scalar(fields["published"]).flatMap(parseDateParts)
        let created = scalar(fields["created"]).flatMap(parseDateParts)
        let accessedDate = created.flatMap { parts -> String? in
            guard let m = parts.month, let d = parts.day else { return nil }
            return String(format: "%04d-%02d-%02d", parts.year, m, d)
        }

        return Reference(
            title: title,
            authors: authorList(fields["author"]),
            year: published?.year,
            url: url,
            abstract: scalar(fields["description"]),
            webContent: Reference.encodeWebContent(body, format: .markdown),
            siteName: siteName,
            referenceType: url != nil ? .webpage : .markdown,
            accessedDate: accessedDate,
            issuedMonth: published?.month,
            issuedDay: published?.day
        )
    }

    // MARK: Authors

    private static func authorList(_ value: FrontmatterValue?) -> [AuthorName] {
        let entries: [String]
        switch value {
        case .list(let items):
            entries = items.map(unquote)
        case .scalar(let raw):
            let unquoted = unquote(raw)
            if unquoted.hasPrefix("["), unquoted.hasSuffix("]") {
                entries = splitFlowList(String(unquoted.dropFirst().dropLast()))
            } else {
                entries = [unquoted]
            }
        case nil:
            return []
        }
        return entries
            .map(stripWikiLink)
            .filter { !$0.isEmpty }
            .map(AuthorName.parse)
    }

    /// `[[Jane Doe]]` → `Jane Doe` (Obsidian wiki-link wrapper).
    static func stripWikiLink(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[["), s.hasSuffix("]]"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Split a flow-list interior on top-level commas. Tracks quote, escape,
    /// AND bracket depth so `"Smith, John"` and `[a, b]` nested inside an
    /// element never split it.
    static func splitFlowList(_ interior: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        var depth = 0
        for ch in interior {
            if escaped { current.append(ch); escaped = false; continue }
            if let q = quote {
                if ch == "\\", q == "\"" { current.append(ch); escaped = true; continue }
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch; current.append(ch)
            case "[", "{":
                depth += 1; current.append(ch)
            case "]", "}":
                depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0:
                elements.append(current); current = ""
            default:
                current.append(ch)
            }
        }
        elements.append(current)
        return elements
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    // MARK: Dates

    /// Accepts `YYYY`, `YYYY-MM`, `YYYY-MM-DD` (calendar-validated, fixed
    /// Gregorian). A datetime suffix is allowed only after `T` or
    /// whitespace; any other trailing characters reject the value.
    static func parseDateParts(_ raw: String) -> (year: Int, month: Int?, day: Int?)? {
        let token = raw.split(whereSeparator: { $0 == "T" || $0.isWhitespace })
            .first.map(String.init) ?? ""
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        func int(_ s: Substring, width: Int) -> Int? {
            guard s.count == width, s.allSatisfy(\.isNumber) else { return nil }
            return Int(s)
        }
        switch parts.count {
        case 1:
            guard let y = int(parts[0], width: 4) else { return nil }
            return (y, nil, nil)
        case 2:
            guard let y = int(parts[0], width: 4), let m = int(parts[1], width: 2),
                  (1...12).contains(m) else { return nil }
            return (y, m, nil)
        case 3:
            guard let y = int(parts[0], width: 4), let m = int(parts[1], width: 2),
                  let d = int(parts[2], width: 2) else { return nil }
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = d
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard comps.isValidDate(in: calendar) else { return nil }
            return (y, m, d)
        default:
            return nil
        }
    }
}
