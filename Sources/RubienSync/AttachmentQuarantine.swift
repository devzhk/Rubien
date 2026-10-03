#if canImport(CloudKit)
import CloudKit
import GRDB
import RubienCore

/// Retain complete wire records and index their dependency without applying scalars.
enum AttachmentQuarantine {
    static func retain(_ record: CKRecord, scope: String?, stagedFilename: String? = nil,
                       buffered: Bool = false, replaying: Bool = false, db: Database) throws {
        _ = try SyncEntityType.quarantineRemoteRecord(record, stagedFilename: stagedFilename, db: db)
        guard let scope else {
            // Environment/account discovery failed. Preserve the payload but never
            // attribute it to the previous scope or replay it under a guessed scope.
            try db.execute(sql: "DELETE FROM attachmentQuarantineScope WHERE recordName=?", arguments: [record.recordID.recordName])
            return
        }
        let kind = AttachmentRecordKind.allCases.first { $0.recordType == record.recordType }
        let parent: String? = kind?.identity(in: record) == nil ? nil
            : record[kind == .referenceAttachment ? "referenceSyncId" : "attachmentSyncId"] as? String
        try db.execute(sql: """
            INSERT INTO attachmentQuarantineScope(recordName,scopeID,parentSyncId,pendingReplay,buffered)
            VALUES(?,?,?,?,?) ON CONFLICT(recordName) DO UPDATE SET scopeID=excluded.scopeID,
                parentSyncId=excluded.parentSyncId,pendingReplay=excluded.pendingReplay,buffered=excluded.buffered
            """, arguments: [record.recordID.recordName,scope,parent,!replaying,buffered])
    }

    static func buffer(records: [CKRecord], deletions: [AttachmentInventoryPage.Deletion],
                       scope: String?, files: ReferenceAttachmentStore, database: AppDatabase) throws {
        try database.dbWriter.write { db in
            for deletion in deletions {
                try db.execute(sql: "INSERT INTO attachmentDeferredDeletion(scopeID,recordName,recordType) VALUES(?,?,?) ON CONFLICT(scopeID,recordName) DO UPDATE SET recordType=excluded.recordType",
                               arguments: [scope ?? "",deletion.recordName,deletion.recordType])
            }
        }
        for record in records {
            if let asset = AttachmentAssetRecord(record: record), let source = asset.assetURL {
                try files.withReceivedFile(at: source, attachmentSyncId: asset.attachmentSyncId,
                                          contentHash: asset.contentHash, byteCount: asset.byteCount) { db,file in
                    let retained = record.copy() as! CKRecord
                    retained["asset"] = CKAsset(fileURL: file.stagedURL)
                    try retain(retained, scope: scope, stagedFilename: file.relativePath, buffered: true, db: db)
                }
            } else {
                try database.dbWriter.write { try retain(record, scope: scope, buffered: true, db: $0) }
            }
        }
    }
}
#endif
