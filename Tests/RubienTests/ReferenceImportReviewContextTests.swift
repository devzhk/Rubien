#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

@MainActor
final class ReferenceImportReviewContextTests: XCTestCase {
    func testReferenceContextCommitsOnlySelectedRowsInOneTransaction() async throws {
        let database = try makeDatabase()
        let entries = ["A", "B", "C"].map {
            PreparedReferenceImport(reference: Reference(title: $0), sourceLabel: $0)
        }
        let context = ReferenceImportReviewContext(
            database: database,
            entries: entries,
            mergePolicy: .standard
        )

        let selected = Set([context.items[0].id, context.items[2].id])
        let report = await context.commit(selectedIDs: selected)

        XCTAssertEqual(report.succeededIDs, selected)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(Set(try database.fetchAllReferences().map(\.title)), ["A", "C"])
    }

    func testReferenceContextReportsSameFailureForAtomicSelection() async throws {
        let database = try makeDatabase()
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_selected_reference
                BEFORE INSERT ON reference
                WHEN NEW.title = 'B'
                BEGIN
                    SELECT RAISE(ABORT, 'injected batch failure');
                END
                """)
        }
        let entries = ["A", "B", "C"].map {
            PreparedReferenceImport(reference: Reference(title: $0), sourceLabel: $0)
        }
        let context = ReferenceImportReviewContext(
            database: database,
            entries: entries,
            mergePolicy: .standard
        )
        let selected = Set(context.items.map(\.id))

        let report = await context.commit(selectedIDs: selected)

        XCTAssertTrue(report.succeededIDs.isEmpty)
        XCTAssertEqual(Set(report.failures.keys), selected)
        XCTAssertEqual(Set(report.failures.values).count, 1)
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }
}
#endif
