#if os(macOS)
import Foundation
import RubienCore

/// Owns Markdown sources that failed their initial read so the shared review
/// sheet's Retry action can prepare them again without persisting a draft.
@MainActor
final class MarkdownImportRetryContext: ImportReviewContext {
    let items: [ImportReviewItem]

    private struct Payload {
        let source: MaterializedImportSource
        var entry: PreparedReferenceImport?
    }

    private let database: AppDatabase
    private var payloads: [UUID: Payload]

    init(database: AppDatabase, sources: [MaterializedImportSource]) {
        self.database = database
        var payloads: [UUID: Payload] = [:]
        var items: [ImportReviewItem] = []
        for source in sources {
            let id = UUID()
            payloads[id] = Payload(source: source, entry: nil)
            items.append(Self.failedItem(id: id, source: source))
        }
        self.payloads = payloads
        self.items = items
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        let selected = selectedIDs.compactMap { id -> (UUID, PreparedReferenceImport)? in
            guard let entry = payloads[id]?.entry else { return nil }
            return (id, entry)
        }
        guard !selected.isEmpty else {
            return ImportReviewCommitReport(succeededIDs: [], failures: [:])
        }

        let database = database
        let references = selected.map { $0.1.reference }
        let result = await Task.detached(priority: .userInitiated) {
            do {
                _ = try database.batchImportReferences(
                    references,
                    mergePolicy: .markdownFillOnly
                )
                return DetachedMarkdownCommitResult.success
            } catch {
                return DetachedMarkdownCommitResult.failure(error.localizedDescription)
            }
        }.value

        switch result {
        case .success:
            let succeededIDs = Set(selected.map(\.0))
            for id in succeededIDs {
                payloads.removeValue(forKey: id)?.source.cleanup()
            }
            return ImportReviewCommitReport(succeededIDs: succeededIDs, failures: [:])
        case .failure(let message):
            return ImportReviewCommitReport(
                succeededIDs: [],
                failures: Dictionary(uniqueKeysWithValues: selected.map { ($0.0, message) })
            )
        }
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        guard var payload = payloads[itemID] else { return item(id: itemID) }
        let source = payload.source
        let accessing = source.temporaryDirectoryURL == nil
            ? source.fileURL.startAccessingSecurityScopedResource()
            : false
        defer {
            if accessing { source.fileURL.stopAccessingSecurityScopedResource() }
        }

        let preparation = await MarkdownImportWorker.prepareSources([source])
        guard let entry = preparation.entries.first else {
            return Self.failedItem(id: itemID, source: source)
        }
        payload.entry = entry
        payloads[itemID] = payload
        return ImportReviewItem(
            id: itemID,
            title: entry.reference.title,
            subtitle: entry.sourceLabel,
            message: nil,
            reference: entry.reference,
            candidates: [],
            readiness: .ready,
            commitError: nil,
            isWorking: false
        )
    }

    func discard(remainingIDs: Set<UUID>) {
        for id in remainingIDs {
            payloads.removeValue(forKey: id)?.source.cleanup()
        }
    }

    private func item(id: UUID) -> ImportReviewItem {
        items.first(where: { $0.id == id })!
    }

    private static func failedItem(
        id: UUID,
        source: MaterializedImportSource
    ) -> ImportReviewItem {
        ImportReviewItem(
            id: id,
            title: source.fileURL.lastPathComponent,
            subtitle: nil,
            message: String(localized: "Could not read this Markdown file.", bundle: .module),
            reference: nil,
            candidates: [],
            readiness: .failed,
            commitError: nil,
            isWorking: false
        )
    }
}

private enum DetachedMarkdownCommitResult: Sendable {
    case success
    case failure(String)
}
#endif
