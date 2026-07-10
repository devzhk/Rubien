import XCTest
@testable import RubienCore

final class ReferenceTests: XCTestCase {

    // MARK: - Initialization

    func testInitWithTitle() {
        let ref = Reference(title: "Test Title")
        XCTAssertEqual(ref.title, "Test Title")
        XCTAssertNil(ref.id)
        XCTAssertNil(ref.year)
        XCTAssertNil(ref.journal)
        XCTAssertNil(ref.doi)
        XCTAssertTrue(ref.authors.isEmpty)
    }

    func testInitWithAllFields() {
        let ref = Reference(
            title: "Full Reference",
            authors: [AuthorName(given: "John", family: "Smith")],
            year: 2023,
            journal: "Test Journal",
            volume: "42",
            issue: "3",
            pages: "100-115",
            doi: "10.1234/test",
            url: "https://example.com",
            abstract: "This is an abstract.",
            notes: "Some notes."
        )
        XCTAssertEqual(ref.title, "Full Reference")
        XCTAssertEqual(ref.year, 2023)
        XCTAssertEqual(ref.journal, "Test Journal")
        XCTAssertEqual(ref.volume, "42")
        XCTAssertEqual(ref.issue, "3")
        XCTAssertEqual(ref.pages, "100-115")
        XCTAssertEqual(ref.doi, "10.1234/test")
        XCTAssertEqual(ref.url, "https://example.com")
        XCTAssertEqual(ref.abstract, "This is an abstract.")
        XCTAssertEqual(ref.notes, "Some notes.")
        XCTAssertEqual(ref.authors.count, 1)
    }

    // MARK: - Reference Type

    func testDefaultReferenceTypeIsJournalArticle() {
        let ref = Reference(title: "Default Type")
        XCTAssertEqual(ref.referenceType, .journalArticle)
    }

    func testAllReferenceTypesHaveIcons() {
        for type in ReferenceType.allCases {
            XCTAssertFalse(type.icon.isEmpty,
                           "\(type.rawValue) should have a non-empty icon")
        }
    }

    func testReferenceTypeRawValues() {
        // Post-v3 prune: 6 BibTeX-derived types remain. Anything else collapses
        // into Other; for organization, use Tags or a custom property.
        XCTAssertEqual(ReferenceType.journalArticle.rawValue,  "Journal Article")
        XCTAssertEqual(ReferenceType.conferencePaper.rawValue, "Conference Paper")
        XCTAssertEqual(ReferenceType.book.rawValue,            "Book")
        XCTAssertEqual(ReferenceType.thesis.rawValue,          "Thesis")
        XCTAssertEqual(ReferenceType.webpage.rawValue,         "Web Page")
        XCTAssertEqual(ReferenceType.other.rawValue,           "Other")
        XCTAssertEqual(ReferenceType.allCases.count, 7)
    }

    func testReferenceTypeCSLTypeMapping() {
        XCTAssertEqual(ReferenceType.journalArticle.cslType,  "article-journal")
        XCTAssertEqual(ReferenceType.conferencePaper.cslType, "paper-conference")
        XCTAssertEqual(ReferenceType.book.cslType,            "book")
        XCTAssertEqual(ReferenceType.thesis.cslType,          "thesis")
        XCTAssertEqual(ReferenceType.webpage.cslType,         "webpage")
        XCTAssertEqual(ReferenceType.other.cslType,           "article")
    }

    // MARK: - AuthorName

    func testAuthorNameDisplayName() {
        let author = AuthorName(given: "John", family: "Smith")
        XCTAssertEqual(author.displayName, "John Smith")
    }

    func testAuthorNameDisplayNameWithEmptyGiven() {
        let author = AuthorName(given: "", family: "Smith")
        XCTAssertEqual(author.displayName, "Smith")
    }

    func testAuthorNameShortName() {
        let author = AuthorName(given: "John", family: "Smith")
        XCTAssertEqual(author.shortName, "Smith, J.")
    }

    func testAuthorNameShortNameMultipleGiven() {
        let author = AuthorName(given: "John Robert", family: "Smith")
        XCTAssertEqual(author.shortName, "Smith, J. R.")
    }

    // MARK: - AuthorName.parse

    func testParseGivenFamily() {
        let author = AuthorName.parse("John Smith")
        XCTAssertEqual(author.given, "John")
        XCTAssertEqual(author.family, "Smith")
    }

