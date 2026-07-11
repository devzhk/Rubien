#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class PendingMetadataIntakePresentationTests: XCTestCase {
    func testSingleQueuedIntakeOpensReviewImmediately() {
        XCTAssertEqual(
            PendingMetadataReviewScope.forQueuedIntakeIDs([7]),
            .queuedImport([7])
        )
    }

    func testMultipleQueuedIntakesOpenOneScopedReview() {
        XCTAssertEqual(
            PendingMetadataReviewScope.forQueuedIntakeIDs([7, 11, 7]),
            .queuedImport([7, 11])
        )
    }

    func testNoQueuedIntakesDoesNotOpenReview() {
        XCTAssertNil(PendingMetadataReviewScope.forQueuedIntakeIDs([]))
    }

    func testScopedIntakesAppearBeforePendingObserverCatchesUp() {
        let scoped = [
            MetadataIntake(
                id: 7,
                sourceKind: .importedPDF,
                verificationStatus: .candidate,
                title: "Just queued"
            ),
        ]

        XCTAssertTrue(
            PendingMetadataIntakePresentation.intakesForReview(
                observedPending: [],
                scopedPending: nil
            ).isEmpty
        )

        XCTAssertEqual(
            PendingMetadataIntakePresentation.intakesForReview(
                observedPending: [],
                scopedPending: scoped
            ).map(\.id),
            [7]
        )
    }

    func testFullQueueStillUsesObservedPendingIntakes() {
        let observed = [
            MetadataIntake(
                id: 3,
                sourceKind: .manualEntry,
                verificationStatus: .seedOnly,
                title: "Existing"
            ),
        ]

        XCTAssertEqual(
            PendingMetadataIntakePresentation.intakesForReview(
                observedPending: observed,
                scopedPending: nil
            ).map(\.id),
            [3]
        )
    }

    func testMultipleRequestedFilesOpenReviewEvenWhenOnlyOnePrepares() {
        XCTAssertTrue(
            FileImportReviewPresentation.shouldReview(
                requestedSourceCount: 2,
                preparedItemCount: 1
            )
        )
    }

    func testTrueSingleFileImportStaysImmediate() {
        XCTAssertFalse(
            FileImportReviewPresentation.shouldReview(
                requestedSourceCount: 1,
                preparedItemCount: 1
            )
        )
    }
}
#endif
