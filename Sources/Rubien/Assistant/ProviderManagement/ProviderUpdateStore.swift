#if os(macOS)
import Foundation
import CryptoKit
import Darwin

struct ProviderReleaseSnapshot: Codable, Equatable, Sendable {
    let installedVersion: String
    let availableVersion: String
    let source: ProviderReleaseSource
    let fingerprint: ProviderBinaryFingerprint
    let checkedAt: Date

    var hasNewerRelease: Bool {
        guard let installed = ProviderReleaseVersion(installedVersion), !installed.isPrerelease,
              let available = ProviderReleaseVersion(availableVersion) else { return false }
        return installed < available
    }
}

struct ProviderUpdateRecord: Codable, Sendable {
    var automaticChecks = true
    var snapshot: ProviderReleaseSnapshot?
    var nextCheckAt: Date?
    var retryAfter: Date?
    var failureCount = 0
    var lastError: String?
    var deferredVersion: String?
    var deferredUntil: Date?

    func shouldCheck(manual: Bool, now: Date) -> Bool {
        if let retryAfter, retryAfter > now { return false }
        return manual || (automaticChecks && (nextCheckAt.map { $0 <= now } ?? true))
    }
    func allowsNotice(now: Date) -> Bool {
        guard automaticChecks, lastError == nil, let snapshot, snapshot.hasNewerRelease,
              snapshot.source.allowsReleaseNotice,
              now.timeIntervalSince(snapshot.checkedAt) >= 0,
              now.timeIntervalSince(snapshot.checkedAt) <= 25 * 3600 else { return false }
        return deferredVersion != snapshot.availableVersion || (deferredUntil.map { $0 <= now } ?? true)
    }
    mutating func succeeded(_ result: ProviderReleaseSnapshot, jitter: TimeInterval) {
        snapshot = result
        lastError = nil
        failureCount = 0
        retryAfter = nil
        nextCheckAt = result.checkedAt.addingTimeInterval(86400 + max(0, min(jitter, 1800)))
    }
    mutating func failed(message: String, now: Date, retryAfter: Date?) {
        lastError = message
        failureCount = min(failureCount + 1, 3)
        self.retryAfter = retryAfter
        let delay: TimeInterval = failureCount == 1 ? 3600 : failureCount == 2 ? 6 * 3600 : 86400
        nextCheckAt = max(now.addingTimeInterval(delay), retryAfter ?? now)
    }
}

/// Shared across bundle identities, outside the library and iCloud. Check locks
/// deduplicate network work; short record locks preserve concurrent preference edits.
final class ProviderUpdateStore: @unchecked Sendable {
    static let standard = ProviderUpdateStore(root: ProviderSetupStore.standard.root.appendingPathComponent("ReleaseChecks"))
    let root: URL
    private let preparationLock = NSLock()
    private var prepared = false
    init(root: URL) { self.root = root }

    static func key(provider: AgentProviderKind, path: String) -> String {
        let identity = provider.rawValue + "\n" + URL(fileURLWithPath: path).standardizedFileURL.path
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read(_ key: String) -> ProviderUpdateRecord {
        let url = root.appendingPathComponent(key + ".json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 32 * 1024,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(ProviderUpdateRecord.self, from: data) else { return .init() }
        return record
    }

    @discardableResult
    func modify(_ key: String, _ change: (inout ProviderUpdateRecord) -> Void) throws -> ProviderUpdateRecord {
        guard let lock = try acquire(key + ".record.lock") else {
            throw CocoaError(.fileLocking)
        }
        defer { withExtendedLifetime(lock) {} }
        var record = read(key)
        change(&record)
        let url = root.appendingPathComponent(key + ".json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return record
    }

    func acquireCheck(_ key: String) throws -> ProviderSetupLock? {
        try acquire(key + ".check.lock")
    }

    private func acquire(_ name: String) throws -> ProviderSetupLock? {
        try prepare()
        let url = root.appendingPathComponent(name)
        do {
            return try ProviderSetupLock(url: url)
        } catch let error as POSIXError where error.code == .ENOENT {
            try prepare(force: true)
            return try ProviderSetupLock(url: url)
        }
    }

    private func prepare(force: Bool = false) throws {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared, !force { return }
        prepared = false
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        prepared = true
    }
}
#endif
