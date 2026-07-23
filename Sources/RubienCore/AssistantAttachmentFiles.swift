import Foundation

/// Portable filesystem lifecycle for Rubien-owned Assistant attachments. The
/// database owns the manifest; this helper removes bytes no longer named by it.
/// Cleanup is deliberately best-effort and idempotent so a database deletion is
/// never reported as rolled back after its transaction has already committed.
public enum AssistantAttachmentFiles {
    public static let directoryName = "AssistantAttachments"

    public static func removeConversation(
        id: String,
        libraryRoot: URL,
        fileManager: FileManager = .default
    ) {
        guard isSafePathComponent(id),
              let root = validatedRoot(
                libraryRoot: libraryRoot,
                fileManager: fileManager
              )
        else { return }
        let url = root.url.appendingPathComponent(id, isDirectory: true)
        if isSymbolicLink(url, fileManager: fileManager) {
            try? fileManager.removeItem(at: url)
            return
        }
        guard isContained(
            url.standardizedFileURL.resolvingSymlinksInPath(),
            in: root.resolvedURL,
            allowRoot: false
        ) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Removes abandoned pending copies and final files with no database row.
    /// Missing named files remain absent; callers render those attachments as
    /// unavailable rather than mutating the durable manifest.
    public static func reconcile(
        libraryRoot: URL,
        storedPaths: [StoredAssistantAttachmentPath],
        fileManager: FileManager = .default
    ) {
        guard let root = validatedRoot(
            libraryRoot: libraryRoot,
            fileManager: fileManager
        ) else { return }
        let pending = root.url.appendingPathComponent(".pending", isDirectory: true)
        if isSymbolicLink(pending, fileManager: fileManager) {
            try? fileManager.removeItem(at: pending)
        } else if isContained(
            pending.standardizedFileURL.resolvingSymlinksInPath(),
            in: root.resolvedURL,
            allowRoot: false
        ), let contents = try? fileManager.contentsOfDirectory(
            at: pending,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) {
            for url in contents { try? fileManager.removeItem(at: url) }
        }
        guard fileManager.fileExists(atPath: root.url.path) else { return }

        let allowed = Set(storedPaths.compactMap {
            allowedPath($0, root: root.url)
        })
        let enumerator = fileManager.enumerator(
            at: root.url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            if values?.isSymbolicLink == true
                || isSymbolicLink(url, fileManager: fileManager)
            {
                enumerator?.skipDescendants()
                try? fileManager.removeItem(at: url)
                continue
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isContained(
                resolved,
                in: root.resolvedURL,
                allowRoot: false
            ) else {
                if values?.isDirectory == true { enumerator?.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if !allowed.contains(url.standardizedFileURL.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private struct ValidatedRoot {
        let url: URL
        let resolvedURL: URL
    }

    private static func validatedRoot(
        libraryRoot: URL,
        fileManager: FileManager
    ) -> ValidatedRoot? {
        let library = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let root = libraryRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        guard !isSymbolicLink(root, fileManager: fileManager) else { return nil }
        let resolved = root.resolvingSymlinksInPath()
        guard isContained(resolved, in: library, allowRoot: false) else { return nil }
        return ValidatedRoot(url: root, resolvedURL: resolved)
    }

    private static func allowedPath(
        _ stored: StoredAssistantAttachmentPath,
        root: URL
    ) -> String? {
        guard isSafePathComponent(stored.id),
              isSafePathComponent(stored.conversationId),
              isValidRelativePath(
                stored.relativePath,
                attachmentID: stored.id
              )
        else { return nil }
        let candidate = root
            .appendingPathComponent(stored.conversationId, isDirectory: true)
            .appendingPathComponent(stored.relativePath)
            .standardizedFileURL
        guard isContained(candidate, in: root, allowRoot: false) else { return nil }
        return candidate.path
    }

    public static func isContained(
        _ candidate: URL,
        in root: URL,
        allowRoot: Bool
    ) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootComponents)
            && (allowRoot || candidateComponents.count > rootComponents.count)
    }

    public static func isSymbolicLink(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    public static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    public static func isValidRelativePath(
        _ relativePath: String,
        attachmentID: String
    ) -> Bool {
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else {
            return false
        }
        let parts = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return parts.count == 2
            && parts[0] == Substring(attachmentID.lowercased())
            && parts.allSatisfy { isSafePathComponent(String($0)) }
    }

    public static func sanitizeBasename(_ displayName: String) -> String {
        let basename = (displayName as NSString).deletingPathExtension
        let sanitizedScalars = basename.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar)
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

    public static func truncateUTF8(_ value: String, to byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }
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

    public static func sanitizedFilename(
        _ displayName: String,
        maxUTF8Bytes: Int = 240
    ) -> String {
        let last = URL(fileURLWithPath: displayName).lastPathComponent
        let pathExtension = (last as NSString).pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let budget = max(0, maxUTF8Bytes - suffix.utf8.count)
        let basename = truncateUTF8(sanitizeBasename(last), to: budget)
        return (basename.isEmpty ? "attachment" : basename) + suffix
    }
}
