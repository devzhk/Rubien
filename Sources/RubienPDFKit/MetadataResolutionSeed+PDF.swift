import Foundation
import RubienCore

private let pdfSeedLog = RubienLogger(subsystem: "com.rubien.metadata", category: "resolution.pdf")

public extension MetadataResolutionSeed {
    /// Build a `MetadataResolutionSeed` from a PDF that just got imported into
    /// the library, combining the user-visible filename (often the most
    /// reliable handle) with the metadata `PDFService` pulled out of the file.
    static func fromImportedPDF(url: URL, extracted: PDFService.ExtractedMetadata) -> MetadataResolutionSeed {
        let originalFileName = url.deletingPathExtension().lastPathComponent
        let cleanedFileName = MetadataResolution.cleanPDFSeedFilename(originalFileName)
        let parsed = MetadataResolution.parsePDFFileNameSeed(cleanedFileName)

        let extractedTitle = extracted.title?.rubien_nilIfBlank
        let title: String?
        if let extractedTitle, !MetadataResolution.isSuspiciousExtractedTitle(extractedTitle) {
            title = extractedTitle
        } else {
            title = parsed.title ?? extractedTitle ?? cleanedFileName.rubien_nilIfBlank
        }

        let firstAuthor = extracted.authors.first?.displayName.rubien_nilIfBlank
            ?? parsed.firstAuthor
            ?? MetadataResolution.extractLikelyAuthorName(from: cleanedFileName)

        let seed = MetadataResolutionSeed(
            fileName: cleanedFileName,
            title: title,
            firstAuthor: firstAuthor,
            year: extracted.year,
            doi: extracted.doi,
            journal: extracted.journal,
            isbn: extracted.isbn,
            issn: extracted.issn,
            publisher: extracted.publisher,
            edition: extracted.edition,
            workKindHint: extracted.workKindHint,
            textSnippet: extracted.textSnippet,
            sourceURL: url.absoluteString
        )
        pdfSeedLog.debug("""
            🌱 [seed] PDF seed built
              fileName: \(cleanedFileName)
              title: \(title ?? "nil")
              author: \(firstAuthor ?? "nil")
              year: \(extracted.year.map(String.init) ?? "nil")
              DOI: \(extracted.doi ?? "nil")
            """)
        return seed
    }

    /// Build a fully-populated `Reference` from a PDF's extracted metadata as
    /// the fallback when no online resolver yields a verified record. The
    /// returned reference is suitable for inserting straight into the library.
    static func fallbackReference(from extracted: PDFService.ExtractedMetadata, url: URL) -> Reference {
        let seed = MetadataResolutionSeed.fromImportedPDF(url: url, extracted: extracted)
        return Reference(
            title: extracted.title?.rubien_nilIfBlank ?? seed.title ?? MetadataResolution.cleanPDFSeedFilename(url.deletingPathExtension().lastPathComponent),
            authors: extracted.authors,
            year: extracted.year,
            journal: extracted.journal,
            doi: extracted.doi,
            abstract: extracted.abstract,
            referenceType: extracted.workKindHint.referenceType,
            publisher: extracted.publisher,
            edition: extracted.edition,
            isbn: extracted.isbn,
            issn: extracted.issn,
            language: extracted.language
        )
    }
}