    func testParseFamilyCommaGiven() {
        let author = AuthorName.parse("Smith, John")
        XCTAssertEqual(author.given, "John")
        XCTAssertEqual(author.family, "Smith")
    }

    func testParseSingleName() {
        let author = AuthorName.parse("Aristotle")
        XCTAssertEqual(author.family, "Aristotle")
        XCTAssertTrue(author.given.isEmpty)
    }

    // MARK: - AuthorName.parseList

    func testParseListWithAnd() {
        let authors = AuthorName.parseList("Smith, John and Doe, Jane")
        XCTAssertEqual(authors, [
            AuthorName(given: "John", family: "Smith"),
            AuthorName(given: "Jane", family: "Doe"),
        ])
    }

    func testParseListWithSemicolon() {
        let authors = AuthorName.parseList("Smith, John; Doe, Jane")
        XCTAssertEqual(authors.count, 2)
        XCTAssertEqual(authors[0].family, "Smith")
        XCTAssertEqual(authors[1].family, "Doe")
    }

    func testParseListWithCommaSeparatedPairs() {
        let authors = AuthorName.parseList("Smith, John, Doe, Jane")
        XCTAssertEqual(authors.count, 2)
        XCTAssertEqual(authors[0], AuthorName(given: "John", family: "Smith"))
        XCTAssertEqual(authors[1], AuthorName(given: "Jane", family: "Doe"))
    }

    func testParseListEmpty() {
        let authors = AuthorName.parseList("")
        XCTAssertTrue(authors.isEmpty)
    }

    // MARK: - AuthorName brace handling (BibTeX capitalization-protection)

    func testParseStripsProtectionBracesFromParticle() {
        // `{de la Vega}` keeps the lowercase particle together in BibTeX; the braces
        // are protection markers and must not survive into the parsed name.
        let author = AuthorName.parse("{de la Vega}, Maria")
        XCTAssertEqual(author.family, "de la Vega")
        XCTAssertEqual(author.given, "Maria")
    }

    func testParseStripsBracesFromCorporateName() {
        // A whole-name brace group is one corporate author; spaces inside it are not a
        // given/family boundary.
        let author = AuthorName.parse("{International Brain Lab}")
        XCTAssertEqual(author.family, "International Brain Lab")
        XCTAssertTrue(author.given.isEmpty)
    }

    func testParseListStripsBracesFromCorporateAuthorInAndList() {
        // Real Zotero export shape: brace-protected corporate author joined with " and ".
        let authors = AuthorName.parseList("{International Brain Lab} and Brandon Benson")
        XCTAssertEqual(authors, [
            AuthorName(given: "", family: "International Brain Lab"),
            AuthorName(given: "Brandon", family: "Benson"),
        ])
    }

    func testParseListDoesNotSplitOnBraceProtectedAnd() {
        // The " and " inside the braces belongs to one corporate name and must NOT be
        // treated as an author separator.
        let authors = AuthorName.parseList("{Barnes and Noble Inc.} and Smith, John")
        XCTAssertEqual(authors, [
            AuthorName(given: "", family: "Barnes and Noble Inc."),
            AuthorName(given: "John", family: "Smith"),
        ])
    }

    func testParseListNonBracedBehaviorUnchanged() {
        // Regression guard: non-braced input (every non-BibTeX caller) is untouched.
        XCTAssertEqual(
            AuthorName.parseList("Smith, John and Doe, Jane"),
            [AuthorName(given: "John", family: "Smith"), AuthorName(given: "Jane", family: "Doe")]
        )
    }

    func testParseListTrailingCommaStillGroupsAsPair() {
        // Regression guard: a stray trailing comma must not turn one "Family, Given" pair
        // into two separate authors (empty fields are dropped, matching `split`).
        XCTAssertEqual(
            AuthorName.parseList("Smith, John,"),
            [AuthorName(given: "John", family: "Smith")]
        )
    }

    func testParseListConsecutiveCommasIgnoreEmptyFields() {
        XCTAssertEqual(
            AuthorName.parseList("Smith, John,, Doe, Jane"),
            [AuthorName(given: "John", family: "Smith"), AuthorName(given: "Jane", family: "Doe")]
        )
    }

    func testParseListProtectedSemicolonDoesNotSelectSemicolonMode() {
        // The ";" lives inside braces, so it must not select semicolon mode and swallow the
        // real top-level " and " separator.
        XCTAssertEqual(
            AuthorName.parseList("{Research; Lab} and Smith, John"),
            [AuthorName(given: "", family: "Research; Lab"), AuthorName(given: "John", family: "Smith")]
        )
    }

