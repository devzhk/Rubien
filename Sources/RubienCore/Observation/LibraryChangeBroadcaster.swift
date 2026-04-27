import Combine
import Foundation
import notify
import os.log

private let broadcasterLog = Logger(subsystem: "Rubien", category: "LibraryChangeBroadcaster")

/// Cross-process invalidation channel for the shared SQLite library.
///
/// GRDB `ValueObservation` only fires for transactions committed through the
/// same `DatabasePool` instance. When `rubien-cli` (a separate process,
/// invoked by the MCP server) writes to the shared App-Group library, the
/// running app's observers are blind to the change. This broadcaster bridges
/// the gap with a Darwin notification: the CLI calls
/// `LibraryChangeBroadcaster.postChangeNotification()` after each successful
/// mutating subcommand; the app subscribes via `notify_register_dispatch` and
/// re-fetches its `observe*` queries.
///
/// Symmetry note: only the CLI posts. The app's own writes already trigger
/// `ValueObservation` in-process — posting from the app would loop.
///
/// `@unchecked Sendable`: the only stored property is a `PassthroughSubject`,
/// whose `send` is documented thread-safe but isn't itself `Sendable`. The
/// notify token is intentionally not retained — we never deregister.
public final class LibraryChangeBroadcaster: @unchecked Sendable {
    public static let shared = LibraryChangeBroadcaster()

    /// Reverse-DNS notification name. The App Group prefix keeps it
    /// namespaced and deliverable across the sandboxed app / non-sandboxed
    /// CLI boundary without any additional entitlement.
    static let notifyName = "\(AppDatabase.appGroupID).library.changed"

    /// `Void` events fire whenever an external process posts the notification
    /// or `triggerLocalRefresh()` is invoked.
    public var events: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()

    private init() {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(Self.notifyName, &token, .main) { [weak self] _ in
            self?.subject.send(())
        }
        if status != NOTIFY_STATUS_OK {
            broadcasterLog.error("notify_register_dispatch failed with status \(status, privacy: .public)")
        }
    }

    /// Post a Darwin notification so subscribers in any process re-fetch.
    /// Safe to call from `rubien-cli` after each successful mutating subcommand.
    /// `notify_post` is coalesced by the OS — bursts of writes deliver as a
    /// single event to subscribers, which is exactly the desired UI behavior.
    public static func postChangeNotification() {
        notify_post(notifyName)
    }

    /// In-process trigger. Used by the app's `didBecomeActive` hook and by
    /// tests so they don't depend on Darwin notify timing.
    public func triggerLocalRefresh() {
        subject.send(())
    }
}
