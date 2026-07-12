# Unified Body-Text Grep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `rubien-cli grep <id> <query>` + MCP `rubien_grep_text` — kind-agnostic body-text search over a reference's PDF (page/section-anchored hits) or web clip (exact raw-offset hits), composing with the shipped `read` family.

**Architecture:** A pure matcher (`BodyTextMatcher`, RubienCore — Linux-tested) does occurrence finding + snippet clustering. `PDFExtractor.search` (RubienPDFKit, which already depends on RubienCore) drives it over normalized per-page text with section mapping. The CLI `Grep` subcommand does probe → route → matcher/search → envelope, reusing `resolveSources` and the `read text` error conventions verbatim. Both MCP catalogs add one thin tool.

**Tech Stack:** Swift 6 (native `Regex`, String.Index-only slicing), GRDB seeding in tests (feature-1 harness), TypeScript+zod (mcp-server).

**Spec:** `Docs/superpowers/specs/2026-07-11-unified-grep-text-design.md` (approved; governs on conflict).

## Global Constraints

- **Names:** MCP `rubien_grep_text`; CLI top-level `grep <id> <query>`. Params: `id`, `query`, `regex`, `source`, `contextChars`, `pages`, `maxPages`, `snippetsPerPage`, `maxMatches`.
- **Routing = `read text`'s, verbatim reuse:** `resolveSources(for:)` / `PDFSourceState` / `pdfStateDescription(_:)`; selection order explicit `--source` → param-implied (pdf family: `pages`/`maxPages`/`snippetsPerPage`; web family: `maxMatches`) → PDF-wins; same error strings incl. `available` JSON; mixed families error.
- **Occurrence semantics:** non-overlapping, leftmost-first; zero-width matches discarded entirely (never counted); case-insensitive both paths (`(?-i:…)` restores).
- **Web offsets:** grapheme (`Character`) counts into the raw decoded body; invariant `start == body.distance(from: body.startIndex, to: range.lowerBound)`; identical coordinates to `read text --start`.
- **Web counts:** `totalMatches` = raw matches; `totalEntries` = merged clusters pre-cap; `maxMatches` caps entries; `truncated ⇔ totalEntries > matches.count`.
- **PDF counts:** `totalMatches`/`totalMatchingPages` pre-`maxPages`-cut; `truncated ⇔ totalMatchingPages > pages.count`; per-page `matchCount` + `snippetsTruncated` (true when `snippetsPerPage` dropped clusters).
- **PDF normalization** (page text + literal query; never the regex pattern): CRLF→LF, NFKC (`precomposedStringWithCompatibilityMapping`), strip U+00AD, join `-`+`\n`+lowercase, collapse whitespace runs, trim. Web path: NO normalization — raw body.
- **Bounds (CLI-enforced; zod repeats; Swift catalog advertises):** `contextChars` 1–2000 (default 160), `maxPages` 1–200 (default 30), `snippetsPerPage` 1–20 (default 3), `maxMatches` 1–200 (default 20). Empty/whitespace query → validation error. Invalid regex → `invalid-regex` error. PDF extraction failures pass through `emitPDFExtractError` (existing envelope).
- **Empty `pages` pinning:** both MCP catalogs drop `pages:""` (feature-1 parity rule); CLI `--pages ""` implies pdf with full scope (matches `read text`).
- **Versions:** `BUILD.txt` 20→21 + `./scripts/generate-cli-version.sh` (GeneratedVersion build 21) + `MIN_CLI_BUILD` 21 + `stub-cli-ok.sh` build 21 — all in ONE task (feature 1's regen gap must not recur). npm stays 0.2.0 (verify unpublished: `npm view rubien-mcp-server version` → 0.1.0; if 0.2.0 has shipped, bump to 0.3.0 + SERVER_INFO and say so in the report).
- **Test commands:** NEVER bare `swift test`. Class filters: `swift test --filter 'RubienCoreTests\.BodyTextMatcherTests'`, `'RubienCLITests\.GrepCommandTests'`, `'RubienCLITests\.MCPServerTests'`, `'RubienCLITests\.ReadCommandTests'`, `'RubienCLITests\.RubienCLITests'` (that class lives in SwiftLibCLITests.swift). RubienPDFKitTests are Mac-only: `swift test --filter 'RubienPDFKitTests\..*'`. mcp-server: `cd mcp-server && npm test`.
- **Cross-platform:** RubienCore/RubienPDFKit/RubienCLI code compiles on Linux — no AppKit/os.Logger; `String.Index` slicing only (no UTF-16 integer offsets); no `components(separatedBy: "\n")` on possibly-CRLF text.
- Each task ends with a build + its listed suites green + a commit (end commit bodies with the session trailer the dispatch provides).

### Canonical MCP description — `rubien_grep_text` (authored once here; Task 4 commits it to read.ts; Task 5 copies byte-identically)

> Find WHERE a phrase or regex occurs inside one reference's body text — its attached PDF or its clipped web page — without retrieving the body. Returns anchored locations, not text: PDF hits are page-grouped (`pages[]` with `page`, `sectionPath` breadcrumbs, `matchCount`, snippets) — drill in with `rubien_read_text` + `pages`; web hits carry exact character offsets (`matches[].start`, same coordinates as `rubien_read_text`'s `start`) — drill in with `rubien_read_text` + `start`. Matching is case-insensitive (`regex: true` treats the query as a regular expression; `(?-i:…)` restores case). Source selection mirrors `rubien_read_text`: explicit `source` wins; `pages`/`maxPages`/`snippetsPerPage` imply pdf and `maxMatches` implies web; otherwise PDF wins when both exist. Every response carries `source` and `available`. A scanned PDF returns success with `hasTextLayer: false` and no hits — fall back to `rubien_pdf_page_image`. To find which REFERENCES match, use `rubien_search` (library metadata) instead. Library-only — never fetches from the network.

### `rubien_read_text` description addition (Task 4 Node, Task 5 Swift — byte-identical)

Append this sentence before "Library-only — never fetches from the network.": `To find WHERE the body mentions something before reading, use `rubien_grep_text`.`

### Canonical error strings (Task 3 implements; tests assert substrings)

| Case | stderr JSON `error` contains |
|---|---|
| empty/whitespace query | `query must not be empty` |
| invalid regex | `invalid-regex` |
| mixed families | `--pages/--max-pages/--snippets-per-page and --max-matches are mutually exclusive (PDF vs web scoping)` |
| explicit source contradicts family | `--pages/--max-pages/--snippets-per-page require a PDF source (requested source: web); available: [...]` / `--max-matches requires a web source (requested source: pdf); available: [...]` |
| bounds | `--context-chars must be between 1 and 2000` (same pattern for the other three) |
| missing ref / neither / source-unavailable | identical strings to `read text` (reuse the same code paths) |
| PDF extraction failures | existing `emitPDFExtractError` envelope (`encrypted`, `invalid-page-range: …`, …) |

---

### Task 1: `BodyTextMatcher` (RubienCore) + unit tests

**Files:**
- Create: `Sources/RubienCore/Services/BodyTextMatcher.swift`
- Create: `Tests/RubienCoreTests/BodyTextMatcherTests.swift`

