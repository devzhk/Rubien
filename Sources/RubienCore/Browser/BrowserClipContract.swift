import Foundation

/// Versioned wire contract between the Chrome extension and the native
/// messaging helper. These are transport values only; the browser-specific
/// database mutation stays in the helper executable target.
public enum BrowserClipContract {
    public static let protocolVersion = 4
    public static let nativeHostName = "com.rubien.browser_clipper"
    public static let extensionID = "pggebflfobimhklmgebcfgeobajkgdbb"
    public static let allowedExtensionOrigin = "chrome-extension://\(extensionID)/"

    /// The HTML limit is enforced in both the extension and helper. The larger
    /// envelope cap leaves room for worst-case JSON escaping (one input byte
    /// can become a six-byte `\u00XX` escape) and metadata while rejecting a
    /// compromised extension before it can force an unbounded allocation.
    public static let maximumHTMLBytes = 8 * 1024 * 1024
    public static let maximumMessageBytes = 64 * 1024 * 1024
    public static let maximumResponseMessageBytes = 1 * 1024 * 1024
}

public struct BrowserClipRequest: Codable, Sendable, Equatable {
    public var version: Int
    public var command: String
    public var page: BrowserClipPage?
    public var confirmationID: String?
    public var downloadedPDFPath: String?
    public var downloadPDF: Bool?

    public init(
        version: Int,
        command: String,
        page: BrowserClipPage? = nil,
        confirmationID: String? = nil,
        downloadedPDFPath: String? = nil,
        downloadPDF: Bool? = nil
    ) {
        self.version = version
        self.command = command
        self.page = page
        self.confirmationID = confirmationID
        self.downloadedPDFPath = downloadedPDFPath
        self.downloadPDF = downloadPDF
    }
}

public struct BrowserClipPage: Codable, Sendable, Equatable {
    public var url: String
    public var canonicalURL: String?
    public var title: String?
    public var author: String?
    public var excerpt: String?
    public var siteName: String?
    public var faviconURL: String?
    public var contentHTML: String?
    public var citation: BrowserCitationMetadata?
    public var browserDownloadedFilePath: String?
    public var browserDownloadToken: String?

    public init(
        url: String,
        canonicalURL: String? = nil,
        title: String? = nil,
        author: String? = nil,
        excerpt: String? = nil,
        siteName: String? = nil,
        faviconURL: String? = nil,
        contentHTML: String? = nil,
        citation: BrowserCitationMetadata? = nil,
        browserDownloadedFilePath: String? = nil,
        browserDownloadToken: String? = nil
    ) {
        self.url = url
        self.canonicalURL = canonicalURL
        self.title = title
        self.author = author
        self.excerpt = excerpt
        self.siteName = siteName
        self.faviconURL = faviconURL
        self.contentHTML = contentHTML
        self.citation = citation
        self.browserDownloadedFilePath = browserDownloadedFilePath
        self.browserDownloadToken = browserDownloadToken
    }
}

public struct BrowserCitationMetadata: Codable, Sendable, Equatable {
    public var title: String?
    public var authors: [String]
    public var publicationDate: String?
    public var journalTitle: String?
    public var conferenceTitle: String?
    public var volume: String?
    public var issue: String?
    public var firstPage: String?
    public var lastPage: String?
    public var doi: String?
    public var isbn: String?
    public var issn: String?
    public var abstract: String?
    public var publisher: String?
    public var pdfURL: String?
    public var arxivID: String?

    public init(
        title: String? = nil,
        authors: [String] = [],
        publicationDate: String? = nil,
        journalTitle: String? = nil,
        conferenceTitle: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        firstPage: String? = nil,
        lastPage: String? = nil,
        doi: String? = nil,
        isbn: String? = nil,
        issn: String? = nil,
        abstract: String? = nil,
        publisher: String? = nil,
        pdfURL: String? = nil,
        arxivID: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.publicationDate = publicationDate
        self.journalTitle = journalTitle
        self.conferenceTitle = conferenceTitle
        self.volume = volume
        self.issue = issue
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.doi = doi
        self.isbn = isbn
        self.issn = issn
        self.abstract = abstract
        self.publisher = publisher
        self.pdfURL = pdfURL
        self.arxivID = arxivID
    }
}

