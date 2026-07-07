import Foundation
import RubienCore

/// The read-only MCP content channel the Assistant attaches to a Claude turn: the
/// already-bundled `rubien-cli` run as an MCP server (`mcp --read-only`) over
/// `--mcp-config`, pointed at the app's live library. This is how the agent reads
/// the document under discussion (design §D4/§D6, Phase 2b).
///
/// Nothing new is bundled — `rubien-cli` already ships at `Contents/Helpers/` — and
/// there is no Node/runtime dependency: the native `rubien-cli mcp` server *is* the
/// content channel.
struct MCPContentChannel: Sendable, Equatable {
    /// The bundled `rubien-cli` to run as `mcp --read-only`.
    let cliURL: URL
    /// The app's resolved library root, passed to the server as
    /// `RUBIEN_LIBRARY_ROOT` so it reads exactly the library the app is using —
    /// correct even for an unsigned dev CLI or a `RUBIEN_LIBRARY_ROOT` override
    /// (which would otherwise resolve a different library.sqlite).
    let libraryRoot: URL

    /// The MCP server registration key. Canonical — every site that recognizes
    /// "our" server derives from this one name: claude's `mcp__<server>__<tool>`
    /// prefix (`ReferenceAttribution.claudeToolPrefix`, the silent-read-tool gate)
    /// and codex's `mcpToolCall.server` match in the History attribution scan.
    /// A rename here renames them all; a hardcoded copy would silently break.
    static let serverName = "rubien"

    /// The `--mcp-config` payload claude reads to spawn our server. `--mcp-config`
    /// accepts a JSON *string* (verified against claude 2.1.201: "Load MCP servers
    /// from JSON files or strings"), so this is passed inline — no temp file to
    /// write, track, or clean up.
    var configJSON: [String: Any] {
        [
            "mcpServers": [
                Self.serverName: [
                    "command": cliURL.path,
                    "args": ["mcp", "--read-only"],
                    "env": ["RUBIEN_LIBRARY_ROOT": libraryRoot.path],
                ],
            ],
        ]
    }

    /// The inline `--mcp-config` argument value: compact, single-line JSON.
    /// Returns nil only if serialization somehow fails (unreachable for this
    /// fixed, string-only shape).
    func configArgument() -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: configJSON, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Resolution

    /// Resolve the bundled channel for production use: the app's own `rubien-cli`
    /// helper + the live library root. Returns nil when the helper can't be found
    /// (e.g. `swift run Rubien` with no built app bundle) — the caller then runs
    /// the turn without the content channel and surfaces that in the UI.
    static func resolveBundled(libraryRoot: URL = AppDatabase.libraryRootURL) -> MCPContentChannel? {
        guard let cli = resolveBundledCLI() else { return nil }
        return MCPContentChannel(cliURL: cli, libraryRoot: libraryRoot)
    }

    /// Locate the bundled `rubien-cli` helper.
    ///
    /// In a shipped app (`Bundle.main.bundleURL` is an `.app`) this is ONLY the
    /// bundle's `Contents/Helpers/rubien-cli` — never a cwd-relative fallback,
    /// which in production could execute an unrelated binary sitting near the
    /// process working directory. Cwd fallbacks apply only to a dev run
    /// (`swift run Rubien`, whose bundle is not an `.app`), and there the fresh
    /// SPM debug binary is preferred over a possibly-stale locally-built
    /// `build/Rubien.app`.
    static func resolveBundledCLI(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL? {
        let bundled = bundleURL.appendingPathComponent("Contents/Helpers/rubien-cli")
        if bundleURL.pathExtension == "app" {
            return fileManager.isExecutableFile(atPath: bundled.path) ? bundled : nil
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates: [URL] = [
            bundled,
            cwd.appendingPathComponent(".build/debug/rubien-cli"),
            cwd.appendingPathComponent("build/Rubien.app/Contents/Helpers/rubien-cli"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