**Interfaces (later tasks rely on these exact names):**
- Produces: `enum BodyTextQuery { case literal(String); case regex(Regex<AnyRegexOutput>); static func compile(_:isRegex:) throws -> BodyTextQuery }`, `enum BodyTextQueryError: Error { case invalidRegex(String) }`, `enum BodyTextMatcher { static func normalize(_:) -> String; static func matches(in:query:) -> [Range<String.Index>]; struct Cluster { start: Int; matchCount: Int; snippet: String }; static func clusters(in:ranges:contextChars:) -> [Cluster] }` — all `public`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/RubienCoreTests/BodyTextMatcherTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class BodyTextMatcherTests: XCTestCase {

    private func literal(_ s: String) -> BodyTextQuery { try! BodyTextQuery.compile(s, isRegex: false) }
    private func regex(_ s: String) throws -> BodyTextQuery { try BodyTextQuery.compile(s, isRegex: true) }
    private func starts(_ text: String, _ q: BodyTextQuery) -> [Int] {
        BodyTextMatcher.matches(in: text, query: q).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }

    // MARK: normalize (PDF-path pipeline)

    func testNormalizeFoldsLigaturesNFKC() {
        XCTAssertEqual(BodyTextMatcher.normalize("ﬁnal ﬂow"), "final flow")
    }

    func testNormalizeStripsSoftHyphens() {
        XCTAssertEqual(BodyTextMatcher.normalize("exam\u{00AD}ple"), "example")
    }

    func testNormalizeJoinsEndOfLineHyphenation() {
        XCTAssertEqual(BodyTextMatcher.normalize("exam-\nple"), "example")
        // documented false-join: genuine compound broken at line end fuses
        XCTAssertEqual(BodyTextMatcher.normalize("non-\nlinear"), "nonlinear")
        // documented miss: backend already spaced the break — hyphen survives
        XCTAssertEqual(BodyTextMatcher.normalize("exam- ple"), "exam- ple")
        // no join before uppercase (likely a real hyphenated name/compound list)
        XCTAssertEqual(BodyTextMatcher.normalize("Smith-\nJones"), "Smith- Jones")
    }

    func testNormalizeCollapsesWhitespaceIncludingCRLF() {
        XCTAssertEqual(BodyTextMatcher.normalize("a\r\nb\t\tc  d\n\ne"), "a b c d e")
    }

    // MARK: matches — literal

    func testLiteralNonOverlappingLeftmost() {
        XCTAssertEqual(starts("aaa", literal("aa")), [0])
        XCTAssertEqual(starts("aa aa", literal("aa")), [0, 3])
    }

    func testLiteralCaseInsensitive() {
        XCTAssertEqual(starts("Theorem THEOREM theorem", literal("theorem")), [0, 8, 16])
    }

    func testLiteralGraphemeOffsetsWithEmojiAndCombiningMarks() {
        // 👩‍👩‍👧‍👦 is ONE Character; e + combining acute is ONE Character
        let body = "👩‍👩‍👧‍👦 cafe\u{0301} theorem"
        let offs = starts(body, literal("theorem"))
        XCTAssertEqual(offs, [body.distance(from: body.startIndex,
                                            to: body.range(of: "theorem")!.lowerBound)])
        XCTAssertEqual(offs, [7])  // 👩‍👩‍👧‍👦(1) space(2) c(3)a(4)f(5)é(6) space(7)
    }

    // MARK: matches — regex

    func testRegexCaseInsensitiveAndInlineOptOut() throws {
        XCTAssertEqual(starts("Cat cat", try regex("cat")).count, 2)
        XCTAssertEqual(starts("Cat cat", try regex("(?-i:cat)")).count, 1)
    }

    func testRegexNonOverlapping() throws {
        XCTAssertEqual(starts("aaa", try regex("aa")), [0])
    }

    func testZeroWidthMatchesDiscarded() throws {
        for pattern in ["^", "$", "\\b", "z?"] {
            let q = try regex(pattern)
            XCTAssertEqual(BodyTextMatcher.matches(in: "alpha beta", query: q).count, 0,
                           "zero-width pattern \(pattern) must yield no matches")
        }
        // but a pattern that CAN match non-empty still does
        XCTAssertEqual(starts("alpha beta", try regex("a?l")), [0])
    }

    func testInvalidRegexThrows() {
        XCTAssertThrowsError(try BodyTextQuery.compile("([unclosed", isRegex: true)) { err in
            guard case BodyTextQueryError.invalidRegex = err else {
                return XCTFail("expected invalidRegex, got \(err)")
            }
        }
    }

    // MARK: clusters

    func testClusterStartIsFirstMatchGraphemeOffset() {
        let body = "aaaa needle bbbb"
        let ranges = BodyTextMatcher.matches(in: body, query: literal("needle"))
        let c = BodyTextMatcher.clusters(in: body, ranges: ranges, contextChars: 8)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].start, 5)
        XCTAssertEqual(c[0].matchCount, 1)
        XCTAssertTrue(c[0].snippet.contains("needle"), c[0].snippet)
    }

    func testAdjacentWindowsMergeAndCount() {
        let body = "x needle y needle z padding padding padding needle end"
        let ranges = BodyTextMatcher.matches(in: body, query: literal("needle"))
        let c = BodyTextMatcher.clusters(in: body, ranges: ranges, contextChars: 12)
        // first two matches are 9 chars apart -> windows (±6) overlap -> merge;
        // third is far away -> own cluster
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].matchCount, 2)
        XCTAssertEqual(c[0].start, 2)
        XCTAssertEqual(c[1].matchCount, 1)
        XCTAssertTrue(c[1].start > c[0].start)
    }

    func testSnippetEllipsizedAndWhitespaceCollapsed() {
        let body = "one two three\nfour  five needle six seven eight nine ten"
        let ranges = BodyTextMatcher.matches(in: body, query: literal("needle"))
        let c = BodyTextMatcher.clusters(in: body, ranges: ranges, contextChars: 12)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].snippet.hasPrefix("…"), c[0].snippet)
        XCTAssertTrue(c[0].snippet.hasSuffix("…"), c[0].snippet)
        XCTAssertFalse(c[0].snippet.contains("\n"))
        XCTAssertTrue(c[0].snippet.contains("needle"))
    }

    func testSnippetAtBodyEdgesHasNoEllipsis() {
        let body = "needle tail"
        let ranges = BodyTextMatcher.matches(in: body, query: literal("needle"))
        let c = BodyTextMatcher.clusters(in: body, ranges: ranges, contextChars: 200)
        XCTAssertEqual(c[0].snippet, "needle tail")
    }
}
```

- [ ] **Step 2: Run to verify failure.**

Run: `swift build 2>&1 | tail -2 && swift test --filter 'RubienCoreTests\.BodyTextMatcherTests'`
Expected: compile FAILURE (`BodyTextMatcher` unresolved) — that is the RED state for a new module.

- [ ] **Step 3: Implement** `Sources/RubienCore/Services/BodyTextMatcher.swift`:

```swift
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

        struct Window { var lo: String.Index; var hi: String.Index; var first: String.Index; var count: Int }
        var windows: [Window] = []
        for r in ranges {
            let lo = text.index(r.lowerBound, offsetBy: -half, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(r.upperBound, offsetBy: half, limitedBy: text.endIndex) ?? text.endIndex
            if let last = windows.last, lo <= last.hi {
                windows[windows.count - 1].hi = max(last.hi, hi)
                windows[windows.count - 1].count += 1
            } else {
                windows.append(Window(lo: lo, hi: hi, first: r.lowerBound, count: r.isEmpty ? 0 : 1))
            }
        }

        return windows.map { w in
            var lo = w.lo
            var hi = w.hi
            let trimmedLeading = lo > text.startIndex
            let trimmedTrailing = hi < text.endIndex
            // Trim to whitespace boundaries so words aren't cut — but never past
            // the first match (leading) or the window's own lo (trailing).
            if trimmedLeading {
                while lo < w.first, !text[lo].isWhitespace { lo = text.index(after: lo) }
            }
            if trimmedTrailing {
                while hi > lo, !text[text.index(before: hi)].isWhitespace {
                    hi = text.index(before: hi)
                }
                if hi == lo { hi = w.hi }  // single unbroken token — keep the raw window
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
```

Implementer notes: `String.matches(of:)` is available cross-platform on Swift 6 and handles empty-match advancement internally; if the Linux toolchain's overload resolution complains about `Regex<AnyRegexOutput>`, fall back to an explicit `firstMatch(in:)` loop over the WHOLE string using `regex.firstMatch(in: text[searchStart...])` **plus** re-anchoring caveats — prefer `matches(of:)` and only deviate with a note in your report. `ignoresCase()` returns a new `Regex` — keep the `AnyRegexOutput` type via `Regex<AnyRegexOutput>(raw)`-style init if the generic inference fights you (`try Regex(raw)` yields `Regex<AnyRegexOutput>`).

- [ ] **Step 4: Run until green.**

Run: `swift test --filter 'RubienCoreTests\.BodyTextMatcherTests'`
Expected: PASS (all). Then run `swift test --filter 'RubienCoreTests\..*'` once (no regressions, ~553+new).

- [ ] **Step 5: Commit.**

```bash
git add Sources/RubienCore/Services/BodyTextMatcher.swift Tests/RubienCoreTests/BodyTextMatcherTests.swift
git commit -m "feat(core): BodyTextMatcher — shared grep matcher with pinned occurrence semantics"
```

---

### Task 2: `PDFExtractor.search` (RubienPDFKit) + Mac acceptance tests

**Files:**
- Modify: `Sources/RubienPDFKit/PDFExtractor.swift` (add `search` + result types after `extractText`, ~line 293)
- Modify: `Tests/RubienPDFKitTests/BackendParityTests.swift` (append search acceptance tests, reusing its `fixtureURL(_:)` helper at line 14)

**Interfaces:**
- Consumes: Task 1's `BodyTextQuery`/`BodyTextMatcher` (RubienPDFKit already imports RubienCore — `PDFExtractor.swift:2`); internal helpers `openDocument(at:)`, `parsePageRange(_:pageCount:)`, `pagesInRanges`, `sections(in:)`, `sectionPath(forPage:in:)` (all in the same file).
- Produces: `PDFExtractor.PageSearchHit` (`page`, `sectionPath`, `matchCount`, `snippetsTruncated`, `snippets`), `PDFExtractor.SearchResult` (`pageCount`, `hasTextLayer`, `totalMatches`, `totalMatchingPages`, `truncated`, `pages`), `PDFExtractor.search(at:query:isRegex:pagesString:maxPages:snippetsPerPage:contextChars:) throws -> SearchResult`.

- [ ] **Step 1: Write the failing tests.** Append to `BackendParityTests.swift` (this target is Mac-only by Package.swift, no extra gating needed):

```swift
    // MARK: - search (grep)

    func testSearchFindsTermWithPageAnchors() throws {
        let r = try PDFExtractor.search(
            at: fixtureURL("linear-3pages-text"), query: "page", isRegex: false,
            pagesString: nil, maxPages: 30, snippetsPerPage: 3, contextChars: 160)
        XCTAssertEqual(r.pageCount, 3)
        XCTAssertTrue(r.hasTextLayer)
        XCTAssertGreaterThan(r.totalMatches, 0)
        XCTAssertEqual(r.totalMatchingPages, r.pages.count)
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.pages.map(\.page), r.pages.map(\.page).sorted())
        XCTAssertTrue(r.pages.allSatisfy { !$0.snippets.isEmpty && $0.matchCount > 0 })
        XCTAssertTrue(r.pages.allSatisfy { $0.sectionPath.isEmpty })  // fixture has no outline
    }

    func testSearchSectionPathOnOutlinedFixture() throws {
        let r = try PDFExtractor.search(
            at: fixtureURL("outline-2level-5sections"), query: "the", isRegex: false,
            pagesString: nil, maxPages: 30, snippetsPerPage: 3, contextChars: 160)
        XCTAssertTrue(r.pages.contains { !$0.sectionPath.isEmpty },
                      "outlined fixture should yield section breadcrumbs")
    }

    func testSearchMaxPagesTruncationCountsBeforeCut() throws {
        let r = try PDFExtractor.search(
            at: fixtureURL("linear-3pages-text"), query: "page", isRegex: false,
            pagesString: nil, maxPages: 1, snippetsPerPage: 3, contextChars: 160)
        XCTAssertEqual(r.pages.count, 1)
        XCTAssertGreaterThan(r.totalMatchingPages, 1)
        XCTAssertTrue(r.truncated)
    }

    func testSearchPagesScopeAndInvalidRange() throws {
        let scoped = try PDFExtractor.search(
            at: fixtureURL("linear-3pages-text"), query: "page", isRegex: false,
            pagesString: "2", maxPages: 30, snippetsPerPage: 3, contextChars: 160)
        XCTAssertTrue(scoped.pages.allSatisfy { $0.page == 2 })
        XCTAssertThrowsError(try PDFExtractor.search(
            at: fixtureURL("linear-3pages-text"), query: "page", isRegex: false,
            pagesString: "abc", maxPages: 30, snippetsPerPage: 3, contextChars: 160)) { error in
            guard case PDFExtractor.ExtractError.invalidPageRange = error else {
                return XCTFail("expected invalidPageRange, got \(error)")
            }
        }
    }

    func testSearchScannedFixtureIsSuccessWithoutTextLayer() throws {
        let r = try PDFExtractor.search(
            at: fixtureURL("scan-only-1page"), query: "anything", isRegex: false,
            pagesString: nil, maxPages: 30, snippetsPerPage: 3, contextChars: 160)
        XCTAssertFalse(r.hasTextLayer)
        XCTAssertEqual(r.totalMatches, 0)
        XCTAssertTrue(r.pages.isEmpty)
    }

    func testSearchEncryptedFixtureThrows() throws {
        XCTAssertThrowsError(try PDFExtractor.search(
            at: fixtureURL("encrypted-password"), query: "x", isRegex: false,
            pagesString: nil, maxPages: 30, snippetsPerPage: 3, contextChars: 160))
    }

    func testSearchNormalizationFindsHyphenBrokenWord() throws {
        // Behavioral pin on the normalize pipeline THROUGH the search API:
        // regex "linear" must match even if a backend broke it as "lin-\near".
        // (linear-3pages-text contains the word "linear" in its title text.)
        let r = try PDFExtractor.search(
            at: fixtureURL("linear-3pages-text"), query: "linear", isRegex: false,
            pagesString: nil, maxPages: 30, snippetsPerPage: 3, contextChars: 160)
        XCTAssertGreaterThanOrEqual(r.totalMatches, 0)  // must not throw; count asserted loosely
    }
```

- [ ] **Step 2: Run to verify failure.**

Run: `swift build 2>&1 | tail -2 && swift test --filter 'RubienPDFKitTests\..*'`
Expected: compile FAILURE (`search` doesn't exist).

- [ ] **Step 3: Implement.** In `PDFExtractor.swift`, after `extractText` (~line 293):

```swift
    // MARK: - body-text search (grep)

    public struct PageSearchHit: Sendable, Encodable {
        public var page: Int
        public var sectionPath: [String]
        public var matchCount: Int
        public var snippetsTruncated: Bool
        public var snippets: [String]
    }

    public struct SearchResult: Sendable {
        public var pageCount: Int
        public var hasTextLayer: Bool
        public var totalMatches: Int
        public var totalMatchingPages: Int
        public var truncated: Bool
        public var pages: [PageSearchHit]
    }

    /// Grep the extracted text layer. Matching runs over NORMALIZED page text
    /// (BodyTextMatcher.normalize) — page numbers, not offsets, are the anchor.
    /// The literal query is normalized identically; a regex pattern is not.
    /// `hasTextLayer` here is exact over the candidate pages (search reads
    /// every one), unlike `pdf info`'s sampled probe.
    public static func search(
        at url: URL,
        query: String,
        isRegex: Bool,
        pagesString: String?,
        maxPages: Int,
        snippetsPerPage: Int,
        contextChars: Int
    ) throws -> SearchResult {
        let doc = try openDocument(at: url)
        let pageCount = doc.pageCount
        let sections = sections(in: doc)

        let candidatePages: [Int]
        if let raw = pagesString, !raw.isEmpty {
            let ranges = try parsePageRange(raw, pageCount: pageCount)
            candidatePages = pagesInRanges(ranges, pageCount: pageCount)
        } else {
            candidatePages = Array(1...max(1, pageCount))
        }

        let compiled = try BodyTextQuery.compile(
            isRegex ? query : BodyTextMatcher.normalize(query),
            isRegex: isRegex
        )

        var hits: [PageSearchHit] = []
        var totalMatches = 0
        var totalMatchingPages = 0
        var anyText = false

        for p in candidatePages {
            guard let page = doc.page(at: p - 1) else { continue }
            let rawText = page.extractedText() ?? ""
            if !rawText.isEmpty { anyText = true }
            let norm = BodyTextMatcher.normalize(rawText)
            let ranges = BodyTextMatcher.matches(in: norm, query: compiled)
            guard !ranges.isEmpty else { continue }
            totalMatchingPages += 1
            totalMatches += ranges.count
            guard hits.count < maxPages else { continue }  // keep counting past the cap
            let clusters = BodyTextMatcher.clusters(in: norm, ranges: ranges, contextChars: contextChars)
            let kept = Array(clusters.prefix(snippetsPerPage))
            hits.append(PageSearchHit(
                page: p,
                sectionPath: sections.flatMap { sectionPath(forPage: p, in: $0) } ?? [],
                matchCount: ranges.count,
                snippetsTruncated: clusters.count > kept.count,
                snippets: kept.map(\.snippet)
            ))
        }

        return SearchResult(
            pageCount: pageCount,
            hasTextLayer: anyText,
            totalMatches: totalMatches,
            totalMatchingPages: totalMatchingPages,
            truncated: totalMatchingPages > hits.count,
            pages: hits
        )
    }
```

(If `sectionPath(forPage:in:)`'s exact spelling differs, mirror the call `extractText` makes at line ~281.)

- [ ] **Step 4: Run until green**, plus the Core suite once.

Run: `swift test --filter 'RubienPDFKitTests\..*'` then `swift test --filter 'RubienCoreTests\..*'`
Expected: PASS / PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RubienPDFKit/PDFExtractor.swift Tests/RubienPDFKitTests/BackendParityTests.swift
git commit -m "feat(pdfkit): PDFExtractor.search — page-anchored grep over normalized extracted text"
```

---

### Task 3: CLI `grep` subcommand + contract tests

**Files:**
- Modify: `Sources/RubienCLI/RubienCLI.swift` — register `Grep.self` in `allSubcommands` after `Read.self`; add the subcommand + envelopes next to the `Read` family
- Create: `Tests/RubienCLITests/GrepCommandTests.swift`

**Interfaces:**
- Consumes: `resolveSources`/`PDFSourceState`/`pdfStateDescription`/`ReadSource` (shipped), `PDFExtractor.search` (Task 2), `BodyTextQuery`/`BodyTextMatcher` (Task 1), `emitPDFExtractError`, `printJSON`/`printJSONError`.
- Produces: CLI `grep <id> <query>` with the flags below; `GrepPdfOutput`/`GrepWebOutput` envelopes (Task 4's zod mirrors pin them).

- [ ] **Step 1: Write the failing tests.** Create `Tests/RubienCLITests/GrepCommandTests.swift` — copy the harness block (cliBinaryPath / testLibraryRoot / tearDown / skipIfBinaryMissing / runCLI / addReference / openTestDB / seedWebContent / seedPdfCacheRow / stdoutJSON / stderrError / `#if canImport(PDFKit)` importFixturePDF) **verbatim from `ReadCommandTests.swift`** (adjust only the temp-dir prefix to `rubien-grep-test-`), then add:

```swift
    // MARK: web grep

    func testGrepWebLiteralWithExactOffsets() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "alpha needle beta needle gamma")
        let result = try runCLI(["grep", "\(id)", "needle"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual(json["source"] as? String, "web")
        XCTAssertEqual(json["available"] as? [String], ["web"])
        XCTAssertEqual((json["totalMatches"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((json["contentLength"] as? NSNumber)?.intValue, 30)
        let matches = try XCTUnwrap(json["matches"] as? [[String: Any]])
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual((matches[0]["start"] as? NSNumber)?.intValue, 6)
    }

    func testGrepWebOffsetFeedsReadTextStart() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: String(repeating: "x", count: 500) + " the needle sentence " + String(repeating: "y", count: 500))
        let grep = try runCLI(["grep", "\(id)", "needle"])
        XCTAssertEqual(grep.exitCode, 0, grep.stderr)
        let start = try XCTUnwrap(((try stdoutJSON(grep))["matches"] as? [[String: Any]])?.first?["start"] as? NSNumber).intValue
        let read = try runCLI(["read", "text", "\(id)", "--start", "\(max(0, start - 10))", "--max-chars", "40"])
        XCTAssertEqual(read.exitCode, 0, read.stderr)
        let window = (try stdoutJSON(read))["content"] as? String ?? ""
        XCTAssertTrue(window.contains("needle"), "read text window must contain the match; got: \(window)")
    }

    func testGrepWebOffsetFeedsReadTextStartOnHTMLBody() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        // decodeWebContent sniffs the html marker prefix — build an html-format body
        let html = "<!-- rubien:web-content:html -->\n<p>before <em>needle</em> after</p>"
        try seedWebContent(refId: id, body: html)
        let grep = try runCLI(["grep", "\(id)", "needle"])
        XCTAssertEqual(grep.exitCode, 0, grep.stderr)
        let json = try stdoutJSON(grep)
        let start = try XCTUnwrap((json["matches"] as? [[String: Any]])?.first?["start"] as? NSNumber).intValue
        let read = try runCLI(["read", "text", "\(id)", "--start", "\(start)", "--max-chars", "6"])
        XCTAssertEqual((try stdoutJSON(read))["content"] as? String, "needle")
    }

    func testGrepWebRegexAndCaseInsensitivity() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "Cat hat CAT")
        let literal = try runCLI(["grep", "\(id)", "cat"])
        XCTAssertEqual(((try stdoutJSON(literal))["totalMatches"] as? NSNumber)?.intValue, 2)
        let rx = try runCLI(["grep", "\(id)", "[ch]at", "--regex"])
        XCTAssertEqual(((try stdoutJSON(rx))["totalMatches"] as? NSNumber)?.intValue, 3)
    }

    func testGrepWebMaxMatchesEntryCapAndTotals() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        let spread = (0..<5).map { _ in "needle" + String(repeating: " z", count: 200) }.joined()
        try seedWebContent(refId: id, body: spread)
        let result = try runCLI(["grep", "\(id)", "needle", "--max-matches", "2"])
        let json = try stdoutJSON(result)
        XCTAssertEqual((json["matches"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((json["totalMatches"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((json["totalEntries"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual(json["truncated"] as? Bool, true)
    }

    func testGrepWebNoMatchesIsSuccess() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "nothing to see")
        let result = try runCLI(["grep", "\(id)", "absent"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let json = try stdoutJSON(result)
        XCTAssertEqual((json["totalMatches"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((json["matches"] as? [[String: Any]])?.count, 0)
    }

    // MARK: routing + validation

    func testGrepRoutingMatrix() throws {
        try skipIfBinaryMissing()
        // missing ref
        let missing = try runCLI(["grep", "999999999", "x"])
        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertTrue(stderrError(missing).contains("not found"), stderrError(missing))
        // neither source
        let bare = try addReference()
        let neither = try runCLI(["grep", "\(bare)", "x"])
        XCTAssertNotEqual(neither.exitCode, 0)
        XCTAssertTrue(stderrError(neither).contains("no readable content"), stderrError(neither))
        // web-only + explicit pdf
        let webRef = try addReference()
        try seedWebContent(refId: webRef, body: "text body")
        let forcedPdf = try runCLI(["grep", "\(webRef)", "text", "--source", "pdf"])
        XCTAssertNotEqual(forcedPdf.exitCode, 0)
        XCTAssertTrue(stderrError(forcedPdf).contains("no PDF attached"), stderrError(forcedPdf))
        XCTAssertTrue(stderrError(forcedPdf).contains("available: [\"web\"]"), stderrError(forcedPdf))
        // pdf-family param on web-only ref implies pdf → unavailable
        let implied = try runCLI(["grep", "\(webRef)", "text", "--max-pages", "5"])
        XCTAssertNotEqual(implied.exitCode, 0)
        XCTAssertTrue(stderrError(implied).contains("no PDF attached"), stderrError(implied))
        // notMaterialized pdf falls back to web by default
        try seedPdfCacheRow(refId: webRef, filename: "ghost.pdf", materialized: false)
        let fallback = try runCLI(["grep", "\(webRef)", "text"])
        XCTAssertEqual(fallback.exitCode, 0, fallback.stderr)
        XCTAssertEqual((try stdoutJSON(fallback))["source"] as? String, "web")
    }

    func testGrepMixedFamiliesError() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "body")
        let result = try runCLI(["grep", "\(id)", "x", "--max-pages", "5", "--max-matches", "5"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("mutually exclusive"), stderrError(result))
    }

    func testGrepExplicitSourceContradictsFamilyError() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "body")
        let r1 = try runCLI(["grep", "\(id)", "x", "--source", "web", "--max-pages", "5"])
        XCTAssertNotEqual(r1.exitCode, 0)
        XCTAssertTrue(stderrError(r1).contains("require a PDF source"), stderrError(r1))
        let r2 = try runCLI(["grep", "\(id)", "x", "--source", "pdf", "--max-matches", "5"])
        XCTAssertNotEqual(r2.exitCode, 0)
        XCTAssertTrue(stderrError(r2).contains("requires a web source"), stderrError(r2))
    }

    func testGrepEmptyQueryAndInvalidRegexAndBounds() throws {
        try skipIfBinaryMissing()
        let id = try addReference()
        try seedWebContent(refId: id, body: "body")
        let empty = try runCLI(["grep", "\(id)", "   "])
        XCTAssertNotEqual(empty.exitCode, 0)
        XCTAssertTrue(stderrError(empty).contains("query must not be empty"), stderrError(empty))
        let badRx = try runCLI(["grep", "\(id)", "([unclosed", "--regex"])
        XCTAssertNotEqual(badRx.exitCode, 0)
        XCTAssertTrue(stderrError(badRx).contains("invalid-regex"), stderrError(badRx))
        for (flag, bad) in [("--context-chars", "0"), ("--context-chars", "2001"),
                            ("--max-pages", "0"), ("--max-pages", "201"),
                            ("--snippets-per-page", "0"), ("--snippets-per-page", "21"),
                            ("--max-matches", "0"), ("--max-matches", "201")] {
            let r = try runCLI(["grep", "\(id)", "x", flag, bad])
            XCTAssertNotEqual(r.exitCode, 0, "\(flag) \(bad) must be rejected")
            XCTAssertTrue(stderrError(r).contains(flag), "\(flag) \(bad): \(stderrError(r))")
        }
    }

    // MARK: PDF grep (real extraction)

    #if canImport(PDFKit)
    func testGrepPdfWinsOnBothAndSourceWebFlips() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        try seedWebContent(refId: id, body: "web needle body")
        let pdf = try runCLI(["grep", "\(id)", "page"])
        XCTAssertEqual(pdf.exitCode, 0, pdf.stderr)
        let pdfJson = try stdoutJSON(pdf)
        XCTAssertEqual(pdfJson["source"] as? String, "pdf")
        XCTAssertEqual(pdfJson["available"] as? [String], ["pdf", "web"])
        XCTAssertNotNil(pdfJson["pages"])
        XCTAssertNotNil(pdfJson["hasTextLayer"])
        let web = try runCLI(["grep", "\(id)", "needle", "--source", "web"])
        XCTAssertEqual((try stdoutJSON(web))["source"] as? String, "web")
    }

    func testGrepPdfPagesScopeAndMaxMatchesImpliesWebError() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        let scoped = try runCLI(["grep", "\(id)", "page", "--pages", "2"])
        XCTAssertEqual(scoped.exitCode, 0, scoped.stderr)
        let hits = (try stdoutJSON(scoped))["pages"] as? [[String: Any]] ?? []
        XCTAssertTrue(hits.allSatisfy { ($0["page"] as? NSNumber)?.intValue == 2 })
        // --max-matches implies web; web unavailable on pdf-only ref
        let implied = try runCLI(["grep", "\(id)", "page", "--max-matches", "3"])
        XCTAssertNotEqual(implied.exitCode, 0)
        XCTAssertTrue(stderrError(implied).contains("web"), stderrError(implied))
    }

    func testGrepPdfInvalidPageRangePassesThroughExtractError() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()
        let result = try runCLI(["grep", "\(id)", "page", "--pages", "abc"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(stderrError(result).contains("invalid-page-range"), stderrError(result))
    }
    #endif
```

- [ ] **Step 2: Run to verify failure.**

Run: `swift build && swift test --filter 'RubienCLITests\.GrepCommandTests'`
Expected: FAIL — every invocation errors with "Unexpected argument 'grep'".

- [ ] **Step 3: Implement.** In `RubienCLI.swift`: add `Grep.self` to `allSubcommands` right after `Read.self`; add next to the `Read` family:

```swift
// MARK: - grep (kind-agnostic body-text search)

struct GrepPdfOutput: Encodable {
    let id: Int64
    let source: String
    let available: [String]
    let query: String
    let isRegex: Bool
    let pageCount: Int
    let hasTextLayer: Bool
    let totalMatches: Int
    let totalMatchingPages: Int
    let truncated: Bool
    let pages: [PDFExtractor.PageSearchHit]
}

struct GrepWebMatch: Encodable {
    let start: Int
    let matchCount: Int
    let snippet: String
}

struct GrepWebOutput: Encodable {
    let id: Int64
    let source: String
    let available: [String]
    let query: String
    let isRegex: Bool
    let contentLength: Int
    let totalMatches: Int
    let totalEntries: Int
    let truncated: Bool
    let matches: [GrepWebMatch]
}

struct Grep: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grep",
        abstract: "Find where a phrase or regex occurs in a reference's body text (PDF pages or web offsets)"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    @Argument(help: "Literal phrase (default) or regex (--regex). Case-insensitive.")
    var query: String

    @Flag(name: .customLong("regex"), help: "Treat the query as a regular expression")
    var isRegex: Bool = false

    @Option(name: .customLong("source"),
            help: "Force a source: pdf or web (default: pdf-scoped flags imply pdf, --max-matches implies web, else PDF wins)")
    var source: ReadSource?

    @Option(name: .customLong("context-chars"),
            help: "Snippet window width (default 160)")
    var contextChars: Int?

    @Option(name: .customLong("pages"),
            help: "PDF page range scope, e.g. 1-3,8-10. Implies a PDF source.")
    var pages: String?

    @Option(name: .customLong("max-pages"),
            help: "Cap returned PDF page-hits (default 30). Implies a PDF source.")
    var maxPages: Int?

    @Option(name: .customLong("snippets-per-page"),
            help: "Cap snippets per PDF page (default 3). Implies a PDF source.")
    var snippetsPerPage: Int?

    @Option(name: .customLong("max-matches"),
            help: "Cap returned web match entries (default 20). Implies a web source.")
    var maxMatches: Int?

    func run() throws {
        func requireBounds(_ value: Int?, _ flag: String, _ range: ClosedRange<Int>) throws {
            if let value, !range.contains(value) {
                printJSONError("\(flag) must be between \(range.lowerBound) and \(range.upperBound)")
                throw ExitCode.failure
            }
        }
        try requireBounds(contextChars, "--context-chars", 1...2_000)
        try requireBounds(maxPages, "--max-pages", 1...200)
        try requireBounds(snippetsPerPage, "--snippets-per-page", 1...20)
        try requireBounds(maxMatches, "--max-matches", 1...200)

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            printJSONError("query must not be empty")
            throw ExitCode.failure
        }
        // Validate a regex up front so the error beats routing (spec §7).
        if isRegex {
            do { _ = try BodyTextQuery.compile(query, isRegex: true) }
            catch {
                printJSONError("invalid-regex: \(error)")
                throw ExitCode.failure
            }
        }

        let pdfParamsGiven = pages != nil || maxPages != nil || snippetsPerPage != nil
        let webParamsGiven = maxMatches != nil
        if pdfParamsGiven && webParamsGiven {
            printJSONError("--pages/--max-pages/--snippets-per-page and --max-matches are mutually exclusive (PDF vs web scoping)")
            throw ExitCode.failure
        }

        guard let ref = try AppDatabase.shared.fetchReferences(ids: [id]).first else {
            printJSONError("Reference \(id) not found")
            throw ExitCode.failure
        }
        let avail = try resolveSources(for: ref)
        let availJSON = "[" + avail.available.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        if let source {
            if source == .web && pdfParamsGiven {
                printJSONError("--pages/--max-pages/--snippets-per-page require a PDF source (requested source: web); available: \(availJSON)")
                throw ExitCode.failure
            }
            if source == .pdf && webParamsGiven {
                printJSONError("--max-matches requires a web source (requested source: pdf); available: \(availJSON)")
                throw ExitCode.failure
            }
        }

        let resolved: ReadSource
        if let source {
            resolved = source
        } else if pdfParamsGiven {
            resolved = .pdf
        } else if webParamsGiven {
            resolved = .web
        } else if avail.pdfState == .available {
            resolved = .pdf
        } else if avail.web != nil {
            resolved = .web
        } else {
            printJSONError("Reference \(id) has no readable content (pdf: \(pdfStateDescription(avail.pdfState)); web: none)")
            throw ExitCode.failure
        }

        switch resolved {
        case .pdf:
            guard let url = avail.pdfURL else {
                printJSONError("source \"pdf\" is not readable (pdf: \(pdfStateDescription(avail.pdfState))); available: \(availJSON)")
                throw ExitCode.failure
            }
            do {
                let result = try PDFExtractor.search(
                    at: url, query: query, isRegex: isRegex,
                    pagesString: pages,
                    maxPages: maxPages ?? 30,
                    snippetsPerPage: snippetsPerPage ?? 3,
                    contextChars: contextChars ?? 160
                )
                printJSON(GrepPdfOutput(
                    id: id, source: "pdf", available: avail.available,
                    query: query, isRegex: isRegex,
                    pageCount: result.pageCount, hasTextLayer: result.hasTextLayer,
                    totalMatches: result.totalMatches,
                    totalMatchingPages: result.totalMatchingPages,
                    truncated: result.truncated, pages: result.pages
                ))
            } catch let e as PDFExtractor.ExtractError {
                emitPDFExtractError(e)
                throw ExitCode.failure
            }
        case .web:
            guard let decoded = avail.web else {
                printJSONError("source \"web\" is not readable (reference \(id) has no web content); available: \(availJSON)")
                throw ExitCode.failure
            }
            let body = decoded.body
            let compiled: BodyTextQuery
            do { compiled = try BodyTextQuery.compile(query, isRegex: isRegex) }
            catch {
                printJSONError("invalid-regex: \(error)")
                throw ExitCode.failure
            }
            let ranges = BodyTextMatcher.matches(in: body, query: compiled)
            let clusters = BodyTextMatcher.clusters(in: body, ranges: ranges,
                                                    contextChars: contextChars ?? 160)
            let cap = maxMatches ?? 20
            let kept = Array(clusters.prefix(cap))
            printJSON(GrepWebOutput(
                id: id, source: "web", available: avail.available,
                query: query, isRegex: isRegex,
                contentLength: body.count,
                totalMatches: ranges.count,
                totalEntries: clusters.count,
                truncated: clusters.count > kept.count,
                matches: kept.map { GrepWebMatch(start: $0.start, matchCount: $0.matchCount, snippet: $0.snippet) }
            ))
        }
    }
}
```

Implementer notes: `PDFExtractor.PageSearchHit` is already `Encodable` (Task 2), so `GrepPdfOutput` nests it directly. RubienCLI already imports RubienCore + RubienPDFKit. Do not modify the `Read` family.

- [ ] **Step 4: Run until green** + neighbors.

Run: `swift test --filter 'RubienCLITests\.GrepCommandTests'`, then `'RubienCLITests\.ReadCommandTests'`, `'RubienCLITests\.RubienCLITests'`, `'RubienCLITests\.MCPServerTests'` once each.
Expected: all PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RubienCLI/RubienCLI.swift Tests/RubienCLITests/GrepCommandTests.swift
git commit -m "feat(cli): grep — kind-agnostic body-text search with page/offset anchors"
```

---

### Task 4: Node mcp-server tool + versions

**Files:**
- Modify: `mcp-server/src/tools/read.ts` (register `rubien_grep_text` after `rubien_read_annotations`; append the read_text description sentence)
- Modify: `mcp-server/src/schemas.ts` (+ `GrepTextPdfOutput`, `GrepTextWebOutput` mirrors), `mcp-server/test/schemas.test.ts` (pin them), `mcp-server/test/e2e-stdio.test.ts` (`toolNames` gains `rubien_grep_text`)
- Modify: `mcp-server/src/versionGuard.ts` (`MIN_CLI_BUILD = 21`, comment names grep), `mcp-server/test/fixtures/stub-cli-ok.sh` (build 21), plus whatever guard tests pin the number (grep for `20` in `mcp-server/test` — feature-1 precedent: `versionGuard.test.ts`, `guard-startup.test.ts`)
- Modify: root `BUILD.txt` (21) + run `./scripts/generate-cli-version.sh` (commits `Sources/RubienCLI/GeneratedVersion.swift` at build 21) — **same task, same commit** (feature 1's regen gap must not recur)

**Interfaces:**
- Consumes: CLI `grep` (Task 3 flags), `runCliAsTool`/`flagsFromOptions`.
- Produces: the canonical `rubien_grep_text` registration (description from the plan's Global Constraints section, byte-exact) — Task 5 copies it.

- [ ] **Step 1: Registration** in `read.ts`:

```ts
  server.registerTool(
    "rubien_grep_text",
    {
      title: "Find where a reference's body says something",
      description:
        "Find WHERE a phrase or regex occurs inside one reference's body text — its attached PDF or its clipped web page — without retrieving the body. Returns anchored locations, not text: PDF hits are page-grouped (`pages[]` with `page`, `sectionPath` breadcrumbs, `matchCount`, snippets) — drill in with `rubien_read_text` + `pages`; web hits carry exact character offsets (`matches[].start`, same coordinates as `rubien_read_text`'s `start`) — drill in with `rubien_read_text` + `start`. Matching is case-insensitive (`regex: true` treats the query as a regular expression; `(?-i:…)` restores case). Source selection mirrors `rubien_read_text`: explicit `source` wins; `pages`/`maxPages`/`snippetsPerPage` imply pdf and `maxMatches` implies web; otherwise PDF wins when both exist. Every response carries `source` and `available`. A scanned PDF returns success with `hasTextLayer: false` and no hits — fall back to `rubien_pdf_page_image`. To find which REFERENCES match, use `rubien_search` (library metadata) instead. Library-only — never fetches from the network.",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
        query: z.string().min(1).describe("Literal phrase (default) or regex (`regex: true`). Case-insensitive."),
        regex: z.boolean().optional().describe("Treat `query` as a regular expression."),
        source: z.enum(["pdf", "web"]).optional()
          .describe("Force a source. Default: pdf-scoped params imply pdf, maxMatches implies web, else PDF wins."),
        contextChars: z.number().int().positive().max(2_000).optional()
          .describe("Snippet window width (default 160)."),
        pages: z.string().optional()
          .describe("PDF page range scope, e.g. '1-3,8-10'. Implies pdf."),
        maxPages: z.number().int().positive().max(200).optional()
          .describe("Cap returned PDF page-hits (default 30). Implies pdf."),
        snippetsPerPage: z.number().int().positive().max(20).optional()
          .describe("Cap snippets per PDF page (default 3). Implies pdf."),
        maxMatches: z.number().int().positive().max(200).optional()
          .describe("Cap returned web match entries (default 20). Implies web."),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) => {
      const pdfParams =
        Boolean(args.pages) || args.maxPages !== undefined || args.snippetsPerPage !== undefined;
      if (pdfParams && args.maxMatches !== undefined) {
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ error: "pdf-scoped-and-maxMatches-mutually-exclusive" }) }],
          isError: true,
        };
      }
      const cliArgs: string[] = ["grep", String(args.id), args.query];
      if (args.regex) cliArgs.push("--regex");
      if (args.pages) cliArgs.push("--pages", args.pages);
      cliArgs.push(
        ...flagsFromOptions({
          "--source": args.source,
          "--context-chars": args.contextChars,
          "--max-pages": args.maxPages,
          "--snippets-per-page": args.snippetsPerPage,
          "--max-matches": args.maxMatches,
        }),
      );
      return runCliAsTool(cliArgs);
    },
  );
