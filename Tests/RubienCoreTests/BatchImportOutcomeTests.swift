import XCTest
import GRDB
@testable import RubienCore

/// Pure batch-outcome coverage for `AppDatabase.batchImportReferencesDetailed`
/// (spec §5.3). Deliberately GRDB-only (no PDFKit) so Linux CI runs it — the
/// PDF/Zotero outcome mapping lives in the Mac-gated `PDFImportCoordinatorTests`
/// / `ZoteroFolderImporterTests`.
final class BatchImportOutcomeTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    func testEmptyEntriesReturnsNoOutcomes() throws {
        let db = try makeDatabase()
        let outcomes = try db.batchImportReferencesDetailed([])
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testDistinctEntriesEachReportCreatedWithProvenance() throws {
        let db = try makeDatabase()
        let entries: [AppDatabase.DetailedImportEntry] = [
            (input: "bibtex[0]", reference: Reference(title: "First", doi: "10.1/a")),
            (input: "bibtex[1]", reference: Reference(title: "Second", doi: "10.1/b"))
        ]

        let outcomes = try db.batchImportReferencesDetailed(entries)

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.map(\.disposition), [.created, .created])
        // Provenance echoed 1:1, in input order.
        XCTAssertEqual(outcomes.map(\.input), ["bibtex[0]", "bibtex[1]"])
        // Distinct rows, each carrying its resolved reference.
        let ids = outcomes.compactMap { $0.reference?.id }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(try db.referenceCount(), 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.intakeId == nil && $0.error == nil })
    }

    func testIntraBatchDuplicateYieldsTwoItemsPointingAtOneReference() throws {
        let db = try makeDatabase()
        // Two entries dedup to one row on PMID: the later one merges into the
        // just-inserted row (spec §5.3 intra-batch duplicate).
        let entries: [AppDatabase.DetailedImportEntry] = [
            (input: "bibtex[0]", reference: Reference(title: "First Import", pmid: "123456")),
            (input: "bibtex[1]", reference: Reference(title: "Second Import", abstract: "Merged abstract", pmid: "123456"))
        ]

        let outcomes = try db.batchImportReferencesDetailed(entries)

        XCTAssertEqual(outcomes.count, 2, "One item per parsed input, not per distinct reference")
        XCTAssertEqual(outcomes[0].disposition, .created)
        XCTAssertEqual(outcomes[1].disposition, .existing, "The later duplicate is existing")
        XCTAssertEqual(outcomes.map(\.input), ["bibtex[0]", "bibtex[1]"])

        let firstID = try XCTUnwrap(outcomes[0].reference?.id)
        let secondID = try XCTUnwrap(outcomes[1].reference?.id)
        XCTAssertEqual(firstID, secondID, "Both items point at the same reference")

        // Only one row exists, carrying the merged metadata.
        XCTAssertEqual(try db.referenceCount(), 1)
        let all = try db.fetchAllReferences()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].abstract, "Merged abstract")

        // #3 regression: the EARLIER (`.created`) outcome must reflect the later
        // merge into its row — outcomes are re-fetched post-commit, not captured
        // as pre-merge snapshots. Entry 0 carried no abstract; the final row does.
        XCTAssertEqual(outcomes[0].reference?.abstract, "Merged abstract", "early outcome must be the final merged reference, not a stale snapshot")
        XCTAssertEqual(outcomes[1].reference?.abstract, "Merged abstract")
    }

    func testEntryDuplicatingAnExistingRowReportsExisting() throws {
        let db = try makeDatabase()
        var seeded = Reference(title: "Seeded", pmid: "999")
        try db.saveReference(&seeded)
        let seededID = try XCTUnwrap(seeded.id)

        let outcomes = try db.batchImportReferencesDetailed([
            (input: "bibtex[0]", reference: Reference(title: "Re-import", abstract: "Filled", pmid: "999"))
        ])

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].disposition, .existing)
        XCTAssertEqual(outcomes[0].reference?.id, seededID)
        XCTAssertEqual(try db.referenceCount(), 1)
    }

    func testBatchTransactionFailureThrowsAndRollsBack() throws {
        let db = try makeDatabase()
        // Force the write transaction to fail: no `reference` table to insert into.
        try db.dbWriter.write { database in
            try database.execute(sql: "DROP TABLE reference")
        }

        XCTAssertThrowsError(
            try db.batchImportReferencesDetailed([
                (input: "bibtex[0]", reference: Reference(title: "Doomed", doi: "10.1/x"))
            ]),
            "A batch-transaction failure must throw so the caller can synthesize per-entry failed items"
        )
    }
}
