#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import RubienCore

struct AttachmentSyncScope: Sendable, Equatable {
    let account: String
    let environment: String
    let zoneName: String
    let zoneOwner: String
    static let featureVersion = 1

    init(account: String, environment: String, zone: CKRecordZone.ID = SyncConstants.libraryZoneID) {
        self.account = account; self.environment = environment
        zoneName = zone.zoneName; zoneOwner = zone.ownerName
    }
    var id: String {
        // Length prefixes avoid collisions without persisting credentials or tokens.
        [SyncConstants.containerIdentifier, account, environment, zoneOwner, zoneName, String(Self.featureVersion)]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

enum AttachmentSyncState {
    static func activeScope(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='attachmentSyncScope'")
    }

    static func activate(_ scope: AttachmentSyncScope, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO attachmentSyncScope(scopeID, accountID, environment, zoneName, zoneOwner, featureVersion)
            VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(scopeID) DO NOTHING
            """, arguments: [scope.id, scope.account, scope.environment, scope.zoneName, scope.zoneOwner, AttachmentSyncScope.featureVersion])
        let old = try activeScope(db)
        if let old, old != scope.id {
            // Server tags belong to one account/environment. Local payloads and
            // markers survive; the new inventory establishes the new server base.
            try db.execute(sql: """
                UPDATE syncState SET systemFields=NULL, lastPushedAt=NULL, isDirty=1, pushInFlight=0
                WHERE entityType IN ('referenceAttachment','attachmentAsset','attachmentAnnotation')
                """)
        }
        if old != scope.id {
            try db.execute(sql: "INSERT INTO attachmentRemovalWork(scopeID,attachmentSyncId) SELECT ?,syncId FROM referenceAttachment WHERE deletedAt IS NOT NULL ON CONFLICT(scopeID,attachmentSyncId) DO NOTHING", arguments: [scope.id])
        }
        try db.execute(sql: "INSERT INTO syncSession(key,value) VALUES('attachmentSyncEnabled','1') ON CONFLICT(key) DO UPDATE SET value='1'")
        try db.execute(sql: "INSERT INTO syncSession(key,value) VALUES('attachmentSyncScope',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [scope.id])
    }

    static func observed(_ record: CKRecord, db: Database) throws {
        guard let scope = try activeScope(db),
              let kind = AttachmentRecordKind.allCases.first(where: { $0.recordType == record.recordType }),
              let id = kind.identity(in: record) else { return }
        let removed: Date?
        switch kind {
        case .referenceAttachment: removed = ReferenceAttachment(record: record)?.deletedAt
        case .attachmentAnnotation: removed = ReferenceAttachmentAnnotation(record: record)?.deletedAt
        case .attachmentAsset: removed = nil
        }
        try db.execute(sql: """
            INSERT INTO attachmentServerState(scopeID,entityType,entityId,observedAt,removalAcknowledgedAt)
            VALUES(?,?,?,?,?) ON CONFLICT(scopeID,entityType,entityId) DO UPDATE SET
                observedAt=excluded.observedAt,
                removalAcknowledgedAt=COALESCE(attachmentServerState.removalAcknowledgedAt,excluded.removalAcknowledgedAt)
            """, arguments: [scope, kind.rawValue, id, Date(), removed])
        if kind != .referenceAttachment {
            try db.execute(sql: "UPDATE attachmentServerState SET physicalDeletedAt=NULL,observationVersion=observationVersion+1 WHERE scopeID=? AND entityType=? AND entityId=?", arguments: [scope,kind.rawValue,id])
        }
        if kind == .referenceAttachment, removed != nil { try requestRemoval(id, scope: scope, db: db) }
        if kind != .referenceAttachment, let parent = record["attachmentSyncId"] as? String,
           try Bool.fetchOne(db, sql: "SELECT removalAcknowledgedAt IS NOT NULL FROM attachmentServerState WHERE scopeID=? AND entityType='referenceAttachment' AND entityId=?", arguments: [scope,parent]) == true {
            // A child observed after a confirmed delete is new positive evidence
            // that physical cleanup must run again, even if its tombstone is retained.
            try SyncStateStore().queueDelete(db, entityType: kind.entityType, entityId: id)
            try requestRemoval(parent, scope: scope, db: db)
        }
    }

    static func wasObserved(_ kind: AttachmentRecordKind, id: String, scope: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentServerState WHERE scopeID=? AND entityType=? AND entityId=?)",
                          arguments: [scope, kind.rawValue, id]) ?? false
    }

    static func referenceDeleted(_ id: String, scope: String, date: Date = Date(), db: Database) throws {
        try db.execute(sql: "INSERT INTO attachmentReferenceDeletion(scopeID,referenceSyncId,deletedAt) VALUES(?,?,?) ON CONFLICT(scopeID,referenceSyncId) DO NOTHING",
                       arguments: [scope, id, date])
        try db.execute(sql: "UPDATE attachmentQuarantineScope SET pendingReplay=1 WHERE scopeID=? AND parentSyncId=?", arguments: [scope,id])
        let children = try String.fetchAll(db, sql: "SELECT syncId FROM referenceAttachment WHERE referenceSyncId=?", arguments: [id])
        for child in children {
            try db.execute(sql: "UPDATE referenceAttachment SET deletedAt=COALESCE(deletedAt,?),dateModified=? WHERE syncId=?", arguments: [date, date, child])
            try SyncStateStore().queueSave(db, entityType: .referenceAttachment, entityId: child)
            try requestRemoval(child, scope: scope, db: db)
        }
    }

    static func parentDeletionDate(_ referenceID: String, db: Database) throws -> Date? {
        guard let scope = try activeScope(db) else { return nil }
        return try Date.fetchOne(db, sql: "SELECT deletedAt FROM attachmentReferenceDeletion WHERE scopeID=? AND referenceSyncId=?", arguments: [scope, referenceID])
    }

    static func requestRemoval(_ id: String, scope: String, db: Database) throws {
        try db.execute(sql: "INSERT INTO attachmentRemovalWork(scopeID,attachmentSyncId) SELECT ?,syncId FROM referenceAttachment WHERE syncId=? AND deletedAt IS NOT NULL ON CONFLICT(scopeID,attachmentSyncId) DO NOTHING", arguments: [scope,id])
    }

    static func drainRemovals(scope: String, db: Database) throws {
        let ids = try String.fetchAll(db, sql: "SELECT attachmentSyncId FROM attachmentRemovalWork WHERE scopeID=? LIMIT 200", arguments: [scope])
        for id in ids {
            try db.execute(sql: "DELETE FROM attachmentRemovalWork WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope,id])
            try reconcileRemoval(id, scope: scope, db: db)
        }
    }

    struct DeleteAttempt: Sendable, Equatable {
        let scope: String
        let observationVersion: Int64
    }

    static func deleteAttempt(_ type: SyncEntityType, id: String, db: Database) throws -> DeleteAttempt? {
        guard type == .attachmentAsset || type == .attachmentAnnotation,
              let scope = try activeScope(db) else { return nil }
        let version = try Int64.fetchOne(db, sql: "SELECT observationVersion FROM attachmentServerState WHERE scopeID=? AND entityType=? AND entityId=?", arguments: [scope,type.rawValue,id]) ?? 0
        return DeleteAttempt(scope: scope, observationVersion: version)
    }

    static func physicalDeleteConfirmed(_ type: SyncEntityType, id: String, db: Database) throws {
        guard type == .attachmentAsset || type == .attachmentAnnotation, let scope = try activeScope(db) else { return }
        try db.execute(sql: """
            INSERT INTO attachmentServerState(scopeID,entityType,entityId,observedAt,physicalDeletedAt)
            VALUES(?,?,?,?,?) ON CONFLICT(scopeID,entityType,entityId)
            DO UPDATE SET physicalDeletedAt=excluded.physicalDeletedAt
            """, arguments: [scope,type.rawValue,id,Date(),Date()])
    }

    /// Idempotent: retained parent markers authorize physical children deletion.
    /// Keep the parent marker and its server evidence indefinitely.
    static func reconcileRemoval(_ id: String, scope: String, db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT deletedAt IS NOT NULL FROM referenceAttachment WHERE syncId=?", arguments: [id]) == true else { return }
        try db.execute(sql: "DELETE FROM attachmentUploadQueue WHERE attachmentSyncId=?", arguments: [id])
        try db.execute(sql: "DELETE FROM attachmentDownload WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope, id])
        try db.execute(sql: "UPDATE syncState SET isDirty=0,pushInFlight=0 WHERE entityType='attachmentAsset' AND entityId=?", arguments: [id])
        try db.execute(sql: "UPDATE syncState SET isDirty=0,pushInFlight=0 WHERE entityType='attachmentAnnotation' AND entityId IN (SELECT syncId FROM attachmentAnnotation WHERE attachmentSyncId=?)", arguments: [id])
        guard try Bool.fetchOne(db, sql: "SELECT removalAcknowledgedAt IS NOT NULL FROM attachmentServerState WHERE scopeID=? AND entityType='referenceAttachment' AND entityId=?",
                                arguments: [scope,id]) == true else { return }
        let state = SyncStateStore()
        try queuePhysicalDelete(.attachmentAsset, id: id, state: state, db: db)
        let notes = try String.fetchAll(db, sql: "SELECT syncId FROM attachmentAnnotation WHERE attachmentSyncId=?", arguments: [id])
        for note in notes { try queuePhysicalDelete(.attachmentAnnotation, id: note, state: state, db: db) }
        try db.execute(sql: "DELETE FROM attachmentAnnotation WHERE attachmentSyncId=?", arguments: [id])
        // Suppressed late arrivals may never have entered a model table.
        let names = try String.fetchAll(db, sql: "SELECT o.recordName FROM syncOrphan o JOIN attachmentQuarantineScope q USING(recordName) WHERE q.scopeID=? AND q.parentSyncId=? AND o.recordType IN ('CDAttachmentAsset','CDAttachmentAnnotation')", arguments: [scope,id])
        for name in names {
            guard let (type,child) = SyncEntityType.parseRecordName(name) else { continue }
            try queuePhysicalDelete(type, id: child, state: state, db: db)
            try db.execute(sql: "DELETE FROM syncOrphan WHERE recordName=?", arguments: [name])
        }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentCache WHERE attachmentSyncId=?) OR EXISTS(SELECT 1 FROM attachmentFileJournal WHERE attachmentSyncId=?)", arguments: [id,id]) == true {
            try db.execute(sql: "INSERT INTO attachmentCleanup(scopeID,attachmentSyncId,requestedAt) VALUES(?,?,?) ON CONFLICT(scopeID,attachmentSyncId) DO NOTHING", arguments: [scope,id,Date()])
        }
        try db.execute(sql: "DELETE FROM attachmentRecovery WHERE scopeID=? AND parentSyncId=?", arguments: [scope,id])
    }

    private static func queuePhysicalDelete(_ kind: SyncEntityType, id: String, state: SyncStateStore, db: Database) throws {
        // A clean acknowledged delete need not be re-sent on every idle pass.
        if let scope = try activeScope(db),
           try Bool.fetchOne(db, sql: "SELECT physicalDeletedAt IS NOT NULL FROM attachmentServerState WHERE scopeID=? AND entityType=? AND entityId=?", arguments: [scope,kind.rawValue,id]) == true { return }
        guard try !state.hasTombstone(db, entityType: kind, entityId: id) else { return }
        try state.queueDelete(db, entityType: kind, entityId: id)
    }

    static func queueDownload(_ asset: AttachmentAssetRecord, scope: String, db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT deletedAt IS NOT NULL FROM referenceAttachment WHERE syncId=?", arguments: [asset.attachmentSyncId]) == true { return }
        // Identity mismatches keep their wire diagnostic; never retarget an existing job.
        try db.execute(sql: """
            INSERT INTO attachmentDownload(scopeID,attachmentSyncId,contentHash,byteCount) VALUES(?,?,?,?)
            ON CONFLICT(scopeID,attachmentSyncId) DO NOTHING
            """, arguments: [scope,asset.attachmentSyncId,asset.contentHash,asset.byteCount])
    }
}
#endif