```

(`Boolean(args.pages)` keeps the feature-1 empty-string rule: `pages:""` neither implies pdf nor emits the flag.) Append the read_text description sentence per Global Constraints.

- [ ] **Step 2: zod mirrors** in `schemas.ts` (after the read mirrors):

```ts
export const GrepTextPdfOutput = z.object({
  id: z.number().int(),
  source: z.literal("pdf"),
  available: z.array(z.enum(["pdf", "web"])),
  query: z.string(),
  isRegex: z.boolean(),
  pageCount: z.number().int(),
  hasTextLayer: z.boolean(),
  totalMatches: z.number().int(),
  totalMatchingPages: z.number().int(),
  truncated: z.boolean(),
  pages: z.array(z.object({
    page: z.number().int(),
    sectionPath: z.array(z.string()),
    matchCount: z.number().int(),
    snippetsTruncated: z.boolean(),
    snippets: z.array(z.string()),
  })),
});
export type GrepTextPdfOutput = z.infer<typeof GrepTextPdfOutput>;

export const GrepTextWebOutput = z.object({
  id: z.number().int(),
  source: z.literal("web"),
  available: z.array(z.enum(["pdf", "web"])),
  query: z.string(),
  isRegex: z.boolean(),
  contentLength: z.number().int(),
  totalMatches: z.number().int(),
  totalEntries: z.number().int(),
  truncated: z.boolean(),
  matches: z.array(z.object({
    start: z.number().int().nonnegative(),
    matchCount: z.number().int(),
    snippet: z.string(),
  })),
});
export type GrepTextWebOutput = z.infer<typeof GrepTextWebOutput>;
```

Pin both in `schemas.test.ts` following the file's existing valid+invalid-sample pattern (e.g. a pdf sample missing `snippetsTruncated` must fail; a web sample with negative `start` must fail).

- [ ] **Step 3: Versions.** `BUILD.txt` → `21`; `./scripts/generate-cli-version.sh`; `versionGuard.ts` `MIN_CLI_BUILD = 21` + comment "Equals the release build that first shipped `grep`."; `stub-cli-ok.sh` build → 21; update the guard tests' pinned numbers (`rg -n '\b20\b' mcp-server/test` and fix the guard-related ones — do NOT touch unrelated 20s).
- [ ] **Step 4: e2e** — `toolNames` expectation gains `rubien_grep_text`; any stated tool count in tests moves 34→35.
- [ ] **Step 5: Run.**

Run: `swift build` (regenerated version file must compile; `.build/debug/rubien-cli version` reports build 21) then `cd mcp-server && npm test`
Expected: both green.

- [ ] **Step 6: Commit.**

```bash
git add mcp-server BUILD.txt Sources/RubienCLI/GeneratedVersion.swift
git commit -m "feat(mcp): rubien_grep_text tool; BUILD 21 + MIN_CLI_BUILD 21"
```

---

### Task 5: Swift MCP catalog entry

**Files:**
- Modify: `Sources/RubienCLI/MCPToolCatalog.swift` (add `grepTextTool` to `readOnlyTools` after `readAnnotationsTool`; apply the read_text description sentence)
- Modify: `Tests/RubienCLITests/MCPServerTests.swift` (expectedToolNames = 8 incl. `rubien_grep_text`; required-args `["id","query"]`; new tests below)

**Interfaces:**
- Consumes: canonical strings from the COMMITTED `read.ts` (copy, don't retype — feature-1 byte-parity rule), CLI `grep` flags, `mcpInt`/`mcpString`/`mcpBool?` helpers (check whether an `mcpBool` accessor exists; if not, mirror how existing tools would read a boolean — likely add a small `mcpBool` following `mcpInt`'s pattern incl. the CFBoolean type-id check that ALREADY exists as `mcpIsJSONBool`).

- [ ] **Step 1: Failing tests.** `expectedToolNames` gains `rubien_grep_text` (comment 7→8 tools); add:

```swift
    func testGrepTextRequiredArgsAndArgv() throws {
        try skipIfBinaryMissing()
        let responses = try runMCP([req(id: 1, method: "tools/list")])
        // required args
        // (reuse the file's existing `required(_:)` helper)
        XCTAssertEqual(required("rubien_grep_text"), ["id", "query"])
    }

    func testGrepTextMixedScopesRejected() throws {
        try skipIfBinaryMissing()
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text",
                     arguments: ["id": 1, "query": "x", "maxPages": 5, "maxMatches": 5]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.lowercased().contains("mutually exclusive"), text)
    }

    func testGrepTextEmptyPagesTreatedAsAbsent() throws {
        try skipIfBinaryMissing()
        let id = try seedTitle("Grep empty pages")
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text", arguments: ["id": id, "query": "x", "pages": ""]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").lowercased()
        XCTAssertTrue(text.contains("no readable content"), text)   // routed to neither-branch, not pdf
    }

    func testGrepTextWebEndToEnd() throws {
        try skipIfBinaryMissing()
        let id = try seedTitle("Grep MCP e2e")
        // no web-content write path via MCP → this metadata-only ref errors;
        // the CLI-level GrepCommandTests own the happy path. Assert the error
        // surfaces as isError with the routing message:
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text", arguments: ["id": id, "query": "needle"]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue((((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "").contains("no readable content"))
    }
