import Foundation
import RubienCore
#if os(macOS)
import RubienPDFKit
#endif

enum BrowserClipHostError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case unsupportedCommand
    case missingPage
    case missingConfirmation
    case staleConfirmation
    case invalidPageURL
    case fieldTooLarge(String)
    case tooManyAuthors
    case missingReferenceID
    case missingImportResult
    case pdfImportUnavailable
    case unauthorizedOrigin(String?)
    case malformedMessage(String)
    case messageTooLarge(Int)
    case incompleteMessage
    case invalidBrowserDownload
    case invalidOpenDestination
    case couldNotOpenRubien

    var code: String {
        switch self {
        case .unsupportedVersion: return "unsupported-version"
        case .unsupportedCommand: return "unsupported-command"
        case .missingPage: return "missing-page"
        case .missingConfirmation: return "missing-confirmation"
        case .staleConfirmation: return "stale-confirmation"
        case .invalidPageURL: return "invalid-page-url"
        case .fieldTooLarge: return "field-too-large"
        case .tooManyAuthors: return "too-many-authors"
        case .missingReferenceID, .missingImportResult: return "save-failed"
        case .pdfImportUnavailable: return "pdf-import-unavailable"
        case .unauthorizedOrigin: return "unauthorized-origin"
        case .malformedMessage: return "malformed-message"
        case .messageTooLarge: return "message-too-large"
        case .incompleteMessage: return "incomplete-message"
        case .invalidBrowserDownload: return "invalid-browser-download"
        case .invalidOpenDestination: return "invalid-open-destination"
        case .couldNotOpenRubien: return "could-not-open-rubien"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This clip uses unsupported protocol version \(version). Update Rubien and the extension."
        case .unsupportedCommand:
            return "Chrome requested an unsupported browser helper command."
        case .missingPage:
            return "Chrome did not provide a page to preview."
        case .missingConfirmation:
            return "Confirm this import from the Rubien extension preview first."
        case .staleConfirmation:
            return "This import preview has expired. Prepare it again before confirming."
        case .invalidPageURL:
            return "The page does not have a valid HTTP or HTTPS URL."
        case .fieldTooLarge(let field):
            return "The extracted \(field) exceeds Rubien's clip limit."
        case .tooManyAuthors:
            return "The page exposes more than 100 citation authors."
        case .missingReferenceID:
            return "Rubien saved the import without returning a reference identifier."
        case .missingImportResult:
            return "Rubien's import pipeline returned no result."
        case .pdfImportUnavailable:
            return "Direct PDF import is unavailable in this Rubien build."
        case .unauthorizedOrigin(let origin):
            return "The native helper rejected caller origin \(origin ?? "<missing>")."
        case .malformedMessage(let message):
            return "Chrome sent an invalid clip payload: \(message)"
        case .messageTooLarge(let bytes):
            return "The native message is too large (\(bytes) bytes)."
        case .incompleteMessage:
            return "Chrome closed the native messaging pipe before sending a complete request."
        case .invalidBrowserDownload:
            return "Chrome provided a downloaded file that does not belong to this import preview."
        case .invalidOpenDestination:
            return "Chrome did not provide one valid imported item to open."
        case .couldNotOpenRubien:
            return "macOS could not open the imported item in Rubien."
        }
    }
}

/// A transport-neutral result produced only after a prepared browser import is
/// confirmed and committed.
struct BrowserSourceImportOutcome: Sendable {
    var result: BrowserClipSaveResult
    var referenceID: Int64?
    var intakeID: Int64?
    var title: String
    var kind: BrowserClipImportKind
    var pdfAttached: Bool
    var message: String?

    init(
        result: BrowserClipSaveResult,
        referenceID: Int64? = nil,
        intakeID: Int64? = nil,
        title: String,
        kind: BrowserClipImportKind,
        pdfAttached: Bool = false,
        message: String? = nil
    ) {
        self.result = result
        self.referenceID = referenceID
        self.intakeID = intakeID
        self.title = title
        self.kind = kind
        self.pdfAttached = pdfAttached
        self.message = message
    }
}

/// A prepared browser import owned by one native-messaging connection. Remote
/// file sources live in a temporary directory until confirmation or disconnect.
struct PreparedBrowserImport: Sendable {
    enum Payload: Sendable {
        case metadata(
            input: String,
            result: MetadataResolutionResult,
            preferredPDFURL: String?,
            browserPDFSource: MaterializedImportSource?
        )
        case website(Reference)
        case markdown(source: MaterializedImportSource, reference: Reference)
#if os(macOS)
        case pdf(source: MaterializedImportSource, prepared: PreparedPDFImport)
#endif
    }

    let confirmationID: String
    let preview: BrowserClipConfirmationPreview
    let payload: Payload

