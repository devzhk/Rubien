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
        let lines = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }

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
                if openListKey != nil || sawKey { continue }             // nested map / continuation: opaque
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

    /// Task 6 replaces this stub with full field mapping.
    private static func makeReference(
        title: String, fields: [String: FrontmatterValue], body: String
    ) -> Reference {
        Reference(
            title: title,
            webContent: Reference.encodeWebContent(body, format: .markdown),
            referenceType: .markdown
        )
    }
}
