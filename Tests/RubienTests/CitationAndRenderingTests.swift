#if canImport(Rubien)
import Foundation
import XCTest
@testable import Rubien
@testable import RubienCore

final class CitationAndRenderingTests: XCTestCase {
    func testCitationFormatterFormatsInlineCitationsAcrossStyles() {
        let ref1 = makeReference(id: 1, title: "First", authors: [
            AuthorName(given: "Jane", family: "Doe"),
            AuthorName(given: "John", family: "Smith"),
            AuthorName(given: "Pat", family: "Lee"),
        ], year: 2024, pages: "42-45")
        let ref2 = makeReference(id: 2, title: "Second", authors: [
            AuthorName(given: "Alex", family: "Jones"),
        ], year: 2023)

        XCTAssertEqual(
            CitationFormatter.formatInlineCitation([ref1, ref2], style: "apa"),
            "(Doe et al., 2024; Jones, 2023)"
        )
        XCTAssertEqual(
            CitationFormatter.formatInlineCitation([ref1], style: "mla"),
            "(Doe et al. 42)"
        )
        XCTAssertEqual(
            CitationFormatter.formatNumericInlineCitation(numbers: [4, 2, 3, 7], style: "ieee"),
            "[2-4, 7]"
        )
        XCTAssertEqual(
            CitationFormatter.formatNumericInlineCitation(numbers: [4, 2, 3, 7], style: "nature"),
            "2-4, 7"
        )
    }

    func testCitationFormatterFormatsBibliographyEntries() {
        let reference = makeReference(
            id: 1,
            title: "Testing Swift",
            authors: [
                AuthorName(given: "Jane", family: "Doe"),
                AuthorName(given: "John", family: "Smith"),
            ],
            year: 2024,
            journal: "Journal of Tests",
            volume: "12",
            issue: "3",
            pages: "10-20",
            doi: "10.1000/test"
        )

        XCTAssertEqual(
            CitationFormatter.formatBibliography(reference, style: "apa"),
            "Doe, J., & Smith, J. (2024). Testing Swift. Journal of Tests, 12(3), 10-20. https://doi.org/10.1000/test"
        )
        XCTAssertEqual(
            CitationFormatter.formatNumericBibliographyEntry("Entry body", number: 3, style: "ieee"),
            "[3] Entry body"
        )
        XCTAssertEqual(
            CitationFormatter.formatNumericBibliographyEntry("Entry body", number: 3, style: "vancouver"),
            "3. Entry body"
        )
    }

    func testCSLXMLParserParsesCitationMetadataAndMacros() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <style xmlns="http://purl.org/net/xbiblio/csl" version="1.0">
          <info>
            <title>Test Numeric Style</title>
            <id>test-style</id>
          </info>
          <category citation-format="numeric"/>
          <macro name="author-short">
            <names variable="author">
              <name name-as-sort-order="all" sort-separator=", " initialize-with="." and="symbol"/>
            </names>
          </macro>
          <citation et-al-min="3" et-al-use-first="1">
            <layout prefix="(" suffix=")" delimiter="; ">
              <text macro="author-short"/>
              <text value=", "/>
              <date variable="issued">
                <date-part name="year"/>
              </date>
            </layout>
            <sort>
              <key variable="title"/>
            </sort>
          </citation>
          <bibliography>
            <layout delimiter="">
              <group delimiter=" ">
                <text macro="author-short"/>
                <text value="("/>
                <date variable="issued">
                  <date-part name="year"/>
                </date>
                <text value=")"/>
                <choose>
                  <if variable="page" match="all">
                    <label variable="page" form="short" suffix=" "/>
                    <text variable="page"/>
                  </if>
                  <else>
                    <text value="no pages"/>
                  </else>
                </choose>
              </group>
            </layout>
          </bibliography>
        </style>
        """

        let style = try XCTUnwrap(CSLXMLParser().parse(data: Data(xml.utf8)))

        XCTAssertEqual(style.id, "test-style")
        XCTAssertEqual(style.title, "Test Numeric Style")
        XCTAssertEqual(style.citationKind, .numeric)
        XCTAssertEqual(style.citationLayout.prefix, "(")
        XCTAssertEqual(style.citationLayout.suffix, ")")
        XCTAssertEqual(style.citationLayout.delimiter, "; ")
        XCTAssertNil(style.citationLayout.verticalAlign)
        XCTAssertEqual(style.citationSort.map(\.variable), ["title"])
        XCTAssertEqual(style.etAlMin, 3)
        XCTAssertEqual(style.etAlUseFirst, 1)
        XCTAssertNotNil(style.macros["author-short"])
    }

    func testCSLXMLParserCapturesCitationVerticalAlign() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <style xmlns="http://purl.org/net/xbiblio/csl" version="1.0">
          <info>
            <title>GB/T Numeric</title>
            <id>gbt-test</id>
          </info>
          <category citation-format="numeric"/>
          <citation>
            <layout vertical-align="sup" prefix="[" suffix="]">
              <text variable="citation-number"/>
            </layout>
          </citation>
          <bibliography>
            <layout delimiter="">
              <text variable="title"/>
            </layout>
          </bibliography>
        </style>
        """

        let style = try XCTUnwrap(CSLXMLParser().parse(data: Data(xml.utf8)))
        XCTAssertEqual(style.citationLayout.verticalAlign, "sup")
    }

    func testCSLEngineRendersInlineCitationAndBibliographyFromParsedStyle() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <style xmlns="http://purl.org/net/xbiblio/csl" version="1.0">
          <info>
            <title>Inline Style</title>
            <id>inline-style</id>
          </info>
          <citation et-al-min="3" et-al-use-first="1">
            <layout prefix="(" suffix=")" delimiter="; ">
              <names variable="author">
                <name name-as-sort-order="first" sort-separator=", " initialize-with="." and="symbol"/>
              </names>
              <text value=", "/>
              <date variable="issued">
                <date-part name="year"/>
              </date>
            </layout>
          </citation>
          <bibliography>
            <layout delimiter="">
              <group delimiter="">
                <names variable="author">
                  <name name-as-sort-order="all" sort-separator=", " initialize-with="." and="symbol"/>
                </names>
                <text value=" ("/>
                <date variable="issued">
                  <date-part name="year"/>
                </date>
                <text value=") "/>
                <label variable="page" form="short" suffix=" "/>
                <text variable="page"/>
              </group>
            </layout>
          </bibliography>
        </style>
        """

        let style = try XCTUnwrap(CSLXMLParser().parse(data: Data(xml.utf8)))
        let engine = CSLEngine(style: style)
        let reference = makeReference(
            id: 1,
            title: "Testing Swift",
            authors: [
                AuthorName(given: "Jane", family: "Doe"),
                AuthorName(given: "John", family: "Smith"),
                AuthorName(given: "Pat", family: "Lee"),
            ],
            year: 2024,
            pages: "10-12"
        )

        XCTAssertEqual(engine.renderInlineCitation([reference]), "(Doe, J. et al., 2024)")
        XCTAssertEqual(engine.renderBibliographyEntry(reference), "Doe, J. et al. (2024) pp. 10-12")
    }

    private func makeReference(
        id: Int64,
        title: String,
        authors: [AuthorName],
        year: Int,
        journal: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        doi: String? = nil
    ) -> Reference {
        Reference(
            id: id,
            title: title,
            authors: authors,
            year: year,
            journal: journal,
            volume: volume,
            issue: issue,
            pages: pages,
            doi: doi
        )
    }
}
#endif
