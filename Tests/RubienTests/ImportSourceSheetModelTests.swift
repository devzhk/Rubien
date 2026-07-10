#if os(macOS)
import Foundation
import XCTest
@testable import Rubien

final class ImportSourceSheetModelTests: XCTestCase {
    func testTypingClearsStagedSelection() {
        var state = ImportSourceSheetState(
            stagedURLs: [URL(fileURLWithPath: "/tmp/first.pdf")]
        )

        state.setTypedInput("/tmp/note.md")

        XCTAssertEqual(state.typedInput, "/tmp/note.md")
        XCTAssertTrue(state.stagedURLs.isEmpty)
    }

    func testChoosingFilesClearsTypedInput() {
        var state = ImportSourceSheetState(typedInput: "/tmp/note.md")
        let selections = [
            URL(fileURLWithPath: "/tmp/first.pdf"),
            URL(fileURLWithPath: "/tmp/second.markdown"),
        ]

        state.setStagedURLs(selections)

        XCTAssertEqual(state.stagedURLs, selections)
        XCTAssertTrue(state.typedInput.isEmpty)
    }

    func testEmptySourceDisablesImport() {
        var state = ImportSourceSheetState()

        XCTAssertFalse(state.canImport)

        state.setTypedInput("   \n")

        XCTAssertFalse(state.canImport)
    }

    func testStagedSelectionSummaryUsesFilenameForOneAndCountForMany() {
        var state = ImportSourceSheetState()

        state.setStagedURLs([URL(fileURLWithPath: "/tmp/one.md")])
        XCTAssertEqual(state.stagedSelectionSummary, .filename("one.md"))

        state.setStagedURLs([
            URL(fileURLWithPath: "/tmp/one.md"),
            URL(fileURLWithPath: "/tmp/two.pdf"),
        ])
        XCTAssertEqual(state.stagedSelectionSummary, .count(2))
    }
}
#endif
