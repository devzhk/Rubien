import Foundation

/// Compiled grep query. `literal` is matched with Foundation's Unicode
/// case-insensitive semantics; `regex` is Swift native `Regex` with
/// `.ignoresCase()` (inline `(?-i:…)` restores sensitivity).
public enum BodyTextQuery {
    case literal(String)
    case regex(Regex<AnyRegexOutput>)

    public static func compile(_ raw: String, isRegex: Bool) throws -> BodyTextQuery {
        guard isRegex else { return .literal(raw) }
        do {
            return .regex(try Regex(raw).ignoresCase())
        } catch {
            throw BodyTextQueryError.invalidRegex(String(describing: error))
        }
    }
}

public enum BodyTextQueryError: Error, CustomStringConvertible {
    case invalidRegex(String)
    public var description: String {
        switch self {
        case .invalidRegex(let detail): return "invalid-regex: \(detail)"
        }
    }
}

/// Pure text matching + snippet clustering shared by the PDF grep path
/// (which feeds it NORMALIZED page text) and the web grep path (which feeds
/// it the RAW decoded body so offsets stay `read text --start`-compatible).
/// All ranges are on `Character` (grapheme) boundaries by construction:
/// both matchers return `Range<String.Index>` into the input string and all
/// arithmetic uses `String.Index`, never UTF-16 offsets.
public enum BodyTextMatcher {

    // MARK: normalization (PDF path only — spec §6)

    public static func normalize(_ text: String) -> String {
        // CRLF first so the hyphenation join sees a single "\n" grapheme
        // (components/grapheme CRLF foot-gun, CLAUDE.md conventions).
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.precomposedStringWithCompatibilityMapping     // NFKC: ﬁ→fi, width variants
        s = s.replacingOccurrences(of: "\u{00AD}", with: "") // soft hyphens survive NFKC
        // Join end-of-line hyphenation: '-' + '\n' + lowercase → drop both.
        var joined = ""
        joined.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "-" {
                let nl = s.index(after: i)
                if nl < s.endIndex, s[nl] == "\n" {
                    let after = s.index(after: nl)
                    if after < s.endIndex, s[after].isLowercase {
                        i = after
                        continue
                    }
                }
            }
            joined.append(c)
            i = s.index(after: i)
        }
        // Collapse whitespace runs to single spaces; trim.
        var out = ""
        out.reserveCapacity(joined.count)
        var pendingSpace = false
        for ch in joined {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(ch)
            }
        }
        return out
    }

    // MARK: matching (spec §5 occurrence semantics)

    /// Non-overlapping, leftmost-first. Zero-width matches are discarded
    /// entirely (never produce entries or counts).
    public static func matches(in text: String, query: BodyTextQuery) -> [Range<String.Index>] {
        switch query {
        case .literal(let needle):
            guard !needle.isEmpty else { return [] }
            var result: [Range<String.Index>] = []
            var from = text.startIndex
            while from < text.endIndex,
                  let r = text.range(of: needle, options: [.caseInsensitive], range: from..<text.endIndex) {
                result.append(r)
                from = r.upperBound
            }
            return result
        case .regex(let regex):
            // matches(of:) enumerates non-overlapping leftmost matches over the
            // WHOLE string (so ^/$ anchor the full text, not scan restarts) and
            // advances internally past empty matches; we then discard zero-width.
            return text.matches(of: regex).map(\.range).filter { !$0.isEmpty }
        }
    }

    // MARK: snippet clustering (spec §5 merge rule)

    public struct Cluster: Sendable, Equatable {
        /// Grapheme offset of the cluster's FIRST match in the input string —
        /// for the web path this is the `read text --start` coordinate.
        public var start: Int
        public var matchCount: Int
        public var snippet: String
    }

    public static func clusters(
        in text: String,
        ranges: [Range<String.Index>],
        contextChars: Int
    ) -> [Cluster] {
        guard !ranges.isEmpty else { return [] }
        let half = max(1, contextChars / 2)

        // `first`/`end` bound the cluster's matched span (first match's start,
        // last match's end). Trimming may shave context OUTSIDE [first, end) but
        // must never cut INTO a match.
        struct Window { var lo: String.Index; var hi: String.Index; var first: String.Index; var end: String.Index; var count: Int }
        var windows: [Window] = []
        for r in ranges {
            let lo = text.index(r.lowerBound, offsetBy: -half, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(r.upperBound, offsetBy: half, limitedBy: text.endIndex) ?? text.endIndex
            if let last = windows.last, lo <= last.hi {
                windows[windows.count - 1].hi = max(last.hi, hi)
                windows[windows.count - 1].end = max(last.end, r.upperBound)
                windows[windows.count - 1].count += 1
            } else {
                windows.append(Window(lo: lo, hi: hi, first: r.lowerBound, end: r.upperBound, count: r.isEmpty ? 0 : 1))
            }
        }

        return windows.map { w in
            var lo = w.lo
            var hi = w.hi
            let trimmedLeading = lo > text.startIndex
            let trimmedTrailing = hi < text.endIndex
            // Trim context to whitespace boundaries so words aren't cut — but
            // never into the matched span: leading stops at the first match's
            // start (`w.first`), trailing at the last match's end (`w.end`).
            // Guarding trailing on `w.end` (not `lo`) keeps a multi-word or
            // whitespace-spanning match whole even when its trailing context is
            // one unbroken token.
            if trimmedLeading {
                while lo < w.first, !text[lo].isWhitespace { lo = text.index(after: lo) }
            }
            if trimmedTrailing {
                while hi > w.end, !text[text.index(before: hi)].isWhitespace {
                    hi = text.index(before: hi)
                }
            }
            var body = String(text[lo..<hi])
            // Display-only whitespace collapse (offsets are already captured).
            body = body.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                       .joined(separator: " ")
            let prefix = trimmedLeading ? "… " : ""
            let suffix = trimmedTrailing ? " …" : ""
            return Cluster(
                start: text.distance(from: text.startIndex, to: w.first),
                matchCount: w.count,
                snippet: prefix + body + suffix
            )
        }
    }
}
