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

    func testIEEEStampStaysAsIs() {
        // IEEE stamp.jsp PDFs have no clean landing-page mapping; pass through
        // so subsequent fetch hits the PDF endpoint and content-type check
        // rejects it (§4 row).
        XCTAssertEqual(rewrite("https://ieeexplore.ieee.org/stamp/stamp.jsp"),
                       "https://ieeexplore.ieee.org/stamp/stamp.jsp")
    }
}
