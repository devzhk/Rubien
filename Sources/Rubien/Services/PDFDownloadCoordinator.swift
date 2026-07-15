#if os(macOS)
import Combine
import Foundation
import os
import RubienCore
import RubienPDFKit

private let pdfDownloadLog = Logger(subsystem: "Rubien", category: "pdf-download")

struct PDFDownloadActivity: Equatable, Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        case downloading
        case succeeded
        case failed(String)
    }

    let referenceID: Int64
    let referenceTitle: String
    let attemptID: UUID
    let startedAt: Date
    var phase: Phase

    var id: Int64 { referenceID }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }
}

typealias LibraryPDFDownloadOperation = @Sendable (
    _ reference: Reference,
    _ referenceID: Int64,
    _ pdfURLOverride: String?,
    _ database: AppDatabase,
    _ storageRoot: URL
) async -> ReferenceDetailPDFAttachmentWorker.Outcome

/// App-scoped owner for Add-by-Identifier PDF downloads. Every library window
/// observes the same activities and shares the same per-reference operation
/// registry, preventing duplicate network transfers and cross-window PDF races.
@MainActor
final class PDFDownloadCoordinator: ObservableObject {
    @Published private(set) var activities: [Int64: PDFDownloadActivity] = [:]
    @Published var operations = ReferenceDetailPDFOperationRegistry()

    private let database: AppDatabase
    private let storageRoot: URL
    private var tasks: [Int64: Task<Void, Never>] = [:]
    private var requests: [Int64: DownloadRequest] = [:]
    weak var syncCoordinator: SyncCoordinator?

    private static let maximumRetainedFinishedActivities = 20

    private struct DownloadRequest: Sendable {
        let id = UUID()
        let reference: Reference
        let pdfURLOverride: String?
        let operation: LibraryPDFDownloadOperation
    }

    init(
        database: AppDatabase = .shared,
        storageRoot: URL = AppDatabase.pdfStorageURL
    ) {
        self.database = database
        self.storageRoot = storageRoot
    }

    var orderedActivities: [PDFDownloadActivity] {
        activities.values.sorted { lhs, rhs in
            let lhsPriority = Self.priority(lhs.phase)
            let rhsPriority = Self.priority(rhs.phase)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.startedAt > rhs.startedAt
        }
    }

    func isDownloading(referenceID: Int64?) -> Bool {
        guard let referenceID else { return false }
        return activities[referenceID]?.isDownloading == true
    }

    func download(
        reference: Reference,
        referenceID: Int64,
        pdfURLOverride: String? = nil
    ) {
        download(
            reference: reference,
            referenceID: referenceID,
            pdfURLOverride: pdfURLOverride,
            operation: { reference, referenceID, pdfURLOverride, database, storageRoot in
                await Self.performDownload(
                    reference: reference,
                    referenceID: referenceID,
                    pdfURLOverride: pdfURLOverride,
                    database: database,
                    storageRoot: storageRoot
                )
            }
        )
    }

    /// Injection point for state-transition tests.
    func download(
        reference: Reference,
        referenceID: Int64,
        pdfURLOverride: String? = nil,
        operation: @escaping LibraryPDFDownloadOperation
    ) {
        let request = DownloadRequest(
            reference: reference,
            pdfURLOverride: pdfURLOverride,
            operation: operation
        )
        start(request, referenceID: referenceID)
    }

    func retry(referenceID: Int64) {
        guard let request = requests[referenceID],
              !isDownloading(referenceID: referenceID)
        else { return }
        let database = database
        Task.detached(priority: .userInitiated) { [weak self] in
            let exists = Self.referenceExists(referenceID: referenceID, database: database)
            await self?.resumeRetry(
                request,
                referenceID: referenceID,
                referenceExists: exists
            )
        }
    }

    func dismiss(referenceID: Int64) {
        guard !isDownloading(referenceID: referenceID) else { return }
        activities.removeValue(forKey: referenceID)
        requests.removeValue(forKey: referenceID)
    }

    func referencesWereDeleted(_ referenceIDs: [Int64]) {
        for referenceID in referenceIDs {
            cancel(referenceID: referenceID)
        }
    }

    nonisolated static func performDownload(
        reference: Reference,
        referenceID: Int64,
        pdfURLOverride: String?,
        database: AppDatabase,
        storageRoot: URL
    ) async -> ReferenceDetailPDFAttachmentWorker.Outcome {
        await performDownload(
            reference: reference,
            referenceID: referenceID,
            database: database,
            storageRoot: storageRoot,
            downloader: { reference in
                try await PDFDownloadService.downloadPDF(
                    for: reference,
                    overrideURL: pdfURLOverride
                )
            }
        )
    }

