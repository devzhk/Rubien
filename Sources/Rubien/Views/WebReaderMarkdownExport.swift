#if os(macOS)
import Foundation
import RubienCore

/// Prepares the web reader's clipped content for an explicit user export.
/// HTML clips use the same persisted Markdown projection as CLI/MCP reads;
/// Markdown imports pass through unchanged.
enum WebReaderMarkdownExportWorker {
    enum PreparationError: LocalizedError, Equatable {
        case missingReferenceID
        case missingContent

        var errorDescription: String? {
            switch self {
            case .missingReferenceID:
                return "This reference must be saved before its Markdown can be exported."
            case .missingContent:
                return "This reference does not have clipped content to export."
            }
        }
    }

    static func prepare(
        reference: Reference,
        database: AppDatabase
    ) throws -> Data {
        guard let referenceID = reference.id else {
            throw PreparationError.missingReferenceID
        }
        guard let source = reference.decodedWebContent else {
            throw PreparationError.missingContent
        }

        let markdown = try database.webContentRepresentation(
            referenceId: referenceID,
            source: source,
            format: .markdown
        )
        return Data(markdown.body.utf8)
    }

    static func suggestedFilename(for title: String) -> String {
        let suffix = ".md"
        let maximumUTF8Bytes = 240
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (trimmed.isEmpty ? "Untitled reference" : trimmed) + suffix
        let basename = AssistantAttachmentFiles.sanitizeBasename(displayName)
        let truncated = AssistantAttachmentFiles.truncateUTF8(
            basename,
            to: maximumUTF8Bytes - suffix.utf8.count
        )
        return (truncated.isEmpty ? "Untitled reference" : truncated) + suffix
    }
}
#endif
