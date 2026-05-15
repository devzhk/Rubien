#if canImport(Rubien)
import XCTest
@testable import Rubien
@testable import RubienCore

final class MetadataResolverTests: XCTestCase {
    func testManualCandidateSelectionPromotesRejectedResultToVerifiedManual() {
        let evidence = EvidenceBundle(
            source: .translationServer,
            recordKey: "doi:10.48550/arXiv.1706.03762",
            sourceURL: "https://arxiv.org/abs/1706.03762",
            fetchMode: .detail,
            fieldEvidence: [
                FieldEvidence(field: "title", value: "Attention Is All You Need", origin: .structuredDetail),
                FieldEvidence(field: "authors", value: "Ashish Vaswani", origin: .structuredDetail)
            ],
            verificationHints: VerificationHints(
                hasStructuredTitle: true,
                hasStructuredAuthors: true,
                hasStableRecordKey: true,
                usedStructuredDetail: true
            )
        )
        let reference = Reference(
            title: "Attention Is All You Need",
            authors: [AuthorName(given: "Ashish", family: "Vaswani")],
            year: 2017,
            journal: "NeurIPS",
            referenceType: .journalArticle
        )
        let rejected = MetadataResolutionResult.rejected(
            RejectedEnvelope(
                seed: MetadataResolutionSeed(
                    fileName: "seed.pdf",
                    title: "Attention Is All You Need",
                    firstAuthor: "Vaswani",
                    year: 2017,
                    journal: "NeurIPS",
                    workKindHint: .journalArticle
                ),
                fallbackReference: nil,
                currentReference: reference,
                reason: .verifierRuleNotSatisfied,
                message: "Auto-verification rule not satisfied.",
                evidence: evidence
            )
        )

        let promoted = MetadataResolver.promoteManualCandidateSelectionResult(
            rejected,
            reviewedBy: "candidate-selection"
        )

        guard case .verified(let envelope) = promoted else {
            return XCTFail("Manual candidate selection should promote to verifiedManual")
        }
        XCTAssertEqual(envelope.reference.verificationStatus, .verifiedManual)
        XCTAssertEqual(envelope.reference.reviewedBy, "candidate-selection")
        XCTAssertEqual(envelope.reference.metadataSource, .translationServer)
        XCTAssertEqual(envelope.reference.recordKey, "doi:10.48550/arXiv.1706.03762")
        XCTAssertEqual(envelope.reference.verificationSourceURL, "https://arxiv.org/abs/1706.03762")
        XCTAssertEqual(envelope.reference.evidenceBundleHash, evidence.bundleHash)
    }

    func testManualCandidateSelectionDoesNotOverrideBlockedResult() {
        let blocked = MetadataResolutionResult.blocked(
            BlockedEnvelope(
                seed: nil,
                fallbackReference: Reference(title: "Blocked entry"),
                currentReference: nil,
                reason: .verificationRequired,
                message: "Verification required."
            )
        )

        let promoted = MetadataResolver.promoteManualCandidateSelectionResult(
            blocked,
            reviewedBy: "candidate-selection"
        )

        guard case .blocked(let envelope) = promoted else {
            return XCTFail("blocked result should not be promoted by manual candidate selection")
        }
        XCTAssertEqual(envelope.reason, .verificationRequired)
    }
}
#endif