    func discard() {
        switch payload {
        case .website:
            break
        case .metadata(_, _, _, let browserPDFSource):
            browserPDFSource?.cleanup()
        case .markdown(let source, _):
            source.cleanup()
#if os(macOS)
        case .pdf(let source, _):
            source.cleanup()
#endif
        }
    }
}

struct BrowserClipImportService {
    typealias MetadataResolveOperation = (
        String,
        Reference?
    ) async -> MetadataResolutionPipeline.IdentifierResolutionOutcome
    typealias FilePreparer = (
        String,
        String?
    ) async throws -> PreparedBrowserImport.Payload
    typealias PDFDownloader = @Sendable (Reference, String?) async throws -> String
    typealias DownloadedPDFImporter = @Sendable (URL) throws -> String
    typealias PDFDeleter = @Sendable (String) -> Void
    let database: AppDatabase
    private let metadataResolver: MetadataResolveOperation
    private let filePreparer: FilePreparer
    private let pdfDownloader: PDFDownloader
    private let downloadedPDFImporter: DownloadedPDFImporter
    private let pdfDeleter: PDFDeleter

    init(
        database: AppDatabase = .shared,
        metadataResolver: MetadataResolveOperation? = nil,
        filePreparer: FilePreparer? = nil,
        pdfDownloader: PDFDownloader? = nil,
        downloadedPDFImporter: DownloadedPDFImporter? = nil,
        pdfDeleter: PDFDeleter? = nil
    ) {
        self.database = database
        self.metadataResolver = metadataResolver ?? { input, fallback in
            await MetadataResolutionPipeline.resolveIdentifierInput(
                input,
                fallback: fallback
            )
        }
        self.filePreparer = filePreparer ?? Self.prepareFile
        self.pdfDownloader = pdfDownloader ?? { reference, overrideURL in
            try await PDFDownloadService.downloadPDF(
                for: reference,
                overrideURL: overrideURL
            )
        }
        self.downloadedPDFImporter = downloadedPDFImporter ?? { sourceURL in
            try Self.importDownloadedPDF(from: sourceURL)
        }
        self.pdfDeleter = pdfDeleter ?? { filename in
            try? FileManager.default.removeItem(
                at: AppDatabase.pdfStorageURL.appendingPathComponent(filename)
            )
        }
    }

    func prepareClip(_ request: BrowserClipRequest) async throws -> PreparedBrowserImport {
        guard request.version == BrowserClipContract.protocolVersion else {
            throw BrowserClipHostError.unsupportedVersion(request.version)
        }
        guard request.command == "preview" else {
            // Do not reflect an attacker-controlled command into the response:
            // Chrome caps native-host responses at 1 MB even though requests
            // may use our larger bounded envelope.
            throw BrowserClipHostError.unsupportedCommand
        }
        guard let requestedPage = request.page else {
            throw BrowserClipHostError.missingPage
        }

        let page = try sanitized(requestedPage)
        guard let pageURL = httpURL(page.url) else {
            throw BrowserClipHostError.invalidPageURL
        }
        let canonicalURL = page.canonicalURL
            .flatMap(httpURL)
            .flatMap { sameOrigin($0, pageURL) ? $0 : nil }

        let payload: PreparedBrowserImport.Payload
        // Routing is based only on the tab URL the user explicitly selected.
        // Captured DOM metadata must never turn an ordinary page into a hidden
        // native-network request.
        switch AddReferenceInputRouter.classify(pageURL.absoluteString) {
        case .metadata(let input):
            let browserPDFSource: MaterializedImportSource?
            if let path = try validatedBrowserDownloadedFilePath(
                in: page,
                sourceURL: pageURL
            ) {
                browserPDFSource = try Self.materializeBrowserDownload(
                    input: pageURL.absoluteString,
                    path: path,
                    expectedKind: .pdf
                )
            } else {
                browserPDFSource = nil
            }
            payload = await prepareMetadata(
                input,
                page: page,
                pageURL: pageURL,
                canonicalURL: canonicalURL,
                browserPDFSource: browserPDFSource
            )
        case .file(let input):
            payload = try await filePreparer(
                input,
                try validatedBrowserDownloadedFilePath(in: page, sourceURL: pageURL)
            )
        case .website:
            try rejectUnexpectedBrowserDownload(in: page)
            payload = prepareWebsite(page, pageURL: pageURL, canonicalURL: canonicalURL)
        case .invalid:
            throw BrowserClipHostError.invalidPageURL
        }

        let confirmationID = UUID().uuidString
        return PreparedBrowserImport(
            confirmationID: confirmationID,
            preview: makePreview(
                confirmationID: confirmationID,
                payload: payload,
                pageURL: pageURL
            ),
            payload: payload
        )
    }

