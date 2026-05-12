import XCTest
@testable import RubienCore

final class PDFDownloadServiceTests: XCTestCase {

    // MARK: - preprintServerPDFURL

    func testPreprintURLForBioRxiv() {
        let ref = Reference(
            title: "Sample",
            journal: "bioRxiv",
            doi: "10.1101/2024.01.01.123456"
        )
        XCTAssertEqual(
            PDFDownloadService.preprintServerPDFURL(for: ref)?.absoluteString,
            "https://www.biorxiv.org/content/10.1101/2024.01.01.123456.full.pdf"
        )
    }

    func testPreprintURLForMedRxiv() {
        let ref = Reference(
            title: "Sample",
            journal: "medRxiv",
            doi: "10.1101/2024.05.05.123456"
        )
        XCTAssertEqual(
            PDFDownloadService.preprintServerPDFURL(for: ref)?.absoluteString,
            "https://www.medrxiv.org/content/10.1101/2024.05.05.123456.full.pdf"
        )
    }

    func testPreprintURLIsCaseInsensitiveOnJournalName() {
        let upper = Reference(title: "x", journal: "BIORXIV", doi: "10.1101/abc")
        XCTAssertEqual(
            PDFDownloadService.preprintServerPDFURL(for: upper)?.host,
            "www.biorxiv.org"
        )
        let padded = Reference(title: "x", journal: " BioRxiv ", doi: "10.1101/abc")
        XCTAssertEqual(
            PDFDownloadService.preprintServerPDFURL(for: padded)?.host,
            "www.biorxiv.org"
        )
    }

    func testPreprintURLReturnsNilForColdSpringHarborJournal() {
        // 10.1101/gr.* is Genome Research — same DOI prefix, must NOT route to
        // bioRxiv/medRxiv. Caller falls back to OpenAlex.
        let ref = Reference(
            title: "x",
            journal: "Genome Research",
            doi: "10.1101/gr.1234567"
        )
        XCTAssertNil(PDFDownloadService.preprintServerPDFURL(for: ref))
    }

    func testPreprintURLReturnsNilWhenJournalMissing() {
        // Don't guess — if we don't know the server, fall back to OpenAlex.
        let ref = Reference(title: "x", journal: nil, doi: "10.1101/2024.01.01.123456")
        XCTAssertNil(PDFDownloadService.preprintServerPDFURL(for: ref))
    }

    func testPreprintURLReturnsNilForNonPreprintDOIPrefix() {
        let ref = Reference(title: "x", journal: "bioRxiv", doi: "10.1038/nature12373")
        XCTAssertNil(PDFDownloadService.preprintServerPDFURL(for: ref))
    }

    func testPreprintURLDetectsViaCrossRefURLForNewBioRxivPrefix() {
        // bioRxiv issued a second DOI prefix (10.64898/) — CrossRef may also
        // omit container-title on posted-content records. The URL field is the
        // robust signal.
        let ref = Reference(
            title: "x",
            doi: "10.64898/2026.05.08.723360",
            url: "http://biorxiv.org/lookup/doi/10.64898/2026.05.08.723360"
        )
        XCTAssertEqual(
            PDFDownloadService.preprintServerPDFURL(for: ref)?.absoluteString,
            "https://www.biorxiv.org/content/10.64898/2026.05.08.723360.full.pdf"
        )
    }

    func testPreprintURLDetectsViaCrossRefURLForMedRxiv() {
        let ref = Reference(
            title: "x",
            doi: "10.1101/2024.05.05.123456",
            url: "https://www.medrxiv.org/lookup/doi/10.1101/2024.05.05.123456"
        )
        XCTAssertEqual(
            PDFDownloadService.preprintServerPDFURL(for: ref)?.host,
            "www.medrxiv.org"
        )
    }

    func testPreprintURLURLBasedDetectionOverridesJournalName() {
        // If CrossRef url says biorxiv but journal is mistakenly empty/wrong,
        // the URL signal should still win.
        let ref = Reference(
            title: "x",
            doi: "10.1101/abc",
            url: "http://www.biorxiv.org/content/abc"
        )
        XCTAssertEqual(
            PDFDownloadService.preprintServerPDFURL(for: ref)?.host,
            "www.biorxiv.org"
        )
    }

    func testPreprintURLReturnsNilForCSHJournalEvenWithMatchingPrefix() {
        // Genome Research shares 10.1101/ but its URL resolves to cshlp.org.
        // URL-based detection should naturally exclude it.
        let ref = Reference(
            title: "x",
            journal: "Genome Research",
            doi: "10.1101/gr.275869.121",
            url: "http://genome.cshlp.org/lookup/doi/10.1101/gr.275869.121"
        )
        XCTAssertNil(PDFDownloadService.preprintServerPDFURL(for: ref))
    }

    // MARK: - DownloadError descriptions

    func testDownloadErrorDescriptions() {
        // Ensure the new error path text doesn't regress.
        XCTAssertNotNil(PDFDownloadService.DownloadError.notAPDF.errorDescription)
        XCTAssertNotNil(PDFDownloadService.DownloadError.noOpenAccessPDF.errorDescription)
    }
}
