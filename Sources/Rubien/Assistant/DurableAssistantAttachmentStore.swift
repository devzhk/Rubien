#if os(macOS)
import Foundation
import RubienCore

struct PreparedAssistantAttachments: Sendable {
    let rows: [StoredAssistantAttachment]
    fileprivate let finalURLs: [URL]
}

struct StoredAssistantAttachmentPresentationAssets: Sendable {
    var availableIDs: Set<String> = []
    var thumbnailDataURLs: [String: String] = [:]

    mutating func formUnion(
        _ other: StoredAssistantAttachmentPresentationAssets
    ) {
        availableIDs.formUnion(other.availableIDs)
        thumbnailDataURLs.merge(other.thumbnailDataURLs) { current, _ in current }
    }
}

/// Library-owned durable copies of user attachments. The existing workspace
/// store remains provider staging; this actor adopts those bytes into transcript
/// ownership and reconciles crash leftovers independently.
actor DurableAssistantAttachmentStore {
    private static let thumbnailCacheLimit = 64

    private let database: AppDatabase
    private let libraryRootURL: URL
    private let rootURL: URL
    private let pendingURL: URL
    private let fileManager: FileManager
    private var thumbnailCache: [String: String] = [:]
    private var thumbnailMisses: Set<String> = []
    private var thumbnailCacheOrder: [String] = []

    init(
        database: AppDatabase,
        libraryRoot: URL = AppDatabase.libraryRootURL,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.fileManager = fileManager
        libraryRootURL = libraryRoot
        rootURL = libraryRoot.appendingPathComponent(
            AssistantAttachmentFiles.directoryName,
            isDirectory: true
        )
        pendingURL = rootURL.appendingPathComponent(".pending", isDirectory: true)
    }

    func prepare(
        _ attachments: [ChatAttachment],
        conversationID: UUID,
        entryID: UUID,
        now: Date = Date()
    ) throws -> PreparedAssistantAttachments {
        guard !attachments.isEmpty else {
            return PreparedAssistantAttachments(rows: [], finalURLs: [])
        }
        let resolvedLibraryRoot = libraryRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try Self.createSafeDirectory(
            rootURL,
            in: resolvedLibraryRoot,
            fileManager: fileManager
        )
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        try Self.createSafeDirectory(
            pendingURL,
            in: resolvedRoot,
            fileManager: fileManager
        )
        let conversationDirectory = rootURL.appendingPathComponent(
            conversationID.uuidString.lowercased(),
            isDirectory: true
        )
        try Self.createSafeDirectory(
            conversationDirectory,
            in: resolvedRoot,
            fileManager: fileManager
        )

        var rows: [StoredAssistantAttachment] = []
        var finalURLs: [URL] = []
        var temporaryURLs: [URL] = []
        do {
            for attachment in attachments {
                let attachmentID = attachment.id.uuidString.lowercased()
                let filename = AssistantAttachmentFiles.sanitizedFilename(
                    attachment.displayName
                )
                let relativePath = "\(attachmentID)/\(filename)"
                let attachmentDirectory = conversationDirectory.appendingPathComponent(
                    attachmentID,
                    isDirectory: true
                )
                try Self.createSafeDirectory(
                    attachmentDirectory,
                    in: resolvedRoot,
                    fileManager: fileManager
                )
                let finalURL = attachmentDirectory.appendingPathComponent(filename)
                try Self.requireSafeDestination(
                    finalURL,
                    in: resolvedRoot,
                    fileManager: fileManager
                )
                let temporaryURL = pendingURL.appendingPathComponent(
                    "\(UUID().uuidString.lowercased()).pending"
                )
                try Self.requireSafeDestination(
                    temporaryURL,
                    in: resolvedRoot,
                    fileManager: fileManager
                )
                temporaryURLs.append(temporaryURL)
                try fileManager.copyItem(at: attachment.stagedURL, to: temporaryURL)
                let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard byteCount == attachment.byteCount, byteCount >= 0 else {
                    throw DurableAssistantAttachmentError.sizeChanged(attachment.displayName)
                }
                let sha256 = try PDFContentHasher.sha256(of: temporaryURL)
                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.removeItem(at: finalURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: finalURL)
                temporaryURLs.removeAll { $0 == temporaryURL }
                finalURLs.append(finalURL)
                rows.append(StoredAssistantAttachment(
                    id: attachmentID,
                    entryId: entryID.uuidString.lowercased(),
                    displayName: attachment.displayName,
                    kind: attachment.kind == .image ? .image : .text,
                    relativePath: relativePath,
                    mediaType: attachment.mediaType,
                    byteCount: byteCount,
                    sha256: sha256,
                    createdAt: now
                ))
            }
            return PreparedAssistantAttachments(rows: rows, finalURLs: finalURLs)
        } catch {
            for url in temporaryURLs + finalURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    func rollback(_ prepared: PreparedAssistantAttachments) {
        for url in prepared.finalURLs {
            try? fileManager.removeItem(at: url)
        }
    }

    func removeConversation(_ conversationID: String) {
        AssistantAttachmentFiles.removeConversation(
            id: conversationID,
            libraryRoot: rootURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
    }

    /// Removes pending copies and final files with no matching database row.
    /// Missing files keep their DB metadata and render unavailable.
    func reconcile() throws {
        try Self.reconcile(
            database: database,
            libraryRoot: rootURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
    }

    /// Synchronous launch seam used after execution-lock acquisition and before
    /// any recorder can stage new bytes. This ordering prevents an orphan sweep
    /// from racing a not-yet-committed attachment prepare transaction.
    nonisolated static func reconcile(
        database: AppDatabase,
        libraryRoot: URL = AppDatabase.libraryRootURL,
        fileManager: FileManager = .default
    ) throws {
        let stored = try database.fetchStoredAssistantAttachmentPaths()
        AssistantAttachmentFiles.reconcile(
            libraryRoot: libraryRoot,
            storedPaths: stored,
            fileManager: fileManager
        )
    }

    func resolvedURL(
        conversationID: String,
        attachment: StoredAssistantAttachment
    ) -> URL? {
        guard let relativePath = attachment.relativePath,
              AssistantAttachmentFiles.isValidRelativePath(
                relativePath,
                attachmentID: attachment.id
              )
        else { return nil }
        let resolvedLibraryRoot = libraryRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !AssistantAttachmentFiles.isSymbolicLink(
            rootURL,
            fileManager: fileManager
        ) else { return nil }
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard AssistantAttachmentFiles.isContained(
            resolvedRoot,
            in: resolvedLibraryRoot,
            allowRoot: false
        ) else { return nil }
        let conversationURL = rootURL
            .appendingPathComponent(conversationID, isDirectory: true)
            .standardizedFileURL
        guard !AssistantAttachmentFiles.isSymbolicLink(
            conversationURL,
            fileManager: fileManager
        ) else { return nil }
        let conversationRoot = conversationURL.resolvingSymlinksInPath()
        guard AssistantAttachmentFiles.isContained(
            conversationRoot,
            in: resolvedRoot,
            allowRoot: false
        ) else { return nil }
        let attachmentDirectory = conversationURL.appendingPathComponent(
            attachment.id.lowercased(),
            isDirectory: true
        )
        guard !AssistantAttachmentFiles.isSymbolicLink(
            attachmentDirectory,
            fileManager: fileManager
        ) else { return nil }
        let candidateURL = conversationURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard !AssistantAttachmentFiles.isSymbolicLink(
            candidateURL,
            fileManager: fileManager
        ) else { return nil }
        let candidate = candidateURL.resolvingSymlinksInPath()
        guard AssistantAttachmentFiles.isContained(
                  candidate,
                  in: conversationRoot,
                  allowRoot: false
              ),
              fileManager.isReadableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    func availableAttachmentIDs(
        conversationID: String,
        attachments: [StoredAssistantAttachment]
    ) -> Set<String> {
        Set(attachments.compactMap { attachment in
            resolvedURL(
                conversationID: conversationID,
                attachment: attachment
            ) == nil ? nil : attachment.id
        })
    }

    func presentationAssets(
        conversationID: String,
        attachments: [StoredAssistantAttachment]
    ) -> StoredAssistantAttachmentPresentationAssets {
        var result = StoredAssistantAttachmentPresentationAssets()
        for attachment in attachments {
            guard let url = resolvedURL(
                conversationID: conversationID,
                attachment: attachment
            ) else { continue }
            result.availableIDs.insert(attachment.id)
            if attachment.kind == .image {
                let cacheKey = [
                    attachment.id,
                    attachment.sha256 ?? "",
                    String(attachment.byteCount),
                ].joined(separator: ":")
                if let thumbnail = thumbnailCache[cacheKey] {
                    result.thumbnailDataURLs[attachment.id] = thumbnail
                } else if !thumbnailMisses.contains(cacheKey) {
                    if let thumbnail = AssistantImageNormalizer
                        .transcriptThumbnailDataURL(fileURL: url) {
                        thumbnailCache[cacheKey] = thumbnail
                        result.thumbnailDataURLs[attachment.id] = thumbnail
                    } else {
                        thumbnailMisses.insert(cacheKey)
                    }
                    thumbnailCacheOrder.append(cacheKey)
                    evictThumbnailCacheIfNeeded()
                }
            }
        }
        return result
    }

    private func evictThumbnailCacheIfNeeded() {
        while thumbnailCacheOrder.count > Self.thumbnailCacheLimit {
            let key = thumbnailCacheOrder.removeFirst()
            thumbnailCache.removeValue(forKey: key)
            thumbnailMisses.remove(key)
        }
    }

    private static func requireSafeDestination(
        _ candidate: URL,
        in resolvedRoot: URL,
        fileManager: FileManager
    ) throws {
        guard !AssistantAttachmentFiles.isSymbolicLink(
            candidate,
            fileManager: fileManager
        ) else {
            throw DurableAssistantAttachmentError.unsafeDestination
        }
        let resolvedCandidate = candidate
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard AssistantAttachmentFiles.isContained(
            resolvedCandidate,
            in: resolvedRoot,
            allowRoot: false
        ) else {
            throw DurableAssistantAttachmentError.unsafeDestination
        }
    }

    /// Validate both sides of directory creation. The first check prevents
    /// traversal through an existing symlink; the second catches replacement
    /// between validation and creation.
    private static func createSafeDirectory(
        _ candidate: URL,
        in resolvedRoot: URL,
        fileManager: FileManager
    ) throws {
        try requireSafeDestination(
            candidate,
            in: resolvedRoot,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: candidate,
            withIntermediateDirectories: true
        )
        try requireSafeDestination(
            candidate,
            in: resolvedRoot,
            fileManager: fileManager
        )
    }
}

enum DurableAssistantAttachmentError: Error, LocalizedError {
    case sizeChanged(String)
    case unsafeDestination

    var errorDescription: String? {
        switch self {
        case let .sizeChanged(name):
            "The attachment \(name) changed while it was being saved."
        case .unsafeDestination:
            "Rubien refused an attachment destination outside its transcript storage."
        }
    }
}
#endif