    func confirm(
        _ prepared: PreparedBrowserImport,
        downloadedPDFPath: String? = nil,
        downloadPDF: Bool = true
    ) async throws -> BrowserClipResponse {
        defer { prepared.discard() }

        let validatedDownloadedPDFPath: String?
        if let downloadedPDFPath {
            guard downloadPDF, prepared.preview.willDownloadPDF else {
                throw BrowserClipHostError.invalidBrowserDownload
            }
            validatedDownloadedPDFPath = try validatedConfirmedPDFPath(
                downloadedPDFPath,
                confirmationID: prepared.confirmationID
            )
        } else {
            validatedDownloadedPDFPath = nil
        }

        let outcome: BrowserSourceImportOutcome
        switch prepared.payload {
        case .metadata(
            let input,
            let result,
            let preferredPDFURL,
            let browserPDFSource
        ):
            if let browserPDFSource {
#if os(macOS)
                outcome = try commitMetadataPDF(
                    result: result,
                    source: browserPDFSource
                )
#else
                throw BrowserClipHostError.pdfImportUnavailable
#endif
                break
            }
            outcome = try await commitMetadata(
                input: input,
                result: result,
                preferredPDFURL: preferredPDFURL,
                downloadedPDFPath: validatedDownloadedPDFPath,
                downloadPDF: downloadPDF
            )
        case .website(let reference):
            outcome = try commitWebsite(reference)
        case .markdown(let source, let reference):
            outcome = try commitMarkdown(source: source, reference: reference)
#if os(macOS)
        case .pdf(_, let preparedPDF):
            outcome = try commitPDF(preparedPDF)
#endif
        }

        LibraryChangeBroadcaster.postChangeNotification()
        return .success(
            result: outcome.result,
            referenceID: outcome.referenceID,
            intakeID: outcome.intakeID,
            title: outcome.title,
            kind: outcome.kind,
            pdfAttached: outcome.pdfAttached,
            message: outcome.message
        )
    }

    private func prepareMetadata(
        _ input: String,
        page: BrowserClipPage,
        pageURL: URL,
        canonicalURL: URL?,
        browserPDFSource: MaterializedImportSource?
    ) async -> PreparedBrowserImport.Payload {
        let capturedFallback = makeCapturedReference(
            page,
            pageURL: pageURL,
            canonicalURL: canonicalURL,
            asPaper: true
        )

        let resolution = await metadataResolver(input, capturedFallback)
        let enrichedResult = enrichCapturedFallback(
            in: resolution.result,
            capturedFallback: capturedFallback
        )
        return .metadata(
            input: input,
            result: enrichedResult,
            preferredPDFURL: resolution.preferredPDFURL,
            browserPDFSource: browserPDFSource
        )
    }

    private func commitMetadata(
        input: String,
        result: MetadataResolutionResult,
        preferredPDFURL: String?,
        downloadedPDFPath: String?,
        downloadPDF: Bool
    ) async throws -> BrowserSourceImportOutcome {
        let persisted = try database.persistMetadataResolutionDetailed(
            result,
            options: MetadataPersistenceOptions(
                sourceKind: .manualEntry,
                originalInput: input
            )
        )
        switch persisted.result {
        case .verified(let reference):
            guard let referenceID = reference.id else {
                throw BrowserClipHostError.missingReferenceID
            }
            let pdf: (attached: Bool, message: String?)
            if downloadPDF {
                pdf = await attachPaperPDF(
                    to: reference,
                    referenceID: referenceID,
                    preferredPDFURL: preferredPDFURL,
                    downloadedPDFPath: downloadedPDFPath
                )
            } else {
                let alreadyAttached = hasMaterializedPDF(referenceID: referenceID)
                pdf = (
                    alreadyAttached,
                    alreadyAttached
                        ? "PDF download was skipped; a PDF is already attached."
                        : "Imported without downloading a PDF."
                )
            }
            return BrowserSourceImportOutcome(
                result: persisted.disposition == .existing ? .existing : .created,
                referenceID: referenceID,
                title: reference.title,
                kind: .paper,
                pdfAttached: pdf.attached,
                message: pdf.message
            )
        case .intake(let intake):
            return BrowserSourceImportOutcome(
                result: .queued,
                intakeID: intake.id,
                title: intake.title,
                kind: .paper
            )
        }
    }

