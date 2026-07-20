import XCTest
@testable import RubienCore

/// `ImportRouter.classify` — the §5.2 routing matrix. Pure classification with
/// an injected filesystem probe so the matrix runs without touching disk
/// (portable, Linux-covered). The end-to-end route behavior is black-box tested
/// through `add --source` in `RubienCLITests`.
final class ImportRouterTests: XCTestCase {

    /// A probe that reports every path as absent (routing without disk).
    private let noPaths: (String) -> ImportRouter.PathProbe = { _ in
        ImportRouter.PathProbe(exists: false, isDirectory: false)
    }

    private func probe(existing: [String: Bool]) -> (String) -> ImportRouter.PathProbe {
        { path in
            if let isDir = existing[path] {
                return ImportRouter.PathProbe(exists: true, isDirectory: isDir)
            }
            return ImportRouter.PathProbe(exists: false, isDirectory: false)
        }
    }

    // MARK: - Step 0: stdin

    func testStdin() {
        XCTAssertEqual(ImportRouter.classify(source: "-", probe: noPaths), .stdin)
    }

    // MARK: - Step 1: existing path wins

    func testExistingFileRoutesAsPath() {
        let route = ImportRouter.classify(source: "refs.bib", probe: probe(existing: ["refs.bib": false]))
        XCTAssertEqual(route, .existingPath(isDirectory: false))
    }

    func testExistingDirectoryRoutesAsFolder() {
        let route = ImportRouter.classify(source: "zotero", probe: probe(existing: ["zotero": true]))
        XCTAssertEqual(route, .existingPath(isDirectory: true))
    }

    /// Paths win over identifier-looking strings: a file named exactly like an
    /// arXiv id routes as a file when it exists on disk.
    func testPathBeatsIdentifier() {
        let route = ImportRouter.classify(source: "2501.07888", probe: probe(existing: ["2501.07888": false]))
        XCTAssertEqual(route, .existingPath(isDirectory: false))
    }