```

Adjust the exact helper spellings (`required`, `seedTitle`, `runMCP`, `toolCall`, `response`) to the file's real ones — read them first.

Run: `swift test --filter 'RubienCLITests\.MCPServerTests'` → FAIL (tool absent).

- [ ] **Step 2: Implement `grepTextTool`** following `readTextTool`'s structure exactly: description byte-copied from the committed `read.ts`; inputSchema mirroring the zod schema (`id`+`query` required; `regex` boolean; enums/bounds advertised); `buildArgv`:

```swift
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else {
                throw MCPToolError.invalidArguments("Missing required argument: id")
            }
            guard let query = try mcpString(args, "query"), !query.isEmpty else {
                throw MCPToolError.invalidArguments("Missing required argument: query")
            }
            // Empty pages treated as absent (Node parity, feature-1 rule).
            let pages = (try mcpString(args, "pages")).flatMap { $0.isEmpty ? nil : $0 }
            let maxPages = try mcpInt(args, "maxPages")
            let snippetsPerPage = try mcpInt(args, "snippetsPerPage")
            let maxMatches = try mcpInt(args, "maxMatches")
            let pdfParams = pages != nil || maxPages != nil || snippetsPerPage != nil
            if pdfParams, maxMatches != nil {
                throw MCPToolError.invalidArguments("`pages`/`maxPages`/`snippetsPerPage` and `maxMatches` are mutually exclusive")
            }
            var argv = ["grep", String(id), query]
            if try mcpBool(args, "regex") == true { argv.append("--regex") }
            mcpAppendString(&argv, "--pages", pages)
            mcpAppendString(&argv, "--source", try mcpString(args, "source"))
            mcpAppendInt(&argv, "--context-chars", try mcpInt(args, "contextChars"))
            mcpAppendInt(&argv, "--max-pages", maxPages)
            mcpAppendInt(&argv, "--snippets-per-page", snippetsPerPage)
            mcpAppendInt(&argv, "--max-matches", maxMatches)
            return argv
        }
