#if os(macOS)
import XCTest
import RubienCore
@testable import Rubien

@MainActor
final class ImportReviewSessionTests: XCTestCase {
    func testReadyRowsStartSelectedAndNonReadyRowsDoNot() {
        let ready = makeItem(title: "Ready A", readiness: .ready)
        let candidate = makeItem(
            title: "Choose B",
            readiness: .needsCandidate,
            candidates: [MetadataCandidate(source: .translationServer, title: "B", score: 0.8)]
        )
        let failed = makeItem(title: "Broken C", readiness: .failed, message: "Unreadable")
        let context = FakeImportReviewContext(items: [ready, candidate, failed])

        let session = ImportReviewSession(title: "Review import", context: context)

        XCTAssertEqual(session.selectedIDs, [ready.id])
        session.selectAllReady()
        XCTAssertEqual(session.selectedIDs, [ready.id])
        session.selectNone()
        XCTAssertTrue(session.selectedIDs.isEmpty)
    }

    func testConfirmRemovesSuccessAndRetainsFailures() async {
        let first = makeItem(title: "A", readiness: .ready)
        let second = makeItem(title: "B", readiness: .ready)
        let third = makeItem(title: "C", readiness: .ready)
        let context = FakeImportReviewContext(items: [first, second, third])
        context.nextReport = ImportReviewCommitReport(
            succeededIDs: [first.id],
            failures: [second.id: "Batch failed", third.id: "Batch failed"]
        )
        let session = ImportReviewSession(title: "Review import", context: context)

        await session.confirmSelected()

        XCTAssertEqual(session.items.map(\.id), [second.id, third.id])
        XCTAssertEqual(Set(session.items.compactMap(\.commitError)), ["Batch failed"])
        XCTAssertEqual(session.selectedIDs, [second.id, third.id])
    }

    func testDiscardIsIdempotentAndIncludesEveryRemainingRow() {
        let first = makeItem(title: "A", readiness: .ready)
        let second = makeItem(title: "B", readiness: .ready)
        let context = FakeImportReviewContext(items: [first, second])
        let session = ImportReviewSession(title: "Review import", context: context)

        session.discardRemaining()
        session.discardRemaining()

        XCTAssertEqual(context.discardCalls, [[first.id, second.id]])
    }

    func testResolvedCandidateBecomesSelectedWhenReady() async {
        let candidate = makeItem(
            title: "Choose",
            readiness: .needsCandidate,
            candidates: [MetadataCandidate(source: .translationServer, title: "Chosen", score: 0.9)]
        )
        let context = FakeImportReviewContext(items: [candidate])
        context.resolvedItem = makeItem(id: candidate.id, title: "Chosen", readiness: .ready)
        let session = ImportReviewSession(title: "Review import", context: context)

        await session.resolveCandidate(itemID: candidate.id, candidate: candidate.candidates[0])

        XCTAssertEqual(session.items.first?.title, "Chosen")
        XCTAssertEqual(session.selectedIDs, [candidate.id])
    }

    private func makeItem(
        id: UUID = UUID(),
        title: String,
        readiness: ImportReviewItem.Readiness,
        candidates: [MetadataCandidate] = [],
        message: String? = nil
    ) -> ImportReviewItem {
        ImportReviewItem(
            id: id,
            title: title,
            subtitle: nil,
            message: message,
            reference: nil,
            candidates: candidates,
            readiness: readiness,
            commitError: nil,
            isWorking: false
        )
    }
}

@MainActor
private final class FakeImportReviewContext: ImportReviewContext {
    let items: [ImportReviewItem]
    var nextReport = ImportReviewCommitReport(succeededIDs: [], failures: [:])
    var resolvedItem: ImportReviewItem?
    var discardCalls: [Set<UUID>] = []

    init(items: [ImportReviewItem]) {
        self.items = items
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        nextReport
    }

    func resolveCandidate(itemID: UUID, candidate: MetadataCandidate) async -> ImportReviewItem {
        resolvedItem ?? item(id: itemID)
    }

    func useProposedMetadata(itemID: UUID) -> ImportReviewItem {
        item(id: itemID)
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        item(id: itemID)
    }

    func discard(remainingIDs: Set<UUID>) {
        discardCalls.append(remainingIDs)
    }

    private func item(id: UUID) -> ImportReviewItem {
        items.first { $0.id == id }!
    }
}
#endif
