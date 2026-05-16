#if canImport(PDFKit)
import XCTest
import PDFKit
import CoreText
@testable import RubienCore
@testable import RubienPDFKit

final class PDFExtractorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PDFExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    /// Build a PDF on disk with one page per entry in `pages`. Each page renders
    /// the corresponding text so `PDFPage.string` returns it. If `pages[i]` is
    /// empty, the page renders blank — used to simulate "no text layer" pages.
    private func makePDF(pages: [String], outline: [(title: String, level: Int, page: Int)] = []) throws -> URL {
        let url = tmpDir.appendingPathComponent("test-\(UUID().uuidString).pdf")
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            XCTFail("Failed to create CGDataConsumer")
            throw NSError(domain: "test", code: 1)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create CGPDFContext")
            throw NSError(domain: "test", code: 2)
        }

        for text in pages {
            ctx.beginPDFPage(nil)
            if !text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.black
                ]
                let attrStr = NSAttributedString(string: text, attributes: attrs)
                let path = CGPath(rect: CGRect(x: 50, y: 50, width: 512, height: 700), transform: nil)
                let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attrStr.length), path, nil)
                CTFrameDraw(frame, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()

        try data.write(to: url, options: [])

        if !outline.isEmpty {
            return try attachOutline(to: url, entries: outline)
        }
        return url
    }

    /// Open `url`, attach an outline built from `entries`, and write to a sibling
    /// `outlined-...pdf`. Returns the new URL.
    private func attachOutline(
        to url: URL,
        entries: [(title: String, level: Int, page: Int)]
    ) throws -> URL {
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Could not open generated PDF")
            throw NSError(domain: "test", code: 3)
        }
        let root = PDFOutline()
        // Track most-recent outline at each level so we can chain children.
        var lastByLevel: [Int: PDFOutline] = [0: root]
        for entry in entries {
            let item = PDFOutline()
            item.label = entry.title
            if let page = doc.page(at: entry.page - 1) {
                let h = page.bounds(for: .mediaBox).height
                item.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: h))
            }
            let parent = lastByLevel[entry.level - 1] ?? root
            parent.insertChild(item, at: parent.numberOfChildren)
            lastByLevel[entry.level] = item
            // Drop deeper-level memos (a level-1 entry resets level-2+ chains).
            for k in lastByLevel.keys where k > entry.level {
                lastByLevel.removeValue(forKey: k)
            }
        }
        doc.outlineRoot = root

        let outlinedURL = tmpDir.appendingPathComponent("outlined-\(UUID().uuidString).pdf")
        guard doc.write(to: outlinedURL) else {
            XCTFail("Failed to write outlined PDF")
            throw NSError(domain: "test", code: 4)
        }
        return outlinedURL
    }

    // MARK: - info

    func testInfoReturnsBasicMetadata() throws {
        let url = try makePDF(pages: ["Page 1 text", "Page 2 text", "Page 3 text"])
        let info = try PDFExtractor.info(at: url)
        XCTAssertEqual(info.pageCount, 3)
        XCTAssertTrue(info.hasTextLayer)
        XCTAssertGreaterThan(info.fileBytes, 0)
        XCTAssertFalse(info.isEncrypted)
        XCTAssertNil(info.sections, "PDF without an outline should report sections == nil")
    }

    func testHasTextLayerSamplesFirstMiddleLast() throws {
        // Three pages: first and last are blank, middle has text.
        // sampleHasTextLayer should still return true because middle samples non-empty.
        let url = try makePDF(pages: ["", "Has content here", ""])
        let info = try PDFExtractor.info(at: url)
        XCTAssertTrue(info.hasTextLayer, "Sampling middle page should find text")
    }

    func testHasTextLayerFalseWhenAllSamplesEmpty() throws {
        let url = try makePDF(pages: ["", "", ""])
        let info = try PDFExtractor.info(at: url)
        XCTAssertFalse(info.hasTextLayer)
    }

    // MARK: - outline + endPage rule

    func testOutlineParsesAndComputesEndPagesCoveringSubsections() throws {
        // Outline: parent "2 Related Work" should span p3-4 (covering subsections),
        // even though the next flat-list entry is "2.1 Transformers" at p3.
        let url = try makePDF(
            pages: Array(repeating: "lorem", count: 14),
            outline: [
                ("1 Intro", 1, 1),
                ("2 Related Work", 1, 3),
                ("2.1 Transformers", 2, 3),
                ("2.2 Attention", 2, 4),
                ("3 Method", 1, 5),
                ("5 Conclusion", 1, 13)
            ]
        )
        let info = try PDFExtractor.info(at: url)
        let sections = try XCTUnwrap(info.sections)
        XCTAssertEqual(sections.count, 6)

        XCTAssertEqual(sections[0].title, "1 Intro")
        XCTAssertEqual(sections[0].startPage, 1)
        XCTAssertEqual(sections[0].endPage, 2,
                       "Intro ends at p2 (next L1 'Related Work' starts at p3)")

        XCTAssertEqual(sections[1].title, "2 Related Work")
        XCTAssertEqual(sections[1].startPage, 3)
        XCTAssertEqual(sections[1].endPage, 4,
                       "Parent should cover all subsections through next-L1 'Method' at p5")

        XCTAssertEqual(sections[2].title, "2.1 Transformers")
        XCTAssertEqual(sections[2].startPage, 3)
        XCTAssertEqual(sections[2].endPage, 3,
                       "Sibling at level ≤ 2 ('2.2 Attention') starts at p4")

        XCTAssertEqual(sections[3].title, "2.2 Attention")
        XCTAssertEqual(sections[3].startPage, 4)
        XCTAssertEqual(sections[3].endPage, 4,
                       "Next entry at level ≤ 2 ('3 Method') starts at p5")

        XCTAssertEqual(sections[5].title, "5 Conclusion")
        XCTAssertEqual(sections[5].startPage, 13)
        XCTAssertEqual(sections[5].endPage, 14, "Last entry inherits pageCount")
    }

    // MARK: - resolveSections

    func testResolveSectionsSubstringMatchAndUnmatched() throws {
        let url = try makePDF(
            pages: Array(repeating: "x", count: 6),
            outline: [
                ("1 Intro", 1, 1),
                ("2 Related Work", 1, 2),
                ("2.1 Transformers", 2, 2),
                ("3 Method", 1, 4)
            ]
        )
        let info = try PDFExtractor.info(at: url)
        let sections = try XCTUnwrap(info.sections)

        let (matched, unmatched) = PDFExtractor.resolveSections(
            ["Related Work", "Transformers", "DoesNotExist"],
            in: sections
        )
        XCTAssertEqual(matched.map(\.title), ["2 Related Work", "2.1 Transformers"])
        XCTAssertEqual(unmatched, ["DoesNotExist"])

        // Multi-match: "2" substring matches three titles ("2 Related Work",
        // "2.1 Transformers", and the chapter "2 Related Work"'s subtree
        // titles all start with "2"). Verify multiple titles come back.
        let (multi, unmatchedMulti) = PDFExtractor.resolveSections(["2"], in: sections)
        XCTAssertGreaterThanOrEqual(multi.count, 2)
        XCTAssertEqual(unmatchedMulti, [])
    }

    // MARK: - extractText

    func testExtractTextAllPages() throws {
        let url = try makePDF(pages: ["Alpha", "Beta", "Gamma"])
        let result = try PDFExtractor.extractText(at: url, selection: .allPages, maxChars: 50_000)
        XCTAssertEqual(result.pages.count, 3)
        XCTAssertEqual(result.pages.map(\.index), [1, 2, 3])
        XCTAssertTrue(result.pages[0].text.contains("Alpha"))
        XCTAssertEqual(result.selection.mode, .all)
    }

    func testExtractTextWithPageRange() throws {
        let url = try makePDF(pages: ["A", "B", "C", "D", "E"])
        let result = try PDFExtractor.extractText(
            at: url, selection: .pages([1...2, 4...4]), maxChars: 50_000
        )
        XCTAssertEqual(result.pages.map(\.index), [1, 2, 4])
        XCTAssertEqual(result.selection.mode, .page)
    }

    func testExtractTextBySectionReturnsParentRangeWithBreadcrumb() throws {
        let url = try makePDF(
            pages: ["p1", "p2", "p3", "p4", "p5", "p6"],
            outline: [
                ("1 Intro", 1, 1),
                ("2 Related Work", 1, 3),
                ("2.1 Transformers", 2, 3),
                ("2.2 Attention", 2, 4),
                ("3 Method", 1, 5)
            ]
        )
        let result = try PDFExtractor.extractText(
            at: url, selection: .sections(["Related Work"]), maxChars: 50_000
        )
        XCTAssertEqual(result.pages.map(\.index), [3, 4])
        XCTAssertEqual(result.pages[0].sectionPath, ["2 Related Work", "2.1 Transformers"])
        XCTAssertEqual(result.pages[1].sectionPath, ["2 Related Work", "2.2 Attention"])
        XCTAssertEqual(result.selection.matchedSections, ["2 Related Work"])
        XCTAssertEqual(result.selection.unmatched, [])
    }

    func testExtractTextBySubsectionReturnsScopedRange() throws {
        let url = try makePDF(
            pages: ["p1", "p2", "p3", "p4", "p5"],
            outline: [
                ("1 Intro", 1, 1),
                ("2 Related Work", 1, 2),
                ("2.1 Transformers", 2, 2),
                ("2.2 Attention", 2, 3),
                ("3 Method", 1, 4)
            ]
        )
        let result = try PDFExtractor.extractText(
            at: url, selection: .sections(["Transformers"]), maxChars: 50_000
        )
        XCTAssertEqual(result.pages.map(\.index), [2])
        XCTAssertEqual(result.pages[0].sectionPath, ["2 Related Work", "2.1 Transformers"])
    }

    func testExtractTextSectionsThrowsOnOutlineLessPDF() throws {
        let url = try makePDF(pages: ["A", "B"])
        XCTAssertThrowsError(
            try PDFExtractor.extractText(at: url, selection: .sections(["Anything"]), maxChars: 50_000)
        ) { err in
            guard let e = err as? PDFExtractor.ExtractError else {
                XCTFail("Expected ExtractError, got \(err)")
                return
            }
            XCTAssertEqual(e.code, "no-outline")
        }
    }

    func testExtractTextSectionUnmatchedReturnsEmptyResultNotError() throws {
        let url = try makePDF(
            pages: ["a", "b", "c"],
            outline: [("1 Intro", 1, 1), ("2 Method", 1, 2)]
        )
        let result = try PDFExtractor.extractText(
            at: url, selection: .sections(["Nonexistent"]), maxChars: 50_000
        )
        XCTAssertEqual(result.pages.count, 0)
        XCTAssertEqual(result.selection.matchedSections, [])
        XCTAssertEqual(result.selection.unmatched, ["Nonexistent"])
    }

    func testExtractTextTruncatesAtPageBoundary() throws {
        // 3 pages of long content; cap at 10 chars. Should return one page
        // and set truncated=true (first page always included).
        let long = String(repeating: "x", count: 200)
        let url = try makePDF(pages: [long, long, long])
        let result = try PDFExtractor.extractText(
            at: url, selection: .allPages, maxChars: 10
        )
        XCTAssertEqual(result.pages.count, 1, "First page always included even when oversize")
        XCTAssertTrue(result.truncated)
    }

    // MARK: - renderPage

    func testRenderPageJPEGProducesValidImage() throws {
        let url = try makePDF(pages: ["render me"])
        let img = try PDFExtractor.renderPage(
            at: url, page: 1, scale: 1.0, maxBytes: 5_000_000, format: .jpeg
        )
        XCTAssertEqual(img.mimeType, "image/jpeg")
        XCTAssertGreaterThan(img.data.count, 100)
        // JPEG signature: FF D8 FF
        XCTAssertEqual(img.data[0], 0xFF)
        XCTAssertEqual(img.data[1], 0xD8)
        XCTAssertEqual(img.data[2], 0xFF)
        XCTAssertNotNil(img.qualityUsed)
    }

    func testRenderPagePNGProducesValidImage() throws {
        let url = try makePDF(pages: ["render me"])
        let img = try PDFExtractor.renderPage(
            at: url, page: 1, scale: 1.0, maxBytes: 5_000_000, format: .png
        )
        XCTAssertEqual(img.mimeType, "image/png")
        XCTAssertGreaterThan(img.data.count, 100)
        // PNG signature: 89 50 4E 47 0D 0A 1A 0A
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for (i, b) in sig.enumerated() { XCTAssertEqual(img.data[i], b) }
        XCTAssertNil(img.qualityUsed)
    }

    func testRenderPageOutOfRangeThrows() throws {
        let url = try makePDF(pages: ["only one"])
        XCTAssertThrowsError(
            try PDFExtractor.renderPage(at: url, page: 99, scale: 1.0, maxBytes: 5_000_000, format: .jpeg)
        ) { err in
            guard let e = err as? PDFExtractor.ExtractError else {
                XCTFail("Expected ExtractError")
                return
            }
            XCTAssertEqual(e.code, "page-out-of-range")
        }
    }

    // MARK: - parsePageRange

    func testParsePageRangeAcceptsCommonForms() throws {
        let pageCount = 14
        XCTAssertEqual(
            try PDFExtractor.parsePageRange("1-3", pageCount: pageCount).map { ($0.lowerBound, $0.upperBound) }.map { "\($0.0)-\($0.1)" },
            ["1-3"]
        )
        XCTAssertEqual(
            try PDFExtractor.parsePageRange("1-3,8-10", pageCount: pageCount).map { ($0.lowerBound, $0.upperBound) }.map { "\($0.0)-\($0.1)" },
            ["1-3", "8-10"]
        )
        XCTAssertEqual(
            try PDFExtractor.parsePageRange("12-", pageCount: pageCount).map { ($0.lowerBound, $0.upperBound) }.map { "\($0.0)-\($0.1)" },
            ["12-14"]
        )
        XCTAssertEqual(
            try PDFExtractor.parsePageRange("7", pageCount: pageCount).map { ($0.lowerBound, $0.upperBound) }.map { "\($0.0)-\($0.1)" },
            ["7-7"]
        )
    }

    func testParsePageRangeRejectsInvalid() {
        XCTAssertThrowsError(try PDFExtractor.parsePageRange("", pageCount: 10))
        XCTAssertThrowsError(try PDFExtractor.parsePageRange("3-1", pageCount: 10))
        XCTAssertThrowsError(try PDFExtractor.parsePageRange("abc", pageCount: 10))
        XCTAssertThrowsError(try PDFExtractor.parsePageRange("0-5", pageCount: 10))
    }

    // MARK: - sectionPath

    // MARK: - container nodes without destinations

    func testOutlinePreservesContainerNodesWithoutDestinations() throws {
        // Many real PDFs (especially books) use top-level container outline
        // entries like "Volume 1" or "Part I" that have no destination of
        // their own — they only group children. Those used to be dropped,
        // making `pdf text --section "Volume 1"` impossible. The walker now
        // backfills the parent's startPage from its first descendant.
        let url = try makeContainerOutlinePDF()
        let info = try PDFExtractor.info(at: url)
        let sections = try XCTUnwrap(info.sections)

        let titles = sections.map(\.title)
        XCTAssertTrue(titles.contains("Volume 1 (container)"),
                      "Container bookmark with no destination should still appear")

        let volume = try XCTUnwrap(sections.first { $0.title == "Volume 1 (container)" })
        XCTAssertEqual(volume.level, 1)
        XCTAssertEqual(volume.startPage, 2,
                       "Container should borrow its first descendant's startPage (Chapter 1 at p2)")
        XCTAssertEqual(volume.endPage, 3,
                       "Container spans only its contained chapters — Chapter 3 is a level-1 sibling, not nested, so it bounds Volume 1's range.")

        let ch3 = try XCTUnwrap(sections.first { $0.title == "Chapter 3" })
        XCTAssertEqual(ch3.startPage, 4)
        XCTAssertEqual(ch3.endPage, 4, "Last L1 entry inherits pageCount")
    }

    func testOutlineDropsTrulyOrphanContainers() throws {
        // A container with no destination AND no descendants with
        // destinations is genuinely useless — we drop it rather than emit a
        // section pointing nowhere.
        let url = try makePDF(pages: ["a", "b"])
        guard let doc = PDFDocument(url: url) else { XCTFail(); return }
        let root = PDFOutline()
        let orphan = PDFOutline()
        orphan.label = "Orphan With No Destination And No Children"
        root.insertChild(orphan, at: 0)
        // Plus a real entry alongside, so the document still has *some* outline.
        let real = PDFOutline()
        real.label = "Real Entry"
        if let p = doc.page(at: 0) {
            real.destination = PDFDestination(page: p, at: NSPoint(x: 0, y: 100))
        }
        root.insertChild(real, at: 1)
        doc.outlineRoot = root
        let outURL = tmpDir.appendingPathComponent("orphan-\(UUID().uuidString).pdf")
        XCTAssertTrue(doc.write(to: outURL))

        let info = try PDFExtractor.info(at: outURL)
        let sections = try XCTUnwrap(info.sections)
        let titles = sections.map(\.title)
        XCTAssertEqual(titles, ["Real Entry"],
                       "Orphan container (no destination, no kids with destination) should be dropped")
    }

    /// Build a 4-page PDF whose outline is:
    /// - Volume 1 (container)        ← no destination
    ///     - Chapter 1 (p2)
    ///     - Chapter 2 (p3)
    /// - Chapter 3 (p4)
    private func makeContainerOutlinePDF() throws -> URL {
        let url = try makePDF(pages: ["p1", "p2", "p3", "p4"])
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Could not open PDF")
            throw NSError(domain: "test", code: 9)
        }
        let root = PDFOutline()
        let volume = PDFOutline()
        volume.label = "Volume 1 (container)"
        // Intentionally leave volume.destination = nil
        root.insertChild(volume, at: 0)

        let ch1 = PDFOutline()
        ch1.label = "Chapter 1"
        if let p2 = doc.page(at: 1) {
            ch1.destination = PDFDestination(page: p2, at: NSPoint(x: 0, y: 700))
        }
        volume.insertChild(ch1, at: 0)

        let ch2 = PDFOutline()
        ch2.label = "Chapter 2"
        if let p3 = doc.page(at: 2) {
            ch2.destination = PDFDestination(page: p3, at: NSPoint(x: 0, y: 700))
        }
        volume.insertChild(ch2, at: 1)

        let ch3 = PDFOutline()
        ch3.label = "Chapter 3"
        if let p4 = doc.page(at: 3) {
            ch3.destination = PDFDestination(page: p4, at: NSPoint(x: 0, y: 700))
        }
        root.insertChild(ch3, at: 1)

        doc.outlineRoot = root
        let outURL = tmpDir.appendingPathComponent("container-\(UUID().uuidString).pdf")
        XCTAssertTrue(doc.write(to: outURL))
        return outURL
    }

    func testSectionPathDeepestWins() throws {
        let url = try makePDF(
            pages: ["a", "b", "c", "d"],
            outline: [
                ("Chapter A", 1, 1),
                ("A.1", 2, 1),
                ("Chapter B", 1, 3),
                ("B.1", 2, 3)
            ]
        )
        let info = try PDFExtractor.info(at: url)
        let sections = try XCTUnwrap(info.sections)

        XCTAssertEqual(
            PDFExtractor.sectionPath(forPage: 1, in: sections),
            ["Chapter A", "A.1"]
        )
        XCTAssertEqual(
            PDFExtractor.sectionPath(forPage: 3, in: sections),
            ["Chapter B", "B.1"]
        )
    }
}
#endif // canImport(PDFKit)
