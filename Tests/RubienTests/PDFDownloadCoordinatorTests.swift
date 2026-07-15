#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

@MainActor
final class PDFDownloadCoordinatorTests: XCTestCase {
    private enum TestFailure: Error {
        case timedOut
    }

    private actor OutcomeGate {
        private var continuation: CheckedContinuation<ReferenceDetailPDFAttachmentWorker.Outcome, Never>?
        private var didStart = false

        func run() async -> ReferenceDetailPDFAttachmentWorker.Outcome {
            didStart = true
            return await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted(timeout: TimeInterval = 1) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !didStart {
                guard Date() < deadline else { throw TestFailure.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func finish(_ outcome: ReferenceDetailPDFAttachmentWorker.Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private actor OutcomeScript {
        private var outcomes: [ReferenceDetailPDFAttachmentWorker.Outcome]
        private(set) var callCount = 0

        init(_ outcomes: [ReferenceDetailPDFAttachmentWorker.Outcome]) {
            self.outcomes = outcomes
        }

        func next() -> ReferenceDetailPDFAttachmentWorker.Outcome {
            callCount += 1
            return outcomes.removeFirst()
        }
    }

    private actor CallCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    private func makeTestDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-pdf-download-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func saveReference(title: String, database: AppDatabase) throws -> Reference {
        var reference = Reference(title: title)
        try database.saveReference(&reference)
        return reference
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TestFailure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testPublishesActiveThenSuccessfulState() async throws {
        let database = try makeTestDB()
        let storageRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let coordinator = PDFDownloadCoordinator(database: database, storageRoot: storageRoot)
        let gate = OutcomeGate()
        let reference = try saveReference(title: "Visible progress", database: database)
        let referenceID = try XCTUnwrap(reference.id)

        coordinator.download(reference: reference, referenceID: referenceID) { _, _, _, _, _ in
            await gate.run()
        }

        XCTAssertEqual(coordinator.activities[referenceID]?.referenceTitle, "Visible progress")
        XCTAssertEqual(coordinator.activities[referenceID]?.phase, .downloading)
        XCTAssertTrue(coordinator.isDownloading(referenceID: referenceID))
        XCTAssertEqual(coordinator.operations.operation(for: referenceID), .download)

        try await gate.waitUntilStarted()
        await gate.finish(.attached)
        try await waitUntil { coordinator.activities[referenceID]?.phase == .succeeded }

        XCTAssertFalse(coordinator.isDownloading(referenceID: referenceID))
        XCTAssertNil(coordinator.operations.operation(for: referenceID))
    }

    func testFailurePersistsAndRetryStartsAnotherAttempt() async throws {
        let database = try makeTestDB()
        let coordinator = PDFDownloadCoordinator(database: database)
        let script = OutcomeScript([.failed("offline"), .attached])
        let reference = try saveReference(title: "Retry me", database: database)
        let referenceID = try XCTUnwrap(reference.id)

        coordinator.download(reference: reference, referenceID: referenceID) { _, _, _, _, _ in
            await script.next()
        }
        try await waitUntil { coordinator.activities[referenceID]?.phase == .failed("offline") }

        coordinator.retry(referenceID: referenceID)
        try await waitUntil { coordinator.activities[referenceID]?.phase == .succeeded }
        let callCount = await script.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testDuplicateRequestDoesNotStartAnotherTransfer() async throws {
        let database = try makeTestDB()
        let coordinator = PDFDownloadCoordinator(database: database)
        let gate = OutcomeGate()
        let calls = CallCounter()
        let reference = try saveReference(title: "One transfer", database: database)
        let referenceID = try XCTUnwrap(reference.id)
        let operation: LibraryPDFDownloadOperation = { _, _, _, _, _ in
            await calls.increment()
            return await gate.run()
        }

        coordinator.download(reference: reference, referenceID: referenceID, operation: operation)
        coordinator.download(reference: reference, referenceID: referenceID, operation: operation)
        try await gate.waitUntilStarted()

        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(coordinator.activities.count, 1)

        await gate.finish(.attached)
        try await waitUntil { coordinator.activities[referenceID]?.phase == .succeeded }
    }

    func testManualAttachmentBlocksAutomaticDownload() async throws {
        let database = try makeTestDB()
        let coordinator = PDFDownloadCoordinator(database: database)
        let calls = CallCounter()
        let reference = try saveReference(title: "Busy", database: database)
        let referenceID = try XCTUnwrap(reference.id)
        XCTAssertTrue(coordinator.operations.begin(.attachment, for: referenceID))

        coordinator.download(reference: reference, referenceID: referenceID) { _, _, _, _, _ in
            await calls.increment()
            return .attached
        }
        await Task.yield()

        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(coordinator.activities[referenceID])
        XCTAssertEqual(coordinator.operations.operation(for: referenceID), .attachment)
    }

    func testDeletingReferenceCancelsAndClearsVisibleDownload() async throws {
        let database = try makeTestDB()
        let storageRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let coordinator = PDFDownloadCoordinator(database: database, storageRoot: storageRoot)
        let viewModel = LibraryViewModel(db: database)
        viewModel.pdfDownloadCoordinator = coordinator
        let gate = OutcomeGate()
        var reference = Reference(title: "Delete while downloading")
        viewModel.saveReference(&reference)
        let referenceID = try XCTUnwrap(reference.id)

        coordinator.download(reference: reference, referenceID: referenceID) { _, _, _, _, _ in
            await gate.run()
        }
        try await gate.waitUntilStarted()
        viewModel.deleteReferences([reference])

        XCTAssertTrue(try database.fetchReferences(ids: [referenceID]).isEmpty)
        XCTAssertNil(coordinator.activities[referenceID])
        XCTAssertNil(coordinator.operations.operation(for: referenceID))

        await gate.finish(.attached)
        await Task.yield()
        XCTAssertNil(coordinator.activities[referenceID], "a cancelled attempt must not republish state")
    }

    func testExternalDeletionDiscardsCompletedAttemptState() async throws {
        let database = try makeTestDB()
        let coordinator = PDFDownloadCoordinator(database: database)
        let gate = OutcomeGate()
        let reference = try saveReference(title: "Deleted elsewhere", database: database)
        let referenceID = try XCTUnwrap(reference.id)

        coordinator.download(reference: reference, referenceID: referenceID) { _, _, _, _, _ in
            await gate.run()
        }
        try await gate.waitUntilStarted()
        try database.deleteReferences(ids: [referenceID])
        await gate.finish(.failed("foreign key failure"))

        try await waitUntil {
            coordinator.activities[referenceID] == nil
                && coordinator.operations.operation(for: referenceID) == nil
        }
    }

    func testRetryDiscardsFailureWhenReferenceWasDeletedElsewhere() async throws {
        let database = try makeTestDB()
        let coordinator = PDFDownloadCoordinator(database: database)
        let script = OutcomeScript([.failed("offline"), .attached])
        let reference = try saveReference(title: "Deleted before retry", database: database)
        let referenceID = try XCTUnwrap(reference.id)

        coordinator.download(reference: reference, referenceID: referenceID) { _, _, _, _, _ in
            await script.next()
        }
        try await waitUntil { coordinator.activities[referenceID]?.phase == .failed("offline") }
        try database.deleteReferences(ids: [referenceID])

        coordinator.retry(referenceID: referenceID)
        try await waitUntil { coordinator.activities[referenceID] == nil }
        let callCount = await script.callCount
        XCTAssertEqual(callCount, 1, "retry must not restart work for a deleted reference")
    }

    func testMissingMaterializedFileIsDematerializedAndReplaced() async throws {
        let database = try makeTestDB()
        let storageRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        var reference = Reference(title: "Repair stale cache")
        try database.saveReference(&reference)
        let referenceID = try XCTUnwrap(reference.id)
        try insertCacheRow(
            referenceID: referenceID,
            filename: "vanished.pdf",
            materializedAt: Date(),
            database: database
        )
        let replacementURL = storageRoot.appendingPathComponent("replacement.pdf")
        try Data("%PDF-1.4".utf8).write(to: replacementURL)
        let calls = CallCounter()

        let outcome = await PDFDownloadCoordinator.performDownload(
            reference: reference,
            referenceID: referenceID,
            database: database,
            storageRoot: storageRoot,
            downloader: { _ in
                await calls.increment()
                return "replacement.pdf"
            }
        )

        XCTAssertEqual(outcome, .attached)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(try database.pdfFilename(for: referenceID), "replacement.pdf")
        let cache = PDFAssetCache(db: database, storageRoot: storageRoot)
        let cachedPath = try await cache.pathFor(referenceId: referenceID)
        XCTAssertEqual(cachedPath, replacementURL)
    }

    func testReachableMaterializedFileSkipsDownload() async throws {
        let database = try makeTestDB()
        let storageRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        var reference = Reference(title: "Already attached")
        try database.saveReference(&reference)
        let referenceID = try XCTUnwrap(reference.id)
        let existingURL = storageRoot.appendingPathComponent("existing.pdf")
        try Data("%PDF-1.4".utf8).write(to: existingURL)
        try insertCacheRow(
            referenceID: referenceID,
            filename: "existing.pdf",
            materializedAt: Date(),
            database: database
        )
        let calls = CallCounter()

        let outcome = await PDFDownloadCoordinator.performDownload(
            reference: reference,
            referenceID: referenceID,
            database: database,
            storageRoot: storageRoot,
            downloader: { _ in
                await calls.increment()
                return "unexpected.pdf"
            }
        )

        XCTAssertEqual(outcome, .alreadyAttached)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try database.pdfFilename(for: referenceID), "existing.pdf")
    }

    func testFinishedHistoryIsBounded() async throws {
        let database = try makeTestDB()
        let coordinator = PDFDownloadCoordinator(database: database)

        for index in 1...25 {
            let reference = try saveReference(title: "Failure \(index)", database: database)
            let referenceID = try XCTUnwrap(reference.id)
            coordinator.download(
                reference: reference,
                referenceID: referenceID
            ) { _, _, _, _, _ in
                .failed("offline")
            }
        }

        try await waitUntil {
            !coordinator.activities.values.contains(where: \.isDownloading)
        }
        XCTAssertEqual(coordinator.activities.count, 20)
    }

    private func insertCacheRow(
        referenceID: Int64,
        filename: String,
        materializedAt: Date?,
        database: AppDatabase
    ) throws {
        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId,
                    localFilename,
                    contentHash,
                    assetVersion,
                    materializedAt,
                    lastOpenedAt
                ) VALUES (?, ?, 'pending', 1, ?, ?)
                """, arguments: [referenceID, filename, materializedAt, Date()])
        }
    }
}
#endif
