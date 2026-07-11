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

    func testMarkdownPreparationDoesNotWriteBeforeCommit() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let firstURL = temporaryDirectory.appendingPathComponent("first.md")
        try Data("""
        ---
        source: https://example.com/first
        ---
        # First

        Body
        """.utf8).write(to: firstURL)
        let secondURL = temporaryDirectory.appendingPathComponent("second.md")
        try Data("# Second".utf8).write(to: secondURL)
        let missingURL = temporaryDirectory.appendingPathComponent("missing.md")

        let result = await MarkdownImportWorker.prepareSources(
            [
                MaterializedImportSource(
                    input: firstURL.path,
                    fileURL: firstURL,
                    kind: .markdown,
                    temporaryDirectoryURL: nil
                ),
                MaterializedImportSource(
                    input: secondURL.path,
                    fileURL: secondURL,
                    kind: .markdown,
                    temporaryDirectoryURL: nil
                ),
                MaterializedImportSource(
                    input: missingURL.path,
                    fileURL: missingURL,
                    kind: .markdown,
                    temporaryDirectoryURL: nil
                ),
            ]
        )

        XCTAssertEqual(result.entries.map(\.reference.title), ["First", "Second"])
        XCTAssertEqual(result.entries.map(\.sourceLabel), ["first.md", "second.md"])
        XCTAssertEqual(result.unreadableFilenames, ["missing.md"])
        XCTAssertEqual(try database.referenceCount(), 0)
    }
}
#endif
