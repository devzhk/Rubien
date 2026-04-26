import Foundation
import XCTest
@testable import Rubien
@testable import RubienCore

final class ImporterAndMetadataTests: XCTestCase {
    func testBibTeXParseMapsEntryTypesAndPreservesNestedBraceContent() throws {
        let bibtex = """
        @article{smith2024,
          title = {Understanding {Swift} Testing},
          author = {Smith, John and Doe, Jane},
          year = {2024},
          journal = {Journal of Tests},
          volume = {12},
          number = {3},
          pages = {10--20},
          doi = {10.1000/test},
          url = {https://example.com/article},
          abstract = {A careful study.}
        }

        @inproceedings{lee2023,
          title = "Conference Paper",
          author = "Lee, Pat",
          year = "2023",
          booktitle = "Proceedings of SwiftConf"
        }
        """

        let references = BibTeXImporter.parse(bibtex)

        XCTAssertEqual(references.count, 2)

        let article = try XCTUnwrap(references.first)
        XCTAssertEqual(article.title, "Understanding {Swift} Testing")
        XCTAssertEqual(article.authors, [
            AuthorName(given: "John", family: "Smith"),
            AuthorName(given: "Jane", family: "Doe"),
        ])
        XCTAssertEqual(article.year, 2024)
        XCTAssertEqual(article.journal, "Journal of Tests")
        XCTAssertEqual(article.volume, "12")
        XCTAssertEqual(article.issue, "3")
        XCTAssertEqual(article.pages, "10--20")
        XCTAssertEqual(article.doi, "10.1000/test")
        XCTAssertEqual(article.url, "https://example.com/article")
        XCTAssertEqual(article.abstract, "A careful study.")
        XCTAssertEqual(article.referenceType, .journalArticle)

        let conference = references[1]
        XCTAssertEqual(conference.title, "Conference Paper")
        XCTAssertEqual(conference.authors, [AuthorName(given: "Pat", family: "Lee")])
        XCTAssertEqual(conference.journal, "Proceedings of SwiftConf")
        XCTAssertEqual(conference.referenceType, .conferencePaper)
    }

    func testRISParseBuildsReferencesIncludingTrailingEntryWithoutER() {
        let ris = """
        TY  - JOUR
        TI  - RIS Article
        AU  - Smith, John
        AU  - Doe, Jane
        PY  - 2022/05/01
        JO  - Parsing Today
        VL  - 8
        IS  - 2
        SP  - 15
        EP  - 30
        DO  - 10.1000/ris
        ER  -
        TY  - CHAP
        T1  - Final Chapter
        A1  - Lee, Pat
        Y1  - 2021
        T2  - Great Book
        """

        let references = RISImporter.parse(ris)

        XCTAssertEqual(references.count, 2)

        let article = references[0]
        XCTAssertEqual(article.title, "RIS Article")
        XCTAssertEqual(article.authors, [
            AuthorName(given: "John", family: "Smith"),
            AuthorName(given: "Jane", family: "Doe"),
        ])
        XCTAssertEqual(article.year, 2022)
        XCTAssertEqual(article.journal, "Parsing Today")
        XCTAssertEqual(article.volume, "8")
        XCTAssertEqual(article.issue, "2")
        XCTAssertEqual(article.pages, "15-30")
        XCTAssertEqual(article.doi, "10.1000/ris")
        XCTAssertEqual(article.referenceType, .journalArticle)

        let chapter = references[1]
        XCTAssertEqual(chapter.title, "Final Chapter")
        XCTAssertEqual(chapter.authors, [AuthorName(given: "Pat", family: "Lee")])
        XCTAssertEqual(chapter.year, 2021)
        XCTAssertEqual(chapter.journal, "Great Book")
        XCTAssertEqual(chapter.referenceType, .bookSection)
    }

    func testMetadataFetcherExtractIdentifierPrioritizesSupportedFormats() {
        assertIdentifier(
            MetadataFetcher.extractIdentifier(from: "https://doi.org/10.1000/xyz.123."),
            matches: .doi("10.1000/xyz.123")
        )
        assertIdentifier(
            MetadataFetcher.extractIdentifier(from: "9780306406157"),
            matches: .isbn("9780306406157")
        )
        assertIdentifier(
            MetadataFetcher.extractIdentifier(from: "arXiv:2301.07041v2"),
            matches: .arxiv("2301.07041")
        )
        // Lowercase arXiv URL with single-digit version: digits-only count is exactly 10
        // ("2501078883"), which previously short-circuited to .isbn before the arXiv pattern ran.
        assertIdentifier(
            MetadataFetcher.extractIdentifier(from: "https://arxiv.org/abs/2501.07888v3"),
            matches: .arxiv("2501.07888")
        )
        assertIdentifier(
            MetadataFetcher.extractIdentifier(from: "arxiv:2501.07888v3"),
            matches: .arxiv("2501.07888")
        )
        assertIdentifier(
            MetadataFetcher.extractIdentifier(from: "12345678"),
            matches: .pmid("12345678")
        )
        XCTAssertNil(MetadataFetcher.extractIdentifier(from: "not an identifier"))
    }

    func testMetadataFetcherPrefersDOIOverOtherNumericPatterns() {
        assertIdentifier(
            MetadataFetcher.extractIdentifier(from: "doi:10.1000/123456789X"),
            matches: .doi("10.1000/123456789X")
        )
    }

    private func assertIdentifier(_ actual: MetadataFetcher.Identifier?, matches expected: MetadataFetcher.Identifier) {
        switch (actual, expected) {
        case (.doi(let lhs), .doi(let rhs)):
            XCTAssertEqual(lhs, rhs)
        case (.pmid(let lhs), .pmid(let rhs)):
            XCTAssertEqual(lhs, rhs)
        case (.arxiv(let lhs), .arxiv(let rhs)):
            XCTAssertEqual(lhs, rhs)
        case (.isbn(let lhs), .isbn(let rhs)):
            XCTAssertEqual(lhs, rhs)
        default:
            XCTFail("Identifier mismatch: actual=\(String(describing: actual)) expected=\(expected)")
        }
    }
}
