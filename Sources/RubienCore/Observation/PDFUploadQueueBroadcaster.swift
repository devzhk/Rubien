import Foundation
#if canImport(Combine) && canImport(Darwin)
import Combine
import notify

private let pdfQueueBroadcasterLog = RubienLogger(subsystem: "Rubien",
                                                  category: "PDFUploadQueueBroadcaster")

/// Cross-process kick channel for the PDF upload queue. The one-shot
/// CLI can't drive `CKSyncEngine`; posting here signals the running app
/// to drain its queue immediately. Mirrors `LibraryChangeBroadcaster`'s
/// Darwin-notify pattern (App-Group-prefixed so it crosses the sandbox
/// boundary without extra entitlements).
public final class PDFUploadQueueBroadcaster: @unchecked Sendable {
    public static let shared = PDFUploadQueueBroadcaster()

    static let notifyName = "\(AppDatabase.appGroupID).pdfUploadQueue.changed"

    /// **Linux invariant.** This member is intentionally absent from the
    /// Linux stub. Any new consumer of `.events` must live inside
    /// `#if canImport(Combine) && canImport(Darwin)`.
    public var events: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()

    private init() {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(Self.notifyName, &token, .main) { [weak self] _ in
            self?.subject.send(())
        }
        if status != NOTIFY_STATUS_OK {
            pdfQueueBroadcasterLog.error("notify_register_dispatch failed with status \(status)")
        }
    }

    /// Coalesced by the OS — safe to call after every `attachImportedPDFs`
    /// from the CLI.
    public static func postChangeNotification() {
        notify_post(Self.notifyName)
    }
}
#else
/// Linux stub. See `LibraryChangeBroadcaster` for the invariant.
public final class PDFUploadQueueBroadcaster: Sendable {
    public static let shared = PDFUploadQueueBroadcaster()
    private init() {}
    public static func postChangeNotification() {}
}
#endif
