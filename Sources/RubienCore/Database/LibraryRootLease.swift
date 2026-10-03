import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum LibraryRootLeaseError: Error, LocalizedError {
    case busy, invalidDatabase
    case promoted(destination: String)

    var errorDescription: String? {
        switch self {
        case .busy: return "The library is open in another process or is being moved. Close it and retry."
        case .promoted(let destination): return "This library was moved to \(destination). Use that location, or set RUBIEN_LIBRARY_ROOT to a separate development library. Keep the moved-library marker in place."
        case .invalidDatabase: return "The copied library failed its integrity check. The original library was retained."
        }
    }
}

/// Open libraries share a lease; promotion requires exclusive ownership of both roots.
/// Keep the lock inode outside the copied entries and never unlink it on release.
final class LibraryRootLease: @unchecked Sendable {
    static let markerName = ".rubien-promoted-to"
    private let descriptor: Int32

    init(root: URL, exclusive: Bool = false) throws {
        let url = root.appendingPathComponent(".library-root.lock")
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd)
            throw LibraryRootLeaseError.busy
        }
        if !exclusive && FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.markerName).path) {
            close(fd)
            throw LibraryRootLeaseError.promoted(destination: (try? String(contentsOf: root.appendingPathComponent(Self.markerName), encoding: .utf8)) ?? "the current library location")
        }
        descriptor = fd
    }

    static func forDatabase(at path: String) throws -> LibraryRootLease? {
        guard path.hasPrefix("/") else { return nil } // GRDB's in-memory databases have no root.
        return try LibraryRootLease(root: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    deinit { close(descriptor) }
}

public struct LibraryStartupError: Error, LocalizedError, Sendable {
    public let root: URL
    public let reason: String
    public var errorDescription: String? {
        "Could not open the library at \(root.path). \(reason) The existing library has been retained."
    }
}
