#if os(macOS)
import XCTest
@testable import Rubien

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
