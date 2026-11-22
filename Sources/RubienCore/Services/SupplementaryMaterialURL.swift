import Foundation

/// Heuristic detector for "this external file is supplementary material of a
/// paper" (supplement, appendix, supporting information). Pure and portable:
/// it inspects only the URL and an optional display title, never the network.
///
/// Signals, any one of which is enough:
/// - Venue host/path shapes that only serve supplements (CVF `supplemental/`
///   directories, NeurIPS `-Supplemental` files, PMLR `-supp.pdf`). These are
///   recorded in `Docs/Supported-Paper-URLs.md`.
/// - Keywords in the URL's filename (`_supp`, `-supplementary`, `_ESM`, …).
/// - Keywords in the title, matched conservatively so ordinary paper titles
///   ("Supply chain…", "Suppressing…", "Appendicitis…", "Dietary supplement
///   use…", "Supplementary motor area…") do not qualify.
///
/// A positive result only changes presentation and suggestions; the user still
/// confirms every attach.
public enum SupplementaryMaterialURL {

    public static func looksSupplementary(url: URL, title: String?) -> Bool {
        if hostPatternLooksSupplementary(url) { return true }
        if filenameLooksSupplementary(url) { return true }
        if let title, titleLooksSupplementary(title) { return true }
        return false
    }

    // MARK: - Host / path patterns

    static func hostPatternLooksSupplementary(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let path = url.path
        switch host {
        case "openaccess.thecvf.com":
            return matches(path, #"^/content/[^/]+/supplemental/[^/]+"#)
        case "proceedings.neurips.cc":
            return matches(path, #"^/paper_files/paper/\d+/file/[^/]+-Supplemental[^/]*$"#)
        case "papers.nips.cc":
            return matches(path, #"^/paper/\d+/file/[^/]+-Supplemental[^/]*$"#)
        case "proceedings.mlr.press":
            return matches(path, #"^/v\d+/[^/]+/[^/]+-supp\.[A-Za-z0-9]+$"#)
        default:
            return false
        }
    }

    // MARK: - Filename keywords

    /// Lowercased filename tokens that mark a supplement on their own.
    private static let filenameKeywords: Set<String> = [
        "supplement", "supplements", "supplemental", "supplementary",
        "supp", "suppl", "appendix", "appendices",
    ]

    /// Uppercase-only tokens (case-sensitive): `SI`, `ESM` (Springer's
    /// `…_MOESM1_ESM.pdf`). Lowercase `esm`/`si` are ordinary words or model
    /// names, so they do not count on their own.
    private static let uppercaseKeywords: Set<String> = ["SI", "ESM"]

    static func filenameLooksSupplementary(_ url: URL) -> Bool {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return false }
        let decoded = last.removingPercentEncoding ?? last
        let stem = (decoded as NSString).deletingPathExtension
        let tokens = filenameTokens(stem)
        guard !tokens.isEmpty else { return false }
        let lowered = tokens.map { $0.lowercased() }

        for (index, token) in tokens.enumerated() where uppercaseKeywords.contains(token) {
            // `ESM-2_….pdf` names the protein model, not Springer's ESM suffix.
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token == "ESM", let next, next.allSatisfy(\.isNumber) { continue }
            return true
        }
        if lowered.contains(where: filenameKeywords.contains) { return true }
        // ACS-style supporting information: `<manuscript>_si_001.pdf`.
        for index in lowered.indices.dropLast()
        where lowered[index] == "si" && lowered[index + 1].allSatisfy(\.isNumber) {
            return true
        }
        for index in lowered.indices.dropLast() {
            let pair = (lowered[index], lowered[index + 1])
            if pair == ("supporting", "information") || pair == ("supporting", "info")
                || pair == ("extended", "data") {
                return true
            }
        }
        return false
    }

    /// Splits a filename stem on punctuation and camelCase boundaries:
    /// `SpeeDiff_SupplementaryMaterial` → `Spee Diff Supplementary Material`,
    /// `SIAppendix` → `SI Appendix`.
    static func filenameTokens(_ stem: String) -> [String] {
        var tokens: [String] = []
        for chunk in stem.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            var current = ""
            let chars = Array(chunk)
            for (i, ch) in chars.enumerated() {
                if !current.isEmpty, ch.isUppercase {
                    let prev = chars[i - 1]
                    let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                    if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                        tokens.append(current)
                        current = ""
                    }
                }
                current.append(ch)
            }
            if !current.isEmpty { tokens.append(current) }
        }
        return tokens
    }

    // MARK: - Title keywords

    /// Case-insensitive title patterns. Bare "supplement"/"supplementary" are
    /// deliberately not enough ("Dietary supplement use", "Supplementary motor
    /// area"); they need a material noun, a leading "for/to/of", or to stand as
    /// their own title segment (see `segmentPattern`).
    private static let titlePatterns: [String] = [
        #"\b(?:supplement(?:al|ary|s)?|suppl?\.?)\s+(?:materials?|information|info|data|files?|appendix|appendices|text|notes?|methods|figures?|tables?|videos?|documents?|sections?|results|proofs?)\b"#,
        #"^\s*(?:online\s+|electronic\s+)?supplement(?:al|ary)?\s+(?:to|for|of)\b"#,
        #"\bsupporting\s+information\b"#,
        #"\bextended\s+data\b"#,
        #"\bappendix\b"#,
        #"\bappendices\b"#,
    ]

    /// A title segment (between dashes, colons, bars, or brackets) made only of
    /// a supplement keyword: "SpeeDiff — Supplementary", "Paper (Supp.)".
    private static let segmentPattern =
        #"^(?:online\s+|electronic\s+)?(?:supplement(?:s|al|ary)?|suppl?\.?)(?:\s+(?:materials?|information|data|files?))?$"#

    /// Title separators that delimit a segment.
    private static let segmentSeparatorPattern = #"\s[—–-]\s|[—–:|()\[\]]"#

    static func titleLooksSupplementary(_ rawTitle: String) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }

        if matchesUppercaseWord(title) { return true }
        for pattern in titlePatterns where matches(title, pattern, caseInsensitive: true) {
            return true
        }
        guard let separator = regex(segmentSeparatorPattern, caseInsensitive: false) else {
            return false
        }
        let marked = separator.stringByReplacingMatches(
            in: title,
            range: NSRange(title.startIndex..., in: title),
            withTemplate: "\u{0}"
        )
        for segment in marked.split(separator: "\u{0}") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, matches(trimmed, segmentPattern, caseInsensitive: true) {
                return true
            }
        }
        return false
    }

    /// `SI` / `ESM` as uppercase whole words. Adjacent letters/digits or a
    /// hyphenated compound disqualify ("SIGGRAPH", "ESM2", "ESM-2", "SI-SNR").
    private static func matchesUppercaseWord(_ title: String) -> Bool {
        matches(
            title,
            #"(?<![A-Za-z0-9])(?<![A-Za-z0-9]-)(?:SI|ESM)(?![A-Za-z0-9])(?!-[A-Za-z0-9])"#
        )
    }

    // MARK: - Regex helpers

    private static let cache = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = "\(caseInsensitive ? "i" : "c")\u{0}\(pattern)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let compiled = try? NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        ) else { return nil }
        cache.setObject(compiled, forKey: key)
        return compiled
    }

    private static func matches(
        _ string: String,
        _ pattern: String,
        caseInsensitive: Bool = false
    ) -> Bool {
        guard let regex = regex(pattern, caseInsensitive: caseInsensitive) else { return false }
        return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
