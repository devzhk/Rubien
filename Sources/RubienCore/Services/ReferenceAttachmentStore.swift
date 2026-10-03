import Foundation
import GRDB
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns supplementary files. Call file operations off the main thread.
/// The caller supplies the root paired with this database, never a filesystem search result.
public struct ReferenceAttachmentStore: Sendable {
    public let database: AppDatabase
    public let libraryRoot: URL
    private let validatePDF: ReferenceAttachmentPDFValidation

    public init(database: AppDatabase, libraryRoot: URL, validatePDF: @escaping ReferenceAttachmentPDFValidation) {
        self.database = database
        self.libraryRoot = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.validatePDF = validatePDF
    }

    public func list(referenceId: Int64) throws -> [ReferenceAttachment] {
        try database.dbWriter.read { db in
            try ReferenceAttachment.fetchAll(db, sql: """
                SELECT * FROM referenceAttachment WHERE referenceId=? AND deletedAt IS NULL
                ORDER BY dateCreated, syncId
                """, arguments: [referenceId])
        }
    }

    public func attachment(syncId: String) throws -> ReferenceAttachment {
        try database.dbWriter.read { db in try Self.requireAttachment(syncId, db: db) }
    }

    public func importFile(at source: URL, referenceId: Int64) throws -> ReferenceAttachmentImportResult {
        try withFileLock(wait: true) {
            try recoverImportsLocked()
            let kind: ReferenceAttachmentKind
            switch source.pathExtension.lowercased() {
            case "pdf": kind = .pdf
            case "md": kind = .markdown
            default: throw ReferenceAttachmentError.unsupportedFile
            }
            #if canImport(Darwin)
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            #endif
            let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true else {
                throw ReferenceAttachmentError.unsupportedFile
            }
            if let size = attributes.fileSize, Int64(size) > kind.maximumBytes {
                throw ReferenceAttachmentError.tooLarge(kind.maximumBytes)
            }
            let operationID = UUID().uuidString.lowercased()
            let attachmentID = SyncIdentifier.random()
            let stagedPath = "Attachments/.staging/\(operationID)/content.\(kind.fileExtension)"
            let finalPath = "Attachments/\(attachmentID)/content.\(kind.fileExtension)"
            let staged = try managedURL(stagedPath)
            let final = try managedURL(finalPath)
            try database.dbWriter.write { db in
                guard try Reference.fetchOne(db, key: referenceId) != nil else {
                    throw ReferenceAttachmentError.missingReference
                }
                try db.execute(sql: """
                    INSERT INTO attachmentFileJournal
                    (operationId, attachmentSyncId, stagedPath, finalPath, purpose, createdAt)
                    VALUES(?, ?, ?, ?, 'import', ?)
                    """, arguments: [operationID, attachmentID, stagedPath, finalPath, Date()])
            }
            do {
                try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                let digest = try Self.copyAndHash(source, to: staged, limit: kind.maximumBytes)
                switch kind {
                case .markdown:
                    guard String(data: try Data(contentsOf: staged), encoding: .utf8) != nil else {
                        throw ReferenceAttachmentError.invalidMarkdown
                    }
                case .pdf: try validatePDF(staged)
                }
                let result = try database.dbWriter.write { db -> ReferenceAttachmentImportResult in
                    guard let parent = try Reference.fetchOne(db, key: referenceId) else {
                        throw ReferenceAttachmentError.missingReference
                    }
                    if let duplicate = try ReferenceAttachment.fetchOne(db, sql: """
                        SELECT * FROM referenceAttachment
                        WHERE referenceId=? AND kind=? AND contentHash=? AND deletedAt IS NULL
                        ORDER BY dateCreated, syncId LIMIT 1
                        """, arguments: [referenceId, kind.rawValue, digest.hash]) {
                        return ReferenceAttachmentImportResult(attachment: duplicate, wasDuplicate: true)
                    }
                    try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Only the atomic rename occurs under the writer; copying, validation,
                    // and hashing have finished. The journal survives a rollback or crash.
                    try FileManager.default.moveItem(at: staged, to: final)
                    let now = Date()
                    let item = ReferenceAttachment(
                        id: nil, syncId: attachmentID, referenceId: referenceId,
                        referenceSyncId: parent.syncId, kind: kind.rawValue,
                        originalFilename: source.lastPathComponent, displayName: source.lastPathComponent,
                        byteCount: digest.count, contentHash: digest.hash,
                        dateCreated: now, dateModified: now, deletedAt: nil)
                    try item.insert(db)
                    try db.execute(sql: """
                        INSERT INTO attachmentCache(attachmentSyncId, relativePath, contentHash, materializedAt)
                        VALUES(?, ?, ?, ?);
                        INSERT INTO attachmentUploadQueue(attachmentSyncId, contentHash, queuedAt) VALUES(?, ?, ?);
                        INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                        VALUES('attachmentAsset', ?, 1, 0)
                        ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty=1, pushInFlight=0;
                        """, arguments: [attachmentID, finalPath, digest.hash, now,
                                          attachmentID, digest.hash, now, attachmentID])
                    return ReferenceAttachmentImportResult(
                        attachment: try Self.requireAttachment(attachmentID, db: db), wasDuplicate: false)
                }
                // The import is committed. Cleanup failure must not report it as a
                // failed import; the journal retains cleanup ownership for retry.
                try? recoverImportsLocked()
                if !result.wasDuplicate, let signature = try? AttachmentFileSignature(final) {
                    AttachmentVerificationCache.shared.remember(final.path + ":" + digest.hash, signature: signature)
                }
                return result
            } catch {
                // Cleanup failures leave durable journal ownership for the next recovery.
                try? recoverImportsLocked()
                throw error
            }
        }
    }

