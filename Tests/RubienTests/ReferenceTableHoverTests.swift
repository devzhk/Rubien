#if os(macOS)
import AppKit
import XCTest
@testable import Rubien

@MainActor
final class ReferenceTableHoverTests: XCTestCase {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    func testHoverPublishesUnselectedRowsAndClearsForHeadersAndExit() {
        let rows = Rows()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        table.dataSource = rows
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.reloadData()
        let coordinator = ReferenceTableRowHover.Coordinator()
        coordinator.rowIDs = [nil, 41, 42]
        var changes: [Int64?] = []
        coordinator.onHoverChange = { changes.append($0) }

        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        coordinator.updateHover(to: 1, in: table)
        coordinator.updateHover(to: 1, in: table)
        XCTAssertEqual(changes, [41], "Hover must reveal controls without selecting or repeating updates")
        coordinator.updateHover(to: 2, in: table)
        XCTAssertEqual(changes, [41, 42])
        coordinator.updateHover(to: 0, in: table)
        XCTAssertEqual(changes, [41, 42, nil], "Group headers must clear the previous reference")
        coordinator.updateHover(to: 1, in: table)
        coordinator.clearHover()
        XCTAssertEqual(changes, [41, 42, nil, 41, nil])
    }

    func testSelectedRowsStillPublishHoverAndChangedMappingUsesReferenceIdentity() {
        let rows = Rows()
        let table = NSTableView()
        table.dataSource = rows
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let coordinator = ReferenceTableRowHover.Coordinator()
        coordinator.rowIDs = [nil, 41, 42]
        var changes: [Int64?] = []
        coordinator.onHoverChange = { changes.append($0) }

        coordinator.updateHover(to: 1, in: table)
        XCTAssertEqual(changes, [41])
        coordinator.rowIDs = [nil, 42, 41]
        coordinator.updateHover(to: 1, in: table)
        XCTAssertEqual(changes, [41, 42], "Reordered rows must resolve to the new reference")
        coordinator.updateHover(to: 99, in: table)
        XCTAssertEqual(changes, [41, 42, nil])
    }

    func testClipBoundsChangeRefreshesHoverWithoutMouseEvent() {
        let rows = Rows()
        let table = NSTableView()
        table.dataSource = rows
        table.reloadData()
        let coordinator = ReferenceTableRowHover.Coordinator()
        coordinator.rowIDs = [nil, 41, 42]
        let clipView = NSClipView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        coordinator.observeScrolling(in: clipView)
        var changes: [Int64?] = []
        coordinator.onHoverChange = { changes.append($0) }
        coordinator.updateHover(to: 1, in: table)

        // No mouse event or explicit hover update: changing scroll bounds must
        // re-resolve the pointer. This detached table has no active window, so
        // the previously hovered reference should be cleared.
        clipView.setBoundsOrigin(NSPoint(x: 0, y: 50))
        XCTAssertEqual(changes, [41, nil])

        coordinator.stop()
        coordinator.updateHover(to: 1, in: table)
        clipView.setBoundsOrigin(NSPoint(x: 0, y: 100))
        XCTAssertEqual(changes, [41, nil, 41], "Teardown must remove the scroll observer")
    }
}
#endif
