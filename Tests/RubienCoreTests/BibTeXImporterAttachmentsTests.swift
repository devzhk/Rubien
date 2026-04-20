import XCTest
@testable import RubienCore

final class BibTeXImporterAttachmentsTests: XCTestCase {

    // MARK: - `file` field parser

    func testSingleAttachment() {
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/835/Sutton and Barto.pdf:application/pdf"
        )
        XCTAssertEqual(paths, ["files/835/Sutton and Barto.pdf"])
    }

    func testMultipleAttachmentsSemicolonSeparated() {
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/1/a.pdf:application/pdf;Snapshot:files/2/b.pdf:application/pdf"
        )
        XCTAssertEqual(paths, ["files/1/a.pdf", "files/2/b.pdf"])
    }

    func testEscapedColonInFilename() {
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/99/Foo\\: Bar - 2024.pdf:application/pdf"
        )
        XCTAssertEqual(paths, ["files/99/Foo: Bar - 2024.pdf"])
    }

    func testEscapedSemicolonInFilename() {
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/99/weird\\;name.pdf:application/pdf"
        )
        XCTAssertEqual(paths, ["files/99/weird;name.pdf"])
    }

    func testEscapedBackslashInFilename() {
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/99/back\\\\slash.pdf:application/pdf"
        )
        XCTAssertEqual(paths, ["files/99/back\\slash.pdf"])
    }

    func testEmptyMIMEWithPDFSuffixAccepted() {
        // Older Zotero exports sometimes emit an empty MIME segment.
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/11/paper.pdf:"
        )
        XCTAssertEqual(paths, ["files/11/paper.pdf"])
    }

    func testNonPDFMIMERejected() {
        let paths = BibTeXImporter.parseFileField(
            "Snapshot:files/12/page.html:text/html"
        )
        XCTAssertTrue(paths.isEmpty)
    }

    func testAbsoluteUnixPathRejectedAndSurfaced() {
        let result = BibTeXImporter.parseFileFieldDetailed(
            "PDF:/Users/alice/Zotero/storage/abc/paper.pdf:application/pdf"
        )
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected, ["/Users/alice/Zotero/storage/abc/paper.pdf"])
        // `parseFileField` facade still returns only accepted paths.
        XCTAssertTrue(BibTeXImporter.parseFileField(
            "PDF:/Users/alice/Zotero/storage/abc/paper.pdf:application/pdf"
        ).isEmpty)
    }

    func testAbsoluteWindowsPathRejectedAndSurfaced() {
        let result = BibTeXImporter.parseFileFieldDetailed(
            "PDF:C\\:\\Users\\alice\\paper.pdf:application/pdf"
        )
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected, ["C:\\Users\\alice\\paper.pdf"])
    }

    func testWhitespaceTrimmedBetweenPieces() {
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/1/a.pdf:application/pdf ; PDF:files/2/b.pdf:application/pdf"
        )
        XCTAssertEqual(paths, ["files/1/a.pdf", "files/2/b.pdf"])
    }

    func testMissingMIMESegmentWithPDFSuffixAccepted() {
        // Only two segments separated by a single colon: description:path
        let paths = BibTeXImporter.parseFileField("PDF:files/1/a.pdf")
        XCTAssertEqual(paths, ["files/1/a.pdf"])
    }

    func testEmptyInput() {
        XCTAssertEqual(BibTeXImporter.parseFileField(nil), [])
        XCTAssertEqual(BibTeXImporter.parseFileField(""), [])
    }

    func testNonASCIIFilename() {
        let paths = BibTeXImporter.parseFileField(
            "PDF:files/42/论文 - 2024.pdf:application/pdf"
        )
        XCTAssertEqual(paths, ["files/42/论文 - 2024.pdf"])
    }

    // MARK: - End-to-end: real Zotero BibTeX excerpt

    func testParseWithAttachmentsFromZoteroExport() {
        let bibtex = """
        @book{suttonReinforcementLearningIntroduction2020,
            title = {Reinforcement learning: an introduction},
            author = {Sutton, Richard S. and Barto, Andrew},
            year = {2020},
            file = {PDF:files/835/Sutton and Barto - 2020 - Reinforcement learning an introduction.pdf:application/pdf},
        }

        @article{agarwalReinforcementLearningTheory,
            title = {Reinforcement {Learning}: {Theory} and {Algorithms}},
            author = {Agarwal, Alekh and Jiang, Nan},
            file = {PDF:files/845/Agarwal et al. - Reinforcement Learning Theory and Algorithms.pdf:application/pdf},
        }

        @article{noAttachment2021,
            title = {No files here},
            author = {Doe, Jane},
        }
        """

        let entries = BibTeXImporter.parseWithAttachments(bibtex)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(
            entries[0].attachmentPaths,
            ["files/835/Sutton and Barto - 2020 - Reinforcement learning an introduction.pdf"]
        )
        XCTAssertEqual(
            entries[1].attachmentPaths,
            ["files/845/Agarwal et al. - Reinforcement Learning Theory and Algorithms.pdf"]
        )
        XCTAssertEqual(entries[2].attachmentPaths, [])
    }

    func testParseFacadeDropsAttachments() {
        let bibtex = """
        @book{x,
            title = {T},
            file = {PDF:files/1/a.pdf:application/pdf},
        }
        """
        let refs = BibTeXImporter.parse(bibtex)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].title, "T")
    }
}
