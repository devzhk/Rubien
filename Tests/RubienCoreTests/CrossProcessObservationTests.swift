#if canImport(Combine) && canImport(Darwin)
import Combine
import GRDB
import XCTest
@testable import RubienCore

/// Two `DatabasePool` instances sharing one on-disk SQLite file simulates the
/// app+CLI pair. Each pool has its own `ValueObservation` plumbing — GRDB
/// observes commits on its own writer, so writes through pool B are invisible
/// to pool A's `ValueObservation`. `LibraryChangeBroadcaster` bridges the gap.
final class CrossProcessObservationTests: XCTestCase {
    private var tempDir: URL!
    private var dbPath: String!
    private var poolA: AppDatabase!
    private var poolB: AppDatabase!
    private var cancellables: Set<AnyCancellable>!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-xprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir.appendingPathComponent("library.sqlite").path

        // Pool A creates the schema; pool B reuses it. Using DatabasePool (not
        // DatabaseQueue) is essential — WAL mode is what lets two pools share
        // the same file, and what GRDB ValueObservation depends on.
        poolA = try AppDatabase(DatabasePool(path: dbPath))
        poolB = try AppDatabase(DatabasePool(path: dbPath))
        cancellables = []
    }

    override func tearDownWithError() throws {
        cancellables = nil
        poolA = nil
        poolB = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Tests

    /// Pins the GRDB cross-process limitation that motivates this whole feature:
    /// pool A's `ValueObservation` does not see writes that committed through
    /// pool B. If GRDB ever changes this (e.g. adds WAL polling), this test
    /// fails loudly so we know the broadcaster could be retired.
    ///
    /// Observes poolA's **raw** `ValueObservation` directly rather than
    /// `observeReferences()`. The latter merges in the process-wide
    /// `LibraryChangeBroadcaster`, whose Darwin-`notify` events can be delivered
    /// (coalesced / late) from elsewhere in the suite and land in this test's
    /// quiet window as a spurious second emission — the cause of this test's CI
    /// flakiness. Observing GRDB directly is exactly what this assertion is about
    /// and is deterministic; the broadcaster's own behavior is covered by
    /// `testTriggerLocalRefreshSurfacesCrossPoolWrites`.
    func testValueObservationDoesNotSeeCrossPoolWrites() throws {
        let initialEmission = expectation(description: "initial emission from poolA")
        let staleEmission = expectation(description: "no second emission within 500ms")
        staleEmission.isInverted = true

        var emissions: [[Reference]] = []
        ValueObservation
            .tracking { db in
                try Reference.order(Reference.Columns.dateAdded.desc).fetchAll(db)
            }
            .publisher(in: poolA.dbWriter, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { refs in
                    emissions.append(refs)
                    if emissions.count == 1 { initialEmission.fulfill() }
                    if emissions.count >= 2 { staleEmission.fulfill() }
                }
            )
            .store(in: &cancellables)

        wait(for: [initialEmission], timeout: 1)
        XCTAssertEqual(emissions.first?.count, 0, "expected initial empty snapshot")

        // Cross-pool write: this row lands on disk via poolB, but poolA's
        // ValueObservation observes only its own writer's commits, so it must
        // not re-emit.
        var ref = Reference(title: "Cross-pool write — should be invisible to poolA's ValueObservation")
        try poolB.saveReference(&ref)
        XCTAssertNotNil(ref.id)

        wait(for: [staleEmission], timeout: 0.5)
        XCTAssertEqual(emissions.count, 1, "ValueObservation must not emit for cross-pool writes")
    }

    /// The fix: after a cross-pool write, calling `triggerLocalRefresh()`
    /// causes poolA's merged publisher to re-fetch and emit the new state.
    /// `triggerLocalRefresh()` exercises the same downstream path the Darwin
    /// notify subscription drives, without depending on notify timing.
    func testTriggerLocalRefreshSurfacesCrossPoolWrites() throws {
        let initialEmission = expectation(description: "initial emission")
        let nudgedEmission = expectation(description: "post-nudge emission with new row")

        var emissions: [[Reference]] = []
        poolA.observeReferences()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { refs in
                    emissions.append(refs)
                    if emissions.count == 1 { initialEmission.fulfill() }
                    if emissions.count >= 2, refs.contains(where: { $0.title.contains("seen via broadcaster") }) {
                        nudgedEmission.fulfill()
                    }
                }
            )
            .store(in: &cancellables)

        wait(for: [initialEmission], timeout: 1)

        var ref = Reference(title: "seen via broadcaster")
        try poolB.saveReference(&ref)

        // Nudge: in production this is fired by `notify_register_dispatch`'s
        // callback when the CLI calls `notify_post`. Here we drive it directly
        // to keep the test deterministic.
        LibraryChangeBroadcaster.shared.triggerLocalRefresh()

        wait(for: [nudgedEmission], timeout: 2)
        XCTAssertEqual(emissions.last?.count, 1)
        XCTAssertEqual(emissions.last?.first?.title, "seen via broadcaster")
    }

    /// The merge helper debounces broadcaster events by 50ms before re-fetching.
    /// A burst of 50 nudges back-to-back must collapse to a single re-fetch
    /// emission — otherwise a chatty CLI loop would force the entire
    /// `ContentView` to re-fetch dozens of times per second.
    func testNudgeBurstCoalescesToSingleEmission() throws {
        let initialEmission = expectation(description: "initial emission")
        var emissions = 0
        poolA.observeReferences()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in
                    emissions += 1
                    if emissions == 1 { initialEmission.fulfill() }
                }
            )
            .store(in: &cancellables)

        wait(for: [initialEmission], timeout: 1)
        XCTAssertEqual(emissions, 1)

        // 50 nudges in a tight loop, all within the 50ms debounce window.
        for _ in 0..<50 {
            LibraryChangeBroadcaster.shared.triggerLocalRefresh()
        }

        // Wait past the debounce + a generous slack for the readPublisher
        // hop and main-queue delivery.
        let settled = expectation(description: "debounce window settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        XCTAssertLessThanOrEqual(emissions, 2,
            "Expected at most one debounced re-emission on top of the initial snapshot, got \(emissions)")
    }
}
#endif
