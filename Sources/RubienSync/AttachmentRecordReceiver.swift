#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import RubienCore

/// One receive boundary for normal fetch, inventory, and quarantine replay.
/// Live dispatch remains gated. Call inside the transaction that owns fetch progress.
struct AttachmentRecordReceiver {
    enum Outcome: Equatable {
        case applied
        case duplicate
        case removalQueued
        case suppressed
        case quarantined
    }

    private let state = SyncStateStore()

    /// File materialization is deliberately separate from the scalar outcome:
    /// a duplicate may repair missing bytes without acknowledging a pending save.
    func receive(
        _ record: CKRecord, db: Database,
        stagedFilename: String? = nil, replaying: Bool = false, drainRemovals: Bool = true,
        materialize: ((Database, ReferenceAttachment) throws -> Void)? = nil
    ) throws -> Outcome {
        guard let kind = AttachmentRecordKind.allCases.first(where: { $0.recordType == record.recordType }) else {
            throw ReceiveError.unsupportedRecord
        }
        if kind == .attachmentAsset, record["asset"] != nil, stagedFilename == nil {
            throw ReceiveError.missingAsset
        }
        var outcome: Outcome = .quarantined
        try db.inSavepoint {
            let alreadyApplying = try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='applyingRemote'")
            try state.setApplyingRemote(db)
            switch kind {
            case .referenceAttachment:
                outcome = try receiveMetadata(record, db: db)
            case .attachmentAnnotation:
                outcome = try receiveAnnotation(record, db: db)
            case .attachmentAsset:
                outcome = try receiveAsset(record, db: db, materialize: materialize)
            }
            if outcome == .quarantined || outcome == .suppressed {
                // The journal retains any prior staged version too. Cleanup must prove
                // ownership has ended before deleting either file.
                try AttachmentQuarantine.retain(record, scope: AttachmentSyncState.activeScope(db),
                    stagedFilename: stagedFilename, replaying: replaying, db: db)
            } else {
                try db.execute(sql: "DELETE FROM syncOrphan WHERE recordName=?", arguments: [record.recordID.recordName])
            }
            if kind == .attachmentAsset, let descriptor = AttachmentAssetRecord(record: record),
               let scope = try AttachmentSyncState.activeScope(db) {
                if materialize != nil, outcome == .applied || outcome == .duplicate {
                    try db.execute(sql: "DELETE FROM attachmentDownload WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope, descriptor.attachmentSyncId])
                } else if outcome != .suppressed {
                    try AttachmentSyncState.queueDownload(descriptor, scope: scope, db: db)
                }
            }
            if outcome != .quarantined {
                try AttachmentSyncState.observed(record, db: db)
                if let scope = try AttachmentSyncState.activeScope(db) {
                    let parentID = kind == .referenceAttachment ? kind.identity(in: record) : record["attachmentSyncId"] as? String
                    if let parentID { try AttachmentSyncState.requestRemoval(parentID, scope: scope, db: db) }
                }
            }
            if drainRemovals, let scope = try AttachmentSyncState.activeScope(db) {
                try AttachmentSyncState.drainRemovals(scope: scope, db: db)
            }
            if let alreadyApplying {
                try db.execute(sql: "UPDATE syncSession SET value=? WHERE key='applyingRemote'", arguments: [alreadyApplying])
            } else {
                try state.clearApplyingRemote(db)
            }
            return .commit
        }
        return outcome
    }

    /// Stages CloudKit's temporary asset before its callback lifetime ends. The
    /// journal and quarantine both survive a missing parent or failed transaction.
    func receiveAssetFile(_ record: CKRecord, store: ReferenceAttachmentStore, resuming operationID: String? = nil, scopeID: String? = nil, replaying: Bool = false) throws -> Outcome {
        guard let asset = AttachmentAssetRecord(record: record), let source = asset.assetURL else {
            throw ReceiveError.missingAsset
        }
        return try store.withReceivedFile(at: source, attachmentSyncId: asset.attachmentSyncId,
                                          contentHash: asset.contentHash, byteCount: asset.byteCount,
                                          resuming: operationID) { db, file in
            if let scopeID, try AttachmentSyncState.activeScope(db) != scopeID { throw CancellationError() }
            let retained = record.copy() as! CKRecord
            retained["asset"] = CKAsset(fileURL: file.stagedURL)
            return try receive(retained, db: db, stagedFilename: file.relativePath, replaying: replaying) { db, parent in
                try store.publishReceivedFile(file, for: parent, db: db)
            }
        }
    }

    private func receiveMetadata(_ record: CKRecord, db: Database) throws -> Outcome {
        guard var remote = ReferenceAttachment(record: record) else { return .quarantined }
        let kind = AttachmentRecordKind.referenceAttachment
        let local = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [remote.syncId])
        if let local {
            guard local.referenceSyncId == remote.referenceSyncId, local.kind == remote.kind,
                  local.originalFilename == remote.originalFilename, local.byteCount == remote.byteCount,
                  local.contentHash == remote.contentHash else { return .quarantined }
            remote.id = local.id
        }
        remote.referenceId = try Int64.fetchOne(db, sql: "SELECT id FROM reference WHERE syncId=?", arguments: [remote.referenceSyncId])
        let parentEvidence = try AttachmentSyncState.parentDeletionDate(remote.referenceSyncId, db: db)
        let ownEvidence = try Date.fetchOne(db, sql: "SELECT removalAcknowledgedAt FROM attachmentServerState WHERE scopeID=(SELECT value FROM syncSession WHERE key='attachmentSyncScope') AND entityType='referenceAttachment' AND entityId=?", arguments: [remote.syncId])
        let evidence = earliest(parentEvidence, ownEvidence)
        let removal = earliest(earliest(local?.deletedAt, remote.deletedAt), evidence)
        let needsSave = removal != remote.deletedAt
        // Removal takes precedence before duplicate detection, even for an old tag.
        if local != nil, removal == nil, try isDuplicate(record, kind: kind, id: remote.syncId, db: db) { return .duplicate }
        guard removal != nil || remote.referenceId != nil else { return .quarantined }
        if let removal {
            remote.deletedAt = removal
            if let local, local.deletedAt != nil {
                // A stale active rename must not refill a retained marker's fields.
                remote.displayName = local.displayName
            }
            remote.dateModified = max(remote.dateModified, local?.dateModified ?? remote.dateModified)
        }
        try remote.save(db)
        try acknowledge(record, kind: kind, id: remote.syncId, needsSave: needsSave, db: db)
        if removal != nil {
            try cancelChildSaves(remote.syncId, db: db)
        }
        if removal == nil, let scope = try AttachmentSyncState.activeScope(db),
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentCache WHERE attachmentSyncId=?)", arguments: [remote.syncId]) == false {
            try AttachmentSyncState.queueDownload(.init(attachmentSyncId: remote.syncId, contentHash: remote.contentHash, byteCount: remote.byteCount, assetURL: nil), scope: scope, db: db)
        }
        return needsSave ? .removalQueued : .applied
    }

    private func receiveAnnotation(_ record: CKRecord, db: Database) throws -> Outcome {
        guard var remote = ReferenceAttachmentAnnotation(record: record) else { return .quarantined }
        let kind = AttachmentRecordKind.attachmentAnnotation
        let local = try ReferenceAttachmentAnnotation.fetchOne(db, sql: "SELECT * FROM attachmentAnnotation WHERE syncId=?", arguments: [remote.syncId])
        if let local {
            guard local.attachmentSyncId == remote.attachmentSyncId, local.contentHash == remote.contentHash else { return .quarantined }
            remote.id = local.id
        }
        let parent = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [remote.attachmentSyncId])
        if let parent {
            guard parent.contentHash == remote.contentHash else { return .quarantined }
            if parent.deletedAt != nil { return .suppressed }
            remote.attachmentId = parent.id
        }
        let removal = earliest(local?.deletedAt, remote.deletedAt)
        let needsSave = removal != remote.deletedAt
        if removal == nil {
            if local != nil, try isDuplicate(record, kind: kind, id: remote.syncId, db: db) { return .duplicate }
            guard let parent else { return .quarantined }
            if let anchorKind = remote.anchorKind, ["pdf", "markdown"].contains(anchorKind), parent.kind != anchorKind {
                return .quarantined
            }
        } else {
            remote.deletedAt = removal
            remote.type = nil; remote.color = nil; remote.selectedText = nil; remote.noteText = nil
            remote.anchorKind = nil; remote.anchorVersion = nil; remote.anchorJSON = nil
            remote.dateModified = max(remote.dateModified, local?.dateModified ?? remote.dateModified)
        }
        try remote.save(db)
        try acknowledge(record, kind: kind, id: remote.syncId, needsSave: needsSave, db: db)
        return needsSave ? .removalQueued : .applied
    }

    private func receiveAsset(
        _ record: CKRecord, db: Database,
        materialize: ((Database, ReferenceAttachment) throws -> Void)?
    ) throws -> Outcome {
        guard let asset = AttachmentAssetRecord(record: record),
              let parent = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [asset.attachmentSyncId])
        else { return .quarantined }
        guard parent.contentHash == asset.contentHash, parent.byteCount == asset.byteCount else { return .quarantined }
        if parent.deletedAt != nil { return .suppressed }
        let duplicate = try isDuplicate(record, kind: .attachmentAsset, id: asset.attachmentSyncId, db: db)
        try materialize?(db, parent)
        if duplicate { return .duplicate }
        try acknowledge(record, kind: .attachmentAsset, id: asset.attachmentSyncId, needsSave: false, db: db)
        return .applied
    }

    private func earliest(_ local: Date?, _ remote: Date?) -> Date? {
        switch (local, remote) {
        case let (a?, b?): min(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    private func isDuplicate(_ record: CKRecord, kind: AttachmentRecordKind, id: String, db: Database) throws -> Bool {
        guard let tag = record.recordChangeTag,
              let data = try state.loadSystemFields(db, entityType: kind.entityType, entityId: id),
              let cached = SyncStateStore.rehydrateRecord(from: data),
              cached.recordID == record.recordID, cached.recordType == record.recordType,
              let cachedTag = cached.recordChangeTag else { return false }
        return tag == cachedTag
    }

    private func acknowledge(_ record: CKRecord, kind: AttachmentRecordKind, id: String, needsSave: Bool, db: Database) throws {
        try state.markPulled(db, entityType: kind.entityType, entityId: id, record: record)
        if needsSave { try state.queueSave(db, entityType: kind.entityType, entityId: id) }
    }

    private func cancelChildSaves(_ syncId: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM attachmentUploadQueue WHERE attachmentSyncId=?", arguments: [syncId])
        try db.execute(sql: """
            UPDATE syncState SET isDirty=0, pushInFlight=0
            WHERE (entityType='attachmentAsset' AND entityId=?)
                OR (entityType='attachmentAnnotation' AND entityId IN
                    (SELECT syncId FROM attachmentAnnotation WHERE attachmentSyncId=?))
            """, arguments: [syncId, syncId])
        // Retain child rows/files until marker acknowledgement can enqueue cleanup.
    }

    enum ReceiveError: Error { case unsupportedRecord, missingAsset }
}
#endif
