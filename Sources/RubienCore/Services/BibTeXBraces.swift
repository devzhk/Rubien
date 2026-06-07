import Foundation

/// Curly-brace handling shared by the BibTeX importer and the author-name parser.
///
/// In BibTeX, inner `{…}` braces are capitalization-protection / grouping markers, not
/// literal text — `{EPFL}` means "keep EPFL's case", not "the word `{EPFL}`". They must be
/// removed before a value is shown to the user, while escaped literal braces (`\{`, `\}`)
/// are preserved. LaTeX command decoding (accents like `{\"o}`, `\textbf{…}`) is intentionally
/// out of scope — only the brace characters themselves are removed.
enum BibTeXBraces {
    /// Remove unescaped grouping/protection braces from `value`, preserving escaped literal
    /// braces (`\{`, `\}`). Content is kept intact (`{EPFL}-{Smart}` → `EPFL-Smart`).
    static func strip(_ value: String) -> String {
        // Fast path: most values have no braces, so skip the allocation below. This keeps
        // the bulk-import hot loop and every non-BibTeX name-parse caller allocation-free.
        guard value.contains("{") || value.contains("}") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        var escaped = false
        for ch in value {
            if escaped {
                // Preserve the escaped character verbatim, including `\{` and `\}`.
                result.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                result.append(ch)
                escaped = true
                continue
            }
            if ch == "{" || ch == "}" { continue }
            result.append(ch)
        }
        return result
    }
}
