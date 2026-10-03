#if os(macOS)
import Foundation
import Darwin
import CryptoKit

enum ProviderSetupAction: String, Codable, CaseIterable, Sendable {
    case install, login
}

struct ProviderSetupRecord: Codable, Equatable, Sendable {
    let id: UUID
    let provider: AgentProviderKind
    let action: ProviderSetupAction
    var stage: String
    var finished: Bool
    var succeeded: Bool
    var updatedAt: Date
    var path: String?
    var version: String?
    var scriptHash: String?
    var scriptPath: String?
    var sourceURL: String?
    var scriptFingerprint: ProviderBinaryFingerprint?
    var detail: String?
    var nativeRoot: String?
    var fingerprint: ProviderBinaryFingerprint?
}

final class ProviderSetupLock: @unchecked Sendable {
    private let fd: Int32
    var descriptor: Int32 { fd }
    enum Mode { case shared, exclusive }
    init?(url: URL, mode: Mode = .exclusive) throws {
        fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
    deinit { Darwin.close(fd) }
}

final class ProviderSetupStore: @unchecked Sendable {
    let root: URL
    private let preparationLock = NSLock()
    private var prepared = false

    init(root: URL) { self.root = root }

    static let standard = ProviderSetupStore(root: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Rubien/ProviderManagement"))
    /// A quick snapshot: callers return immediately instead of queuing an auth probe.
    func maintenanceAvailability(provider: AgentProviderKind) -> AgentAvailability? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        for action in ProviderSetupAction.allCases {
            let url = root.appendingPathComponent("\(provider.rawValue)-\(action.rawValue).lock")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                if let lock = try ProviderSetupLock(url: url, mode: .shared) { withExtendedLifetime(lock) {}; continue }
                let record = read(provider: provider, action: action)
                return AgentAvailability(isInstalled: record?.path != nil, isAuthenticated: false,
                    version: record?.version, resolvedPath: record?.path,
                    unavailableReason: "\(provider.setupName) setup is running. Finish setup or view its progress in Settings → Assistant.",
                    setupInProgress: true)
            } catch { continue }
        }
        return nil
    }
    func acquire(provider: AgentProviderKind, action: ProviderSetupAction = .install, mode: ProviderSetupLock.Mode = .exclusive) throws -> ProviderSetupLock? {
        try prepare()
        // A provider-wide install lock also covers discovery before a native owner exists.
        let url = root.appendingPathComponent("\(provider.rawValue)-\(action.rawValue).lock")
        do {
            return try ProviderSetupLock(url: url, mode: mode)
        } catch let error as POSIXError where error.code == .ENOENT {
            try prepare(force: true)
            return try ProviderSetupLock(url: url, mode: mode)
        }
    }
    /// Give brief status readers time to finish without queuing behind another
    /// setup action. Never hold a shared lock while sleeping or acquiring exclusive.
    func acquireForAction(provider: AgentProviderKind, action: ProviderSetupAction = .install) async throws -> ProviderSetupLock? {
        for attempt in 0...5 {
            try Task.checkCancellation()
            if let lock = try acquire(provider: provider, action: action) { return lock }
            do {
                guard let reader = try acquire(provider: provider, action: action, mode: .shared) else { return nil }
                withExtendedLifetime(reader) {}
            }
            guard attempt < 5 else { return nil }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
    func read(provider: AgentProviderKind, action: ProviderSetupAction = .install) -> ProviderSetupRecord? {
        let url = recordURL(provider, action)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue < 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProviderSetupRecord.self, from: data)
    }
    /// Finalize abandoned intent once, under the action's exclusive lock. A
    /// successful health check may clear the notice, but never creates a receipt.
    func recoverInterrupted(provider: AgentProviderKind, action: ProviderSetupAction, expectedID: UUID) throws -> Bool {
        guard let lock = try acquire(provider: provider, action: action) else { return false }
        defer { withExtendedLifetime(lock) {} }
        guard var record = read(provider: provider, action: action), record.id == expectedID, !record.finished else { return false }
        if action == .install { cleanAbandonedDownload(record) }
        record.finished = true
        record.succeeded = false
        record.stage = "Interrupted"
        record.detail = ProviderSetupError.interrupted.localizedDescription
        record.updatedAt = Date()
        try write(record)
        return true
    }
    func cleanAbandonedDownload(_ record: ProviderSetupRecord) {
        guard !record.finished, let path = record.scriptPath else { return }
        let script = URL(fileURLWithPath: path).standardizedFileURL
        let folder = script.deletingLastPathComponent()
        let prefix = "rubien-provider-"
        guard script.lastPathComponent == "install.sh", folder.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(folder.lastPathComponent.dropFirst(prefix.count))) != nil,
              folder.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: folder.path),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return }
        try? FileManager.default.removeItem(at: folder)
    }
    func write(_ record: ProviderSetupRecord) throws {
        try prepare()
        let data = try JSONEncoder().encode(record)
        try data.write(to: recordURL(record.provider, record.action), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL(record.provider, record.action).path)
    }
    func saveReceipt(_ record: ProviderSetupRecord) throws {
        guard record.action == .install, record.finished, record.succeeded,
              let path = record.path, let version = record.version, !version.isEmpty,
              let fingerprint = record.fingerprint,
              let nativeRoot = record.nativeRoot, fingerprint.target.hasPrefix(nativeRoot + "/"),
              ProviderBinaryFingerprint.read(path) == fingerprint, record.scriptHash != nil else { throw ProviderSetupError.verification }
        try prepare()
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("\(record.provider.rawValue)-receipt.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("\(record.provider.rawValue)-receipt.json").path)
    }
    private func recordURL(_ provider: AgentProviderKind, _ action: ProviderSetupAction) -> URL {
        root.appendingPathComponent("\(provider.rawValue)-\(action.rawValue).json")
    }
    private func prepare(force: Bool = false) throws {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if prepared && !force { return }
        prepared = false
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        prepared = true
    }
}

