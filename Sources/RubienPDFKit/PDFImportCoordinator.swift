import Foundation
import RubienCore

public enum PDFImportOutcome: Sendable {
    case imported(Reference)
    case queued(MetadataIntake)
}

/// Coordinates the durable half of a PDF import after a caller has chosen or
/// downloaded its source file. It owns the copied-library-PDF lifecycle so all
/// front doors persist verified and pending metadata the same way.
public enum PDFImportCoordinator {
    public typealias Resolver = (URL, PDFService.ExtractedMetadata) async -> MetadataResolutionResult

    public static func importPDF(
        from sourceURL: URL,
        database: AppDatabase,
        resolver: @escaping Resolver = ImportedPDFMetadataResolver.resolve
    ) async throws -> PDFImportOutcome {
        let prepared = try PDFService.prepareImportedPDF(from: sourceURL)

        do {
            let resolution = await resolver(sourceURL, prepared.extracted)
            let persisted = try database.persistMetadataResolution(
                resolution,
                options: MetadataPersistenceOptions(
                    sourceKind: .importedPDF,
                    preferredPDFPath: prepared.pdfPath
                )
            )
            switch persisted {
            case .verified(let reference):
                if let referenceID = reference.id,
                   let attachedPath = try? database.pdfFilename(for: referenceID),
                   attachedPath != prepared.pdfPath {
                    // Duplicate resolution merged into a reference that already
                    // owns a cached PDF, so the fresh copy has no durable owner.
                    PDFService.deletePDF(at: prepared.pdfPath)
                }
                return .imported(reference)
            case .intake(let intake):
                return .queued(intake)
            }
        } catch {
            PDFService.deletePDF(at: prepared.pdfPath)
            throw error
        }
    }
}
