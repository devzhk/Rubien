import XCTest
@testable import RubienCore

final class SortEngineTests: XCTestCase {

    private func makeRef(
        id: Int64,
        title: String = "Untitled",
        year: Int? = nil,
        journal: String? = nil,
        readingStatus: String = ReadingStatus.unread,
        dateAdded: Date = Date()
    ) -> Reference {
        ReferenceFixtures.makeRef(
            id: id, title: title, year: year, journal: journal,
            readingStatus: readingStatus, dateAdded: dateAdded
        )
    }

    private var context: PipelineContext { PipelineContext() }

    func testSortByYearAscending() {
        let rows = [
            makeRef(id: 1, year: 2024),
            makeRef(id: 2, year: 2020),
            makeRef(id: 3, year: 2022),
        ]
        let sorts = [ViewSort(target: .builtin(.year), ascending: true)]
        let out = SortEngine.apply(rows, sorts: sorts, context: context)
        XCTAssertEqual(out.map(\.id), [2, 3, 1])
    }

    func testSortByYearDescending() {
        let rows = [
            makeRef(id: 1, year: 2020),
            makeRef(id: 2, year: 2024),
            makeRef(id: 3, year: 2022),
        ]
        let sorts = [ViewSort(target: .builtin(.year), ascending: false)]
        let out = SortEngine.apply(rows, sorts: sorts, context: context)
        XCTAssertEqual(out.map(\.id), [2, 3, 1])
    }

    func testNullsSortLastRegardlessOfDirection() {
        let rows = [
            makeRef(id: 1, year: nil),
            makeRef(id: 2, year: 2024),
            makeRef(id: 3, year: nil),
            makeRef(id: 4, year: 2020),
        ]
        let ascending = SortEngine.apply(rows, sorts: [ViewSort(target: .builtin(.year), ascending: true)], context: context)
        XCTAssertEqual(Array(ascending.map(\.id).prefix(2)), [4, 2])
        XCTAssertEqual(Set(ascending.suffix(2).map(\.id)), [1, 3])

        let descending = SortEngine.apply(rows, sorts: [ViewSort(target: .builtin(.year), ascending: false)], context: context)
        XCTAssertEqual(Array(descending.map(\.id).prefix(2)), [2, 4])
        XCTAssertEqual(Set(descending.suffix(2).map(\.id)), [1, 3])
    }

    func testMultiColumnPrimaryThenSecondary() {
        let rows = [
            makeRef(id: 1, year: 2024, journal: "B"),
            makeRef(id: 2, year: 2024, journal: "A"),
            makeRef(id: 3, year: 2020, journal: "C"),
        ]
        let sorts = [
            ViewSort(target: .builtin(.year), ascending: false),
            ViewSort(target: .builtin(.journal), ascending: true),
        ]
        let out = SortEngine.apply(rows, sorts: sorts, context: context)
        XCTAssertEqual(out.map(\.id), [2, 1, 3])
    }

    func testIdTiebreakerWhenAllUserSortsEqual() {
        let now = Date()
        let rows = [
            makeRef(id: 3, dateAdded: now),
            makeRef(id: 1, dateAdded: now),
            makeRef(id: 2, dateAdded: now),
        ]
        let sorts = [ViewSort(target: .builtin(.dateAdded), ascending: true)]
        let out = SortEngine.apply(rows, sorts: sorts, context: context)
        XCTAssertEqual(out.map(\.id), [1, 2, 3])
    }

    func testEmptySortsPreservesInputOrder() {
        let rows = (1...3).map { makeRef(id: Int64($0)) }
        let out = SortEngine.apply(rows, sorts: [], context: context)
        XCTAssertEqual(out.map(\.id), rows.map(\.id))
    }

    func testNullsLastOnTextDescending() {
        let rows = [
            makeRef(id: 1, journal: nil),
            makeRef(id: 2, journal: "Nature"),
            makeRef(id: 3, journal: nil),
            makeRef(id: 4, journal: "Science"),
        ]
        let out = SortEngine.apply(rows, sorts: [ViewSort(target: .builtin(.journal), ascending: false)], context: context)
        XCTAssertEqual(Array(out.map(\.id).prefix(2)), [4, 2])
        XCTAssertEqual(Set(out.suffix(2).map(\.id)), [1, 3])
    }

    func testMultiSelectSortIsDroppedAndPreservesInputOrder() {
        let t1 = Tag(id: 10, name: "Z")
        let t2 = Tag(id: 20, name: "A")
        let rows = [makeRef(id: 3), makeRef(id: 1), makeRef(id: 2)]
        let tagMap: [Int64: [Tag]] = [3: [t1], 1: [t2], 2: [t1, t2]]
        let ctx = PipelineContext(tagMap: tagMap)
        let sorts = [ViewSort(target: .builtin(.tags), ascending: true)]
        let out = SortEngine.apply(rows, sorts: sorts, context: ctx)
        // Multi-select sort is filtered out; with no effective sorts input order wins.
        XCTAssertEqual(out.map(\.id), [3, 1, 2])
    }

    func testMultiSelectSortSkippedButOtherSortStillApplies() {
        let rows = [
            makeRef(id: 1, year: 2020),
            makeRef(id: 2, year: 2024),
            makeRef(id: 3, year: 2022),
        ]
        let sorts = [
            ViewSort(target: .builtin(.tags), ascending: true),
            ViewSort(target: .builtin(.year), ascending: false),
        ]
        let out = SortEngine.apply(rows, sorts: sorts, context: context)
        XCTAssertEqual(out.map(\.id), [2, 3, 1])
    }
}
