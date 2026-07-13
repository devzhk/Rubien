import XCTest
@testable import RubienCore

final class PaperURLExtractionTests: XCTestCase {

    private func extract(_ s: String) -> MetadataFetcher.Identifier? {
        MetadataFetcher.extractIdentifier(from: s)
    }

    func testOpenReviewForumExtractsAsPaperURL() {
        guard case .paperURL = extract("https://openreview.net/forum?id=ABCD") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testOpenReviewPDFExtractsAsPaperURL() {
        guard case .paperURL = extract("https://openreview.net/pdf?id=ABCD") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testACLExtractsAsPaperURL() {
        guard case .paperURL = extract("https://aclanthology.org/2024.acl-long.123/") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testNatureExtractsAsPaperURL() {
        guard case .paperURL = extract("https://www.nature.com/articles/s41586-024-12345-6") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testELifeArticleExtractsAsPaperURL() {
        guard case .paperURL = extract("https://elifesciences.org/articles/29515") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testELifePDFExtractsAsPaperURL() {
        guard case .paperURL = extract("https://elifesciences.org/articles/29515.pdf") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testSpringerArticleExtractsAsPaperURL() {
        guard case .paperURL = extract("https://link.springer.com/article/10.1007/s11042-024-12345-6") else {
            return XCTFail("Expected .paperURL — must beat bare DOI extraction")
        }
    }

    func testSpringerChapterExtractsAsPaperURL() {
        guard case .paperURL = extract("https://link.springer.com/chapter/10.1007/978-3-540-24777-7_1") else {
            return XCTFail("Expected .paperURL")
        }
    }

    func testSpringerContentPDFNotAccepted() {
        // No Springer PDF rewrite — must fall through.
        let result = extract("https://link.springer.com/content/pdf/10.1007/foo.pdf")
        switch result {
        case .paperURL: XCTFail("Should not be .paperURL")
        case .doi: break  // OK — bare DOI substring caught by existing extractor
        case .none: break // OK — no identifier
        default: XCTFail("Unexpected: \(String(describing: result))")
        }
    }

    func testSpringerSearchFallsThrough() {
        XCTAssertNil(extract("https://link.springer.com/search?q=neural"))
    }

    func testRandomBlogFallsThrough() {
        XCTAssertNil(extract("https://example-blog.com/post/hello"))
    }

    func testBareDOIStillWorks() {
        guard case .doi(let value) = extract("10.1234/abc.def"),
              value == "10.1234/abc.def" else {
            return XCTFail("Bare DOI extraction broken")
        }
    }

    func testCaseInsensitivePaperURL() {
        guard case .paperURL = extract("HTTPS://WWW.NATURE.COM/articles/foo") else {
            return XCTFail("Expected .paperURL after canonicalization")
        }
    }
}
