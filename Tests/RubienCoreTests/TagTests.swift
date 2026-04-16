import XCTest
@testable import RubienCore

final class TagModelTests: XCTestCase {

    // MARK: - Initialization

    func testInitWithNameAndColor() {
        let tag = Tag(name: "Important", color: "#FF0000")
        XCTAssertEqual(tag.name, "Important")
        XCTAssertEqual(tag.color, "#FF0000")
        XCTAssertNil(tag.id)
    }

    func testDefaultColor() {
        let tag = Tag(name: "Default Color")
        XCTAssertEqual(tag.color, "#007AFF")
    }

    func testNameCanBeUpdated() {
        var tag = Tag(name: "Original")
        tag.name = "Updated"
        XCTAssertEqual(tag.name, "Updated")
    }

    func testColorCanBeUpdated() {
        var tag = Tag(name: "Color Test", color: "#007AFF")
        tag.color = "#FF5733"
        XCTAssertEqual(tag.color, "#FF5733")
    }

    func testColorFormatIsHex() {
        let tag = Tag(name: "Hex Test", color: "#007AFF")
        XCTAssertTrue(tag.color.hasPrefix("#"),
                      "Color should be in hex format starting with #")
    }
}

final class ReferenceTagModelTests: XCTestCase {

    func testInit() {
        let rt = ReferenceTag(referenceId: 1, tagId: 2)
        XCTAssertEqual(rt.referenceId, 1)
        XCTAssertEqual(rt.tagId, 2)
    }
}
