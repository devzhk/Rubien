#if canImport(CloudKit)
import CloudKit
import Foundation

struct AttachmentInventoryPage: @unchecked Sendable {
    struct Deletion: Sendable { let recordName: String; let recordType: String }
    let records: [CKRecord]
    let deletions: [Deletion]
    let token: Data?
    let moreComing: Bool
}

protocol AttachmentCloudTransport: Sendable {
    func inventoryPage(token: Data?) async throws -> AttachmentInventoryPage
    func record(id: CKRecord.ID, desiredKeys: [String]) async throws -> CKRecord?
}

final class LiveAttachmentCloudTransport: AttachmentCloudTransport, @unchecked Sendable {
    let database: CKDatabase
    init(database: CKDatabase) { self.database = database }

    func inventoryPage(token: Data?) async throws -> AttachmentInventoryPage {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.desiredKeys = AttachmentInventoryProjection.desiredKeys
        configuration.resultsLimit = 200
        if let token {
            do {
                configuration.previousServerChangeToken = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token)
                if configuration.previousServerChangeToken == nil { throw CKError(.changeTokenExpired) }
            } catch { throw CKError(.changeTokenExpired) }
        }
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [SyncConstants.libraryZoneID], configurationsByRecordZoneID: [SyncConstants.libraryZoneID: configuration])
        operation.fetchAllChanges = false
        let buffer = PageBuffer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.recordWasChangedBlock = { _, result in buffer.record(result) }
                operation.recordWithIDWasDeletedBlock = { id, type in buffer.deleted(id, type: type) }
                operation.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case .success(let value):
                        do {
                            let token = try NSKeyedArchiver.archivedData(withRootObject: value.serverChangeToken, requiringSecureCoding: true)
                            buffer.finish(token: token, more: value.moreComing)
                        } catch { buffer.fail(error) }
                    case .failure(let error): buffer.fail(error)
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    if case .failure(let error) = result { buffer.fail(error) }
                    continuation.resume(with: buffer.result())
                }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    func record(id: CKRecord.ID, desiredKeys: [String]) async throws -> CKRecord? {
        // Exact IDs only. Inventory never calls this for a primary PDF.
        let result = try await database.records(for: [id], desiredKeys: desiredKeys)
        guard let result = result[id] else { throw CKError(.internalError) }
        do { return try result.get() }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    private final class PageBuffer: @unchecked Sendable {
        let lock = NSLock()
        var records: [CKRecord] = []
        var deletions: [AttachmentInventoryPage.Deletion] = []
        var token: Data?
        var more = false
        var error: Error?
        func record(_ result: Result<CKRecord, Error>) {
            lock.lock(); defer { lock.unlock() }
            switch result { case .success(let record): records.append(record); case .failure(let error): self.error = error }
        }
        func deleted(_ id: CKRecord.ID, type: String) {
            lock.lock(); defer { lock.unlock() }
            deletions.append(.init(recordName: id.recordName, recordType: type))
        }
        func finish(token: Data, more: Bool) {
            lock.lock(); defer { lock.unlock() }
            self.token = token; self.more = more
        }
        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            // Keep the per-zone cause; the aggregate result may only say partialFailure.
            if self.error == nil { self.error = error }
        }
        func result() -> Result<AttachmentInventoryPage, Error> {
            lock.lock(); defer { lock.unlock() }
            if let error { return .failure(error) }
            guard let token else { return .failure(CKError(.internalError)) }
            return .success(.init(records: records, deletions: deletions, token: token, moreComing: more))
        }
    }
}
#endif
