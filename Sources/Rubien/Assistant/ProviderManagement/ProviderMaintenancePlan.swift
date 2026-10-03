#if os(macOS)
import Foundation

struct ProviderMaintenancePlan: Sendable, Equatable {
    enum Method: String, Sendable { case npm, codexNative, claudeNative }
    let provider: AgentProviderKind
    let method: Method
    let launcher: String
    let root: String
    let fingerprint: ProviderBinaryFingerprint
    let executable: String
    let executableFingerprint: ProviderBinaryFingerprint
    let packageManager: String?
    let packageManagerFingerprint: ProviderBinaryFingerprint?
    let previousVersion: String
    let targetVersion: String
    let arguments: [String]
    let environment: [String: String]

    var needsUsageExclusion: Bool { method == .npm }
    var allowsAutomaticInstall: Bool { method == .npm && provider == .codex }
    var command: String {
        ([executable] + arguments).map(ProviderInstallerPlan.quote).joined(separator: " ")
    }
    var identity: String { ProviderUpdateStore.key(provider: provider, path: root) }
    func unchanged() -> Bool {
        ProviderBinaryFingerprint.read(launcher) == fingerprint
            && ProviderBinaryFingerprint.read(executable) == executableFingerprint
            && (packageManager.map { ProviderBinaryFingerprint.read($0) == packageManagerFingerprint } ?? true)
    }
}

enum ProviderMaintenancePlanner {
    typealias Run = @Sendable (ProviderMaintenanceRequest) async throws -> ProviderCommandResult
    // Compatibility gate: this bootstrap preserved every old release resource in
    // the live retention test. Revalidate that contract when the script changes.
    static let reviewedCodexScriptHash = "150e3cf675682efeaac115aa3747add3f27887896d04ce6d0b56478d8b428bf6"

