#if os(macOS)
import XCTest
import Combine
import GRDB
@testable import Rubien
@testable import RubienCore

/// Bursty writes to the `reference` table during sync apply commit one row at
/// a time. Without throttling, every commit triggers a fresh
/// `fetchReferences` + a `@Published references` assignment on main, which
/// starves the PDF reader window's draw cycle.
///
/// This test commits 20 rows in rapid succession and asserts
/// `LibraryViewModel.$references` delivers no more than 4 emissions in the
/// ~600 ms window after the burst — i.e. the 150 ms throttle (applied inside
/// `rebuildReferenceObserver`) has coalesced the burst.
@MainActor
final class LibraryViewModelThrottleTests: XCTestCase {

    func testReselectingCurrentSidebarDoesNotRebuildReferenceObserver() async throws {
        let db = try AppDatabase(DatabaseQueue())
        try await db.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, ?, ?, ?)",
                arguments: [1, "seed", Date(), Date()]
            )
        }

        let vm = LibraryViewModel(db: db)
        var cancellables = Set<AnyCancellable>()
        let primed = expectation(description: "view-model primed")
        vm.$references
            .filter { $0.count == 1 }
            .prefix(1)
            .sink { _ in primed.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [primed], timeout: 2.0)

        // Let the initial throttle window close before observing navigation work.
        try await Task.sleep(for: .milliseconds(250))
        var subsequentEmissions = 0
        vm.$references
            .dropFirst()
            .sink { _ in subsequentEmissions += 1 }
            .store(in: &cancellables)
        var sidebarEmissions = 0
        vm.$selectedSidebar
            .dropFirst()
            .sink { _ in sidebarEmissions += 1 }
            .store(in: &cancellables)

        vm.selectSidebar(vm.selectedSidebar, stashCurrentDraft: false)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            subsequentEmissions,
            0,
            "reselecting the active library row must not cancel and recreate its database observation"
        )
        XCTAssertEqual(
            sidebarEmissions,
            0,
            "reselecting the active library row must not invalidate the entire view hierarchy"
        )
    }

    func testReselectingSavedViewRebuildsObserverWhenSyncedScopeChanged() async throws {
        let db = try AppDatabase(DatabaseQueue())
        try await db.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, ?, ?, ?)",
                arguments: [1, "seed", Date(), Date()]
            )
        }

        let vm = LibraryViewModel(db: db)
        vm.databaseViews = [DatabaseView(id: 42, name: "Synced view", scope: .all)]
        vm.selectSidebar(.view(42), stashCurrentDraft: false)

        let primed = expectation(description: "all-scope observer primed")
        var cancellables = Set<AnyCancellable>()
        vm.$references
            .filter { $0.count == 1 }
            .prefix(1)
            .sink { _ in primed.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [primed], timeout: 2.0)

        vm.databaseViews = [DatabaseView(id: 42, name: "Synced view", scope: .tag(99))]
        let narrowed = expectation(description: "tag-scope observer rebuilt")
        vm.$references
            .dropFirst()
            .filter(\.isEmpty)
            .prefix(1)
            .sink { _ in narrowed.fulfill() }
            .store(in: &cancellables)

        vm.selectSidebar(vm.selectedSidebar, stashCurrentDraft: false)
        await fulfillment(of: [narrowed], timeout: 2.0)
    }

    func testReturningFromHomeAdoptsRemoteSavedViewConfigurationWithoutLocalDraft() throws {
        let vm = LibraryViewModel(db: try AppDatabase(DatabaseQueue()))
        vm.databaseViews = [DatabaseView(id: 42, name: "Synced view")]
        vm.selectSidebar(.view(42), stashCurrentDraft: false)
        vm.stashCurrentViewDraft()

        let remoteFilter = ViewFilter(
            target: .builtin(.title),
            op: .contains,
            value: .text("remote")
        )
        vm.databaseViews = [DatabaseView(
            id: 42,
            name: "Synced view",
            filters: [remoteFilter]
        )]

        vm.selectSidebar(.view(42), stashCurrentDraft: false)

        XCTAssertEqual(vm.viewFilters, [remoteFilter])
    }

    func testReturningFromHomePreservesGenuineLocalSavedViewDraft() throws {
        let vm = LibraryViewModel(db: try AppDatabase(DatabaseQueue()))
        vm.databaseViews = [DatabaseView(id: 42, name: "Synced view")]
        vm.selectSidebar(.view(42), stashCurrentDraft: false)
        let localFilter = ViewFilter(
            target: .builtin(.title),
            op: .contains,
            value: .text("local")
        )
        vm.viewFilters = [localFilter]
        vm.stashCurrentViewDraft()

        let remoteFilter = ViewFilter(
            target: .builtin(.title),
            op: .contains,
            value: .text("remote")
        )
        vm.databaseViews = [DatabaseView(
            id: 42,
            name: "Synced view",
            filters: [remoteFilter]
        )]

        vm.selectSidebar(.view(42), stashCurrentDraft: false)

        XCTAssertEqual(vm.viewFilters, [localFilter])
    }

    func testReferenceObserverCoalescesBurstyCommits() async throws {
        let db = try AppDatabase(DatabaseQueue())
        var cancellables = Set<AnyCancellable>()

        // Seed an initial row so the view-model primes the observer with a
        // non-empty fetch.
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, ?, ?, ?)",
                           arguments: [1, "seed", Date(), Date()])
        }

        let vm = LibraryViewModel(db: db)

        // Wait for the view-model's initial emission (which seeds
        // `references` with the row above). We can't use `dropFirst()` here
        // because `LibraryViewModel.init -> setupObservation` may have
        // synchronously assigned to `references` before our `sink` attaches,
        // which would cause `dropFirst()` to skip the seed-row notification
        // and `primed` to time out. Instead, fulfill on the first emission
        // that matches the post-seed count of 1.
        let primed = expectation(description: "view-model primed with seed row")
        var primedOnce = false
        var emissionCount = 0
        let countLock = NSLock()
        vm.$references
            .sink { refs in
                countLock.lock()
                let alreadyPrimed = primedOnce
                if alreadyPrimed { emissionCount += 1 }
                countLock.unlock()
                if !alreadyPrimed, refs.count == 1 {
                    countLock.lock(); primedOnce = true; countLock.unlock()
                    primed.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [primed], timeout: 2.0)

        // Burst: 20 sequential single-row commits.
        for i in 2...21 {
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, ?, ?, ?)",
                               arguments: [i, "row\(i)", Date(), Date()])
            }
        }

        // Wait long enough for any throttle window (150 ms) plus scheduling
        // slack to close. 600 ms upper-bounds ~4 throttle windows.
        try await Task.sleep(nanoseconds: 600_000_000)

        countLock.lock(); let observed = emissionCount; countLock.unlock()
        XCTAssertLessThanOrEqual(observed, 4,
                                 "burst of 20 commits should coalesce into ≤ 4 emissions; got \(observed)")
        XCTAssertGreaterThanOrEqual(observed, 1,
                                    "throttle must still deliver at least one update")
        XCTAssertEqual(vm.references.count, 21,
                       "after the throttle window settles, the final value must include every committed row")
    }
}
#endif