enum ProviderSetupError: LocalizedError {
    case existingInstallation, download, verification, scriptChanged, command(String), interrupted
    var errorDescription: String? {
        switch self {
        case .existingInstallation: return "An existing or unverified installation was found. Recheck or choose its executable."
        case .download: return "The official installer could not be downloaded completely. No installer was run."
        case .verification: return "The installer finished, but Rubien could not verify the expected executable and version."
        case .scriptChanged: return "The downloaded installer changed before execution. Please try again."
        case .command(let detail): return detail
        case .interrupted: return "The previous setup was interrupted. Recheck the installation before trying again."
        }
    }
}

struct ProviderDownloadedScript: Equatable, Sendable {
    let hash: String
    let byteCount: Int
    let sourceURL: URL
    let fingerprint: ProviderBinaryFingerprint
}

struct ProviderInstallerPlan: Sendable {
    let provider: AgentProviderKind
    let directory: URL
    var script: URL { directory.appendingPathComponent("install.sh") }
    var headers: URL { directory.appendingPathComponent("headers.txt") }
    var downloadArguments: [String] {
        ["--disable", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "60",
         "--max-filesize", "2097152", "--max-redirs", "5", "--dump-header", headers.path,
         "--output", script.path, provider.installerURL.absoluteString]
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    var displayedProcedure: String {
        "/usr/bin/curl " + downloadArguments.map(Self.quote).joined(separator: " ") + "\n"
        + (provider == .codex ? "CODEX_NON_INTERACTIVE=1 " : "")
        + provider.installerShell + " " + Self.quote(script.path)
    }
    func validateDownload() throws -> String { try inspectDownload().hash }
    func inspectDownload() throws -> ProviderDownloadedScript {
        let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else { throw ProviderSetupError.download }
        let data = try Data(contentsOf: script)
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8), text.hasPrefix("#!/") else { throw ProviderSetupError.download }
        let headerSize = try FileManager.default.attributesOfItem(atPath: headers.path)[.size] as? NSNumber
        guard let headerSize, headerSize.intValue <= 128 * 1024 else { throw ProviderSetupError.download }
        let headerText = try String(contentsOf: headers, encoding: .utf8)
        let allowed = provider == .codex ? ["chatgpt.com", "releases.openai.com"] : ["claude.ai", "downloads.claude.ai"]
        var base = provider.installerURL
        for line in headerText.components(separatedBy: .newlines) where line.lowercased().hasPrefix("location:") {
            let value = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  url.scheme == "https", let host = url.host, allowed.contains(host),
                  url.user == nil, url.password == nil else { throw ProviderSetupError.download }
            base = url
        }
        guard let fingerprint = ProviderBinaryFingerprint.read(script.path) else { throw ProviderSetupError.download }
        return ProviderDownloadedScript(hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                        byteCount: data.count, sourceURL: base, fingerprint: fingerprint)
    }
}
#endif
