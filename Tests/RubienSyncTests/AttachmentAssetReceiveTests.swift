#if os(macOS)
import CloudKit
import GRDB
import XCTest
@testable import RubienCore
@testable import RubienSync

final class AttachmentAssetReceiveTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var store: ReferenceAttachmentStore!
    private var parent: Reference!
    private var source: URL!
    private var item: ReferenceAttachment!
    private let receiver = AttachmentRecordReceiver()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentSync-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path))
        parent = Reference(title: "Primary")
        try database.saveReference(&parent)
        store = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in })
        source = root.appendingPathComponent("incoming.md")
        try Data("abc".utf8).write(to: source)
        let digest = try ReferenceAttachmentStore.hash(source, limit: 100)
        item = ReferenceAttachment(syncId: SyncIdentifier.random(), referenceId: parent.id,
            referenceSyncId: parent.syncId, kind: "markdown", originalFilename: "incoming.md", displayName: "Supplement",
            byteCount: digest.count, contentHash: digest.hash, dateCreated: Date(), dateModified: Date(), deletedAt: nil)
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func asset(tag: String? = nil, file: Bool = true) -> CKRecord {
        let record = AttachmentAssetRecord(attachmentSyncId: item.syncId, contentHash: item.contentHash,
                                          byteCount: item.byteCount, assetURL: file ? source : nil).makeRecord()
        if let tag { setTestRecordChangeTag(record, tag) }
        return record
    }

    private func receiveMetadata() throws {
        try database.dbWriter.write { db in
            XCTAssertEqual(try receiver.receive(item.makeRecord(), db: db), .applied)
        }
    }

    func testReceivesFileAndPublishesVerifiedCache() throws {
        try receiveMetadata()
        XCTAssertEqual(try receiver.receiveAssetFile(asset(), store: store), .applied)
        XCTAssertEqual(try Data(contentsOf: store.verifiedFileURL(syncId: item.syncId)), Data("abc".utf8))
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentFileJournal") }, 0)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentUploadQueue") }, 0)
    }

    func testEqualAssetTagRepairsMissingBytesWithoutAcknowledgingPendingSave() throws {
        try receiveMetadata()
        try database.dbWriter.write { db in
            XCTAssertEqual(try receiver.receive(asset(tag: "one", file: false), db: db), .applied)
            try SyncStateStore().queueSave(db, entityType: .attachmentAsset, entityId: item.syncId)
            _ = try SyncStateStore().markPushInFlight(db, entityType: .attachmentAsset, entityId: item.syncId)
        }
        let before = try database.dbWriter.read { db in
            try SyncStateStore().loadSystemFields(db, entityType: .attachmentAsset, entityId: item.syncId)
        }
        XCTAssertEqual(try receiver.receiveAssetFile(asset(tag: "one"), store: store), .duplicate)
        XCTAssertNoThrow(try store.verifiedFileURL(syncId: item.syncId))
        try database.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='attachmentAsset' AND entityId=?", arguments: [item.syncId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT pushInFlight FROM syncState WHERE entityType='attachmentAsset' AND entityId=?", arguments: [item.syncId]), 1)
            XCTAssertEqual(before, try SyncStateStore().loadSystemFields(db, entityType: .attachmentAsset, entityId: item.syncId))
        }
    }

    func testUnresolvedAssetRetainsBytesThroughImportRecoveryAndDatabaseReopen() throws {
        XCTAssertEqual(try receiver.receiveAssetFile(asset(), store: store), .quarantined)
        let retained = try database.dbWriter.read { db -> (String, Data) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT stagedFilename, recordData FROM syncOrphan"))
            return (row["stagedFilename"], row["recordData"])
        }
        try store.recoverInterruptedImports()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(retained.0)), Data("abc".utf8))
        let operation = try XCTUnwrap(database.dbWriter.read { try String.fetchOne($0, sql: "SELECT operationId FROM attachmentFileJournal") })
        store = nil; database = nil
        database = try AppDatabase(DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path))
        store = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in })
        try receiveMetadata()
        let record = try XCTUnwrap(SyncRecordIdentity.unarchive(retained.1))
        XCTAssertEqual(try receiver.receiveAssetFile(record, store: store, resuming: operation), .applied)
        XCTAssertNoThrow(try store.verifiedFileURL(syncId: item.syncId))
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncOrphan") }, 0)
    }

    func testFailedTransactionAfterPublishRetainsFileForRetry() throws {
        try receiveMetadata()
        enum SimulatedFailure: Error { case crash }
        var operation: String?
        XCTAssertThrowsError(try store.withReceivedFile(at: source, attachmentSyncId: item.syncId, contentHash: item.contentHash, byteCount: item.byteCount) { db, file in
            operation = file.operationID
            try store.publishReceivedFile(file, for: item, db: db)
            throw SimulatedFailure.crash
        })
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentCache") }, 0)
        try store.recoverInterruptedImports()
        XCTAssertEqual(try receiver.receiveAssetFile(asset(), store: store, resuming: XCTUnwrap(operation)), .applied)
        XCTAssertNoThrow(try store.verifiedFileURL(syncId: item.syncId))
    }

    func testMismatchedDescriptorCannotReplaceUploadOwnedBytes() throws {
        let local = try store.importFile(at: source, referenceId: parent.id!).attachment
        let wrongSource = root.appendingPathComponent("wrong.md")
        try Data("xyz".utf8).write(to: wrongSource)
        let digest = try ReferenceAttachmentStore.hash(wrongSource, limit: 10)
        let record = AttachmentAssetRecord(attachmentSyncId: local.syncId, contentHash: digest.hash, byteCount: digest.count, assetURL: wrongSource).makeRecord()
        XCTAssertEqual(try receiver.receiveAssetFile(record, store: store), .quarantined)
        XCTAssertEqual(try Data(contentsOf: store.verifiedFileURL(syncId: local.syncId)), Data("abc".utf8))
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentUploadQueue") }, 1)
    }

    func testCorruptBytesNeverPublishOrAcknowledge() throws {
        try receiveMetadata()
        try Data("xyz".utf8).write(to: source)
        XCTAssertThrowsError(try receiver.receiveAssetFile(asset(), store: store))
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentCache") }, 0)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='attachmentAsset'") }, 0)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentFileJournal WHERE purpose='receive'") }, 1)
    }

    func testDuplicateFileDeliveryReusesExistingCachePath() throws {
        try receiveMetadata()
        _ = try receiver.receiveAssetFile(asset(tag: "one"), store: store)
        let first = try store.verifiedFileURL(syncId: item.syncId)
        XCTAssertEqual(try receiver.receiveAssetFile(asset(tag: "one"), store: store), .duplicate)
        XCTAssertEqual(try store.verifiedFileURL(syncId: item.syncId), first)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentFileJournal") }, 0)
    }

    func testActualTerminalReplayRetainsAllUnresolvedAttachmentTypesAndBytes() async throws {
        item.referenceSyncId = SyncIdentifier.random()
        let metadata = item.makeRecord()
        let note = ReferenceAttachmentAnnotation(syncId: SyncIdentifier.random(), attachmentId: nil,
            attachmentSyncId: item.syncId, contentHash: item.contentHash, type: "highlight", color: "yellow",
            selectedText: "abc", noteText: nil, anchorKind: "markdown", anchorVersion: 1,
            anchorJSON: String(decoding: try JSONEncoder().encode(ReferenceAttachmentAnchor.markdown(text: "abc", prefix: nil, suffix: nil)), as: UTF8.self),
            dateCreated: Date(), dateModified: Date(), deletedAt: nil)
        try await database.dbWriter.write { db in
            XCTAssertEqual(try self.receiver.receive(metadata, db: db), .quarantined)
            XCTAssertEqual(try self.receiver.receive(note.makeRecord(), db: db), .quarantined)
        }
        XCTAssertEqual(try receiver.receiveAssetFile(asset(), store: store), .quarantined)
        let filename = try await database.dbWriter.read { try String.fetchOne($0, sql: "SELECT stagedFilename FROM syncOrphan WHERE recordType='CDAttachmentAsset'") }
        let library = SyncedLibrary(appDatabase: database,
                                   stateFileURL: root.appendingPathComponent("test-engine-state"),
                                   pdfAssetSyncEnabledProvider: { true })
        let result = await library.reconcileFetchedZoneForTest()
        XCTAssertTrue(result, "Durable unresolved attachments must not prevent replay completion")
        let counts = try await database.dbWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOrphan"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachmentFileJournal"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE entityType IN ('referenceAttachment','attachmentAsset','attachmentAnnotation')"))
        }
        XCTAssertEqual(counts.0, 3)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(XCTUnwrap(filename))), Data("abc".utf8))
    }

    func testRemovedParentRetainsLateFileForAcknowledgementCleanup() throws {
        item.deletedAt = Date()
        try receiveMetadata()
        XCTAssertEqual(try receiver.receiveAssetFile(asset(), store: store), .suppressed)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentCache") }, 0)
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachmentFileJournal") }, 1)
    }

    func testTemporaryCloudAssetCannotBypassStaging() throws {
        try receiveMetadata()
        XCTAssertThrowsError(try database.dbWriter.write { try receiver.receive(asset(), db: $0) })
    }
}
#endif
