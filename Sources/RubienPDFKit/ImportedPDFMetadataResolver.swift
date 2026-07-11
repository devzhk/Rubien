import Foundation
import RubienCore

/// Adapts PDF-extracted metadata to the shared Core resolution pipeline.
public enum ImportedPDFMetadataResolver {
    public static func resolve(
        url: URL,
        extracted: PDFService.ExtractedMetadata
    ) async -> MetadataResolutionResult {
        let seed = MetadataResolutionSeed.fromImportedPDF(url: url, extracted: extracted)
        let fallback = MetadataResolutionSeed.fallbackReference(from: extracted, url: url)
        return await MetadataResolutionPipeline.resolve(seed: seed, fallback: fallback)
    }
}
