import XCTest
@testable import SwiftLibCore

final class MetadataResolutionTests: XCTestCase {
    func testSeedExtractionFromImportedPDF() {
        let extracted = PDFService.ExtractedMetadata(
            title: "Deep Learning for Scientific Discovery",
            authors: [AuthorName(given: "Ashish", family: "Vaswani")],
            year: 2017,
            doi: "10.48550/arXiv.1706.03762",
            abstract: nil,
            journal: "NeurIPS"
        )

        let seed = MetadataResolutionSeed.fromImportedPDF(
            url: URL(fileURLWithPath: "/tmp/deep-learning-paper.pdf"),
            extracted: extracted
        )

        XCTAssertEqual(seed.title, "Deep Learning for Scientific Discovery")
        XCTAssertEqual(seed.firstAuthor, "Ashish Vaswani")
        XCTAssertEqual(seed.year, 2017)
        XCTAssertEqual(seed.doi, "10.48550/arXiv.1706.03762")
    }

    func testCleanPDFSeedFilenameStripsExtensionAndCounter() {
        XCTAssertEqual(
            MetadataResolution.cleanPDFSeedFilename("attention-is-all-you-need(1).pdf"),
            "attention-is-all-you-need"
        )
    }

    func testParseVolumeIssuePagesHandlesEnglishPatterns() {
        let parsed = MetadataResolution.parseVolumeIssuePages(from: "Nature, vol. 35, no. 3, pages: 120-128")

        XCTAssertEqual(parsed.volume, "35")
        XCTAssertEqual(parsed.issue, "3")
        XCTAssertEqual(parsed.pages, "120-128")
    }

    func testSuspiciousExtractedTitleRejectsGatewayTitles() {
        XCTAssertTrue(MetadataResolution.isSuspiciousExtractedTitle("Author"))
        XCTAssertTrue(MetadataResolution.isSuspiciousExtractedTitle("Title"))
        XCTAssertFalse(MetadataResolution.isSuspiciousExtractedTitle("Deep Learning for Scientific Discovery"))
    }

    func testShouldAcceptDOIReferenceRequiresMinimumCompleteness() {
        let seed = MetadataResolutionSeed(
            fileName: "vaswani-attention",
            title: "Attention Is All You Need",
            firstAuthor: "Vaswani",
            year: 2017,
            doi: "10.48550/arXiv.1706.03762"
        )
        let complete = Reference(
            title: "Attention Is All You Need",
            authors: [AuthorName(given: "Ashish", family: "Vaswani")],
            year: 2017,
            journal: "NeurIPS",
            doi: "10.48550/arXiv.1706.03762",
            abstract: "We propose a new simple network architecture, the Transformer."
        )
        let sparse = Reference(title: "Untitled", authors: [], year: nil)

        XCTAssertTrue(MetadataResolution.shouldAcceptDOIReference(complete, seed: seed))
        XCTAssertFalse(MetadataResolution.shouldAcceptDOIReference(sparse, seed: seed))
    }

    func testReferenceSeedFallsBackToPDFFileName() {
        let reference = Reference(
            title: "Untitled",
            authors: [],
            year: 2023,
            journal: "NeurIPS",
            pdfPath: "/tmp/attention-is-all-you-need-vaswani.pdf"
        )

        let seed = MetadataResolutionSeed.fromReference(reference)

        XCTAssertNotNil(seed.title)
    }

    func testPreferredAutomaticCandidateRequiresClearLead() {
        let strong = MetadataCandidate(
            source: .translationServer,
            title: "Attention Is All You Need",
            detailURL: "https://example.org/paper/strong",
            score: 0.95
        )
        let weak = MetadataCandidate(
            source: .translationServer,
            title: "An Attention Mechanism Survey",
            detailURL: "https://example.org/paper/weak",
            score: 0.72
        )
        let ambiguous = MetadataCandidate(
            source: .translationServer,
            title: "Attention Is All You Need",
            detailURL: "https://example.org/paper/ambiguous",
            score: 0.92
        )

        XCTAssertEqual(
            MetadataResolution.preferredAutomaticCandidate(from: [strong, weak])?.detailURL,
            strong.detailURL
        )
        XCTAssertNil(MetadataResolution.preferredAutomaticCandidate(from: [strong, ambiguous]))
    }

    func testMergeRefreshedReferencePreservesLocalFields() {
        let existing = Reference(
            id: 42,
            title: "Old Title",
            authors: [AuthorName(given: "Ashish", family: "Vaswani")],
            year: 2016,
            journal: "Old Journal",
            doi: nil,
            url: "https://example.com/original",
            abstract: "Old abstract",
            pdfPath: "/tmp/sample.pdf",
            notes: "My notes",
            webContent: "<article>cached</article>",
            siteName: "Custom Site",
            favicon: "icon.png",
            referenceType: .journalArticle,
            collectionId: 7
        )
        let refreshed = Reference(
            title: "Attention Is All You Need",
            authors: [AuthorName(given: "Ashish", family: "Vaswani")],
            year: 2017,
            journal: "NeurIPS",
            doi: "10.48550/arXiv.1706.03762",
            url: "https://arxiv.org/abs/1706.03762",
            abstract: "We propose the Transformer.",
            referenceType: .journalArticle
        )

        let merged = MetadataResolution.mergeRefreshedReference(primary: refreshed, existing: existing)

        XCTAssertEqual(merged.id, 42)
        XCTAssertEqual(merged.collectionId, 7)
        XCTAssertEqual(merged.pdfPath, "/tmp/sample.pdf")
        XCTAssertEqual(merged.notes, "My notes")
        XCTAssertEqual(merged.webContent, "<article>cached</article>")
        XCTAssertEqual(merged.title, "Attention Is All You Need")
        XCTAssertEqual(merged.journal, "NeurIPS")
        XCTAssertEqual(merged.doi, "10.48550/arXiv.1706.03762")
        XCTAssertTrue(MetadataResolution.hasMeaningfulRefreshChanges(original: existing, refreshed: merged))
    }
}
