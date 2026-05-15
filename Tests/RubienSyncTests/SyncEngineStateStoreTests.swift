#if canImport(RubienSync)
import XCTest
import CloudKit
@testable import RubienSync

final class SyncEngineStateStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("rubien-test-\(UUID().uuidString).bin")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testLoadReturnsNilWhenMissing() {
        let store = SyncEngineStateStore(fileURL: tempURL)
        XCTAssertNil(
            store.load(),
            "fresh install (no sidecar) must signal 'start fresh' via nil, not crash"
        )
    }

    func testResetRemovesFile() throws {
        let store = SyncEngineStateStore(fileURL: tempURL)
        // Write a byte so reset has something to delete. We can't round-trip
        // a real State.Serialization without a live CloudKit account, so
        // just exercise the file-lifecycle plumbing.
        try Data([0xDE, 0xAD]).write(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        try store.reset()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempURL.path),
            "reset must delete the sidecar so a `sync reset` CLI command is a single-file operation"
        )
    }

    func testResetIsIdempotentOnMissingFile() throws {
        let store = SyncEngineStateStore(fileURL: tempURL)
        XCTAssertNoThrow(
            try store.reset(),
            "reset on a non-existent file must not throw — it's the 'already clean' state"
        )
    }
}
#endif
