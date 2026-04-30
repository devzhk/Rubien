import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

final class PDFUploadQueueTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testEnqueueInsertsRow() async throws {
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
        }
        let queue = PDFUploadQueue(db: db)
        try await queue.enqueue(referenceId: 1, localFilename: "abc.pdf")

        let count = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue WHERE referenceId=1") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testRemoveByReferenceIdDeletesRow() async throws {
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt) VALUES(1, 'x.pdf', ?)
            """, arguments: [Date()])
        }
        let queue = PDFUploadQueue(db: db)
        try await queue.remove(referenceId: 1)

        let count = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func testPendingReferenceIdsReturnsAllInQueueOrder() async throws {
        try await db.dbWriter.write { db in
            for i: Int64 in [1, 2, 3] {
                try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(?, 'r', ?, ?)", arguments: [i, Date(), Date()])
                try db.execute(sql: """
                    INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                    VALUES(?, ?, ?)
                """, arguments: [i, "f\(i).pdf", Date(timeIntervalSince1970: 1_000_000 + Double(i))])
            }
        }
        let queue = PDFUploadQueue(db: db)
        let ids = try await queue.pendingReferenceIds()
        XCTAssertEqual(ids, [1, 2, 3])
    }

    func testCountReturnsRowCount() async throws {
        let queue = PDFUploadQueue(db: db)
        let initialCount = try await queue.count()
        XCTAssertEqual(initialCount, 0)

        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO reference(id, title, dateAdded, dateModified) VALUES(1, 'r', ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt) VALUES(1, 'x.pdf', ?)
            """, arguments: [Date()])
        }
        let count = try await queue.count()
        XCTAssertEqual(count, 1)
    }
}
