#if os(macOS)
import Foundation
import RubienCore
import RubienPDFKit

enum ZoteroImportReviewPresentation {
    static func shouldReview(entryCount: Int) -> Bool {
        entryCount > 1
    }
}

@MainActor
final class ZoteroImportReviewContext: ImportReviewContext {
    typealias Committer = @Sendable (
        ZoteroFolderImportPlan,
        Set<UUID>,
        AppDatabase
    ) throws -> ZoteroFolderImporter.Result

    let items: [ImportReviewItem]

    private let database: AppDatabase
    private let plan: ZoteroFolderImportPlan
    private let committer: Committer

    init(
        database: AppDatabase,
        plan: ZoteroFolderImportPlan,
        committer: @escaping Committer = { plan, selectedIDs, database in
            try ZoteroFolderImporter.commit(
                plan: plan,
                selectedEntryIDs: selectedIDs,
                db: database
            )
        }
    ) {
        self.database = database
        self.plan = plan
        self.committer = committer
        self.items = plan.entries.map { entry in
            let attachmentProblems = entry.rejectedAttachmentPaths + entry.missingAttachmentPaths
            let attachmentMessage = String(
                format: String(
                    localized: "zoteroImport.attachmentNotFound",
                    bundle: .module
                ),
                attachmentProblems.joined(separator: ", ")
            )
            return ImportReviewItem(
                id: entry.id,
                title: entry.reference.title,
                subtitle: plan.folderURL.lastPathComponent,
                message: attachmentProblems.isEmpty
                    ? nil
                    : attachmentMessage,
                reference: entry.reference,
                candidates: [],
                readiness: .ready,
                commitError: nil,
                isWorking: false
            )
        }
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        let validIDs = selectedIDs.intersection(plan.entries.map(\.id))
        guard !validIDs.isEmpty else {
            return ImportReviewCommitReport(succeededIDs: [], failures: [:])
        }

        let database = database
        let plan = plan
        let committer = committer
        let result = await Task.detached(priority: .userInitiated) {
            do {
                _ = try committer(plan, validIDs, database)
                return DetachedZoteroCommitResult.success
            } catch {
                return DetachedZoteroCommitResult.failure(error.localizedDescription)
            }
        }.value

        switch result {
        case .success:
            return ImportReviewCommitReport(succeededIDs: validIDs, failures: [:])
        case .failure(let message):
            return ImportReviewCommitReport(
                succeededIDs: [],
                failures: Dictionary(uniqueKeysWithValues: validIDs.map { ($0, message) })
            )
        }
    }

    func discard(remainingIDs: Set<UUID>) {
        // The Zotero export folder is user-owned; review never deletes it.
    }
}

private enum DetachedZoteroCommitResult: Sendable {
    case success
    case failure(String)
}
#endif
