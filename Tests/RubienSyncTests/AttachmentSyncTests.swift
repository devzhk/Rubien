#if os(macOS)
import XCTest
import CloudKit
import GRDB
@testable import RubienCore
@testable import RubienSync

final class AttachmentSyncTests: XCTestCase {
    private var database: AppDatabase!
    private var parent: Reference!
    private let receiver = AttachmentRecordReceiver()
    private let writer = AttachmentRecordWriter()
    private let state = SyncStateStore()
    private let fileHash = String(repeating: "a", count: 64)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        database = try AppDatabase(DatabaseQueue())
        parent = Reference(title: "Parent paper")
        try database.saveReference(&parent)
    }

    private func metadata() -> ReferenceAttachment {
        ReferenceAttachment(syncId: SyncIdentifier.random(), referenceId: parent.id,
                            referenceSyncId: parent.syncId, kind: "markdown", originalFilename: "notes.md",
                            displayName: "Notes", byteCount: 3, contentHash: fileHash,
                            dateCreated: now, dateModified: now, deletedAt: nil)
    }

    private func annotation(_ parent: ReferenceAttachment) throws -> ReferenceAttachmentAnnotation {
        ReferenceAttachmentAnnotation(syncId: SyncIdentifier.random(), attachmentId: parent.id,
            attachmentSyncId: parent.syncId, contentHash: fileHash, type: "highlight", color: "#FFDE59",
            selectedText: "abc", noteText: "comment", anchorKind: "markdown", anchorVersion: 1,
            anchorJSON: String(decoding: try JSONEncoder().encode(ReferenceAttachmentAnchor.markdown(text: "abc", prefix: nil, suffix: nil)), as: UTF8.self),
            dateCreated: now, dateModified: now, deletedAt: nil)
    }

    private func tagged(_ record: CKRecord, _ tag: String = "server-1") -> CKRecord {
        // Test-only server metadata, preserved by the real system-fields codec.
        setTestRecordChangeTag(record, tag)
        return record
    }

    private func receive(_ record: CKRecord) throws -> AttachmentRecordReceiver.Outcome {
        try database.dbWriter.write { try receiver.receive(record, db: $0) }
    }

    private func dirty(_ type: AttachmentRecordKind, _ id: String) throws -> Int? {
        try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT isDirty FROM syncState WHERE entityType=? AND entityId=?", arguments: [type.rawValue, id]) }
    }

    func testMappingsExcludeLocalIDsAndPreserveUnknownValues() throws {
        var item = metadata()
        item.kind = "future-format"
        let record = item.makeRecord()
        XCTAssertNil(record["id"])
        XCTAssertNil(record["referenceId"])
        let decoded = try XCTUnwrap(ReferenceAttachment(record: record))
        XCTAssertEqual(decoded.kind, item.kind)
        XCTAssertNil(decoded.referenceId)
        XCTAssertEqual(Set(record.allKeys()), Set(ReferenceAttachment.allFieldNames).subtracting(["deletedAt"]))
        XCTAssertEqual(try receive(record), .applied)
        var note = try annotation(item)
        note.anchorVersion = 12
        note.anchorKind = "future-anchor"
        note.anchorJSON = "opaque"
        XCTAssertEqual(try receive(note.makeRecord()), .applied)
        let stored = try database.dbWriter.read { try ReferenceAttachmentAnnotation.fetchOne($0, sql: "SELECT * FROM attachmentAnnotation WHERE syncId=?", arguments: [note.syncId]) }
        XCTAssertEqual(stored?.anchorJSON, "opaque")
        XCTAssertNil(stored?.anchor)
    }

    func testStrictIdentityAndMalformedValuesAreQuarantined() throws {
        let item = metadata()
        for key in ["syncId", "contentHash", "deletedAt", "byteCount"] {
            let record = item.makeRecord()
            record[key] = "invalid"
            XCTAssertEqual(try receive(record), .quarantined)
        }
        let record = item.makeRecord()
        record["byteCount"] = NSNumber(value: true)
        XCTAssertNil(ReferenceAttachment(record: record))
        let mismatched = CKRecord(recordType: "CDReferenceAttachment", recordID: .init(recordName: "referenceAttachment:123"))
        item.populate(record: mismatched)
        XCTAssertNil(ReferenceAttachment(record: mismatched))
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM referenceAttachment") }, 0)
    }

    func testMetadataBeforeParentRetainsCompleteQuarantine() throws {
        var item = metadata()
        item.referenceSyncId = SyncIdentifier.random()
        XCTAssertEqual(try receive(item.makeRecord()), .quarantined)
        let count = try database.dbWriter.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM syncOrphan WHERE recordName=?", arguments: [item.makeRecord().recordID.recordName]))
            let retained = try XCTUnwrap(SyncRecordIdentity.unarchive(row["recordData"]))
            XCTAssertEqual(retained["displayName"] as? String, "Notes")
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='referenceAttachment'")
        }
        XCTAssertEqual(count, 0)
        var lateParent = Reference(title: "Late")
        lateParent.syncId = item.referenceSyncId
        try database.saveReference(&lateParent)
        XCTAssertEqual(try receive(item.makeRecord()), .applied)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncOrphan") }, 0)
    }

    func testDuplicateMetadataPreservesRenameAndEveryStateField() throws {
        let item = metadata()
        let record = tagged(item.makeRecord())
        XCTAssertEqual(try receive(record), .applied)
        try database.dbWriter.write { db in
            try db.execute(sql: "UPDATE referenceAttachment SET displayName='Local rename' WHERE syncId=?", arguments: [item.syncId])
            _ = try state.markPushInFlight(db, entityType: .referenceAttachment, entityId: item.syncId)
            let before = try Row.fetchOne(db, sql: "SELECT * FROM syncState WHERE entityType='referenceAttachment' AND entityId=?", arguments: [item.syncId])
            XCTAssertEqual(try receiver.receive(record, db: db), .duplicate)
            XCTAssertEqual(before, try Row.fetchOne(db, sql: "SELECT * FROM syncState WHERE entityType='referenceAttachment' AND entityId=?", arguments: [item.syncId]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT displayName FROM referenceAttachment WHERE syncId=?", arguments: [item.syncId]), "Local rename")
        }
    }

    func testDifferentAndAbsentTagsUseServerVersion() throws {
        for useTag in [false, true] {
            let item = metadata()
            let record = item.makeRecord()
            if useTag { _ = tagged(record) }
            _ = try receive(record)
            try database.dbWriter.write { try $0.execute(sql: "UPDATE referenceAttachment SET displayName='Local' WHERE syncId=?", arguments: [item.syncId]) }
            if useTag { _ = tagged(record, "server-2") }
            XCTAssertEqual(try receive(record), .applied)
            XCTAssertEqual(try dirty(.referenceAttachment, item.syncId), 0)
        }
    }

    func testImmutableMismatchPrecedesDuplicateGuard() throws {
        let item = metadata()
        let record = tagged(item.makeRecord())
        _ = try receive(record)
        record["contentHash"] = String(repeating: "b", count: 64)
        XCTAssertEqual(try receive(record), .quarantined)
        XCTAssertEqual(try database.dbWriter.read { try String.fetchOne($0, sql: "SELECT contentHash FROM referenceAttachment WHERE syncId=?", arguments: [item.syncId]) }, fileHash)
    }

    func testRemovalWinsOverStaleActiveCopyEvenWithEqualTag() throws {
        let item = metadata()
        let record = tagged(item.makeRecord())
        _ = try receive(record)
        let removed = now.addingTimeInterval(10)
        try database.dbWriter.write { try $0.execute(sql: "UPDATE referenceAttachment SET deletedAt=? WHERE syncId=?", arguments: [removed, item.syncId]) }
        record["dateModified"] = now.addingTimeInterval(9_999_999)
        record["displayName"] = "Stale renamed file"
        XCTAssertEqual(try receive(record), .removalQueued)
        XCTAssertEqual(try dirty(.referenceAttachment, item.syncId), 1)
        let stored = try database.dbWriter.read { try ReferenceAttachment.fetchOne($0, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [item.syncId]) }
        XCTAssertEqual(stored?.deletedAt, removed)
        XCTAssertEqual(stored?.displayName, "Notes")
    }

    func testEarliestMarkerConvergesAndAppliesWithoutParent() throws {
        var item = metadata()
        item.referenceSyncId = SyncIdentifier.random()
        item.deletedAt = now
        XCTAssertEqual(try receive(item.makeRecord()), .applied)
        item.deletedAt = now.addingTimeInterval(100)
        XCTAssertEqual(try receive(item.makeRecord()), .removalQueued)
        item.deletedAt = now.addingTimeInterval(-100)
        XCTAssertEqual(try receive(item.makeRecord()), .applied)
        XCTAssertEqual(try database.dbWriter.read { try Date.fetchOne($0, sql: "SELECT deletedAt FROM referenceAttachment WHERE syncId=?", arguments: [item.syncId]) }, item.deletedAt)
    }

    func testAnnotationMarkerClearsCachedPayloadWithoutParent() throws {
        var note = try annotation(metadata())
        let record = tagged(note.makeRecord())
        note.deletedAt = now
        note.populate(record: record)
        for key in ["type", "color", "selectedText", "noteText", "anchorKind", "anchorVersion", "anchorJSON"] { XCTAssertNil(record[key]) }
        XCTAssertEqual(record.recordChangeTag, "server-1")
        XCTAssertEqual(try receive(record), .applied)
        note.deletedAt = nil
        XCTAssertEqual(try receive(note.makeRecord()), .removalQueued)
        let stored = try database.dbWriter.read { try ReferenceAttachmentAnnotation.fetchOne($0, sql: "SELECT * FROM attachmentAnnotation WHERE syncId=?", arguments: [note.syncId]) }
        XCTAssertEqual(stored?.deletedAt, now)
        XCTAssertNil(stored?.attachmentId)
        XCTAssertNil(stored?.noteText)
    }

    func testDuplicateAnnotationPreservesPendingNote() throws {
        let item = metadata()
        _ = try receive(item.makeRecord())
        let note = try annotation(item)
        let record = tagged(note.makeRecord())
        _ = try receive(record)
        try database.dbWriter.write { try $0.execute(sql: "UPDATE attachmentAnnotation SET noteText='Offline note' WHERE syncId=?", arguments: [note.syncId]) }
        XCTAssertEqual(try receive(record), .duplicate)
        XCTAssertEqual(try dirty(.attachmentAnnotation, note.syncId), 1)
        XCTAssertEqual(try database.dbWriter.read { try String.fetchOne($0, sql: "SELECT noteText FROM attachmentAnnotation WHERE syncId=?", arguments: [note.syncId]) }, "Offline note")
    }

    func testRemovalSuppressesLateChildrenAndPreservesTheirRecoveryPayload() throws {
        var item = metadata()
        item.deletedAt = now
        _ = try receive(item.makeRecord())
        let note = try annotation(item)
        XCTAssertEqual(try receive(note.makeRecord()), .suppressed)
        let asset = AttachmentAssetRecord(attachmentSyncId: item.syncId, contentHash: fileHash, byteCount: 3, assetURL: nil)
        XCTAssertEqual(try receive(asset.makeRecord()), .suppressed)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncOrphan") }, 2)
        XCTAssertNil(try dirty(.attachmentAnnotation, note.syncId))
    }

    func testSaveAcknowledgementPreservesLaterRename() throws {
        let item = metadata()
        try database.dbWriter.write { db in
            try item.insert(db)
            let record = try XCTUnwrap(writer.build(.referenceAttachment, id: item.syncId, db: db))
            try db.execute(sql: "UPDATE referenceAttachment SET displayName='Rename during upload' WHERE syncId=?", arguments: [item.syncId])
            try writer.acknowledge(tagged(record), kind: .referenceAttachment, db: db)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='referenceAttachment' AND entityId=?", arguments: [item.syncId]), 1)
            let retry = try XCTUnwrap(writer.build(.referenceAttachment, id: item.syncId, db: db))
            XCTAssertEqual(retry["displayName"] as? String, "Rename during upload")
            XCTAssertEqual(retry.recordChangeTag, "server-1")
            try writer.acknowledge(tagged(retry, "server-2"), kind: .referenceAttachment, db: db)
        }
        XCTAssertEqual(try dirty(.referenceAttachment, item.syncId), 0)
        XCTAssertNil(try dirty(.attachmentAsset, item.syncId), "Renaming must not queue asset upload")
    }

    func testRemovalDuringInFlightSaveStaysQueuedAndBlocksChildren() throws {
        let item = metadata()
        try database.dbWriter.write { db in
            try item.insert(db)
            let record = try XCTUnwrap(writer.build(.referenceAttachment, id: item.syncId, db: db))
            try db.execute(sql: "UPDATE referenceAttachment SET deletedAt=? WHERE syncId=?", arguments: [now, item.syncId])
            try writer.acknowledge(record, kind: .referenceAttachment, db: db)
            let marker = try XCTUnwrap(writer.build(.referenceAttachment, id: item.syncId, db: db))
            XCTAssertEqual(marker["deletedAt"] as? Date, now)
            XCTAssertNil(try writer.build(.attachmentAsset, id: item.syncId, db: db,
                asset: .init(attachmentSyncId: item.syncId, contentHash: fileHash, byteCount: 3, assetURL: URL(fileURLWithPath: "/unused"))))
        }
    }

    func testMissingAcknowledgedAnnotationIsNotBlindlyRecreated() throws {
        let item = metadata()
        _ = try receive(item.makeRecord())
        let note = try annotation(item)
        _ = try receive(note.makeRecord())
        let id = note.syncId
        try database.dbWriter.write { db in
            XCTAssertEqual(try writer.recoverMissingChild(.attachmentAnnotation, id: id, parentID: item.syncId,
                previouslyAcknowledged: true, parent: .found(item.makeRecord()), child: .absent, db: db), .preserveMissingAcknowledgedAnnotation)
            XCTAssertEqual(try writer.recoverMissingChild(.attachmentAnnotation, id: id, parentID: item.syncId,
                previouslyAcknowledged: false, parent: .found(item.makeRecord()), child: .absent, db: db), .retryNew)
            XCTAssertEqual(try writer.recoverMissingChild(.attachmentAsset, id: item.syncId, parentID: item.syncId,
                previouslyAcknowledged: false, parent: .failed, child: .absent, db: db), .deferRetry)
            var removed = item
            removed.deletedAt = now
            XCTAssertEqual(try writer.recoverMissingChild(.attachmentAnnotation, id: id, parentID: item.syncId,
                previouslyAcknowledged: false, parent: .found(removed.makeRecord()), child: .absent, db: db), .cancel)
        }
    }

    func testAnnotationRemovalDuringUploadSurvivesAcknowledgement() throws {
        let item = metadata()
        _ = try receive(item.makeRecord())
        let note = try annotation(item)
        _ = try receive(note.makeRecord())
        try database.dbWriter.write { db in
            try db.execute(sql: "UPDATE attachmentAnnotation SET noteText='New note' WHERE syncId=?", arguments: [note.syncId])
            let inFlight = try XCTUnwrap(writer.build(.attachmentAnnotation, id: note.syncId, db: db))
            try db.execute(sql: "UPDATE attachmentAnnotation SET deletedAt=? WHERE syncId=?", arguments: [now, note.syncId])
            try writer.acknowledge(tagged(inFlight), kind: .attachmentAnnotation, db: db)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='attachmentAnnotation' AND entityId=?", arguments: [note.syncId]), 1)
            let marker = try XCTUnwrap(writer.build(.attachmentAnnotation, id: note.syncId, db: db))
            XCTAssertEqual(marker["deletedAt"] as? Date, now)
            XCTAssertNil(marker["noteText"])
            try writer.acknowledge(tagged(marker, "removed"), kind: .attachmentAnnotation, db: db)
        }
        XCTAssertEqual(try dirty(.attachmentAnnotation, note.syncId), 0)
    }

    func testNewRecordTypesRegisteredForDispatch() {
        for kind in AttachmentRecordKind.allCases { XCTAssertEqual(SyncEntityType.forRecordType(kind.recordType)?.rawValue, kind.rawValue) }
    }
}
#endif
