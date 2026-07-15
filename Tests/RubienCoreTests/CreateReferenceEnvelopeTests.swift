import XCTest
import GRDB
@testable import RubienCore

/// The unified-envelope machinery (spec §5.3–§5.4): `ImportSummary` counting,
/// `CreateReferenceEnvelope` / `CreateReferenceItem` field omission, diagnostics
/// presence, and the inline-continuation / title-provenance outcome builders.
/// Portable (GRDB-only, no PDFKit) so Linux CI runs it — the routes that build
/// these items aren't `--source`-reachable until the Phase-D cutover, so Core
/// placement is what makes them testable now.
final class CreateReferenceEnvelopeTests: XCTestCase {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    // MARK: - ImportSummary

    func testSummaryCountsEveryDisposition() {
        let summary = ImportSummary(dispositions: [.created, .created, .existing, .queued, .failed])
        XCTAssertEqual(summary, ImportSummary(created: 2, existing: 1, queued: 1, failed: 1))
        XCTAssertEqual(summary.succeeded, 4)
        XCTAssertFalse(summary.isFailure, "partial success is not a failure")
    }

    func testSummaryAllFailedIsFailure() {
        let summary = ImportSummary(dispositions: [.failed, .failed])
        XCTAssertEqual(summary.succeeded, 0)
        XCTAssertTrue(summary.isFailure)
    }

    func testEmptySummaryIsFailure() {
        XCTAssertTrue(ImportSummary(dispositions: []).isFailure)
    }

    // MARK: - Diagnostics

    func testDiagnosticsIsEmptyWhenAllNil() {
        XCTAssertTrue(CreateReferenceDiagnostics().isEmpty)
        XCTAssertFalse(CreateReferenceDiagnostics(file: "x").isEmpty)
        XCTAssertFalse(CreateReferenceDiagnostics(attached: 0).isEmpty)
    }

    // MARK: - Envelope encoding (field omission)

    private struct StubRef: Encodable, Sendable, Equatable { let id: Int64 }
    private struct StubPDF: Encodable, Sendable, Equatable { let ok: Bool }
    private typealias Item = CreateReferenceItem<StubRef, StubPDF>
    private typealias Envelope = CreateReferenceEnvelope<StubRef, StubPDF>

    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A created item carries `reference` + `status` + `input`; nil optionals
    /// (`intakeId`, `pdfDownload`, `error`) are omitted entirely.
    func testCreatedItemOmitsNilFields() throws {
        let item = Item(reference: StubRef(id: 42), status: .created, input: "10.1/a")
        let obj = try encodeToObject(item)
        XCTAssertEqual(obj["status"] as? String, "created")
        XCTAssertEqual(obj["input"] as? String, "10.1/a")
        XCTAssertNotNil(obj["reference"])
        XCTAssertNil(obj["intakeId"], "intakeId omitted when nil")
        XCTAssertNil(obj["pdfDownload"], "pdfDownload omitted when nil")
        XCTAssertNil(obj["error"], "error omitted when nil")
    }

    /// A queued item has an `intakeId` and no `reference`.
    func testQueuedItemCarriesIntakeIdNoReference() throws {
        let item = Item(reference: nil, status: .queued, intakeId: 7, input: "paper.pdf")
        let obj = try encodeToObject(item)
        XCTAssertEqual(obj["status"] as? String, "queued")
        XCTAssertEqual(obj["intakeId"] as? Int, 7)
        XCTAssertNil(obj["reference"], "reference omitted for a queued-unlinked item")
    }

    /// A failed item carries `error` and no `reference`.
    func testFailedItemCarriesError() throws {
        let item = Item(reference: nil, status: .failed, input: "bogus", error: "unrecognized identifier")
        let obj = try encodeToObject(item)
        XCTAssertEqual(obj["status"] as? String, "failed")
        XCTAssertEqual(obj["error"] as? String, "unrecognized identifier")
        XCTAssertNil(obj["reference"])
    }

    func testEnvelopeShapeRoundTrips() throws {
        let envelope = Envelope(
            items: [
                Item(reference: StubRef(id: 1), status: .created, input: "bibtex[0]",
                     pdfDownload: StubPDF(ok: true)),
                Item(status: .failed, input: "bibtex[1]", error: "boom")
            ],
            summary: ImportSummary(created: 1, existing: 0, queued: 0, failed: 1),
            diagnostics: CreateReferenceDiagnostics(file: "refs.bib")
        )
        let obj = try encodeToObject(envelope)
        let items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil((items[0]["pdfDownload"] as? [String: Any]))
        let summary = try XCTUnwrap(obj["summary"] as? [String: Any])
        XCTAssertEqual(summary["created"] as? Int, 1)
        XCTAssertEqual(summary["failed"] as? Int, 1)
        let diag = try XCTUnwrap(obj["diagnostics"] as? [String: Any])
        XCTAssertEqual(diag["file"] as? String, "refs.bib")
        XCTAssertNil(diag["attached"], "unset diagnostic fields are omitted")
    }

    // MARK: - importEntriesContinuingPastFailures (inline / title routes)

    /// Title provenance: the manual-title route echoes the title string as the
    /// item's `input`, and the created reference carries the title.
    func testTitleProvenance() throws {
        let db = try makeDB()
        let outcomes = db.importEntriesContinuingPastFailures([
            (input: "My Manual Paper", reference: Reference(title: "My Manual Paper"))
        ])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].disposition, .created)
        XCTAssertEqual(outcomes[0].input, "My Manual Paper", "input provenance is the title string")
        XCTAssertEqual(outcomes[0].reference?.title, "My Manual Paper")
        XCTAssertNil(outcomes[0].error)
    }

    /// Inline-BibTeX continuation: each entry is its own transaction, in order,
    /// with 1:1 provenance. A later entry duplicating an earlier one reports
    /// `existing` (not failed) — continuation, not stop-on-first.
    func testInlineContinuationYieldsPerEntryOutcomes() throws {
        let db = try makeDB()
        let outcomes = db.importEntriesContinuingPastFailures([
            (input: "bibtex[0]", reference: Reference(title: "First", doi: "10.1/x")),
            (input: "bibtex[1]", reference: Reference(title: "Second", doi: "10.1/y")),
            (input: "bibtex[2]", reference: Reference(title: "Dup of first", doi: "10.1/x"))
        ])
        XCTAssertEqual(outcomes.map(\.input), ["bibtex[0]", "bibtex[1]", "bibtex[2]"])
        XCTAssertEqual(outcomes.map(\.disposition), [.created, .created, .existing])
        // The duplicate points at the first entry's row.
        XCTAssertEqual(outcomes[0].reference?.id, outcomes[2].reference?.id)
        XCTAssertEqual(try db.referenceCount(), 2)
    }

    func testEmptyEntriesYieldNoOutcomes() throws {
        let db = try makeDB()
        XCTAssertTrue(db.importEntriesContinuingPastFailures([]).isEmpty)
    }
}
