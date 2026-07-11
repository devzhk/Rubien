import Foundation
import RubienCore

private let pdfImportCoordinatorLog = RubienLogger(
    subsystem: "com.rubien.pdf",
    category: "import.coordinator"
)

public enum PDFImportOutcome: Sendable {
    case imported(Reference)
    case queued(MetadataIntake)

    /// Applies the cross-process notifications a command-line front door needs
    /// after persisting an import. Both outcomes refresh library observers,
    /// but only an attached PDF creates a `pdfUploadQueue` row that should wake
    /// the app's sync drainer.
    public func postImportNotifications(
        libraryChanged: () -> Void,
        uploadQueueChanged: () -> Void
    ) {
        libraryChanged()
        if case .imported = self {
            uploadQueueChanged()
        }
    }
}

public struct PreparedPDFImport: Sendable {
    public let sourceURL: URL
    public var resolution: MetadataResolutionResult

    public init(sourceURL: URL, resolution: MetadataResolutionResult) {
        self.sourceURL = sourceURL
        self.resolution = resolution
    }
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
        let prepared = await preparePDF(from: sourceURL, resolver: resolver)
        return try commitPreparedPDF(prepared, database: database)
    }

    public static func preparePDF(
        from sourceURL: URL,
        resolver: @escaping Resolver = ImportedPDFMetadataResolver.resolve
    ) async -> PreparedPDFImport {
        let extracted: PDFService.ExtractedMetadata
#if canImport(Darwin)
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        extracted = PDFService.extractMetadata(from: sourceURL)
        if accessing { sourceURL.stopAccessingSecurityScopedResource() }
#else
        extracted = PDFService.extractMetadata(from: sourceURL)
#endif
        let resolution = await resolver(sourceURL, extracted)
        return PreparedPDFImport(sourceURL: sourceURL, resolution: resolution)
    }

    public static func commitPreparedPDF(
        _ prepared: PreparedPDFImport,
        database: AppDatabase
    ) throws -> PDFImportOutcome {
        let pdfPath = try PDFService.copyImportedPDF(from: prepared.sourceURL)

        do {
            let persisted = try database.persistMetadataResolution(
                prepared.resolution,
                options: MetadataPersistenceOptions(
                    sourceKind: .importedPDF,
                    preferredPDFPath: pdfPath
                )
            )
            switch persisted {
            case .verified(let reference):
                if preparedCopyHasDurableOwner(
                    pdfPath,
                    for: reference,
                    database: database
                ) == false {
                    // Duplicate resolution can merge into either a materialized
                    // cache row or a sync-side placeholder. Both preserve their
                    // existing cache state, so this fresh copy has no durable
                    // owner and must not be left behind.
                    PDFService.deletePDF(at: pdfPath)
                }
                return .imported(reference)
            case .intake(let intake):
                return .queued(intake)
            }
        } catch {
            PDFService.deletePDF(at: pdfPath)
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
