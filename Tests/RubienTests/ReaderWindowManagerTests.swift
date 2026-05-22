#if os(macOS)
import Foundation
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

/// Verify both reader-open paths invoke the read-stamping side effect. The
/// PDF and Web call sites are separate code paths in `ReaderWindowManager`,
/// so testing one does not transitively prove the other — both need explicit
/// assertion that opening the reader bumps the reference's `readCount`.
@MainActor
final class ReaderWindowManagerTests: XCTestCase {

    override func tearDown() async throws {
        // Close any windows the test opened so the singleton doesn't carry
        // state between test methods.
        ReaderWindowManager.shared.closeAll()
    }

    // MARK: - Helper sanity check

    func testRecordReaderOpenStampsLastReadAtAndBumpsCount() throws {
        let db = try makeDatabase()
        let refId = try insertReference(in: db)

        ReaderWindowManager.shared.recordReaderOpen(referenceId: refId, db: db)

        let state = try waitForState(refId: refId, in: db) { $0.readCount == 1 }
        XCTAssertNotNil(state.lastReadAt, "recordReaderOpen must stamp lastReadAt")
        XCTAssertEqual(state.readCount, 1, "first stamp must bump readCount to 1")
    }

    func testRecordReaderOpenSilentlyTolerantOfMissingReference() throws {
        let db = try makeDatabase()
        // No exception thrown; the UPDATE matches zero rows.
        XCTAssertNoThrow(
            ReaderWindowManager.shared.recordReaderOpen(referenceId: 999_999, db: db)
        )
    }

    // MARK: - PDF reader path