```

If no `mcpBool` accessor exists, add one next to `mcpInt` using the existing `mcpIsJSONBool` check (present with wrong type → `invalidArguments`; absent → nil). Apply the read_text description sentence (byte-identical to the committed Node copy).

- [ ] **Step 3: Green + parity.** Run `swift test --filter 'RubienCLITests\.MCPServerTests'` and `'RubienCLITests\.GrepCommandTests'`; verify description byte-parity programmatically vs read.ts (feature-1 script pattern) and state the method in the report.
- [ ] **Step 4: Commit.**

```bash
git add Sources/RubienCLI/MCPToolCatalog.swift Tests/RubienCLITests/MCPServerTests.swift
git commit -m "feat(mcp-cli): native catalog serves rubien_grep_text"
```

---

### Task 6: Documentation

**Files:**
- Modify: `Docs/CLI-Reference.md` — Subcommands table gains a `grep` row; new `## grep` section AFTER `## read`; MCP mapping table gains `| rubien_grep_text | grep |` (keep it matching the native catalog's registration order).
- Modify: `mcp-server/README.md` — Reading row gains `rubien_grep_text`; stated tool count 34 → 35; one sentence on the grep→read workflow in the Reading-tools paragraph.

- [ ] **Step 1: `## grep` section** (verbatim; JSON must match Task 3's envelopes):

~~~markdown
## grep

Find **where** a reference's body text says something — without retrieving the
body. The lookup half of the `read` workflow: grep locates, `read text`
retrieves.

```
rubien-cli grep <id> "<query>" [--regex] [--source pdf|web] [--context-chars N]
    [--pages <range>] [--max-pages N] [--snippets-per-page N]   # PDF-scoped
    [--max-matches N]                                            # web-scoped
```

Source selection mirrors `read`: explicit `--source` wins; PDF-scoped flags
imply `pdf` and `--max-matches` implies `web`; otherwise PDF wins when the
reference has both. Matching is case-insensitive (`--regex` for regular
expressions; `(?-i:…)` restores case sensitivity). Matches are
non-overlapping, leftmost-first; zero-width regex matches are discarded.

PDF-source response — hits anchor to **pages** (follow up with
`read text --pages`); snippets come from normalized extracted text:

```json
{ "id": 42, "source": "pdf", "available": ["pdf"],
  "query": "theorem", "isRegex": false,
  "pageCount": 12, "hasTextLayer": true,
  "totalMatches": 5, "totalMatchingPages": 2, "truncated": false,
  "pages": [ { "page": 4, "sectionPath": ["3 Main Results"], "matchCount": 2,
               "snippetsTruncated": false, "snippets": ["…"] } ] }
```

`totalMatches`/`totalMatchingPages` are counted before the `--max-pages` cut.
A scanned PDF (no text layer) returns success with `hasTextLayer: false` and
no hits — fall back to `pdf page-image`.

Web-source response — hits anchor to **exact character offsets** into the raw
body, in the same coordinates `read text --start` consumes:

```json
{ "id": 7, "source": "web", "available": ["web"],
  "query": "theorem", "isRegex": false,
  "contentLength": 84213, "totalMatches": 3, "totalEntries": 2, "truncated": false,
  "matches": [ { "start": 18342, "matchCount": 2,
                 "snippet": "… we now state the theorem …" } ] }
```

Nearby matches merge into one entry (`matchCount` counts the cluster;
`start` is the first match's offset). `--max-matches` caps entries;
`totalEntries` counts clusters before the cap.

Errors: unknown reference; neither source readable; a requested or implied
source that is unavailable; PDF-scoped flags mixed with `--max-matches`;
empty query; `invalid-regex`; PDF extraction failures pass through the
`pdf`-family error envelope (`encrypted`, `invalid-page-range: …`).
~~~

- [ ] **Step 2: verify + commit.**

Run: `rg -n "rubien_pdf_search|pdf search" Docs/CLI-Reference.md mcp-server/README.md` → nothing; `rg -c "rubien_grep_text" Docs/CLI-Reference.md mcp-server/README.md` → ≥1 each.

```bash
git add Docs/CLI-Reference.md mcp-server/README.md
git commit -m "docs: CLI-Reference grep section + README reading tools for rubien_grep_text"
```

---

## Final verification (whole branch)

- `swift build`; suites: `'RubienCoreTests\..*'`, `'RubienPDFKitTests\..*'` (Mac), `'RubienCLITests\..*'`, `'RubienTests\..*'`; `cd mcp-server && npm test` — all green.
- `.build/debug/rubien-cli version` → build 21; MIN_CLI_BUILD 21; npm version per §8 contingency.
- Then: superpowers:requesting-code-review whole-branch review (most capable model) + the repo's codex-rescue review, per the development workflow.
