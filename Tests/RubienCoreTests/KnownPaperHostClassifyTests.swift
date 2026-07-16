import XCTest
@testable import RubienCore

final class URLCanonicalizationTests: XCTestCase {

    private func canonicalize(_ s: String) -> String? {
        guard let url = URL(string: s) else { return nil }
        return PaperURLResolver.canonicalize(url)?.absoluteString
    }

    func testLowercaseHost() {
        XCTAssertEqual(canonicalize("https://OPENREVIEW.NET/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testLowercaseScheme() {
        XCTAssertEqual(canonicalize("HTTPS://openreview.net/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testStripWWWPrefix() {
        XCTAssertEqual(canonicalize("https://www.nature.com/articles/foo"),
                       "https://nature.com/articles/foo")
    }

    func testStripFragment() {
        XCTAssertEqual(canonicalize("https://openreview.net/forum?id=ABCD#section-2"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testUpgradeHTTPToHTTPS() {
        // Spec §2.4: "If both work for a publisher, store as https." All 10
        // target hosts support https; canonicalize unconditionally upgrades.
        XCTAssertEqual(canonicalize("http://openreview.net/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testStripDefaultPort80AndUpgrade() {
        // http://...:80 becomes https://... (no port).
        XCTAssertEqual(canonicalize("http://openreview.net:80/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testStripDefaultPort443() {
        XCTAssertEqual(canonicalize("https://openreview.net:443/forum?id=ABCD"),
                       "https://openreview.net/forum?id=ABCD")
    }

    func testPreserveTrailingSlash() {
        XCTAssertEqual(canonicalize("https://aclanthology.org/2024.acl-long.123/"),
                       "https://aclanthology.org/2024.acl-long.123/")
    }

    func testPreservePathCase() {
        // CVF paths are case-sensitive; preserve.
        XCTAssertEqual(canonicalize("https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html"),
                       "https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html")
    }

    func testPreserveQueryOrder() {
        // Query params not reordered; OpenReview routing depends on ?id=.
        XCTAssertEqual(canonicalize("https://openreview.net/forum?id=ABCD&noteId=XYZ"),
                       "https://openreview.net/forum?id=ABCD&noteId=XYZ")
    }

    func testRejectEmbeddedCredentials() {
        XCTAssertNil(canonicalize("https://user:pass@openreview.net/forum?id=ABCD"))
    }

    func testRejectUnsupportedScheme() {
        XCTAssertNil(canonicalize("ftp://openreview.net/forum?id=ABCD"))
        XCTAssertNil(canonicalize("file:///etc/passwd"))
    }
}

final class KnownPaperHostClassifyTests: XCTestCase {

    private func classify(_ s: String) -> KnownPaperHost? {
        guard let url = URL(string: s) else { return nil }
        return KnownPaperHost.classify(url)
    }

    // OpenReview
    func testOpenReviewLanding() {
        XCTAssertEqual(classify("https://openreview.net/forum?id=ABCD"), .openReview)
    }
    func testOpenReviewPDF() {
        XCTAssertEqual(classify("https://openreview.net/pdf?id=ABCD"), .openReview)
    }
    func testOpenReviewMissingQuery() {
        // No ?id= → not a paper URL
        XCTAssertNil(classify("https://openreview.net/forum"))
    }
    func testOpenReviewHomepage() {
        XCTAssertNil(classify("https://openreview.net/"))
    }

    // ACL Anthology
    func testACLLanding() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.acl-long.123/"), .aclAnthology)
    }
    func testACLLandingNoTrailingSlash() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.acl-long.123"), .aclAnthology)
    }
    func testACLPDF() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.acl-long.123.pdf"), .aclAnthology)
    }
    func testACLFindings() {
        XCTAssertEqual(classify("https://aclanthology.org/2024.findings-emnlp.42/"), .aclAnthology)
    }
    func testACLHomepage() {
        XCTAssertNil(classify("https://aclanthology.org/"))
    }

    // CVF
    func testCVFLanding() {
        XCTAssertEqual(classify("https://openaccess.thecvf.com/content/CVPR2024/html/Foo_paper.html"), .cvfOpenAccess)
    }
    func testCVFPDF() {
        XCTAssertEqual(classify("https://openaccess.thecvf.com/content/CVPR2024/papers/Foo_paper.pdf"), .cvfOpenAccess)
    }
    func testCVFHomepage() {
        XCTAssertNil(classify("https://openaccess.thecvf.com/"))
    }

    // NeurIPS
    func testNeurIPSLegacyLanding() {
        XCTAssertEqual(classify("https://papers.nips.cc/paper/2020/hash/abc.html"), .neurIPS)
    }
    func testNeurIPSLegacyPDF() {
        XCTAssertEqual(classify("https://papers.nips.cc/paper/2020/file/abc.pdf"), .neurIPS)
    }
    func testNeurIPSModernLanding() {
        XCTAssertEqual(classify("https://proceedings.neurips.cc/paper_files/paper/2024/hash/abc-Abstract-Conference.html"), .neurIPSProceedings)
    }
    func testNeurIPSModernPDF() {
        XCTAssertEqual(classify("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Conference.pdf"), .neurIPSProceedings)
    }
    func testNeurIPSDatasetsTrack() {
        XCTAssertEqual(classify("https://proceedings.neurips.cc/paper_files/paper/2024/file/abc-Paper-Datasets_and_Benchmarks_Track.pdf"), .neurIPSProceedings)
    }

    // PMLR
    func testPMLRLanding() {
        XCTAssertEqual(classify("https://proceedings.mlr.press/v200/foo23a.html"), .pmlr)
    }
    func testPMLRPDF() {
        XCTAssertEqual(classify("https://proceedings.mlr.press/v200/foo23a/foo23a.pdf"), .pmlr)
    }

    // IEEE
    func testIEEEDocument() {
        XCTAssertEqual(classify("https://ieeexplore.ieee.org/document/1234567"), .ieeeXplore)
    }
    func testIEEEAbstract() {
        XCTAssertEqual(classify("https://ieeexplore.ieee.org/abstract/document/1234567"), .ieeeXplore)
    }
    func testIEEEStampPDF() {
        XCTAssertEqual(classify("https://ieeexplore.ieee.org/stamp/stamp.jsp"), .ieeeXplore)
    }
    func testIEEEJournalHomepage() {
        // Not a paper URL — falls through
        XCTAssertNil(classify("https://ieeexplore.ieee.org/journal/12345"))
    }

    // ACM
    func testACMLanding() {
        XCTAssertEqual(classify("https://dl.acm.org/doi/10.1145/foo.bar"), .acmDL)
    }
    func testACMAbs() {
        XCTAssertEqual(classify("https://dl.acm.org/doi/abs/10.1145/foo.bar"), .acmDL)
    }
    func testACMPDF() {
        XCTAssertEqual(classify("https://dl.acm.org/doi/pdf/10.1145/foo.bar"), .acmDL)
    }

    // Nature
    func testNatureArticle() {
        XCTAssertEqual(classify("https://nature.com/articles/s41586-024-12345-6"), .nature)
    }
    func testNatureWWWArticle() {
        XCTAssertEqual(classify("https://www.nature.com/articles/s41586-024-12345-6"), .nature)
    }
    func testNaturePDF() {
        XCTAssertEqual(classify("https://nature.com/articles/s41586-024-12345-6.pdf"), .nature)
    }
    func testNatureHomepage() {
        XCTAssertNil(classify("https://nature.com/"))
    }

    // Springer
    func testSpringerArticle() {
        XCTAssertEqual(classify("https://link.springer.com/article/10.1007/s11042-024-12345-6"), .springer)
    }
    func testSpringerChapter() {
        XCTAssertEqual(classify("https://link.springer.com/chapter/10.1007/978-3-540-24777-7_1"), .springer)
    }
    func testSpringerBook() {
        XCTAssertEqual(classify("https://link.springer.com/book/10.1007/978-3-030-12345-6"), .springer)
    }
    func testSpringerContentPDF_NotAccepted() {
        // No Springer PDF rewrite; should fall through.
        XCTAssertNil(classify("https://link.springer.com/content/pdf/10.1007/foo.pdf"))
    }
    func testSpringerSearch() {
        XCTAssertNil(classify("https://link.springer.com/search?query=foo"))
    }

    // ScienceDirect
    func testScienceDirectPII() {
        XCTAssertEqual(classify("https://www.sciencedirect.com/science/article/pii/S0123456789012345"), .scienceDirect)
    }
    func testScienceDirectAbsPII() {
        XCTAssertEqual(classify("https://www.sciencedirect.com/science/article/abs/pii/S0123456789012345"), .scienceDirect)
    }
    func testScienceDirectPDFFT() {
        XCTAssertEqual(classify("https://www.sciencedirect.com/science/article/pii/S0123456789012345/pdfft"), .scienceDirect)
    }

    // eLife
    func testELifeArticle() {
        XCTAssertEqual(classify("https://elifesciences.org/articles/29515"), .eLife)
    }
    func testELifeWWWArticle() {
        XCTAssertEqual(classify("https://www.elifesciences.org/articles/29515/"), .eLife)
    }
    func testELifePDF() {
        XCTAssertEqual(classify("https://elifesciences.org/articles/29515.pdf"), .eLife)
    }
    func testELifeRejectsNonArticlePages() {
        XCTAssertNil(classify("https://elifesciences.org/articles/research-article"))
        XCTAssertNil(classify("https://elifesciences.org/inside-elife/example"))
    }

    // APS Physical Review journals
    func testAPSCurrentDOIAbstract() {
        XCTAssertEqual(
            classify("https://journals.aps.org/prl/abstract/10.1103/3v91-5pzf"),
            .aps
        )
    }
    func testAPSLegacyDOIPDF() {
        XCTAssertEqual(
            classify("https://journals.aps.org/prl/pdf/10.1103/PhysRevLett.133.030001"),
            .aps
        )
    }
    func testAPSOtherPhysicalReviewJournal() {
        XCTAssertEqual(
            classify("https://journals.aps.org/pra/abstract/10.1103/PhysRevA.109.012345"),
            .aps
        )
    }
    func testAPSAcceptedPaper() {
        XCTAssertEqual(
            classify("https://journals.aps.org/prl/accepted/10.1103/3v91-5pzf"),
            .aps
        )
    }
    func testAPSRejectsNonArticlePagesAndOtherDOIPrefixes() {
        XCTAssertNil(classify("https://journals.aps.org/prl/recent"))
        XCTAssertNil(classify("https://journals.aps.org/prl/abstract/10.9999/example"))
        XCTAssertNil(classify("https://journals.aps.org/prl/abstract/10.1103/example/references"))
    }
    func testAPSToleratesSingleTrailingSlash() {
        XCTAssertEqual(
            classify("https://journals.aps.org/prl/abstract/10.1103/3v91-5pzf/"),
            .aps
        )
    }
    func testAPSRejectsEmptyPathComponents() {
        // Doubled slashes must not collapse into a valid article path —
        // the landing URL is persisted verbatim on the Reference.
        XCTAssertNil(classify("https://journals.aps.org//prl/abstract/10.1103/3v91-5pzf"))
        XCTAssertNil(classify("https://journals.aps.org/prl//abstract/10.1103/3v91-5pzf"))
        XCTAssertNil(classify("https://journals.aps.org/prl/abstract/10.1103//3v91-5pzf"))
        XCTAssertNil(classify("https://journals.aps.org/prl/abstract/10.1103/3v91-5pzf//"))
    }

    // eNeuro
    func testENeuroAssignedIssueArticle() {
        XCTAssertEqual(
            classify("https://www.eneuro.org/content/9/2/ENEURO.0361-21.2022.long"),
            .eNeuro
        )
    }
    func testENeuroEarlyReleaseArticle() {
        XCTAssertEqual(
            classify("https://www.eneuro.org/content/early/2026/07/02/ENEURO.0257-25.2026"),
            .eNeuro
        )
    }
    func testENeuroEarlyReleasePDF() {
        XCTAssertEqual(
            classify("https://www.eneuro.org/content/eneuro/early/2026/07/02/ENEURO.0257-25.2026.full.pdf"),
            .eNeuro
        )
    }
    func testENeuroRejectsNonArticlePages() {
        XCTAssertNil(classify("https://www.eneuro.org/content/9/2"))
        XCTAssertNil(classify("https://www.eneuro.org/content/by/section/Cognition%20and%20Behavior"))
    }

    // Negatives — random hosts
    func testRandomBlog() {
        XCTAssertNil(classify("https://example-blog.com/post/hello"))
    }
    func testGoogle() {
        XCTAssertNil(classify("https://www.google.com/search?q=foo"))
    }
}
