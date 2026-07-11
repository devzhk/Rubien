#if os(macOS)
import Foundation
import RubienCore

/// Owns all Markdown rows in one review batch so initially prepared and
/// successfully retried references share one atomic fill-only commit.
@MainActor
final class MarkdownImportReviewContext: ImportReviewContext {
    typealias Committer = @Sendable ([Reference], AppDatabase) throws -> Void

    let items: [ImportReviewItem]

    private struct Payload {
        let source: MaterializedImportSource
        var entry: PreparedReferenceImport?
    }

    private let database: AppDatabase
    private let committer: Committer
    private var payloads: [UUID: Payload]

    init(
        database: AppDatabase,
        entries: [PreparedReferenceImport],
        sourcesByEntryID: [UUID: MaterializedImportSource],
        unreadableSources: [MaterializedImportSource],
        committer: @escaping Committer = { references, database in
            _ = try database.batchImportReferences(
                references,
                mergePolicy: .markdownFillOnly
            )
        }
    ) {
        self.database = database
        self.committer = committer

        var payloads: [UUID: Payload] = [:]
        var items: [ImportReviewItem] = []
        for entry in entries {
            guard let source = sourcesByEntryID[entry.id] else {
                preconditionFailure("Prepared Markdown entry is missing its retained source")
            }
            payloads[entry.id] = Payload(source: source, entry: entry)
            items.append(Self.readyItem(id: entry.id, entry: entry))
        }
        for source in unreadableSources {
            let id = UUID()
            payloads[id] = Payload(source: source, entry: nil)
            items.append(Self.failedItem(id: id, source: source))
        }
        self.payloads = payloads
        self.items = items
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        let selected = items.compactMap { item -> (UUID, PreparedReferenceImport)? in
            guard selectedIDs.contains(item.id), let entry = payloads[item.id]?.entry else {
                return nil
            }
            return (item.id, entry)
        }
        guard !selected.isEmpty else {
            return ImportReviewCommitReport(succeededIDs: [], failures: [:])
        }

        let database = database
        let committer = committer
        let references = selected.map { $0.1.reference }
        let result = await Task.detached(priority: .userInitiated) {
            do {
                try committer(references, database)
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
        return Self.readyItem(id: itemID, entry: entry)
    }

    func discard(remainingIDs: Set<UUID>) {
        for id in remainingIDs {
            payloads.removeValue(forKey: id)?.source.cleanup()
        }
    }

    private func item(id: UUID) -> ImportReviewItem {
        items.first(where: { $0.id == id })!
    }

    private static func readyItem(
        id: UUID,
        entry: PreparedReferenceImport
    ) -> ImportReviewItem {
        ImportReviewItem(
            id: id,
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
