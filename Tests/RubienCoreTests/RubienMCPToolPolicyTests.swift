import XCTest
@testable import RubienCore

final class RubienMCPToolPolicyTests: XCTestCase {
    func testCanonicalCatalogPartitionsThirtySixTools() {
        XCTAssertEqual(RubienMCPToolPolicy.readToolNames.count, 18)
        XCTAssertEqual(RubienMCPToolPolicy.writeToolNames.count, 18)
        XCTAssertEqual(RubienMCPToolPolicy.allToolNames.count, 36)
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

    func testSupplementaryFileCandidatesGetSupplementBadge() {
        let badge = RubienAppPresentationContract.externalCandidateBadge
        XCTAssertEqual(
            badge("https://openaccess.thecvf.com/content/CVPR2026/supplemental/Foo_CVPR_2026_supplemental.pdf", nil),
            "Supplement candidate"
        )
        XCTAssertEqual(
            badge("https://openaccess.thecvf.com/content/CVPR2026/supplemental/Foo.pdf",
                  "SpeeDiff — CVPR 2026 Supplementary Material"),
            "Supplement candidate"
        )
        // Formerly misrouted as the paper itself ("Paper candidate").
        XCTAssertEqual(
            badge("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Supplemental-Conference.pdf", nil),
            "Supplement candidate"
        )
        XCTAssertEqual(
            badge("https://proceedings.mlr.press/v200/foo23a/foo23a-supp.pdf", nil),
            "Supplement candidate"
        )
        // A title alone can mark an otherwise ordinary file URL.
        XCTAssertEqual(badge("https://example.com/files/12345.pdf", "Supplementary Information"), "Supplement candidate")
        XCTAssertEqual(badge("https://example.com/appendix.md", nil), "Supplement candidate")
    }

    func testOrdinaryAndPaperCandidatesKeepTheirBadges() {
        let badge = RubienAppPresentationContract.externalCandidateBadge
        XCTAssertEqual(badge("https://example.com/paper.pdf", "Supply Chain Attacks on Package Managers"), "PDF candidate")
        XCTAssertEqual(badge("https://example.com/notes.md", "Reading notes"), "Document candidate")
        XCTAssertEqual(
            badge("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf", nil),
            "Paper candidate"
        )
        XCTAssertEqual(
            badge("https://proceedings.mlr.press/v200/foo23a/foo23a.pdf", nil),
            "Paper candidate"
        )
        // Supplement wording on a paper or web route does not override it:
        // only attachable files can become supplement candidates.
        XCTAssertEqual(badge("https://arxiv.org/abs/2606.24597", "Supplementary Material"), "Paper candidate")
        XCTAssertEqual(badge("https://example.com/supplementary", "Supplementary Material"), "Web candidate")
    }
}
