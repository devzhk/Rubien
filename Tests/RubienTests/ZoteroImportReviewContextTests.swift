#if os(macOS) && canImport(PDFKit)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore
@testable import RubienPDFKit

@MainActor
final class ZoteroImportReviewContextTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    private var copiedPDFPaths: [String] = []

    override func tearDownWithError() throws {
        for path in copiedPDFPaths {
            PDFService.deletePDF(at: path)
        }
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        copiedPDFPaths.removeAll()
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testContextPreservesPlanRowsWithoutPersisting() throws {
        let database = try makeDatabase()
        let folder = try makeFolder(
            bibtex: """
            @article{a, title = {First}}
            @article{b, title = {Second}, file = {PDF:/linked/second.pdf:application/pdf}}
            """
        )
        let plan = try ZoteroFolderImporter.prepareFolder(
            at: folder,
            db: database,
            propertyTarget: nil
        )

        let context = ZoteroImportReviewContext(database: database, plan: plan)

        XCTAssertEqual(context.items.map(\.id), plan.entries.map(\.id))
        XCTAssertEqual(context.items.map(\.title), ["First", "Second"])
        XCTAssertEqual(context.items.map(\.readiness), [.ready, .ready])
        XCTAssertNil(context.items[0].message)
        XCTAssertTrue(context.items[1].message?.contains("/linked/second.pdf") == true)
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testContextCommitsOnlySelectedRowsOffMainThread() async throws {
        let database = try makeDatabase()
        let folder = try makeFolder(
            bibtex: """
            @article{a, title = {First}, doi = {10.1/first}}
            @article{b, title = {Second}, doi = {10.1/second}, file = {PDF:files/2/b.pdf:application/pdf}}
            """,
            pdfs: ["files/2/b.pdf": Data("second-pdf".utf8)]
        )
        let plan = try ZoteroFolderImporter.prepareFolder(
            at: folder,
            db: database,
            propertyTarget: nil
        )
        let context = ZoteroImportReviewContext(
            database: database,
            plan: plan,
            committer: { plan, selectedIDs, database in
                XCTAssertFalse(Thread.isMainThread)
                return try ZoteroFolderImporter.commit(
                    plan: plan,
                    selectedEntryIDs: selectedIDs,
                    db: database
                )
            }
        )
        let selectedID = context.items[1].id

        let report = await context.commit(selectedIDs: [selectedID])

        XCTAssertEqual(report.succeededIDs, [selectedID])
        XCTAssertTrue(report.failures.isEmpty)
        let reference = try XCTUnwrap(database.fetchAllReferences().first)
        XCTAssertEqual(reference.title, "Second")
        copiedPDFPaths.append(try XCTUnwrap(try database.pdfFilename(for: reference.id!)))
    }

    func testContextReportsOneAtomicFailureForEverySelectedRow() async throws {
        let database = try makeDatabase()
        let folder = try makeFolder(
            bibtex: """
            @article{a, title = {First}}
            @article{b, title = {Second}}
            """
        )
        let plan = try ZoteroFolderImporter.prepareFolder(
            at: folder,
            db: database,
            propertyTarget: nil
        )
        let context = ZoteroImportReviewContext(
            database: database,
            plan: plan,
            committer: { _, _, _ in throw InjectedFailure() }
        )
        let selected = Set(context.items.map(\.id))

        let report = await context.commit(selectedIDs: selected)

        XCTAssertTrue(report.succeededIDs.isEmpty)
        XCTAssertEqual(Set(report.failures.keys), selected)
        XCTAssertEqual(Set(report.failures.values), ["Injected Zotero failure"])
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testContextSurfacesRuntimeMissingPDFFromSuccessfulCommit() async throws {
        let database = try makeDatabase()
        let folder = try makeFolder(
            bibtex: """
            @article{a, title = {First}}
            @article{b, title = {Second}}
            """
        )
        let plan = try ZoteroFolderImporter.prepareFolder(
            at: folder,
            db: database,
            propertyTarget: nil
        )
        var completion: ZoteroFolderImporter.Result?
        let expected = ZoteroFolderImporter.Result(
            imported: 2,
            attached: 0,
            missingPDFs: ["files/missing.pdf"],
            duplicatesSkipped: 0
        )
        let context = ZoteroImportReviewContext(
            database: database,
            plan: plan,
            committer: { _, _, _ in expected },
            onCompleted: { completion = $0 }
        )

        let report = await context.commit(selectedIDs: Set(context.items.map(\.id)))

        XCTAssertEqual(report.succeededIDs, Set(context.items.map(\.id)))
        XCTAssertEqual(completion, expected)
    }

    func testReviewThresholdUsesPreparedEntryCount() {
        XCTAssertFalse(ZoteroImportReviewPresentation.shouldReview(entryCount: 0))
        XCTAssertFalse(ZoteroImportReviewPresentation.shouldReview(entryCount: 1))
        XCTAssertTrue(ZoteroImportReviewPresentation.shouldReview(entryCount: 2))
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func makeFolder(
        bibtex: String,
        pdfs: [String: Data] = [:]
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroImportReviewContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bibtex.write(
            to: folder.appendingPathComponent("export.bib"),
            atomically: true,
            encoding: .utf8
        )
        for (path, data) in pdfs {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        cleanupURLs.append(folder)
        return folder
    }
}

private struct InjectedFailure: LocalizedError {
    var errorDescription: String? { "Injected Zotero failure" }
}
#endif