    /// Internal overload keeps stale-cache behavior testable without network.
    nonisolated static func performDownload(
        reference: Reference,
        referenceID: Int64,
        database: AppDatabase,
        storageRoot: URL,
        downloader: @escaping ReferenceDetailPDFAttachmentWorker.Downloader
    ) async -> ReferenceDetailPDFAttachmentWorker.Outcome {
        let cache = PDFAssetCache(db: database, storageRoot: storageRoot)
        do {
            while let metadata = try await cache.metadataFor(referenceId: referenceID),
                  metadata.materializedAt != nil {
                if try await cache.pathFor(referenceId: referenceID) != nil {
                    return .alreadyAttached
                }
                // A materialized row whose file vanished would make
                // `attachImportedPDF` preserve a nonexistent attachment.
                // Compare-and-swap the observed row so a newer CloudKit
                // materialization cannot be dematerialized by this repair.
                if try await cache.dematerializeIfUnchanged(metadata) {
                    break
                }
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        return await ReferenceDetailPDFAttachmentWorker.downloadAndAttach(
            reference: reference,
            referenceId: referenceID,
            database: database,
            replacingExisting: false,
            downloader: downloader
        )
    }

    private func start(_ request: DownloadRequest, referenceID: Int64) {
        guard !isDownloading(referenceID: referenceID),
              operations.begin(.download, for: referenceID)
        else { return }

        let attemptID = UUID()
        requests[referenceID] = request
        activities[referenceID] = PDFDownloadActivity(
            referenceID: referenceID,
            referenceTitle: request.reference.title,
            attemptID: attemptID,
            startedAt: Date(),
            phase: .downloading
        )

        let database = database
        let storageRoot = storageRoot
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await request.operation(
                request.reference,
                referenceID,
                request.pdfURLOverride,
                database,
                storageRoot
            )
            let exists = Self.referenceExists(referenceID: referenceID, database: database)
            await self?.finish(
                referenceID: referenceID,
                attemptID: attemptID,
                outcome: outcome,
                referenceExists: exists
            )
        }
        tasks[referenceID] = task
    }

    private func resumeRetry(
        _ request: DownloadRequest,
        referenceID: Int64,
        referenceExists: Bool
    ) {
        guard requests[referenceID]?.id == request.id,
              !isDownloading(referenceID: referenceID)
        else { return }
        guard referenceExists else {
            activities.removeValue(forKey: referenceID)
            requests.removeValue(forKey: referenceID)
            return
        }
        start(request, referenceID: referenceID)
    }

    private func finish(
        referenceID: Int64,
        attemptID: UUID,
        outcome: ReferenceDetailPDFAttachmentWorker.Outcome,
        referenceExists: Bool
    ) {
        guard var activity = activities[referenceID],
              activity.attemptID == attemptID
        else { return }

        tasks.removeValue(forKey: referenceID)
        operations.finish(.download, for: referenceID)
        guard referenceExists else {
            activities.removeValue(forKey: referenceID)
            requests.removeValue(forKey: referenceID)
            return
        }
        switch outcome {
        case .attached:
            activity.phase = .succeeded
            activities[referenceID] = activity
            Task { await syncCoordinator?.kickPDFUploadDrainer() }
            scheduleSuccessDismissal(referenceID: referenceID, attemptID: attemptID)
        case .alreadyAttached:
            activity.phase = .succeeded
            activities[referenceID] = activity
            scheduleSuccessDismissal(referenceID: referenceID, attemptID: attemptID)
        case .failed(let message):
            pdfDownloadLog.error("Background PDF download failed: \(message, privacy: .public)")
            activity.phase = .failed(message)
            activities[referenceID] = activity
        }
        trimFinishedActivities()
    }

    private func scheduleSuccessDismissal(referenceID: Int64, attemptID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  self.activities[referenceID]?.attemptID == attemptID
            else { return }
            self.activities.removeValue(forKey: referenceID)
            self.requests.removeValue(forKey: referenceID)
        }
    }

    private func cancel(referenceID: Int64) {
        tasks.removeValue(forKey: referenceID)?.cancel()
        activities.removeValue(forKey: referenceID)
        requests.removeValue(forKey: referenceID)
        operations.finish(.download, for: referenceID)
    }

    private func trimFinishedActivities() {
        let stale = activities.values
            .filter { !$0.isDownloading }
            .sorted { $0.startedAt > $1.startedAt }
            .dropFirst(Self.maximumRetainedFinishedActivities)
        for activity in stale {
            activities.removeValue(forKey: activity.referenceID)
            requests.removeValue(forKey: activity.referenceID)
        }
    }

    nonisolated private static func referenceExists(
        referenceID: Int64,
        database: AppDatabase
    ) -> Bool {
        do {
            return try !database.fetchReferences(ids: [referenceID]).isEmpty
        } catch {
            // A transient read error should preserve the actionable outcome
            // rather than silently discarding it as though the row vanished.
            return true
        }
    }

    private static func priority(_ phase: PDFDownloadActivity.Phase) -> Int {
        switch phase {
        case .downloading: return 0
        case .failed: return 1
        case .succeeded: return 2
        }
    }
}
#endif
