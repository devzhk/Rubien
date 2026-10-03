#if os(macOS)
import XCTest
import Darwin
@testable import Rubien

/// Explicit opt-in only: drives the setup model's real install flow in temporary homes.
/// Ordinary test runs skip this class and never download or install providers.
final class ProviderInstallerLiveTests: XCTestCase {
    @MainActor
    func testReviewedOfficialInstallers() async throws {
        guard let path = ProcessInfo.processInfo.environment["RUBIEN_PROVIDER_LIVE_TEST_ROOT"] else {
            throw XCTSkip("Requires an explicitly prepared live-installer test directory")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/build/ProviderInstallValidation/live-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("working-paths-before.json").path) else {
            throw XCTSkip("Live tests require isolated artifacts and a baseline snapshot")
        }
        let hashes: [AgentProviderKind: String] = [
            .codex: "150e3cf675682efeaac115aa3747add3f27887896d04ce6d0b56478d8b428bf6",
            .claude: "3a68d3406cf674e17bed1733a4dcf37805e2e47d87417700007d7e1aa766a944",
        ]
        let runRoot = root.appendingPathComponent("model-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        print("LIVE evidence: \(runRoot.path)")
        for provider in [AgentProviderKind.codex, .claude] {
            let bootstrap = root.appendingPathComponent("\(provider.rawValue)-bootstrap")
            let plan = ProviderInstallerPlan(provider: provider, directory: bootstrap)
            let reviewedHash = try XCTUnwrap(hashes[provider])
            let inspectedHash = try plan.validateDownload()
            XCTAssertEqual(inspectedHash, reviewedHash, "Reinspect changed scripts before running them")
            guard inspectedHash == reviewedHash else { return }
            let home = runRoot.appendingPathComponent("\(provider.rawValue)-home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let temp = home.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
            var scopedEnvironment = ProviderSetupEnvironment.make(provider: provider)
            scopedEnvironment["HOME"] = home.path
            scopedEnvironment["TMPDIR"] = temp.path
            scopedEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            let environment = scopedEnvironment
            let store = ProviderSetupStore(root: home.appendingPathComponent("setup-state"))
            let binary = home.appendingPathComponent(".local/bin/\(provider.setupBinary)")
            let model = ProviderSetupModel(provider: provider, store: store, home: home,
                run: { request in
                    guard request.environment["HOME"] == home.path else {
                        throw ProviderSetupError.command("Live test refused a command outside its temporary home")
                    }
                    if request.executable == provider.installerShell {
                        let downloaded = ProviderInstallerPlan(provider: provider, directory: request.directory)
                        // Keep the model's real download/validation; add only the live-test
                        // approval gate immediately before executing vendor script bytes.
                        guard try downloaded.validateDownload() == reviewedHash else {
                            throw ProviderSetupError.command("Official script changed. Reinspect it and update the reviewed hash before rerunning.")
                        }
                    }
                    return try await ProviderMaintenanceRunner.run(request)
                }, environment: { _ in environment }, discover: { provider, _ in
                    // Scope absence checks to this home; the real account deliberately
                    // already has both providers. Host login-shell discovery is not tested.
                    ProviderInstallationDetector.inspect(provider: provider, override: nil,
                        candidates: [binary.path], shellPath: nil, shellSucceeded: true)
                }, probe: { _, _ in
                    // Refresh uses real version/auth commands without the shared app-server
                    // registry or the user's library. This is not a Rubien chat/UI test.
                    do {
                        let result = try await ProviderMaintenanceRunner.run(executable: binary.path, arguments: ["--version"],
                            environment: environment, directory: home, timeout: 20)
                        guard result.exitCode == 0, !result.timedOut,
                              let version = ProviderSetupModel.version(from: result.output) else {
                            return .notFound(reason: "Live version probe failed")
                        }
                        let auth = try await ProviderMaintenanceRunner.run(executable: binary.path,
                            arguments: provider == .codex ? ["login", "status"] : ["auth", "status"],
                            environment: environment, directory: home, timeout: 20, retainOutput: false)
                        return AgentAvailability(isInstalled: true, isAuthenticated: auth.exitCode == 0 && !auth.timedOut,
                            version: version, resolvedPath: binary.path, unavailableReason: nil)
                    } catch { return .notFound(reason: "Live availability probe failed") }
                })
            await model.refresh()
            XCTAssertTrue(model.canInstall)
            print("LIVE \(provider.rawValue): model Install with real download, verification, and receipt")
            model.install()
            let deadline = Date().addingTimeInterval(18 * 60)
            while model.activity != nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard model.activity == nil else {
                XCTFail("Live setup model did not finish within the bounded test deadline")
                return
            }
            try model.diagnostics.write(to: runRoot.appendingPathComponent("\(provider.rawValue)-install.log"), atomically: true, encoding: .utf8)
            let record = try XCTUnwrap(store.read(provider: provider))
            XCTAssertTrue(record.finished)
            XCTAssertTrue(record.succeeded, model.message ?? record.detail ?? "Install failed")
            guard record.succeeded else { return }
            XCTAssertEqual(record.scriptHash, reviewedHash)
            XCTAssertEqual(record.path, binary.path)
            XCTAssertTrue(model.availability?.isInstalled == true)
            let receiptData = try Data(contentsOf: store.root.appendingPathComponent("\(provider.rawValue)-receipt.json"))
            let receipt = try JSONDecoder().decode(ProviderSetupRecord.self, from: receiptData)
            XCTAssertEqual(receipt, record)
            try receiptData.write(to: runRoot.appendingPathComponent("\(provider.rawValue)-receipt.json"))
            try assertLockReleased(store: store, provider: provider)

            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
            let fingerprint = try XCTUnwrap(ProviderBinaryFingerprint.read(binary.path))
            let expectedRoot = home.appendingPathComponent(provider == .codex ? ".codex/packages/standalone" : ".local/share/claude/versions")
            XCTAssertTrue(fingerprint.target.hasPrefix(expectedRoot.path + "/"), fingerprint.target)
            XCTAssertEqual(record.fingerprint, fingerprint)
            XCTAssertEqual(record.nativeRoot, expectedRoot.path)
            let version = try await ProviderMaintenanceRunner.run(executable: binary.path, arguments: ["--version"],
                environment: environment, directory: home, timeout: 20)
            XCTAssertEqual(version.exitCode, 0)
            print("LIVE \(provider.rawValue): verified \(version.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            try version.output.write(to: runRoot.appendingPathComponent("\(provider.rawValue)-version.txt"), atomically: true, encoding: .utf8)

            // Exercise the official login process without retaining authorization output.
            // Authentication is cancelled; this does not validate a completed browser login.
            for mode in ["timeout", "cancel"] {
                var loginLock: ProviderSetupLock? = try XCTUnwrap(store.acquire(provider: provider, action: .login))
                let descriptor = loginLock!.descriptor
                let loginEnvironment = environment
                let login = Task {
                    try await ProviderMaintenanceRunner.run(executable: binary.path, arguments: provider.loginArguments,
                        environment: loginEnvironment, directory: home, timeout: mode == "timeout" ? 5 : 60,
                        retainOutput: false, inheritedLock: descriptor)
                }
                if mode == "cancel" {
                    try await Task.sleep(for: .seconds(3))
                    login.cancel()
                }
                do {
                    let result = try await login.value
                    print("LIVE \(provider.rawValue): login \(mode), exit=\(String(describing: result.exitCode)), timedOut=\(result.timedOut)")
                    XCTAssertTrue(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if mode == "timeout" { XCTAssertTrue(result.timedOut, "Login exited before the timeout; inspect provider behavior") }
                    else { XCTFail("Login should remain active until cancelled") }
                } catch is CancellationError {
                    XCTAssertEqual(mode, "cancel")
                    print("LIVE \(provider.rawValue): login cancellation completed")
                }
                withExtendedLifetime(loginLock) {}
                loginLock = nil
                try assertLockReleased(store: store, provider: provider, action: .login)
            }
        }
    }

    private func assertLockReleased(store: ProviderSetupStore, provider: AgentProviderKind,
                                    action: ProviderSetupAction = .install) throws {
        let next = try store.acquire(provider: provider, action: action)
        XCTAssertNotNil(next, "A descendant still holds the \(provider.rawValue) \(action.rawValue) lock")
        withExtendedLifetime(next) {}
        print("LIVE \(provider.rawValue): \(action.rawValue) lock released")
    }
}
#endif
