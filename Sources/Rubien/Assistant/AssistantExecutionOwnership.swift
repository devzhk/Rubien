#if os(macOS)
import Foundation
import RubienCore

/// App-lifetime holder for the per-library Assistant execution lock. Every
/// window shares this one object; a second Rubien process remains transcript
/// read-only instead of running recovery or starting a provider.
@MainActor
final class AssistantExecutionOwnership: ObservableObject {
    static let shared = AssistantExecutionOwnership()

    @Published private(set) var isOwner = false
    @Published private(set) var unavailableReason: String?

    private var executionLock: AssistantLibraryExecutionLock?
    private var attemptedRoot: URL?
    private var preparedRoot: URL?
    private var maintenanceRoot: URL?
    private var activeWorkTokens: Set<UUID> = []
    private var preparationID: UUID?
    private var preparationRoot: URL?
    private var preparationTask: Task<String?, Never>?

    @discardableResult
    func acquireIfNeeded(
        libraryRoot: URL = AppDatabase.libraryRootURL,
        ownerDescription: String = "Rubien.app"
    ) -> Bool {
        let root = libraryRoot.standardizedFileURL
        if attemptedRoot == root, executionLock != nil { return isOwner }
        executionLock?.release()
        executionLock = nil
        preparedRoot = nil
        preparationTask?.cancel()
        preparationTask = nil
        preparationID = nil
        preparationRoot = nil
        attemptedRoot = root
        do {
            guard let lock = try AssistantLibraryExecutionLock.tryAcquire(
                libraryRoot: root,
                ownerDescription: ownerDescription
            ) else {
                isOwner = false
                unavailableReason = AssistantLibraryExecutionLock
                    .diagnosticOwner(libraryRoot: root)
                    .map { "Assistant execution is owned by another Rubien process (\($0))." }
                    ?? "Assistant execution is owned by another Rubien process."
                return false
            }
            executionLock = lock
            isOwner = true
            unavailableReason = nil
            return true
        } catch {
            isOwner = false
            unavailableReason = error.localizedDescription
            return false
        }
    }

    /// Acquires the per-library execution lock and performs all crash recovery
    /// before admitting either an interactive or scheduled provider turn. This
    /// synchronous MainActor boundary makes ownership, attachment reconciliation,
    /// and interrupted-work recovery one ordered startup operation: a newly
    /// inserted turn can never be mistaken for work left by a prior process.
    @discardableResult
    func prepareIfNeeded(
        database: AppDatabase,
        libraryRoot: URL = AppDatabase.libraryRootURL,
        ownerDescription: String = "Rubien.app",
        now: Date = Date()
    ) -> Bool {
        let root = libraryRoot.standardizedFileURL
        guard maintenanceRoot == nil else {
            unavailableReason = "Assistant conversation maintenance is in progress."
            return false
        }
        guard acquireIfNeeded(
            libraryRoot: root,
            ownerDescription: ownerDescription
        ) else { return false }
        if preparedRoot == root { return true }
        guard preparationTask == nil else {
            unavailableReason = "Assistant startup recovery is still in progress."
            return false
        }

        do {
            try DurableAssistantAttachmentStore.reconcile(
                database: database,
                libraryRoot: root
            )
            _ = try database.recoverInterruptedAssistantWork(at: now)
            preparedRoot = root
            unavailableReason = nil
            return true
        } catch {
            preparedRoot = nil
            unavailableReason = "Assistant startup recovery failed: \(error.localizedDescription)"
            return false
        }
    }