    func testParseSuffixWithMultipleCommasPreservesGivenRemainder() {
        // `Family, Suffix, Given` — everything after the first depth-0 comma is the given
        // remainder (parity with the original `firstIndex(of: ",")` behavior).
        let author = AuthorName.parse("Smith, Jr., John")
        XCTAssertEqual(author.family, "Smith")
        XCTAssertEqual(author.given, "Jr., John")
    }

    func testParseListBraceProtectedFamilyWithGivenIsSingleAuthor() {
        // `{de la Vega}, Maria` is ONE author: the brace-protected multi-word family must not
        // be mistaken for a comma-separated list of full names just because it has spaces.
        XCTAssertEqual(
            AuthorName.parseList("{de la Vega}, Maria"),
            [AuthorName(given: "Maria", family: "de la Vega")]
        )
    }

    func testParseListBraceInteriorPaddingTrimmed() {
        // Whitespace revealed from inside braces (`{ Smith }`) must be trimmed, not retained.
        XCTAssertEqual(
            AuthorName.parseList("{ Smith }, John"),
            [AuthorName(given: "John", family: "Smith")]
        )
    }

    func testParseListBraceProtectedFamilyGivenPairs() {
        // Two protected-family pairs must group correctly (brace-aware single-token check).
        XCTAssertEqual(
            AuthorName.parseList("{de la Vega}, Maria, {von Braun}, Werner"),
            [
                AuthorName(given: "Maria", family: "de la Vega"),
                AuthorName(given: "Werner", family: "von Braun"),
            ]
        )
    }

    // MARK: - Authors displayString

    func testAuthorsDisplayString() {
        let authors = [
            AuthorName(given: "John", family: "Smith"),
            AuthorName(given: "Jane", family: "Doe"),
        ]
        XCTAssertEqual(authors.displayString, "John Smith, Jane Doe")
    }

    func testEmptyAuthorsDisplayString() {
        let authors: [AuthorName] = []
        XCTAssertEqual(authors.displayString, "")
    }

    // MARK: - Dates

    func testDateAddedIsSetOnInit() {
        let before = Date()
        let ref = Reference(title: "Date Test")
        XCTAssertGreaterThanOrEqual(ref.dateAdded, before)
    }

    func testDateModifiedIsSetOnInit() {
        let before = Date()
        let ref = Reference(title: "Date Test")
        XCTAssertGreaterThanOrEqual(ref.dateModified, before)
    }

    // MARK: - Extended Metadata

    func testExtendedMetadataDefaults() {
        let ref = Reference(title: "Extended Test")
        XCTAssertNil(ref.publisher)
        XCTAssertNil(ref.publisherPlace)
        XCTAssertNil(ref.edition)
        XCTAssertNil(ref.editors)
        XCTAssertNil(ref.isbn)
        XCTAssertNil(ref.issn)
        XCTAssertNil(ref.accessedDate)
        XCTAssertNil(ref.translators)
        XCTAssertNil(ref.language)
        XCTAssertNil(ref.pmid)
        XCTAssertNil(ref.pmcid)
    }

    func testExtendedMetadataCanBeSet() {
        var ref = Reference(title: "Extended Set Test")
        ref.publisher = "Springer"
        ref.isbn = "978-3-16-148410-0"
        ref.language = "en"
        XCTAssertEqual(ref.publisher, "Springer")
        XCTAssertEqual(ref.isbn, "978-3-16-148410-0")
        XCTAssertEqual(ref.language, "en")
    }

    // MARK: - Hashable / Equatable

    func testReferencesWithSameIdAndContentAreEqual() {
        let ref1 = Reference(id: 1, title: "A")
        let ref2 = ref1
        XCTAssertEqual(ref1, ref2)
    }

    func testReferencesWithSameIdButDifferentContentAreNotEqual() {
        let ref1 = Reference(id: 1, title: "A")
        let ref2 = Reference(id: 1, title: "B")
        XCTAssertNotEqual(ref1, ref2)
    }

    func testReferencesWithDifferentIdsAreNotEqual() {
        let ref1 = Reference(id: 1, title: "A")
        let ref2 = Reference(id: 2, title: "A")
        XCTAssertNotEqual(ref1, ref2)
    }
}
