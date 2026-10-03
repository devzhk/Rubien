import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A process-local verification receipt. ctime detects same-size edits even when
/// an editor restores mtime. A new process always verifies bytes independently.
struct AttachmentFileSignature: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ReferenceAttachmentError.unavailable }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ReferenceAttachmentError.invalidPath }
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(info.st_mtim.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        changedSeconds = Int64(info.st_ctim.tv_sec)
        changedNanoseconds = Int64(info.st_ctim.tv_nsec)
        #endif
    }
}

final class AttachmentVerificationCache: @unchecked Sendable {
    static let shared = AttachmentVerificationCache()
    private let lock = NSLock()
    private var receipts: [String: AttachmentFileSignature] = [:]

    func contains(_ key: String, signature: AttachmentFileSignature, byteCount: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard signature == receipts[key], signature.size == byteCount else { return false }
        return true
    }

    func remember(_ key: String, signature: AttachmentFileSignature) {
        lock.lock()
        defer { lock.unlock() }
        if receipts.count >= 128 { receipts.removeAll(keepingCapacity: true) }
        receipts[key] = signature
    }
}
