import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Holds managed files stable across reader lifetime or an asynchronous upload.
/// A shared library-wide lock also covers older cache paths retained by a reader.
public final class AttachmentFileLease: @unchecked Sendable {
    private let descriptor: Int32
    private let rootLease: LibraryRootLease

    init(root: URL) throws {
        rootLease = try LibraryRootLease(root: root)
        let directory = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".published.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReferenceAttachmentError.busy }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { close(fd); throw ReferenceAttachmentError.busy }
        descriptor = fd
    }

    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}

extension ReferenceAttachmentStore {
    public func acquireFileLease() throws -> AttachmentFileLease {
        _ = try managedURL("Attachments/.published.lock")
        return try AttachmentFileLease(root: libraryRoot)
    }

    /// The caller must first prove remote acknowledgement in its current scope.
    /// Refuse cleanup while any reader/upload holds a lease; the durable job retries.
    public func cleanRemovedFiles(syncId: String) throws {
        guard UUID(uuidString: syncId)?.uuidString.lowercased() == syncId else { throw ReferenceAttachmentError.invalidPath }
        try withFileLock(wait: true) {
            try withPublishedFiles(exclusive: true, wait: false) {
                let eligible = try database.dbWriter.read { db in
                    try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM referenceAttachment a
                        JOIN attachmentServerState s ON s.entityId=a.syncId AND s.entityType='referenceAttachment'
                        WHERE a.syncId=? AND a.deletedAt IS NOT NULL AND s.removalAcknowledgedAt IS NOT NULL
                          AND s.scopeID=(SELECT value FROM syncSession WHERE key='attachmentSyncScope'))
                        AND NOT EXISTS(SELECT 1 FROM attachmentUploadQueue WHERE attachmentSyncId=?)
                        """, arguments: [syncId, syncId]) ?? false
                }
                guard eligible else { return }
                let paths = try database.dbWriter.read { db -> [String] in
                    let rows = try Row.fetchAll(db, sql: "SELECT operationId,stagedPath,finalPath FROM attachmentFileJournal WHERE attachmentSyncId=?", arguments: [syncId])
                    return try rows.flatMap { row -> [String] in
                        let operation: String = row["operationId"]
                        let staged: String = row["stagedPath"], final: String = row["finalPath"]
                        guard UUID(uuidString: operation)?.uuidString.lowercased() == operation,
                              staged.hasPrefix("Attachments/.staging/" + operation + "/"),
                              final.hasPrefix("Attachments/" + syncId + "/") else { throw ReferenceAttachmentError.invalidPath }
                        for path in [staged, final] {
                            guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentCache WHERE relativePath=? AND attachmentSyncId<>?)", arguments: [path,syncId])! else { throw ReferenceAttachmentError.invalidPath }
                        }
                        return [staged, final]
                    }
                }
                let fm = FileManager.default
                // Cache/journal rows remain until all unlinks succeed. A crash simply
                // repeats missing-file-tolerant cleanup; retained metadata stays put.
                for path in paths {
                    let url = try managedURL(path)
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                }
                let directory = try managedURL("Attachments/" + syncId)
                if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
                try database.dbWriter.write { db in
                    try db.execute(sql: "DELETE FROM attachmentCache WHERE attachmentSyncId=?", arguments: [syncId])
                    try db.execute(sql: "DELETE FROM attachmentFileJournal WHERE attachmentSyncId=?", arguments: [syncId])
                    try db.execute(sql: "DELETE FROM attachmentCleanup WHERE attachmentSyncId=? AND scopeID=(SELECT value FROM syncSession WHERE key='attachmentSyncScope')", arguments: [syncId])
                }
            }
        }
    }
}
