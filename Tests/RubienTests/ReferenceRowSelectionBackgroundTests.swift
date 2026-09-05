#if os(macOS)
import AppKit
import XCTest
@testable import Rubien

@MainActor
final class ReferenceRowSelectionBackgroundTests: XCTestCase {
    func testBackgroundSitsBelowCellsWithoutChangingSelectionOrInterceptingClicks() {
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 500, height: 48))
        let cell = NSView(frame: row.bounds)
        let anchor = ReferenceRowSelectionBackground.Anchor()
        row.isSelected = true
        row.addSubview(cell)
        cell.addSubview(anchor)

        anchor.attach()

        XCTAssertTrue(row.isSelected)
        XCTAssertEqual(row.selectionHighlightStyle, .none)
        XCTAssertEqual(row.interiorBackgroundStyle, .normal)
        XCTAssertTrue(row.subviews.first === anchor.fill)
        XCTAssertEqual(anchor.fill.frame, row.bounds)
        XCTAssertNil(anchor.fill.hitTest(NSPoint(x: 20, y: 20)))
    }

    func testBackgroundFollowsReusedRowAndResizesWithIt() {
        let first = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let second = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        let anchor = ReferenceRowSelectionBackground.Anchor()
        first.addSubview(anchor)
        anchor.attach()
        anchor.attach()
        XCTAssertEqual(first.subviews.filter { $0 === anchor.fill }.count, 1)

        anchor.removeFromSuperview()
        second.addSubview(anchor)
        anchor.attach()

        XCTAssertFalse(first.subviews.contains { $0 === anchor.fill })
        XCTAssertTrue(anchor.fill.superview === second)
        XCTAssertEqual(anchor.fill.frame, second.bounds)
        second.setFrameSize(NSSize(width: 700, height: 72))
        XCTAssertEqual(anchor.fill.frame, second.bounds)

        ReferenceRowSelectionBackground.dismantleNSView(anchor, coordinator: ())
        XCTAssertNil(anchor.fill.superview)
    }
}
#endif
