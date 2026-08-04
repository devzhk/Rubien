import XCTest
import GRDB
@testable import RubienCore

final class HTMLToMarkdownConverterTests: XCTestCase {
    func testProjectsSemanticHTMLAndCompactsMathML() {
        let html = """
            <article>
              <h2>Scaling &amp; Structure</h2>
              <p>Read the <a href="https://example.com/paper">paper</a> and use
                <math display="inline" data-latex="a x^{p} &gt; 0">
                  <mrow><mi>a</mi><msup><mi>x</mi><mi>p</mi></msup></mrow>
                </math>.
              </p>
              <ul><li><strong>First</strong></li><li>Second</li></ul>
              <pre><code class="language-swift">let x = 1 &lt; 2</code></pre>
              <script>ignoreMe()</script>
            </article>
            """

        let markdown = HTMLToMarkdownConverter.convert(html)

        XCTAssertTrue(markdown.contains("## Scaling & Structure"), markdown)
        XCTAssertTrue(markdown.contains("[paper](https://example.com/paper)"), markdown)
        XCTAssertTrue(markdown.contains("$a x^{p} > 0$"), markdown)
        XCTAssertTrue(markdown.contains("- **First**"), markdown)
        XCTAssertTrue(markdown.contains("```swift\nlet x = 1 < 2\n```"), markdown)
        XCTAssertFalse(markdown.contains("<math"), markdown)
        XCTAssertFalse(markdown.contains("<mi>"), markdown)
        XCTAssertFalse(markdown.contains("ignoreMe"), markdown)
    }

    func testProjectsTableAndImage() {
        let html = """
            <table>
              <tr><th>Model</th><th>Score</th></tr>
              <tr><td>A | B</td><td>92</td></tr>
            </table>
            <p><img src="https://example.com/chart.png" alt="Scaling chart"></p>
            """

        let markdown = HTMLToMarkdownConverter.convert(html)

        XCTAssertTrue(markdown.contains("| Model | Score |"), markdown)
        XCTAssertTrue(markdown.contains("| --- | --- |"), markdown)
        XCTAssertTrue(markdown.contains(#"| A \| B | 92 |"#), markdown)
        XCTAssertTrue(markdown.contains("![Scaling chart](https://example.com/chart.png)"), markdown)
    }

    func testCodeDelimitersExpandPastEmbeddedBackticks() {
        let html = """
            <p>Use <code>value`with`ticks</code> here.</p>
            <pre><code class="language-markdown">before
            ```
            after</code></pre>
            <p>Following paragraph.</p>
            """

        let markdown = HTMLToMarkdownConverter.convert(html)

        XCTAssertTrue(markdown.contains("``value`with`ticks``"), markdown)
        XCTAssertTrue(markdown.contains("````markdown\nbefore\n```\nafter\n````"), markdown)
        XCTAssertTrue(markdown.hasSuffix("Following paragraph."), markdown)
    }

    func testProjectsManyBlocksWithoutLosingBoundaries() {
        let blockCount = 2_000
        let html = (0..<blockCount)
            .map { "<section><h3>Part \($0)</h3><p>Body \($0)</p></section>" }
            .joined()

        let markdown = HTMLToMarkdownConverter.convert(html)

        XCTAssertTrue(markdown.hasPrefix("### Part 0\n\nBody 0"), String(markdown.prefix(100)))
        XCTAssertTrue(
            markdown.hasSuffix("### Part \(blockCount - 1)\n\nBody \(blockCount - 1)"),
            String(markdown.suffix(100))
        )
    }

    func testExplicitMarkdownMarkerOverridesLegacyHTMLHeuristic() throws {
        let body = "<details><summary>Methods</summary>Markdown body</details>"
        let stored = try XCTUnwrap(Reference.encodeWebContent(body, format: .markdown))
        let decoded = try XCTUnwrap(Reference.decodeWebContent(stored))

        XCTAssertEqual(decoded.format, .markdown)
        XCTAssertEqual(decoded.body, body)

        let database = try AppDatabase(DatabaseQueue())
        XCTAssertThrowsError(
            try database.webContentRepresentation(referenceId: 1, source: decoded, format: .html)
        ) { error in
            XCTAssertEqual(error as? WebContentRepresentationError, .htmlUnavailable)
        }
    }

    func testHTMLProjectionIsCachedAndInvalidatedBySourceHash() throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(
            title: "Cached clip",
            webContent: Reference.encodeWebContent("<p>First body</p>", format: .html),
            referenceType: .webpage
        )
        try database.dbWriter.write { db in try reference.insert(db) }
        let id = try XCTUnwrap(reference.id)
        let firstSource = try XCTUnwrap(reference.decodedWebContent)

        let first = try database.webContentRepresentation(
            referenceId: id,
            source: firstSource,
            format: .markdown
        )
        XCTAssertEqual(first.body, "First body")
        XCTAssertEqual(first.format, .markdown)

        try database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE webContentMarkdownCache SET markdown = 'cached sentinel' WHERE referenceId = ?",
                arguments: [id]
            )
        }
        let reused = try database.webContentRepresentation(
            referenceId: id,
            source: firstSource,
            format: .markdown
        )
        XCTAssertEqual(reused.body, "cached sentinel")

        let changed = Reference.DecodedWebContent(body: "<p>Second body</p>", format: .html)
        let refreshed = try database.webContentRepresentation(
            referenceId: id,
            source: changed,
            format: .markdown
        )
        XCTAssertEqual(refreshed.body, "Second body")
        let stored: String? = try database.dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT markdown FROM webContentMarkdownCache WHERE referenceId = ?",
                arguments: [id]
            )
        }
        XCTAssertEqual(stored, "Second body")
    }

    func testExplicitHTMLAndMarkdownSourceBehavior() throws {
        let database = try AppDatabase(DatabaseQueue())
        let html = Reference.DecodedWebContent(body: "<p>Body</p>", format: .html)
        XCTAssertEqual(
            try database.webContentRepresentation(referenceId: 1, source: html, format: .html),
            html
        )

        let markdown = Reference.DecodedWebContent(body: "# Body", format: .markdown)
        XCTAssertEqual(
            try database.webContentRepresentation(referenceId: 1, source: markdown, format: .markdown),
            markdown
        )
        XCTAssertThrowsError(
            try database.webContentRepresentation(referenceId: 1, source: markdown, format: .html)
        ) { error in
            XCTAssertEqual(error as? WebContentRepresentationError, .htmlUnavailable)
        }
    }

    func testV12CacheTableIsLocalOnlyAndCascades() throws {
        let database = try AppDatabase(DatabaseQueue())
        let columns: [String] = try database.dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('webContentMarkdownCache') ORDER BY cid"
            ).map { $0["name"] }
        }
        XCTAssertEqual(columns, ["referenceId", "sourceHash", "converterVersion", "markdown"])

        let triggerCount: Int = try database.dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'webContentMarkdownCache'"
            ) ?? -1
        }
        XCTAssertEqual(triggerCount, 0)

        var reference = Reference(title: "Cascade test", referenceType: .webpage)
        try database.dbWriter.write { db in
            try reference.insert(db)
            let id = try XCTUnwrap(reference.id)
            try db.execute(
                sql: """
                    INSERT INTO webContentMarkdownCache
                        (referenceId, sourceHash, converterVersion, markdown)
                    VALUES (?, 'hash', 1, 'body')
                    """,
                arguments: [id]
            )
            _ = try reference.delete(db)
        }
        let cachedRows = try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM webContentMarkdownCache") ?? -1
        }
        XCTAssertEqual(cachedRows, 0)
    }
}
