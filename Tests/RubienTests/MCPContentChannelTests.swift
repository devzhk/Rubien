#if os(macOS)
import XCTest
@testable import Rubien

/// The native MCP library channel and its wiring into the Claude
/// argv. Pure/value-level — nothing is spawned.
final class MCPContentChannelTests: XCTestCase {

    private func makeChannel() -> MCPContentChannel {
        MCPContentChannel(
            cliURL: URL(fileURLWithPath: "/Applications/Rubien.app/Contents/Helpers/rubien-cli"),
            libraryRoot: URL(fileURLWithPath: "/Users/x/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien")
        )
    }

    // MARK: config JSON

    func testConfigJSONShapeMirrorsClaudeMCPConfig() {
        let channel = makeChannel()
        let json = channel.configJSON
        let servers = try? XCTUnwrap(json["mcpServers"] as? [String: Any])
        let rubien = servers?["rubien"] as? [String: Any]
        XCTAssertEqual(rubien?["command"] as? String, channel.cliURL.path)
        XCTAssertEqual(rubien?["args"] as? [String], ["mcp"])
        let env = rubien?["env"] as? [String: String]
        XCTAssertEqual(env?["RUBIEN_LIBRARY_ROOT"], channel.libraryRoot.path)
    }

    func testConfigArgumentIsSingleLineAndRoundTrips() throws {
        let channel = makeChannel()
        let arg = try XCTUnwrap(channel.configArgument())
        // Single line — claude reads `--mcp-config` as one argv element.
        XCTAssertFalse(arg.contains("\n"))
        // Parses back to the same structure.
        let parsed = try JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: Any]
        let rubien = (parsed?["mcpServers"] as? [String: Any])?["rubien"] as? [String: Any]
        XCTAssertEqual(rubien?["command"] as? String, channel.cliURL.path)
        XCTAssertEqual(rubien?["args"] as? [String], ["mcp"])
    }

    // MARK: argv injection

    func testArgumentsInjectMCPFlagsWhenConfigPresent() {
        let request = AgentTurnRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            resumeSessionID: nil, prompt: "hi", seed: nil,
            webAccess: true, codexSandbox: .readOnly, modelOverride: nil)
        let config = makeChannel().configArgument()!
        let args = ClaudeCLIInvocation.arguments(for: request, mcpConfig: config)

        // The flags are present, in order, and adjacent (value follows the flag).
        let idx = try? XCTUnwrap(args.firstIndex(of: "--mcp-config"))
        XCTAssertNotNil(idx)
        if let idx {
            XCTAssertEqual(args[idx + 1], config)
        }
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        // Coexists with the mandatory config-isolation flag.
        XCTAssertTrue(args.contains("--setting-sources"))
    }

    func testArgumentsOmitMCPFlagsWhenConfigNilOrEmpty() {
        let request = AgentTurnRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            resumeSessionID: nil, prompt: "hi", seed: nil,
            webAccess: true, codexSandbox: .readOnly, modelOverride: nil)
        for config in [String?.none, ""] {
            let args = ClaudeCLIInvocation.arguments(for: request, mcpConfig: config)
            XCTAssertFalse(args.contains("--mcp-config"), "config=\(String(describing: config))")
            XCTAssertFalse(args.contains("--strict-mcp-config"), "config=\(String(describing: config))")
        }
    }

    func testUserToolsOptInKeepsRubienConfigButDropsClaudeIsolationFlags() throws {
        let request = AgentTurnRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"),
            prompt: "hi", loadUserTools: true)
        let config = try XCTUnwrap(makeChannel().configArgument())

        let args = ClaudeCLIInvocation.arguments(for: request, mcpConfig: config)

        let configIndex = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
        XCTAssertEqual(args[configIndex + 1], config,
                       "Rubien remains available alongside the user's tools")
        XCTAssertFalse(args.contains("--strict-mcp-config"),
                       "ambient user MCP servers must be allowed in the opted-in posture")
        XCTAssertFalse(args.contains("--setting-sources"),
                       "Claude's normal user/project/local settings and plugins must load")
        let approvalIndex = try XCTUnwrap(args.firstIndex(of: "--permission-prompt-tool"))
        XCTAssertEqual(args[approvalIndex + 1], "stdio",
                       "Rubien's approval transport remains active")
    }

    // MARK: bundled-cli resolution

    func testResolveBundledCLIPrefersBundleHelper() throws {
        // A fake app bundle carrying an executable Contents/Helpers/rubien-cli.
        let appURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Rubien-\(UUID().uuidString).app", isDirectory: true)
        let helper = appURL.appendingPathComponent("Contents/Helpers/rubien-cli")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: appURL) }

        // Even though a cwd fallback (.build/debug/rubien-cli) may also exist, the
        // bundle helper is first in precedence and must win.
        let resolved = MCPContentChannel.resolveBundledCLI(bundleURL: appURL)
        XCTAssertEqual(resolved?.path, helper.path)
    }

    func testResolveBundledIsNilWhenNoCandidateIsExecutable() {
        // When nothing on the candidate list is executable, resolution is nil (the
        // caller then runs without the content channel). A FileManager that reports
        // nothing executable exercises this without mutating the real cwd — the
        // repo's own .build/debug/rubien-cli must not accidentally satisfy it.
        let anyBundle = URL(fileURLWithPath: "/nonexistent/Rubien.app")
        XCTAssertNil(MCPContentChannel.resolveBundledCLI(
            bundleURL: anyBundle, fileManager: NoExecutablesFileManager()))
    }
}

/// A FileManager that answers "not executable" for every path, so the resolver's
/// no-candidate branch can be tested deterministically regardless of the real cwd.
private final class NoExecutablesFileManager: FileManager {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}
#endif
