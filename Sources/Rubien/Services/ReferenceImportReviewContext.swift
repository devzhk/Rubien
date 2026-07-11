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
    let items: [ImportReviewItem]

    private let database: AppDatabase
    private let entries: [PreparedReferenceImport]
    private let mergePolicy: ImportMergePolicy

    init(
        database: AppDatabase,
        entries: [PreparedReferenceImport],
        mergePolicy: ImportMergePolicy
    ) {
        self.database = database
        self.entries = entries
        self.mergePolicy = mergePolicy
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
        do {
            _ = try database.batchImportReferences(
                selected.map(\.reference),
                mergePolicy: mergePolicy
            )
            return ImportReviewCommitReport(succeededIDs: selectedIDs, failures: [:])
        } catch {
            let message = error.localizedDescription
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
#endif
