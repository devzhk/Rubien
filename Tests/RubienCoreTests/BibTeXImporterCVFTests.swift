import XCTest
@testable import RubienCore

final class BibTeXImporterCVFTests: XCTestCase {

    // MARK: - Standard CVPR @InProceedings

    func testStandardCVPRBlock() {
        let bib = """
        @InProceedings{Smith_2024_CVPR,
            author    = {Smith, John and Doe, Jane},
            title     = {Some Paper Title},
            booktitle = {Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)},
            month     = {June},
            year      = {2024},
            pages     = {1234-1245}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        let ref = refs[0]
        XCTAssertEqual(ref.title, "Some Paper Title")
        XCTAssertEqual(ref.authors.count, 2)
        XCTAssertEqual(ref.authors[0].family, "Smith")
        XCTAssertEqual(ref.authors[1].family, "Doe")
        XCTAssertEqual(ref.year, 2024)
        XCTAssertEqual(ref.pages, "1234-1245")
        XCTAssertEqual(ref.referenceType, .conferencePaper)
        XCTAssertEqual(ref.journal, "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)")
        XCTAssertEqual(ref.eventTitle, "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)")
        XCTAssertEqual(ref.issuedMonth, 6)
    }

    // MARK: - Multi-author block

    func testMultiAuthorBlock() {
        let bib = """
        @InProceedings{Alpha_2024_ICCV,
            author    = {Alpha, A. and Beta, B. and Gamma, C. and Delta, D. and Epsilon, E.},
            title     = {Five-Author Vision Paper},
            booktitle = {Proceedings of the IEEE/CVF International Conference on Computer Vision (ICCV)},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].authors.count, 5)
        // Lock per-author family names so 5 empty AuthorName structs can't silently pass.
        XCTAssertEqual(refs[0].authors[0].family, "Alpha")
        XCTAssertEqual(refs[0].authors[4].family, "Epsilon")
    }

    // MARK: - LaTeX brace protection in title

    func testTitleWithLaTeXBraces() {
        let bib = """
        @InProceedings{Foo_2024_ECCV,
            author    = {Foo, F.},
            title     = {Foundations of {S}^n Manifold Learning},
            booktitle = {Proceedings of the European Conference on Computer Vision (ECCV)},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        // Inner braces are BibTeX capitalization-protection markers, not literal
        // content: {S} must be stripped to S so the title reads naturally.
        XCTAssertEqual(refs[0].title, "Foundations of S^n Manifold Learning")
    }

    // MARK: - Capitalization-protection braces stripped from title (Zotero export)

    func testTitleStripsCapitalizationProtectionBraces() {
        // Real-world Zotero `Better BibTeX` export: every protected word is wrapped
        // in braces. These must not leak into the displayed title.
        let bib = """
        @article{epfl_2025,
            author = {Last, First},
            title = {{EPFL}-{Smart}-{Kitchen}-30: {Densely} annotated cooking dataset with {3D} kinematics to challenge video and language models},
            year = {2025}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(
            refs[0].title,
            "EPFL-Smart-Kitchen-30: Densely annotated cooking dataset with 3D kinematics to challenge video and language models"
        )
    }

    func testTitleStripsTitleCaseProtectionBraces() {
        // Zotero wraps each word of a title-cased entry: {A} {Self}-{Controlled} ...
        let bib = """
        @article{selfctrl_2024,
            title = {A {Self}-{Controlled} {Mind} {Is} {Reflected} by {Stable} {Mental} {Processing}},
            year = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].title, "A Self-Controlled Mind Is Reflected by Stable Mental Processing")
    }

    func testProtectionBracesStrippedFromJournalAndPublisher() {
        // The same brace convention applies to every display-text field, not just title.
        let bib = """
        @article{abbr_2024,
            title = {Some Paper},
            journal = {{IEEE} Transactions on {PAMI}},
            publisher = {{MIT} Press},
            year = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].journal, "IEEE Transactions on PAMI")
        XCTAssertEqual(refs[0].publisher, "MIT Press")
    }

    func testProtectionBracesStrippedFromBooktitle() {
        // `booktitle` only surfaces when there is no `journal` (importer maps
        // `journal ?? booktitle`); a conference paper also exposes it via `eventTitle`.
        let bib = """
        @inproceedings{conf_2024,
            title = {Some Paper},
            booktitle = {{NeurIPS} 2024},
            year = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].journal, "NeurIPS 2024")
        XCTAssertEqual(refs[0].eventTitle, "NeurIPS 2024")
    }

    func testAuthorProtectionBracesStrippedOnImport() {
        // End-to-end shape from the user's real library: a brace-protected corporate
        // author must import with clean names and not be split on its internal " and ".
        let bib = """
        @article{ibl_2023,
            author = {{International Brain Lab} and Benson, Brandon},
            title = {A Brain-Wide Map},
            year = {2023}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].authors.count, 2)
        XCTAssertEqual(refs[0].authors[0], AuthorName(given: "", family: "International Brain Lab"))
        XCTAssertEqual(refs[0].authors[1], AuthorName(given: "Brandon", family: "Benson"))
    }

    func testEscapedLiteralBracesPreservedInTitle() {
        // `\{` / `\}` are escaped *literal* braces (LaTeX), not protection markers —
        // they must survive de-bracing while bare protection braces are removed.
        let bib = """
        @article{literal_2024,
            title = {The \\{Set\\} of {Natural} Numbers},
            year = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].title, "The \\{Set\\} of Natural Numbers")
    }

    // MARK: - Bare-word month

    func testBareWordMonth() {
        let bib = """
        @InProceedings{Bar_2024_WACV,
            author    = {Bar, B.},
            title     = {Winter Vision Paper},
            booktitle = {Proceedings of the IEEE/CVF Winter Conference on Applications of Computer Vision (WACV)},
            month     = {january},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].issuedMonth, 1)
    }

    // MARK: - Block followed by HTML noise (mimics <pre> extraction)

    func testBlockFollowedByHTMLNoise() {
        let bib = """
        @InProceedings{Baz_2024_CVPR,
            author    = {Baz, B.},
            title     = {HTML-Noise Robustness},
            booktitle = {Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)},
            year      = {2024}
        }
        </pre>
        <div class="footer">Copyright 2024</div>
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].title, "HTML-Noise Robustness")
    }

    // MARK: - Block without doi field (CVF norm)

    func testBlockWithoutDOI() {
        let bib = """
        @InProceedings{Qux_2024_CVPR,
            author    = {Qux, Q.},
            title     = {No DOI Here},
            booktitle = {CVPR 2024},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        XCTAssertNil(refs[0].doi)
    }

    // MARK: - Multi-line title (line-wrapped BibTeX)

    func testMultiLineTitle() {
        let bib = """
        @InProceedings{Wrap_2024_CVPR,
            author    = {Wrap, W.},
            title     = {A Very Long Title That Wraps
                         Across Multiple Lines in the BibTeX Source},
            booktitle = {CVPR 2024},
            year      = {2024}
        }
        """
        let refs = BibTeXImporter.parse(bib)
        XCTAssertEqual(refs.count, 1)
        // Title should contain both halves; importer may preserve newlines or
        // collapse whitespace — assert content rather than exact form.
        XCTAssertTrue(refs[0].title.contains("Long Title"))
        XCTAssertTrue(refs[0].title.contains("Multiple Lines"))
        // Importer trims the final value; no leading/trailing whitespace.
        XCTAssertFalse(refs[0].title.hasPrefix(" "))
        XCTAssertFalse(refs[0].title.hasSuffix(" "))
    }
}
