#if os(macOS)
import Foundation
import OSLog
import RubienCore

private let browserHostInstallerLog = Logger(
    subsystem: "Rubien",
    category: "BrowserExtensionHostInstaller"
)

enum BrowserExtensionHostInstaller {
    private struct HostManifest: Codable, Equatable {
        let name: String
        let description: String
        let path: String
        let type: String
        let allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case name, description, path, type
            case allowedOrigins = "allowed_origins"
        }
    }

    /// Registers only a real app-bundled helper. A `swift run Rubien` process
    /// has no `Contents/Helpers` payload and remains side-effect free.
    static func registerBundledHostIfAvailable() {
        do {
            guard let installedURL = try install(
                bundleURL: Bundle.main.bundleURL,
                applicationSupportURL: FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            ) else {
                return
            }
            browserHostInstallerLog.notice(
                "Registered Chrome native messaging host at \(installedURL.path, privacy: .public)"
            )
        } catch {
            // Browser clipping is optional and must never prevent Rubien from
            // launching. Chrome surfaces a connection error if registration
            // could not be repaired on this launch.
            browserHostInstallerLog.error(
                "Could not register Chrome native messaging host: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @discardableResult
    static func install(
        bundleURL: URL,
        applicationSupportURL: URL?,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard bundleURL.pathExtension.lowercased() == "app",
              let applicationSupportURL else {
            return nil
        }

        let helperURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("rubien-browser-host", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            return nil
        }

        let manifestDirectory = applicationSupportURL
            .appendingPathComponent("Google", isDirectory: true)
            .appendingPathComponent("Chrome", isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let manifestURL = manifestDirectory
            .appendingPathComponent("\(BrowserClipContract.nativeHostName).json", isDirectory: false)
        let manifest = HostManifest(
            name: BrowserClipContract.nativeHostName,
            description: "Import the current Chrome tab into Rubien",
            path: helperURL.standardizedFileURL.path,
            type: "stdio",
            allowedOrigins: [BrowserClipContract.allowedExtensionOrigin]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)

        if let existing = try? Data(contentsOf: manifestURL), existing == data {
            return manifestURL
        }

        try fileManager.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }
}
#endif
