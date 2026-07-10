#if os(macOS)
import Foundation
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class MarkdownImportWorkerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownImportWorkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testImportsMarkdownFillOnlyAndReportsUnreadableSource() async throws {
        let database = try AppDatabase(DatabaseQueue())
        var curated = Reference(
            title: "Curated title",
            url: "https://example.com/worker",
            referenceType: .webpage
        )
        _ = try database.saveReference(&curated)
        let curatedID = try XCTUnwrap(curated.id)

        let readableURL = temporaryDirectory.appendingPathComponent("clip.md")
        try Data("""
        ---
        source: https://example.com/worker
        description: Filled from Markdown
        ---
        # Incoming title

        Body
        """.utf8).write(to: readableURL)
        let missingURL = temporaryDirectory.appendingPathComponent("missing.md")

        let result = await MarkdownImportWorker.importSources(
            [
                MaterializedImportSource(
                    input: readableURL.path,
                    fileURL: readableURL,
                    kind: .markdown,
                    temporaryDirectoryURL: nil
                ),
                MaterializedImportSource(
                    input: missingURL.path,
                    fileURL: missingURL,
                    kind: .markdown,
                    temporaryDirectoryURL: nil
                ),
            ],
            database: database
        )

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.importedIDs, [curatedID])
        XCTAssertEqual(result.unreadableFilenames, ["missing.md"])
        XCTAssertNil(result.errorDescription)

        let merged = try XCTUnwrap(database.fetchReferences(ids: [curatedID]).first)
        XCTAssertEqual(merged.title, "Curated title")
        XCTAssertEqual(merged.abstract, "Filled from Markdown")
    }
}
#endif
