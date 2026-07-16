import XCTest
@testable import RubienCore

final class PaperURLRewriteTests: XCTestCase {

    private func rewrite(_ s: String) -> String? {
        guard let url = URL(string: s),
              let host = KnownPaperHost.classify(url) else { return nil }
        return PaperURLResolver.rewritePDFURLToLanding(url, host: host).absoluteString
    }

    func testOpenReviewPDFRewrite() {
        XCTAssertEqual(rewrite("https://openreview.net/pdf?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testOpenReviewLandingNoChange() {
        XCTAssertEqual(rewrite("https://openreview.net/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testACLPDFRewrite() {
        XCTAssertEqual(rewrite("https://aclanthology.org/2024.acl-long.123.pdf"),
                       "https://aclanthology.org/2024.acl-long.123/")
    }

    func testCVFPDFRewrite() {
        XCTAssertEqual(rewrite("https://openaccess.thecvf.com/content/CVPR2024/papers/Foo_paper.pdf"),
                       "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html")
    }

    func testNeurIPSLegacyPDFRewrite() {
        XCTAssertEqual(rewrite("https://papers.nips.cc/paper/2020/file/abc.pdf"),
                       "https://papers.nips.cc/paper/2020/hash/abc.html")
    }

    func testNeurIPSModernPDFRewriteMainTrack() {
        XCTAssertEqual(rewrite("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf"),
                       "https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html")
    }

    func testNeurIPSModernPDFRewriteDatasetsTrack() {
        XCTAssertEqual(rewrite("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Datasets_and_Benchmarks_Track.pdf"),
                       "https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Datasets_and_Benchmarks_Track.html")
    }

    func testPMLRPDFRewrite() {
        XCTAssertEqual(rewrite("https://proceedings.mlr.press/v200/foo23a/foo23a.pdf"),
                       "https://proceedings.mlr.press/v200/foo23a.html")
    }

    func testACMPDFRewrite() {
        XCTAssertEqual(rewrite("https://dl.acm.org/doi/pdf/10.1145/foo"),
                       "https://dl.acm.org/doi/10.1145/foo")
    }

    func testNaturePDFRewrite() {
        XCTAssertEqual(rewrite("https://nature.com/articles/foo.pdf"),
                       "https://nature.com/articles/foo")
    }

    func testScienceDirectPDFFTRewrite() {
        XCTAssertEqual(rewrite("https://www.sciencedirect.com/science/article/pii/SXXXX/pdfft"),
                       "https://sciencedirect.com/science/article/pii/SXXXX")
    }

    func testSciencePDFVariantsRewriteToCanonicalLanding() {
        XCTAssertEqual(
            rewrite("https://www.science.org/doi/pdf/10.1126/sciadv.abn9545"),
            "https://www.science.org/doi/10.1126/sciadv.abn9545"
        )
        XCTAssertEqual(
            rewrite("https://www.science.org/doi/epdf/10.1126/sciadv.abn9545"),
            "https://www.science.org/doi/10.1126/sciadv.abn9545"
        )
    }

    func testScienceFullLandingRetainsWorkingWWWHost() {
        XCTAssertEqual(
            rewrite("https://www.science.org/doi/full/10.1126/sciadv.abn9545"),
            "https://www.science.org/doi/full/10.1126/sciadv.abn9545"
        )
    }

    func testACSPDFVariantsRewriteToCanonicalLanding() {
        XCTAssertEqual(
            rewrite("https://pubs.acs.org/doi/pdf/10.1021/acscentsci.3c01275"),
            "https://pubs.acs.org/doi/10.1021/acscentsci.3c01275"
        )
        XCTAssertEqual(
            rewrite("https://pubs.acs.org/doi/epdf/10.1021/acscentsci.3c01275"),
            "https://pubs.acs.org/doi/10.1021/acscentsci.3c01275"
        )
    }

    func testAANDAPDFRewrite() {
        XCTAssertEqual(
            rewrite("https://www.aanda.org/articles/aa/pdf/2026/02/aa57022-25.pdf"),
            "https://www.aanda.org/articles/aa/full_html/2026/02/aa57022-25/aa57022-25.html"
        )
    }

    func testAANDAFullHTMLRetainsWorkingWWWHost() {
        XCTAssertEqual(
            rewrite("https://www.aanda.org/articles/aa/full_html/2026/02/aa57022-25/aa57022-25.html"),
            "https://www.aanda.org/articles/aa/full_html/2026/02/aa57022-25/aa57022-25.html"
        )
    }

    func testELifePDFRewrite() {
        XCTAssertEqual(rewrite("https://www.elifesciences.org/articles/29515.pdf"),
                       "https://elifesciences.org/articles/29515")
    }

    func testELifeLandingNoChange() {
        XCTAssertEqual(rewrite("https://elifesciences.org/articles/29515"),
                       "https://elifesciences.org/articles/29515")
    }

    func testAPSPDFRewrite() {
        XCTAssertEqual(
            rewrite("https://journals.aps.org/prl/pdf/10.1103/3v91-5pzf"),
            "https://journals.aps.org/prl/abstract/10.1103/3v91-5pzf"
        )
    }

    func testAPSAbstractAndAcceptedPagesStayAsIs() {
        XCTAssertEqual(
            rewrite("https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.133.030001"),
            "https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.133.030001"
        )
        XCTAssertEqual(
            rewrite("https://journals.aps.org/prl/accepted/10.1103/3v91-5pzf"),
            "https://journals.aps.org/prl/accepted/10.1103/3v91-5pzf"
        )
    }

    func testENeuroLongPageRewrite() {
        XCTAssertEqual(
            rewrite("https://www.eneuro.org/content/9/2/ENEURO.0361-21.2022.long"),
            "https://www.eneuro.org/content/9/2/ENEURO.0361-21.2022"
        )
    }

    func testENeuroEarlyReleasePDFRewrite() {
        XCTAssertEqual(
            rewrite("https://www.eneuro.org/content/eneuro/early/2026/07/02/ENEURO.0257-25.2026.full.pdf"),
            "https://www.eneuro.org/content/early/2026/07/02/ENEURO.0257-25.2026"
        )
    }

    func testIEEEStampStaysAsIs() {
        // IEEE stamp.jsp PDFs have no clean landing-page mapping; pass through
        // so subsequent fetch hits the PDF endpoint and content-type check
        // rejects it (§4 row).
        XCTAssertEqual(rewrite("https://ieeexplore.ieee.org/stamp/stamp.jsp"),
                       "https://ieeexplore.ieee.org/stamp/stamp.jsp")
    }
}
