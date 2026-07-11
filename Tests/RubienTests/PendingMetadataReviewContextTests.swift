#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

@MainActor
final class PendingMetadataReviewContextTests: XCTestCase {
    func testDirectlyConfirmableRowsStartSelectedAndCandidateChoiceDoesNotPersist() async throws {
        let database = try makeDatabase()
        let ready = try saveIntake(database, title: "Ready")
        let candidate = MetadataCandidate(
            source: .translationServer,
            title: "Chosen candidate",
            authors: [AuthorName(given: "Ada", family: "Lovelace")],
            score: 0.9
        )
        let waiting = try saveIntake(
            database,
            title: "Waiting",
            candidates: [candidate]
        )
        let context = PendingMetadataReviewContext(
            database: database,
            intakes: [ready, waiting],
            candidateResolver: { candidate, _, _ in
                let reference = MetadataVerifier.manuallyVerified(
                    Reference(title: candidate.title),
                    reviewedBy: "candidate-selection"
                )
                return .verified(
                    VerifiedEnvelope(
                        reference: reference,
                        evidence: EvidenceBundle(
                            source: candidate.source,
                            fetchMode: .manual,
                            fieldEvidence: []
                        )
                    )
                )
            }
        )
        let session = ImportReviewSession(title: "Pending", context: context)

        XCTAssertEqual(session.selectedIDs, [context.items[0].id])
        XCTAssertEqual(context.items.map(\.readiness), [.ready, .needsCandidate])

        let updated = await context.resolveCandidate(
            itemID: context.items[1].id,
            candidate: candidate
        )

        XCTAssertEqual(updated.readiness, .ready)
        XCTAssertEqual(updated.reference?.title, "Chosen candidate")
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertEqual(try database.fetchPendingMetadataIntakes().count, 2)
    }

    func testCommitProcessesOnlySelectedRowsInQueueOrderAndRetainsFailures() async throws {
        let database = try makeDatabase()
        let first = try saveIntake(database, title: "First")
        let second = try saveIntake(database, title: "Second")
        let third = try saveIntake(database, title: "Third")
        var attempts: [String] = []
        let context = PendingMetadataReviewContext(
            database: database,
            intakes: [first, second, third],
            committer: { intake, staged, evidence, reviewedBy, database in
                attempts.append(intake.title)
                if intake.title == "Third" {
                    throw TestError.injected
                }
                return try database.confirmMetadataIntake(
                    intake,
                    stagedReference: staged,
                    evidence: evidence,
                    reviewedBy: reviewedBy
                )
            }
        )
        let selected = Set([context.items[0].id, context.items[2].id])

        let report = await context.commit(selectedIDs: selected)

        XCTAssertEqual(attempts, ["First", "Third"])
        XCTAssertEqual(report.succeededIDs, [context.items[0].id])
        XCTAssertEqual(Set(report.failures.keys), [context.items[2].id])
        XCTAssertEqual(try database.fetchAllReferences().map(\.title), ["First"])
        XCTAssertEqual(
            Set(try database.fetchPendingMetadataIntakes().map(\.title)),
            ["Second", "Third"]
        )
    }

    func testDiscardDoesNotDeleteDurableUnselectedRows() throws {
        let database = try makeDatabase()
        let intake = try saveIntake(database, title: "Keep me")
        let context = PendingMetadataReviewContext(database: database, intakes: [intake])

        context.discard(remainingIDs: Set(context.items.map(\.id)))

        XCTAssertEqual(try database.fetchPendingMetadataIntakes().map(\.title), ["Keep me"])
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testUnverifiedCandidateResolutionCannotCreateAnotherIntake() async throws {
        let database = try makeDatabase()
        let candidate = MetadataCandidate(source: .translationServer, title: "Sparse", score: 0.8)
        let intake = try saveIntake(database, title: "Original", candidates: [candidate])
        let context = PendingMetadataReviewContext(
            database: database,
            intakes: [intake],
            candidateResolver: { _, _, _ in
                .blocked(
                    BlockedEnvelope(
                        seed: nil,
                        fallbackReference: nil,
                        reason: .verificationRequired,
                        message: "Candidate still needs metadata"
                    )
                )
            }
        )

        let updated = await context.resolveCandidate(itemID: context.items[0].id, candidate: candidate)

        XCTAssertEqual(updated.readiness, .blocked)
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertEqual(try database.fetchPendingMetadataIntakes().count, 1)
    }

    func testRetryRefreshesTheExistingDurableIntakeWithoutCreatingAnotherRow() async throws {
        let database = try makeDatabase()
        let intake = try saveIntake(database, title: "Original")
        let refreshedCandidate = MetadataCandidate(
            source: .translationServer,
            title: "Refreshed match",
            score: 0.85
        )
        let context = PendingMetadataReviewContext(
            database: database,
            intakes: [intake],
            retryResolver: { _ in
                .candidate(
                    CandidateEnvelope(
                        seed: nil,
                        fallbackReference: Reference(title: "Refreshed proposal"),
                        candidates: [refreshedCandidate],
                        message: "Choose the refreshed match"
                    )
                )
            }
        )

        let updated = await context.retry(itemID: context.items[0].id)

        XCTAssertEqual(updated.readiness, .needsCandidate)
        XCTAssertEqual(updated.candidates.map(\.title), ["Refreshed match"])
        let pending = try database.fetchPendingMetadataIntakes()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].id, intake.id)
        XCTAssertEqual(pending[0].decodedCandidates.map(\.title), ["Refreshed match"])
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func saveIntake(
        _ database: AppDatabase,
        title: String,
        candidates: [MetadataCandidate] = []
    ) throws -> MetadataIntake {
        let reference = Reference(title: title)
        var intake = MetadataIntake(
            sourceKind: .manualEntry,
            verificationStatus: candidates.isEmpty ? .seedOnly : .candidate,
            title: title,
            fallbackReferenceJSON: MetadataVerificationCodec.encodeToJSONString(reference),
            candidatesJSON: MetadataVerificationCodec.encodeToJSONString(candidates)
        )
        try database.saveMetadataIntake(&intake)
        return intake
    }

    private enum TestError: Error {
        case injected
    }
}
#endif
