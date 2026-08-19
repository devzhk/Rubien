#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class SelectOptionRenameValidationTests: XCTestCase {
    private let options = [
        SelectOption(value: "Alpha", color: "#007AFF"),
        SelectOption(value: "Beta", color: "#34C759"),
    ]

    func testRenameTrimsTheNewName() {
        XCTAssertEqual(
            validateSelectOptionRename(
                draft: "  Gamma\n",
                originalValue: "Alpha",
                options: options
            ),
            .valid("Gamma")
        )
    }

    func testRenameRejectsBlankName() {
        XCTAssertEqual(
            validateSelectOptionRename(
                draft: " \n ",
                originalValue: "Alpha",
                options: options
            ),
            .invalid("Name can’t be empty.")
        )
    }

    func testRenameRejectsCaseInsensitiveDuplicate() {
        XCTAssertEqual(
            validateSelectOptionRename(
                draft: "beta",
                originalValue: "Alpha",
                options: options
            ),
            .invalid("An option with this name already exists.")
        )
    }

    func testRenameAllowsChangingOnlyTheOriginalOptionsCase() {
        XCTAssertEqual(
            validateSelectOptionRename(
                draft: "alpha",
                originalValue: "Alpha",
                options: options
            ),
            .valid("alpha")
        )
    }

    func testUnchangedRenameIsANoOp() {
        XCTAssertEqual(
            validateSelectOptionRename(
                draft: "Alpha",
                originalValue: "Alpha",
                options: options
            ),
            .unchanged
        )
    }

    func testTagRenameRejectsCaseInsensitiveDuplicateByAnotherTag() {
        let alpha = Tag(id: 1, name: "Alpha")
        let beta = Tag(id: 2, name: "Beta")

        XCTAssertEqual(
            validateTagRename(
                draft: " beta ",
                tag: alpha,
                allTags: [alpha, beta]
            ),
            .invalid("A tag with this name already exists.")
        )
    }

    func testTagRenameAllowsChangingOnlyItsOwnCase() {
        let alpha = Tag(id: 1, name: "Alpha")

        XCTAssertEqual(
            validateTagRename(
                draft: "alpha",
                tag: alpha,
                allTags: [alpha]
            ),
            .valid("alpha")
        )
    }

    func testDetailMirrorMigratesSelectedSingleValue() {
        XCTAssertEqual(
            customSelectValue(
                "Alpha",
                afterRenaming: "Alpha",
                to: "Gamma",
                type: .singleSelect
            ),
            "Gamma"
        )
    }

    func testDetailMirrorMigratesOnlyMatchingMultiValue() {
        let current = PropertyValue.encodeMultiSelect(["Alpha", "Beta"])
        let migrated = customSelectValue(
            current,
            afterRenaming: "Alpha",
            to: "Gamma",
            type: .multiSelect
        )
        XCTAssertEqual(PropertyValue.decodeMultiSelect(migrated), ["Gamma", "Beta"])
    }
}
#endif
