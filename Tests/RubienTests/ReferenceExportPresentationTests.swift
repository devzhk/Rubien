#if os(macOS)
import XCTest
import RubienCore
@testable import Rubien

final class ReferenceExportPresentationTests: XCTestCase {
    func testGroupedDisplayOrderIsFlattenedAndStableDeduplicated() {
        let first = Reference(id: 1, title: "First")
        let second = Reference(id: 2, title: "Second")
        let third = Reference(id: 3, title: "Third")
        let buckets = [
            GroupBucket(key: "b", label: "B", references: [second, first]),
            GroupBucket(key: "a", label: "A", references: [third, second]),
        ]

        XCTAssertEqual(
            orderedReferenceExportIDs(
                processed: [first, second, third],
                buckets: buckets
            ),
            [2, 1, 3]
        )
        XCTAssertEqual(
            orderedReferenceExportIDs(
                processed: [first, second, third],
                buckets: nil
            ),
            [1, 2, 3]
        )
    }

    func testFilenameSanitizationIsSafeBoundedAndHasFallback() {
        XCTAssertEqual(
            ReferenceExportFilename.sanitize("  My / Research: View  "),
            "My-Research-View"
        )
        XCTAssertEqual(ReferenceExportFilename.sanitize("/ : \u{0}"), "current-view")
        XCTAssertEqual(
            ReferenceExportFilename.sanitize("（ Draft: Results! ）"),
            "Draft-Results"
        )
        XCTAssertLessThanOrEqual(
            ReferenceExportFilename.sanitize(String(repeating: "a", count: 120)).count,
            80
        )
    }

    func testConfigurationContextCapturesScopeAndSuggestedName() {
        let context = ReferenceExportConfigurationContext(
            selectedIDs: [3, 1],
            currentViewIDs: [3, 1, 2],
            viewName: "Needs / Review",
            hasEntireLibraryRows: true
        )
        let selected = context.intent(scope: .selected, format: .bibtex)
        let current = context.intent(scope: .currentView, format: .ris)
        let all = context.intent(scope: .entireLibrary, format: .json)

        XCTAssertEqual(selected?.request.scope, .ids([3, 1]))
        XCTAssertEqual(selected?.suggestedBasename, "rubien-selected-2")
        XCTAssertEqual(current?.request.scope, .ids([3, 1, 2]))
        XCTAssertEqual(current?.suggestedBasename, "rubien-Needs-Review")
        XCTAssertEqual(all?.request.scope, .all)
        XCTAssertEqual(all?.suggestedBasename, "rubien-library")

        let empty = ReferenceExportConfigurationContext(
            selectedIDs: [],
            currentViewIDs: [],
            viewName: nil,
            hasEntireLibraryRows: false
        )
        XCTAssertNil(empty.intent(scope: .entireLibrary, format: .json))
    }
}
#endif
