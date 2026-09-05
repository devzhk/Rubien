#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

@MainActor
final class LibrarySearchStateTests: XCTestCase {
    func testYearEditsPreserveSelectionButOtherSearchChangesResetIt() {
        let original = LibrarySearchFilterState(query: "scaling", contentScope: .everything,
            selectedType: nil, hasPDF: nil, titleOnly: false, yearFrom: "", yearTo: "")
        var changed = original
        changed.yearFrom = "2020"
        changed.yearTo = "2026"
        XCTAssertTrue(changed.preservesSelection(from: original))
        for mutate: (inout LibrarySearchFilterState) -> Void in [
            { $0.query = "compute" }, { $0.contentScope = .notesAndHighlights },
            { $0.hasPDF = true }, { $0.titleOnly = true }, { $0.selectedType = .webpage },
        ] {
            var next = changed
            mutate(&next)
            XCTAssertFalse(next.preservesSelection(from: changed))
        }
    }

    private actor Batches {
        var ids: [[Int64]] = []
        func record(_ references: [Reference]) { ids.append(references.compactMap(\.id)) }
        func snapshot() -> [[Int64]] { ids }
    }

    func testVisibleExcerptRequestsAreBatchedAndEmptyResultsAreCached() async throws {
        let loader = LibrarySearchExcerptLoader()
        let batches = Batches()
        var references = (1...20).map { id in
            var reference = Reference(title: "Paper \(id)")
            reference.id = Int64(id)
            return reference
        }
        for reference in references {
            loader.request(reference) { refs in await batches.record(refs); return [:] }
        }
        try await Task.sleep(for: .milliseconds(100))
        // Reappearing rows without a matching excerpt must not repeat database work.
        references.reverse()
        for reference in references {
            loader.request(reference) { refs in await batches.record(refs); return [:] }
        }
        try await Task.sleep(for: .milliseconds(100))
        let recorded = await batches.snapshot()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(Set(recorded[0]), Set((1...20).map(Int64.init)))
    }

    func testResetPreventsOldExcerptResultsFromEnteringNewSearch() async throws {
        let loader = LibrarySearchExcerptLoader()
        let started = expectation(description: "Old search started")
        var old = Reference(title: "Old")
        old.id = 1
        loader.request(old) { _ in
            started.fulfill()
            // Even a reader that returns a result after cancellation must be ignored.
            try? await Task.sleep(for: .seconds(1))
            return [1: LibrarySearchExcerpt(source: "Note", text: "Old result")]
        }
        await fulfillment(of: [started], timeout: 2)
        loader.reset()
        var new = Reference(title: "New")
        new.id = 2
        loader.request(new) { _ in [2: LibrarySearchExcerpt(source: "Note", text: "New result")] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(loader.excerpts[1])
        XCTAssertEqual(loader.excerpts[2]?.text, "New result")
    }
}
#endif
