import Foundation

enum PDFBackend {
    static func open(url: URL) throws -> any PDFDocumentProtocol {
        #if canImport(PDFKit)
        return try DarwinPDFDocument(url: url)
        #elseif os(Linux)
        return try LinuxPDFDocument(url: url)
        #else
        throw PDFOpenError.cannotOpen(url)
        #endif
    }
}
