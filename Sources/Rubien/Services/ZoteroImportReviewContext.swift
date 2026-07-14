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
    private let onCompleted: (ZoteroFolderImporter.Result) -> Void

    init(
        database: AppDatabase,
        plan: ZoteroFolderImportPlan,
        committer: @escaping Committer = { plan, selectedIDs, database in
            try ZoteroFolderImporter.commit(
                plan: plan,
                selectedEntryIDs: selectedIDs,
                db: database
            )
        },
        onCompleted: @escaping (ZoteroFolderImporter.Result) -> Void = { _ in }
    ) {
        self.database = database
        self.plan = plan
        self.committer = committer
        self.onCompleted = onCompleted
        self.items = plan.entries.map { entry in
            let attachmentProblems = entry.rejectedAttachmentPaths + entry.missingAttachmentPaths
            var messages: [String] = []
            if !attachmentProblems.isEmpty {
                messages.append(
                    String(
                        format: String(
                            localized: "zoteroImport.attachmentNotFound",
                            bundle: .module
                        ),
                        attachmentProblems.joined(separator: ", ")
                    )
                )
            }
            if !entry.annotations.isEmpty {
                messages.append(
                    "\(entry.annotations.count) PDF annotation\(entry.annotations.count == 1 ? "" : "s")"
                )
            }
            if entry.skippedAnnotationCount > 0 {
                messages.append("\(entry.skippedAnnotationCount) annotation\(entry.skippedAnnotationCount == 1 ? "" : "s") skipped")
            }
            return ImportReviewItem(
                id: entry.id,
                title: entry.reference.title,
                subtitle: plan.sourceName,
                message: messages.isEmpty ? nil : messages.joined(separator: " • "),
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
                return DetachedZoteroCommitResult.success(
                    try committer(plan, validIDs, database)
                )
            } catch {
                return DetachedZoteroCommitResult.failure(error.localizedDescription)
            }
        }.value

        switch result {
        case .success(let completion):
            onCompleted(completion)
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
    case success(ZoteroFolderImporter.Result)
    case failure(String)
}
#endif
