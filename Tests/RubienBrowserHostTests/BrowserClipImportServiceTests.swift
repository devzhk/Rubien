import Foundation
import GRDB
import XCTest
@testable import RubienBrowserHost
@testable import RubienCore
#if os(macOS)
import RubienPDFKit
#endif

final class BrowserClipImportServiceTests: XCTestCase {
    func testPreviewDoesNotWriteAndSessionConfirmationImportsWebpage() async throws {
        let database = try makeDatabase()
        var session = BrowserImportSession(
            service: BrowserClipImportService(database: database)
        )

        let previewResponse = try await session.handle(request(page: BrowserClipPage(
            url: "https://example.com/private"
        )))
        let preview = try XCTUnwrap(previewResponse.preview)

        XCTAssertTrue(previewResponse.ok)
        XCTAssertEqual(preview.kind, .webpage)
        XCTAssertEqual(preview.title, "example.com")
        XCTAssertEqual(try database.referenceCount(), 0)

        let response = try await session.handle(confirmRequest(preview.confirmationID))
        XCTAssertEqual(response.result, .created)
        XCTAssertEqual(response.kind, .webpage)
        let reference = try XCTUnwrap(try fetch(response.referenceID, from: database))
        XCTAssertEqual(reference.url, "https://example.com/private")
        XCTAssertEqual(reference.referenceType, .webpage)
        XCTAssertNil(reference.webContent)
        XCTAssertEqual(reference.verificationStatus, .verifiedManual)
        XCTAssertEqual(reference.reviewedBy, "browser-clipper")
    }

    func testGenericCitationRichPageStillPreviewsAndImportsAsWebsite() async throws {
        let database = try makeDatabase()
        let service = BrowserClipImportService(database: database)
        let page = BrowserClipPage(
            url: "https://publisher.example/session/article",
            canonicalURL: "https://publisher.example/papers/42",
            title: "Browser shell title",
            author: "Page Author",
            excerpt: "Browser excerpt",
            siteName: "Publisher",
            faviconURL: "https://publisher.example/icon.png",
            contentHTML: "<article><p>Authenticated paper body</p></article>",
            citation: BrowserCitationMetadata(
                title: "A Captured Paper",
                authors: ["Lovelace, Ada", "Alan Turing"],
                publicationDate: "2025-04-03",
                journalTitle: "Journal of Browser Research",
                doi: "https://doi.org/10.1234/EXAMPLE.42"
            )
        )

        let prepared = try await service.prepareClip(request(page: page))
        XCTAssertEqual(prepared.preview.kind, .webpage)
        XCTAssertEqual(prepared.preview.title, "Browser shell title")
        XCTAssertTrue(prepared.preview.hasCapturedContent)
        XCTAssertEqual(try database.referenceCount(), 0)

        let response = try await service.confirm(prepared)
        let reference = try XCTUnwrap(try fetch(response.referenceID, from: database))
        XCTAssertEqual(reference.authors.map(\.displayName), ["Page Author"])
        XCTAssertEqual(reference.referenceType, .webpage)
        XCTAssertNil(reference.doi)
        XCTAssertEqual(reference.url, "https://publisher.example/papers/42")
        XCTAssertEqual(reference.abstract, "Browser excerpt")
        XCTAssertEqual(reference.siteName, "Publisher")
        XCTAssertEqual(reference.favicon, "https://publisher.example/icon.png")
        XCTAssertEqual(
            reference.decodedWebContent?.body,
            "<article><p>Authenticated paper body</p></article>"
        )
    }

    func testKnownPaperPreviewUsesResolvedMetadataAndConfirmationPersistsEvidence() async throws {
        let database = try makeDatabase()
        let fetched = Reference(
            title: "Resolved Paper",
            authors: [AuthorName(given: "Ada", family: "Lovelace")],
            year: 2026,
            journal: "Resolved Journal",
            doi: "10.1234/resolved",
            url: "https://arxiv.org/abs/2501.01234",
            referenceType: .journalArticle
        )
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { input, fallback in
                XCTAssertEqual(input, "https://arxiv.org/abs/2501.01234")
                XCTAssertEqual(fallback?.decodedWebContent?.body, "<article>Captured full text</article>")
                return self.verifiedOutcome(
                    fetched,
                    preferredPDFURL: "https://arxiv.org/pdf/2501.01234"
                )
            },
            pdfDownloader: { reference, overrideURL in
                XCTAssertEqual(reference.title, "Resolved Paper")
                XCTAssertEqual(overrideURL, "https://arxiv.org/pdf/2501.01234")
                return "downloaded-paper.pdf"
            }
        )
        let page = BrowserClipPage(
            url: "https://arxiv.org/abs/2501.01234",
            title: "Page title",
            siteName: "arXiv",
            contentHTML: "<article>Captured full text</article>"
        )

