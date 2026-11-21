#if os(macOS)
import XCTest
import GRDB
@testable import Rubien
@testable import RubienCore

@MainActor
final class LibrarySearchScopeTests: XCTestCase {
    private let unreadOnly = ViewFilter(
        target: .builtin(.readingStatus), op: .equals, value: .selectKeys([ReadingStatus.unread])
    )
    private let since2024 = ViewFilter(
        target: .builtin(.year), op: .greaterOrEqual, value: .number(2024)
    )

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    @discardableResult
    private func save(
        _ db: AppDatabase,
        _ title: String,
        status: String = ReadingStatus.unread,
        year: Int? = nil,
        notes: String? = nil,
        addedSecondsAgo: TimeInterval = 0
    ) throws -> Reference {
        var reference = Reference(
            title: title,
            year: year,
            dateAdded: Date(timeIntervalSinceNow: -addedSecondsAgo),
            notes: notes,
            readingStatus: status
        )
        try db.saveReference(&reference)
        return reference
    }

    private func viewScope(_ scope: ReferenceScope = .all, filters: [ViewFilter]) -> LibrarySearchViewScope {
        LibrarySearchViewScope(
            name: "Reading list", icon: "tray", referenceScope: scope, filters: filters,
            tagMap: [:], propertyValueMap: [:], propertyDefs: []
        )
    }

    private func query(_ keyword: String, in contentScope: ReferenceSearchScope = .everything) -> ReferenceFilter {
        var filter = ReferenceFilter()
        filter.keyword = keyword
        filter.contentScope = contentScope
        return filter
    }

    // MARK: - Fetch and narrow

    func testThisViewAppliesViewFiltersAndLibraryDoesNot() throws {
        let db = try makeDB()
        let unread = try save(db, "Scaling laws for language models")
        let read = try save(db, "Scaling vision transformers", status: ReadingStatus.read)
        try save(db, "Unrelated paper")

        let inView = try librarySearchReferences(
            db: db, viewScope: viewScope(filters: [unreadOnly]), filter: query("scaling"), limit: 0
        )
        XCTAssertEqual(inView.map(\.id), [unread.id])

        let inLibrary = try librarySearchReferences(db: db, viewScope: nil, filter: query("scaling"), limit: 0)
        XCTAssertEqual(Set(inLibrary.map(\.id)), [unread.id, read.id])
    }

    func testTagScopedViewCombinesTagWithFilters() throws {
        let db = try makeDB()
        let taggedNew = try save(db, "Scaling A", year: 2025)
        let taggedOld = try save(db, "Scaling B", year: 2019)
        try save(db, "Scaling C", year: 2025)
        var tag = Tag(name: "Compute")
        try db.saveTag(&tag)
        let tagId = try XCTUnwrap(tag.id)
        try db.setTags(forReference: try XCTUnwrap(taggedNew.id), tagIds: [tagId])
        try db.setTags(forReference: try XCTUnwrap(taggedOld.id), tagIds: [tagId])

        let tagOnly = try librarySearchReferences(
            db: db, viewScope: viewScope(.tag(tagId), filters: []), filter: query("scaling"), limit: 0
        )
        XCTAssertEqual(Set(tagOnly.map(\.id)), [taggedNew.id, taggedOld.id])

        let tagAndYear = try librarySearchReferences(
            db: db, viewScope: viewScope(.tag(tagId), filters: [since2024]), filter: query("scaling"), limit: 0
        )
        XCTAssertEqual(tagAndYear.map(\.id), [taggedNew.id])
    }

    func testRecentCapIsAppliedAfterViewFilters() throws {
        let db = try makeDB()
        // The 20 newest references are read, so capping before filtering would
        // leave an "unread" view with no recent results at all.
        var unreadIDs: [Int64?] = []
        for index in 0..<25 {
            let isOld = index >= 20
            let reference = try save(
                db, "Paper \(index)",
                status: isOld ? ReadingStatus.unread : ReadingStatus.read,
                addedSecondsAgo: TimeInterval(index * 60)
            )
            if isOld { unreadIDs.append(reference.id) }
        }

        let recentInView = try librarySearchReferences(
            db: db, viewScope: viewScope(filters: [unreadOnly]), filter: query(""), limit: 20
        )
        XCTAssertEqual(recentInView.map(\.id), unreadIDs)

        let recentInLibrary = try librarySearchReferences(db: db, viewScope: nil, filter: query(""), limit: 20)
        XCTAssertEqual(recentInLibrary.count, 20)
    }

    func testNotesAndHighlightsResultsAreNarrowedByViewFilters() throws {
        let db = try makeDB()
        let unread = try save(db, "Paper one", notes: "Scaling compute budget")
        try save(db, "Paper two", status: ReadingStatus.read, notes: "Scaling data")
        try save(db, "Scaling in the title only")

        let results = try librarySearchReferences(
            db: db,
            viewScope: viewScope(filters: [unreadOnly]),
            filter: query("scaling", in: .notesAndHighlights),
            limit: 0
        )
        XCTAssertEqual(results.map(\.id), [unread.id])
    }

    func testTagFiltersResolveAgainstTheScopesTagMap() throws {
        let db = try makeDB()
        let tagged = try save(db, "Scaling A")
        let untagged = try save(db, "Scaling B")
        var tag = Tag(name: "Compute")
        try db.saveTag(&tag)
        let tagId = try XCTUnwrap(tag.id)
        let tagFilter = ViewFilter(target: .builtin(.tags), op: .contains, value: .selectKeys([String(tagId)]))
        let scope = LibrarySearchViewScope(
            name: "Compute", icon: "tag", referenceScope: .all, filters: [tagFilter],
            tagMap: [try XCTUnwrap(tagged.id): [tag]], propertyValueMap: [:], propertyDefs: []
        )

        let results = try librarySearchReferences(db: db, viewScope: scope, filter: query("scaling"), limit: 0)
        XCTAssertEqual(results.map(\.id), [tagged.id])
        XCTAssertFalse(results.contains { $0.id == untagged.id })
    }

