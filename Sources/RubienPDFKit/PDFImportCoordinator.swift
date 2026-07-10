import Foundation
import RubienCore

private let pdfImportCoordinatorLog = RubienLogger(
    subsystem: "com.rubien.pdf",
    category: "import.coordinator"
)

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
                if preparedCopyHasDurableOwner(
                    prepared.pdfPath,
                    for: reference,
                    database: database
                ) == false {
                    // Duplicate resolution can merge into either a materialized
                    // cache row or a sync-side placeholder. Both preserve their
                    // existing cache state, so this fresh copy has no durable
                    // owner and must not be left behind.
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

    /// Returns nil when cache ownership cannot be read after successful
    /// persistence. In that ambiguous case we preserve the fresh file: the
    /// reference and its cache state are already committed, and deleting the
    /// file would risk losing the only materialized copy.
    private static func preparedCopyHasDurableOwner(
        _ preparedPath: String,
        for reference: Reference,
        database: AppDatabase
    ) -> Bool? {
        guard let referenceID = reference.id else { return false }
        do {
            guard let cacheStatus = try database.pdfCacheStatus(for: referenceID) else {
                return false
            }
            return cacheStatus.localFilename == preparedPath
                && cacheStatus.materializedAt != nil
        } catch {
            pdfImportCoordinatorLog.error(
                "Unable to verify imported PDF ownership after persistence: \(error.localizedDescription)"
            )
            return nil
        }
    }
}
