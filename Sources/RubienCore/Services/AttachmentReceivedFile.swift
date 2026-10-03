import Foundation
import GRDB

/// A verified, journal-owned copy. Constructed only while holding the attachment
/// ownership lock; the receive callback uses it in the same database transaction.
public struct AttachmentReceivedFile: Sendable {
    public let operationID: String
    public let attachmentSyncId: String
    public let contentHash: String
    public let byteCount: Int64
    public let stagedPath: String
    public let finalPath: String
    public let stagedURL: URL
    fileprivate let finalURL: URL
    fileprivate let verifiedCachePath: String?

    public var relativePath: String { stagedURL == finalURL ? finalPath : stagedPath }
}

extension ReferenceAttachmentStore {
    /// Copy/hash before entering the writer. A failed callback retains the journal
    /// and bytes. Resume with its operationID, including after publication rolled back.
    public func withReceivedFile<T>(
        at source: URL, attachmentSyncId: String, contentHash: String, byteCount: Int64,
        resuming operationID: String? = nil,
        apply: (Database, AttachmentReceivedFile) throws -> T
    ) throws -> T {
        guard UUID(uuidString: attachmentSyncId)?.uuidString.lowercased() == attachmentSyncId,
              byteCount >= 0, byteCount <= ReferenceAttachmentKind.pdf.maximumBytes,
              contentHash.utf8.count == 64,
              contentHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ReferenceAttachmentError.integrityMismatch }
        return try withFileLock(wait: true) {
            let operation = operationID ?? UUID().uuidString.lowercased()
            guard UUID(uuidString: operation)?.uuidString.lowercased() == operation else {
                throw ReferenceAttachmentError.invalidPath
            }
            let stagedPath = "Attachments/.staging/\(operation)/received.asset"
            let finalPath = "Attachments/\(attachmentSyncId)/received-\(operation).asset"
            let staged = try managedURL(stagedPath)
            let final = try managedURL(finalPath)
            if operationID != nil {
                let matches = try database.dbWriter.read { db in
                    try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM attachmentFileJournal
                        WHERE operationId=? AND attachmentSyncId=? AND stagedPath=? AND finalPath=? AND purpose='receive')
                        """, arguments: [operation, attachmentSyncId, stagedPath, finalPath]) ?? false
                }
                guard matches else { throw ReferenceAttachmentError.invalidPath }
            } else {
                try database.dbWriter.write { db in
                    try db.execute(sql: """
                        INSERT INTO attachmentFileJournal(operationId, attachmentSyncId, stagedPath, finalPath, purpose, createdAt)
                        VALUES(?, ?, ?, ?, 'receive', ?)
                        """, arguments: [operation, attachmentSyncId, stagedPath, finalPath, Date()])
                }
            }
            let fm = FileManager.default
            let existing = fm.fileExists(atPath: final.path) ? final : staged
            let digest: (hash: String, count: Int64)
            if operationID != nil, fm.fileExists(atPath: existing.path) {
                let previous = try? Self.hash(existing, limit: byteCount)
                try Task<Never, Never>.checkCancellation()
                if let previous, previous.hash == contentHash, previous.count == byteCount {
                    digest = previous
                } else {
                    // A crash may leave a partial staging copy. Recopy only this
                    // journal's unpublished, unreferenced file; never truncate a
                    // cache- or quarantine-owned version to repair a retry.
                    let owned = try database.dbWriter.read { db in
                        try Bool.fetchOne(db, sql: """
                            SELECT EXISTS(SELECT 1 FROM syncOrphan WHERE stagedFilename=?)
                                OR EXISTS(SELECT 1 FROM attachmentCache WHERE relativePath=?)
                            """, arguments: [stagedPath, stagedPath]) ?? true
                    }
                    guard existing == staged, !owned, source.standardizedFileURL != staged.standardizedFileURL else {
                        throw ReferenceAttachmentError.integrityMismatch
                    }
                    digest = try Self.copyAndHash(source, to: staged, limit: byteCount)
                }
            } else {
                try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                digest = try Self.copyAndHash(source, to: staged, limit: byteCount)
            }
            guard digest.hash == contentHash, digest.count == byteCount else {
                throw ReferenceAttachmentError.integrityMismatch
            }
            // Keep an existing verified copy, especially one still owned by an upload.
            // Recheck its cache path in the transaction before deciding to reuse it.
            let verifiedURL = try? verifiedFileURL(syncId: attachmentSyncId)
            let cachePath = verifiedURL.map { String($0.path.dropFirst(libraryRoot.path.count + 1)) }
            let prepared = AttachmentReceivedFile(
                operationID: operation, attachmentSyncId: attachmentSyncId,
                contentHash: contentHash, byteCount: byteCount,
                stagedPath: stagedPath, finalPath: finalPath,
                stagedURL: fm.fileExists(atPath: final.path) ? final : staged,
                finalURL: final, verifiedCachePath: cachePath)
            let result = try database.dbWriter.write { db in try apply(db, prepared) }
            // Keep quarantine-owned files. The journal also makes failed cleanup retryable.
            let ownership = try database.dbWriter.read { db -> (quarantined: Bool, cached: Bool) in
                let quarantined = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM syncOrphan WHERE stagedFilename IN (?, ?))",
                                                     arguments: [stagedPath, finalPath]) ?? false
                let cached = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentCache WHERE relativePath=?)",
                                               arguments: [finalPath]) ?? false
                return (quarantined, cached)
            }
            if !ownership.quarantined {
                if !ownership.cached, fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                let stagingDirectory = staged.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: stagingDirectory.path).isEmpty) == true {
                    try fm.removeItem(at: stagingDirectory)
                }
                try database.dbWriter.write { db in
                    try db.execute(sql: "DELETE FROM attachmentFileJournal WHERE operationId=?", arguments: [operation])
                }
            }
            return result
        }
    }

    /// Publish only after scalar identity and removal checks, while the receive
    /// callback still holds ownership. Renaming is quick; copying/hashing already ran.
    public func publishReceivedFile(_ file: AttachmentReceivedFile, for parent: ReferenceAttachment, db: Database) throws {
        guard try managedURL(file.finalPath) == file.finalURL,
              [try managedURL(file.stagedPath), file.finalURL].contains(file.stagedURL) else {
            throw ReferenceAttachmentError.invalidPath
        }
        guard file.attachmentSyncId == parent.syncId, file.contentHash == parent.contentHash,
              file.byteCount == parent.byteCount else { throw ReferenceAttachmentError.integrityMismatch }
        guard parent.deletedAt == nil,
              try Bool.fetchOne(db, sql: """
                SELECT deletedAt IS NULL AND contentHash=? AND byteCount=?
                FROM referenceAttachment WHERE syncId=?
                """, arguments: [file.contentHash, file.byteCount, parent.syncId]) == true
        else { throw ReferenceAttachmentError.removed }
        if let path = file.verifiedCachePath,
           try String.fetchOne(db, sql: "SELECT relativePath FROM attachmentCache WHERE attachmentSyncId=?", arguments: [parent.syncId]) == path {
            return
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.finalURL.path) {
            try fm.createDirectory(at: file.finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: file.stagedURL, to: file.finalURL)
        }
        try db.execute(sql: """
            INSERT INTO attachmentCache(attachmentSyncId, relativePath, contentHash, materializedAt)
            VALUES(?, ?, ?, ?) ON CONFLICT(attachmentSyncId) DO UPDATE SET
                relativePath=excluded.relativePath, contentHash=excluded.contentHash, materializedAt=excluded.materializedAt
            """, arguments: [parent.syncId, file.finalPath, parent.contentHash, Date()])
    }
}
