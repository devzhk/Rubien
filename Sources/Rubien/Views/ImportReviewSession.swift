#if os(macOS)
import Foundation
import SwiftUI
import RubienCore

struct ImportReviewItem: Identifiable, Equatable {
    enum Readiness: Equatable {
        case ready
        case needsCandidate
        case needsProposal
        case blocked
        case failed
    }

    let id: UUID
    var title: String
    var subtitle: String?
    var message: String?
    var reference: Reference?
    var candidates: [MetadataCandidate]
    var readiness: Readiness
    var commitError: String?
    var isWorking: Bool

    var isSelectable: Bool {
        !isWorking && (readiness == .ready || readiness == .needsProposal)
    }

    var isSelectedByDefault: Bool {
        readiness == .ready && !isWorking
    }
}

struct ImportReviewCommitReport: Equatable {
    var succeededIDs: Set<UUID>
    var failures: [UUID: String]
}

@MainActor
protocol ImportReviewContext: AnyObject {
    var items: [ImportReviewItem] { get }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport
    func resolveCandidate(itemID: UUID, candidate: MetadataCandidate) async -> ImportReviewItem
    func useProposedMetadata(itemID: UUID) -> ImportReviewItem
    func retry(itemID: UUID) async -> ImportReviewItem
    func discard(remainingIDs: Set<UUID>)
}

@MainActor
extension ImportReviewContext {
    func resolveCandidate(itemID: UUID, candidate: MetadataCandidate) async -> ImportReviewItem {
        unchangedItem(id: itemID)
    }

    func useProposedMetadata(itemID: UUID) -> ImportReviewItem {
        unchangedItem(id: itemID)
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        unchangedItem(id: itemID)
    }

    private func unchangedItem(id: UUID) -> ImportReviewItem {
        guard let item = items.first(where: { $0.id == id }) else {
            preconditionFailure("Import review context received an unknown item id")
        }
        return item
    }
}

@MainActor
final class ImportReviewSession: ObservableObject, Identifiable {
    let id = UUID()
    let title: String

    @Published private(set) var items: [ImportReviewItem]
    @Published private(set) var selectedIDs: Set<UUID>
    @Published private(set) var isCommitting = false
    @Published private var activeRowIDs: Set<UUID> = []

    var isBusy: Bool {
        isCommitting || !activeRowIDs.isEmpty
    }

    private let context: any ImportReviewContext
    private var didDiscard = false

    init(title: String, context: any ImportReviewContext) {
        self.title = title
        self.context = context
        self.items = context.items
        self.selectedIDs = Set(context.items.filter(\.isSelectedByDefault).map(\.id))
    }

    func setSelected(_ selected: Bool, itemID: UUID) {
        guard items.first(where: { $0.id == itemID })?.isSelectable == true else { return }
        if selected {
            selectedIDs.insert(itemID)
        } else {
            selectedIDs.remove(itemID)
        }
    }

    func selectAllReady() {
        selectedIDs = Set(items.filter(\.isSelectable).map(\.id))
    }

    func selectNone() {
        selectedIDs.removeAll()
    }

    func confirmSelected() async {
        var selection = selectedIDs.intersection(items.filter(\.isSelectable).map(\.id))
        guard !selection.isEmpty, !isBusy, !didDiscard else { return }

        for id in selection where items.first(where: { $0.id == id })?.readiness == .needsProposal {
            replaceItem(context.useProposedMetadata(itemID: id))
        }

        let readyIDs = Set(
            items
                .filter { $0.readiness == .ready && !$0.isWorking }
                .map(\.id)
        )
        let unresolvedIDs = selection.subtracting(readyIDs)
        for id in unresolvedIDs {
            updateItem(id: id) { item in
                item.commitError = String(
                    localized: "importReview.error.proposalAcceptance",
                    bundle: .module
                )
            }
        }
        selection.formIntersection(readyIDs)
        guard !selection.isEmpty else { return }

        isCommitting = true
        for id in selection {
            updateItem(id: id) { item in
                item.isWorking = true
                item.commitError = nil
            }
        }

        let report = await context.commit(selectedIDs: selection)
        items.removeAll { report.succeededIDs.contains($0.id) }
        selectedIDs.subtract(report.succeededIDs)

        for (id, message) in report.failures {
            updateItem(id: id) { item in
                item.isWorking = false
                item.commitError = message
            }
        }
        for id in selection where report.failures[id] == nil {
            updateItem(id: id) { $0.isWorking = false }
        }

        selectedIDs.formIntersection(items.filter(\.isSelectable).map(\.id))
        isCommitting = false
    }

    func resolveCandidate(itemID: UUID, candidate: MetadataCandidate) async {
        guard beginRowAction(itemID: itemID) else { return }
        let updated = await context.resolveCandidate(itemID: itemID, candidate: candidate)
        finishRowAction(itemID: itemID, updated: updated)
    }

    func retry(itemID: UUID) async {
        guard beginRowAction(itemID: itemID) else { return }
        let updated = await context.retry(itemID: itemID)
        finishRowAction(itemID: itemID, updated: updated)
    }

    func discardRemaining() {
        guard !didDiscard else { return }
        didDiscard = true
        context.discard(remainingIDs: Set(items.map(\.id)))
    }

    /// Removes a durable queue row after an explicit Delete action. This is
    /// intentionally separate from discard, which must preserve unselected
    /// pending metadata when the sheet closes.
    func removeItem(itemID: UUID) {
        guard !isBusy, !didDiscard else { return }
        items.removeAll { $0.id == itemID }
        selectedIDs.remove(itemID)
    }

    private func beginRowAction(itemID: UUID) -> Bool {
        guard !isBusy,
              !didDiscard,
              items.contains(where: { $0.id == itemID && !$0.isWorking })
        else { return false }

        activeRowIDs.insert(itemID)
        updateItem(id: itemID) { $0.isWorking = true }
        return true
    }

    private func finishRowAction(itemID: UUID, updated: ImportReviewItem) {
        activeRowIDs.remove(itemID)
        guard !didDiscard else { return }

        var completed = updated
        completed.isWorking = false
        replaceItem(completed)
    }

    private func replaceItem(_ updated: ImportReviewItem) {
        guard let index = items.firstIndex(where: { $0.id == updated.id }) else { return }
        let wasSelected = selectedIDs.contains(updated.id)
        items[index] = updated
        if updated.isSelectable {
            if wasSelected || updated.isSelectedByDefault {
                selectedIDs.insert(updated.id)
            }
        } else {
            selectedIDs.remove(updated.id)
        }
    }

    private func updateItem(id: UUID, mutation: (inout ImportReviewItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&items[index])
    }
}
#endif
