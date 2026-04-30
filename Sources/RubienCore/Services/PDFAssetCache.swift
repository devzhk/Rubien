import Foundation
import GRDB

/// Per-device materialization state for PDF binaries.
///
/// Lives in the `pdfCache` DB table — a local-only table never observed by
/// sync triggers, never registered in `SyncEntityType`, never has a CKRecord.
/// This is the architectural defense against the local-only-column-clobber
/// bug class: assets that are device-local stay completely off the synced
/// schema. `Reference` has zero columns the CKRecord doesn't carry, so
/// remote pulls cannot wipe device-local state.
///
/// Materialization model:
/// - `materializedAt != NULL` → file exists at `storageRoot/localFilename`.
/// - `materializedAt == NULL` → metadata known (we've seen the asset record
///   on pull), but the file isn't on this device. Used for iOS on-demand
///   (deferred to iOS-port plan; on Mac under current scope this state is
///   only reached via dematerialize).
public actor PDFAssetCache {

    private let db: AppDatabase
    private let storageRoot: URL

    public init(db: AppDatabase, storageRoot: URL) {
        self.db = db
        self.storageRoot = storageRoot
    }

    public struct MaterializeResult: Sendable {
        public let localURL: URL
        public let localFilename: String
        public let contentHash: String
    }

    public struct CacheEntry: Sendable {
        public let referenceId: Int64
        public let localFilename: String
        public let contentHash: String
        public let assetVersion: Int64
        public let materializedAt: Date?
        public let lastOpenedAt: Date
    }

    /// Copy `sourceURL` into our PDFs/ dir (under a fresh UUID-prefixed name
    /// modeled after `PDFService.importPDF`), upsert the cache row, and
    /// return the local URL + the file's SHA-256.
    ///
    /// Caller is responsible for ensuring `referenceId` exists in `reference`.
    /// Each call generates a fresh UUID-prefixed filename, so calling twice
    /// for the same `referenceId` orphans the previous file on disk — call
    /// `dematerialize` first if you need to reclaim that space.
    public func materialize(
        referenceId: Int64,
        sourceURL: URL,
        originalFilename: String,
        assetVersion: Int64
    ) throws -> MaterializeResult {
        // Mirror PDFService.importPDF naming so the two paths are interchangeable.
        let localFilename = "\(UUID().uuidString)_\(originalFilename)"
        let dest = storageRoot.appendingPathComponent(localFilename)
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        let hash = try PDFContentHasher.sha256(of: dest)

        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(referenceId) DO UPDATE SET
                    localFilename = excluded.localFilename,
                    contentHash = excluded.contentHash,
                    assetVersion = excluded.assetVersion,
                    materializedAt = excluded.materializedAt,
                    lastOpenedAt = excluded.lastOpenedAt
            """, arguments: [referenceId, localFilename, hash, assetVersion, Date(), Date()])
        }

        return MaterializeResult(localURL: dest, localFilename: localFilename, contentHash: hash)
    }

    /// Resolve a Reference's local file URL if the asset is materialized on
    /// this device. Nil if the row is missing OR if `materializedAt` is NULL
    /// OR if the file vanished since materialization.
    public func pathFor(referenceId: Int64) throws -> URL? {
        let row = try db.dbWriter.read { db -> (filename: String, materialized: Bool)? in
            guard let r = try Row.fetchOne(db,
                sql: "SELECT localFilename, materializedAt FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            ) else { return nil }
            let filename: String = r["localFilename"]
            let mat: Date? = r["materializedAt"]
            return (filename, mat != nil)
        }
        guard let row, row.materialized else { return nil }
        let url = storageRoot.appendingPathComponent(row.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Return the cache row even if not materialized.
    public func metadataFor(referenceId: Int64) throws -> CacheEntry? {
        try db.dbWriter.read { db in
            guard let r = try Row.fetchOne(db,
                sql: "SELECT * FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            ) else { return nil }
            return CacheEntry(
                referenceId: r["referenceId"],
                localFilename: r["localFilename"],
                contentHash: r["contentHash"],
                assetVersion: r["assetVersion"],
                materializedAt: r["materializedAt"],
                lastOpenedAt: r["lastOpenedAt"]
            )
        }
    }

    /// Bump `lastOpenedAt`. Reader calls this on each open.
    public func markOpened(referenceId: Int64) throws {
        try db.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE pdfCache SET lastOpenedAt = ? WHERE referenceId = ?",
                arguments: [Date(), referenceId]
            )
        }
    }

    /// Delete the local file but keep the row so a future fetch can re-materialize.
    public func dematerialize(referenceId: Int64) throws {
        let filename: String? = try db.dbWriter.read { db in
            try String.fetchOne(db,
                sql: "SELECT localFilename FROM pdfCache WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }
        if let filename {
            let url = storageRoot.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        try db.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE pdfCache SET materializedAt = NULL WHERE referenceId = ?",
                arguments: [referenceId]
            )
        }
    }
}
