#if os(macOS)
import Foundation

/// Lock identity follows the installation root, not a versioned binary. A held
/// intent lock is authoritative: process death cannot leave a stale admission flag.
enum ProviderUsageCoordinator {
    @TaskLocal static var storageRoot = ProviderSetupStore.standard.root.appendingPathComponent("Usage")

    static func packageRoot(_ path: String) -> String? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // Only the Codex npm adapter replaces a package in place.
        if let range = target.range(of: "/lib/node_modules/@openai/codex/") {
            return String(target[..<range.upperBound].dropLast())
        }
        // npm briefly removes the launcher while replacing its package. The
        // already-registered intent must still prevent starts during that gap.
        let launcher = URL(fileURLWithPath: path).standardizedFileURL
        if !FileManager.default.fileExists(atPath: path), launcher.deletingLastPathComponent().lastPathComponent == "bin",
           launcher.lastPathComponent == "codex" {
            let package = "@openai/codex"
            let prefix = launcher.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
            let root = prefix.appendingPathComponent("lib/node_modules/" + package).path
            let intent = storageRoot.appendingPathComponent(key(root)).appendingPathComponent("intent.lock")
            if FileManager.default.fileExists(atPath: intent.path) { return root }
        }
        return nil
    }

    static func pendingPath(provider: AgentProviderKind, override: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let selected = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = selected.flatMap { $0.isEmpty ? nil : [$0] } ?? provider.setupCandidates(home: home)
        return paths.first { pending(path: $0) }
    }

    static func key(_ root: String) -> String { ProviderUpdateStore.key(provider: .codex, path: root) }
    static func directory(_ root: String) throws -> URL {
        let url = storageRoot.appendingPathComponent(key(root))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func pending(root: String) -> Bool {
        let url = storageRoot.appendingPathComponent(key(root)).appendingPathComponent("intent.lock")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let lock = try ProviderSetupLock(url: url, mode: .shared)
            return lock == nil
        } catch { return true }
    }
    static func pending(path: String) -> Bool { packageRoot(path).map { pending(root: $0) } ?? false }

    static func acquireUsage(path: String, owner: ProviderUsageOwner? = nil) throws -> ProviderSetupLock? {
        guard let root = packageRoot(path) else { return nil }
        if let owner, owner.root == root { return nil }
        guard !pending(root: root) else { throw ProviderMutationError.busy }
        let url = try directory(root).appendingPathComponent("usage.lock")
        guard let lock = try ProviderSetupLock(url: url, mode: .shared), !pending(root: root),
              packageRoot(path) == root else { throw ProviderMutationError.busy }
        return lock
    }

    static func markDemand(path: String) {
        guard let root = packageRoot(path), let directory = try? directory(root) else { return }
        let file = directory.appendingPathComponent("demand")
        try? Data().write(to: file, options: .atomic)
    }
    static func demandSince(_ date: Date, root: String) -> Bool {
        let file = storageRoot.appendingPathComponent(key(root)).appendingPathComponent("demand")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return modified >= date
    }
}

/// An unforgeable in-process capability. Verification children inherit the owner's
/// exclusive descriptor instead of attempting a conflicting shared acquisition.
final class ProviderUsageOwner: @unchecked Sendable {
    let root: String
    let usage: ProviderSetupLock
    let intent: ProviderSetupLock
    init(root: String, usage: ProviderSetupLock, intent: ProviderSetupLock) {
        self.root = root
        self.usage = usage
        self.intent = intent
    }
}

enum ProviderMutationError: LocalizedError {
    case unsupported(String), deferred(String), changed, busy, timeout, failed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let text), .deferred(let text), .failed(let text): return text
        case .changed: return "The installation or update policy changed. Recheck before updating."
        case .busy: return "A provider update is running. Your conversation can continue when it finishes."
        case .timeout: return "The update is still waiting for another process to release this installation. Close its idle CLI sessions and retry. No running conversation was stopped."
        }
    }
}
#endif
