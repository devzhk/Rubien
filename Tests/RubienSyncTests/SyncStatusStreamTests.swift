import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

@available(macOS 14.0, iOS 17.0, *)
final class SyncStatusStreamTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() { db = nil; super.tearDown() }

    func testStatusStreamEmitsWhenPublishCalled() async throws {
        let library = SyncedLibrary(appDatabase: db)

        var iterator = await library.statusStream.makeAsyncIterator()

        await library.publishStatusForTest(.syncing)
        let first = await iterator.next()
        XCTAssertEqual(first, .syncing)

        await library.publishStatusForTest(.idle)
        let second = await iterator.next()
        XCTAssertEqual(second, .idle)
    }
}
