#if os(macOS)
import XCTest
import Darwin
@testable import Rubien

/// Explicit network/installer opt-in. All package mutations are confined to a
/// fresh directory below build/ProviderUpdateValidation; shared tools are read only.
final class ProviderUpdaterLiveTests: XCTestCase {
    @MainActor
    func testNPMProductionUpdateWaitsForOldServerAndVerifiesNewVersion() async throws {
        guard let value = ProcessInfo.processInfo.environment["RUBIEN_UPDATER_LIVE_ROOT"] else {
            throw XCTSkip("Requires a disposable live-update directory")
        }
        let base = URL(fileURLWithPath: value).standardizedFileURL
        guard base.path.contains("/build/ProviderUpdateValidation/live-"),
              FileManager.default.fileExists(atPath: base.path) else { throw XCTSkip("Unprepared live root") }
        let home = base.appendingPathComponent("run-" + String(UUID().uuidString.prefix(8)).lowercased())
        let prefix = home.appendingPathComponent(".npm-global")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let node = "/usr/local/bin/node"
        let npm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/lib/node_modules/npm/bin/npm-cli.js").path
        guard FileManager.default.isExecutableFile(atPath: node), FileManager.default.fileExists(atPath: npm) else { throw XCTSkip("Expected host Node/npm not found") }
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("bin/node"), withDestinationURL: URL(fileURLWithPath: node))
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("bin/npm"), withDestinationURL: URL(fileURLWithPath: npm))
        try "prefix=\(prefix.path)\nregistry=https://registry.npmjs.org/\ncache=\(home.path)/npm-cache\n".write(to: home.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
        var env = ProviderSetupEnvironment.make(provider: .codex)
        env["HOME"] = home.path
        env["PATH"] = prefix.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        let environment = env
        let install = try await ProviderMaintenanceRunner.run(.init(executable: node,
            arguments: [npm, "install", "--global", "--prefix", prefix.path, "--no-audit", "--no-fund", "@openai/codex@0.153.4"],
            environment: environment, directory: home, timeout: 600))
        XCTAssertEqual(install.exitCode, 0, install.output)
        guard install.exitCode == 0 else { return }
        let launcher = prefix.appendingPathComponent("bin/codex")
        let snapshot = ProviderReleaseSnapshot(installedVersion: "0.153.4", availableVersion: "0.160.0",
            source: .codexNPM, fingerprint: try XCTUnwrap(ProviderBinaryFingerprint.read(launcher.path)), checkedAt: Date())
        let installation = ProviderInstallation(state: .found, path: launcher.path, hint: .npm, detail: nil)
        try await ProviderUsageCoordinator.$storageRoot.withValue(home.appendingPathComponent("usage")) {
            // This separate descriptor proves the actual Node wrapper preserves
            // inherited locks after the parent closes its own reference.
            let inheritedURL = home.appendingPathComponent("inheritance.lock")
            var inherited = try XCTUnwrap(ProviderSetupLock(url: inheritedURL)) as ProviderSetupLock?
            let server = try SpawnedAgentProcess.spawn(executablePath: launcher.path, arguments: ["app-server"],
                environment: environment, workingDirectory: home.path, inheritedLock: inherited!.descriptor)
            inherited = nil
            let out = Task.detached { server.stdoutHandle.readDataToEndOfFile() }
            let err = Task.detached { server.stderrHandle.readDataToEndOfFile() }
            try await Task.sleep(for: .seconds(1))
            XCTAssertNil(try ProviderSetupLock(url: inheritedURL), "Actual Node launch chain lost the inherited lock")
            let model = ProviderUpdateActionModel(provider: .codex, root: home.appendingPathComponent("actions"), home: home, override: { launcher.path }, refreshed: {}, run: { request in
                guard request.environment["HOME"] == home.path else { throw ProviderMutationError.changed }
                if request.arguments.contains("install") {
                    XCTAssertTrue(request.arguments.contains(prefix.path), "Mutation must stay in the temporary prefix")
                }
                return try await ProviderMaintenanceRunner.run(request)
            })
            await model.prepare(installation: installation, snapshot: snapshot)
            XCTAssertTrue(model.canUpdate, model.explanation ?? "no plan")
            if !model.canUpdate {
                server.closeStdin()
                _ = await server.wait()
                _ = await out.value
                _ = await err.value
                return
            }
            model.update()
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(model.canCancel)
            XCTAssertTrue(model.stage?.contains("Waiting") == true, model.stage ?? "no stage")
            server.closeStdin()
            _ = await server.wait()
            _ = await out.value
            _ = await err.value
            let deadline = Date().addingTimeInterval(180)
            while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            XCTAssertFalse(model.isRunning)
            XCTAssertTrue(model.stage?.contains("Updated to 0.160.0") == true, model.stage ?? "no stage")
            try (model.stage ?? "").write(to: base.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            try model.output.write(to: base.appendingPathComponent("updater.log"), atomically: true, encoding: .utf8)
            print("LIVE updater home: \(home.path)")
        }
    }
}
#endif
