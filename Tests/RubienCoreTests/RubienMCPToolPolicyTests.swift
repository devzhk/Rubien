import XCTest
@testable import RubienCore

final class RubienMCPToolPolicyTests: XCTestCase {
    func testCanonicalCatalogPartitionsTwentySevenTools() {
        XCTAssertEqual(RubienMCPToolPolicy.readToolNames.count, 14)
        XCTAssertEqual(RubienMCPToolPolicy.writeToolNames.count, 13)
        XCTAssertEqual(RubienMCPToolPolicy.allToolNames.count, 27)
        XCTAssertTrue(
            RubienMCPToolPolicy.readToolNames.isDisjoint(with: RubienMCPToolPolicy.writeToolNames)
        )
    }

    func testUnknownRubienToolIsUnclassified() {
        XCTAssertNil(RubienMCPToolPolicy.access(for: "rubien_future_mutation"))
        XCTAssertEqual(RubienMCPToolPolicy.access(for: "rubien_get_reference"), .read)
        XCTAssertEqual(RubienMCPToolPolicy.access(for: "rubien_update_reference"), .write)
    }
}
