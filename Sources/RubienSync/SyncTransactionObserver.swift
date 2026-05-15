#if canImport(CloudKit)
import Foundation
import GRDB

/// GRDB `TransactionObserver` that forwards post-commit mutations into the
/// `SyncedLibrary` actor. Watches only the sync-bookkeeping tables that the
/// per-table triggers write to, so we skip the noise of every scalar-level
/// change — the triggers have already condensed "anything touched table X
/// row Y" into a single syncState upsert or tombstone insert.
///
/// Non-actor-isolated because GRDB calls observer hooks synchronously from
/// the DB's serial write queue. We bridge into the actor via a detached
/// `Task`; the commit has already happened so no DB mutation inside the
/// actor's callback can race with the completing transaction.
@available(macOS 14.0, iOS 17.0, *)
final class SyncTransactionObserver: TransactionObserver, @unchecked Sendable {

    private let library: SyncedLibrary

    init(library: SyncedLibrary) {
        self.library = library
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        switch eventKind.tableName {
        case SyncStateStore.SQL.stateTable, SyncStateStore.SQL.tombstoneTable:
            return true
        default:
            return false
        }
    }

    func databaseDidChange(with event: DatabaseEvent) {
        // Per-change bookkeeping isn't needed — we batch-query the tables
        // at commit. Still required by the protocol.
    }

    func databaseDidCommit(_ db: Database) {
        // Intentionally not awaited: the observer can't be async and
        // GRDB's write queue shouldn't block on CloudKit I/O. The actor
        // will serialize concurrent ingest calls naturally.
        Task { [library] in
            await library.ingestPendingChanges()
        }
    }

    func databaseDidRollback(_ db: Database) {
        // Nothing to propagate — rollbacks unwind syncState/tombstone
        // writes too, so the engine shouldn't see the pending changes.
    }
}
#endif
