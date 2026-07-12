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

    func testRegexLigaturePatternDoesNotMatchFoldedText() throws {
        // The PDF path folds page text via NFKC but never folds the PATTERN
        // (spec §6): a literal ﬁ in a regex won't match the folded "fi".
        XCTAssertEqual(BodyTextMatcher.matches(in: "final text", query: try regex("ﬁnal")).count, 0)
        // whereas the literal path normalizes the query too — at the PDF call
        // site (PDFExtractor.search normalizes literal queries); at matcher
        // level a pre-normalized needle matches:
        XCTAssertEqual(starts("final text", literal(BodyTextMatcher.normalize("ﬁnal"))), [0])
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

    func testClusterPreservesMultiWordLiteralMatch() {
        // Trailing context ("zzz…") is one unbroken token, so a naive trailing
        // trim that only guards the window start would retreat into the match
        // and drop "bar". The full match must survive.
        let body = "aaaa foo barzzzzzzzzzzzz"
        let ranges = BodyTextMatcher.matches(in: body, query: literal("foo bar"))
        XCTAssertEqual(ranges.count, 1)
        let c = BodyTextMatcher.clusters(in: body, ranges: ranges, contextChars: 12)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].snippet.contains("foo bar"),
                      "multi-word match must survive trimming; got: \(c[0].snippet)")
    }

    func testClusterPreservesRegexMatchSpanningWhitespace() throws {
        let body = "xxxx alpha betayyyyyyyyyyyy"
        let ranges = BodyTextMatcher.matches(in: body, query: try regex("alpha\\s+beta"))
        XCTAssertEqual(ranges.count, 1)
        let c = BodyTextMatcher.clusters(in: body, ranges: ranges, contextChars: 12)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].snippet.contains("alpha beta"),
                      "regex match spanning whitespace must survive trimming; got: \(c[0].snippet)")
    }

    func testSnippetAtBodyEdgesHasNoEllipsis() {
        let body = "needle tail"
        let ranges = BodyTextMatcher.matches(in: body, query: literal("needle"))
        let c = BodyTextMatcher.clusters(in: body, ranges: ranges, contextChars: 200)
        XCTAssertEqual(c[0].snippet, "needle tail")
    }
}