    func testNarrowingKeepsRelevanceOrder() throws {
        let db = try makeDB()
        try save(db, "Scaling", addedSecondsAgo: 30)
        try save(db, "Scaling scaling scaling", addedSecondsAgo: 20)
        try save(db, "Scaling notes on scaling", status: ReadingStatus.read, addedSecondsAgo: 10)
        try save(db, "A long survey that mentions scaling once among many other words", addedSecondsAgo: 0)

        let library = try librarySearchReferences(db: db, viewScope: nil, filter: query("scaling"), limit: 0)
        let inView = try librarySearchReferences(
            db: db, viewScope: viewScope(filters: [unreadOnly]), filter: query("scaling"), limit: 0
        )
        XCTAssertEqual(inView.map(\.id), library.filter { $0.readingStatus == ReadingStatus.unread }.map(\.id))
        XCTAssertEqual(inView.count, 3)
    }

    func testOnlyATagScopeOrAFilterHidesReferences() {
        XCTAssertFalse(viewScope(.all, filters: []).hidesReferences)
        XCTAssertTrue(viewScope(.tag(1), filters: []).hidesReferences)
        XCTAssertTrue(viewScope(.all, filters: [unreadOnly]).hidesReferences)
    }

    // MARK: - Reveal routing

    func testOnlyResultsKnownToBeVisibleAreRevealedInPlace() {
        let filtered = viewScope(filters: [unreadOnly])
        let unfiltered = viewScope(filters: [])
        XCTAssertTrue(LibrarySearchScopeChoice.thisView.revealsInPlace(over: filtered))
        XCTAssertFalse(LibrarySearchScopeChoice.library.revealsInPlace(over: filtered))
        XCTAssertTrue(LibrarySearchScopeChoice.library.revealsInPlace(over: unfiltered))
        XCTAssertFalse(LibrarySearchScopeChoice.library.revealsInPlace(over: nil), "Home")
    }

    // MARK: - View model

    func testViewModelSearchScopeFollowsTheFiltersOnScreen() throws {
        let db = try makeDB()
        let vm = LibraryViewModel(db: db)
        XCTAssertEqual(vm.currentSearchViewScope?.hidesReferences, false)

        var view = DatabaseView(name: "Unread", icon: "tray", filters: [unreadOnly], displayOrder: 1)
        try db.saveDatabaseView(&view)
        vm.databaseViews = [view]
        vm.selectSidebar(.view(try XCTUnwrap(view.id)), stashCurrentDraft: false)

        let tagMap: [Int64: [Tag]] = [1: [Tag(id: 9, name: "Compute")]]
        vm.referenceTagMap = tagMap
        let saved = try XCTUnwrap(vm.currentSearchViewScope)
        XCTAssertEqual(saved.tagMap, tagMap, "Filters resolve against the table's lookup maps")
        XCTAssertEqual(saved.name, "Unread")
        XCTAssertEqual(saved.icon, "tray")
        XCTAssertEqual(saved.filters, [unreadOnly])
        XCTAssertTrue(saved.hidesReferences)

        // An unsaved draft is what the table shows, so it is what "This view" searches.
        vm.viewFilters = [since2024]
        XCTAssertEqual(vm.currentSearchViewScope?.filters, [since2024])

        vm.viewFilters = []
        XCTAssertEqual(vm.currentSearchViewScope?.hidesReferences, false)
    }

    func testAllReferencesWithAdHocFiltersAndOtherListTypes() throws {
        let db = try makeDB()
        let vm = LibraryViewModel(db: db)
        vm.viewFilters = [unreadOnly]
        let allReferences = try XCTUnwrap(vm.currentSearchViewScope)
        XCTAssertEqual(allReferences.name, "All References")
        XCTAssertTrue(allReferences.hidesReferences)

        var tag = Tag(name: "Compute")
        try db.saveTag(&tag)
        var tagView = DatabaseView(name: "Compute papers", scope: .tag(try XCTUnwrap(tag.id)), displayOrder: 1)
        try db.saveDatabaseView(&tagView)
        vm.databaseViews = [tagView]
        vm.selectSidebar(.view(try XCTUnwrap(tagView.id)), stashCurrentDraft: false)
        XCTAssertEqual(vm.currentSearchViewScope?.filters, [])
        XCTAssertEqual(vm.currentSearchViewScope?.hidesReferences, true)

        vm.selectSidebar(.titleKeyword("scaling"), stashCurrentDraft: false)
        XCTAssertNil(vm.currentSearchViewScope)
    }

    func testTagListAlwaysHidesReferences() throws {
        let db = try makeDB()
        let vm = LibraryViewModel(db: db)
        var tag = Tag(name: "Compute")
        try db.saveTag(&tag)
        vm.tags = [tag]
        vm.selectSidebar(.tag(try XCTUnwrap(tag.id)), stashCurrentDraft: false)

        let scope = try XCTUnwrap(vm.currentSearchViewScope)
        XCTAssertEqual(scope.name, "Compute")
        guard case .tag(let id) = scope.referenceScope else {
            return XCTFail("Expected a tag scope")
        }
        XCTAssertEqual(id, tag.id)
        XCTAssertTrue(scope.hidesReferences)
    }
}
#endif