    func testOpenPDFReaderStampsReadOnFreshOpen() throws {
        let db = try makeDatabase()
        let refId = try insertReference(in: db)
        try attachPDFCacheRow(refId: refId, in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openPDFReader(for: reference, db: db)

        let state = try waitForState(refId: refId, in: db) { $0.readCount == 1 }
        XCTAssertNotNil(state.lastReadAt, "openPDFReader must call recordReaderOpen on a fresh open")
        XCTAssertEqual(state.readCount, 1)
    }

    func testOpenPDFReaderEarlyReturnsWhenNoPDFCached() throws {
        let db = try makeDatabase()
        let refId = try insertReference(in: db)
        // Deliberately do NOT attach a PDF cache row.

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openPDFReader(for: reference, db: db)

        // Non-occurrence assertion: give the detached Task a moment to NOT
        // fire (the early-return path), then verify nothing was stamped.
        Thread.sleep(forTimeInterval: 0.1)
        let state = try readState(refId: refId, in: db)
        XCTAssertNil(state.lastReadAt, "no PDF → early return → no stamping")
        XCTAssertEqual(state.readCount, 0)
    }

    func testReopeningAlreadyOpenPDFWindowDoesNotRestamp() throws {
        let db = try makeDatabase()
        let refId = try insertReference(in: db)
        try attachPDFCacheRow(refId: refId, in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openPDFReader(for: reference, db: db)
        let firstState = try waitForState(refId: refId, in: db) { $0.readCount == 1 }

        ReaderWindowManager.shared.openPDFReader(for: reference, db: db)
        // Second open is a no-op; give the detached Task a moment to NOT
        // fire, then assert idempotency.
        Thread.sleep(forTimeInterval: 0.1)
        let secondState = try readState(refId: refId, in: db)

        XCTAssertEqual(secondState.readCount, firstState.readCount,
                       "refocusing an open PDF reader must not bump readCount")
        XCTAssertEqual(secondState.lastReadAt, firstState.lastReadAt,
                       "refocusing an open PDF reader must not re-advance lastReadAt")
    }

    // MARK: - Web reader path

    func testOpenWebReaderStampsReadOnFreshOpen() throws {
        let db = try makeDatabase()
        let refId = try insertWebpageReference(in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openWebReader(for: reference, db: db)

        let state = try waitForState(refId: refId, in: db) { $0.readCount == 1 }
        XCTAssertNotNil(state.lastReadAt, "openWebReader must call recordReaderOpen on a fresh open")
        XCTAssertEqual(state.readCount, 1)
    }

    func testOpenWebReaderEarlyReturnsWhenCannotOpen() throws {
        let db = try makeDatabase()
        // A plain journal-article reference is not webpage-eligible.
        let refId = try insertReference(in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openWebReader(for: reference, db: db)

        Thread.sleep(forTimeInterval: 0.1)
        let state = try readState(refId: refId, in: db)
        XCTAssertNil(state.lastReadAt, "non-webpage references → early return → no stamping")
        XCTAssertEqual(state.readCount, 0)
    }

    func testReopeningAlreadyOpenWebWindowDoesNotRestamp() throws {
        let db = try makeDatabase()
        let refId = try insertWebpageReference(in: db)

        let reference = try XCTUnwrap(try db.fetchReferences(ids: [refId]).first)
        ReaderWindowManager.shared.openWebReader(for: reference, db: db)
        let firstState = try waitForState(refId: refId, in: db) { $0.readCount == 1 }

        ReaderWindowManager.shared.openWebReader(for: reference, db: db)
        Thread.sleep(forTimeInterval: 0.1)
        let secondState = try readState(refId: refId, in: db)

        XCTAssertEqual(secondState.readCount, firstState.readCount,
                       "refocusing an open web reader must not bump readCount")
        XCTAssertEqual(secondState.lastReadAt, firstState.lastReadAt,
                       "refocusing an open web reader must not re-advance lastReadAt")
    }

    // MARK: - Polling helper

    /// Polls `readState` until `predicate` returns true or `timeout` elapses.
    /// Phase 3 dispatches `markReferenceRead` onto a detached Task, so reads
    /// immediately after `recordReaderOpen` race the write. Tests that
    /// observe the post-stamp state need to wait for it.
    private func waitForState(
        refId: Int64,
        in db: AppDatabase,
        timeout: TimeInterval = 1.0,
        until predicate: ((lastReadAt: Date?, readCount: Int)) -> Bool,
        line: UInt = #line
    ) throws -> (lastReadAt: Date?, readCount: Int) {
        let deadline = Date().addingTimeInterval(timeout)
        var last: (lastReadAt: Date?, readCount: Int) = (nil, 0)
        while Date() < deadline {
            last = try readState(refId: refId, in: db)
            if predicate(last) { return last }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("waitForState timed out; last observed state = \(last)", line: line)
        return last
    }

    // MARK: - Helpers

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func insertReference(in db: AppDatabase) throws -> Int64 {
        var ref = Reference(
            title: "Test",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            dateModified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try db.dbWriter.write { try ref.insert($0) }
        return try XCTUnwrap(ref.id)
    }

    private func insertWebpageReference(in db: AppDatabase) throws -> Int64 {
        var ref = Reference(
            title: "A webpage",
            url: "https://example.com/article",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            dateModified: Date(timeIntervalSince1970: 1_700_000_000),
            referenceType: .webpage
        )
        try db.dbWriter.write { try ref.insert($0) }
        let id = try XCTUnwrap(ref.id)
        XCTAssertTrue(ref.canOpenWebReader, "fixture must satisfy canOpenWebReader")
        return id
    }

    private func attachPDFCacheRow(refId: Int64, in db: AppDatabase) throws {
        let now = Date()
        try db.dbWriter.write { conn in
            try conn.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, 'test', 1, ?, ?)
            """, arguments: [refId, "test-\(refId).pdf", now, now])
        }
    }

    private func readState(refId: Int64, in db: AppDatabase) throws -> (lastReadAt: Date?, readCount: Int) {
        try db.dbWriter.read { conn in
            let row = try Row.fetchOne(
                conn,
                sql: "SELECT lastReadAt, readCount FROM reference WHERE id = ?",
                arguments: [refId]
            )!
            return (row["lastReadAt"] as Date?, row["readCount"] as Int)
        }
    }
}
#endif
