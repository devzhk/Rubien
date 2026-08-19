#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class PickerSelectionControlsTests: XCTestCase {
    func testWrappableColumnsIncludeTagsAndMultiSelectProperties() {
        let properties = [
            PropertyDefinition(id: 11, name: "Modality", type: .multiSelect),
            PropertyDefinition(id: 12, name: "Venue", type: .singleSelect),
        ]
        let visibleIDs: Set<String> = [
            ColumnIdentifier.tags.rawValue,
            properties[0].customizationID,
            properties[1].customizationID,
        ]

        let columns = visibleReferenceTableWrappableColumns(
            propertyDefs: properties,
            isColumnVisible: { visibleIDs.contains($0) }
        )

        XCTAssertEqual(columns.map(\.id), [
            ColumnIdentifier.tags.rawValue,
            properties[0].customizationID,
        ])
    }

    func testOverflowStartsAfterTwoVisibleItems() {
        XCTAssertEqual(pickerSelectionOverflowCount(itemCount: 0), 0)
        XCTAssertEqual(pickerSelectionOverflowCount(itemCount: 2), 0)
        XCTAssertEqual(pickerSelectionOverflowCount(itemCount: 3), 1)
        XCTAssertEqual(pickerSelectionOverflowCount(itemCount: 6), 4)
    }

    func testWrappedSelectionDisplaysEveryItem() {
        let items = (1...4).map {
            PickerSelectionItem(id: String($0), name: "Option \($0)", color: "#8E8E93")
        }

        XCTAssertEqual(pickerSelectionDisplayedItems(items, wraps: false), Array(items.prefix(2)))
        XCTAssertEqual(pickerSelectionDisplayedItems(items, wraps: true), items)
    }

    func testSelectItemsPreserveSelectionOrderAndColors() {
        let options = [
            SelectOption(value: "Alpha", color: "#FF0000"),
            SelectOption(value: "Beta", color: "#00FF00"),
        ]

        XCTAssertEqual(
            pickerSelectionItems(values: ["Beta", "Alpha"], options: options),
            [
                PickerSelectionItem(id: "Beta", name: "Beta", color: "#00FF00"),
                PickerSelectionItem(id: "Alpha", name: "Alpha", color: "#FF0000"),
            ]
        )
    }

    func testUnknownSelectValueGetsNeutralFallbackColor() {
        XCTAssertEqual(
            pickerSelectionItems(values: ["Legacy"], options: []),
            [PickerSelectionItem(id: "Legacy", name: "Legacy", color: "#8E8E93")]
        )
    }
}
#endif
