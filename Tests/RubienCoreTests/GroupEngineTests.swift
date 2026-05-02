import XCTest
@testable import RubienCore

final class GroupEngineTests: XCTestCase {

    private func makeRef(
        id: Int64,
        readingStatus: String = ReadingStatus.unread,
        dateAdded: Date = Date()
    ) -> Reference {
        ReferenceFixtures.makeRef(id: id, title: "ref\(id)", readingStatus: readingStatus, dateAdded: dateAdded)
    }

    func testGroupBySingleSelect() {
        let rows = [
            makeRef(id: 1, readingStatus: ReadingStatus.reading),
            makeRef(id: 2, readingStatus: ReadingStatus.read),
            makeRef(id: 3, readingStatus: ReadingStatus.reading),
            makeRef(id: 4, readingStatus: ReadingStatus.unread),
        ]
        let config = GroupConfig(target: .builtin(.readingStatus))
        let buckets = GroupEngine.apply(rows, config: config, context: PipelineContext())
        let byKey = Dictionary(uniqueKeysWithValues: buckets.map { ($0.key, $0.references.map(\.id)) })
        XCTAssertEqual(byKey["Reading"], [1, 3])
        XCTAssertEqual(byKey["Read"], [2])
        XCTAssertEqual(byKey["Unread"], [4])
    }

    func testGroupByMultiSelectPlacesRefInEveryGroup() {
        let rows = [makeRef(id: 1), makeRef(id: 2)]
        let tagMap: [Int64: [Tag]] = [
            1: [Tag(id: 10, name: "ML"), Tag(id: 20, name: "LLM")],
            2: [Tag(id: 10, name: "ML")],
        ]
        let config = GroupConfig(target: .builtin(.tags))
        let buckets = GroupEngine.apply(rows, config: config, context: PipelineContext(tagMap: tagMap))
        let byKey = Dictionary(uniqueKeysWithValues: buckets.map { ($0.key, Set($0.references.map(\.id))) })
        XCTAssertEqual(byKey["10"], [1, 2])
        XCTAssertEqual(byKey["20"], [1])
    }

    func testGroupByDateYearBin() {
        let cal = Calendar.current
        let y2020 = cal.date(from: DateComponents(year: 2020, month: 6, day: 1))!
        let y2024 = cal.date(from: DateComponents(year: 2024, month: 3, day: 1))!
        let rows = [makeRef(id: 1, dateAdded: y2020), makeRef(id: 2, dateAdded: y2024), makeRef(id: 3, dateAdded: y2020)]
        let config = GroupConfig(target: .builtin(.dateAdded), dateBin: .year)
        let buckets = GroupEngine.apply(rows, config: config, context: PipelineContext())
        let keys = buckets.map(\.key)
        XCTAssertTrue(keys.contains("2020"))
        XCTAssertTrue(keys.contains("2024"))
    }

    func testEmptyValueGoesToEmptyBucket() {
        let row = makeRef(id: 1)
        let config = GroupConfig(target: .builtin(.journal))
        let buckets = GroupEngine.apply([row], config: config, context: PipelineContext())
        XCTAssertEqual(buckets.first?.key, "__empty__")
        XCTAssertEqual(buckets.first?.references.map(\.id), [1])
    }

    func testCustomOrderOverridesNatural() {
        let rows = [
            makeRef(id: 1, readingStatus: ReadingStatus.reading),
            makeRef(id: 2, readingStatus: ReadingStatus.read),
            makeRef(id: 3, readingStatus: ReadingStatus.unread),
        ]
        let config = GroupConfig(
            target: .builtin(.readingStatus),
            customOrder: ["Reading", "Unread", "Read"]
        )
        let buckets = GroupEngine.apply(rows, config: config, context: PipelineContext())
        XCTAssertEqual(buckets.map(\.key), ["Reading", "Unread", "Read"])
    }

    func testCheckboxGrouping() {
        // Post-B8: pdfAttached is a per-device cache fact carried via
        // PipelineContext.pdfAttachedRefIds, not on the Reference itself.
        let rows = [makeRef(id: 1), makeRef(id: 2)]
        let config = GroupConfig(target: .builtin(.pdfAttached))
        let ctx = PipelineContext(pdfAttachedRefIds: [2])
        let buckets = GroupEngine.apply(rows, config: config, context: ctx)
        let byKey = Dictionary(uniqueKeysWithValues: buckets.map { ($0.key, $0.references.map(\.id)) })
        XCTAssertEqual(byKey["false"], [1])
        XCTAssertEqual(byKey["true"], [2])
    }
}
