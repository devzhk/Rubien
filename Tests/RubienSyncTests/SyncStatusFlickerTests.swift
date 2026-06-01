#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, iOS 17.0, *)
final class SyncStatusFlickerTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() { db = nil; super.tearDown() }

    /// A manual fetch finishing while an automatic send is still in flight
    /// must NOT publish `.idle`. Expected emission order: .syncing, .syncing, .idle.
    func testFetchFinishingMidSendDoesNotPublishIdle() async {
        let library = SyncedLibrary(appDatabase: db)
        var iterator = await library.statusStream.makeAsyncIterator()

        await library.noteSend(inFlight: true)    // → .syncing
        await library.noteFetch(inFlight: true)   // → .syncing
        await library.noteFetch(inFlight: false)  // send still in flight → no emit
        await library.noteSend(inFlight: false)   // both quiescent → .idle

        let a = await iterator.next()
        let b = await iterator.next()
        let c = await iterator.next()
        XCTAssertEqual(a, .syncing)
        XCTAssertEqual(b, .syncing)
        XCTAssertEqual(c, .idle, "idle must only publish once BOTH fetch and send are done")
    }

    /// A standalone fetch cycle still resolves to idle.
    func testStandaloneFetchPublishesIdle() async {
        let library = SyncedLibrary(appDatabase: db)
        var iterator = await library.statusStream.makeAsyncIterator()

        await library.noteFetch(inFlight: true)   // → .syncing
        await library.noteFetch(inFlight: false)  // → .idle

        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .syncing)
        XCTAssertEqual(second, .idle)
    }
}
#endif
