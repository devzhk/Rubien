import Foundation
import UniformTypeIdentifiers

enum AssistantAttachmentStoreError: LocalizedError, Equatable {
    case unsupported(String)
    case notRegularFile(String)
    case unreadable(String)
    case nonUTF8(String)
    case tooLarge(String)
    case imageDecode(String)
    case imageEncode(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "\(name) is not a supported attachment. Choose an image, Markdown, or text file."
        case .notRegularFile(let name):
            return "\(name) must be a regular file, not a folder, package, alias, or symbolic link."
        case .unreadable(let name):
            return "\(name) could not be read."
        case .nonUTF8(let name):
            return "\(name) is not valid UTF-8 text."
        case .tooLarge(let name):
            return "\(name) is larger than the 5 MB text attachment limit."
        case .imageDecode(let name):
            return "\(name) could not be decoded as an image."
        case .imageEncode(let name):
            return "\(name) could not be encoded within the image attachment limits."
        }
    }
}

actor AssistantAttachmentStore {
    static let relativeRoot = ".rubien/attachments"
    static let maxTextBytes: Int64 = 5 * 1_024 * 1_024

    nonisolated let managedRoot: URL

    private let fileManager: FileManager

    init(workspaceURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        managedRoot = workspaceURL
            .appendingPathComponent(Self.relativeRoot, isDirectory: true)
            .standardizedFileURL
    }

    func stageFile(
        _ sourceURL: URL,
        id: UUID = UUID(),
        conversationID: UUID
    ) throws -> ChatAttachment {
        let name = sourceURL.lastPathComponent
        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
                .fileSizeKey,
            ])
        } catch {
            throw AssistantAttachmentStoreError.unreadable(name)
        }

        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.isAliasFile != true
        else {
            throw AssistantAttachmentStoreError.notRegularFile(name)
        }

        let pathExtension = sourceURL.pathExtension.lowercased()
        guard ["md", "markdown", "txt"].contains(pathExtension) else {
            if
                let type = UTType(filenameExtension: pathExtension),
                type.conforms(to: .image)
            {
                return try stageImageFile(
                    sourceURL,
                    id: id,
                    conversationID: conversationID
                )
            }
            throw AssistantAttachmentStoreError.unsupported(name)
        }

        guard Int64(values.fileSize ?? 0) <= Self.maxTextBytes else {
            throw AssistantAttachmentStoreError.tooLarge(name)
        }

        let data = try read(sourceURL)
        guard Int64(data.count) <= Self.maxTextBytes else {
            throw AssistantAttachmentStoreError.tooLarge(name)
        }

        let body = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        guard String(data: body, encoding: .utf8) != nil else {
            throw AssistantAttachmentStoreError.nonUTF8(name)
        }

        return try write(
            data: data,
            displayName: name,
            kind: .text,
            mediaType: pathExtension == "txt" ? "text/plain" : "text/markdown",
            sourceIdentity: sourceURL.standardizedFileURL.path,
            pathExtension: pathExtension,
            conversationID: conversationID,
            id: id
        )
    }

    func stageImageData(
        _ data: Data,
        suggestedName: String,
        id: UUID = UUID(),
        conversationID: UUID
    ) throws -> ChatAttachment {
        _ = data
        _ = id
        _ = conversationID
        throw AssistantAttachmentStoreError.imageDecode(suggestedName)
    }

    func removePending(_ attachments: [ChatAttachment]) {
        for attachment in attachments {
            try? fileManager.removeItem(at: attachment.stagedURL)
        }
    }

    func rehomePending(
        _ attachments: [ChatAttachment],
        to conversationID: UUID
    ) throws -> [ChatAttachment] {
        guard !attachments.isEmpty else { return [] }

        let destinationDirectory = conversationDirectory(for: conversationID)
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        var prepared: [(original: URL, temporary: URL, destination: URL)] = []
        prepared.reserveCapacity(attachments.count)

        do {
            for attachment in attachments {
                let destination = destinationDirectory
                    .appendingPathComponent(attachment.stagedURL.lastPathComponent)
                let temporary = destinationDirectory
                    .appendingPathComponent(".rehome-\(UUID().uuidString)")
                // Prepare complete copies under transaction-private names while every
                // caller-visible original remains untouched.
                prepared.append((attachment.stagedURL, temporary, destination))
                try fileManager.copyItem(at: attachment.stagedURL, to: temporary)
            }
        } catch {
            // Originals were never moved. Cleanup failures can leave only private
            // temporary copies; every URL held by the caller remains usable.
            for item in prepared.reversed() {
                try? fileManager.removeItem(at: item.temporary)
            }
            throw error
        }

        var committed: [(original: URL, destination: URL)] = []
        committed.reserveCapacity(prepared.count)
        do {
            for item in prepared {
                // These renames stay within one conversation directory and are atomic on
                // the underlying volume.
                try fileManager.moveItem(at: item.temporary, to: item.destination)
                committed.append((item.original, item.destination))
            }
        } catch {
            // Even if cleanup itself is interrupted, originals are still authoritative and
            // readable. At worst, transaction-private or destination duplicates remain.
            for item in prepared {
                try? fileManager.removeItem(at: item.temporary)
            }
            for item in committed.reversed() {
                try? fileManager.removeItem(at: item.destination)
            }
            throw error
        }

        // The batch is committed once every destination exists. Failing to unlink an old
        // path leaves a harmless duplicate, but every returned destination remains complete.
        for item in prepared {
            try? fileManager.removeItem(at: item.original)
        }

        return zip(attachments, committed).map { attachment, item in
            ChatAttachment(
                id: attachment.id,
                displayName: attachment.displayName,
                kind: attachment.kind,
                stagedURL: item.destination,
                mediaType: attachment.mediaType,
                byteCount: attachment.byteCount,
                sourceIdentity: attachment.sourceIdentity,
                thumbnailDataURL: attachment.thumbnailDataURL
            )
        }
    }

    private func stageImageFile(
        _ sourceURL: URL,
        id: UUID,
        conversationID: UUID
    ) throws -> ChatAttachment {
        _ = id
        _ = conversationID
        throw AssistantAttachmentStoreError.imageDecode(sourceURL.lastPathComponent)
    }

    private func read(_ sourceURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: sourceURL)
        } catch {
            throw AssistantAttachmentStoreError.unreadable(sourceURL.lastPathComponent)
        }
    }

    private func write(
        data: Data,
        displayName: String,
        kind: ChatAttachmentKind,
        mediaType: String,
        sourceIdentity: String,
        pathExtension: String,
        conversationID: UUID,
        id: UUID,
        thumbnailDataURL: String? = nil
    ) throws -> ChatAttachment {
        let directory = conversationDirectory(for: conversationID)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = "\(id.uuidString)-\(sanitizeBasename(displayName)).\(pathExtension)"
            let destination = directory.appendingPathComponent(filename)
            try data.write(to: destination, options: .atomic)
            return ChatAttachment(
                id: id,
                displayName: displayName,
                kind: kind,
                stagedURL: destination,
                mediaType: mediaType,
                byteCount: Int64(data.count),
                sourceIdentity: sourceIdentity,
                thumbnailDataURL: thumbnailDataURL
            )
        } catch {
            throw AssistantAttachmentStoreError.unreadable(displayName)
        }
    }

    private func conversationDirectory(for conversationID: UUID) -> URL {
        managedRoot.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func sanitizeBasename(_ displayName: String) -> String {
        let basename = (displayName as NSString).deletingPathExtension
        let sanitizedScalars = basename.unicodeScalars.map { scalar -> Character in
            if
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "/"
                    || scalar == "\\"
                    || scalar == ":"
            {
                return "-"
            }
            return Character(String(scalar))
        }
        let sanitized = String(sanitizedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty || sanitized == "." || sanitized == ".."
            ? "attachment"
            : sanitized
    }
}
