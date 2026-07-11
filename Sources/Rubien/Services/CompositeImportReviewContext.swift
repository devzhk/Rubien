#if os(macOS)
import Foundation
import RubienCore

@MainActor
final class CompositeImportReviewContext: ImportReviewContext {
    let items: [ImportReviewItem]

    private let children: [any ImportReviewContext]
    private var ownedSources: [UUID: MaterializedImportSource]

    init(
        children: [any ImportReviewContext],
        additionalItems: [ImportReviewItem] = [],
        ownedSources: [UUID: MaterializedImportSource] = [:]
    ) {
        self.children = children
        self.items = children.flatMap(\.items) + additionalItems
        self.ownedSources = ownedSources
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        var combined = ImportReviewCommitReport(succeededIDs: [], failures: [:])
        for child in children {
            let childIDs = Set(child.items.map(\.id)).intersection(selectedIDs)
            guard !childIDs.isEmpty else { continue }
            let report = await child.commit(selectedIDs: childIDs)
            combined.succeededIDs.formUnion(report.succeededIDs)
            combined.failures.merge(report.failures) { _, new in new }
            for id in report.succeededIDs {
                ownedSources.removeValue(forKey: id)?.cleanup()
            }
        }
        return combined
    }

    func resolveCandidate(itemID: UUID, candidate: MetadataCandidate) async -> ImportReviewItem {
        guard let child = child(for: itemID) else { return item(id: itemID) }
        return await child.resolveCandidate(itemID: itemID, candidate: candidate)
    }

    func useProposedMetadata(itemID: UUID) -> ImportReviewItem {
        guard let child = child(for: itemID) else { return item(id: itemID) }
        return child.useProposedMetadata(itemID: itemID)
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        guard let child = child(for: itemID) else { return item(id: itemID) }
        return await child.retry(itemID: itemID)
    }

    func discard(remainingIDs: Set<UUID>) {
        for child in children {
            let childIDs = Set(child.items.map(\.id)).intersection(remainingIDs)
            if !childIDs.isEmpty {
                child.discard(remainingIDs: childIDs)
            }
        }
        for id in remainingIDs {
            ownedSources.removeValue(forKey: id)?.cleanup()
        }
    }

    private func child(for itemID: UUID) -> (any ImportReviewContext)? {
        children.first { child in child.items.contains(where: { $0.id == itemID }) }
    }

    private func item(id: UUID) -> ImportReviewItem {
        items.first(where: { $0.id == id })!
    }
}
#endif