    private func enrichCapturedFallback(
        in result: MetadataResolutionResult,
        capturedFallback: Reference
    ) -> MetadataResolutionResult {
        switch result {
        case .verified(let envelope):
            // A verified paper follows the same contract as Import Reference:
            // save bibliographic metadata and acquire a PDF. Captured HTML is
            // retained only for unresolved review fallbacks.
            return .verified(envelope)
        case .candidate(var envelope):
            envelope.fallbackReference = capturedReference(
                envelope.fallbackReference,
                merging: capturedFallback,
                useCaptureWhenMissing: true
            )
            envelope.currentReference = capturedReference(
                envelope.currentReference,
                merging: capturedFallback
            )
            return .candidate(envelope)
        case .blocked(var envelope):
            envelope.fallbackReference = capturedReference(
                envelope.fallbackReference,
                merging: capturedFallback,
                useCaptureWhenMissing: true
            )
            envelope.currentReference = capturedReference(
                envelope.currentReference,
                merging: capturedFallback
            )
            return .blocked(envelope)
        case .seedOnly(var envelope):
            envelope.fallbackReference = capturedReference(
                envelope.fallbackReference,
                merging: capturedFallback,
                useCaptureWhenMissing: true
            )
            envelope.currentReference = capturedReference(
                envelope.currentReference,
                merging: capturedFallback
            )
            return .seedOnly(envelope)
        case .rejected(var envelope):
            envelope.fallbackReference = capturedReference(
                envelope.fallbackReference,
                merging: capturedFallback,
                useCaptureWhenMissing: true
            )
            envelope.currentReference = capturedReference(
                envelope.currentReference,
                merging: capturedFallback
            )
            return .rejected(envelope)
        }
    }

    private func capturedReference(
        _ reference: Reference?,
        merging capturedFallback: Reference,
        useCaptureWhenMissing: Bool = false
    ) -> Reference? {
        guard var reference else {
            return useCaptureWhenMissing ? capturedFallback : nil
        }
        reference.webContent = reference.webContent ?? capturedFallback.webContent
        reference.favicon = reference.favicon ?? capturedFallback.favicon
        reference.siteName = reference.siteName ?? capturedFallback.siteName
        return reference
    }

    private func attachPaperPDF(
        to reference: Reference,
        referenceID: Int64,
        preferredPDFURL: String?,
        downloadedPDFPath: String?
    ) async -> (attached: Bool, message: String?) {
        let browserSourceURL = downloadedPDFPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .rubien_nilIfBlank
            .map { URL(fileURLWithPath: $0) }
        defer {
            if let browserSourceURL {
                try? FileManager.default.removeItem(at: browserSourceURL)
            }
        }

        if hasMaterializedPDF(referenceID: referenceID) {
            return (true, "A PDF is already attached to this reference.")
        }

        var browserDownloadError: Error?
        if let sourceURL = browserSourceURL {
            do {
                let path = sourceURL.path
                guard path.utf8.count <= 16_384, path.hasPrefix("/") else {
                    throw BrowserClipHostError.pdfImportUnavailable
                }
                let filename = try downloadedPDFImporter(sourceURL)
                let attached = try attachStoredPDF(filename, referenceID: referenceID)
                return attached
                    ? (true, "The authenticated PDF was downloaded and attached.")
                    : (hasMaterializedPDF(referenceID: referenceID), "A PDF is already attached to this reference.")
            } catch {
                browserDownloadError = error
            }
        }

        guard preferredPDFURL != nil || reference.canDownloadPDF else {
            return (
                false,
                browserDownloadError.map {
                    "The reference was imported, but the browser PDF could not be attached: \($0.localizedDescription)"
                }
            )
        }

        do {
            let filename = try await pdfDownloader(reference, preferredPDFURL)
            let attached = try attachStoredPDF(filename, referenceID: referenceID)
            return attached
                ? (true, "The PDF was downloaded and attached.")
                : (hasMaterializedPDF(referenceID: referenceID), "A PDF is already attached to this reference.")
        } catch {
            let detail: String
            if let browserDownloadError {
                detail = "Chrome: \(browserDownloadError.localizedDescription); Rubien: \(error.localizedDescription)"
            } else {
                detail = error.localizedDescription
            }
            return (false, "The reference was imported, but the PDF download failed: \(detail)")
        }
    }

    private func attachStoredPDF(
        _ filename: String,
        referenceID: Int64
    ) throws -> Bool {
        do {
            let attached = try database.attachImportedPDF(
                referenceId: referenceID,
                filename: filename
            )
            if attached {
                PDFUploadQueueBroadcaster.postChangeNotification()
            } else {
                pdfDeleter(filename)
            }
            return attached
        } catch {
            pdfDeleter(filename)
            throw error
        }
    }