    /// MainActor owns admission state, but the potentially large filesystem sweep
    /// and SQLite recovery run detached. Concurrent launch/send/settings callers
    /// join the same preparation task and only the matching root/generation may
    /// publish its result.
    func prepareIfNeededAsync(
        database: AppDatabase,
        libraryRoot: URL = AppDatabase.libraryRootURL,
        ownerDescription: String = "Rubien.app",
        now: Date = Date()
    ) async -> Bool {
        let root = libraryRoot.standardizedFileURL
        guard maintenanceRoot == nil else {
            unavailableReason = "Assistant conversation maintenance is in progress."
            return false
        }
        guard acquireIfNeeded(
            libraryRoot: root,
            ownerDescription: ownerDescription
        ) else { return false }
        if preparedRoot == root { return true }

        let id: UUID
        let task: Task<String?, Never>
        if let currentID = preparationID,
           preparationRoot == root,
           let currentTask = preparationTask {
            id = currentID
            task = currentTask
        } else {
            id = UUID()
            preparationID = id
            preparationRoot = root
            task = Task.detached(priority: .userInitiated) {
                do {
                    try DurableAssistantAttachmentStore.reconcile(
                        database: database,
                        libraryRoot: root
                    )
                    _ = try database.recoverInterruptedAssistantWork(at: now)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            preparationTask = task
            unavailableReason = "Assistant startup recovery is in progress."
        }

        let failure = await task.value
        guard preparationID == id,
              preparationRoot == root,
              attemptedRoot == root,
              executionLock != nil else {
            return false
        }
        preparationTask = nil
        preparationID = nil
        preparationRoot = nil
        if let failure {
            preparedRoot = nil
            unavailableReason = "Assistant startup recovery failed: \(failure)"
            return false
        }
        preparedRoot = root
        unavailableReason = nil
        return true
    }

    /// Registers one in-process Assistant execution before it can stage files or
    /// create durable turn state. Maintenance checks this registry synchronously
    /// on MainActor, so a clear/reconcile sweep cannot begin in the gap between
    /// attachment staging and the first database row.
    func beginAssistantWork(
        libraryRoot: URL = AppDatabase.libraryRootURL
    ) -> UUID? {
        let root = libraryRoot.standardizedFileURL
        guard maintenanceRoot == nil,
              preparedRoot == root,
              executionLock != nil,
              isOwner
        else {
            unavailableReason = maintenanceRoot == nil
                ? "Assistant startup recovery has not completed."
                : "Assistant conversation maintenance is in progress."
            return nil
        }
        let token = UUID()
        activeWorkTokens.insert(token)
        unavailableReason = nil
        return token
    }

    func finishAssistantWork(_ token: UUID) {
        activeWorkTokens.remove(token)
    }

    /// Reserves the execution owner for a potentially large maintenance operation
    /// whose SQLite/filesystem work will run off-main. New turn preparation fails
    /// closed until `finishMaintenance` publishes the result.
    @discardableResult
    func beginMaintenance(
        database: AppDatabase,
        libraryRoot: URL = AppDatabase.libraryRootURL,
        ownerDescription: String = "Rubien.app"
    ) -> Bool {
        let root = libraryRoot.standardizedFileURL
        guard maintenanceRoot == nil else {
            unavailableReason = "Assistant conversation maintenance is already in progress."
            return false
        }
        guard activeWorkTokens.isEmpty else {
            unavailableReason = "Assistant work is currently running. Try again when it finishes."
            return false
        }
        guard prepareIfNeeded(
            database: database,
            libraryRoot: root,
            ownerDescription: ownerDescription
        ) else { return false }
        // `prepareIfNeeded` is synchronous on MainActor, so no turn can register
        // between the checks above and this reservation.
        guard activeWorkTokens.isEmpty else {
            unavailableReason = "Assistant work is currently running. Try again when it finishes."
            return false
        }
        do {
            guard try !database.hasActiveAssistantWork() else {
                unavailableReason = "Assistant work is currently running. Try again when it finishes."
                return false
            }
        } catch {
            unavailableReason = "Could not verify Assistant activity: \(error.localizedDescription)"
            return false
        }
        maintenanceRoot = root
        unavailableReason = "Assistant conversation maintenance is in progress."
        return true
    }

    func finishMaintenance(
        libraryRoot: URL = AppDatabase.libraryRootURL,
        prepared: Bool,
        failureMessage: String? = nil
    ) {
        let root = libraryRoot.standardizedFileURL
        guard maintenanceRoot == root else { return }
        maintenanceRoot = nil
        if prepared {
            preparedRoot = root
            unavailableReason = nil
        } else {
            preparedRoot = nil
            unavailableReason = failureMessage
                ?? "Assistant conversation maintenance failed."
        }
    }

    func release() {
        executionLock?.release()
        preparationTask?.cancel()
        executionLock = nil
        attemptedRoot = nil
        preparedRoot = nil
        maintenanceRoot = nil
        activeWorkTokens.removeAll()
        preparationTask = nil
        preparationID = nil
        preparationRoot = nil
        isOwner = false
        unavailableReason = nil
    }
}
#endif
