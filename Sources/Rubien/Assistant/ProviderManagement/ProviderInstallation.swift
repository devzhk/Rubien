#if os(macOS)
import Foundation
import Darwin

/// Shared setup metadata; the terminal command remains the vendor's published command.
extension AgentProviderKind {
    var setupName: String { self == .codex ? "Codex" : "Claude Code" }
    var setupBinary: String { self == .codex ? "codex" : "claude" }
    var installerURL: URL {
        URL(string: self == .codex ? "https://chatgpt.com/codex/install.sh" : "https://claude.ai/install.sh")!
    }
    var setupDocumentationURL: URL {
        URL(string: self == .codex ? "https://learn.chatgpt.com/docs/codex/cli" : "https://code.claude.com/docs/en/overview")!
    }
    var installerShell: String { self == .codex ? "/bin/sh" : "/bin/bash" }
    var officialInstallCommand: String {
        "curl -fsSL \(installerURL.absoluteString) | \(self == .codex ? "sh" : "bash")"
    }
    var installProcedure: String {
        ProviderInstallerPlan(provider: self, directory: URL(fileURLWithPath: "/<temporary directory>"))
            .displayedProcedure
    }

    var loginArguments: [String] { self == .codex ? ["login"] : ["auth", "login"] }
    func setupCandidates(home: URL) -> [String] {
        let local = home.appendingPathComponent(".local/bin/\(setupBinary)").path
        let npm = home.appendingPathComponent(".npm-global/bin/\(setupBinary)").path
        let brew = ["/opt/homebrew/bin/\(setupBinary)", "/usr/local/bin/\(setupBinary)"]
        return self == .codex ? [npm] + brew + [local] : [local] + brew + [npm]
    }
}

struct ProviderBinaryFingerprint: Equatable, Sendable, Codable {
    let target: String
    let inode: UInt64
    let size: UInt64
    let modified: Date

    static func read(_ path: String) -> Self? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: target),
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let size = attrs[.size] as? NSNumber,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Self(target: target, inode: inode.uint64Value, size: size.uint64Value, modified: date)
    }
}

struct ProviderInstallation: Equatable, Sendable {
    enum State: Equatable, Sendable { case missing, selectedPathMissing, found, inaccessible }
    let state: State
    let path: String?
    enum MethodHint: String, Sendable {
        case native = "Likely native"
        case homebrew = "Likely Homebrew"
        case npm = "Likely npm"
        case unknown = "Installation method unknown"
        case selectedPath = "Selected path"
        case notInstalled = "Not installed"
        case inaccessible = "Unknown"
    }
    let hint: MethodHint
    let detail: String?
    var canInstall: Bool { state == .missing }

    static func hint(for path: String) -> MethodHint {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if target.contains("/Cellar/") || target.contains("/Caskroom/") { return .homebrew }
        if target.contains("/node_modules/") { return .npm }
        if target.contains("/.codex/packages/standalone/") || target.contains("/.local/share/claude/versions/") {
            return .native
        }
        return .unknown
    }
}

