#if os(macOS)
import AppKit
import XCTest
@testable import Rubien

@MainActor
final class ReferenceTableSelectionScrollerTests: XCTestCase {
    private final class Rows: NSObject, NSTableViewDataSource {
        var count: Int
        init(_ count: Int) { self.count = count }
        func numberOfRows(in tableView: NSTableView) -> Int { count }
    }

    private struct Fixture {
        let rows: Rows
        let container: NSView
        let scrollView: NSScrollView
        let table: NSTableView
        let anchor: NSView
        let coordinator: ReferenceTableSelectionScroller.Coordinator

        var clipY: CGFloat { scrollView.contentView.bounds.origin.y }

        func isVisible(row: Int) -> Bool {
            let clip = scrollView.contentView
            return ReferenceTableSelectionScroller.Coordinator.isRow(
                table.rect(ofRow: row),
                fullyVisibleIn: clip.bounds,
                contentInsets: clip.contentInsets
            )
        }
    }

    /// Mirrors the live layout: the scroller's anchor view is a sibling of
    /// the table's scroll view, and the table holds no AppKit selection.
    private func makeFixture(rowCount: Int, rowIDs: [Int64?], selectedId: Int64) -> Fixture {
        let rows = Rows(rowCount)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowHeight = 20
        table.dataSource = rows
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scrollView.documentView = table
        let container = NSView(frame: scrollView.frame)
        container.addSubview(scrollView)
        let anchor = NSView(frame: .zero)
        container.addSubview(anchor)
        table.reloadData()
        table.tile()

        let coordinator = ReferenceTableSelectionScroller.Coordinator()
        coordinator.rowIDs = rowIDs
        coordinator.selectedId = selectedId
        coordinator.scrollRequest = 1
        return Fixture(
            rows: rows,
            container: container,
            scrollView: scrollView,
            table: table,
            anchor: anchor,
            coordinator: coordinator
        )
    }

    private func ids(_ range: ClosedRange<Int64>) -> [Int64?] {
        range.map { Optional($0) }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRevealsOffscreenSelectionWithoutAppKitSelection() {
        // Like a search reveal: SwiftUI's binding holds the reference, but
        // AppKit's selection stays empty for the off-screen row.
        let f = makeFixture(rowCount: 100, rowIDs: ids(1...100), selectedId: 80)
        XCTAssertTrue(f.table.selectedRowIndexes.isEmpty)
        XCTAssertFalse(f.isVisible(row: 79))

        f.coordinator.scheduleScroll(from: f.anchor)
        spin(0.1)

        XCTAssertTrue(f.isVisible(row: 79), "Search reveal must scroll to the selected row")
    }

    func testRetriesUntilTableAppliesSnapshotRows() {
        // The snapshot has one more row than AppKit has applied.
        let f = makeFixture(rowCount: 100, rowIDs: ids(1...101), selectedId: 80)

        f.coordinator.scheduleScroll(from: f.anchor)
        spin(0.12)
        XCTAssertEqual(f.clipY, 0, "Must not scroll by a row index the table has not applied")

        // AppKit catches up; a pending retry, not a new request, reveals it.
        f.rows.count = 101
        f.table.reloadData()
        spin(0.15)
        XCTAssertTrue(f.isVisible(row: 79))
    }

    func testAppKitSelectionMustContainTheRowWhenPresent() {
        let f = makeFixture(rowCount: 100, rowIDs: ids(1...100), selectedId: 80)
        // A stale AppKit selection means AppKit has not applied the reorder
        // that put reference 80 at row 79 yet.
        f.table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        f.coordinator.scheduleScroll(from: f.anchor)
        spin(0.45)
        XCTAssertEqual(f.clipY, 0)

        f.table.selectRowIndexes(IndexSet(integer: 79), byExtendingSelection: false)
        f.coordinator.scrollRequest = 2
        f.coordinator.scheduleScroll(from: f.anchor)
        spin(0.1)
        XCTAssertTrue(f.isVisible(row: 79))
    }

    func testKeepsRowRevealedWhenTableLayoutChangesAfterReveal() {
        let f = makeFixture(rowCount: 100, rowIDs: ids(1...100), selectedId: 80)
        f.coordinator.scheduleScroll(from: f.anchor)
        spin(0.1)
        XCTAssertTrue(f.isVisible(row: 79))

        // Measured heights replacing estimates resize the table and move the
        // row away from the clip view's unchanged origin.
        f.table.rowHeight = 40
        f.table.tile()
        spin(0.1)

        XCTAssertTrue(f.isVisible(row: 79), "Layout changes during settling must not lose the row")
    }

    func testUserScrollStopsFollowingLayout() {
        let f = makeFixture(rowCount: 100, rowIDs: ids(1...100), selectedId: 80)
        f.coordinator.scheduleScroll(from: f.anchor)
        spin(0.1)
        let revealedY = f.clipY

        // Legacy mouse wheels post only this, not willStartLiveScroll.
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: f.scrollView
        )
        f.table.rowHeight = 40
        f.table.tile()
        spin(0.1)

        XCTAssertEqual(f.clipY, revealedY, "A user scroll must end automatic corrections")
        XCTAssertFalse(f.isVisible(row: 79))
    }

    func testAlreadyVisibleSelectionDoesNotFollowLayout() {
        // Like a click: the row is in view, so nothing should hold the table
        // there while the user scrolls away.
        let f = makeFixture(rowCount: 100, rowIDs: ids(1...100), selectedId: 3)
        f.coordinator.scheduleScroll(from: f.anchor)
        spin(0.1)
        XCTAssertTrue(f.isVisible(row: 2))

        let clip = f.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 1000))
        f.scrollView.reflectScrolledClipView(clip)
        f.table.rowHeight = 40
        f.table.tile()
        spin(0.1)

        XCTAssertFalse(f.isVisible(row: 2), "A click must not arm layout following")
    }

    func testRowVisibilityIgnoresHorizontalOverflowAndRespectsInsets() {
        let clip = NSRect(x: 0, y: 100, width: 300, height: 200)
        let insets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        let wideRow = NSRect(x: 0, y: 150, width: 2000, height: 20)
        XCTAssertTrue(
            ReferenceTableSelectionScroller.Coordinator.isRow(wideRow, fullyVisibleIn: clip, contentInsets: insets)
        )
        let underHeader = NSRect(x: 0, y: 110, width: 300, height: 20)
        XCTAssertFalse(
            ReferenceTableSelectionScroller.Coordinator.isRow(underHeader, fullyVisibleIn: clip, contentInsets: insets)
        )
        XCTAssertFalse(
            ReferenceTableSelectionScroller.Coordinator.isRow(.zero, fullyVisibleIn: clip, contentInsets: insets)
        )
    }
}
#endif