        let prepared = try await service.prepareClip(request(page: page))
        XCTAssertEqual(prepared.preview.kind, .paper)
        XCTAssertEqual(prepared.preview.title, "Resolved Paper")
        XCTAssertEqual(prepared.preview.authors, ["Ada Lovelace"])
        XCTAssertEqual(prepared.preview.year, 2026)
        XCTAssertFalse(prepared.preview.willQueueForReview)
        XCTAssertFalse(prepared.preview.hasCapturedContent)
        XCTAssertTrue(prepared.preview.willDownloadPDF)
        XCTAssertEqual(prepared.preview.pdfDownloadURL, "https://arxiv.org/pdf/2501.01234")
        XCTAssertEqual(try database.referenceCount(), 0)

        let response = try await service.confirm(prepared)
        let reference = try XCTUnwrap(try fetch(response.referenceID, from: database))
        XCTAssertEqual(response.kind, .paper)
        XCTAssertEqual(response.result, .created)
        XCTAssertEqual(response.pdfAttached, true)
        XCTAssertEqual(reference.title, "Resolved Paper")
        XCTAssertNil(reference.webContent)
        XCTAssertEqual(try database.pdfFilename(for: try XCTUnwrap(reference.id)), "downloaded-paper.pdf")
        let evidenceCount = try await database.dbWriter.read { db in
            try MetadataEvidence.fetchCount(db)
        }
        XCTAssertEqual(evidenceCount, 1)
    }

    func testHuggingFacePaperURLPreviewsAsPaperInsteadOfWebpage() async throws {
        let database = try makeDatabase()
        let pageURL = "https://huggingface.co/papers/2607.09657"
        let fetched = Reference(
            title: "Scalable Visual Pretraining for Language Intelligence",
            authors: [AuthorName(given: "Yiming", family: "Zhang")],
            year: 2026,
            url: "https://arxiv.org/abs/2607.09657",
            referenceType: .journalArticle
        )
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { input, _ in
                XCTAssertEqual(input, pageURL)
                return self.verifiedOutcome(fetched)
            }
        )

        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: pageURL,
            title: fetched.title,
            siteName: "Hugging Face"
        )))

        XCTAssertEqual(prepared.preview.kind, .paper)
        XCTAssertEqual(prepared.preview.title, fetched.title)
        XCTAssertEqual(prepared.preview.sourceURL, "https://arxiv.org/abs/2607.09657")
        XCTAssertTrue(prepared.preview.willDownloadPDF)
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testSciencePaperConfirmationAttachesChromeDownloadedPDFInsteadOfCapturedPage() async throws {
        let database = try makeDatabase()
        let articleURL = "https://www.science.org/doi/10.1126/scirobotics.adz7397"
        let pdfURL = "https://www.science.org/doi/pdf/10.1126/scirobotics.adz7397?download=true"
        let importedDownloadedPath = LockedValue<String?>(nil)
        let fetched = Reference(
            title: "Agile perceptive multiskill locomotion for quadrupedal robots in the wild",
            authors: [AuthorName(given: "Jun-Gil", family: "Kang")],
            year: 2026,
            journal: "Science Robotics",
            doi: "10.1126/scirobotics.adz7397",
            url: articleURL,
            referenceType: .journalArticle
        )
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { input, fallback in
                XCTAssertEqual(input, articleURL)
                XCTAssertNotNil(fallback?.webContent)
                return self.verifiedOutcome(fetched, preferredPDFURL: pdfURL)
            },
            pdfDownloader: { _, _ in
                XCTFail("The authenticated Chrome download should be preferred")
                return "unexpected.pdf"
            },
            downloadedPDFImporter: { sourceURL in
                XCTAssertEqual(
                    try Data(contentsOf: sourceURL),
                    Data("%PDF-1.7\n".utf8)
                )
                importedDownloadedPath.value = sourceURL.path
                return "authenticated-science-paper.pdf"
            },
            pdfDeleter: { _ in
                XCTFail("The attached Chrome download should not be deleted")
            }
        )

        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: articleURL,
            title: fetched.title,
            contentHTML: "<article>Publisher HTML is not the paper attachment.</article>"
        )))

        XCTAssertEqual(prepared.preview.kind, .paper)
        XCTAssertFalse(prepared.preview.hasCapturedContent)
        XCTAssertTrue(prepared.preview.willDownloadPDF)
        XCTAssertEqual(prepared.preview.pdfDownloadURL, pdfURL)

        let downloadedURL = try makeBrowserDownload(
            filename: "rubien-\(prepared.confirmationID.lowercased()).pdf",
            contents: Data("%PDF-1.7\n".utf8)
        )
        let downloadedPath = downloadedURL.path

        let response = try await service.confirm(
            prepared,
            downloadedPDFPath: downloadedPath
        )
        let reference = try XCTUnwrap(try fetch(response.referenceID, from: database))
        XCTAssertEqual(response.pdfAttached, true)
        XCTAssertEqual(
            importedDownloadedPath.value.map(canonicalTemporaryPath),
            canonicalTemporaryPath(downloadedPath)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedPath))
        XCTAssertNil(reference.webContent)
        XCTAssertEqual(
            try database.pdfFilename(for: try XCTUnwrap(reference.id)),
            "authenticated-science-paper.pdf"
        )
    }

    func testConfirmedChromeDownloadIsDeletedWhenExistingReferenceAlreadyHasPDF() async throws {
        let database = try makeDatabase()
        let articleURL = "https://www.science.org/doi/10.1126/scirobotics.adz7397"
        var existing = Reference(
            title: "Existing paper",
            doi: "10.1126/scirobotics.adz7397",
            url: articleURL,
            referenceType: .journalArticle
        )
        _ = try database.saveReference(&existing)
        let referenceID = try XCTUnwrap(existing.id)
        let storedFilename = "\(UUID().uuidString)-existing.pdf"
        try FileManager.default.createDirectory(
            at: AppDatabase.pdfStorageURL,
            withIntermediateDirectories: true
        )
        try Data("%PDF-1.7\n".utf8).write(
            to: AppDatabase.pdfStorageURL.appendingPathComponent(storedFilename)
        )
        _ = try database.attachImportedPDF(
            referenceId: referenceID,
            filename: storedFilename
        )
        defer { deleteStoredPDF(at: storedFilename) }

        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { _, _ in
                self.verifiedOutcome(
                    existing,
                    preferredPDFURL: "https://www.science.org/doi/pdf/10.1126/scirobotics.adz7397?download=true"
                )
            },
            downloadedPDFImporter: { _ in
                XCTFail("An already-attached reference should not import another PDF")
                return "unexpected.pdf"
            }
        )
        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: articleURL
        )))
        let downloadedURL = try makeBrowserDownload(
            filename: "rubien-\(prepared.confirmationID.lowercased()).pdf",
            contents: Data("%PDF-1.7\n".utf8)
        )

        let response = try await service.confirm(
            prepared,
            downloadedPDFPath: downloadedURL.path
        )

        XCTAssertEqual(response.result, .existing)
        XCTAssertEqual(response.pdfAttached, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
    }

    func testVerifiedPaperCanBeConfirmedWithoutDownloadingPDF() async throws {
        let database = try makeDatabase()
        let articleURL = "https://www.science.org/doi/10.1126/sciimmunol.adv1149"
        let fetched = Reference(
            title: "Mucosal tissue cues shape B cell memory through the IgA BCR",
            authors: [AuthorName(given: "Maria Pia", family: "Holgado")],
            doi: "10.1126/sciimmunol.adv1149",
            url: articleURL,
            referenceType: .journalArticle
        )
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { _, _ in
                self.verifiedOutcome(
                    fetched,
                    preferredPDFURL: "https://www.science.org/doi/pdf/10.1126/sciimmunol.adv1149?download=true"
                )
            },
            pdfDownloader: { _, _ in
                XCTFail("The PDF downloader must not run when the option is off")
                return "unexpected.pdf"
            },
            downloadedPDFImporter: { _ in
                XCTFail("A Chrome download must not be imported when the option is off")
                return "unexpected.pdf"
            }
        )
        var session = BrowserImportSession(service: service)

        let previewResponse = try await session.handle(request(page: BrowserClipPage(
            url: articleURL,
            contentHTML: "<article>Captured publisher page</article>"
        )))
        let preview = try XCTUnwrap(previewResponse.preview)
        XCTAssertTrue(preview.willDownloadPDF)

        let response = try await session.handle(confirmRequest(
            preview.confirmationID,
            downloadPDF: false
        ))
        let reference = try XCTUnwrap(try fetch(response.referenceID, from: database))
        XCTAssertEqual(response.pdfAttached, false)
        XCTAssertEqual(response.message, "Imported without downloading a PDF.")
        XCTAssertNil(try database.pdfFilename(for: try XCTUnwrap(reference.id)))
        XCTAssertNil(reference.webContent)
    }

    func testConfirmationRejectsDownloadedPDFPathNotBoundToPreview() async throws {
        let database = try makeDatabase()
        let articleURL = "https://www.science.org/doi/10.1126/sciimmunol.adv1149"
        let fetched = Reference(
            title: "Mucosal tissue cues shape B cell memory through the IgA BCR",
            authors: [AuthorName(given: "Maria Pia", family: "Holgado")],
            doi: "10.1126/sciimmunol.adv1149",
            url: articleURL,
            referenceType: .journalArticle
        )
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { _, _ in
                self.verifiedOutcome(
                    fetched,
                    preferredPDFURL: "https://www.science.org/doi/pdf/10.1126/sciimmunol.adv1149?download=true"
                )
            }
        )
        let prepared = try await service.prepareClip(request(page: BrowserClipPage(url: articleURL)))

        do {
            _ = try await service.confirm(
                prepared,
                downloadedPDFPath: "/Users/test/Documents/private.pdf"
            )
            XCTFail("Expected the unbound local path to be rejected")
        } catch {
            XCTAssertEqual(error as? BrowserClipHostError, .invalidBrowserDownload)
        }
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testKnownPaperPDFUsesTokenBoundChromeDownload() async throws {
        let database = try makeDatabase()
        let token = UUID()
        let browserURL = try makeBrowserDownload(
            filename: "rubien-preview-\(token.uuidString.lowercased()).pdf",
            contents: Data("%PDF-1.7\n".utf8)
        )
        let paperURL = "https://aclanthology.org/2024.acl-long.1.pdf"
        let fetched = Reference(
            title: "Known paper PDF",
            doi: "10.1000/known-paper",
            url: paperURL,
            referenceType: .conferencePaper
        )
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { _, _ in self.verifiedOutcome(fetched) },
            pdfDownloader: { _, _ in
                XCTFail("The staged authenticated PDF should be preferred")
                return "unexpected.pdf"
            }
        )

        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: paperURL,
            browserDownloadedFilePath: browserURL.path,
            browserDownloadToken: token.uuidString.lowercased()
        )))

        XCTAssertEqual(prepared.preview.kind, .paper)
        XCTAssertFalse(prepared.preview.willDownloadPDF)
        XCTAssertFalse(FileManager.default.fileExists(atPath: browserURL.path))
        guard case .metadata(_, _, _, let stagedSource?) = prepared.payload else {
            return XCTFail("Expected a private staged PDF source")
        }
        XCTAssertEqual(try Data(contentsOf: stagedSource.fileURL), Data("%PDF-1.7\n".utf8))
        let response = try await service.confirm(prepared)
        XCTAssertEqual(response.pdfAttached, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedSource.fileURL.path))
        if let referenceID = response.referenceID,
           let filename = try database.pdfFilename(for: referenceID) {
            deleteStoredPDF(at: filename)
        }
    }

    func testKnownPaperPDFIsPreservedWhenMetadataNeedsReview() async throws {
        let database = try makeDatabase()
        let token = UUID()
        let browserURL = try makeBrowserDownload(
            filename: "rubien-preview-\(token.uuidString.lowercased()).pdf",
            contents: Data("%PDF-1.7\n".utf8)
        )
        let paperURL = "https://aclanthology.org/2024.acl-long.2.pdf"
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { _, fallback in
                MetadataResolutionPipeline.IdentifierResolutionOutcome(
                    result: .candidate(CandidateEnvelope(
                        seed: nil,
                        fallbackReference: fallback,
                        currentReference: Reference(
                            title: "Needs metadata review",
                            url: paperURL,
                            referenceType: .conferencePaper
                        ),
                        candidates: [],
                        message: "Needs review"
                    ))
                )
            }
        )

        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: paperURL,
            browserDownloadedFilePath: browserURL.path,
            browserDownloadToken: token.uuidString.lowercased()
        )))
        let response = try await service.confirm(prepared)

        XCTAssertEqual(response.result, .queued)
        let intake = try XCTUnwrap(try database.fetchPendingMetadataIntakes().first)
        let pdfPath = try XCTUnwrap(intake.pdfPath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppDatabase.pdfStorageURL.appendingPathComponent(pdfPath).path
        ))
        deleteStoredPDF(at: pdfPath)
    }

    func testDirectChromePDFRejectsHTMLBodyAndDeletesBrowserFile() async throws {
        let database = try makeDatabase()
        let token = UUID()
        let browserURL = try makeBrowserDownload(
            filename: "rubien-preview-\(token.uuidString.lowercased()).pdf",
            contents: Data("<html>Sign in</html>".utf8)
        )
        let service = BrowserClipImportService(database: database)

        do {
            _ = try await service.prepareClip(request(page: BrowserClipPage(
                url: "https://files.example/private.pdf",
                browserDownloadedFilePath: browserURL.path,
                browserDownloadToken: token.uuidString.lowercased()
            )))
            XCTFail("Expected the non-PDF download to be rejected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Server returned a non-PDF response")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: browserURL.path))
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testQueuedPaperPreviewWarnsAndConfirmationPreservesAuthenticatedCapture() async throws {
        let database = try makeDatabase()
        let service = BrowserClipImportService(
            database: database,
            metadataResolver: { _, fallback in
                MetadataResolutionPipeline.IdentifierResolutionOutcome(
                    result: .candidate(CandidateEnvelope(
                        seed: nil,
                        fallbackReference: fallback,
                        currentReference: Reference(
                            title: "Resolver candidate",
                            url: "https://openreview.net/forum?id=private-paper",
                            referenceType: .conferencePaper
                        ),
                        candidates: [],
                        message: "Needs review"
                    ))
                )
            }
        )
        let page = BrowserClipPage(
            url: "https://openreview.net/forum?id=private-paper",
            title: "Captured title",
            siteName: "OpenReview",
            faviconURL: "https://openreview.net/favicon.ico",
            contentHTML: "<article>Authenticated full text</article>"
        )

        let prepared = try await service.prepareClip(request(page: page))
        XCTAssertEqual(prepared.preview.title, "Resolver candidate")
        XCTAssertTrue(prepared.preview.willQueueForReview)
        XCTAssertTrue(prepared.preview.hasCapturedContent)
        XCTAssertEqual(try database.fetchPendingMetadataIntakes().count, 0)

        let response = try await service.confirm(prepared)
        let intake = try XCTUnwrap(try database.fetchPendingMetadataIntakes().first)
        let queuedReference = try XCTUnwrap(intake.bestAvailableReference)
        XCTAssertEqual(response.result, .queued)
        XCTAssertEqual(response.intakeID, intake.id)
        XCTAssertEqual(queuedReference.title, "Resolver candidate")
        XCTAssertEqual(queuedReference.siteName, "OpenReview")
        XCTAssertEqual(queuedReference.favicon, "https://openreview.net/favicon.ico")
        XCTAssertEqual(
            queuedReference.decodedWebContent?.body,
            "<article>Authenticated full text</article>"
        )
    }

    func testDirectMarkdownIsPreparedThenCommittedAndTemporarySourceIsCleaned() async throws {
        let database = try makeDatabase()
        let temporary = try makeMaterializedSource(kind: .markdown, filename: "notes.md")
        try Data("# Prepared notes".utf8).write(to: temporary.source.fileURL)
        let service = BrowserClipImportService(
            database: database,
            filePreparer: { input, browserDownloadedFilePath in
                XCTAssertEqual(input, "https://files.example/notes.md")
                XCTAssertNil(browserDownloadedFilePath)
                return .markdown(
                    source: temporary.source,
                    reference: Reference(title: "Prepared notes", referenceType: .webpage)
                )
            }
        )

        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: "https://files.example/notes.md"
        )))
        XCTAssertEqual(prepared.preview.kind, .markdown)
        XCTAssertEqual(prepared.preview.title, "Prepared notes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.directory.path))
        XCTAssertEqual(try database.referenceCount(), 0)

        let response = try await service.confirm(prepared)
        XCTAssertEqual(response.kind, .markdown)
        XCTAssertEqual(response.result, .created)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.directory.path))
    }

    func testDirectMarkdownCanUseTokenBoundChromeDownload() async throws {
        let database = try makeDatabase()
        let temporary = try makeMaterializedSource(kind: .markdown, filename: "notes.md")
        let token = UUID()
        let downloadedPath = "/Users/test/Downloads/Rubien/rubien-preview-\(token.uuidString.lowercased()).md"
        let service = BrowserClipImportService(
            database: database,
            filePreparer: { input, browserDownloadedFilePath in
                XCTAssertEqual(input, "https://files.example/private-notes.md")
                XCTAssertEqual(browserDownloadedFilePath, downloadedPath)
                return .markdown(
                    source: temporary.source,
                    reference: Reference(title: "Private notes", referenceType: .webpage)
                )
            }
        )

        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: "https://files.example/private-notes.md",
            browserDownloadedFilePath: downloadedPath,
            browserDownloadToken: token.uuidString.lowercased()
        )))

        XCTAssertEqual(prepared.preview.kind, .markdown)
        prepared.discard()
    }