    private func hasMaterializedPDF(referenceID: Int64) -> Bool {
        guard let filename = try? database.pdfFilename(for: referenceID) else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: AppDatabase.pdfStorageURL.appendingPathComponent(filename).path
        )
    }

    private static func importDownloadedPDF(from sourceURL: URL) throws -> String {
        guard fileStartsWithPDFMagic(sourceURL) else {
            throw PDFDownloadService.DownloadError.notAPDF
        }
#if os(macOS)
        try FileManager.default.createDirectory(
            at: AppDatabase.pdfStorageURL,
            withIntermediateDirectories: true
        )
        return try PDFService.importPDF(from: sourceURL)
#else
        throw BrowserClipHostError.pdfImportUnavailable
#endif
    }

    private static func fileStartsWithPDFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 5)) == Data("%PDF-".utf8)
    }

    private func prepareWebsite(
        _ page: BrowserClipPage,
        pageURL: URL,
        canonicalURL: URL?
    ) -> PreparedBrowserImport.Payload {
        var reference = makeCapturedReference(
            page,
            pageURL: pageURL,
            canonicalURL: canonicalURL,
            asPaper: false
        )
        reference = MetadataVerifier.manuallyVerified(reference, reviewedBy: "browser-clipper")
        return .website(reference)
    }

    private func commitWebsite(_ preparedReference: Reference) throws -> BrowserSourceImportOutcome {
        var reference = preparedReference
        let saveResult = try database.saveReference(&reference)
        guard let referenceID = reference.id else {
            throw BrowserClipHostError.missingReferenceID
        }
        return BrowserSourceImportOutcome(
            result: saveResult == .created ? .created : .existing,
            referenceID: referenceID,
            title: reference.title,
            kind: .webpage
        )
    }

    private func makePreview(
        confirmationID: String,
        payload: PreparedBrowserImport.Payload,
        pageURL: URL
    ) -> BrowserClipConfirmationPreview {
        switch payload {
        case .metadata(_, let result, let preferredPDFURL, let browserPDFSource):
            return makeResolutionPreview(
                confirmationID: confirmationID,
                result: result,
                kind: .paper,
                fallbackTitle: pageURL.host ?? "Paper",
                fallbackURL: pageURL.absoluteString,
                preferredPDFURL: browserPDFSource == nil ? preferredPDFURL : nil,
                paperPDFAlreadyStaged: browserPDFSource != nil
            )
        case .website(let reference):
            return makeReferencePreview(
                confirmationID: confirmationID,
                reference: reference,
                kind: .webpage,
                willQueueForReview: false,
                fallbackTitle: pageURL.host ?? "Web page",
                fallbackURL: pageURL.absoluteString,
                message: reference.webContent == nil
                    ? "Review this web reference before importing."
                    : "Authenticated page content was captured for review."
            )
        case .markdown(let source, let reference):
            return makeReferencePreview(
                confirmationID: confirmationID,
                reference: reference,
                kind: .markdown,
                willQueueForReview: false,
                fallbackTitle: source.fileURL.deletingPathExtension().lastPathComponent,
                fallbackURL: source.input,
                message: "Review the parsed Markdown reference before importing."
            )
#if os(macOS)
        case .pdf(let source, let prepared):
            return makeResolutionPreview(
                confirmationID: confirmationID,
                result: prepared.resolution,
                kind: .pdf,
                fallbackTitle: source.fileURL.deletingPathExtension().lastPathComponent,
                fallbackURL: source.input,
                preferredPDFURL: nil
            )
#endif
        }
    }

    private func makeResolutionPreview(
        confirmationID: String,
        result: MetadataResolutionResult,
        kind: BrowserClipImportKind,
        fallbackTitle: String,
        fallbackURL: String,
        preferredPDFURL: String?,
        paperPDFAlreadyStaged: Bool = false
    ) -> BrowserClipConfirmationPreview {
        let reference: Reference?
        let willQueueForReview: Bool
        let message: String
        switch result {
        case .verified(let envelope):
            reference = envelope.reference
            willQueueForReview = false
            message = paperPDFAlreadyStaged
                ? "Bibliographic metadata and the authenticated PDF are ready to import."
                : kind == .pdf
                ? "PDF metadata is ready to import."
                : "Bibliographic metadata was verified by Rubien."
        case .candidate(let envelope):
            reference = envelope.currentReference ?? envelope.fallbackReference
            willQueueForReview = true
            message = envelope.message
        case .blocked(let envelope):
            reference = envelope.currentReference ?? envelope.fallbackReference
            willQueueForReview = true
            message = envelope.message
        case .seedOnly(let envelope):
            reference = envelope.currentReference ?? envelope.fallbackReference
            willQueueForReview = true
            message = envelope.message
        case .rejected(let envelope):
            reference = envelope.currentReference ?? envelope.fallbackReference
            willQueueForReview = true
            message = envelope.message
        }

        return makeReferencePreview(
            confirmationID: confirmationID,
            reference: reference,
            kind: kind,
            willQueueForReview: willQueueForReview,
            fallbackTitle: fallbackTitle,
            fallbackURL: fallbackURL,
            preferredPDFURL: preferredPDFURL,
            paperPDFAlreadyStaged: paperPDFAlreadyStaged,
            message: message
        )
    }

    private func makeReferencePreview(
        confirmationID: String,
        reference: Reference?,
        kind: BrowserClipImportKind,
        willQueueForReview: Bool,
        fallbackTitle: String,
        fallbackURL: String,
        preferredPDFURL: String? = nil,
        paperPDFAlreadyStaged: Bool = false,
        message: String
    ) -> BrowserClipConfirmationPreview {
        BrowserClipConfirmationPreview(
            confirmationID: confirmationID,
            title: reference?.title.rubien_nilIfBlank ?? fallbackTitle,
            kind: kind,
            authors: Array(reference?.authors.map(\.displayName).prefix(20) ?? []),
            year: reference?.year,
            containerTitle: reference?.journal.rubien_nilIfBlank
                ?? reference?.eventTitle.rubien_nilIfBlank
                ?? reference?.publisher.rubien_nilIfBlank
                ?? reference?.siteName.rubien_nilIfBlank,
            sourceURL: reference?.url.rubien_nilIfBlank ?? fallbackURL,
            willQueueForReview: willQueueForReview,
            hasCapturedContent: reference?.webContent != nil,
            willDownloadPDF: !willQueueForReview
                && kind == .paper
                && !paperPDFAlreadyStaged
                && (preferredPDFURL != nil || reference?.canDownloadPDF == true),
            pdfDownloadURL: !willQueueForReview ? preferredPDFURL : nil,
            message: message
        )
    }

    private func makeCapturedReference(
        _ page: BrowserClipPage,
        pageURL: URL,
        canonicalURL: URL?,
        asPaper: Bool
    ) -> Reference {
        let sourceURL = canonicalURL ?? pageURL
        let citation = page.citation ?? BrowserCitationMetadata()
        let citationAuthors = citation.authors.flatMap(AuthorName.parseList)
        let authors = asPaper && !citationAuthors.isEmpty
            ? citationAuthors
            : AuthorName.parseList(page.author ?? "")
        let pages: String? = {
            switch (citation.firstPage, citation.lastPage) {
            case let (first?, last?) where first != last: return "\(first)-\(last)"
            case let (first?, _): return first
            case let (_, last?): return last
            default: return nil
            }
        }()
        let fallbackTitle = sourceURL.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = asPaper ? (citation.title ?? page.title) : page.title
        let referenceType: ReferenceType = asPaper
            ? (citation.conferenceTitle == nil ? .journalArticle : .conferencePaper)
            : .webpage

        return Reference(
            title: title ?? fallbackTitle ?? "Web page",
            authors: authors,
            year: asPaper ? citation.publicationDate.flatMap(MetadataResolution.extractYear(fromMetadataText:)) : nil,
            journal: asPaper ? (citation.journalTitle ?? citation.conferenceTitle) : nil,
            volume: asPaper ? citation.volume : nil,
            issue: asPaper ? citation.issue : nil,
            pages: asPaper ? pages : nil,
            doi: asPaper ? cleanedDOI(citation.doi) : nil,
            url: sourceURL.absoluteString,
            abstract: asPaper ? (citation.abstract ?? page.excerpt) : page.excerpt,
            webContent: Reference.encodeWebContent(page.contentHTML, format: .html),
            siteName: page.siteName ?? sourceURL.host,
            favicon: page.faviconURL.flatMap(httpURL)?.absoluteString,
            referenceType: referenceType,
            publisher: asPaper ? citation.publisher : nil,
            isbn: asPaper ? citation.isbn : nil,
            issn: asPaper ? citation.issn : nil,
            eventTitle: asPaper ? citation.conferenceTitle : nil
        )
    }

    private func sanitized(_ page: BrowserClipPage) throws -> BrowserClipPage {
        let citation = page.citation ?? BrowserCitationMetadata()
        guard citation.authors.count <= 100 else {
            throw BrowserClipHostError.tooManyAuthors
        }
        return BrowserClipPage(
            url: page.url,
            canonicalURL: page.canonicalURL,
            title: try bounded(page.title, field: "title", maximumBytes: 4_096),
            author: try bounded(page.author, field: "author", maximumBytes: 16_384),
            excerpt: try bounded(page.excerpt, field: "abstract", maximumBytes: 64 * 1_024),
            siteName: try bounded(page.siteName, field: "site name", maximumBytes: 1_024),
            faviconURL: try bounded(page.faviconURL, field: "favicon URL", maximumBytes: 8_192),
            contentHTML: try bounded(
                page.contentHTML,
                field: "article body",
                maximumBytes: BrowserClipContract.maximumHTMLBytes
            ),
            citation: BrowserCitationMetadata(
                title: try bounded(citation.title, field: "citation title", maximumBytes: 4_096),
                authors: try citation.authors.compactMap {
                    try bounded($0, field: "citation author", maximumBytes: 4_096)
                },
                publicationDate: try bounded(citation.publicationDate, field: "publication date", maximumBytes: 1_024),
                journalTitle: try bounded(citation.journalTitle, field: "journal", maximumBytes: 4_096),
                conferenceTitle: try bounded(citation.conferenceTitle, field: "conference", maximumBytes: 4_096),
                volume: try bounded(citation.volume, field: "volume", maximumBytes: 1_024),
                issue: try bounded(citation.issue, field: "issue", maximumBytes: 1_024),
                firstPage: try bounded(citation.firstPage, field: "first page", maximumBytes: 1_024),
                lastPage: try bounded(citation.lastPage, field: "last page", maximumBytes: 1_024),
                doi: try bounded(citation.doi, field: "DOI", maximumBytes: 2_048),
                isbn: try bounded(citation.isbn, field: "ISBN", maximumBytes: 2_048),
                issn: try bounded(citation.issn, field: "ISSN", maximumBytes: 2_048),
                abstract: try bounded(citation.abstract, field: "citation abstract", maximumBytes: 64 * 1_024),
                publisher: try bounded(citation.publisher, field: "publisher", maximumBytes: 4_096),
                pdfURL: try bounded(citation.pdfURL, field: "PDF URL", maximumBytes: 8_192),
                arxivID: try bounded(citation.arxivID, field: "arXiv identifier", maximumBytes: 2_048)
            ),
            browserDownloadedFilePath: try bounded(
                page.browserDownloadedFilePath,
                field: "browser download path",
                maximumBytes: 16_384
            ),
            browserDownloadToken: try bounded(
                page.browserDownloadToken,
                field: "browser download token",
                maximumBytes: 64
            )
        )
    }

    private func rejectUnexpectedBrowserDownload(in page: BrowserClipPage) throws {
        guard page.browserDownloadedFilePath == nil,
              page.browserDownloadToken == nil else {
            throw BrowserClipHostError.invalidBrowserDownload
        }
    }

    private func validatedBrowserDownloadedFilePath(
        in page: BrowserClipPage,
        sourceURL: URL
    ) throws -> String? {
        guard page.browserDownloadedFilePath != nil || page.browserDownloadToken != nil else {
            return nil
        }
        guard let path = page.browserDownloadedFilePath,
              let rawToken = page.browserDownloadToken,
              let token = UUID(uuidString: rawToken),
              let kind = ImportSourceKind(pathExtension: sourceURL.pathExtension) else {
            throw BrowserClipHostError.invalidBrowserDownload
        }
        let pathExtension = kind == .pdf ? "pdf" : sourceURL.pathExtension.lowercased()
        return try validatedBrowserDownloadPath(
            path,
            expectedDirectory: "Rubien",
            expectedFilename: "rubien-preview-\(token.uuidString.lowercased()).\(pathExtension)"
        )
    }

    private func validatedConfirmedPDFPath(
        _ path: String,
        confirmationID: String
    ) throws -> String {
        try validatedBrowserDownloadPath(
            path,
            expectedDirectory: "Rubien",
            expectedFilename: "rubien-\(confirmationID.lowercased()).pdf"
        )
    }

    private func validatedBrowserDownloadPath(
        _ path: String,
        expectedDirectory: String,
        expectedFilename: String
    ) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384 else {
            throw BrowserClipHostError.invalidBrowserDownload
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let components = url.pathComponents
        guard components.count >= 3,
              components[components.count - 2] == expectedDirectory,
              components.last == expectedFilename,
              url.resolvingSymlinksInPath() == url else {
            throw BrowserClipHostError.invalidBrowserDownload
        }
        return url.path
    }

    private func bounded(
        _ rawValue: String?,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        guard value.utf8.count <= maximumBytes else {
            throw BrowserClipHostError.fieldTooLarge(field)
        }
        return value
    }

    private func httpURL(_ rawValue: String) -> URL? {
        Self.httpURL(rawValue)
    }

    private static func httpURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8_192,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func cleanedDOI(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let range = value.range(of: "doi.org/", options: .caseInsensitive) {
            value = String(value[range.upperBound...])
        } else if value.lowercased().hasPrefix("doi:") {
            value = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.lowercased().hasPrefix("10."), value.contains("/") else {
            return nil
        }
        return value
    }

    private static func prepareFile(
        _ source: String,
        browserDownloadedFilePath: String?
    ) async throws -> PreparedBrowserImport.Payload {
        let materialized: MaterializedImportSource
        if let browserDownloadedFilePath {
            guard let expectedKind = URL(string: source).flatMap({
                ImportSourceKind(pathExtension: $0.pathExtension)
            }) else {
                throw BrowserClipHostError.invalidBrowserDownload
            }
            materialized = try materializeBrowserDownload(
                input: source,
                path: browserDownloadedFilePath,
                expectedKind: expectedKind
            )
        } else {
            materialized = try await ImportSourceMaterializer.materialize(
                source,
                localPathPolicy: .requireAbsolute
            )
        }

        do {
            switch materialized.kind {
            case .pdf:
#if os(macOS)
                let prepared = await PDFImportCoordinator.preparePDF(
                    from: materialized.fileURL
                )
                return .pdf(source: materialized, prepared: prepared)
#else
                throw BrowserClipHostError.pdfImportUnavailable
#endif

            case .markdown:
                let content = try String(contentsOf: materialized.fileURL, encoding: .utf8)
                let reference = MarkdownImporter.parse(
                    content,
                    filename: materialized.fileURL.deletingPathExtension().lastPathComponent
                )
                return .markdown(source: materialized, reference: reference)
            }
        } catch {
            materialized.cleanup()
            throw error
        }
    }

    /// Copies a Chrome-owned temporary download into Rubien's private staging
    /// directory, then removes the browser file. The private copy survives for
    /// preview/confirmation; Chrome history can be erased independently.
    private static func materializeBrowserDownload(
        input: String,
        path: String,
        expectedKind: ImportSourceKind
    ) throws -> MaterializedImportSource {
        let browserURL = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: browserURL) }

        let materialized = try ImportSourceMaterializer.materializeTemporaryCopy(
            localFileURL: browserURL,
            originalInput: input
        )
        do {
            guard materialized.kind == expectedKind else {
                throw BrowserClipHostError.invalidBrowserDownload
            }
            if expectedKind == .pdf, !fileStartsWithPDFMagic(materialized.fileURL) {
                throw PDFDownloadService.DownloadError.notAPDF
            }
            return materialized
        } catch {
            materialized.cleanup()
            throw error
        }
    }

    private func commitMarkdown(
        source: MaterializedImportSource,
        reference: Reference
    ) throws -> BrowserSourceImportOutcome {
        guard let item = try database.batchImportReferencesDetailed(
            [(input: source.input, reference: reference)],
            mergePolicy: .markdownFillOnly
        ).first,
        let saved = item.reference,
        let referenceID = saved.id else {
            throw BrowserClipHostError.missingImportResult
        }
        return BrowserSourceImportOutcome(
            result: item.disposition == .existing ? .existing : .created,
            referenceID: referenceID,
            title: saved.title,
            kind: .markdown
        )
    }

