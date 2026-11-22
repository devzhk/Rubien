import XCTest
@testable import RubienCore

final class HTMLEntitiesTests: XCTestCase {
    func testDecodesDecimalAndHexadecimalReferences() {
        XCTAssertEqual(HTMLEntities.decode("St&#233;fan del R&#237;o"), "Stéfan del Río")
        XCTAssertEqual(HTMLEntities.decode("&#x17D;&#XED;dek &#x1F600;"), "Žídek 😀")
        // A combining mark right after `;` must not hide the terminator.
        XCTAssertEqual(HTMLEntities.decode("e&#769;&#769;"), "e\u{301}\u{301}")
        XCTAssertEqual(HTMLEntities.decode("plain text"), "plain text")
    }

    func testDecodesNamedReferencesCaseSensitively() {
        XCTAssertEqual(
            HTMLEntities.decode("M&uuml;ller &amp; &Eacute;mile &lt;i&gt; &quot;a&quot; &apos;b&#39;"),
            "Müller & Émile <i> \"a\" 'b'"
        )
        XCTAssertEqual(HTMLEntities.decode("a&nbsp;b &ndash; &alpha;&le;&beta; &lang;x&rang;"), "a\u{A0}b – α≤β ⟨x⟩")
        XCTAssertEqual(HTMLEntities.decode("&EACUTE;"), "&EACUTE;")
    }

    func testLeavesUnknownAndMalformedReferencesLiteral() {
        for text in ["AT&T", "R&D; Q&A", "&bogus;", "&eacute", "&#233", "&#;", "&#x;", "&;", "& amp;", "&#12a;", "&"] {
            XCTAssertEqual(HTMLEntities.decode(text), text, text)
        }
    }

    func testFollowsHTMLRulesForUnusualCodePoints() {
        XCTAssertEqual(HTMLEntities.decode("O&#146;Brien &#150; &#x80;"), "O’Brien – €")
        XCTAssertEqual(
            HTMLEntities.decode("a&#0;b&#xD800;c&#x110000;d&#99999999999;"),
            "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}"
        )
    }

    func testDecodesOneLevelOfDoubleEscaping() {
        XCTAssertEqual(HTMLEntities.decode("St&amp;#233;fan &amp;quot;x&amp;quot;"), "Stéfan \"x\"")
        XCTAssertEqual(HTMLEntities.decode("&amp;&amp; AT&amp;T"), "&& AT&T")
    }
}
