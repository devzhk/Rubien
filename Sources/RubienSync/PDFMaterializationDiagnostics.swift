#if canImport(CloudKit)
import Foundation
import GRDB

public struct PDFMaterializationDiagnostics: Codable, Equatable, Sendable {
    public struct Issue: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable {
            case missingCache
            case missingFile
        }

        public let syncId: String
        public let localFilename: String?
        public let reason: Reason
    }

    public let checkedDirtyPDFCount: Int
    public let missingCacheCount: Int
    public let missingFileCount: Int
    public let issues: [Issue]

    /// Snapshot the database first, then release its read transaction before
    /// touching the filesystem. Callers must pass the active AppDatabase PDF
    /// root; rediscovering it here could inspect a different coexisting
    /// sandboxed, unsandboxed, legacy, or backup library.
    public static func read(
        from dbReader: any DatabaseReader,
        pdfStorageURL: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        struct Snapshot {
            let syncId: String
            let localFilename: String?
        }

        let snapshots: [Snapshot] = try dbReader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.entityId, pc.localFilename
                FROM syncState s
                LEFT JOIN reference r ON r.syncId = s.entityId
                LEFT JOIN pdfCache pc ON pc.referenceId = r.id
                WHERE s.entityType='referencePDF' AND s.isDirty=1
                ORDER BY s.entityId
                """).map { row in
                    Snapshot(
                        syncId: row["entityId"],
                        localFilename: row["localFilename"]
                    )
                }
        }

        var issues: [Issue] = []
        for snapshot in snapshots {
            guard let filename = snapshot.localFilename else {
                issues.append(Issue(
                    syncId: snapshot.syncId,
                    localFilename: nil,
                    reason: .missingCache
                ))
                continue
            }
            let url = pdfStorageURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path) else {
                issues.append(Issue(
                    syncId: snapshot.syncId,
                    localFilename: filename,
                    reason: .missingFile
                ))
                continue
            }
        }

        return Self(
            checkedDirtyPDFCount: snapshots.count,
            missingCacheCount: issues.filter { $0.reason == .missingCache }.count,
            missingFileCount: issues.filter { $0.reason == .missingFile }.count,
            issues: issues
        )
    }
}
#endif
