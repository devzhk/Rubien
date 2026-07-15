import XCTest
@testable import RubienCore

final class AddReferenceInputRouterTests: XCTestCase {
    private let noPaths: (String) -> ImportRouter.PathProbe = { _ in
        ImportRouter.PathProbe(exists: false, isDirectory: false)
    }

    func testEmptyInputIsRejected() {
        XCTAssertEqual(
            AddReferenceInputRouter.classify("  \n", probe: noPaths),
            .invalid(.emptyInput)
        )
    }

    func testIdentifierRoutesToMetadata() {
        XCTAssertEqual(
            AddReferenceInputRouter.classify("10.1038/s41586-021-03819-2", probe: noPaths),
            .metadata("10.1038/s41586-021-03819-2")
        )
    }

    func testPaperURLRoutesToMetadata() {
        let input = "https://aclanthology.org/2024.acl-long.123"
        XCTAssertEqual(AddReferenceInputRouter.classify(input, probe: noPaths), .metadata(input))
    }

    func testKnownPaperPDFURLStillRoutesToMetadata() {
        let input = "https://aclanthology.org/2024.acl-long.123.pdf"
        XCTAssertEqual(AddReferenceInputRouter.classify(input, probe: noPaths), .metadata(input))
    }

    func testTitleRoutesToMetadata() {
        let input = "Attention Is All You Need"
        XCTAssertEqual(AddReferenceInputRouter.classify(input, probe: noPaths), .metadata(input))
    }

    func testOrdinaryURLRoutesToWebsite() {
        let input = "https://example.com/articles/reference-managers"
        XCTAssertEqual(AddReferenceInputRouter.classify(input, probe: noPaths), .website(input))
    }

    func testDirectPDFAndMarkdownURLsRouteToFileImport() {
        let pdf = "https://example.com/paper.pdf"
        let markdown = "https://example.com/note.markdown"
        XCTAssertEqual(AddReferenceInputRouter.classify(pdf, probe: noPaths), .file(pdf))
        XCTAssertEqual(AddReferenceInputRouter.classify(markdown, probe: noPaths), .file(markdown))
    }

    func testArxivPDFURLRoutesToFileImport() {
        let input = "https://arxiv.org/pdf/2501.01234.pdf"
        XCTAssertEqual(AddReferenceInputRouter.classify(input, probe: noPaths), .file(input))
    }

    func testMissingSupportedPathRoutesToFileImportForClearMaterializerError() {
        let input = "/tmp/missing-paper.pdf"
        XCTAssertEqual(AddReferenceInputRouter.classify(input, probe: noPaths), .file(input))
    }

    func testExistingUnsupportedFileIsRejected() {
        let input = "/tmp/references.bib"
        let route = AddReferenceInputRouter.classify(input) { path in
            ImportRouter.PathProbe(exists: path == input, isDirectory: false)
        }
        XCTAssertEqual(route, .invalid(.unsupportedFileType(pathExtension: "bib")))
    }

    func testExistingDirectoryIsRejected() {
        let input = "/tmp/library"
        let route = AddReferenceInputRouter.classify(input) { path in
            ImportRouter.PathProbe(exists: path == input, isDirectory: true)
        }
        XCTAssertEqual(route, .invalid(.directory))
    }

    func testUnsupportedURLSchemeIsRejected() {
        let route = AddReferenceInputRouter.classify("ftp://example.com/paper.pdf", probe: noPaths)
        XCTAssertEqual(route, .invalid(.unsupportedURLScheme))
    }

    func testIncompleteHTTPURLIsRejectedAsInvalidURL() {
        for input in ["https://", "http://"] {
            XCTAssertEqual(
                AddReferenceInputRouter.classify(input, probe: noPaths),
                .invalid(.invalidHTTPURL)
            )
        }
    }

    func testRelativeFilePathIsRejectedBeforeMaterialization() {
        for input in ["paper.pdf", "./paper.pdf", "../note.md"] {
            XCTAssertEqual(
                AddReferenceInputRouter.classify(input, probe: noPaths),
                .invalid(.relativeFilePath)
            )
        }
    }

    func testTildeFilePathRoutesToFileImport() {
        let input = "~/Documents/paper.pdf"
        XCTAssertEqual(AddReferenceInputRouter.classify(input, probe: noPaths), .file(input))
    }

    func testInputIsTrimmed() {
        XCTAssertEqual(
            AddReferenceInputRouter.classify("  A Paper Title\n", probe: noPaths),
            .metadata("A Paper Title")
        )
    }
}
