import AppKit
import Foundation

/// Installs / uninstalls the `rubien-cli` CLI tool to /usr/local/bin.
///
/// The CLI binary is expected to live alongside the main app executable
/// inside the app bundle's `MacOS/` directory (or as a bundled resource).
enum CLIInstaller {
    static let binaryName = "rubien-cli"

    static var installURL: URL {
        URL(fileURLWithPath: "/usr/local/bin/\(binaryName)")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installURL.path)
    }

    /// True when the app is running from a SwiftPM dev build (e.g. `swift run Rubien`
    /// produces a binary under `.build/`) rather than a proper `.app` bundle. Used to
    /// suppress the first-launch CLI install prompt during development, since
    /// `/usr/local/bin` isn't writable without admin rights anyway.
    static var isRunningFromDevBuild: Bool {
        guard let execURL = Bundle.main.executableURL else { return false }
        let path = execURL.path
        return path.contains("/.build/") || path.contains("/DerivedData/")
    }

    /// Locate the bundled CLI binary inside the app bundle.
    static var bundledBinaryURL: URL? {
        // 1. Contents/Helpers/rubien-cli (standard location, avoids case-insensitive collision with the app bundle)
        if let bundleURL = Bundle.main.bundleURL as URL? {
            let candidate = bundleURL.appendingPathComponent("Contents/Helpers/\(binaryName)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // 2. Contents/MacOS/rubien-cli
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL.deletingLastPathComponent().appendingPathComponent(binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // 3. As a resource
        if let url = Bundle.main.url(forResource: binaryName, withExtension: nil) {
            return url
        }
        // 4. Development: built product in same directory (swift build)
        if let execURL = Bundle.main.executableURL {
            let buildDir = execURL.deletingLastPathComponent()
            let candidate = buildDir.appendingPathComponent(binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func install() throws {
        guard let source = bundledBinaryURL else {
            throw makeError("rubien-cli binary not found. Make sure the CLI is embedded in the app bundle.")
        }

        let dest = installURL
        let dir = dest.deletingLastPathComponent()

        // Ensure /usr/local/bin exists
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Remove old version if present
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: installURL)
    }

    static func revealInFinder() {
        if isInstalled {
            NSWorkspace.shared.selectFile(installURL.path, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/usr/local/bin"))
        }
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "Rubien.CLIInstaller",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
