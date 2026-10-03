import Foundation

enum AttachmentMigrationValidation {
    /// Validate only attachment bytes; existing PDF/metadata migration is unchanged.
    static func validateCopy(from sourceRoot: URL, to destinationRoot: URL) throws {
        let sourcePath = sourceRoot.appendingPathComponent("Attachments")
        let destination = destinationRoot.appendingPathComponent("Attachments")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath.path) else { return }
        guard try sourcePath.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ReferenceAttachmentError.invalidPath
        }
        // File enumeration and URL resolution can spell /var differently.
        // Resolve both roots and children before deriving relative paths.
        let source = sourcePath.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                             errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ReferenceAttachmentError.unavailable
        }
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw ReferenceAttachmentError.invalidPath }
            guard properties.isRegularFile == true else { continue }
            let childPath = url.resolvingSymlinksInPath().path
            guard childPath.hasPrefix(source.path + "/") else {
                throw ReferenceAttachmentError.invalidPath
            }
            let relative = String(childPath.dropFirst(source.path.count + 1))
            if [".ownership.lock", ".published.lock"].contains(relative) { continue }
            let copied = destination.appendingPathComponent(relative)
            guard (try copied.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ReferenceAttachmentError.invalidPath
            }
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == copied.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw ReferenceAttachmentError.integrityMismatch
            }
            let original = try ReferenceAttachmentStore.hash(url, limit: .max)
            let copy = try ReferenceAttachmentStore.hash(copied, limit: .max)
            guard original.hash == copy.hash, original.count == copy.count else {
                throw ReferenceAttachmentError.integrityMismatch
            }
        }
        if let enumerationError { throw enumerationError }
    }
}