public enum BrowserClipSaveResult: String, Codable, Sendable, Equatable {
    case created
    case existing
    case queued
}

/// The branch selected by the same URL router that backs Import Reference.
public enum BrowserClipImportKind: String, Codable, Sendable, Equatable {
    case paper
    case pdf
    case markdown
    case webpage
}

/// User-visible description of a fully prepared browser import. The native
/// helper keeps the corresponding prepared value in memory and performs no
/// database writes until a matching confirmation arrives on the same port.
public struct BrowserClipConfirmationPreview: Codable, Sendable, Equatable {
    public var confirmationID: String
    public var title: String
    public var kind: BrowserClipImportKind
    public var authors: [String]
    public var year: Int?
    public var containerTitle: String?
    public var sourceURL: String?
    public var willQueueForReview: Bool
    public var hasCapturedContent: Bool
    public var willDownloadPDF: Bool
    public var pdfDownloadURL: String?
    public var message: String?

    public init(
        confirmationID: String,
        title: String,
        kind: BrowserClipImportKind,
        authors: [String] = [],
        year: Int? = nil,
        containerTitle: String? = nil,
        sourceURL: String? = nil,
        willQueueForReview: Bool = false,
        hasCapturedContent: Bool = false,
        willDownloadPDF: Bool = false,
        pdfDownloadURL: String? = nil,
        message: String? = nil
    ) {
        self.confirmationID = confirmationID
        self.title = title
        self.kind = kind
        self.authors = authors
        self.year = year
        self.containerTitle = containerTitle
        self.sourceURL = sourceURL
        self.willQueueForReview = willQueueForReview
        self.hasCapturedContent = hasCapturedContent
        self.willDownloadPDF = willDownloadPDF
        self.pdfDownloadURL = pdfDownloadURL
        self.message = message
    }
}

public struct BrowserClipFailure: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct BrowserClipResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var result: BrowserClipSaveResult?
    public var referenceID: Int64?
    public var intakeID: Int64?
    public var title: String?
    public var kind: BrowserClipImportKind?
    public var pdfAttached: Bool?
    public var message: String?
    public var preview: BrowserClipConfirmationPreview?
    public var error: BrowserClipFailure?

    public init(
        ok: Bool,
        result: BrowserClipSaveResult? = nil,
        referenceID: Int64? = nil,
        intakeID: Int64? = nil,
        title: String? = nil,
        kind: BrowserClipImportKind? = nil,
        pdfAttached: Bool? = nil,
        message: String? = nil,
        preview: BrowserClipConfirmationPreview? = nil,
        error: BrowserClipFailure? = nil
    ) {
        self.ok = ok
        self.result = result
        self.referenceID = referenceID
        self.intakeID = intakeID
        self.title = title
        self.kind = kind
        self.pdfAttached = pdfAttached
        self.message = message
        self.preview = preview
        self.error = error
    }

    public static func success(
        result: BrowserClipSaveResult,
        referenceID: Int64? = nil,
        intakeID: Int64? = nil,
        title: String,
        kind: BrowserClipImportKind,
        pdfAttached: Bool = false,
        message: String? = nil
    ) -> BrowserClipResponse {
        BrowserClipResponse(
            ok: true,
            result: result,
            referenceID: referenceID,
            intakeID: intakeID,
            title: title,
            kind: kind,
            pdfAttached: pdfAttached,
            message: message
        )
    }

    public static func failure(code: String, message: String) -> BrowserClipResponse {
        BrowserClipResponse(
            ok: false,
            error: BrowserClipFailure(code: code, message: message)
        )
    }

    public static func confirmation(
        _ preview: BrowserClipConfirmationPreview
    ) -> BrowserClipResponse {
        BrowserClipResponse(ok: true, preview: preview)
    }
}
