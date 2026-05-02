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
        XCTAssertEqual(ReferenceType.allCases.count, 6)
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
