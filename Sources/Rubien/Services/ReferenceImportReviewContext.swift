#if os(macOS)
import Foundation
import RubienCore

struct PreparedReferenceImport: Identifiable, Sendable {
    let id: UUID
    let reference: Reference
    let sourceLabel: String

    init(id: UUID = UUID(), reference: Reference, sourceLabel: String) {
        self.id = id
        self.reference = reference
        self.sourceLabel = sourceLabel
    }
}

@MainActor
final class ReferenceImportReviewContext: ImportReviewContext {
    typealias Committer = @Sendable ([Reference], ImportMergePolicy, AppDatabase) throws -> Void

    let items: [ImportReviewItem]

    private let database: AppDatabase
    private let entries: [PreparedReferenceImport]
    private let mergePolicy: ImportMergePolicy
    private let committer: Committer

    init(
        database: AppDatabase,
        entries: [PreparedReferenceImport],
        mergePolicy: ImportMergePolicy,
        committer: @escaping Committer = { references, mergePolicy, database in
            _ = try database.batchImportReferences(references, mergePolicy: mergePolicy)
        }
    ) {
        self.database = database
        self.entries = entries
        self.mergePolicy = mergePolicy
        self.committer = committer
        self.items = entries.map { entry in
            ImportReviewItem(
                id: entry.id,
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
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        let selected = entries.filter { selectedIDs.contains($0.id) }
        let references = selected.map(\.reference)
        let mergePolicy = mergePolicy
        let database = database
        let committer = committer
        let result = await Task.detached(priority: .userInitiated) {
            do {
                try committer(references, mergePolicy, database)
                return DetachedReferenceCommitResult.success
            } catch {
                return DetachedReferenceCommitResult.failure(error.localizedDescription)
            }
        }.value

        switch result {
        case .success:
            return ImportReviewCommitReport(succeededIDs: selectedIDs, failures: [:])
        case .failure(let message):
            return ImportReviewCommitReport(
                succeededIDs: [],
                failures: Dictionary(
                    uniqueKeysWithValues: selectedIDs.map { ($0, message) }
                )
            )
        }
    }

    func discard(remainingIDs: Set<UUID>) {}
}

private enum DetachedReferenceCommitResult: Sendable {
    case success
    case failure(String)
}
#endif
