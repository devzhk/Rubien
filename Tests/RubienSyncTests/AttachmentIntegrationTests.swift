#if os(macOS)
import CloudKit
import GRDB
import XCTest
@testable import RubienCore
@testable import RubienSync

private actor AttachmentTestTransport: AttachmentCloudTransport {
    var pages: [Result<AttachmentInventoryPage, Error>] = []
    var records: [String: CKRecord] = [:]
    var tokens: [Data?] = []
    var requested: [String] = []
    var recordError: CKError?
    func failRecords(_ error: CKError?) { recordError = error }
    func configure(pages: [Result<AttachmentInventoryPage, Error>] = [], records: [String: CKRecord] = [:]) {
        self.pages = pages; self.records = records
    }
    func inventoryPage(token: Data?) async throws -> AttachmentInventoryPage {
        tokens.append(token)
        guard !pages.isEmpty else { throw CKError(.networkUnavailable) }
        return try pages.removeFirst().get()
    }
    func record(id: CKRecord.ID, desiredKeys: [String]) async throws -> CKRecord? {
        requested.append(id.recordName)
        if let recordError { throw recordError }
        return records[id.recordName]
    }
}

final class AttachmentIntegrationTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var files: ReferenceAttachmentStore!
    private var parent: Reference!
    private var item: ReferenceAttachment!
    private var source: URL!
    private var transport: AttachmentTestTransport!
    private let scope = AttachmentSyncScope(account: "test-account", environment: "Development")
    private var coordinator: AttachmentSyncCoordinator {
        .init(database: database, files: files, scope: scope, transport: transport)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path))
        files = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in })
        parent = Reference(title: "Locally edited paper")
        try database.saveReference(&parent)
        source = root.appendingPathComponent("source.md")
        try Data("Supplementary text".utf8).write(to: source)
        let digest = try ReferenceAttachmentStore.hash(source, limit: 1000)
        item = ReferenceAttachment(syncId: SyncIdentifier.random(), referenceId: parent.id,
            referenceSyncId: parent.syncId, kind: "markdown", originalFilename: "source.md", displayName: "Notes",
            byteCount: digest.count, contentHash: digest.hash, dateCreated: Date(), dateModified: Date(), deletedAt: nil)
        transport = AttachmentTestTransport()
        try database.dbWriter.write { try AttachmentSyncState.activate(scope, db: $0) }
    }
    override func tearDownWithError() throws {
        files = nil; database = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func asset(file: Bool = true) -> CKRecord {
        AttachmentAssetRecord(attachmentSyncId: item.syncId, contentHash: item.contentHash,
                              byteCount: item.byteCount, assetURL: file ? source : nil).makeRecord()
    }
    private func scalar(_ sql: String) throws -> Int {
        try database.dbWriter.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }
    private func receive() throws { try coordinator.receive(records: [item.makeRecord()], deletions: []) }

    func testInventoryPreservesPrimaryRowsAndIntentAndCommitsCursorWithDownloads() async throws {
        let before = try await database.dbWriter.read { db in
            try ["reference", "syncState", "tombstone", "pdfCache", "pdfUploadQueue", "syncSession"].map {
                try Data(JSONEncoder().encode(Row.fetchAll(db, sql: "SELECT * FROM \($0)").map { $0.description }))
            }
        }
        let engineURL = root.appendingPathComponent("sync-engine.json")
        let engineBytes = Data("Existing engine cursor".utf8)
        try engineBytes.write(to: engineURL)
        let record = Reference.makeRecord(recordName: "reference:" + parent.syncId, reference: parent)
        record["title"] = "Stale cloud paper" as CKRecordValue
        record["webContent"] = "Must never be applied" as CKRecordValue
        await transport.configure(pages: [.success(.init(records: [record, item.makeRecord(), asset(file: false)], deletions: [], token: Data([1]), moreComing: false))])
        try await coordinator.inventory()
        let after = try await database.dbWriter.read { db in
            try ["reference", "syncState", "tombstone", "pdfCache", "pdfUploadQueue", "syncSession"].map { table in
                let whereClause = table == "syncState" ? " WHERE entityType NOT IN ('referenceAttachment','attachmentAsset','attachmentAnnotation')" : ""
                return try Data(JSONEncoder().encode(Row.fetchAll(db, sql: "SELECT * FROM \(table)\(whereClause)").map { $0.description }))
            }
        }
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: engineURL), engineBytes)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentDownload"), 1)
        XCTAssertEqual(try scalar("SELECT inventoryComplete FROM attachmentSyncScope"), 1)
        let token = try await database.dbWriter.read { try Data.fetchOne($0, sql: "SELECT inventoryToken FROM attachmentSyncScope") }
        XCTAssertEqual(token, Data([1]))
    }

    func testInventoryRejectsAssetsAndRollsBackWholePage() throws {
        XCTAssertThrowsError(try database.dbWriter.write {
            try coordinator.commit(.init(records: [item.makeRecord(), asset()], deletions: [], token: Data([2]), moreComing: true), db: $0)
        })
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM referenceAttachment"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentDownload"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentSyncScope WHERE inventoryToken IS NOT NULL"), 0)
    }

    func testInventoryRestartAndExpiredTokenUseOnlyPrivateCursor() async throws {
        await transport.configure(pages: [.success(.init(records: [item.makeRecord()], deletions: [], token: Data([3]), moreComing: true)), .failure(CKError(.networkUnavailable))])
        do { try await coordinator.inventory(); XCTFail("Expected interrupted inventory") } catch {}
        await transport.configure(pages: [.failure(CKError(.changeTokenExpired)), .success(.init(records: [], deletions: [], token: Data([4]), moreComing: false))])
        try await coordinator.inventory()
        let tokens = await transport.tokens
        XCTAssertEqual(tokens, [nil, Data([3]), Data([3]), nil])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM referenceAttachment"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentDownload"), 1)
    }

    func testEngineDuplicateDeliveryPreservesLocalRenameAndDirtyState() async throws {
        let record = item.makeRecord()
        setTestRecordChangeTag(record, "same-version")
        try coordinator.receive(records: [record], deletions: [])
        try files.rename(syncId: item.syncId, to: "Local rename")
        let library = SyncedLibrary(appDatabase: database, stateFileURL: root.appendingPathComponent("engine.json"), attachmentSyncEnabledProvider: { true })
        await library.configureAttachmentSyncForTest(coordinator)
        let applied = await library.applyFetchedRecordsForTest(modifications: [record], deletions: [])
        XCTAssertTrue(applied)
        XCTAssertEqual(try files.attachment(syncId: item.syncId).displayName, "Local rename")
        XCTAssertEqual(try scalar("SELECT isDirty FROM syncState WHERE entityType='referenceAttachment'"), 1)
    }

    func testTargetedDownloadIsBoundedAndFailuresRemainRetryable() async throws {
        try receive()
        try await coordinator.downloadPending(limit: 1)
        XCTAssertEqual(try scalar("SELECT attempts FROM attachmentDownload"), 1)
        await transport.configure(records: [asset().recordID.recordName: asset()])
        try await database.dbWriter.write { try $0.execute(sql: "UPDATE attachmentDownload SET nextAttemptAt=NULL") }
        try await coordinator.downloadPending(limit: 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentDownload"), 0)
        XCTAssertEqual(try Data(contentsOf: files.verifiedFileURL(syncId: item.syncId)), Data("Supplementary text".utf8))
        let requested = await transport.requested
        XCTAssertEqual(requested, Array(repeating: "attachmentAsset:" + item.syncId, count: 2))
    }

    func testRemovalWaitsForAcknowledgementAndReaderLease() throws {
        try receive()
        try coordinator.receive(records: [asset()], deletions: [])
        let path = try files.verifiedFileURL(syncId: item.syncId)
        var lease: AttachmentFileLease? = try files.acquireFileLease()
        try files.remove(syncId: item.syncId)
        try coordinator.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        var removed = item!
        removed.deletedAt = Date()
        try coordinator.receive(records: [removed.makeRecord()], deletions: [])
        try coordinator.cleanup()
        XCTAssertNotNil(lease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        lease = nil
        try coordinator.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM referenceAttachment WHERE deletedAt IS NOT NULL"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tombstone WHERE entityType='attachmentAsset'"), 1)
    }

    func testReferenceDeletionEvidenceIsScopedAndRemovesLateMetadata() throws {
        try database.dbWriter.write { try AttachmentSyncState.referenceDeleted(parent.syncId, scope: scope.id, db: $0) }
        try receive()
        XCTAssertNotNil(try files.attachment(syncId: item.syncId).deletedAt)
        let other = AttachmentSyncScope(account: "other", environment: "Development")
        try database.dbWriter.write { db in
            try AttachmentSyncState.activate(other, db: db)
            XCTAssertNil(try AttachmentSyncState.parentDeletionDate(parent.syncId, db: db))
        }
        XCTAssertThrowsError(try coordinator.receive(records: [], deletions: []))
    }
    func testMissingAcknowledgedAnnotationPreservesContentAcrossRetry() async throws {
        try receive()
        let note = try files.addAnnotation(attachmentSyncId: item.syncId, type: .highlight,
            anchor: .markdown(text: "text", prefix: nil, suffix: nil), noteText: "Keep this note")
        try coordinator.receive(records: [note.makeRecord()], deletions: [])
        try await database.dbWriter.write { db in
            try SyncStateStore().clearSystemFields(db, entityType: .attachmentAnnotation, entityId: note.syncId)
        }
        let library = SyncedLibrary(appDatabase: database, stateFileURL: root.appendingPathComponent("engine.json"), attachmentSyncEnabledProvider: { true })
        await library.configureAttachmentSyncForTest(coordinator)
        let failure = await library.recoverUnknownItemSaveFailure(type: .attachmentAnnotation, entityId: note.syncId, error: CKError(.unknownItem))
        XCTAssertNil(failure)
        await transport.configure(records: [item.makeRecord().recordID.recordName: item.makeRecord()])
        try await coordinator.recoverPending()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentRecovery WHERE error IS NOT NULL"), 1)
        XCTAssertEqual(try files.annotations(attachmentSyncId: item.syncId).first?.noteText, "Keep this note")
        try files.retrySync(syncId: item.syncId)
        try await coordinator.recoverPending()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentRecovery WHERE error IS NOT NULL"), 1)
    }

    func testLateChildRequeuesConfirmedDelete() throws {
        try receive()
        var removed = item!
        removed.deletedAt = Date()
        try coordinator.receive(records: [removed.makeRecord()], deletions: [])
        try database.dbWriter.write { try SyncStateStore().markTombstoneConfirmed($0, entityType: .attachmentAsset, entityId: item.syncId) }
        try coordinator.receive(records: [asset(file: false)], deletions: [])
        XCTAssertEqual(try scalar("SELECT confirmedByServer FROM tombstone WHERE entityType='attachmentAsset'"), 0)
    }

    func testQuarantineFromAnotherAccountDoesNotReplay() throws {
        let missingParent = Reference(title: "Not received yet")
        item.referenceSyncId = missingParent.syncId
        try receive()
        let other = AttachmentSyncScope(account: "another-account", environment: "Development")
        try database.dbWriter.write { try AttachmentSyncState.activate(other, db: $0) }
        var inserted = missingParent
        try database.saveReference(&inserted)
        let otherCoordinator = AttachmentSyncCoordinator(database: database, files: files, scope: other, transport: transport)
        try otherCoordinator.replay()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM referenceAttachment"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM syncOrphan"), 1)
    }

    func testDefaultGateDoesNotApplyAttachmentTraffic() async throws {
        let library = SyncedLibrary(appDatabase: database, stateFileURL: root.appendingPathComponent("engine.json"))
        let result = await library.applyFetchedRecordsForTest(modifications: [item.makeRecord(), asset()], deletions: [])
        XCTAssertTrue(result)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM referenceAttachment"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentCache"), 0)
    }

    func testInventoryFailureKeepsPrimaryAvailableAndBuffersAttachmentsUntilRetry() async throws {
        let library = SyncedLibrary(appDatabase: database, stateFileURL: root.appendingPathComponent("engine.json"), attachmentSyncEnabledProvider: { true })
        await library.configureAttachmentSyncForTest(coordinator, ready: false)
        await transport.configure(pages: [.failure(CKError(.networkUnavailable))])
        let primaryMayStart = await library.prepareAttachmentSyncForTest()
        let ready = await library.attachmentsReadyForTest
        XCTAssertTrue(primaryMayStart)
        XCTAssertFalse(ready)
        var cloudParent = parent!
        cloudParent.title = "New primary title"
        let primary = Reference.makeRecord(recordName: "reference:" + parent.syncId, reference: cloudParent)
        let applied = await library.applyFetchedRecordsForTest(modifications: [primary,item.makeRecord()], deletions: [])
        XCTAssertTrue(applied)
        let primaryTitle = try await database.dbWriter.read { try String.fetchOne($0, sql: "SELECT title FROM reference") }
        XCTAssertEqual(primaryTitle, "New primary title")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM referenceAttachment"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentQuarantineScope WHERE buffered=1"), 1)
        await transport.configure(pages: [.success(.init(records: [], deletions: [], token: Data([9]), moreComing: false))], records: [item.makeRecord().recordID.recordName:item.makeRecord()])
        let retry = await library.prepareAttachmentSyncForTest()
        let readyAfterRetry = await library.attachmentsReadyForTest
        XCTAssertTrue(retry)
        XCTAssertTrue(readyAfterRetry)
        XCTAssertEqual(try files.attachment(syncId: item.syncId).displayName, item.displayName)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentQuarantineScope"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM syncSession WHERE key='attachmentSyncError'"), 0)
    }

    func testBufferedCurrentVersionWinsAcrossIndependentCursorsAndFailedRefresh() async throws {
        var buffered = item!
        buffered.displayName = "Intermediate engine version"
        try AttachmentQuarantine.buffer(records: [buffered.makeRecord()], deletions: [], scope: scope.id, files: files, database: database)
        var newest = item!
        newest.displayName = "Current cloud version"
        // An older inventory page must not discard the buffered identity.
        await transport.configure(pages: [.success(.init(records: [item.makeRecord()], deletions: [], token: Data([7]), moreComing: false))], records: [newest.makeRecord().recordID.recordName:newest.makeRecord()])
        await transport.failRecords(CKError(.networkUnavailable))
        do { try await coordinator.inventory(); XCTFail("Expected failed current-version lookup") } catch {}
        XCTAssertEqual(try scalar("SELECT inventoryComplete FROM attachmentSyncScope"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentQuarantineScope WHERE buffered=1"), 1)
        await transport.failRecords(nil)
        try await coordinator.inventory()
        XCTAssertEqual(try files.attachment(syncId: item.syncId).displayName, "Current cloud version")
        let tokens = await transport.tokens
        XCTAssertEqual(tokens, [nil])
    }

    func testBufferedAssetOwnsBytesAfterCloudTemporaryFileDisappears() async throws {
        try receive()
        try AttachmentQuarantine.buffer(records: [asset()], deletions: [], scope: scope.id, files: files, database: database)
        try FileManager.default.removeItem(at: source)
        await transport.configure(pages: [.success(.init(records: [], deletions: [], token: Data([8]), moreComing: false))], records: [asset(file: false).recordID.recordName:asset(file: false)])
        try await coordinator.inventory()
        XCTAssertEqual(try Data(contentsOf: files.verifiedFileURL(syncId: item.syncId)), Data("Supplementary text".utf8))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentDownload"), 0)
    }

    func testBufferedParentDeletionSurvivesRetryAndRemovesLateMetadata() async throws {
        try AttachmentQuarantine.buffer(records: [], deletions: [.init(recordName: "reference:" + parent.syncId, recordType: "CDReference")], scope: scope.id, files: files, database: database)
        await transport.configure(pages: [.failure(CKError(.networkUnavailable))])
        do { try await coordinator.inventory(); XCTFail("Expected interrupted inventory") } catch {}
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentReferenceDeletion"), 1)
        await transport.configure(pages: [.success(.init(records: [item.makeRecord()], deletions: [], token: Data([8]), moreComing: false))])
        try await coordinator.inventory()
        XCTAssertNotNil(try files.attachment(syncId: item.syncId).deletedAt)
    }

    func testInvalidEnvironmentDoesNotChangeScopeOrDirtyState() async throws {
        XCTAssertThrowsError(try SyncedLibrary.validatedAttachmentCloudEnvironment(nil))
        XCTAssertThrowsError(try SyncedLibrary.validatedAttachmentCloudEnvironment(""))
        XCTAssertThrowsError(try SyncedLibrary.validatedAttachmentCloudEnvironment("production"))
        XCTAssertEqual(try SyncedLibrary.validatedAttachmentCloudEnvironment("Production"), "Production")
        XCTAssertEqual(try SyncedLibrary.validatedAttachmentCloudEnvironment("Development"), "Development")
        try receive()
        let before = try await database.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId").map(\.description) }
        let library = SyncedLibrary(appDatabase: database, stateFileURL: root.appendingPathComponent("engine.json"), attachmentSyncEnabledProvider: { true }, attachmentEnvironmentProvider: { "invalid" })
        let primaryMayStart = await library.prepareAttachmentSyncForTest()
        XCTAssertTrue(primaryMayStart)
        let after = try await database.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId").map(\.description) }
        XCTAssertEqual(before, after)
        let activeScope = try await database.dbWriter.read { try AttachmentSyncState.activeScope($0) }
        XCTAssertEqual(activeScope, scope.id)
        let applied = await library.applyFetchedRecordsForTest(modifications: [asset(file: false)], deletions: [])
        XCTAssertTrue(applied)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM syncOrphan"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentQuarantineScope"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM syncSession WHERE key='attachmentInventoryRequired'"), 1)
    }

    func testConfirmedPhysicalDeleteSurvivesCompactionAndNewDeliveryReopensIt() async throws {
        try receive()
        var removed = item!
        removed.deletedAt = Date()
        try coordinator.receive(records: [removed.makeRecord()], deletions: [])
        let library = SyncedLibrary(appDatabase: database, stateFileURL: root.appendingPathComponent("engine.json"))
        try await library.finalizeDeleteOutcomeForTest(entityType: .attachmentAsset, entityId: item.syncId, retainConfirmedTombstone: true)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentServerState WHERE entityType='attachmentAsset' AND physicalDeletedAt IS NOT NULL"), 1)
        try await database.dbWriter.write { try SyncStateStore().compactTombstones($0, olderThan: Date().addingTimeInterval(1)) }
        try coordinator.cleanup()
        try coordinator.cleanup()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tombstone WHERE entityType='attachmentAsset'"), 0)
        // Even an explicit reconciliation must honor the permanent receipt.
        try await database.dbWriter.write { try AttachmentSyncState.requestRemoval(item.syncId, scope: scope.id, db: $0) }
        try coordinator.cleanup()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tombstone WHERE entityType='attachmentAsset'"), 0)
        try coordinator.receive(records: [asset(file: false)], deletions: [])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tombstone WHERE entityType='attachmentAsset' AND confirmedByServer=0"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentServerState WHERE entityType='attachmentAsset' AND physicalDeletedAt IS NOT NULL"), 0)
    }

    func testLateDeleteAcknowledgementCannotCompleteNewChildCleanup() async throws {
        try receive()
        var removed = item!
        removed.deletedAt = Date()
        try coordinator.receive(records: [removed.makeRecord()], deletions: [])
        let attempt = try await database.dbWriter.read { try AttachmentSyncState.deleteAttempt(.attachmentAsset, id: item.syncId, db: $0) }
        let library = SyncedLibrary(appDatabase: database, stateFileURL: root.appendingPathComponent("engine.json"))
        // This arrival supersedes the attempt even within the same clock tick.
        try coordinator.receive(records: [asset(file: false)], deletions: [])
        for retained in [true, false] {
            try await library.finalizeDeleteOutcomeForTest(entityType: .attachmentAsset, entityId: item.syncId,
                retainConfirmedTombstone: retained, attachmentAttempt: attempt)
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tombstone WHERE entityType='attachmentAsset' AND confirmedByServer=0"), 1)
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentServerState WHERE physicalDeletedAt IS NOT NULL"), 0)
        }
        try await library.finalizeDeleteOutcomeForTest(entityType: .attachmentAsset, entityId: item.syncId, retainConfirmedTombstone: true)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentServerState WHERE physicalDeletedAt IS NOT NULL"), 1)
    }

    func testIdleMaintenanceDoesNotRewriteHistoricalRemovalsOrWaitingOrphans() throws {
        let missing = Reference(title: "Later parent")
        item.referenceSyncId = missing.syncId
        try receive()
        XCTAssertEqual(try scalar("SELECT pendingReplay FROM attachmentQuarantineScope"), 0)
        let before = try database.dbWriter.read { $0.totalChangesCount }
        try coordinator.replay()
        try coordinator.cleanup()
        XCTAssertEqual(try database.dbWriter.read { $0.totalChangesCount }, before)
        var inserted = missing
        try database.saveReference(&inserted)
        XCTAssertEqual(try scalar("SELECT pendingReplay FROM attachmentQuarantineScope"), 1)
        try coordinator.replay()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM referenceAttachment"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentQuarantineScope"), 0)
        var removed = item!
        removed.deletedAt = Date()
        try coordinator.receive(records: [removed.makeRecord()], deletions: [])
        let afterRemoval = try database.dbWriter.read { $0.totalChangesCount }
        try coordinator.cleanup()
        try coordinator.cleanup()
        XCTAssertEqual(try database.dbWriter.read { $0.totalChangesCount }, afterRemoval)
    }

    func testNewAccountWithoutZoneFinishesEmptyInventory() async throws {
        await transport.configure(pages: [.failure(CKError(.zoneNotFound))])
        try await coordinator.inventory()
        XCTAssertEqual(try scalar("SELECT inventoryComplete FROM attachmentSyncScope"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM attachmentReferenceDeletion"), 0)
    }

}
#endif
