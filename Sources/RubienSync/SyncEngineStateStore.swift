import Foundation
import CloudKit
import os.log

private let log = Logger(subsystem: "Rubien", category: "SyncEngineStateStore")

/// Sidecar-file persistence for `CKSyncEngine.State.Serialization`.
///
/// Per the plan (B4): engine state lives next to `library.sqlite` as
/// `sync-engine-state.bin` rather than inside the DB so that (a) a
/// `rubien-cli sync reset` is a single `rm`, (b) library-schema migrations
/// don't have to bundle CloudKit state migrations, and (c) the engine can
/// persist state outside any DB transaction our triggers might observe.
///
/// Load returns nil when the file doesn't exist (fresh install / post-reset),
/// which is the signal `CKSyncEngine` expects for a from-scratch init.
public struct SyncEngineStateStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        do {
            // `CKSyncEngine.State.Serialization` is `Codable` — the WWDC
            // 2023 sample uses JSONDecoder. Apple stabilizes the shape
            // across OS versions; if a future version changes the contract
            // the decode fails and we fall through to a fresh engine.
            return try JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: data
            )
        } catch {
            // If the blob is corrupt (e.g. format changed on a beta OS),
            // fall back to a fresh engine rather than crashing. The engine
            // will re-pull from scratch — slow but correct.
            log.error("engine-state rehydrate failed: \(error.localizedDescription, privacy: .public); continuing fresh")
            return nil
        }
    }

    public func save(_ serialization: CKSyncEngine.State.Serialization) throws {
        let data = try JSONEncoder().encode(serialization)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Delete the sidecar file. Used by a future `rubien-cli sync reset`.
    public func reset() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