    /// The reverse escape: an identifier-shaped string that does NOT exist on
    /// disk falls through to the identifier route.
    func testMissingIdentifierShapedPathRoutesAsResolver() {
        let route = ImportRouter.classify(source: "2501.07888", probe: noPaths)
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: true))
    }

    /// A `doi.org` URL is never probed as a local path (it has a scheme), so it
    /// escapes the path-wins rule and routes to the resolver — the documented
    /// `https://doi.org/…` escape hatch.
    func testDoiOrgURLEscapesPathRule() {
        // Even if a same-named local path "existed", a scheme URL is not probed.
        let route = ImportRouter.classify(source: "https://doi.org/10.1234/foo", probe: { _ in
            ImportRouter.PathProbe(exists: true, isDirectory: false)
        })
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: true))
    }

    // MARK: - Step 2: URLs

    func testKnownHostLandingURLRoutesToResolver() {
        let route = ImportRouter.classify(source: "https://aclanthology.org/2024.acl-long.123", probe: noPaths)
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: true))
    }

    /// Registered PDF forms all take the resolver route and inherit its
    /// default-on policy; host-specific PDF-shape parsing is no longer needed
    /// to decide whether a download should be attempted.
    func testRegisteredHostPDFFormsRouteToResolverWithDefaultDownload() {
        let sources = [
            "https://aclanthology.org/2024.acl-long.123.pdf",
            "https://www.cell.com/neuron/pdf/S0896-6273(26)00414-9.pdf",
            "https://journals.aps.org/prl/pdf/10.1103/3v91-5pzf",
            "https://www.science.org/doi/pdf/10.1126/scirobotics.adz7397?download=true",
            "https://pubs.acs.org/doi/epdf/10.1021/acscentsci.3c01275",
        ]

        for source in sources {
            XCTAssertEqual(
                ImportRouter.classify(source: source, probe: noPaths),
                .resolver(impliedDownloadPdf: true),
                source
            )
        }
    }

    /// An explicit `--no-download-pdf` suppresses the default download.
    func testExplicitFalseSuppressesDefaultDownloadForPDFURL() {
        let route = ImportRouter.classify(
            source: "https://aclanthology.org/2024.acl-long.123.pdf",
            explicitDownloadPdf: false,
            probe: noPaths
        )
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: false))
    }

    func testExplicitFalseSuppressesDefaultDownloadForLandingURL() {
        let route = ImportRouter.classify(
            source: "https://aclanthology.org/2024.acl-long.123",
            explicitDownloadPdf: false,
            probe: noPaths
        )
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: false))
    }

    func testExplicitTrueKeepsDownloadOnPDFURL() {
        let route = ImportRouter.classify(
            source: "https://aclanthology.org/2024.acl-long.123.pdf",
            explicitDownloadPdf: true,
            probe: noPaths
        )
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: true))
    }

    /// arXiv is NOT in the paper-host registry, so `arxiv.org/pdf/…` takes the
    /// download-import route (fetches the file directly).
    func testArxivPDFURLRoutesToDownloadImport() {
        let route = ImportRouter.classify(source: "https://arxiv.org/pdf/2501.01234.pdf", probe: noPaths)
        XCTAssertEqual(route, .downloadImport)
    }

    func testUnregisteredMarkdownURLRoutesToDownloadImport() {
        let route = ImportRouter.classify(source: "https://example.com/notes/paper.md", probe: noPaths)
        XCTAssertEqual(route, .downloadImport)
    }

    /// Remote `.bib`/`.ris` URLs are not supported (v1 non-goal): unregistered
    /// host, non-file extension, no extractable identifier → unroutable.
    func testRemoteBibURLIsUnroutable() {
        let route = ImportRouter.classify(source: "https://example.com/refs.bib", probe: noPaths)
        guard case .unroutable = route else {
            return XCTFail("expected unroutable, got \(route)")
        }
    }

    // MARK: - Step 3: bare identifiers

    func testBareDOIRoutesToResolver() {
        let route = ImportRouter.classify(source: "10.1038/s41586-021-03819-2", probe: noPaths)
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: true))
    }

    func testBarePMCIDRoutesToResolver() {
        let route = ImportRouter.classify(source: "PMC4587766", probe: noPaths)
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: true))
    }

    func testExplicitFalseSuppressesDefaultDownloadForBareIdentifier() {
        let route = ImportRouter.classify(
            source: "PMC4587766",
            explicitDownloadPdf: false,
            probe: noPaths
        )
        XCTAssertEqual(route, .resolver(impliedDownloadPdf: false))
    }

    /// A typo'd path (no scheme, no identifier shape, not on disk) is
    /// unroutable, and the message names the path-not-found case.
    func testTypoedPathIsUnroutableWithHint() {
        let route = ImportRouter.classify(source: "./missing file.bib", probe: noPaths)
        guard case .unroutable(let reason) = route else {
            return XCTFail("expected unroutable, got \(route)")
        }
        XCTAssertTrue(reason.lowercased().contains("path"), "message should mention the path-not-found case; got: \(reason)")
    }

    // MARK: - Locator normalization (matches ImportSourceMaterializer)

    /// A leading `~` is expanded before the existence probe — an MCP source has
    /// no shell to expand it, so probing the raw string would misroute it.
    func testLeadingTildeExpandedBeforeProbe() {
        let expanded = ("~/Downloads/paper.pdf" as NSString).expandingTildeInPath
        let route = ImportRouter.classify(source: "~/Downloads/paper.pdf", probe: probe(existing: [expanded: false]))
        XCTAssertEqual(route, .existingPath(isDirectory: false))
    }

    /// Surrounding whitespace is trimmed before the probe (and before routing),
    /// matching the materializer.
    func testSurroundingWhitespaceTrimmedBeforeProbe() {
        let route = ImportRouter.classify(source: "  zotero  ", probe: probe(existing: ["zotero": true]))
        XCTAssertEqual(route, .existingPath(isDirectory: true))
    }
}
