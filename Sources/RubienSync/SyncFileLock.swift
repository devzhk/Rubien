#if canImport(CloudKit)
import Foundation
import RubienCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX advisory-lock wrapper for the single-writer invariant between the
/// app and the CLI: Apple's CKSyncEngine contract is "one engine per
/// database per process", so if both Rubien.app and `rubien-cli sync push`
/// were to run their engines against the same `library.sqlite` they would
/// race on state and corrupt each other's change tags.
///
/// The lockfile lives next to `library.sqlite` as
/// `library.sqlite-sync.lock`. Whichever side acquires the exclusive lock
/// first gets to run its sync; the other side either waits or exits
/// depending on which call it used.
///
/// Unrelated to SQLite's own WAL/database locks — those are per-connection
/// for concurrent DB readers/writers; this lock guards a higher-level
/// invariant about the CloudKit sync engine.
public final class SyncFileLock: @unchecked Sendable {

    public let fileURL: URL
    private let fileDescriptor: Int32
    private var isLocked = false

    /// Open (or create) the lock file. Creation uses mode 0o644 so the
    /// user's other tools can inspect it; it carries no content.
    ///
    /// Sets `FD_CLOEXEC` so child processes (e.g. anything the app
    /// `exec`s — helper binaries, crash reporters) don't inherit the
    /// open-file-description and with it the advisory lock. Without
    /// this, a helper that outlives the parent could hold the sync
    /// lock indefinitely and block the CLI.
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let fd = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        if fd == -1 {
            throw SyncFileLockError.openFailed(errno: errno)
        }
        self.fileDescriptor = fd
    }

    deinit {
        if isLocked {
            _ = flock(fileDescriptor, LOCK_UN)
        }
        close(fileDescriptor)
    }

    /// Acquire an exclusive lock, blocking until available. Prefer
    /// `tryLockExclusive()` for UI-facing code — blocking indefinitely
    /// behind a possibly-hung other process is rarely the right
    /// behavior.
    public func lockExclusive() throws {
        if flock(fileDescriptor, LOCK_EX) == -1 {
            throw SyncFileLockError.lockFailed(errno: errno)
        }
        isLocked = true
    }

    /// Attempt to acquire an exclusive lock without blocking. Returns
    /// `false` immediately if another process holds the lock.
    public func tryLockExclusive() throws -> Bool {
        let result = flock(fileDescriptor, LOCK_EX | LOCK_NB)
        if result == 0 {
            isLocked = true
            return true
        }
        // EWOULDBLOCK on macOS, EAGAIN on some platforms — `flock(2)`
        // defines them as equivalent values but the symbolic name
        // differs between flavors. Normalize both.
        let err = errno
        if err == EWOULDBLOCK || err == EAGAIN {
            return false
        }
        throw SyncFileLockError.lockFailed(errno: err)
    }

    public func unlock() throws {
        guard isLocked else { return }
        if flock(fileDescriptor, LOCK_UN) == -1 {
            throw SyncFileLockError.unlockFailed(errno: errno)
        }
        isLocked = false
    }

    /// Scope helper: acquire, run the body, release. The body runs with
    /// the lock held; lock is released on normal return and on throw.
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try lockExclusive()
        defer { try? unlock() }
        return try body()
    }

    /// Non-blocking scope helper. Returns `nil` if the lock is held by
    /// another process — caller should treat that as "can't run sync
    /// right now" rather than a hard error.
    public func withTryLock<T>(_ body: () throws -> T) throws -> T? {
        guard try tryLockExclusive() else { return nil }
        defer { try? unlock() }
        return try body()
    }
}

public enum SyncFileLockError: Error, CustomStringConvertible {
    case openFailed(errno: Int32)
    case lockFailed(errno: Int32)
    case unlockFailed(errno: Int32)

    public var description: String {
        switch self {
        case .openFailed(let e):
            return "SyncFileLock.open failed (errno=\(e): \(String(cString: strerror(e))))"
        case .lockFailed(let e):
            return "SyncFileLock.lock failed (errno=\(e): \(String(cString: strerror(e))))"
        case .unlockFailed(let e):
            return "SyncFileLock.unlock failed (errno=\(e): \(String(cString: strerror(e))))"
        }
    }
}

public extension SyncFileLock {
    /// Canonical path next to `library.sqlite` under Application Support.
    static var defaultURL: URL {
        AppDatabase.syncEngineStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("library.sqlite-sync.lock")
    }
}

#endif
