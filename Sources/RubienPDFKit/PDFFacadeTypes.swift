import Foundation

// All types in this file are `internal` — they describe the contract
// between RubienPDFKit's facade and its backends (Darwin/Linux). External
// consumers (`RubienCLI`, the SwiftUI app) interact with the higher-level
// `PDFExtractor` / `PDFService` API, which translates between these
// internal types and its own public surface. Tests reach in via
// `@testable import RubienPDFKit`.

struct PDFMetadata: Sendable, Equatable {
    var title: String?
    var author: String?
    var subject: String?
    var keywords: [String] = []
    var creator: String?
    var producer: String?
    var creationDate: Date?
    var modificationDate: Date?
}

struct PDFPageBox: Sendable, Equatable {
    var width: Double
    var height: Double
    var originX: Double = 0
    var originY: Double = 0
}

/// `pageIndex` is 0-based; nil for container-only bookmarks whose start
/// page is borrowed from the first descendant with a destination — the
/// cross-platform flattener does that backfill.
struct PDFOutlineNode: Sendable {
    var label: String
    var pageIndex: Int?
    var children: [PDFOutlineNode] = []
}

struct PDFRenderResult: Sendable, Equatable {
    var data: Data
    var widthPx: Int
    var heightPx: Int
    var mimeType: String
    var qualityUsed: Double?
}

enum PDFRenderFormat: String, Sendable, Equatable {
    case jpeg
    case png
}

enum PDFOpenError: Error, Equatable, Sendable {
    case fileMissing(URL)
    case cannotOpen(URL)
    case locked
}

enum PDFRenderError: Error, Equatable, Sendable {
    case pageOutOfRange(Int)
    case renderFailed
    case maxBytesExceeded(Int)
    case formatUnsupportedOnPlatform
}

protocol PDFDocumentProtocol: AnyObject, Sendable {
    var pageCount: Int { get }
    var metadata: PDFMetadata { get }
    var isEncrypted: Bool { get }
    var isLocked: Bool { get }
    func page(at index: Int) -> PDFPageProtocol?
    func outlineRoot() -> PDFOutlineNode?
}

protocol PDFPageProtocol: AnyObject, Sendable {
    var label: String? { get }
    var mediaBox: PDFPageBox { get }
    func extractedText() -> String?
    func render(scale: Double, format: PDFRenderFormat, maxBytes: Int) throws -> PDFRenderResult
}
