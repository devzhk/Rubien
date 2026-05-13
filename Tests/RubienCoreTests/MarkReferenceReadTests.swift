import XCTest
import GRDB
@testable import RubienCore

/// Tests for `AppDatabase.markReferenceRead(id:now:)`. The helper enforces three
/// rules: (1) `lastReadAt` always advances (monotonic, even under negative
/// clock skew); (2) `readCount` bumps on the first-ever read; (3) `readCount`
/// bumps again only after the 10-minute debounce window.
final class MarkReferenceReadTests: XCTestCase {

    private var db: AppDatabase!
    private var referenceId: Int64!

    override func setUpWithError() throws {
        db = try AppDatabase(DatabaseQueue())
        var ref = Reference(
            title: "Test",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            dateModified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try db.dbWriter.write { db in
            try ref.insert(db)
        }
        referenceId = ref.id
    }

    private func currentState() throws -> (lastReadAt: Date?, readCount: Int) {
        try db.dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT lastReadAt, readCount FROM reference WHERE id = ?",
                arguments: [self.referenceId!]
            )!
            return (row["lastReadAt"] as Date?, row["readCount"] as Int)
        }
    }

    func testFirstReadSetsBothFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.markReferenceRead(id: referenceId, now: now)

        let state = try currentState()
        XCTAssertEqual(state.lastReadAt, now)
        XCTAssertEqual(state.readCount, 1)
    }

    func testSecondReadWithinDebounceWindowAdvancesTimestampOnly() throws {
        let firstOpen = Date(timeIntervalSince1970: 1_700_000_000)
        try db.markReferenceRead(id: referenceId, now: firstOpen)

        // 5 minutes later — well inside the 10-minute debounce window.
        let secondOpen = firstOpen.addingTimeInterval(5 * 60)
        try db.markReferenceRead(id: referenceId, now: secondOpen)

        let state = try currentState()
        XCTAssertEqual(state.lastReadAt, secondOpen, "lastReadAt must advance even when count is debounced")
        XCTAssertEqual(state.readCount, 1, "readCount must NOT bump inside the 10-minute window")
    }

    func testSecondReadAfterDebounceWindowBumpsCount() throws {
        let firstOpen = Date(timeIntervalSince1970: 1_700_000_000)
        try db.markReferenceRead(id: referenceId, now: firstOpen)

        // Just past the 10-minute boundary.
        let secondOpen = firstOpen.addingTimeInterval(601)
        try db.markReferenceRead(id: referenceId, now: secondOpen)

        let state = try currentState()
        XCTAssertEqual(state.lastReadAt, secondOpen)
        XCTAssertEqual(state.readCount, 2, "readCount must bump once the 10-minute debounce elapses")
    }

    /// Exactly 600 seconds since the last read should NOT bump the count
    /// (the helper requires strictly > 600).
    func testCountDebounceBoundaryIsExclusive() throws {
        let firstOpen = Date(timeIntervalSince1970: 1_700_000_000)
        try db.markReferenceRead(id: referenceId, now: firstOpen)

        let boundaryOpen = firstOpen.addingTimeInterval(600)
        try db.markReferenceRead(id: referenceId, now: boundaryOpen)

        let state = try currentState()
        XCTAssertEqual(state.readCount, 1, "= 600s is still inside the debounce window")
    }

    /// A `now` that's earlier than the stored `lastReadAt` (clock skew or a peer
    /// that wrote a future-dated stamp) must NOT regress the column.
    func testClockSkewDoesNotRegressLastReadAt() throws {
        let futureStamp = Date(timeIntervalSince1970: 1_700_000_000 + 86_400) // +1d
        try db.markReferenceRead(id: referenceId, now: futureStamp)

        // Local clock claims "now" is one minute earlier — should keep the future stamp.
        let earlierNow = futureStamp.addingTimeInterval(-60)
        try db.markReferenceRead(id: referenceId, now: earlierNow)

        let state = try currentState()
        XCTAssertEqual(state.lastReadAt, futureStamp, "lastReadAt must be monotonic — never regress")
        XCTAssertEqual(state.readCount, 1, "skewed-earlier `now` counts as inside the debounce window")
    }

    /// Three reads across multiple debounce windows: count grows by 1 per window.
    func testMultipleWindowsAccumulateCount() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try db.markReferenceRead(id: referenceId, now: base)
        try db.markReferenceRead(id: referenceId, now: base.addingTimeInterval(700))
        try db.markReferenceRead(id: referenceId, now: base.addingTimeInterval(700 + 700))

        let state = try currentState()
        XCTAssertEqual(state.readCount, 3)
        XCTAssertEqual(state.lastReadAt, base.addingTimeInterval(1400))
    }

    /// Reading a nonexistent reference is a silent no-op (the underlying UPDATE
    /// matches no rows). `ReaderWindowManager` already gates on a resolved
    /// reference, but the helper must not blow up on a stale ID either.
    func testNonexistentReferenceIsSilentNoOp() throws {
        XCTAssertNoThrow(try db.markReferenceRead(id: 999_999, now: Date()))
    }
}