    public func rename(syncId: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.contains("\0") else {
            throw ReferenceAttachmentError.invalidName
        }
        try database.dbWriter.write { db in
            let item = try Self.requireAttachment(syncId, db: db)
            guard item.deletedAt == nil else { throw ReferenceAttachmentError.removed }
            try db.execute(sql: "UPDATE referenceAttachment SET displayName=?, dateModified=? WHERE syncId=?",
                           arguments: [trimmed, Date(), syncId])
        }
    }

    /// Retain bytes until the sync layer has acknowledged removal and readers release them.
    public func remove(syncId: String) throws {
        try database.dbWriter.write { db in
            let item = try Self.requireAttachment(syncId, db: db)
            guard item.deletedAt == nil else { return }
            try db.execute(sql: "UPDATE referenceAttachment SET deletedAt=?, dateModified=? WHERE syncId=?",
                           arguments: [Date(), Date(), syncId])
            try db.execute(sql: "DELETE FROM attachmentUploadQueue WHERE attachmentSyncId=?", arguments: [syncId])
            try db.execute(sql: "DELETE FROM syncState WHERE entityType='attachmentAsset' AND entityId=?", arguments: [syncId])
        }
    }

    public func verifiedFileURL(syncId: String) throws -> URL {
        try withPublishedFiles { try verifiedFileURLLocked(syncId: syncId) }
    }

    /// Never overwrites an existing destination or edits the managed source.
    public func export(syncId: String, to destination: URL, replaceExisting: Bool = false) throws {
        try withPublishedFiles {
            let source = try verifiedFileURLLocked(syncId: syncId)
            // Finder/export must never overwrite any file owned by this library.
            let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
            if resolved.path.hasPrefix(libraryRoot.path + "/") {
                let relative = String(resolved.path.dropFirst(libraryRoot.path.count + 1))
                let first = relative.split(separator: "/").first.map(String.init) ?? ""
                if ["Attachments", "PDFs", "MetadataArtifacts"].contains(first)
                    || first.hasPrefix("library.sqlite") || first == "sync-engine-state.bin"
                    || first == ".library-root.lock" || first == LibraryRootLease.markerName {
                    throw ReferenceAttachmentError.invalidPath
                }
            }
            let fm = FileManager.default
            if replaceExisting, fm.fileExists(atPath: destination.path) {
                let staged = destination.deletingLastPathComponent().appendingPathComponent(".rubien-export-\(UUID())")
                defer { try? fm.removeItem(at: staged) }
                try fm.copyItem(at: source, to: staged)
                // Same-directory POSIX rename is atomic on both platforms. Foundation's
                // replaceItemAt can remove the destination and fail on Linux.
                #if canImport(Darwin)
                let result = Darwin.rename(staged.path, destination.path)
                #else
                let result = Glibc.rename(staged.path, destination.path)
                #endif
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            } else {
                try fm.copyItem(at: source, to: destination)
            }
        }
    }

    public func recoverInterruptedImports() throws {
        try withFileLock { try recoverImportsLocked() }
    }

    /// A cheap availability check for lists; reading/export still verify contents.
    func locallyAvailableFileURL(syncId: String) throws -> URL {
        try withPublishedFiles { try verifiedFileURLLocked(syncId: syncId, verifyContents: false) }
    }

