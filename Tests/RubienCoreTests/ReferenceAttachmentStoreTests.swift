import Foundation
import GRDB
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import RubienCore
#if canImport(PDFKit)
import PDFKit
import RubienPDFKit
#endif

final class ReferenceAttachmentStoreTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var parent: Reference!
    private var store: ReferenceAttachmentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentsTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path))
        parent = Reference(title: "Main paper")
        parent.notes = "Primary notes"
        try database.saveReference(&parent)
        store = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in
            throw ReferenceAttachmentError.invalidPDF
        })
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ text: String = "abc", name: String = "notes.md") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func add(_ text: String = "abc", name: String = "notes.md") throws -> ReferenceAttachment {
        try store.importFile(at: source(text, name: name), referenceId: parent.id!).attachment
    }

    private func count(_ table: String) throws -> Int {
        try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    func testNamedByteLimitsRejectOversizedFilesBeforeCreatingIntent() throws {
        XCTAssertEqual(ReferenceAttachmentKind.pdf.maximumBytes, 262_144_000)
        XCTAssertEqual(ReferenceAttachmentKind.markdown.maximumBytes, 52_428_800)
        for kind in [ReferenceAttachmentKind.pdf, .markdown] {
            let file = try source("", name: "oversized.\(kind.fileExtension)")
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(kind.maximumBytes + 1))
            try handle.close()
            XCTAssertThrowsError(try store.importFile(at: file, referenceId: parent.id!)) {
                XCTAssertEqual($0 as? ReferenceAttachmentError, .tooLarge(kind.maximumBytes))
            }
        }
        XCTAssertEqual(try count("referenceAttachment"), 0)
        XCTAssertEqual(try count("attachmentFileJournal"), 0)
        XCTAssertEqual(try count("attachmentUploadQueue"), 0)
    }

    func testStreamingLimitStillRejectsGrowthAfterPreflight() throws {
        let file = try source("12345")
        XCTAssertEqual(try ReferenceAttachmentStore.hash(file, limit: 5).count, 5)
        XCTAssertThrowsError(try ReferenceAttachmentStore.hash(file, limit: 4)) {
            XCTAssertEqual($0 as? ReferenceAttachmentError, .tooLarge(4))
        }
    }

    func testExportCannotCreateLibraryPromotionMarker() throws {
        let item = try add()
        XCTAssertThrowsError(try store.export(syncId: item.syncId,
            to: root.appendingPathComponent(LibraryRootLease.markerName))) {
            XCTAssertEqual($0 as? ReferenceAttachmentError, .invalidPath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryRootLease.markerName).path))
    }

    func testImportCopiesOriginalBytesQueuesUploadAndLeavesPrimaryUnchanged() throws {
        let input = try source()
        let item = try store.importFile(at: input, referenceId: parent.id!).attachment
        XCTAssertEqual(item.contentHash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(item.byteCount, 3)
        XCTAssertEqual(item.referenceSyncId, parent.syncId)
        XCTAssertNotNil(item.id)
        try FileManager.default.removeItem(at: input)
        XCTAssertEqual(try Data(contentsOf: store.verifiedFileURL(syncId: item.syncId)), Data("abc".utf8))
        XCTAssertEqual(try count("attachmentUploadQueue"), 1)
        XCTAssertEqual(try count("attachmentFileJournal"), 0)
        let main = try database.dbWriter.read { try Reference.fetchOne($0, key: parent.id!)! }
        XCTAssertEqual(main.title, "Main paper")
        XCTAssertEqual(main.notes, "Primary notes")
        XCTAssertEqual(try count("pdfCache"), 0)
    }

    func testDuplicateBytesSkipButSameNameDifferentBytesRemainSeparate() throws {
        let first = try add()
        let duplicate = try store.importFile(at: source(name: "other.md"), referenceId: parent.id!)
        XCTAssertTrue(duplicate.wasDuplicate)
        XCTAssertEqual(duplicate.attachment.syncId, first.syncId)
        let second = try add("different")
        XCTAssertNotEqual(first.syncId, second.syncId)
        XCTAssertEqual(try store.list(referenceId: parent.id!).count, 2)
        XCTAssertEqual(try count("attachmentFileJournal"), 0)
    }

    func testDuplicateDetectionDoesNotCrossReferences() throws {
        let first = try add()
        var other = Reference(title: "Other")
        try database.saveReference(&other)
        let result = try store.importFile(at: source(), referenceId: other.id!)
        XCTAssertFalse(result.wasDuplicate)
        XCTAssertNotEqual(result.attachment.syncId, first.syncId)
    }

    func testRenameOnlyDirtiesMetadataAndDoesNotTouchFileOrAssetIntent() throws {
        let item = try add()
        let before = try store.verifiedFileURL(syncId: item.syncId)
        try database.dbWriter.write { db in
            try db.execute(sql: "UPDATE syncState SET isDirty=0, pushInFlight=1 WHERE entityId=?", arguments: [item.syncId])
            try db.execute(sql: "DELETE FROM attachmentUploadQueue")
        }
        try store.rename(syncId: item.syncId, to: "Supplement")
        let renamed = try store.attachment(syncId: item.syncId)
        XCTAssertEqual(renamed.originalFilename, "notes.md")
        XCTAssertEqual(renamed.displayName, "Supplement")
        XCTAssertEqual(try store.verifiedFileURL(syncId: item.syncId), before)
        XCTAssertEqual(try count("attachmentUploadQueue"), 0)
        try database.dbWriter.read { db in
            let metadata = try Row.fetchOne(db, sql: "SELECT * FROM syncState WHERE entityType='referenceAttachment' AND entityId=?", arguments: [item.syncId])!
            XCTAssertEqual(metadata["isDirty"] as Int, 1)
            XCTAssertEqual(metadata["pushInFlight"] as Int, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='attachmentAsset' AND entityId=?", arguments: [item.syncId]), 0)
        }
    }

    func testRemovalRetainsMarkerAndBytesButCancelsUpload() throws {
        let item = try add()
        let file = try store.verifiedFileURL(syncId: item.syncId)
        try store.remove(syncId: item.syncId)
        let removed = try store.attachment(syncId: item.syncId)
        XCTAssertNotNil(removed.deletedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try store.list(referenceId: parent.id!).isEmpty)
        XCTAssertEqual(try count("attachmentUploadQueue"), 0)
        XCTAssertThrowsError(try store.rename(syncId: item.syncId, to: "Restore"))
        XCTAssertThrowsError(try database.dbWriter.write { db in
            try db.execute(sql: "UPDATE referenceAttachment SET deletedAt=NULL WHERE syncId=?", arguments: [item.syncId])
        })
    }

    func testParentDeletionPreservesGlobalMarkerDuringRemoteApply() throws {
        let item = try add()
        try database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO syncSession(key,value) VALUES('applyingRemote','1')")
            try db.execute(sql: "DELETE FROM syncState WHERE entityId=?", arguments: [item.syncId])
            try db.execute(sql: "DELETE FROM reference WHERE id=?", arguments: [parent.id!])
        }
        let marker = try store.attachment(syncId: item.syncId)
        XCTAssertNil(marker.referenceId)
        XCTAssertEqual(marker.referenceSyncId, parent.syncId)
        XCTAssertNotNil(marker.deletedAt)
        XCTAssertEqual(try count("attachmentUploadQueue"), 0)
        XCTAssertEqual(try database.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT isDirty FROM syncState WHERE entityType='referenceAttachment' AND entityId=?", arguments: [item.syncId])
        }, 1)
    }

    func testFailedCommitAfterPublishRemovesOnlyNewFile() throws {
        let first = try add()
        let firstURL = try store.verifiedFileURL(syncId: first.syncId)
        try database.dbWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_attachment BEFORE INSERT ON referenceAttachment BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        XCTAssertThrowsError(try add("new bytes"))
        XCTAssertEqual(try count("referenceAttachment"), 1)
        XCTAssertEqual(try count("attachmentFileJournal"), 0)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("abc".utf8))
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Attachments"), includingPropertiesForKeys: nil)!
        XCTAssertEqual(files.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.count, 1)
    }

    func testParentDeletedWhileValidatingCannotAdoptFile() throws {
        let db = database!
        let id = parent.id!
        let racingStore = ReferenceAttachmentStore(database: db, libraryRoot: root, validatePDF: { _ in
            try db.dbWriter.write { try $0.execute(sql: "DELETE FROM reference WHERE id=?", arguments: [id]) }
        })
        XCTAssertThrowsError(try racingStore.importFile(at: source("fake pdf", name: "supplement.pdf"), referenceId: id))
        XCTAssertEqual(try count("referenceAttachment"), 0)
        XCTAssertEqual(try count("attachmentFileJournal"), 0)
    }

    func testInvalidUTF8AndPDFLeaveNoRowsOrOwnedFiles() throws {
        let input = root.appendingPathComponent("bad.md")
        try Data([0xff, 0xfe]).write(to: input)
        XCTAssertThrowsError(try store.importFile(at: input, referenceId: parent.id!))
        XCTAssertThrowsError(try store.importFile(at: source("invalid", name: "bad.pdf"), referenceId: parent.id!))
        XCTAssertEqual(try count("referenceAttachment"), 0)
        XCTAssertEqual(try count("attachmentFileJournal"), 0)
    }

    func testRecoveryAfterCrashRemovesUnownedPublishedFileAndKeepsCommittedFile() throws {
        let item = try add()
        let good = try store.verifiedFileURL(syncId: item.syncId)
        let strayPath = "Attachments/\(UUID())/content.md"
        let stray = root.appendingPathComponent(strayPath)
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("interrupted".utf8).write(to: stray)
        try database.dbWriter.write { db in
            for (id, final) in [("orphan", strayPath), ("committed", "Attachments/\(item.syncId)/content.md")] {
                try db.execute(sql: "INSERT INTO attachmentFileJournal VALUES(?, ?, ?, ?, 'import', ?)",
                               arguments: [id, item.syncId, "Attachments/.staging/\(id)/content.md", final, Date()])
            }
        }
        try store.recoverInterruptedImports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertEqual(try Data(contentsOf: good), Data("abc".utf8))
        XCTAssertEqual(try count("attachmentFileJournal"), 0)
    }

    func testPublishedAttachmentsRemainReadableDuringImportValidation() throws {
        let item = try add()
        let existing = store!
        let output = root.appendingPathComponent("during-import.md")
        let validatingStore = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in
            XCTAssertEqual(try String(contentsOf: existing.verifiedFileURL(syncId: item.syncId), encoding: .utf8), "abc")
            try existing.export(syncId: item.syncId, to: output)
            XCTAssertEqual(try existing.status(syncId: item.syncId).localAvailability, "available")
            XCTAssertEqual(try existing.list(referenceId: try XCTUnwrap(item.referenceId)).count, 1)
        })
        _ = try validatingStore.importFile(at: source("bytes", name: "test.pdf"), referenceId: parent.id!)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "abc")
    }

    func testReadWaitingForRecoveryCanBeCancelled() async throws {
        let item = try add()
        let existing = store!
        let lockURL = root.appendingPathComponent("Attachments/.published.lock")
        let fd = open(lockURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let entered = expectation(description: "Reader entered")
        let task = Task.detached {
            entered.fulfill()
            return try existing.verifiedFileURL(syncId: item.syncId)
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled lock wait must stop")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertNoThrow(try existing.verifiedFileURL(syncId: item.syncId))
    }

    func testVerificationCacheDetectsSameSizeEditWithRestoredModificationDate() throws {
        let item = try add()
        let url = try store.verifiedFileURL(syncId: item.syncId)
        let previous = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]!
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("xyz".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: previous], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.verifiedFileURL(syncId: item.syncId)) {
            XCTAssertEqual($0 as? ReferenceAttachmentError, .integrityMismatch)
        }
    }

    func testRecoveryCannotRunDuringAnActiveImport() throws {
        let existing = store!
        let validatingStore = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in
            XCTAssertThrowsError(try existing.recoverInterruptedImports()) {
                XCTAssertEqual($0 as? ReferenceAttachmentError, .busy)
            }
        })
        _ = try validatingStore.importFile(at: source("bytes", name: "test.pdf"), referenceId: parent.id!)
        XCTAssertEqual(try count("referenceAttachment"), 1)
    }

    func testPathTraversalAndSymlinkEscapeAreRejected() throws {
        XCTAssertThrowsError(try store.managedURL("Attachments/../../outside.md"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Attachments/escape"), withDestinationURL: root)
        XCTAssertThrowsError(try store.managedURL("Attachments/escape/notes.md"))
    }

    func testExportDoesNotOverwriteAndCorruptionIsDetected() throws {
        let item = try add()
        let destination = root.appendingPathComponent("export.md")
        try store.export(syncId: item.syncId, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "abc")
        XCTAssertThrowsError(try store.export(syncId: item.syncId, to: destination))
        try Data("xyz".utf8).write(to: store.verifiedFileURL(syncId: item.syncId))
        XCTAssertThrowsError(try store.verifiedFileURL(syncId: item.syncId)) {
            XCTAssertEqual($0 as? ReferenceAttachmentError, .integrityMismatch)
        }
    }

    func testConfirmedExportReplacementPreservesManagedFile() throws {
        let item = try add()
        let destination = root.appendingPathComponent("copy.md")
        try Data("old".utf8).write(to: destination)
        try store.export(syncId: item.syncId, to: destination, replaceExisting: true)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "abc")
        let managed = try store.verifiedFileURL(syncId: item.syncId)
        XCTAssertThrowsError(try store.export(syncId: item.syncId, to: managed, replaceExisting: true))
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "abc")
    }

    func testReadingPositionsAreLocalIsolatedAndRejectStaleOrInvalidPayloads() throws {
        let first = try add()
        let second = try add("other")
        let before = try database.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }
        try ReferenceAttachmentPosition.markdown(fraction: 0.6).save(attachment: first, database: database)
        XCTAssertEqual(try ReferenceAttachmentPosition.load(attachment: first, database: database), .markdown(fraction: 0.6))
        XCTAssertNil(try ReferenceAttachmentPosition.load(attachment: second, database: database))
        XCTAssertEqual(try database.dbWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM syncState ORDER BY entityType,entityId") }, before)
        XCTAssertThrowsError(try ReferenceAttachmentPosition.pdf(pageIndex: 3).save(attachment: first, database: database))
        XCTAssertThrowsError(try ReferenceAttachmentPosition.markdown(fraction: .nan).save(attachment: first, database: database))
        try database.dbWriter.write { db in
            try db.execute(sql: "UPDATE attachmentReaderState SET positionVersion=99")
        }
        XCTAssertNil(try ReferenceAttachmentPosition.load(attachment: first, database: database))
        try store.remove(syncId: first.syncId)
        try ReferenceAttachmentPosition.markdown(fraction: 0.8).save(attachment: first, database: database)
        XCTAssertNil(try ReferenceAttachmentPosition.load(attachment: first, database: database))
    }

    func testAnnotationsAreIsolatedAndRemovalMarkerCannotBeCleared() throws {
        let first = try add()
        let second = try add("other")
        let annotation = try store.addAnnotation(attachmentSyncId: first.syncId, type: .highlight,
                                                anchor: .markdown(text: "abc", prefix: nil, suffix: nil))
        XCTAssertNotNil(annotation.anchor)
        XCTAssertTrue(try store.annotations(attachmentSyncId: second.syncId).isEmpty)
        XCTAssertEqual(try count("webAnnotation"), 0)
        try store.removeAnnotation(syncId: annotation.syncId)
        XCTAssertTrue(try store.annotations(attachmentSyncId: first.syncId).isEmpty)
        XCTAssertEqual(try count("attachmentAnnotation"), 1)
        XCTAssertThrowsError(try store.updateAnnotationNote(syncId: annotation.syncId, note: "stale edit"))
        XCTAssertThrowsError(try database.dbWriter.write { db in
            try db.execute(sql: "UPDATE attachmentAnnotation SET deletedAt=NULL WHERE syncId=?", arguments: [annotation.syncId])
        })
    }

    func testRemovingAttachmentBlocksAnnotationWrites() throws {
        let item = try add()
        let note = try store.addAnnotation(attachmentSyncId: item.syncId, type: .note,
                                          anchor: .markdown(text: "abc", prefix: nil, suffix: nil))
        try store.remove(syncId: item.syncId)
        XCTAssertTrue(try store.annotations(attachmentSyncId: item.syncId).isEmpty)
        XCTAssertThrowsError(try store.updateAnnotationNote(syncId: note.syncId, note: "late"))
        XCTAssertThrowsError(try store.addAnnotation(attachmentSyncId: item.syncId, type: .highlight,
                                                   anchor: .markdown(text: "abc", prefix: nil, suffix: nil)))
    }

    #if canImport(PDFKit)
    func testPDFBackendValidatesAndImportsSupplement() throws {
        let document = PDFKit.PDFDocument()
        let page = PDFKit.PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        document.insert(page, at: 0)
        let input = root.appendingPathComponent("supplement.pdf")
        try XCTUnwrap(document.dataRepresentation()).write(to: input)
        let pdfStore = ReferenceAttachmentStore(database: database, libraryRoot: root,
                                               validatePDF: { try ReferenceAttachmentPDFValidator.validate($0) })
        let result = try pdfStore.importFile(at: input, referenceId: parent.id!)
        XCTAssertEqual(result.attachment.supportedKind, .pdf)
        XCTAssertNotNil(PDFKit.PDFDocument(url: try pdfStore.verifiedFileURL(syncId: result.attachment.syncId)))
        XCTAssertThrowsError(try pdfStore.importFile(at: source("not PDF", name: "invalid.pdf"), referenceId: parent.id!))
    }
    #endif
}