#if os(macOS)
    func testDirectPDFPreviewQueuesOnlyAfterConfirmation() async throws {
        let database = try makeDatabase()
        let temporary = try makeMaterializedSource(kind: .pdf, filename: "paper.pdf")
        try Data("test-pdf-placeholder".utf8).write(to: temporary.source.fileURL)
        let preparedPDF = PreparedPDFImport(
            sourceURL: temporary.source.fileURL,
            resolution: .seedOnly(IntakeEnvelope(
                seed: MetadataResolutionSeed(fileName: "paper.pdf", title: "Needs PDF review"),
                fallbackReference: Reference(title: "Needs PDF review"),
                message: "No authoritative match"
            ))
        )
        let service = BrowserClipImportService(
            database: database,
            filePreparer: { _, _ in .pdf(source: temporary.source, prepared: preparedPDF) }
        )

        let prepared = try await service.prepareClip(request(page: BrowserClipPage(
            url: "https://files.example/paper.pdf"
        )))
        XCTAssertEqual(prepared.preview.kind, .pdf)
        XCTAssertEqual(prepared.preview.title, "Needs PDF review")
        XCTAssertTrue(prepared.preview.willQueueForReview)
        XCTAssertEqual(try database.fetchPendingMetadataIntakes().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.source.fileURL.path))
        // The outer Codex sandbox can make Rubien's Application Support root
        // fall back to a not-yet-created temp directory. Production hosts can
        // create their normal storage root; make that fallback explicit here.
        try FileManager.default.createDirectory(
            at: AppDatabase.pdfStorageURL,
            withIntermediateDirectories: true
        )

        let response = try await service.confirm(prepared)
        XCTAssertEqual(response.result, .queued)
        XCTAssertEqual(response.kind, .pdf)
        let intake = try XCTUnwrap(try database.fetchPendingMetadataIntakes().first)
        XCTAssertNotNil(intake.pdfPath)
        if let pdfPath = intake.pdfPath {
            PDFService.deletePDF(at: pdfPath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.directory.path))
    }
