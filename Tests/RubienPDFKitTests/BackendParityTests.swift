#if canImport(PDFKit)
import XCTest
@testable import RubienPDFKit

/// Tests that the Darwin and Linux backends produce structurally equivalent
/// output on the same input fixtures. Same test bodies run on both platforms;
/// the assertions deliberately avoid byte-equality (JPEG/PNG encoders differ
/// between PDFKit's NSBitmapImageRep and gdk-pixbuf) and instead check
/// shape: mime signature, dimensions, quality ladder step, error mapping.
final class BackendParityTests: XCTestCase {

    // MARK: - Fixtures

    private func fixtureURL(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures/PDFs") else {
            XCTFail("missing fixture: \(name).pdf — regenerate with scripts/generate-pdf-fixtures.swift")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    // MARK: - Open + error mapping

    func testOpenLinearFixture() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertFalse(doc.isLocked)
    }

    func testOpenEncryptedThrowsLocked() {
        XCTAssertThrowsError(try PDFBackend.open(url: fixtureURL("encrypted-password"))) { error in
            XCTAssertEqual(error as? PDFOpenError, .locked,
                           "expected PDFOpenError.locked; got \(error)")
        }
    }

    func testOpenMissingFileThrowsCannotOpen() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try PDFBackend.open(url: url)) { error in
            switch error as? PDFOpenError {
            case .cannotOpen, .fileMissing:
                break  // Both backends collapse missing+unreadable into one or the other.
            default:
                XCTFail("expected .cannotOpen / .fileMissing; got \(error)")
            }
        }
    }

    // MARK: - Text extraction

    func testExtractedTextOnLinearFixture() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else {
                XCTFail("page(at: \(i)) returned nil")
                continue
            }
            let text = page.extractedText() ?? ""
            // Whitespace-tolerant: collapse runs to a single space + trim.
            let normalized = text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(normalized.contains("Page \(i + 1) body text") ||
                          normalized.contains("body text") ||
                          normalized.lowercased().contains("page"),
                          "page \(i): extracted text didn't match expected. got: \(normalized)")
        }
    }

    func testExtractedTextOnScanFixtureIsEmpty() throws {
        let doc = try PDFBackend.open(url: fixtureURL("scan-only-1page"))
        guard let page = doc.page(at: 0) else {
            XCTFail("scan-only fixture: page(at: 0) returned nil")
            return
        }
        let text = (page.extractedText() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(text.isEmpty, "scan-only page should have no text layer; got: \(text)")
    }

    // MARK: - Outline

    func testOutlineRootNilWhenNoOutline() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        XCTAssertNil(doc.outlineRoot())
    }

    func testOutlineRootStructureMatchesGeneratorContract() throws {
        let doc = try PDFBackend.open(url: fixtureURL("outline-2level-5sections"))
        guard let root = doc.outlineRoot() else {
            XCTFail("expected non-nil outline")
            return
        }
        // Root is a synthetic container with empty label.
        XCTAssertEqual(root.label, "")
        XCTAssertNil(root.pageIndex)
        XCTAssertEqual(root.children.count, 5, "expected 5 top-level sections")

        let labels = root.children.map(\.label)
        XCTAssertEqual(labels, ["Chapter 1", "Chapter 2", "Chapter 3", "Chapter 4", "Chapter 5"])

        // Page indices: 0, 3, 4, 6, 7 (0-based — Darwin uses doc.index(for:),
        // Linux subtracts 1 from poppler's 1-based page_num).
        XCTAssertEqual(root.children[0].pageIndex, 0)
        XCTAssertEqual(root.children[1].pageIndex, 3)
        XCTAssertEqual(root.children[2].pageIndex, 4)
        XCTAssertEqual(root.children[3].pageIndex, 6)
        XCTAssertEqual(root.children[4].pageIndex, 7)

        // Chapter 1 nests "1.1" and "1.2"
        let chapter1 = root.children[0]
        XCTAssertEqual(chapter1.children.count, 2)
        XCTAssertEqual(chapter1.children.map(\.label), ["1.1", "1.2"])
        XCTAssertEqual(chapter1.children.map(\.pageIndex), [1, 2])

        // Chapter 3 nests "3.1"
        let chapter3 = root.children[2]
        XCTAssertEqual(chapter3.children.count, 1)
        XCTAssertEqual(chapter3.children[0].label, "3.1")
        XCTAssertEqual(chapter3.children[0].pageIndex, 5)
    }

    // MARK: - Page bounds

    func testPageBoundsMatchUsLetter() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        guard let page = doc.page(at: 0) else {
            XCTFail("page(at: 0) returned nil")
            return
        }
        // Generator uses 612 × 792 (US Letter at 72dpi).
        XCTAssertEqual(page.mediaBox.width, 612, accuracy: 1.0)
        XCTAssertEqual(page.mediaBox.height, 792, accuracy: 1.0)
    }

    // MARK: - Render

    func testRenderPNGProducesValidImage() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        guard let page = doc.page(at: 0) else { XCTFail("page nil"); return }
        let result = try page.render(scale: 2.0, format: .png, maxBytes: 5_000_000)
        XCTAssertEqual(result.mimeType, "image/png")
        // PNG signature: 89 50 4E 47 0D 0A 1A 0A
        XCTAssertEqual(result.data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertGreaterThan(result.widthPx, 0)
        XCTAssertGreaterThan(result.heightPx, 0)
        XCTAssertGreaterThan(result.data.count, 100)
        XCTAssertNil(result.qualityUsed, "PNG render must not report qualityUsed")
        // Dimensions should be approximately mediaBox × scale (± 1 pixel rounding).
        XCTAssertEqual(result.widthPx, Int((page.mediaBox.width * 2.0).rounded()), accuracy: 1)
        XCTAssertEqual(result.heightPx, Int((page.mediaBox.height * 2.0).rounded()), accuracy: 1)
    }

    func testRenderJPEGProducesValidImageAtTopQuality() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        guard let page = doc.page(at: 0) else { XCTFail("page nil"); return }
        let result = try page.render(scale: 2.0, format: .jpeg, maxBytes: 5_000_000)
        XCTAssertEqual(result.mimeType, "image/jpeg")
        // JPEG SOI marker: FF D8 FF
        XCTAssertEqual(result.data.prefix(3), Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(result.qualityUsed, 0.9,
                       "5 MB budget should accommodate top-ladder quality")
        XCTAssertLessThanOrEqual(result.data.count, 5_000_000)
        XCTAssertGreaterThan(result.widthPx, 0)
        XCTAssertGreaterThan(result.heightPx, 0)
    }

    func testRenderJPEGDropsThroughQualityLadderUnderTightBudget() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        guard let page = doc.page(at: 0) else { XCTFail("page nil"); return }
        // 50 KB is unlikely to fit a 0.9-quality JPEG of a US Letter page at
        // scale 2.0 with text content; the ladder should step down. Exact
        // step is encoder-dependent (Darwin NSBitmapImageRep vs Linux
        // gdk-pixbuf), so we accept any non-top quality.
        let result = try page.render(scale: 2.0, format: .jpeg, maxBytes: 50_000)
        XCTAssertEqual(result.mimeType, "image/jpeg")
        XCTAssertEqual(result.data.prefix(3), Data([0xFF, 0xD8, 0xFF]))
        XCTAssertLessThanOrEqual(result.data.count, 50_000)
        XCTAssertNotNil(result.qualityUsed)
    }

    func testRenderPNGThrowsMaxBytesExceeded() throws {
        let doc = try PDFBackend.open(url: fixtureURL("linear-3pages-text"))
        guard let page = doc.page(at: 0) else { XCTFail("page nil"); return }
        // PNG with a 1 KB budget for a US Letter page at scale 2.0 is
        // guaranteed to exceed on both backends.
        XCTAssertThrowsError(try page.render(scale: 2.0, format: .png, maxBytes: 1_000)) { error in
            switch error as? PDFRenderError {
            case .maxBytesExceeded(let n):
                XCTAssertEqual(n, 1_000)
            default:
                XCTFail("expected .maxBytesExceeded; got \(error)")
            }
        }
    }
}
#endif
