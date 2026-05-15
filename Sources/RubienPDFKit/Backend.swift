import Foundation

public enum PDFBackend {
    public static func open(url: URL) throws -> any PDFDocumentProtocol {
        #if canImport(PDFKit)
        return try DarwinPDFDocument(url: url)
        #else
        // Linux poppler backend lands in the next commit. Until then,
        // non-Darwin platforms fail closed so any caller path that survives
        // the build gates Phase 1/2 already installed gets a clear error.
        throw PDFOpenError.cannotOpen(url)
        #endif
    }
}
