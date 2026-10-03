import Foundation
import RubienCore

public enum ReferenceAttachmentPDFValidator {
    public static func validate(_ url: URL) throws {
        guard let document = try? PDFBackend.open(url: url), document.pageCount > 0 else {
            throw ReferenceAttachmentError.invalidPDF
        }
    }
}
