#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import RubienCore

/// Called only by SyncedLibrary's external start/foreground/idle path for network
/// work. Receive/ack callbacks use its database/file helpers without engine re-entry.
struct AttachmentSyncCoordinator: Sendable {
    let database: AppDatabase
    let files: ReferenceAttachmentStore
    let scope: AttachmentSyncScope
    let transport: any AttachmentCloudTransport
    private let receiver = AttachmentRecordReceiver()

    func inventory() async throws {
        try await database.dbWriter.write { try AttachmentSyncState.activate(scope, db: $0) }
        // Deletion evidence remains durable across inventory retries.
        try await database.dbWriter.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT recordName,recordType FROM attachmentDeferredDeletion WHERE scopeID=?", arguments: [scope.id]) {
                try deleted(.init(recordName: row["recordName"], recordType: row["recordType"]), db: db)
            }
            try db.execute(sql: "DELETE FROM attachmentDeferredDeletion WHERE scopeID=?", arguments: [scope.id])
        }
        try replay()
        var expiredOnce = false
        while true {
            try Task.checkCancellation()
            let progress = try await database.dbWriter.read { db -> (Bool, Data?) in
                guard let row = try Row.fetchOne(db, sql: "SELECT inventoryComplete,inventoryToken FROM attachmentSyncScope WHERE scopeID=?", arguments: [scope.id]) else { throw CKError(.internalError) }
                return (row["inventoryComplete"], row["inventoryToken"])
            }
            if progress.0 {
                try await replayBuffered()
                return
            }
            do {
                let page = try await transport.inventoryPage(token: progress.1)
                try await database.dbWriter.write { try commit(page, db: $0) }
            } catch let error as CKError where error.code == .changeTokenExpired && !expiredOnce {
                expiredOnce = true
                try await database.dbWriter.write { db in
                    try requireScope(db)
                    try db.execute(sql: "UPDATE attachmentSyncScope SET inventoryToken=NULL,inventoryComplete=0 WHERE scopeID=?", arguments: [scope.id])
                }
            } catch let error as CKError where error.code == .zoneNotFound {
                // A new account has no Library zone yet. There is nothing to
                // inventory; ordinary engine zone creation can now proceed.
                try await database.dbWriter.write {
                    try commit(.init(records: [], deletions: [], token: nil, moreComing: false), db: $0)
                }
                try await replayBuffered()
                return
            } catch {
                try await database.dbWriter.write { db in
                    try db.execute(sql: "UPDATE attachmentSyncScope SET error=? WHERE scopeID=?", arguments: [error.localizedDescription,scope.id])
                }
                throw error
            }
        }
    }

    /// The engine and inventory have independent cursors. A buffered engine
    /// event may predate an already-applied page, so fetch its current scalar
    /// version instead of replaying an older payload over that page.
    private func replayBuffered() async throws {
        while true {
            let names = try await database.dbWriter.read { db in
                try String.fetchAll(db, sql: "SELECT recordName FROM attachmentQuarantineScope WHERE scopeID=? AND buffered=1 LIMIT 100", arguments: [scope.id])
            }
            guard !names.isEmpty else { break }
            for name in names {
                try Task.checkCancellation()
                let id = CKRecord.ID(recordName: name, zoneID: SyncConstants.libraryZoneID)
                let current = try await transport.record(id: id, desiredKeys: AttachmentInventoryProjection.desiredKeys)
                if let current, current.recordID != id { throw CKError(.invalidArguments) }
                if let current, let asset = AttachmentAssetRecord(record: current) {
                    let retained = try await database.dbWriter.read { db -> (String,String)? in
                        guard let row = try Row.fetchOne(db, sql: "SELECT o.stagedFilename,j.operationId FROM syncOrphan o JOIN attachmentFileJournal j ON (j.stagedPath=o.stagedFilename OR j.finalPath=o.stagedFilename) WHERE o.recordName=? AND j.attachmentSyncId=?", arguments: [name,asset.attachmentSyncId]) else { return nil }
                        return (row["stagedFilename"],row["operationId"])
                    }
                    if let (path,operation) = retained {
                        let withFile = current.copy() as! CKRecord
                        withFile["asset"] = CKAsset(fileURL: files.libraryRoot.appendingPathComponent(path))
                        do {
                            _ = try receiver.receiveAssetFile(withFile, store: files, resuming: operation, scopeID: scope.id, replaying: true)
                            continue
                        } catch is CancellationError { throw CancellationError() }
                        catch { /* Scalar receipt queues a fresh download; the journal keeps its old bytes. */ }
                    }
                }
                try await database.dbWriter.write { db in
                    try requireScope(db)
                    if let current {
                        _ = try receiver.receive(current, db: db, replaying: true)
                    } else if let (type,_) = SyncEntityType.parseRecordName(name) {
                        try deleted(.init(recordName: name, recordType: type.recordType), db: db)
                        try db.execute(sql: "DELETE FROM syncOrphan WHERE recordName=?", arguments: [name])
                    }
                    try db.execute(sql: "UPDATE attachmentQuarantineScope SET buffered=0 WHERE recordName=? AND scopeID=?", arguments: [name,scope.id])
                    try AttachmentSyncState.drainRemovals(scope: scope.id, db: db)
                }
            }
        }
        try replay()
    }

    /// Scalar rows, dependent download work and the page cursor commit together.
    /// No primary dispatch, baseline, primary queues or engine serialization here.
    func commit(_ page: AttachmentInventoryPage, db: Database) throws {
        try requireScope(db)
        guard page.token != nil || !page.moreComing else { throw CKError(.internalError) }
        for deletion in page.deletions { try deleted(deletion, db: db) }
        for record in page.records.sorted(by: { rank($0) < rank($1) }) {
            guard AttachmentRecordKind.allCases.contains(where: { $0.recordType == record.recordType }) else { continue }
            guard record["asset"] == nil else { throw CKError(.invalidArguments) }
            // Preserve the buffered identity until its current cloud version has
            // been fetched; two independent cursors do not establish version order.
            if try Bool.fetchOne(db, sql: "SELECT buffered FROM attachmentQuarantineScope WHERE scopeID=? AND recordName=?", arguments: [scope.id,record.recordID.recordName]) == true { continue }
            _ = try receiver.receive(record, db: db, drainRemovals: false)
        }
        try replayScalars(db)
        try AttachmentSyncState.drainRemovals(scope: scope.id, db: db)
        try db.execute(sql: "UPDATE attachmentSyncScope SET inventoryToken=?,inventoryComplete=?,error=NULL WHERE scopeID=?",
                       arguments: [page.token,!page.moreComing,scope.id])
    }

    func receive(records: [CKRecord], deletions: [AttachmentInventoryPage.Deletion]) throws {
        try database.dbWriter.write { db in
            try requireScope(db)
            for deletion in deletions { try deleted(deletion, db: db) }
        }
        for record in records.sorted(by: { rank($0) < rank($1) }) {
            if record.recordType == "CDAttachmentAsset", record["asset"] != nil {
                _ = try receiver.receiveAssetFile(record, store: files, scopeID: scope.id)
            } else {
                try database.dbWriter.write { db in
                    try requireScope(db)
                    _ = try receiver.receive(record, db: db)
                }
            }
        }
        try replay()
    }

    func deleted(_ deletion: AttachmentInventoryPage.Deletion, db: Database) throws {
        guard let (type,id) = SyncEntityType.parseRecordName(deletion.recordName), type.recordType == deletion.recordType else { return }
        if type == .reference {
            try AttachmentSyncState.referenceDeleted(id, scope: scope.id, db: db)
        } else if type == .referenceAttachment {
            // A physical metadata delete is positive removal evidence too. Retain
            // that fence even if this device has not received the metadata yet.
            try db.execute(sql: """
                INSERT INTO attachmentServerState(scopeID,entityType,entityId,observedAt,removalAcknowledgedAt)
                VALUES(?,'referenceAttachment',?,?,?) ON CONFLICT(scopeID,entityType,entityId)
                DO UPDATE SET removalAcknowledgedAt=COALESCE(removalAcknowledgedAt,excluded.removalAcknowledgedAt)
                """, arguments: [scope.id,id,Date(),Date()])
            try db.execute(sql: "UPDATE referenceAttachment SET deletedAt=COALESCE(deletedAt,?),dateModified=? WHERE syncId=?", arguments: [Date(),Date(),id])
            if try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [id]) != nil {
                try SyncStateStore().queueSave(db, entityType: type, entityId: id)
                try AttachmentSyncState.requestRemoval(id, scope: scope.id, db: db)
            }
        } else if let kind = type.attachmentKind {
            try AttachmentSyncState.physicalDeleteConfirmed(type, id: id, db: db)
            let parent = kind == .attachmentAsset ? id : try String.fetchOne(db, sql: "SELECT attachmentSyncId FROM attachmentAnnotation WHERE syncId=?", arguments: [id])
            guard let parent else { return }
            if try Bool.fetchOne(db, sql: "SELECT deletedAt IS NOT NULL FROM referenceAttachment WHERE syncId=?", arguments: [parent]) == true {
                try AttachmentSyncState.requestRemoval(parent, scope: scope.id, db: db)
            } else {
                try queueRecovery(kind, id: id, parent: parent, db: db)
            }
        }
    }

    func replayScalars(_ db: Database) throws {
        for _ in 0..<3 {
            var progressed = false
            let rows = try Row.fetchAll(db, sql: "SELECT recordName,recordData FROM syncOrphan WHERE recordType IN ('CDReferenceAttachment','CDAttachmentAnnotation') AND recordName IN (SELECT recordName FROM attachmentQuarantineScope WHERE scopeID=? AND pendingReplay=1 AND buffered=0) ORDER BY recordType DESC,receivedAt", arguments: [scope.id])
            for row in rows {
                let name: String = row["recordName"]
                try db.execute(sql: "UPDATE attachmentQuarantineScope SET pendingReplay=0 WHERE recordName=? AND scopeID=?", arguments: [name,scope.id])
                guard let record = try? SyncRecordIdentity.unarchive(row["recordData"]) else { continue }
                let result = try receiver.receive(record, db: db, replaying: true, drainRemovals: false)
                if result == .applied || result == .duplicate || result == .removalQueued { progressed = true }
            }
            if !progressed { break }
        }
    }

    func replay() throws {
        try database.dbWriter.write { db in
            try requireScope(db)
            // Old v17 quarantine has no dependency index. Populate it once.
            let legacy = try Row.fetchAll(db, sql: "SELECT o.recordName,o.recordData FROM syncOrphan o JOIN attachmentQuarantineScope q USING(recordName) WHERE q.scopeID=? AND q.parentSyncId IS NULL AND q.pendingReplay=1 AND q.buffered=0", arguments: [scope.id])
            for row in legacy {
                if let record = try? SyncRecordIdentity.unarchive(row["recordData"]) {
                    try AttachmentQuarantine.retain(record, scope: scope.id, db: db)
                } else {
                    let name: String = row["recordName"]
                    try db.execute(sql: "UPDATE attachmentQuarantineScope SET pendingReplay=0 WHERE recordName=? AND scopeID=?", arguments: [name,scope.id])
                }
            }
            try replayScalars(db)
            try AttachmentSyncState.drainRemovals(scope: scope.id, db: db)
        }
        let pending = try database.dbWriter.read { db -> [(String,Data,String?)] in
            try Row.fetchAll(db, sql: "SELECT recordName,recordData,stagedFilename FROM syncOrphan WHERE recordType='CDAttachmentAsset' AND recordName IN (SELECT recordName FROM attachmentQuarantineScope WHERE scopeID=? AND pendingReplay=1 AND buffered=0)", arguments: [scope.id])
                .map { ($0["recordName"],$0["recordData"],$0["stagedFilename"]) }
        }
        for (name,data,path) in pending {
            guard let record = try? SyncRecordIdentity.unarchive(data), let asset = AttachmentAssetRecord(record: record) else {
                try database.dbWriter.write { try $0.execute(sql: "UPDATE attachmentQuarantineScope SET pendingReplay=0 WHERE recordName=? AND scopeID=?", arguments: [name,scope.id]) }
                continue
            }
            let local = try database.dbWriter.read { db in
                try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [asset.attachmentSyncId])
            }
            guard let local else {
                try database.dbWriter.write { try $0.execute(sql: "UPDATE attachmentQuarantineScope SET pendingReplay=0 WHERE recordName=? AND scopeID=?", arguments: [record.recordID.recordName,scope.id]) }
                continue
            }
            if let path, let operation = try database.dbWriter.read({ db in
                try String.fetchOne(db, sql: "SELECT operationId FROM attachmentFileJournal WHERE stagedPath=? OR finalPath=?", arguments: [path,path])
            }) {
                do {
                    _ = try receiver.receiveAssetFile(record, store: files, resuming: operation, scopeID: scope.id, replaying: true)
                    continue
                } catch is CancellationError { throw CancellationError() }
                catch { /* Keep the journal-owned file; fetch a fresh copy independently. */ }
            }
            do {
                let scalar = record.copy() as! CKRecord
                scalar["asset"] = nil
                try database.dbWriter.write { db in
                    try requireScope(db)
                    try db.execute(sql: "UPDATE syncOrphan SET stagedFilename=NULL WHERE recordName=?", arguments: [record.recordID.recordName])
                    _ = try receiver.receive(scalar, db: db, replaying: true)
                    if local.deletedAt == nil { try AttachmentSyncState.queueDownload(asset, scope: scope.id, db: db) }
                }
            }
        }
    }

    /// Bounded downloads do not hold scalar sync hostage. Failed jobs retain their
    /// descriptor and backoff; a normal engine asset delivery can satisfy the job.
    func downloadPending(limit: Int = 4) async throws {
        let jobs = try await database.dbWriter.read { db -> [(String,String,Int64,Int)] in
            try Row.fetchAll(db, sql: "SELECT * FROM attachmentDownload WHERE scopeID=? AND (nextAttemptAt IS NULL OR nextAttemptAt<=?) ORDER BY attempts,attachmentSyncId LIMIT ?", arguments: [scope.id,Date(),limit])
                .map { ($0["attachmentSyncId"],$0["contentHash"],$0["byteCount"],$0["attempts"]) }
        }
        for (id,hash,count,attempts) in jobs {
            try Task.checkCancellation()
            do {
                let item = try? files.attachment(syncId: id)
                if item?.deletedAt != nil {
                    try await database.dbWriter.write { try AttachmentSyncState.requestRemoval(id, scope: scope.id, db: $0) }
                    continue
                }
                if item?.contentHash == hash, item?.byteCount == count, (try? files.verifiedFileURL(syncId: id)) != nil {
                    try await database.dbWriter.write { try $0.execute(sql: "DELETE FROM attachmentDownload WHERE scopeID=? AND attachmentSyncId=?", arguments: [scope.id,id]) }
                    continue
                }
                let stagedPath = try await database.dbWriter.read { db in
                    try String.fetchOne(db, sql: "SELECT stagedFilename FROM syncOrphan WHERE recordName=?", arguments: [AttachmentRecordKind.attachmentAsset.recordName(id)])
                }
                if let stagedPath, FileManager.default.fileExists(atPath: files.libraryRoot.appendingPathComponent(stagedPath).path) {
                    // Durable quarantine already owns the bytes; wait for its parent
                    // instead of downloading another copy on every idle cycle.
                    continue
                }
                let recordID = CKRecord.ID(recordName: AttachmentRecordKind.attachmentAsset.recordName(id), zoneID: SyncConstants.libraryZoneID)
                guard let record = try await transport.record(id: recordID, desiredKeys: AttachmentAssetRecord.allFieldNames),
                      let asset = AttachmentAssetRecord(record: record), asset.contentHash == hash, asset.byteCount == count else { throw ReferenceAttachmentError.unavailable }
                try requireCurrentScope()
                let outcome = try receiver.receiveAssetFile(record, store: files, scopeID: scope.id)
                if outcome == .quarantined { throw ReferenceAttachmentError.integrityMismatch }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try await database.dbWriter.write { db in
                    try db.execute(sql: "UPDATE attachmentDownload SET attempts=attempts+1,nextAttemptAt=?,error=? WHERE scopeID=? AND attachmentSyncId=?",
                                   arguments: [Date().addingTimeInterval(min(900,pow(2,Double(min(attempts,8))) * 15)),error.localizedDescription,scope.id,id])
                }
            }
        }
    }

    func queueRecovery(_ kind: AttachmentRecordKind, id: String, parent: String, db: Database) throws {
        try db.execute(sql: "INSERT INTO attachmentRecovery(scopeID,entityType,entityId,parentSyncId) VALUES(?,?,?,?) ON CONFLICT(scopeID,entityType,entityId) DO NOTHING", arguments: [scope.id,kind.rawValue,id,parent])
    }

    func recoverPending() async throws {
        let jobs = try await database.dbWriter.read { db -> [(String,String,String)] in
            try Row.fetchAll(db, sql: "SELECT entityType,entityId,parentSyncId FROM attachmentRecovery WHERE scopeID=? AND error IS NULL LIMIT 8", arguments: [scope.id])
                .map { ($0["entityType"],$0["entityId"],$0["parentSyncId"]) }
        }
        for (raw,id,parent) in jobs {
            guard let kind = AttachmentRecordKind(rawValue: raw) else { continue }
            do {
                let parentRecord = try await transport.record(id: .init(recordName: AttachmentRecordKind.referenceAttachment.recordName(parent), zoneID: SyncConstants.libraryZoneID), desiredKeys: ReferenceAttachment.allFieldNames)
                let childRecord = try await transport.record(id: .init(recordName: kind.recordName(id), zoneID: SyncConstants.libraryZoneID), desiredKeys: AttachmentInventoryProjection.desiredKeys)
                try await database.dbWriter.write { db in
                    try requireScope(db)
                    let acknowledged = try AttachmentSyncState.wasObserved(kind, id: id, scope: scope.id, db: db)
                    let result = try AttachmentRecordWriter().recoverMissingChild(kind, id: id, parentID: parent, previouslyAcknowledged: acknowledged,
                        parent: parentRecord.map(AttachmentRecordWriter.Lookup.found) ?? .absent,
                        child: childRecord.map(AttachmentRecordWriter.Lookup.found) ?? .absent, db: db)
                    if result == .preserveMissingAcknowledgedAnnotation {
                        try db.execute(sql: "UPDATE attachmentRecovery SET error='The previously synced annotation is missing from iCloud. Its local content has been preserved.' WHERE scopeID=? AND entityType=? AND entityId=?", arguments: [scope.id,raw,id])
                    } else if result != .deferRetry {
                        if result == .retryNew {
                            let type = SyncEntityType(rawValue: raw)!
                            try SyncStateStore().clearSystemFields(db, entityType: type, entityId: id)
                            try SyncStateStore().queueSave(db, entityType: type, entityId: id)
                        }
                        try db.execute(sql: "DELETE FROM attachmentRecovery WHERE scopeID=? AND entityType=? AND entityId=?", arguments: [scope.id,raw,id])
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* A failed lookup supplies no deletion/recreate evidence; retry on the next external cycle. */ }
        }
    }

    func cleanup() throws {
        try database.dbWriter.write { db in
            try requireScope(db)
            try AttachmentSyncState.drainRemovals(scope: scope.id, db: db)
        }
        let jobs = try database.dbWriter.read { try String.fetchAll($0, sql: "SELECT attachmentSyncId FROM attachmentCleanup WHERE scopeID=?", arguments: [scope.id]) }
        for id in jobs {
            do { try files.cleanRemovedFiles(syncId: id) }
            catch {
                try database.dbWriter.write { try $0.execute(sql: "UPDATE attachmentCleanup SET error=? WHERE scopeID=? AND attachmentSyncId=?", arguments: [error.localizedDescription,scope.id,id]) }
            }
        }
    }

    func requireScope(_ db: Database) throws {
        guard try AttachmentSyncState.activeScope(db) == scope.id else { throw CancellationError() }
    }
    private func requireCurrentScope() throws { try database.dbWriter.read { try requireScope($0) } }
    private func rank(_ record: CKRecord) -> Int { record.recordType == "CDReferenceAttachment" ? 0 : 1 }
}
#endif