    private func verifiedFileURLLocked(syncId: String, verifyContents: Bool = true) throws -> URL {
        let (item, path) = try database.dbWriter.read { db -> (ReferenceAttachment, String) in
            let item = try Self.requireAttachment(syncId, db: db)
            guard item.deletedAt == nil else { throw ReferenceAttachmentError.removed }
            guard let path = try String.fetchOne(db, sql: "SELECT relativePath FROM attachmentCache WHERE attachmentSyncId=?",
                                                arguments: [syncId]) else { throw ReferenceAttachmentError.unavailable }
            return (item, path)
        }
        let url = try managedURL(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReferenceAttachmentError.unavailable }
        let signature = try AttachmentFileSignature(url)
        guard signature.size == item.byteCount else { throw ReferenceAttachmentError.integrityMismatch }
        if !verifyContents { return url }
        let key = url.path + ":" + item.contentHash
        if AttachmentVerificationCache.shared.contains(key, signature: signature, byteCount: item.byteCount) { return url }
        let digest: (hash: String, count: Int64)
        do { digest = try Self.hash(url, limit: item.byteCount) }
        catch ReferenceAttachmentError.tooLarge { throw ReferenceAttachmentError.integrityMismatch }
        guard digest.hash == item.contentHash, digest.count == item.byteCount else {
            throw ReferenceAttachmentError.integrityMismatch
        }
        guard try AttachmentFileSignature(url) == signature else { throw ReferenceAttachmentError.integrityMismatch }
        AttachmentVerificationCache.shared.remember(key, signature: signature)
        return url
    }

    private static func requireAttachment(_ syncId: String, db: Database) throws -> ReferenceAttachment {
        guard let item = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?",
                                                         arguments: [syncId]) else {
            throw ReferenceAttachmentError.missingAttachment
        }
        return item
    }

    private func recoverImportsLocked() throws {
        do { try withPublishedFiles(exclusive: true, wait: false) { try recoverUnownedFilesLocked() } }
        catch ReferenceAttachmentError.busy { /* Readers retain old paths; retry recovery after they close. */ }
    }

    private func recoverUnownedFilesLocked() throws {
        let journals = try database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM attachmentFileJournal WHERE purpose='import'")
        }
        for row in journals {
            let staged: String = row["stagedPath"]
            let final: String = row["finalPath"]
            for path in [staged, final] {
                let owned = try database.dbWriter.read { db in
                    try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachmentCache WHERE relativePath=?)",
                                      arguments: [path]) ?? false
                }
                if !owned {
                    let url = try managedURL(path)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    let directory = url.deletingLastPathComponent()
                    if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                        try FileManager.default.removeItem(at: directory)
                    }
                }
            }
            try database.dbWriter.write { db in
                try db.execute(sql: "DELETE FROM attachmentFileJournal WHERE operationId=?", arguments: [row["operationId"] as String])
            }
        }
    }

    func managedURL(_ path: String) throws -> URL {
        guard path.hasPrefix("Attachments/"), !path.split(separator: "/").contains("..") else {
            throw ReferenceAttachmentError.invalidPath
        }
        // URL's resolver can leave a nonexistent final component unresolved. Check
        // every existing ancestor so a symlink cannot escape during a later write.
        var ancestor = libraryRoot
        for component in path.split(separator: "/") {
            ancestor.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                throw ReferenceAttachmentError.invalidPath
            }
        }
        let root = libraryRoot.appendingPathComponent("Attachments").path + "/"
        let url = libraryRoot.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root) else { throw ReferenceAttachmentError.invalidPath }
        return url
    }

    func withFileLock<T>(wait: Bool = false, _ body: () throws -> T) throws -> T {
        let lease = try LibraryRootLease(root: libraryRoot)
        return try withExtendedLifetime(lease) {
            try withLock(name: ".ownership.lock", exclusive: true, wait: wait, body)
        }
    }

    // Imports only publish new immutable paths. Readers of committed paths need
    // exclusion from recovery, not from the long copy/validation operation.
    func withPublishedFiles<T>(exclusive: Bool = false, wait: Bool = true, _ body: () throws -> T) throws -> T {
        let lease = try LibraryRootLease(root: libraryRoot)
        return try withExtendedLifetime(lease) {
            try withLock(name: ".published.lock", exclusive: exclusive, wait: wait, body)
        }
    }

    private func withLock<T>(name: String, exclusive: Bool, wait: Bool, _ body: () throws -> T) throws -> T {
        let root = libraryRoot.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = try managedURL("Attachments/" + name)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try Task<Never, Never>.checkCancellation()
            guard wait, ProcessInfo.processInfo.systemUptime < deadline else { throw ReferenceAttachmentError.busy }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task<Never, Never>.checkCancellation()
        return try body()
    }

    static func hash(_ source: URL, limit: Int64) throws -> (hash: String, count: Int64) {
        try stream(source, output: nil, limit: limit)
    }

    static func copyAndHash(_ source: URL, to destination: URL, limit: Int64) throws -> (hash: String, count: Int64) {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let result = try stream(source, output: output, limit: limit)
        try output.synchronize()
        return result
    }

    private static func stream(_ source: URL, output: FileHandle?, limit: Int64) throws -> (hash: String, count: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task<Never, Never>.checkCancellation()
            count += Int64(bytes.count)
            guard count <= limit else { throw ReferenceAttachmentError.tooLarge(limit) }
            hash.update(data: bytes)
            try output?.write(contentsOf: bytes)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
