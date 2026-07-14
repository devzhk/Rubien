#if os(macOS)
import XCTest
@testable import Rubien
import RubienPDFKit

final class ZoteroLibraryImportPresentationTests: XCTestCase {
    private let collections = [
        ZoteroLibraryCollection(
            key: "ROOT0001",
            name: "Research",
            parentKey: nil,
            itemCount: 3,
            childCollectionCount: 1
        ),
        ZoteroLibraryCollection(
            key: "CHILD001",
            name: "Papers",
            parentKey: "ROOT0001",
            itemCount: 2,
            childCollectionCount: 0
        ),
    ]

    func testScopeKeepsCheckedCollectionsDistinctFromExplicitSelectAll() {
        let allCollectionKeys: Set<String> = ["ROOT0001", "CHILD001"]

        XCTAssertEqual(
            ZoteroLibraryImportPresentation.scope(
                entireLibrary: false,
                selectedKeys: allCollectionKeys
            ),
            .collections(allCollectionKeys)
        )
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.scope(
                entireLibrary: true,
                selectedKeys: allCollectionKeys
            ),
            .entireLibrary
        )
        XCTAssertNil(
            ZoteroLibraryImportPresentation.scope(
                entireLibrary: false,
                selectedKeys: []
            )
        )
    }

    func testAttachmentSummaryDescribesReferenceSingleAndMultiplePDFs() {
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.attachmentSummary(
                for: ZoteroLibraryItemSummary(
                    key: "NO_PDF",
                    title: "Reference",
                    pdfFilenames: []
                )
            ),
            "Zotero reference"
        )
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.attachmentSummary(
                for: ZoteroLibraryItemSummary(
                    key: "ONE_PDF",
                    title: "Paper",
                    pdfFilenames: ["paper.pdf"]
                )
            ),
            "paper.pdf"
        )
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.attachmentSummary(
                for: ZoteroLibraryItemSummary(
                    key: "TWO_PDFS",
                    title: "Paper",
                    pdfFilenames: ["main.pdf", "supplement.pdf"]
                )
            ),
            "2 PDFs: main.pdf, supplement.pdf"
        )
    }

    func testSingleCollectionSuggestsItsNameWithoutOverwritingMultiScopeMeaning() {
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.stampSuggestion(
                entireLibrary: false,
                selectedKeys: ["ROOT0001"],
                collections: collections
            ),
            "Research"
        )
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.stampSuggestion(
                entireLibrary: false,
                selectedKeys: ["ROOT0001", "CHILD001"],
                collections: collections
            ),
            "Zotero"
        )
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.stampSuggestion(
                entireLibrary: true,
                selectedKeys: [],
                collections: collections
            ),
            "Zotero"
        )
    }

    func testSelectionSummaryIncludesDescendantsWhenRequested() {
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.selectionSummary(
                entireLibrary: false,
                selectedKeys: ["ROOT0001"],
                collections: collections,
                includeSubcollections: false
            ),
            "1 collection will be scanned"
        )
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.selectionSummary(
                entireLibrary: false,
                selectedKeys: ["ROOT0001"],
                collections: collections,
                includeSubcollections: true
            ),
            "2 collections will be scanned"
        )
        XCTAssertEqual(
            ZoteroLibraryImportPresentation.selectionSummary(
                entireLibrary: true,
                selectedKeys: [],
                collections: collections,
                includeSubcollections: true
            ),
            "All references in My Library"
        )
    }
}
#endif
