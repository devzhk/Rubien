#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

@MainActor
final class MetadataImportReviewContextTests: XCTestCase {
    func testCandidateChoiceIsStagedUntilConfirmSelected() async throws {
        let database = try makeDatabase()
        let candidate = makeCandidate(title: "Chosen candidate")
        let entries = [
            PreparedMetadataImport(
                input: "10.1000/verified",
                result: verifiedResult(title: "Already verified")
            ),
            PreparedMetadataImport(
                input: "Ambiguous title",
                result: .candidate(
                    CandidateEnvelope(
                        seed: MetadataResolutionSeed(fileName: "Ambiguous title", title: "Ambiguous title"),
                        fallbackReference: Reference(title: "Ambiguous title"),
                        candidates: [candidate],
                        message: "Choose a match"
                    )
                )
            ),
        ]
        let context = MetadataImportReviewContext(database: database, entries: entries)
        let candidateID = context.items[1].id

        let updated = await context.resolveCandidate(itemID: candidateID, candidate: candidate)

        XCTAssertEqual(updated.readiness, .ready)
        XCTAssertEqual(updated.reference?.title, "Chosen candidate")
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertTrue(try database.fetchPendingMetadataIntakes().isEmpty)

        let report = await context.commit(selectedIDs: [candidateID])

        XCTAssertEqual(report.succeededIDs, [candidateID])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try database.fetchAllReferences().map(\.title), ["Chosen candidate"])
        XCTAssertTrue(try database.fetchPendingMetadataIntakes().isEmpty)
    }

    func testUseProposedMetadataStagesSeedBlockedAndRejectedReferences() throws {
        let database = try makeDatabase()
        let entries = [
            PreparedMetadataImport(
                input: "seed",
                result: .seedOnly(
                    IntakeEnvelope(
                        seed: MetadataResolutionSeed(fileName: "seed", title: "Seed proposal"),
                        fallbackReference: Reference(title: "Seed proposal"),
                        message: "No authoritative match"
                    )
                )
            ),
            PreparedMetadataImport(
                input: "blocked",
                result: .blocked(
                    BlockedEnvelope(
                        seed: nil,
                        fallbackReference: nil,
                        currentReference: Reference(title: "Blocked proposal"),
                        reason: .verificationRequired,
                        message: "Verification required"
                    )
                )
            ),
            PreparedMetadataImport(
                input: "rejected",
                result: .rejected(
                    RejectedEnvelope(
                        seed: nil,
                        fallbackReference: Reference(title: "Rejected proposal"),
                        reason: .verifierRuleNotSatisfied,
                        message: "Verification rule not satisfied"
                    )
                )
            ),
        ]
        let context = MetadataImportReviewContext(database: database, entries: entries)

        XCTAssertEqual(context.items.map(\.readiness), [.needsProposal, .needsProposal, .needsProposal])
        for item in context.items {
            let updated = context.useProposedMetadata(itemID: item.id)
            XCTAssertEqual(updated.readiness, .ready)
            XCTAssertEqual(updated.reference?.verificationStatus, .verifiedManual)
        }
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertTrue(try database.fetchPendingMetadataIntakes().isEmpty)
    }

    func testResultsWithoutCandidateOrProposalRemainDisabledAndRetryable() throws {
        let database = try makeDatabase()
        let entries = [
            PreparedMetadataImport(
                input: "seed",
                result: .seedOnly(
                    IntakeEnvelope(seed: nil, fallbackReference: nil, message: "Nothing found")
                )
            ),
            PreparedMetadataImport(
                input: "blocked",
                result: .blocked(
                    BlockedEnvelope(
                        seed: nil,
                        fallbackReference: nil,
                        reason: .verificationRequired,
                        message: "Verification required"
                    )
                )
            ),
            PreparedMetadataImport(
                input: "rejected",
                result: .rejected(
                    RejectedEnvelope(
                        seed: nil,
                        fallbackReference: nil,
                        reason: .insufficientEvidence,
                        message: "No matching record"
                    )
                )
            ),
        ]
        let context = MetadataImportReviewContext(database: database, entries: entries)

        XCTAssertEqual(context.items.map(\.readiness), [.blocked, .blocked, .failed])
        XCTAssertTrue(context.items.allSatisfy { !$0.isSelectable })
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertTrue(try database.fetchPendingMetadataIntakes().isEmpty)
    }

    func testCommitOfSelectedReadyRowsIsAtomic() async throws {
        let database = try makeDatabase()
        let entries = ["First", "Second", "Third"].map {
            PreparedMetadataImport(input: $0, result: verifiedResult(title: $0))
        }
        let context = MetadataImportReviewContext(database: database, entries: entries)
        let selected = Set([context.items[0].id, context.items[2].id])

        let report = await context.commit(selectedIDs: selected)

        XCTAssertEqual(report.succeededIDs, selected)
        XCTAssertEqual(Set(try database.fetchAllReferences().map(\.title)), ["First", "Third"])
        XCTAssertTrue(try database.fetchPendingMetadataIntakes().isEmpty)
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func verifiedResult(title: String) -> MetadataResolutionResult {
        let reference = Reference(title: title)
        let evidence = EvidenceBundle(
            source: .translationServer,
            fetchMode: .manual,
            fieldEvidence: [FieldEvidence(field: "title", value: title, origin: .manual)]
        )
        return .verified(VerifiedEnvelope(reference: reference, evidence: evidence))
    }

    private func makeCandidate(title: String) -> MetadataCandidate {
        MetadataCandidate(
            source: .translationServer,
            title: title,
            authors: [AuthorName(given: "Ada", family: "Lovelace")],
            year: 1843,
            detailURL: "https://example.com/chosen",
            score: 0.9,
            workKind: .journalArticle
        )
    }
}
#endif
