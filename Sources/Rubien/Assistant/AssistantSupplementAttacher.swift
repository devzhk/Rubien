#if os(macOS)
import Foundation
import RubienCore
import RubienPDFKit

/// Attaches an Assistant document card's file to an existing reference. A
/// main-actor façade: the download and the attachment-store import run in a
/// detached task whose cancellation follows the caller's task. Dependencies are
/// injected so tests stay database- and network-free.
@MainActor
final class AssistantSupplementAttacher {
    struct Outcome: Equatable, Sendable {
        let attachmentSyncId: String
        let parentReferenceId: Int64
        /// The parent's database title at attach time.
        let parentTitle: String
        let wasDuplicate: Bool
    }

    struct ImportedAttachment: Equatable, Sendable {
        let syncId: String
        let wasDuplicate: Bool
    }

    enum AttachError: LocalizedError, Equatable {
        case parentMissing
        case unsafeURL
        case busy

        var errorDescription: String? {
            switch self {
            case .parentMissing: return "The reference no longer exists."
            case .unsafeURL: return "This link cannot be downloaded."
            case .busy: return "Another attachment operation is running. Try again."
            }
        }
    }

    struct Dependencies: Sendable {
        /// The parent's database title, nil when the reference no longer exists.
        var parentTitle: @Sendable (Int64) throws -> String?
        var materialize: @Sendable (String) async throws -> MaterializedImportSource
        var importFile: @Sendable (URL, Int64, String?) throws -> ImportedAttachment
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Re-checks the parent and URL, downloads through `ImportSourceMaterializer`
    /// (content-type and magic-byte checks, GitHub blob normalization), imports
    /// with `displayName`, and always removes the temporary download.
    func attach(url: String, to referenceId: Int64, displayName: String?) async throws -> Outcome {
        let dependencies = dependencies
        let work = Task.detached(priority: .userInitiated) {
            try await Self.perform(
                url: url,
                referenceId: referenceId,
                displayName: displayName,
                dependencies: dependencies)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    nonisolated private static func perform(
        url: String,
        referenceId: Int64,
        displayName: String?,
        dependencies: Dependencies
    ) async throws -> Outcome {
        guard ChatExternalLink.classify(url) != .reject else { throw AttachError.unsafeURL }
        let name = try displayName.map(ReferenceAttachmentStore.validatedDisplayName)
        guard try dependencies.parentTitle(referenceId) != nil else { throw AttachError.parentMissing }
        try Task.checkCancellation()

        let source = try await dependencies.materialize(url)
        defer { source.cleanup() }
        try Task.checkCancellation()

        // Re-check after the download: the parent may have been deleted meanwhile.
        guard let parentTitle = try dependencies.parentTitle(referenceId) else {
            throw AttachError.parentMissing
        }
        let imported: ImportedAttachment
        do {
            imported = try dependencies.importFile(source.fileURL, referenceId, name)
        } catch ReferenceAttachmentError.busy {
            throw AttachError.busy
        } catch ReferenceAttachmentError.missingReference {
            throw AttachError.parentMissing
        }
        return Outcome(
            attachmentSyncId: imported.syncId,
            parentReferenceId: referenceId,
            parentTitle: parentTitle,
            wasDuplicate: imported.wasDuplicate)
    }
}

extension AssistantSupplementAttacher.Dependencies {
    /// Production wiring over the session's library database.
    static func live(
        database: AppDatabase,
        libraryRoot: URL = AppDatabase.libraryRootURL
    ) -> Self {
        let store = ReferenceAttachmentStore.assistantAttachmentStore(
            database: database, libraryRoot: libraryRoot)
        return Self(
            parentTitle: { id in try database.fetchReferences(ids: [id]).first?.title },
            materialize: { url in
                try await ImportSourceMaterializer.materialize(url, localPathPolicy: .requireAbsolute)
            },
            importFile: { file, referenceId, name in
                let result = try store.importFile(at: file, referenceId: referenceId, displayName: name)
                return AssistantSupplementAttacher.ImportedAttachment(
                    syncId: result.attachment.syncId,
                    wasDuplicate: result.wasDuplicate)
            })
    }
}

extension ReferenceAttachmentStore {
    /// The PDF-validating store the Assistant attach path and its Open action share.
    static func assistantAttachmentStore(
        database: AppDatabase,
        libraryRoot: URL = AppDatabase.libraryRootURL
    ) -> ReferenceAttachmentStore {
        ReferenceAttachmentStore(
            database: database,
            libraryRoot: libraryRoot,
            validatePDF: { try ReferenceAttachmentPDFValidator.validate($0) })
    }
}
#endif
