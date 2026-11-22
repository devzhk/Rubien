#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

/// The Add by Identifier sheet imports an unsigned publisher item (no authors
/// on the page or in CrossRef) directly, like the browser extension, while
/// batch and retry callers keep its review candidate.
final class ManualEntryAuthorlessImportTests: XCTestCase {
    private let pdfURL = "https://www.nature.com/articles/d41586-026-03638-3.pdf"

    private func highlight() -> Reference {
        Reference(
            title: "Found: a protein that drives ageing without unleashing inflammation",
            authors: [],
            year: 2026,
            journal: "Nature",
            volume: "659",
            issue: "8141",
            pages: "565-565",
            doi: "10.1038/d41586-026-03638-3",
            url: "https://nature.com/articles/d41586-026-03638-3",
            referenceType: .journalArticle,
            metadataSource: .publisherCitationMeta
        )
    }

    private func authorlessOutcome() -> ManualEntryOutcome {
        let pipeline = MetadataResolutionPipeline.noAuthorsOutcome(
            partialReference: highlight(),
            scrapedPDFURL: pdfURL,
            seed: nil,
            fallback: nil
        )
        return ManualEntryOutcome(
            result: pipeline.result,
            preferredPDFURL: pipeline.preferredPDFURL,
            authorlessRecord: pipeline.authorlessRecord
        )
    }

    func testUnsignedPublisherRecordIsImportableAsManuallyVerified() throws {
        let outcome = authorlessOutcome()
        guard case .candidate = outcome.result else {
            return XCTFail("Batch and retry callers still see the review candidate")
        }

        let reference = try XCTUnwrap(outcome.importableReference(reviewedBy: "add-by-identifier"))
        XCTAssertEqual(reference.doi, "10.1038/d41586-026-03638-3")
        XCTAssertEqual(reference.journal, "Nature")
        XCTAssertTrue(reference.authors.isEmpty)
        XCTAssertEqual(reference.verificationStatus, .verifiedManual)
        XCTAssertEqual(reference.reviewedBy, "add-by-identifier")
        XCTAssertNil(outcome.preferredPDFURL)
        XCTAssertEqual(outcome.importablePDFURL, pdfURL)
    }

    func testVerifiedRecordImportsUnchanged() throws {
        var verified = highlight()
        verified.authors = [AuthorName(given: "Alexandra", family: "Witze")]
        verified.verificationStatus = .verifiedAuto
        let evidence = EvidenceBundle(
            source: .publisherCitationMeta,
            recordKey: verified.doi,
            sourceURL: verified.url,
            fetchMode: .identifier,
            fieldEvidence: [],
            verificationHints: VerificationHints(exactIdentifierMatch: true)
        )
        let outcome = ManualEntryOutcome(
            result: .verified(VerifiedEnvelope(reference: verified, evidence: evidence)),
            preferredPDFURL: pdfURL
        )

        let reference = try XCTUnwrap(outcome.importableReference(reviewedBy: "add-by-identifier"))
        XCTAssertEqual(reference.verificationStatus, .verifiedAuto)
        XCTAssertNil(reference.reviewedBy)
        XCTAssertEqual(reference.authors.map(\.family), ["Witze"])
        XCTAssertEqual(outcome.importablePDFURL, pdfURL)
    }

    func testOrdinaryCandidateStillNeedsReview() {
        let outcome = ManualEntryOutcome(
            result: .candidate(CandidateEnvelope(
                seed: nil,
                fallbackReference: nil,
                currentReference: highlight(),
                candidates: [],
                message: "Multiple candidates matched; manual review required."
            )),
            preferredPDFURL: nil
        )

        XCTAssertNil(outcome.importableReference(reviewedBy: "add-by-identifier"))
        XCTAssertNil(outcome.importablePDFURL)
    }
}
#endif
