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
    case writeFailed(String)
    case rehomeRecovered([ChatAttachment])

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
        case .writeFailed(let name):
            return "\(name) could not be saved in Rubien's attachment storage."
        case .rehomeRecovered:
            return "Attachments were recovered in Rubien's storage but still need to be reconciled."
        }
    }
}

actor AssistantAttachmentStore {
    static let relativeRoot = ".rubien/attachments"
    static let maxTextBytes: Int64 = 5 * 1_024 * 1_024

    nonisolated let managedRoot: URL

    private let fileManager: FileManager
    private let workspaceRoot: URL

    private static func canonicalWorkspaceURL(_ workspaceURL: URL) -> URL {
        workspaceURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func managedRootURL(for workspaceURL: URL) -> URL {
        canonicalWorkspaceURL(workspaceURL)
            .appendingPathComponent(relativeRoot, isDirectory: true)
            .standardizedFileURL
    }

    init(workspaceURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        workspaceRoot = Self.canonicalWorkspaceURL(workspaceURL)
        managedRoot = Self.managedRootURL(for: workspaceURL)
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
        guard let fileSize = values.fileSize else {
            throw AssistantAttachmentStoreError.unreadable(name)
        }

        let pathExtension = sourceURL.pathExtension.lowercased()
        guard ["md", "markdown", "txt"].contains(pathExtension) else {
            let claimedImage = UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true
            return try stageImageFile(
                sourceURL,
                id: id,
                conversationID: conversationID,
                fallbackError: claimedImage ? nil : .unsupported(name)
            )
        }

        guard Int64(fileSize) <= Self.maxTextBytes else {
            return try stageImageFile(
                sourceURL,
                id: id,
                conversationID: conversationID,
                fallbackError: .tooLarge(name)
            )
        }

        let data = try readText(sourceURL)
        guard Int64(data.count) <= Self.maxTextBytes else {
            return try stageImageFile(
                sourceURL,
                id: id,
                conversationID: conversationID,
                fallbackError: .tooLarge(name)
            )
        }

        let body = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        guard String(data: body, encoding: .utf8) != nil else {
            return try stageImageFile(
                sourceURL,
                data: data,
                id: id,
                conversationID: conversationID,
                fallbackError: .nonUTF8(name)
            )
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
        let normalized = try AssistantImageNormalizer.normalize(
            data,
            displayName: suggestedName
        )
        return try write(
            data: normalized.data,
            displayName: suggestedName,
            kind: .image,
            mediaType: normalized.mediaType,
            sourceIdentity: "clipboard:\(UUID().uuidString)",
            pathExtension: normalized.pathExtension,
            conversationID: conversationID,
            id: id,
            thumbnailDataURL: normalized.thumbnailDataURL
        )
    }

    func removePending(_ attachments: [ChatAttachment]) {
        for attachment in attachments {
            guard isOwnedAttachment(attachment) else { continue }
            try? removeManagedItem(at: attachment.stagedURL)
        }
    }

    func rehomePending(
        _ attachments: [ChatAttachment],
        to conversationID: UUID
    ) throws -> [ChatAttachment] {
        guard !attachments.isEmpty else { return [] }

        let destinationDirectory = conversationDirectory(for: conversationID)
        let planned = attachments.map { attachment in
            (
                attachment: attachment,
                destination: destinationDirectory
                    .appendingPathComponent(attachment.stagedURL.lastPathComponent)
            )
        }
        let alreadyHomed = planned.allSatisfy {
            $0.attachment.stagedURL.standardizedFileURL == $0.destination.standardizedFileURL
        }

        var attachmentIDs = Set<UUID>()
        for item in planned {
            guard
                attachmentIDs.insert(item.attachment.id).inserted,
                item.attachment.stagedURL.lastPathComponent
                    .hasPrefix(item.attachment.id.uuidString + "-"),
                isOwnedAttachment(item.attachment)
            else {
                throw AssistantAttachmentStoreError.unreadable(item.attachment.displayName)
            }
        }
        if alreadyHomed { return attachments }
        if let invalid = planned.first(where: {
            $0.attachment.stagedURL.standardizedFileURL
                == $0.destination.standardizedFileURL
        }) {
            throw AssistantAttachmentStoreError.unreadable(invalid.attachment.displayName)
        }

        try createManagedDirectory(
            destinationDirectory,
            displayName: attachments[0].displayName
        )

        // A prior failed commit may have left one of these deterministic, ID-derived
        // destinations behind. Originals have all been verified and remain authoritative,
        // so stale destinations can be reconciled before this attempt prepares any copies.
        // If removal fails, throwing here leaves every original untouched for a later retry.
        for item in planned where pathEntryExists(at: item.destination) {
            do {
                try removeManagedItem(at: item.destination)
            } catch {
                throw AssistantAttachmentStoreError.writeFailed(item.attachment.displayName)
            }
        }

        var prepared: [(
            original: URL,
            temporary: URL,
            destination: URL,
            displayName: String
        )] = []
        prepared.reserveCapacity(attachments.count)

        do {
            for item in planned {
                let temporary = destinationDirectory
                    .appendingPathComponent(".rehome-\(UUID().uuidString)")
                // Prepare complete copies under transaction-private names while every
                // caller-visible original remains untouched.
                prepared.append(
                    (
                        item.attachment.stagedURL,
                        temporary,
                        item.destination,
                        item.attachment.displayName
                    )
                )
                do {
                    try validateManagedPath(
                        item.attachment.stagedURL,
                        requireExisting: true
                    )
                } catch {
                    throw AssistantAttachmentStoreError.unreadable(
                        item.attachment.displayName
                    )
                }
                try validateManagedPath(temporary, requireExisting: false)
                try fileManager.copyItem(at: item.attachment.stagedURL, to: temporary)
                try validateManagedPath(temporary, requireExisting: true)
            }
        } catch {
            // Originals were never moved. Cleanup failures can leave only private
            // temporary copies; every URL held by the caller remains usable.
            for item in prepared.reversed() {
                try? removeManagedItem(at: item.temporary)
            }
            if let attachmentError = error as? AssistantAttachmentStoreError {
                throw attachmentError
            }
            let name = prepared.last?.displayName ?? attachments[0].displayName
            throw AssistantAttachmentStoreError.writeFailed(name)
        }

        var committed: [(original: URL, destination: URL)] = []
        committed.reserveCapacity(prepared.count)
        var committingName = prepared[0].displayName
        do {
            for item in prepared {
                committingName = item.displayName
                // These renames stay within one conversation directory and are atomic on
                // the underlying volume.
                try validateManagedPath(item.temporary, requireExisting: true)
                try validateManagedPath(item.destination, requireExisting: false)
                try fileManager.moveItem(at: item.temporary, to: item.destination)
                committed.append((item.original, item.destination))
                try validateManagedPath(item.destination, requireExisting: true)
            }
        } catch {
            // Even if cleanup itself is interrupted, originals are still authoritative and
            // readable. At worst, transaction-private or destination duplicates remain.
            for item in prepared {
                try? removeManagedItem(at: item.temporary)
            }
            for item in committed.reversed() {
                try? removeManagedItem(at: item.destination)
            }
            throw AssistantAttachmentStoreError.writeFailed(committingName)
        }

        // Keep caller-held originals authoritative until cleanup succeeds for the whole
        // batch. If an unlink fails, restore any originals already removed, discard every
        // committed destination, and throw so callers retain their original attachment set.
        var removedOriginals: [(original: URL, destination: URL)] = []
        do {
            for item in prepared {
                try removeManagedItem(at: item.original)
                removedOriginals.append((item.original, item.destination))
            }
        } catch {
            var restorationFailed = false
            for item in removedOriginals.reversed() where !pathEntryExists(at: item.original) {
                do {
                    try validateManagedPath(item.destination, requireExisting: true)
                    try validateManagedPath(item.original, requireExisting: false)
                    try fileManager.copyItem(at: item.destination, to: item.original)
                    try validateManagedPath(item.original, requireExisting: true)
                } catch {
                    restorationFailed = true
                }
            }

            if restorationFailed {
                // Rollback can no longer make every original authoritative. Keep the
                // complete committed batch and transfer those URLs back to the caller
                // so no recovery copy becomes unreachable or unremovable. Best-effort
                // cleanup of remaining originals only removes duplicates.
                for item in prepared where pathEntryExists(at: item.original) {
                    try? removeManagedItem(at: item.original)
                }
                let recovered = zip(attachments, committed).map { attachment, item in
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
                throw AssistantAttachmentStoreError.rehomeRecovered(recovered)
            }

            for item in committed.reversed() {
                try? removeManagedItem(at: item.destination)
            }
            let failedIndex = min(removedOriginals.count, prepared.count - 1)
            throw AssistantAttachmentStoreError.writeFailed(prepared[failedIndex].displayName)
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
        data: Data? = nil,
        id: UUID,
        conversationID: UUID,
        fallbackError: AssistantAttachmentStoreError? = nil
    ) throws -> ChatAttachment {
        let normalized: NormalizedAssistantImage
        do {
            if let data {
                normalized = try AssistantImageNormalizer.normalize(
                    data,
                    displayName: sourceURL.lastPathComponent
                )
            } else {
                normalized = try AssistantImageNormalizer.normalize(
                    fileURL: sourceURL,
                    displayName: sourceURL.lastPathComponent
                )
            }
        } catch let error as AssistantAttachmentStoreError {
            if case .imageDecode = error, let fallbackError {
                throw fallbackError
            }
            throw error
        }
        return try write(
            data: normalized.data,
            displayName: sourceURL.lastPathComponent,
            kind: .image,
            mediaType: normalized.mediaType,
            sourceIdentity: sourceURL.standardizedFileURL.path,
            pathExtension: normalized.pathExtension,
            conversationID: conversationID,
            id: id,
            thumbnailDataURL: normalized.thumbnailDataURL
        )
    }

    private func readText(_ sourceURL: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            let limit = Int(Self.maxTextBytes + 1)
            var data = Data()
            while data.count < limit {
                let requested = min(64 * 1_024, limit - data.count)
                guard
                    let chunk = try handle.read(upToCount: requested),
                    !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
            return data
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
            try createManagedDirectory(directory, displayName: displayName)
            let filename = stagedFilename(
                id: id,
                displayName: displayName,
                pathExtension: pathExtension
            )
            let destination = directory.appendingPathComponent(filename)
            try validateManagedPath(destination, requireExisting: false)
            try data.write(to: destination, options: .atomic)
            try validateManagedPath(destination, requireExisting: true)
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
        } catch let error as AssistantAttachmentStoreError {
            throw error
        } catch {
            throw AssistantAttachmentStoreError.writeFailed(displayName)
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

    private func stagedFilename(
        id: UUID,
        displayName: String,
        pathExtension: String
    ) -> String {
        let prefix = id.uuidString + "-"
        let suffix = pathExtension.isEmpty ? "" : "." + pathExtension
        let basenameBudget = max(0, 255 - prefix.utf8.count - suffix.utf8.count)
        let basename = truncateUTF8(sanitizeBasename(displayName), to: basenameBudget)
        return prefix + basename + suffix
    }

    private func truncateUTF8(_ value: String, to byteLimit: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= byteLimit else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private func createManagedDirectory(_ directory: URL, displayName: String) throws {
        do {
            try validateManagedPath(directory, requireExisting: false)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try validateManagedPath(directory, requireExisting: true)
        } catch {
            throw AssistantAttachmentStoreError.writeFailed(displayName)
        }
    }

    private func isOwnedAttachment(_ attachment: ChatAttachment) -> Bool {
        guard
            attachment.stagedURL.lastPathComponent
                .hasPrefix(attachment.id.uuidString + "-")
        else {
            return false
        }

        do {
            try validateManagedPath(attachment.stagedURL, requireExisting: true)
            let values = try attachment.stagedURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isReadableKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
            ])
            return values.isRegularFile == true
                && values.isReadable == true
                && values.isSymbolicLink != true
                && values.isAliasFile != true
        } catch {
            return false
        }
    }

    private func removeManagedItem(at url: URL) throws {
        try validateManagedPath(url, requireExisting: true)
        try fileManager.removeItem(at: url)
    }

    private func validateManagedPath(_ url: URL, requireExisting: Bool) throws {
        let target = url.standardizedFileURL
        let workspaceComponents = workspaceRoot.pathComponents
        let managedComponents = managedRoot.pathComponents
        let targetComponents = target.pathComponents

        guard
            targetComponents.count >= managedComponents.count,
            targetComponents.starts(with: managedComponents),
            managedComponents.starts(with: workspaceComponents)
        else {
            throw ManagedPathError.outsideRoot
        }

        var current = workspaceRoot
        var encounteredMissingComponent = false
        for component in targetComponents.dropFirst(workspaceComponents.count) {
            current.appendPathComponent(component)
            if isSymbolicLink(at: current) {
                throw ManagedPathError.symbolicLink
            }
            if fileManager.fileExists(atPath: current.path) {
                if encounteredMissingComponent {
                    throw ManagedPathError.invalidPath
                }
            } else {
                encounteredMissingComponent = true
            }
        }

        if requireExisting, !pathEntryExists(at: target) {
            throw ManagedPathError.missing
        }

        let resolvedWorkspace = workspaceRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedWorkspace.pathComponents == workspaceComponents else {
            throw ManagedPathError.outsideRoot
        }

        let resolvedTarget = target
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isContained(resolvedTarget, in: resolvedWorkspace) else {
            throw ManagedPathError.outsideRoot
        }

        if fileManager.fileExists(atPath: managedRoot.path) {
            let resolvedManagedRoot = managedRoot
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard
                isContained(resolvedManagedRoot, in: resolvedWorkspace),
                isContained(resolvedTarget, in: resolvedManagedRoot)
            else {
                throw ManagedPathError.outsideRoot
            }
        }
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func pathEntryExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(at: url)
    }

    private enum ManagedPathError: Error {
        case outsideRoot
        case symbolicLink
        case invalidPath
        case missing
    }
}
