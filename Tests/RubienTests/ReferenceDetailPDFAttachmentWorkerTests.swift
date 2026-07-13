#if os(macOS)
import XCTest
import GRDB
@testable import Rubien
@testable import RubienCore

@MainActor
final class ReferenceDetailPDFAttachmentWorkerTests: XCTestCase {
    private enum TestFailure: Error {
        case replacementCommitFailed
        case writerGateTimedOut
    }

    func testOperationRegistryKeepsReferenceBusyAcrossSelectionChanges() {
        var registry = ReferenceDetailPDFOperationRegistry()

        XCTAssertTrue(registry.begin(.download, for: 1))
        XCTAssertNil(registry.operation(for: 2), "another selection remains available")
        XCTAssertEqual(registry.operation(for: 1), .download)
        XCTAssertFalse(
            registry.begin(.attachment, for: 1),
            "returning to the first selection must not start a competing operation"
        )

        registry.finish(.download, for: 1)
        XCTAssertTrue(registry.begin(.attachment, for: 1))
    }

    func testCopyAndDatabaseCommitRunOffMainThread() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let sourceURL = URL(fileURLWithPath: "/tmp/reference-detail-worker-source.pdf")

        let outcome = await ReferenceDetailPDFAttachmentWorker.attach(
            sourceURL: sourceURL,
            referenceId: 42,
            database: database,
            importer: { receivedURL in
                XCTAssertFalse(Thread.isMainThread, "PDF copying must not block the main thread")
                XCTAssertEqual(receivedURL, sourceURL)
                return "copied.pdf"
            },
            attacher: { receivedDatabase, referenceId, filename in
                XCTAssertFalse(Thread.isMainThread, "a busy SQLite writer must not block the main thread")
                XCTAssertTrue(receivedDatabase === database)
                XCTAssertEqual(referenceId, 42)
                XCTAssertEqual(filename, "copied.pdf")
                return true
            },
            deleter: { _ in
                XCTFail("a successfully attached copy must not be deleted")
            }
        )

        XCTAssertEqual(outcome, .attached)
    }

    func testDownloadedFileIsDeletedWhenConcurrentAttachmentWins() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let deleted = expectation(description: "unowned copy deleted")

        let outcome = await ReferenceDetailPDFAttachmentWorker.registerImportedPDF(
            filename: "unowned.pdf",
            referenceId: 42,
            database: database,
            attacher: { _, _, _ in
                XCTAssertFalse(Thread.isMainThread, "download persistence must not block the main thread")
                return false
            },
            deleter: { filename in
                XCTAssertEqual(filename, "unowned.pdf")
                deleted.fulfill()
            }
        )

        await fulfillment(of: [deleted], timeout: 1)
        XCTAssertEqual(outcome, .alreadyAttached)
    }

    func testFailedReplacementDownloadLeavesExistingAttachmentUntouched() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let reference = Reference(title: "Replacement")

        let outcome = await ReferenceDetailPDFAttachmentWorker.downloadAndAttach(
            reference: reference,
            referenceId: 42,
            database: database,
            replacingExisting: true,
            downloader: { _ in throw URLError(.notConnectedToInternet) },
            attacher: { _, _, _ in
                XCTFail("a failed download must not attempt attachment")
                return true
            },
            replacer: { _, _, _ in
                XCTFail("a failed download must not replace the current attachment")
                return "existing.pdf"
            },
            deleter: { _ in
                XCTFail("a failed download produced no new file to delete")
            }
        )

        guard case .failed = outcome else {
            return XCTFail("Expected download failure")
        }
    }

    func testReplacementDeletesPriorFileOnlyAfterCommit() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let committed = expectation(description: "replacement committed")
        let deleted = expectation(description: "prior file deleted")

        let outcome = await ReferenceDetailPDFAttachmentWorker.downloadAndAttach(
            reference: Reference(title: "Replacement"),
            referenceId: 42,
            database: database,
            replacingExisting: true,
            downloader: { _ in "new.pdf" },
            attacher: { _, _, _ in
                XCTFail("replacement must use the atomic swap path")
                return true
            },
            replacer: { _, referenceId, filename in
                XCTAssertFalse(Thread.isMainThread, "replacement commit must not block the main thread")
                XCTAssertEqual(referenceId, 42)
                XCTAssertEqual(filename, "new.pdf")
                committed.fulfill()
                return "old.pdf"
            },
            deleter: { filename in
                XCTAssertEqual(filename, "old.pdf")
                deleted.fulfill()
            }
        )

        await fulfillment(of: [committed, deleted], timeout: 1, enforceOrder: true)
        XCTAssertEqual(outcome, .attached)
    }

    func testReplacementCommitFailureDeletesOnlyNewFile() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let deleted = expectation(description: "uncommitted replacement deleted")

        let outcome = await ReferenceDetailPDFAttachmentWorker.downloadAndAttach(
            reference: Reference(title: "Replacement"),
            referenceId: 42,
            database: database,
            replacingExisting: true,
            downloader: { _ in "new.pdf" },
            replacer: { _, _, _ in throw TestFailure.replacementCommitFailed },
            deleter: { filename in
                XCTAssertEqual(filename, "new.pdf")
                deleted.fulfill()
            }
        )

        await fulfillment(of: [deleted], timeout: 1)
        guard case .failed = outcome else {
            return XCTFail("Expected replacement commit failure")
        }
    }

    func testBusyWriterDoesNotBlockMainQueue() async throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(title: "Contended")
        try database.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)

        let writerBusy = expectation(description: "writer queue occupied")
        let writerGate = DispatchSemaphore(value: 0)
        let blockerTask = Task.detached {
            try await database.dbWriter.write { db in
                writerBusy.fulfill()
                guard writerGate.wait(timeout: .now() + 2) == .success else {
                    throw TestFailure.writerGateTimedOut
                }
                try db.execute(
                    sql: "UPDATE reference SET title = 'Still contended' WHERE id = ?",
                    arguments: [referenceId]
                )
            }
        }
        await fulfillment(of: [writerBusy], timeout: 1)

        let attachmentWaiting = expectation(description: "attachment waiting for writer")
        let attachmentTask = Task {
            await ReferenceDetailPDFAttachmentWorker.attach(
                sourceURL: URL(fileURLWithPath: "/tmp/reference-detail-worker-source.pdf"),
                referenceId: referenceId,
                database: database,
                importer: { _ in "contended.pdf" },
                attacher: { database, referenceId, filename in
                    attachmentWaiting.fulfill()
                    return try database.attachImportedPDF(
                        referenceId: referenceId,
                        filename: filename
                    )
                },
                deleter: { _ in
                    XCTFail("the attachment should succeed once the writer is released")
                }
            )
        }
        await fulfillment(of: [attachmentWaiting], timeout: 1)

        let heartbeat = expectation(description: "main queue heartbeat")
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        writerGate.signal()

        let outcome = await attachmentTask.value
        XCTAssertEqual(outcome, .attached)
        try await blockerTask.value
    }
}
#endif