    static func make(provider: AgentProviderKind, installation: ProviderInstallation,
                     snapshot: ProviderReleaseSnapshot, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     run: Run = { try await ProviderMaintenanceRunner.run($0) }) async throws -> ProviderMaintenancePlan {
        guard let path = installation.path,
              let fingerprint = ProviderBinaryFingerprint.read(path), fingerprint == snapshot.fingerprint,
              let previous = ProviderReleaseVersion(snapshot.installedVersion), !previous.isPrerelease,
              let target = ProviderReleaseVersion(snapshot.availableVersion), !target.isPrerelease else {
            throw ProviderMutationError.changed
        }
        var env = ProviderSetupEnvironment.make(provider: provider)
        env["HOME"] = home.path
        env["PATH"] = (path as NSString).deletingLastPathComponent + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        let cwd = FileManager.default.temporaryDirectory
        func probe(_ executable: String, _ arguments: [String]) async throws -> String {
            let result = try await run(.init(executable: executable, arguments: arguments, environment: env, directory: cwd, timeout: 15, sanitizeOutput: false))
            guard result.exitCode == 0, !result.timedOut else {
                throw ProviderMutationError.unsupported("Could not verify the package manager. Use the official update instructions.")
            }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func executable(_ name: String) -> String? {
            (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        if installation.hint == .npm {
            guard provider == .codex else {
                throw ProviderMutationError.unsupported("Claude Code manages its own npm updates and version policy. Use its official update command for this installation.")
            }
            guard let root = ProviderUsageCoordinator.packageRoot(path), root.contains("/lib/node_modules/"),
                  let npm = executable("npm"), let node = executable("node"),
                  let npmFingerprint = ProviderBinaryFingerprint.read(npm),
                  let nodeFingerprint = ProviderBinaryFingerprint.read(node) else {
                throw ProviderMutationError.unsupported("Could not identify the npm and Node installation used by this executable.")
            }
            let package = provider == .codex ? "@openai/codex" : "@anthropic-ai/claude-code"
            let packageRoot = URL(fileURLWithPath: root)
            let prefix = packageRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
            let metadata = try json(at: packageRoot.appendingPathComponent("package.json"))
            guard metadata["name"] as? String == package,
                  metadata["version"] as? String == snapshot.installedVersion,
                  let bins = metadata["bin"] as? [String: String], let bin = bins[provider.setupBinary],
                  !bin.hasPrefix("/"), !bin.split(separator: "/").contains(".."),
                  packageRoot.appendingPathComponent(bin).resolvingSymlinksInPath().path == fingerprint.target,
                  URL(fileURLWithPath: path).standardizedFileURL.path == prefix + "/bin/" + provider.setupBinary,
                  FileManager.default.isWritableFile(atPath: root), FileManager.default.isWritableFile(atPath: prefix + "/bin") else {
                throw ProviderMutationError.unsupported("The npm package does not own this executable, or its prefix is not writable. Use Terminal to update it.")
            }
            let detectedPrefix = try await probe(npm, ["prefix", "--global"])
            let registry = try await probe(npm, ["config", "get", "registry"])
            let scope = try await probe(npm, ["config", "get", String(package.split(separator: "/")[0]) + ":registry"])
            guard URL(fileURLWithPath: detectedPrefix).standardizedFileURL.path == prefix,
                  registry == "https://registry.npmjs.org/",
                  scope == "undefined" || scope == "null" || scope == registry else {
                throw ProviderMutationError.unsupported("This installation uses a different npm prefix or registry. Rubien will not change that policy; update it through Terminal.")
            }
            // Invoke the verified JS manager with the exact Node runtime, so a PATH
            // change cannot select a different interpreter halfway through an update.
            guard npmFingerprint.target.hasSuffix("/npm/bin/npm-cli.js") else {
                throw ProviderMutationError.unsupported("This npm wrapper is not supported for in-app updates.")
            }
            let args = [npmFingerprint.target, "install", "--global", "--prefix", prefix,
                "--registry=https://registry.npmjs.org/", "--no-audit", "--no-fund", package + "@" + target.rawValue]
            return .init(provider: provider, method: .npm, launcher: path, root: root,
                fingerprint: fingerprint, executable: node, executableFingerprint: nodeFingerprint,
                packageManager: npm, packageManagerFingerprint: npmFingerprint, previousVersion: previous.rawValue,
                targetVersion: target.rawValue, arguments: args, environment: env)
        }
        if installation.hint == .native {
            if provider == .claude {
                for key in ["DISABLE_UPDATES", "DISABLE_AUTOUPDATER"] {
                    env[key] = ProcessInfo.processInfo.environment[key]
                }
                if let disabled = env["DISABLE_UPDATES"], ["1", "true", "yes"].contains(disabled.lowercased()) {
                    throw ProviderMutationError.unsupported("Claude Code updates are disabled by your environment policy.")
                }
            }
            let launcher = home.appendingPathComponent(".local/bin/" + provider.setupBinary).path
            guard path == launcher else {
                throw ProviderMutationError.unsupported("This is a custom native launcher. Use the provider’s update instructions.")
            }
            let root = home.appendingPathComponent(provider == .codex ? ".codex/packages/standalone" : ".local/share/claude").path
            guard fingerprint.target.hasPrefix(root + "/"), FileManager.default.isWritableFile(atPath: root) else {
                throw ProviderMutationError.unsupported("The native installation owner could not be verified.")
            }
            if provider == .codex {
                let current = URL(fileURLWithPath: root + "/current").resolvingSymlinksInPath().path
                let policyURL = URL(fileURLWithPath: root + "/auto-update-version")
                guard current.hasPrefix(root + "/releases/"), fingerprint.target.hasPrefix(current + "/"),
                      let policy = try? String(contentsOf: policyURL, encoding: .utf8),
                      policy == (current as NSString).lastPathComponent,
                      (current as NSString).lastPathComponent.hasPrefix(previous.rawValue + "-") else {
                    throw ProviderMutationError.unsupported("Codex follows a pinned or unrecognized native update policy. Use its official instructions.")
                }
                return .init(provider: provider, method: .codexNative, launcher: path, root: root,
                    fingerprint: fingerprint, executable: "/bin/sh", executableFingerprint: ProviderBinaryFingerprint.read("/bin/sh")!,
                    packageManager: nil, packageManagerFingerprint: nil, previousVersion: previous.rawValue,
                    targetVersion: target.rawValue, arguments: ["<downloaded official installer>"], environment: env)
            }
            guard fingerprint.target == root + "/versions/" + previous.rawValue else { throw ProviderMutationError.changed }
            // Claude's updater reads its own channel, pin and administrator policy.
            // Do not pass a channel/version override or duplicate its automatic loop.
            return .init(provider: provider, method: .claudeNative, launcher: path, root: root,
                fingerprint: fingerprint, executable: path, executableFingerprint: fingerprint,
                packageManager: nil, packageManagerFingerprint: nil, previousVersion: previous.rawValue,
                targetVersion: target.rawValue, arguments: ["update"], environment: env)
        }
        throw ProviderMutationError.unsupported("This installation needs its package manager’s update instructions. Rubien cannot yet verify a version-specific update that preserves its pins.")
    }
    static func json(at url: URL) throws -> [String: Any] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue < 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ProviderMutationError.changed
        }
        return value
    }
}
#endif
