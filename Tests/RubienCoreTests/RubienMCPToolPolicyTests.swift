import XCTest
@testable import RubienCore

final class RubienMCPToolPolicyTests: XCTestCase {
    func testCanonicalCatalogPartitionsTwentyEightTools() {
        XCTAssertEqual(RubienMCPToolPolicy.readToolNames.count, 15)
        XCTAssertEqual(RubienMCPToolPolicy.writeToolNames.count, 13)
        XCTAssertEqual(RubienMCPToolPolicy.allToolNames.count, 28)
        XCTAssertTrue(
            RubienMCPToolPolicy.readToolNames.isDisjoint(with: RubienMCPToolPolicy.writeToolNames)
        )
    }

    func testUnknownRubienToolIsUnclassified() {
        XCTAssertNil(RubienMCPToolPolicy.access(for: "rubien_future_mutation"))
        XCTAssertEqual(RubienMCPToolPolicy.access(for: "rubien_get_reference"), .read)
        XCTAssertEqual(RubienMCPToolPolicy.access(for: "rubien_update_reference"), .write)
    }

    func testExternalDocumentBadgeMatchesAddReferenceRouting() {
        XCTAssertEqual(
            RubienAppPresentationContract.externalCandidateBadge(
                for: "https://arxiv.org/abs/2606.24597"
            ),
            "Paper candidate"
        )
        XCTAssertEqual(
            RubienAppPresentationContract.externalCandidateBadge(
                for: "https://example.com/paper.pdf"
            ),
            "PDF candidate"
        )
        XCTAssertEqual(
            RubienAppPresentationContract.externalCandidateBadge(
                for: "https://example.com/notes.md"
            ),
            "Document candidate"
        )
        XCTAssertEqual(
            RubienAppPresentationContract.externalCandidateBadge(
                for: "https://example.com/article"
            ),
            "Web candidate"
        )
    }
}
