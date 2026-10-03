#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import RubienCore

/// Shared send/recovery handling for attachment records. Saves reuse
/// SyncStateStore's push-in-flight acknowledgement handshake.
struct AttachmentRecordWriter {
    private let state = SyncStateStore()

    func build(_ kind: AttachmentRecordKind, id: String, db: Database, asset: AttachmentAssetRecord? = nil) throws -> CKRecord? {
        guard try !state.hasTombstone(db, entityType: kind.entityType, entityId: id) else { return nil }
        let record: CKRecord
        if let data = try state.loadSystemFields(db, entityType: kind.entityType, entityId: id),
           let cached = SyncStateStore.rehydrateRecord(from: data) {
            guard cached.recordID.recordName == kind.recordName(id), cached.recordType == kind.recordType else {
                throw WriterError.invalidCachedIdentity
            }
            record = cached
        } else {
            record = kind.makeRecord(id)
        }
        switch kind {
        case .referenceAttachment:
            guard let item = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [id]),
                  item.deletedAt != nil || item.referenceId != nil else { return nil }
            item.populate(record: record)
        case .attachmentAsset:
            guard let item = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [id]),
                  item.deletedAt == nil, item.referenceId != nil,
                  let asset, asset.assetURL != nil, asset.attachmentSyncId == id,
                  item.contentHash == asset.contentHash, item.byteCount == asset.byteCount else { return nil }
            asset.populate(record: record)
        case .attachmentAnnotation:
            guard let item = try ReferenceAttachmentAnnotation.fetchOne(db, sql: "SELECT * FROM attachmentAnnotation WHERE syncId=?", arguments: [id]) else { return nil }
            let parent = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [item.attachmentSyncId])
            if let parent, parent.deletedAt != nil { return nil }
            guard item.deletedAt != nil || (parent != nil && parent?.contentHash == item.contentHash) else { return nil }
            item.populate(record: record)
        }
        guard try state.markPushInFlight(db, entityType: kind.entityType, entityId: id) else { return nil }
        return record
    }

    /// A local mutation during upload resets pushInFlight through the v15 triggers.
    /// In that race markPushed preserves the newer dirty payload and caches this tag.
    func acknowledge(_ record: CKRecord, kind: AttachmentRecordKind, db: Database) throws {
        guard let id = kind.identity(in: record) else { throw WriterError.invalidCachedIdentity }
        try AttachmentSyncState.observed(record, db: db)
        if let scope = try AttachmentSyncState.activeScope(db) { try AttachmentSyncState.drainRemovals(scope: scope, db: db) }
        if kind != .referenceAttachment {
            let parentID = kind == .attachmentAsset ? id : record["attachmentSyncId"] as? String
            guard let parentID else { throw WriterError.invalidCachedIdentity }
            let removed = try Bool.fetchOne(db, sql: "SELECT deletedAt IS NOT NULL FROM referenceAttachment WHERE syncId=?", arguments: [parentID])
            if removed == true { return } // Parent cleanup will delete the raced child save.
        }
        if kind == .attachmentAsset, let scope = try AttachmentSyncState.activeScope(db) {
            try db.execute(sql: "DELETE FROM attachmentTransferError WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope,id])
        }
        try state.markPushed(db, entityType: kind.entityType, entityId: id, record: record)
        if kind == .attachmentAsset,
           try Bool.fetchOne(db, sql: "SELECT isDirty=0 FROM syncState WHERE entityType=? AND entityId=?", arguments: [kind.rawValue, id]) == true {
            try db.execute(sql: "DELETE FROM attachmentUploadQueue WHERE attachmentSyncId=? AND contentHash=?",
                           arguments: [id, record["contentHash"] as? String])
        }
    }

    enum Lookup {
        case failed, absent
        case found(CKRecord)
    }
    enum Recovery: Equatable { case retryNew, merged, deferRetry, cancel, preserveMissingAcknowledgedAnnotation }

    /// unknownItem requires fresh parent evidence. Failed reads never authorize a
    /// recreate; an acknowledged annotation missing under an active parent is kept
    /// for recovery rather than silently published again under its removed UUID.
    func recoverMissingChild(
        _ kind: AttachmentRecordKind, id: String, parentID: String,
        previouslyAcknowledged: Bool, parent: Lookup, child: Lookup, db: Database
    ) throws -> Recovery {
        guard kind == .attachmentAsset || kind == .attachmentAnnotation else { return .deferRetry }
        if kind == .attachmentAnnotation {
            guard try String.fetchOne(db, sql: "SELECT attachmentSyncId FROM attachmentAnnotation WHERE syncId=?", arguments: [id]) == parentID else {
                return .cancel
            }
        } else if id != parentID {
            return .cancel
        }
        guard case .found(let parentRecord) = parent,
              let metadata = ReferenceAttachment(record: parentRecord), metadata.syncId == parentID else { return .deferRetry }
        let receiver = AttachmentRecordReceiver()
        let parentOutcome = try receiver.receive(parentRecord, db: db)
        guard parentOutcome != .quarantined else { return .deferRetry }
        if try Bool.fetchOne(db, sql: "SELECT deletedAt IS NOT NULL FROM referenceAttachment WHERE syncId=?", arguments: [parentID]) == true { return .cancel }
        switch child {
        case .failed: return .deferRetry
        case .found(let record):
            guard kind.identity(in: record) == id,
                  record["attachmentSyncId"] as? String == parentID else { return .deferRetry }
            // Assets with bytes must go through the staged-file receive path.
            if kind == .attachmentAsset, (record["asset"] as? CKAsset)?.fileURL != nil { return .deferRetry }
            let outcome = try receiver.receive(record, db: db)
            return outcome == .quarantined ? .deferRetry : .merged
        case .absent:
            if kind == .attachmentAnnotation && previouslyAcknowledged { return .preserveMissingAcknowledgedAnnotation }
            return .retryNew
        }
    }

    enum WriterError: Error { case invalidCachedIdentity }
}
#endif
