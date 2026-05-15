import Foundation

public struct PDFMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: [String]
    public var creator: String?
    public var producer: String?
    public var creationDate: Date?
    public var modificationDate: Date?

    public init(
        title: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        keywords: [String] = [],
        creator: String? = nil,
        producer: String? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
        self.creator = creator
        self.producer = producer
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

public struct PDFPageBox: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var originX: Double
    public var originY: Double

    public init(width: Double, height: Double, originX: Double = 0, originY: Double = 0) {
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
    }
}

/// Recursive outline tree. `pageIndex` is 0-based; nil for container-only
/// bookmarks (whose effective start page is the first descendant with a
/// destination — `PDFExtractor.flattenOutline` does that backfill).
public struct PDFOutlineNode: Sendable {
    public var label: String
    public var pageIndex: Int?
    public var children: [PDFOutlineNode]

    public init(label: String, pageIndex: Int?, children: [PDFOutlineNode] = []) {
        self.label = label
        self.pageIndex = pageIndex
        self.children = children
    }
}

public struct PDFRenderResult: Sendable, Equatable {
    public var data: Data
    public var widthPx: Int
    public var heightPx: Int
    public var mimeType: String
    public var qualityUsed: Double?

    public init(data: Data, widthPx: Int, heightPx: Int, mimeType: String, qualityUsed: Double? = nil) {
        self.data = data
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.mimeType = mimeType
        self.qualityUsed = qualityUsed
    }
}

public enum PDFRenderFormat: String, Sendable, Equatable {
    case jpeg
    case png
}

public enum PDFOpenError: Error, Equatable, Sendable {
    case fileMissing(URL)
    case cannotOpen(URL)
    case locked
}

public enum PDFRenderError: Error, Equatable, Sendable {
    case pageOutOfRange(Int)
    case renderFailed
    case maxBytesExceeded(Int)
    case formatUnsupportedOnPlatform
}

public protocol PDFDocumentProtocol: AnyObject, Sendable {
    var pageCount: Int { get }
    var metadata: PDFMetadata { get }
    var isEncrypted: Bool { get }
    var isLocked: Bool { get }
    func page(at index: Int) -> PDFPageProtocol?
    func outlineRoot() -> PDFOutlineNode?
}

public protocol PDFPageProtocol: AnyObject, Sendable {
    var label: String? { get }
    var mediaBox: PDFPageBox { get }
    func extractedText() -> String?
    func render(scale: Double, format: PDFRenderFormat, maxBytes: Int) throws -> PDFRenderResult
}
