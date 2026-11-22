import XCTest
@testable import RubienCore

final class SupplementaryMaterialURLTests: XCTestCase {
    private func looks(_ url: String, title: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let parsed = URL(string: url) else {
            XCTFail("Bad URL \(url)", file: file, line: line)
            return false
        }
        return SupplementaryMaterialURL.looksSupplementary(url: parsed, title: title)
    }

    // MARK: - Host / path patterns

    func testVenueSupplementPathsArePositive() {
        for url in [
            "https://openaccess.thecvf.com/content/CVPR2026/supplemental/Foo_Bar_CVPR_2026_paper.pdf",
            "https://openaccess.thecvf.com/content/ICCV2023/supplemental/Foo.zip",
            "https://proceedings.neurips.cc/paper_files/paper/2024/file/abc123-Supplemental-Conference.pdf",
            "https://papers.nips.cc/paper/2020/file/abc123-Supplemental.pdf",
            "https://proceedings.mlr.press/v202/radford23a/radford23a-supp.pdf",
        ] {
            XCTAssertTrue(looks(url), url)
            XCTAssertTrue(SupplementaryMaterialURL.hostPatternLooksSupplementary(URL(string: url)!), url)
        }
    }

    func testVenuePaperPathsAreNegative() {
        for url in [
            "https://openaccess.thecvf.com/content/CVPR2026/papers/Foo_Bar_CVPR_2026_paper.pdf",
            "https://proceedings.neurips.cc/paper_files/paper/2024/file/abc123-Paper-Conference.pdf",
            "https://papers.nips.cc/paper/2020/file/abc123-Paper.pdf",
            "https://proceedings.mlr.press/v202/radford23a/radford23a.pdf",
        ] {
            XCTAssertFalse(looks(url, title: "Learning Transferable Visual Models"), url)
        }
    }

    // MARK: - Filename keywords

    func testFilenameKeywordsArePositive() {
        for url in [
            "https://example.com/files/speediff_supplementary.pdf",
            "https://example.com/files/SpeeDiff-Supplemental.pdf",
            "https://example.com/files/SupplementaryMaterial.pdf",
            "https://example.com/files/paper_supp.pdf",
            "https://example.com/files/paper-supp.pdf",
            "https://example.com/files/paper.suppl.pdf",
            "https://example.com/files/paper_appendix.pdf",
            "https://example.com/files/appendices.md",
            "https://example.com/files/41586_2024_1234_MOESM1_ESM.pdf",
            "https://example.com/files/manuscript_SI.pdf",
            "https://example.com/files/SIAppendix.pdf",
            "https://pubs.acs.org/doi/suppl/10.1021/x/suppl_file/ja0c01234_si_001.pdf",
            "https://example.com/files/supporting_information.pdf",
            "https://example.com/files/extended-data.pdf",
            "https://example.com/files/Supplementary%20Material.pdf",
        ] {
            XCTAssertTrue(looks(url), url)
        }
    }

    func testFilenameNegatives() {
        for url in [
            "https://example.com/files/supply_chain_security.pdf",
            "https://example.com/files/suppressing-noise.pdf",
            "https://example.com/files/appendicitis-outcomes.pdf",
            "https://example.com/files/supplementation_trial.pdf",
            "https://example.com/files/esm2_protein_models.pdf",
            "https://example.com/files/ESM-2.pdf",
            "https://example.com/files/sigmoid.pdf",
            "https://example.com/files/2401.12345.pdf",
            "https://example.com/",
        ] {
            XCTAssertFalse(looks(url), url)
        }
    }

    // MARK: - Title keywords

    func testTitleKeywordsArePositive() {
        let url = "https://example.com/files/12345.pdf"
        for title in [
            "SpeeDiff — CVPR 2026 Supplementary Material",
            "Supplementary Materials for SpeeDiff",
            "Supplemental Material",
            "Supplementary Information",
            "Supporting Information for: Catalytic Cycles",
            "Supplement to “Scaling Laws for Neural Language Models”",
            "SpeeDiff — Supplementary",
            "SpeeDiff (Supp.)",
            "SpeeDiff: Supplement",
            "Appendix A: Proofs",
            "SpeeDiff Appendices",
            "SpeeDiff SI",
            "ESM for Deep Wavelets",
            "Extended Data Figures",
            "Online Supplementary Methods",
            "supp. materials",
        ] {
            XCTAssertTrue(looks(url, title: title), title)
        }
    }

    func testOrdinaryPaperTitlesAreNegative() {
        let url = "https://example.com/files/12345.pdf"
        for title in [
            "Supply Chain Attacks on Open-Source Package Managers",
            "Suppressing Hallucinations in Large Language Models",
            "Appendicitis in Children: A Cohort Study",
            "Dietary Supplement Use Among Adults",
            "Vitamin D Supplementation and Fracture Risk",
            "Supplementary Motor Area Activation During Speech",
            "SIGGRAPH Asia Technical Papers",
            "Scale-Invariant SI-SNR Training for Speech Separation",
            "ESM-2: Evolutionary Scale Modeling of Proteins",
            "Si Photonic Interconnects",
            "Attention Is All You Need",
            "",
        ] {
            XCTAssertFalse(looks(url, title: title), title)
        }
    }

    func testUppercaseOnlyKeywordsAreCaseSensitiveInTitles() {
        let url = "https://example.com/files/12345.pdf"
        XCTAssertTrue(looks(url, title: "Paper — SI"))
        XCTAssertFalse(looks(url, title: "Paper — si"))
        XCTAssertFalse(looks(url, title: "Esm and friends"))
    }

    func testFilenameTokenizer() {
        XCTAssertEqual(SupplementaryMaterialURL.filenameTokens("SpeeDiff_SupplementaryMaterial"),
                       ["Spee", "Diff", "Supplementary", "Material"])
        XCTAssertEqual(SupplementaryMaterialURL.filenameTokens("SIAppendix-v2"), ["SI", "Appendix", "v2"])
        XCTAssertEqual(SupplementaryMaterialURL.filenameTokens("MOESM1_ESM"), ["MOESM1", "ESM"])
    }
}