enum ProviderInstallationDetector {
    /// Discovery is conservative: even a broken symlink blocks a second native install.
    static func inspect(provider: AgentProviderKind, override: String?, candidates: [String],
                        shellPath: String?, shellSucceeded: Bool) -> ProviderInstallation {
        let selected = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOverride = !(selected?.isEmpty ?? true)
        let paths = hasOverride ? [selected!] : candidates + [shellPath].compactMap { $0 }
        var present: [String] = []
        for path in paths {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path)
                present.append(path)
            } catch {
                let e = error as NSError
                if e.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code) {
                    return ProviderInstallation(state: .inaccessible, path: path, hint: .inaccessible,
                                                detail: "Rubien could not inspect this location. Choose an executable or check its permissions.")
                }
            }
        }
        if let path = present.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? present.first {
            return ProviderInstallation(state: .found, path: path, hint: ProviderInstallation.hint(for: path), detail: nil)
        }
        if hasOverride {
            return ProviderInstallation(state: .selectedPathMissing, path: selected, hint: .selectedPath,
                                        detail: "The selected executable cannot be found. Use automatic discovery or choose another file.")
        }
        guard shellSucceeded else {
            return ProviderInstallation(state: .inaccessible, path: nil, hint: .inaccessible,
                                        detail: "Automatic discovery could not finish. Recheck or choose your existing executable before installing.")
        }
        return ProviderInstallation(state: .missing, path: nil, hint: .notInstalled, detail: nil)
    }

    static func discover(provider: AgentProviderKind, override: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         respectPendingUpdates: Bool = true) async -> ProviderInstallation {
        if respectPendingUpdates, let pending = ProviderUsageCoordinator.pendingPath(provider: provider, override: override, home: home) {
            return ProviderInstallation(state: .found, path: pending, hint: .npm,
                detail: "An update is in progress. The installation will be rechecked when it finishes.")
        }
        let candidates = provider.setupCandidates(home: home)
        if let override, !override.isEmpty {
            return inspect(provider: provider, override: override, candidates: candidates, shellPath: nil, shellSucceeded: true)
        }
        let known = inspect(provider: provider, override: nil, candidates: candidates, shellPath: nil, shellSucceeded: true)
        guard known.canInstall else { return known }
        let lookup = await ProviderShellLookup.discover(binaryName: provider.setupBinary,
            shell: ProviderSetupEnvironment.loginShell(), environment: ProviderSetupEnvironment.make(provider: provider))
        return inspect(provider: provider, override: nil, candidates: candidates,
                       shellPath: lookup.path, shellSucceeded: lookup.completed)
    }
}

/// Frames command output so profile banners, ssh-agent output, and logout hooks
/// cannot be mistaken for an executable path or for a failed lookup.
struct ProviderShellLookup: Sendable {
    let marker: String
    init(marker: String = "RUBIEN_LOOKUP_" + UUID().uuidString) { self.marker = marker }
    struct Result: Equatable, Sendable {
        var path: String?
        var completed: Bool
    }
    func command(binaryName: String) -> String {
        let script = "if rubien_lookup_path=$(command -v " + ProviderInstallerPlan.quote(binaryName) + " 2>/dev/null); then "
        + "printf '\n" + marker + "\n0\n%s\n" + marker + "_END\n' \"$rubien_lookup_path\"; else "
        + "printf '\n" + marker + "\n1\n\n" + marker + "_END\n'; fi"
        // The login shell supplies PATH; sh interprets the framed lookup even
        // when the user's shell does not understand POSIX conditionals.
        return "exec /bin/sh -c " + ProviderInstallerPlan.quote(script)
    }
    func parse(_ output: String) -> Result {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: marker), lines.count > start + 3,
              lines[start + 3] == marker + "_END" else { return Result(completed: false) }
        if lines[start + 1] == "1", lines[start + 2].isEmpty { return Result(completed: true) }
        let path = lines[start + 2]
        guard lines[start + 1] == "0", path.hasPrefix("/"), !path.contains("\r"), !path.contains("\0") else {
            return Result(completed: false)
        }
        return Result(path: path, completed: true)
    }
    static func discover(binaryName: String, shell: String, environment: [String: String], timeout: TimeInterval = 15) async -> Result {
        let lookup = Self()
        // The synchronous probe has a hard pipe deadline even when a profile
        // starts a daemon. Keep that wait off the main and broker actors.
        let result = await Task.detached {
            AgentBinaryProbe.runCommand(executablePath: shell,
                arguments: ["-l", "-c", lookup.command(binaryName: binaryName)],
                environment: environment, timeout: timeout, captureStderr: false)
        }.value
        guard let result, !result.timedOut, result.exitCode == 0 else { return Result(completed: false) }
        return lookup.parse(result.stdout)
    }
}

enum ProviderSetupEnvironment {
    static func loginShell() -> String {
        if let raw = getpwuid(getuid())?.pointee.pw_shell {
            let shell = String(cString: raw)
            if shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    static func make(provider: AgentProviderKind, host: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                    "https_proxy", "http_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE"] {
            env[key] = host[key]
        }
        env["HOME"] = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["SHELL"] = loginShell()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        if provider == .codex { env["CODEX_NON_INTERACTIVE"] = "1" }
        return env
    }
}
#endif
