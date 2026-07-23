import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Exclusive advisory ownership for Assistant execution against one resolved
/// Rubien library. The file contents are diagnostic only; `flock` is authority,
/// so process death releases ownership automatically.
public final class AssistantLibraryExecutionLock: @unchecked Sendable {
    public static let filename = "assistant-execution.lock"

    public let lockFileURL: URL
    public let ownerDescription: String
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var isReleased = false

    private init(lockFileURL: URL, descriptor: Int32, ownerDescription: String) {
        self.lockFileURL = lockFileURL
        self.descriptor = descriptor
        self.ownerDescription = ownerDescription
    }

    /// Attempts to become the sole Assistant executor for `libraryRoot` without
    /// waiting. Reads never need this lock; provider admission, recovery, and
    /// destructive transcript/job mutations do.
    public static func tryAcquire(
        libraryRoot: URL,
        ownerDescription: String
    ) throws -> AssistantLibraryExecutionLock? {
        try FileManager.default.createDirectory(
            at: libraryRoot,
            withIntermediateDirectories: true
        )
        let url = libraryRoot.appendingPathComponent(filename, isDirectory: false)
        // The lock must die with Rubien, not leak into a spawned Claude/Codex
        // runtime. Refuse a pre-planted symlink as well: this file is truncated
        // below when its diagnostic owner record is refreshed.
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw AssistantExecutionLockError.openFailed(errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw AssistantExecutionLockError.lockFailed(code)
        }

        let lock = AssistantLibraryExecutionLock(
            lockFileURL: url,
            descriptor: descriptor,
            ownerDescription: ownerDescription
        )
        lock.writeOwnerRecord()
        return lock
    }

    public func release() {
        stateLock.lock()
        guard !isReleased else {
            stateLock.unlock()
            return
        }
        isReleased = true
        stateLock.unlock()
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit {
        release()
    }

    /// Best-effort owner text for a read-only second instance. It is never used
    /// as a liveness signal because a crashed process can leave stale bytes.
    public static func diagnosticOwner(libraryRoot: URL) -> String? {
        let url = libraryRoot.appendingPathComponent(filename, isDirectory: false)
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func writeOwnerRecord() {
        let record = "pid=\(ProcessInfo.processInfo.processIdentifier) owner=\(ownerDescription) acquired=\(ISO8601DateFormatter().string(from: Date()))\n"
        guard let data = record.data(using: .utf8) else { return }
        _ = ftruncate(descriptor, 0)
        _ = lseek(descriptor, 0, SEEK_SET)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = write(descriptor, base, bytes.count)
        }
        _ = fsync(descriptor)
    }
}

public enum AssistantExecutionLockError: Error, Equatable, LocalizedError {
    case openFailed(Int32)
    case lockFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(code):
            "Unable to open the Assistant execution lock (errno \(code))."
        case let .lockFailed(code):
            "Unable to acquire the Assistant execution lock (errno \(code))."
        }
    }
}
