#if os(macOS)
import Foundation
import XCTest
@testable import Rubien
import RubienCore

final class AddReferenceSourceSheetModelTests: XCTestCase {
    func testSuggestedArxivCardStartsInMetadataFlow() {
        let input = "https://arxiv.org/abs/2606.24597"

        let state = AddReferenceFlowState(initialInput: input)

        XCTAssertEqual(state.step, .metadata(input))
    }

    func testSuggestedOrdinaryWebCardStartsInWebClipFlow() {
        let input = "https://example.com/article"

        let state = AddReferenceFlowState(initialInput: input)

        XCTAssertEqual(state.step, .website(input))
    }

    func testSuggestedPDFCardStartsInPrefilledSourceFlow() {
        let input = "https://arxiv.org/pdf/2501.01234.pdf"

        let state = AddReferenceFlowState(initialInput: input)

        XCTAssertEqual(state.step, .source(input))
    }

    func testMetadataRouteAdvancesWithinUnifiedFlow() {
        let input = "https://arxiv.org/abs/2606.05405"
        var state = AddReferenceFlowState()

        let files = state.advance(using: .metadata(input))

        XCTAssertNil(files)
        XCTAssertEqual(state.step, .metadata(input))
    }

    func testWebsiteRouteAdvancesWithinUnifiedFlow() {
        let input = "https://example.com/article"
        var state = AddReferenceFlowState()

        let files = state.advance(using: .website(input))

        XCTAssertNil(files)
        XCTAssertEqual(state.step, .website(input))
    }

    func testTypingClearsStagedSelection() {
        var state = AddReferenceSourceSheetState(
            stagedURLs: [URL(fileURLWithPath: "/tmp/first.pdf")]
        )

        state.setTypedInput("/tmp/note.md")

        XCTAssertEqual(state.typedInput, "/tmp/note.md")
        XCTAssertTrue(state.stagedURLs.isEmpty)
    }

    func testChoosingFilesClearsTypedInput() {
        var state = AddReferenceSourceSheetState(typedInput: "/tmp/note.md")
        let selections = [
            URL(fileURLWithPath: "/tmp/first.pdf"),
            URL(fileURLWithPath: "/tmp/second.markdown"),
        ]

        state.setStagedURLs(selections)

        XCTAssertEqual(state.stagedURLs, selections)
        XCTAssertTrue(state.typedInput.isEmpty)
    }

    func testEmptySourceDisablesContinue() {
        var state = AddReferenceSourceSheetState()

        XCTAssertFalse(state.hasSource)

        state.setTypedInput("   \n")

        XCTAssertFalse(state.hasSource)
    }

    func testStagedSelectionSummaryUsesFilenameForOneAndCountForMany() {
        var state = AddReferenceSourceSheetState()

        state.setStagedURLs([URL(fileURLWithPath: "/tmp/one.md")])
        XCTAssertEqual(state.stagedSelectionSummary, .filename("one.md"))

        state.setStagedURLs([
            URL(fileURLWithPath: "/tmp/one.md"),
            URL(fileURLWithPath: "/tmp/two.pdf"),
        ])
        XCTAssertEqual(state.stagedSelectionSummary, .count(2))
    }

    func testSubmissionRequiresSourceAndIdleState() {
        var state = AddReferenceSourceSheetState()
        XCTAssertFalse(state.canSubmit)

        state.setTypedInput("/tmp/paper.pdf")
        XCTAssertTrue(state.canSubmit)

        state.setStagedURLs([
            URL(fileURLWithPath: "/tmp/one.pdf"),
            URL(fileURLWithPath: "/tmp/two.md"),
        ])
        XCTAssertTrue(state.canSubmit)
    }

    func testPreviewInvalidInputDisablesSubmission() {
        let state = AddReferenceSourceSheetState(typedInput: "paper.pdf")

        XCTAssertFalse(state.canSubmit(previewRoute: .invalid(.relativeFilePath)))
        XCTAssertTrue(state.canSubmit(previewRoute: .metadata("paper.pdf")))
    }

    func testSubmittedFilesystemErrorDisablesRetryUntilInputChanges() {
        var state = AddReferenceSourceSheetState(typedInput: "/tmp/folder.pdf")
        state.recordSubmittedInvalidReason(.directory)

        XCTAssertEqual(state.submittedInvalidReason, .directory)
        XCTAssertFalse(state.canSubmit(previewRoute: .file("/tmp/folder.pdf")))

        state.setTypedInput("/tmp/paper.pdf")

        XCTAssertNil(state.submittedInvalidReason)
        XCTAssertTrue(state.canSubmit(previewRoute: .file("/tmp/paper.pdf")))
    }

    func testBeginningSubmissionLatchesImmediatelyAndRejectsDuplicateReturnAction() {
        var state = AddReferenceSourceSheetState(
            stagedURLs: [URL(fileURLWithPath: "/tmp/paper.pdf")]
        )

        XCTAssertTrue(state.beginSubmission())
        XCTAssertTrue(state.isAcquiring)
        XCTAssertFalse(state.beginSubmission())

        state.finishSubmission()
        XCTAssertFalse(state.isAcquiring)
        XCTAssertTrue(state.beginSubmission())
    }

    func testEmptyTextCommitPreservesPickerSelectionAndLatchedInputCannotMutate() {
        let selectedURLs = [
            URL(fileURLWithPath: "/tmp/one.pdf"),
            URL(fileURLWithPath: "/tmp/two.md"),
        ]
        var state = AddReferenceSourceSheetState(stagedURLs: selectedURLs)

        // SwiftUI commits the text field's existing empty value before firing
        // the default button action for Return.
        state.setTypedInput("")

        XCTAssertEqual(state.stagedURLs, selectedURLs)
        XCTAssertTrue(state.beginSubmission())

        state.setTypedInput("/tmp/replacement.pdf")
        state.setStagedURLs([URL(fileURLWithPath: "/tmp/replacement.md")])

        XCTAssertEqual(state.stagedURLs, selectedURLs)
        XCTAssertTrue(state.typedInput.isEmpty)
    }
}
#endif
