import Foundation
import GRDB
import RubienCore

/// Per-device queue of "PDFs not yet pushed to CloudKit." Drained by
/// `SyncedLibrary` when sync is enabled (Task 14 wires that up); until
/// then rows accumulate harmlessly and drain on next enable.
///
/// Local-only — the `pdfUploadQueue` DB table is never registered in
/// `SyncEntityType`, never observed by dirty-tracking triggers, never
/// has a CKRecord. State lives only on the device that imported the PDF.
public actor PDFUploadQueue {

    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    /// Enqueue a PDF for upload. Idempotent: re-enqueueing the same
    /// `referenceId` (e.g., the user re-imports the same paper) replaces
    /// the existing row and bumps `queuedAt` to now — newest write wins,
    /// the row slides to the back of the FIFO. The drainer sees one row
    /// per ref no matter how many times enqueue was called.
    public func enqueue(referenceId: Int64, localFilename: String) throws {
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                VALUES(?, ?, ?)
            """, arguments: [referenceId, localFilename, Date()])
        }
    }

    public func remove(referenceId: Int64) throws {
        try db.dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM pdfUploadQueue WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }
    }

    /// Reference IDs of all queued rows, oldest-queued first.
    public func pendingReferenceIds() throws -> [Int64] {
        try db.dbWriter.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT referenceId FROM pdfUploadQueue ORDER BY queuedAt ASC
            """)
        }
    }

    public func count() throws -> Int {
        try db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue") ?? 0
        }
    }
}
