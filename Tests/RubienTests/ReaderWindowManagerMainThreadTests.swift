#if os(macOS)
import XCTest
import GRDB
@testable import Rubien
@testable import RubienCore

/// Opening a PDF reader never synchronously blocks the main thread on a
/// dbWriter.write. The mark-read bookkeeping is dispatched onto a
/// background Task so a briefly-held writer queue (sync commits) doesn't
/// translate into a UI freeze on "tap to open."
@MainActor
final class ReaderWindowManagerMainThreadTests: XCTestCase {

    func testRecordReaderOpenReturnsImmediatelyEvenWhenWriterIsBusy() async throws {
        let db = try AppDatabase(DatabaseQueue())
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
        }

        // Synthetic writer-busy condition: occupy the writer queue with a
        // slow async write, then assert that recordReaderOpen returns before
        // it completes.
        let writerBusy = expectation(description: "writer-busy long task started")
        let writerDone = expectation(description: "writer-busy long task done")
        let blockerTask = Task.detached {
            try await db.dbWriter.write { db in
                writerBusy.fulfill()
                Thread.sleep(forTimeInterval: 0.4)
                try db.execute(sql: "UPDATE reference SET title='busy' WHERE id=1")
            }
            writerDone.fulfill()
        }
        await fulfillment(of: [writerBusy], timeout: 1.0)

        // Now invoke recordReaderOpen — it must return promptly.
        let start = Date()
        ReaderWindowManager.shared.recordReaderOpen(referenceId: 1, db: db)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05,
                          "recordReaderOpen must not synchronously wait on the writer queue (took \(elapsed)s)")

        // Drain the blocker so the test exits cleanly.
        await fulfillment(of: [writerDone], timeout: 2.0)
        try await blockerTask.value
    }
}
#endif