#if os(macOS)
    private func commitMetadataPDF(
        result: MetadataResolutionResult,
        source: MaterializedImportSource
    ) throws -> BrowserSourceImportOutcome {
        let detailed = try PDFImportCoordinator.commitPreparedPDFDetailed(
            PreparedPDFImport(sourceURL: source.fileURL, resolution: result),
            database: database
        )
        detailed.outcome.postImportNotifications(
            libraryChanged: {},
            uploadQueueChanged: PDFUploadQueueBroadcaster.postChangeNotification
        )
        switch detailed.outcome {
        case .imported(let reference):
            guard let referenceID = reference.id else {
                throw BrowserClipHostError.missingReferenceID
            }
            return BrowserSourceImportOutcome(
                result: detailed.disposition == .existing ? .existing : .created,
                referenceID: referenceID,
                title: reference.title,
                kind: .paper,
                pdfAttached: true,
                message: "The authenticated PDF was imported and attached."
            )
        case .queued(let intake):
            return BrowserSourceImportOutcome(
                result: .queued,
                intakeID: intake.id,
                title: intake.title,
                kind: .paper,
                message: "The authenticated PDF was preserved for metadata review."
            )
        }
    }

    private func commitPDF(
        _ prepared: PreparedPDFImport
    ) throws -> BrowserSourceImportOutcome {
        let detailed = try PDFImportCoordinator.commitPreparedPDFDetailed(
            prepared,
            database: database
        )
        detailed.outcome.postImportNotifications(
            libraryChanged: {},
            uploadQueueChanged: PDFUploadQueueBroadcaster.postChangeNotification
        )
        switch detailed.outcome {
        case .imported(let reference):
            guard let referenceID = reference.id else {
                throw BrowserClipHostError.missingReferenceID
            }
            return BrowserSourceImportOutcome(
                result: detailed.disposition == .existing ? .existing : .created,
                referenceID: referenceID,
                title: reference.title,
                kind: .pdf,
                pdfAttached: true
            )
        case .queued(let intake):
            return BrowserSourceImportOutcome(
                result: .queued,
                intakeID: intake.id,
                title: intake.title,
                kind: .pdf
            )
        }
    }
#endif

}
