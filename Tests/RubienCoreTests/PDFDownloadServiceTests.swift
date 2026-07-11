import Foundation
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

    // MARK: - temporary downloads

    func testDownloadTemporaryWritesValidatedPDFToRequestedDirectory() async throws {
        let remoteURL = "https://example.test/papers/temporary.pdf"
        let expectedData = Data("%PDF-1.7\ntemporary".utf8)
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/pdf; charset=binary",
            data: expectedData
        )
        let destinationDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        let downloadedURL = try await PDFDownloadService.downloadTemporary(
            from: URL(string: remoteURL)!,
            suggestedFilename: "temporary.pdf",
            destinationDirectory: destinationDirectory,
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(downloadedURL.deletingLastPathComponent(), destinationDirectory)
        XCTAssertEqual(downloadedURL.lastPathComponent, "temporary.pdf")
        XCTAssertEqual(try Data(contentsOf: downloadedURL), expectedData)
    }

    func testDownloadTemporaryAcceptsGenericBinaryPDFMediaTypeWhenMagicIsValid() async throws {
        let remoteURL = "https://example.test/papers/github-hosted.pdf"
        let expectedData = Data("%PDF-1.7\\ngeneric binary PDF".utf8)
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/octet-stream",
            data: expectedData
        )
        let destinationDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        let downloadedURL = try await PDFDownloadService.downloadTemporary(
            from: URL(string: remoteURL)!,
            suggestedFilename: "github-hosted.pdf",
            destinationDirectory: destinationDirectory,
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(try Data(contentsOf: downloadedURL), expectedData)
    }

    func testDownloadTemporaryRejectsInvalidContentType() async throws {
        let remoteURL = "https://example.test/papers/html.pdf"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/html",
            data: Data("<html>not a PDF</html>".utf8)
        )
        let destinationDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        await assertNotAPDF(
            remoteURL: remoteURL,
            destinationDirectory: destinationDirectory
        )
    }

    func testDownloadTemporaryRejectsLookalikePDFMediaType() async throws {
        let remoteURL = "https://example.test/papers/lookalike.pdf"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/pdf-malformed",
            data: Data("%PDF-1.7\nlookalike".utf8)
        )
        let destinationDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        await assertNotAPDF(
            remoteURL: remoteURL,
            destinationDirectory: destinationDirectory
        )
    }

    func testDownloadTemporaryRejectsGenericBinaryResponseWithoutPDFMagic() async throws {
        let remoteURL = "https://example.test/papers/not-really.pdf"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/octet-stream",
            data: Data("not a PDF".utf8)
        )
        let destinationDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        await assertNotAPDF(
            remoteURL: remoteURL,
            destinationDirectory: destinationDirectory
        )
    }

    func testDownloadTemporaryRejectsGenericBinaryResponseWithoutPDFURLPath() async throws {
        let remoteURL = "https://example.test/papers/download"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/octet-stream",
            data: Data("%PDF-1.7\\ngeneric download".utf8)
        )
        let destinationDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        await assertNotAPDF(
            remoteURL: remoteURL,
            destinationDirectory: destinationDirectory
        )
    }

    func testDownloadTemporaryRejectsInvalidPDFMagic() async throws {
        let remoteURL = "https://example.test/papers/invalid.pdf"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/pdf",
            data: Data("not a PDF".utf8)
        )
        let destinationDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        await assertNotAPDF(
            remoteURL: remoteURL,
            destinationDirectory: destinationDirectory
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFDownloadServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertNotAPDF(remoteURL: String, destinationDirectory: URL) async {
        do {
            _ = try await PDFDownloadService.downloadTemporary(
                from: URL(string: remoteURL)!,
                suggestedFilename: "download.pdf",
                destinationDirectory: destinationDirectory,
                session: ImportSourceURLProtocol.makeSession()
            )
            XCTFail("Expected non-PDF response to be rejected")
        } catch let error as PDFDownloadService.DownloadError {
            guard case .notAPDF = error else {
                XCTFail("Expected notAPDF, got: \(error)")
                return
            }
        } catch {
            XCTFail("Expected DownloadError.notAPDF, got: \(error)")
        }
    }
}
