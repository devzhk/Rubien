#if os(macOS)
import Foundation
import XCTest
@testable import Rubien
@testable import RubienCore

final class PendingMetadataIntakePresentationTests: XCTestCase {
    func testSinglePDFOpensPendingReviewImmediately() {
        XCTAssertEqual(
            PendingMetadataIntakePresentation.forImportedSources([
                source(kind: .pdf, name: "paper.pdf")
            ]),
            .reviewImmediately
        )
    }

    func testMultipleSourcesKeepPendingNotice() {
        XCTAssertEqual(
            PendingMetadataIntakePresentation.forImportedSources([
                source(kind: .pdf, name: "one.pdf"),
                source(kind: .pdf, name: "two.pdf"),
            ]),
            .showNotice
        )
    }

    func testSingleMarkdownSourceKeepsPendingNotice() {
        XCTAssertEqual(
            PendingMetadataIntakePresentation.forImportedSources([
                source(kind: .markdown, name: "note.md")
            ]),
            .showNotice
        )
    }

    private func source(kind: ImportSourceKind, name: String) -> MaterializedImportSource {
        MaterializedImportSource(
            input: "/tmp/\(name)",
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            kind: kind,
            temporaryDirectoryURL: nil
        )
    }
}
#endif
