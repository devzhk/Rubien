#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

@MainActor
final class ReferenceTableCellEqualityTests: XCTestCase {
    func testCustomPropertyDispatcherInvalidatesWhenMutationTargetChanges() {
        let first = makeCell(referenceId: 1, propertyId: 31)
        let reusedForAnotherRow = makeCell(referenceId: 2, propertyId: 31)
        let reusedForAnotherProperty = makeCell(referenceId: 1, propertyId: 32)

        XCTAssertNotEqual(
            first,
            reusedForAnotherRow,
            "A reused table cell must install the new row's update closure"
        )
        XCTAssertNotEqual(
            first,
            reusedForAnotherProperty,
            "A reused table cell must install the new property's update closure"
        )
    }

    func testCustomPropertyDispatcherRemainsEqualForSameTargetAndVisualInputs() {
        XCTAssertEqual(
            makeCell(referenceId: 1, propertyId: 31),
            makeCell(referenceId: 1, propertyId: 31)
        )
    }

    private func makeCell(referenceId: Int64, propertyId: Int64) -> EditableCustomPropertyCell {
        EditableCustomPropertyCell(
            referenceId: referenceId,
            property: PropertyDefinition(
                id: propertyId,
                name: "Topics",
                type: .multiSelect,
                options: [SelectOption(value: "Alpha", color: "#007AFF")]
            ),
            rawValue: nil,
            isEditing: false,
            onBeginEdit: {},
            onCancel: {},
            commitCustom: { _, _, _ in },
            onCreateOption: { _, _ in },
            onDeleteOption: { _, _ in },
            deleteUnlessInUse: { _, _ in nil }
        )
    }
}
#endif