#endif

    func testClosingSessionCancelsPreparedImportAndCleansTemporarySource() async throws {
        let database = try makeDatabase()
        let temporary = try makeMaterializedSource(kind: .markdown, filename: "cancel.md")
        var session = BrowserImportSession(service: BrowserClipImportService(
            database: database,
            filePreparer: { _, _ in
                .markdown(
                    source: temporary.source,
                    reference: Reference(title: "Cancel me", referenceType: .webpage)
                )
            }
        ))

        let response = try await session.handle(request(page: BrowserClipPage(
            url: "https://files.example/cancel.md"
        )))
        XCTAssertNotNil(response.preview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.directory.path))

        session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.directory.path))
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testSessionRejectsMissingWrongAndReusedConfirmation() async throws {
        let database = try makeDatabase()
        var session = BrowserImportSession(service: BrowserClipImportService(database: database))
        let previewResponse = try await session.handle(request(page: BrowserClipPage(
            url: "https://example.com/article"
        )))
        let preview = try XCTUnwrap(previewResponse.preview)

        await assertSessionThrows(
            .missingConfirmation,
            session: &session,
            request: BrowserClipRequest(
                version: BrowserClipContract.protocolVersion,
                command: "confirm"
            )
        )
        await assertSessionThrows(
            .staleConfirmation,
            session: &session,
            request: confirmRequest("wrong-id")
        )

        _ = try await session.handle(confirmRequest(preview.confirmationID))
        XCTAssertEqual(try database.referenceCount(), 1)
        await assertSessionThrows(
            .staleConfirmation,
            session: &session,
            request: confirmRequest(preview.confirmationID)
        )
        XCTAssertEqual(try database.referenceCount(), 1)
    }

    func testSessionOpensImportedReferenceAndPendingIntakeDeepLinks() async throws {
        var openedURLs: [URL] = []
        var session = BrowserImportSession(
            service: BrowserClipImportService(database: try makeDatabase()),
            openURL: { url in
                openedURLs.append(url)
                return true
            }
        )

        let referenceResponse = try await session.handle(BrowserClipRequest(
            version: BrowserClipContract.protocolVersion,
            command: "open",
            referenceID: 42
        ))
        let intakeResponse = try await session.handle(BrowserClipRequest(
            version: BrowserClipContract.protocolVersion,
            command: "open",
            intakeID: 73
        ))

        XCTAssertEqual(
            openedURLs.map(\.absoluteString),
            ["rubien://reference/42", "rubien://pending-intake/73"]
        )
        XCTAssertEqual(referenceResponse.opened, true)
        XCTAssertEqual(referenceResponse.referenceID, 42)
        XCTAssertEqual(intakeResponse.opened, true)
        XCTAssertEqual(intakeResponse.intakeID, 73)
    }

    func testSessionRejectsInvalidOrUnopenableImportDestination() async throws {
        var session = BrowserImportSession(
            service: BrowserClipImportService(database: try makeDatabase()),
            openURL: { _ in false }
        )

        await assertSessionThrows(
            .invalidOpenDestination,
            session: &session,
            request: BrowserClipRequest(
                version: BrowserClipContract.protocolVersion,
                command: "open",
                referenceID: 42,
                intakeID: 73
            )
        )
        await assertSessionThrows(
            .couldNotOpenRubien,
            session: &session,
            request: BrowserClipRequest(
                version: BrowserClipContract.protocolVersion,
                command: "open",
                referenceID: 42
            )
        )
    }

    func testSessionResolvesOnlyItsEnclosingApplicationBundle() {
        XCTAssertEqual(
            BrowserImportSession.enclosingApplicationURL(for: URL(
                fileURLWithPath: "/Applications/Rubien.app/Contents/Helpers/rubien-browser-host"
            ))?.path,
            "/Applications/Rubien.app"
        )
        XCTAssertNil(BrowserImportSession.enclosingApplicationURL(for: URL(
            fileURLWithPath: "/usr/local/bin/rubien-browser-host"
        )))
        XCTAssertNil(BrowserImportSession.enclosingApplicationURL(for: URL(
            fileURLWithPath: "/Applications/Rubien.app/Contents/MacOS/rubien-browser-host"
        )))
    }

    func testSecondConfirmedXArticleUsesWebsiteMergePath() async throws {
        let database = try makeDatabase()
        let service = BrowserClipImportService(database: database)
        let first = BrowserClipPage(
            url: "https://x.com/Majumdar_Ani/article/2078508177620926531",
            title: "X article",
            contentHTML: "<p>Short</p>"
        )
        let second = BrowserClipPage(
            url: "https://x.com/Majumdar_Ani/article/2078508177620926531",
            title: "X article",
            contentHTML: "<article><p>A much longer captured article body.</p></article>"
        )

        let created = try await service.confirm(try await service.prepareClip(request(page: first)))
        let existing = try await service.confirm(try await service.prepareClip(request(page: second)))

        XCTAssertEqual(created.result, .created)
        XCTAssertEqual(existing.result, .existing)
        XCTAssertEqual(existing.referenceID, created.referenceID)
        let reference = try XCTUnwrap(try fetch(existing.referenceID, from: database))
        XCTAssertEqual(
            reference.decodedWebContent?.body,
            "<article><p>A much longer captured article body.</p></article>"
        )
    }

    func testCanonicalValidationDoesNotChangeNativeRoute() async throws {
        let database = try makeDatabase()
        let service = BrowserClipImportService(
            database: database,
            filePreparer: { _, _ in
                XCTFail("DOM-controlled canonical URL must not enter the file importer")
                throw BrowserClipHostError.invalidPageURL
            }
        )

        let invalidCanonical = try await service.prepareClip(request(page: BrowserClipPage(
            url: "https://example.com/article",
            canonicalURL: "javascript:alert(1)",
            title: "Safe page"
        )))
        XCTAssertEqual(invalidCanonical.preview.sourceURL, "https://example.com/article")
        invalidCanonical.discard()

        let crossOrigin = try await service.prepareClip(request(page: BrowserClipPage(
            url: "https://example.com/article",
            canonicalURL: "http://127.0.0.1/private.pdf",
            title: "Safe article"
        )))
        XCTAssertEqual(crossOrigin.preview.kind, .webpage)
        XCTAssertEqual(crossOrigin.preview.sourceURL, "https://example.com/article")
        crossOrigin.discard()
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testRejectsInvalidPreviewRequests() async throws {
        let service = BrowserClipImportService(database: try makeDatabase())

        await assertPrepareThrows(
            .unsupportedVersion(99),
            service: service,
            request: BrowserClipRequest(
                version: 99,
                command: "preview",
                page: BrowserClipPage(url: "https://example.com")
            )
        )
        await assertPrepareThrows(
            .unsupportedCommand,
            service: service,
            request: BrowserClipRequest(
                version: BrowserClipContract.protocolVersion,
                command: "clip",
                page: BrowserClipPage(url: "https://example.com")
            )
        )
        await assertPrepareThrows(
            .missingPage,
            service: service,
            request: BrowserClipRequest(
                version: BrowserClipContract.protocolVersion,
                command: "preview"
            )
        )
        await assertPrepareThrows(
            .invalidPageURL,
            service: service,
            request: request(page: BrowserClipPage(url: "file:///tmp/private.html"))
        )
        await assertPrepareThrows(
            .fieldTooLarge("title"),
            service: service,
            request: request(page: BrowserClipPage(
                url: "https://example.com",
                title: String(repeating: "x", count: 4_097)
            ))
        )
    }

    private func assertPrepareThrows(
        _ expected: BrowserClipHostError,
        service: BrowserClipImportService,
        request: BrowserClipRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.prepareClip(request)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BrowserClipHostError, expected, file: file, line: line)
        }
    }

    private func assertSessionThrows(
        _ expected: BrowserClipHostError,
        session: inout BrowserImportSession,
        request: BrowserClipRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await session.handle(request)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BrowserClipHostError, expected, file: file, line: line)
        }
    }

    private func request(page: BrowserClipPage) -> BrowserClipRequest {
        BrowserClipRequest(
            version: BrowserClipContract.protocolVersion,
            command: "preview",
            page: page
        )
    }

    private func confirmRequest(
        _ confirmationID: String,
        downloadedPDFPath: String? = nil,
        downloadPDF: Bool? = nil
    ) -> BrowserClipRequest {
        BrowserClipRequest(
            version: BrowserClipContract.protocolVersion,
            command: "confirm",
            confirmationID: confirmationID,
            downloadedPDFPath: downloadedPDFPath,
            downloadPDF: downloadPDF
        )
    }

    private func verifiedOutcome(
        _ reference: Reference,
        preferredPDFURL: String? = nil
    ) -> MetadataResolutionPipeline.IdentifierResolutionOutcome {
        let evidence = EvidenceBundle(
            source: reference.metadataSource ?? .translationServer,
            recordKey: reference.doi,
            sourceURL: reference.url,
            fetchMode: .identifier,
            fieldEvidence: [
                FieldEvidence(field: "title", value: reference.title, origin: .identifierAPI)
            ],
            verificationHints: VerificationHints(
                hasStructuredTitle: true,
                hasStructuredAuthors: !reference.authors.isEmpty,
                hasStableRecordKey: reference.doi != nil,
                usedIdentifierFetch: true,
                exactIdentifierMatch: true
            )
        )
        var verified = reference
        verified.verificationStatus = .verifiedAuto
        return MetadataResolutionPipeline.IdentifierResolutionOutcome(
            result: .verified(VerifiedEnvelope(reference: verified, evidence: evidence)),
            preferredPDFURL: preferredPDFURL
        )
    }

    private func makeMaterializedSource(
        kind: ImportSourceKind,
        filename: String
    ) throws -> (source: MaterializedImportSource, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienBrowserHostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
        return (
            MaterializedImportSource(
                input: "https://files.example/\(filename)",
                fileURL: fileURL,
                kind: kind,
                temporaryDirectoryURL: directory
            ),
            directory
        )
    }

    private func deleteStoredPDF(at relativePath: String) {
        try? FileManager.default.removeItem(
            at: AppDatabase.pdfStorageURL.appendingPathComponent(relativePath)
        )
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private func makeBrowserDownload(filename: String, contents: Data) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("RubienBrowserDownloadTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Rubien", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        try contents.write(to: fileURL)
        return fileURL
    }

    private func canonicalTemporaryPath(_ path: String) -> String {
        path.hasPrefix("/private/tmp/")
            ? String(path.dropFirst("/private".count))
            : path
    }

    private func fetch(_ id: Int64?, from database: AppDatabase) throws -> Reference? {
        guard let id else { return nil }
        return try database.fetchReferences(ids: [id]).first
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
