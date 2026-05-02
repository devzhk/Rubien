import XCTest
@testable import RubienCore

final class FilterEngineTests: XCTestCase {

    private func makeRef(
        id: Int64,
        title: String = "Untitled",
        authors: [AuthorName] = [],
        year: Int? = nil,
        journal: String? = nil,
        readingStatus: ReadingStatus = .unread,
        referenceType: ReferenceType = .journalArticle,
        dateAdded: Date = Date()
    ) -> Reference {
        ReferenceFixtures.makeRef(
            id: id, title: title, authors: authors, year: year, journal: journal,
            readingStatus: readingStatus, referenceType: referenceType,
            dateAdded: dateAdded
        )
    }

    private var context: PipelineContext { PipelineContext() }

    // MARK: - Text operators

    func testTextEqualsCaseInsensitive() {
        let row = makeRef(id: 1, title: "Attention Is All You Need")
        let filter = ViewFilter(target: .builtin(.title), op: .equals, value: .text("attention is all you need"))
        XCTAssertTrue(FilterEngine.evaluate(filter, row: row, context: context))
    }

    func testTextContainsAndNotContains() {
        let row = makeRef(id: 1, title: "Attention Is All You Need")
        let contains = ViewFilter(target: .builtin(.title), op: .contains, value: .text("attention"))
        let notContains = ViewFilter(target: .builtin(.title), op: .notContains, value: .text("transformer"))
        XCTAssertTrue(FilterEngine.evaluate(contains, row: row, context: context))
        XCTAssertTrue(FilterEngine.evaluate(notContains, row: row, context: context))
    }

    func testTextStartsWithEndsWith() {
        let row = makeRef(id: 1, title: "Attention Is All You Need")
        let starts = ViewFilter(target: .builtin(.title), op: .startsWith, value: .text("Attention"))
        let ends = ViewFilter(target: .builtin(.title), op: .endsWith, value: .text("need"))
        XCTAssertTrue(FilterEngine.evaluate(starts, row: row, context: context))
        XCTAssertTrue(FilterEngine.evaluate(ends, row: row, context: context))
    }

    // MARK: - Number operators

    func testNumberComparisons() {
        let row = makeRef(id: 1, year: 2024)
        let gt = ViewFilter(target: .builtin(.year), op: .greaterThan, value: .number(2020))
        let ge = ViewFilter(target: .builtin(.year), op: .greaterOrEqual, value: .number(2024))
        let lt = ViewFilter(target: .builtin(.year), op: .lessThan, value: .number(2020))
        XCTAssertTrue(FilterEngine.evaluate(gt, row: row, context: context))
        XCTAssertTrue(FilterEngine.evaluate(ge, row: row, context: context))
        XCTAssertFalse(FilterEngine.evaluate(lt, row: row, context: context))
    }

    // MARK: - Date operators

    func testDateIsWithinLastNDays() {
        let now = Date()
        let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        let twentyDaysAgo = Calendar.current.date(byAdding: .day, value: -20, to: now)!
        let recent = makeRef(id: 1, dateAdded: fiveDaysAgo)
        let old = makeRef(id: 2, dateAdded: twentyDaysAgo)
        let ctx = PipelineContext(now: now)
        let filter = ViewFilter(target: .builtin(.dateAdded), op: .isWithin, value: .datePreset(.lastNDays(7)))
        XCTAssertTrue(FilterEngine.evaluate(filter, row: recent, context: ctx))
        XCTAssertFalse(FilterEngine.evaluate(filter, row: old, context: ctx))
    }

    // MARK: - Single-select operators

    func testSingleSelectEqualsAndIsAnyOf() {
        let row = makeRef(id: 1, readingStatus: .reading)
        let equals = ViewFilter(target: .builtin(.readingStatus), op: .equals, value: .selectKeys(["Reading"]))
        let anyOf = ViewFilter(target: .builtin(.readingStatus), op: .isAnyOf, value: .selectKeys(["Reading", "Read"]))
        let noneOf = ViewFilter(target: .builtin(.readingStatus), op: .isNoneOf, value: .selectKeys(["Reading", "Read"]))
        XCTAssertTrue(FilterEngine.evaluate(equals, row: row, context: context))
        XCTAssertTrue(FilterEngine.evaluate(anyOf, row: row, context: context))
        XCTAssertFalse(FilterEngine.evaluate(noneOf, row: row, context: context))
    }

    // MARK: - Multi-select (tags)

    func testTagsContainsAnyAndAll() {
        let row = makeRef(id: 1)
        let mlTag = Tag(id: 10, name: "ML")
        let llmTag = Tag(id: 20, name: "LLM")
        let tagMap: [Int64: [Tag]] = [1: [mlTag, llmTag]]
        let ctx = PipelineContext(tagMap: tagMap)

        let anyOf = ViewFilter(target: .builtin(.tags), op: .containsAnyOf, value: .selectKeys(["10", "99"]))
        let allOf = ViewFilter(target: .builtin(.tags), op: .containsAllOf, value: .selectKeys(["10", "20"]))
        let none = ViewFilter(target: .builtin(.tags), op: .containsNoneOf, value: .selectKeys(["99"]))
        let contains = ViewFilter(target: .builtin(.tags), op: .contains, value: .selectKeys(["10"]))

        XCTAssertTrue(FilterEngine.evaluate(anyOf, row: row, context: ctx))
        XCTAssertTrue(FilterEngine.evaluate(allOf, row: row, context: ctx))
        XCTAssertTrue(FilterEngine.evaluate(none, row: row, context: ctx))
        XCTAssertTrue(FilterEngine.evaluate(contains, row: row, context: ctx))
    }

    // MARK: - Checkbox

