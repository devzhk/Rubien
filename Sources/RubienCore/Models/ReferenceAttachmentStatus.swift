import Foundation
import GRDB

public struct ReferenceAttachmentTransferState: Sendable, Equatable {
    public let status: String
    public let error: String?

    /// Database-only lookup, suitable for observation without hashing file bytes.
    public static func fetch(_ db: Database, attachment: ReferenceAttachment) throws -> Self {
        if let error = try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='attachmentSyncError'") {
            return .init(status: "error", error: error)
        }
        guard try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='attachmentSyncEnabled'") == "1",
              let scope = try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='attachmentSyncScope'") else {
            return .init(status: "notEnabled", error: nil)
        }
        let id = attachment.syncId
        let failure = try String.fetchOne(db, sql: """
            SELECT error FROM attachmentSyncScope WHERE scopeID=? AND error IS NOT NULL
            UNION ALL SELECT error FROM attachmentDownload WHERE scopeID=? AND attachmentSyncId=? AND error IS NOT NULL
            UNION ALL SELECT error FROM attachmentRecovery WHERE scopeID=? AND parentSyncId=? AND error IS NOT NULL
            UNION ALL SELECT error FROM attachmentTransferError WHERE scopeID=? AND attachmentSyncId=?
            UNION ALL SELECT error FROM attachmentCleanup WHERE scopeID=? AND attachmentSyncId=? AND error IS NOT NULL LIMIT 1
            """, arguments: [scope,scope,id,scope,id,scope,id,scope,id])
        if let failure { return .init(status: "error", error: failure) }
        if try Bool.fetchOne(db, sql: "SELECT inventoryComplete FROM attachmentSyncScope WHERE scopeID=?", arguments: [scope]) != true {
            return .init(status: "catchingUp", error: nil)
        }
        if attachment.deletedAt != nil { return .init(status: "removed", error: nil) }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentDownload WHERE scopeID=? AND attachmentSyncId=?)", arguments: [scope,id]) == true {
            return .init(status: "pendingDownload", error: nil)
        }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM syncState WHERE isDirty=1 AND
              ((entityType IN ('referenceAttachment','attachmentAsset') AND entityId=?) OR
               (entityType='attachmentAnnotation' AND entityId IN (SELECT syncId FROM attachmentAnnotation WHERE attachmentSyncId=?))))
            OR EXISTS(SELECT 1 FROM attachmentUploadQueue WHERE attachmentSyncId=?)
            """, arguments: [id,id,id]) == true { return .init(status: "pendingUpload", error: nil) }
        let observed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachmentServerState WHERE scopeID=? AND entityId=? AND entityType IN ('referenceAttachment','attachmentAsset')", arguments: [scope,id]) ?? 0
        return .init(status: observed == 2 ? "synced" : "pendingUpload", error: nil)
    }
}

public struct ReferenceAttachmentStatus: Encodable, Sendable {
    public let attachment: ReferenceAttachment
    public let localAvailability: String
    public let pendingUpload: Bool
    public let syncStatus: String
    public let error: String?
}

extension ReferenceAttachmentStore {
    /// Verify bytes by default; lists check only existence, type, and size.
    public func status(syncId: String, verifyContents: Bool = true) throws -> ReferenceAttachmentStatus {
        let item = try attachment(syncId: syncId)
        let (pending, transfer) = try database.dbWriter.read { db in
            (try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentUploadQueue WHERE attachmentSyncId=?)", arguments: [syncId]) ?? false,
             try ReferenceAttachmentTransferState.fetch(db, attachment: item))
        }
        let availability: String
        var failure = transfer.error
        do {
            _ = try verifyContents ? verifiedFileURL(syncId: syncId) : locallyAvailableFileURL(syncId: syncId)
            availability = "available"
        } catch ReferenceAttachmentError.removed { availability = "removed" }
        catch ReferenceAttachmentError.unavailable {
            availability = "unavailable"
            if transfer.status != "pendingDownload" { failure = failure ?? ReferenceAttachmentError.unavailable.localizedDescription }
        } catch { availability = "error"; failure = failure ?? error.localizedDescription }
        return ReferenceAttachmentStatus(attachment: item, localAvailability: availability,
            pendingUpload: pending, syncStatus: transfer.status, error: failure)
    }

    /// Retry lookups/transfers in the active scope. This does not authorize
    /// recreating a missing, previously acknowledged annotation.
    public func retrySync(syncId: String) throws {
        _ = try attachment(syncId: syncId)
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncSession WHERE key='attachmentSyncError'")
            guard let scope = try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='attachmentSyncScope'") else { return }
            try db.execute(sql: "UPDATE attachmentSyncScope SET error=NULL WHERE scopeID=?", arguments: [scope])
            try db.execute(sql: "UPDATE attachmentDownload SET attempts=0,nextAttemptAt=NULL,error=NULL WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope,syncId])
            try db.execute(sql: "UPDATE attachmentRecovery SET error=NULL WHERE scopeID=? AND parentSyncId=?", arguments: [scope,syncId])
            try db.execute(sql: "DELETE FROM attachmentTransferError WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope,syncId])
            try db.execute(sql: "UPDATE attachmentQuarantineScope SET pendingReplay=1 WHERE scopeID=? AND (parentSyncId=? OR recordName=?)", arguments: [scope,syncId,"referenceAttachment:" + syncId])
            try db.execute(sql: "UPDATE attachmentCleanup SET error=NULL WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope,syncId])
        }
    }
}
