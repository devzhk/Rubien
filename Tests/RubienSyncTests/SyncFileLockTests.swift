import XCTest
@testable import RubienSync

final class SyncFileLockTests: XCTestCase {

    private var lockFileURL: URL!

    override func setUp() {
        super.setUp()
        lockFileURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("rubien-test-lock-\(UUID().uuidString).lock")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: lockFileURL)
        super.tearDown()
    }

    func testLockFileIsCreatedOnInit() throws {
        _ = try SyncFileLock(fileURL: lockFileURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockFileURL.path),
            "lockfile must exist after open — other tools grep for it"
        )
    }

    func testTryLockReturnsFalseWhenHeldElsewhere() throws {
        let holder = try SyncFileLock(fileURL: lockFileURL)
        try holder.lockExclusive()

        // Same-process, different file descriptor on the same path.
        // flock's exclusion is per-file-description, so this is a
        // faithful stand-in for the app-vs-CLI racing case.
        let contender = try SyncFileLock(fileURL: lockFileURL)
        let acquired = try contender.tryLockExclusive()
        XCTAssertFalse(
            acquired,
            "CLI trying to run sync while the app holds the lock must back off, not block"
        )

        try holder.unlock()
        let afterRelease = try contender.tryLockExclusive()
        XCTAssertTrue(afterRelease, "lock must be re-acquirable after the prior holder unlocks")
    }

    func testUnlockIsIdempotent() throws {
        let lock = try SyncFileLock(fileURL: lockFileURL)
        try lock.lockExclusive()
        try lock.unlock()
        XCTAssertNoThrow(
            try lock.unlock(),
            "double-unlock must not throw — lifecycle code often pairs lock/unlock defensively"
        )
    }

    func testWithLockRunsBodyAndReleases() throws {
        let lock = try SyncFileLock(fileURL: lockFileURL)
        var didRun = false
        try lock.withLock {
            didRun = true
        }
        XCTAssertTrue(didRun)

        // Lock must be released on return; a fresh contender can now
        // acquire.
        let contender = try SyncFileLock(fileURL: lockFileURL)
        XCTAssertTrue(try contender.tryLockExclusive())
    }

    func testWithTryLockReturnsNilWhenHeld() throws {
        let holder = try SyncFileLock(fileURL: lockFileURL)
        try holder.lockExclusive()

        let contender = try SyncFileLock(fileURL: lockFileURL)
        let result = try contender.withTryLock { 42 }
        XCTAssertNil(result, "non-blocking variant must signal refusal via nil, not raise")
    }
}