    func testPdfAttachedCheckbox() {
        // Post-B8: PDF presence is a per-device cache fact, not a Reference
        // property. The filter pipeline reads it from PipelineContext.
        let withPdf = makeRef(id: 1)
        let withoutPdf = makeRef(id: 2)
        let ctx = PipelineContext(pdfAttachedRefIds: [1])
        let checked = ViewFilter(target: .builtin(.pdfAttached), op: .isChecked, value: .none)
        let unchecked = ViewFilter(target: .builtin(.pdfAttached), op: .isUnchecked, value: .none)
        XCTAssertTrue(FilterEngine.evaluate(checked, row: withPdf, context: ctx))
        XCTAssertTrue(FilterEngine.evaluate(unchecked, row: withoutPdf, context: ctx))
    }

    // MARK: - Empty / not empty

    func testIsEmptyAndIsNotEmpty() {
        let noJournal = makeRef(id: 1, journal: nil)
        let hasJournal = makeRef(id: 2, journal: "Nature")
        let empty = ViewFilter(target: .builtin(.journal), op: .isEmpty, value: .none)
        let notEmpty = ViewFilter(target: .builtin(.journal), op: .isNotEmpty, value: .none)
        XCTAssertTrue(FilterEngine.evaluate(empty, row: noJournal, context: context))
        XCTAssertTrue(FilterEngine.evaluate(notEmpty, row: hasJournal, context: context))
        XCTAssertFalse(FilterEngine.evaluate(empty, row: hasJournal, context: context))
    }

    // MARK: - Multiple filters compose with AND

    func testMultipleFiltersAllMustMatch() {
        let rows = [
            makeRef(id: 1, year: 2024, readingStatus: .reading),
            makeRef(id: 2, year: 2024, readingStatus: .read),
            makeRef(id: 3, year: 2020, readingStatus: .reading),
        ]
        let filters: [ViewFilter] = [
            .init(target: .builtin(.year), op: .greaterOrEqual, value: .number(2024)),
            .init(target: .builtin(.readingStatus), op: .equals, value: .selectKeys(["Reading"])),
        ]
        let out = FilterEngine.apply(rows, filters: filters, context: context)
        XCTAssertEqual(out.map(\.id), [1])
    }

    func testEmptyFiltersReturnsAll() {
        let rows = (1...3).map { makeRef(id: Int64($0)) }
        XCTAssertEqual(FilterEngine.apply(rows, filters: [], context: context).count, 3)
    }

    // MARK: - Custom property

    func testCustomNumberProperty() {
        let row = makeRef(id: 1)
        let def = PropertyDefinition(id: 42, name: "Impact", type: .number)
        let ctx = PipelineContext(
            propertyValueMap: [1: [42: "7.5"]],
            propertyDefs: [def]
        )
        let filter = ViewFilter(target: .custom(42), op: .greaterThan, value: .number(5))
        XCTAssertTrue(FilterEngine.evaluate(filter, row: row, context: ctx))
    }

    func testContainsAllOfWithEmptyKeysReturnsFalse() {
        let row = makeRef(id: 1)
        let tagMap: [Int64: [Tag]] = [1: [Tag(id: 10, name: "ML")]]
        let filter = ViewFilter(target: .builtin(.tags), op: .containsAllOf, value: .selectKeys([]))
        XCTAssertFalse(FilterEngine.evaluate(filter, row: row, context: PipelineContext(tagMap: tagMap)))
    }

    func testContainsAnyOfWithEmptyKeysReturnsFalse() {
        let row = makeRef(id: 1)
        let tagMap: [Int64: [Tag]] = [1: [Tag(id: 10, name: "ML")]]
        let filter = ViewFilter(target: .builtin(.tags), op: .containsAnyOf, value: .selectKeys([]))
        XCTAssertFalse(FilterEngine.evaluate(filter, row: row, context: PipelineContext(tagMap: tagMap)))
    }

    func testNotEqualsOnNilValueReturnsFalse() {
        let row = makeRef(id: 1, journal: nil)
        let filter = ViewFilter(target: .builtin(.journal), op: .notEquals, value: .text("Nature"))
        // nil value can't be compared — notEquals returns false (same as equals).
        // isEmpty / isNotEmpty are the right operators for null checks.
        XCTAssertFalse(FilterEngine.evaluate(filter, row: row, context: context))
    }

    func testSelectOperatorOnNumberTargetReturnsFalse() {
        let row = makeRef(id: 1)  // year defaults to nil
        let filter = ViewFilter(target: .builtin(.year), op: .isAnyOf, value: .selectKeys(["2024"]))
        // year is a .number kind, so isAnyOf doesn't apply — evaluator rejects
        XCTAssertFalse(FilterEngine.evaluate(filter, row: row, context: context))
    }

    func testDateEqualsIsDayGranularity() {
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let evening = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        let row = makeRef(id: 1, dateAdded: morning)
        let filter = ViewFilter(target: .builtin(.dateAdded), op: .equals, value: .date(evening))
        // Same calendar day but different hours — .equals on date is day-granularity.
        XCTAssertTrue(FilterEngine.evaluate(filter, row: row, context: context))
    }

    func testCustomMultiSelectContainsAllOf() {
        let row = makeRef(id: 1)
        let def = PropertyDefinition(id: 50, name: "Topics", type: .multiSelect)
        let jsonValue = #"["ml","llm","transformers"]"#
        let ctx = PipelineContext(
            propertyValueMap: [1: [50: jsonValue]],
            propertyDefs: [def]
        )
        let filter = ViewFilter(target: .custom(50), op: .containsAllOf, value: .selectKeys(["ml", "llm"]))
        XCTAssertTrue(FilterEngine.evaluate(filter, row: row, context: ctx))
    }
}
