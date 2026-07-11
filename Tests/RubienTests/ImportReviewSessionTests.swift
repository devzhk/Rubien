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

    func testSuspendedRetryIsDeduplicatedAndCannotMutateAfterDiscard() async {
        let failed = makeItem(title: "Failed", readiness: .failed)
        let context = SuspendingImportReviewContext(items: [failed])
        let session = ImportReviewSession(title: "Review import", context: context)

        XCTAssertFalse(session.isBusy)
        let firstRetry = Task { await session.retry(itemID: failed.id) }
        while context.retryCalls.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(session.isBusy)

        let duplicateRetry = Task { await session.retry(itemID: failed.id) }
        await Task.yield()

        XCTAssertEqual(context.retryCalls, [failed.id])

        session.discardRemaining()
        let itemsAtDiscard = session.items
        context.resumeRetries(
            with: makeItem(id: failed.id, title: "Late replacement", readiness: .ready)
        )
        await firstRetry.value
        await duplicateRetry.value

        XCTAssertEqual(session.items, itemsAtDiscard)
        XCTAssertFalse(session.isBusy)
    }

    func testDiscardRejectsEveryRowAction() async {
        let candidate = makeItem(
            title: "Candidate",
            readiness: .needsCandidate,
            candidates: [MetadataCandidate(source: .translationServer, title: "Match", score: 0.9)]
        )
        let proposal = makeItem(title: "Proposal", readiness: .needsProposal)
        let failed = makeItem(title: "Failed", readiness: .failed)
        let context = FakeImportReviewContext(items: [candidate, proposal, failed])
        let session = ImportReviewSession(title: "Review import", context: context)

        session.discardRemaining()
        let itemsAtDiscard = session.items
        await session.resolveCandidate(itemID: candidate.id, candidate: candidate.candidates[0])
        session.useProposedMetadata(itemID: proposal.id)
        await session.retry(itemID: failed.id)

        XCTAssertTrue(context.candidateCalls.isEmpty)
        XCTAssertTrue(context.proposalCalls.isEmpty)
        XCTAssertTrue(context.retryCalls.isEmpty)
        XCTAssertEqual(session.items, itemsAtDiscard)
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
private final class SuspendingImportReviewContext: ImportReviewContext {
    let items: [ImportReviewItem]
    private(set) var retryCalls: [UUID] = []
    private var retryContinuations: [CheckedContinuation<ImportReviewItem, Never>] = []

    init(items: [ImportReviewItem]) {
        self.items = items
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        ImportReviewCommitReport(succeededIDs: [], failures: [:])
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        retryCalls.append(itemID)
        return await withCheckedContinuation { continuation in
            retryContinuations.append(continuation)
        }
    }

    func discard(remainingIDs: Set<UUID>) {}

    func resumeRetries(with item: ImportReviewItem) {
        let continuations = retryContinuations
        retryContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: item)
        }
    }
}

@MainActor
private final class FakeImportReviewContext: ImportReviewContext {
    let items: [ImportReviewItem]
    var nextReport = ImportReviewCommitReport(succeededIDs: [], failures: [:])
    var resolvedItem: ImportReviewItem?
    var discardCalls: [Set<UUID>] = []
    private(set) var candidateCalls: [UUID] = []
    private(set) var proposalCalls: [UUID] = []
    private(set) var retryCalls: [UUID] = []

    init(items: [ImportReviewItem]) {
        self.items = items
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        nextReport
    }

    func resolveCandidate(itemID: UUID, candidate: MetadataCandidate) async -> ImportReviewItem {
        candidateCalls.append(itemID)
        return resolvedItem ?? item(id: itemID)
    }

    func useProposedMetadata(itemID: UUID) -> ImportReviewItem {
        proposalCalls.append(itemID)
        return item(id: itemID)
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        retryCalls.append(itemID)
        return item(id: itemID)
    }

    func discard(remainingIDs: Set<UUID>) {
        discardCalls.append(remainingIDs)
    }

    private func item(id: UUID) -> ImportReviewItem {
        items.first { $0.id == id }!
    }
}
#endif
