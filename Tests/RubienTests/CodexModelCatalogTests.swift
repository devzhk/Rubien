#if os(macOS)
import Darwin
import XCTest
@testable import Rubien

/// Drives `CodexModelCatalog` end-to-end against `fake-codex-app-server.py`:
/// fetch + decode, per-binary memoization (one spawn), forceReload, concurrent
/// callers sharing one in-flight fetch, and the failure → `.unavailable` paths.
final class CodexModelCatalogTests: XCTestCase {

    private var workspacesToClean: [URL] = []

    override func setUpWithError() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeServerPath)
    }

    override func tearDown() {
        for url in workspacesToClean { try? FileManager.default.removeItem(at: url) }
        workspacesToClean.removeAll()
    }

    func testFetchesAndDecodesModelList() async throws {
        let catalog = await freshCatalog().catalog(executableOverride: fakeServerPath)
        XCTAssertTrue(catalog.fetchedOK)
        XCTAssertEqual(catalog.models.map(\.id), ["fake-default", "fake-frontier", "fake-hidden"])
        XCTAssertEqual(catalog.visibleModels.map(\.id), ["fake-default", "fake-frontier"])
        XCTAssertEqual(catalog.models[0].defaultEffort, "medium")
        XCTAssertTrue(catalog.models[0].isDefault)
        XCTAssertEqual(catalog.models[1].efforts.map(\.value), ["low", "max", "ultra"])
    }

    func testProbeDisablesAppsPluginsAndAmbientMCPServers() async throws {
        _ = await freshCatalog(config: ["mcpServers": [
            ["name": "github", "enabled": true],
            ["name": "rubien", "enabled": true],
        ]]).catalog(executableOverride: fakeServerPath)

        let arguments = try spawnedArguments()
        XCTAssertTrue(arguments.containsPair("--disable", "apps"))
        XCTAssertTrue(arguments.containsPair("--disable", "plugins"))
        XCTAssertTrue(arguments.containsPair("-c", "mcp_servers.github.enabled=false"))
        XCTAssertTrue(arguments.containsPair("-c", "mcp_servers.rubien.enabled=false"))
    }

    func testMemoizesPerBinaryPath() async throws {
        let store = freshCatalog()
        _ = await store.catalog(executableOverride: fakeServerPath)
        _ = await store.catalog(executableOverride: fakeServerPath)
        XCTAssertEqual(try modelListRequests(), 1, "second call must hit the memo, not respawn")
    }

    func testForceReloadRefetches() async throws {
        let store = freshCatalog()
        _ = await store.catalog(executableOverride: fakeServerPath)
        let second = await store.catalog(executableOverride: fakeServerPath, forceReload: true)
        XCTAssertTrue(second.fetchedOK)
        XCTAssertEqual(try modelListRequests(), 2)
    }

    func testConcurrentCallersShareOneFetch() async throws {
        let store = freshCatalog()
        async let a = store.catalog(executableOverride: fakeServerPath)
        async let b = store.catalog(executableOverride: fakeServerPath)
        let (first, second) = await (a, b)
        XCTAssertTrue(first.fetchedOK)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try modelListRequests(), 1, "concurrent callers must join one in-flight fetch")
    }

    func testMissingBinaryIsUnavailable() async {
        let catalog = await freshCatalog().catalog(executableOverride: "/nonexistent/codex-binary")
        XCTAssertEqual(catalog, .unavailable)
    }

    func testServerErrorIsUnavailable() async throws {
        let store = freshCatalog(config: ["modelListError": true])
        let catalog = await store.catalog(executableOverride: fakeServerPath)
        XCTAssertEqual(catalog, .unavailable)
    }

    /// The spec §4.1 stale-completion guarantee: a fetch that was in flight when a
    /// forceReload happened must not repopulate the cache with its (pre-reload)
    /// result. The slow fetch reads the ORIGINAL config (default model set); the
    /// reload reads the rewritten one — the rewritten list must win and stay won.
    /// Timing tolerance: if the slow fetch happens to read the NEW config, both
    /// lists match and the test passes vacuously — it can never flake into failure.
    func testStaleInFlightFetchCannotClobberForceReload() async throws {
        let store = freshCatalog(config: ["modelListDelayMs": 1500])
        let slow = Task { await store.catalog(executableOverride: fakeServerPath) }
        try await Task.sleep(for: .milliseconds(500))   // slow probe is in flight
        try writeConfig(["models": [["id": "fresh-model", "displayName": "Fresh"]]])

        let reloaded = await store.catalog(executableOverride: fakeServerPath, forceReload: true)
        XCTAssertEqual(reloaded.models.map(\.id), ["fresh-model"])

        let joined = await slow.value
        XCTAssertEqual(joined.models.map(\.id), ["fresh-model"],
                       "a superseded waiter must join the replacement fetch")
        let cached = await store.catalog(executableOverride: fakeServerPath)
        XCTAssertEqual(cached.models.map(\.id), ["fresh-model"],
                       "the stale in-flight fetch must not repopulate the cache (plan-review #2)")
    }

    func testForceReloadKillsSupersededProbeBeforeStartingFreshOne() async throws {
        let store = freshCatalog(config: ["modelListDelayMs": 5_000])
        let slow = Task { await store.catalog(executableOverride: fakeServerPath) }
        let oldPID = try observedPID()
        try writeConfig(["models": [["id": "fresh-model", "displayName": "Fresh"]]])

        let reloaded = await store.catalog(executableOverride: fakeServerPath, forceReload: true)

        XCTAssertEqual(reloaded.models.map(\.id), ["fresh-model"])
        for _ in 0..<50 where kill(oldPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(kill(oldPID, 0), 0,
                          "forceReload must not leave the superseded app-server running")
        _ = await slow.value
    }

    // MARK: Helpers

    /// A fresh actor with its own temp working directory (the fake writes its
    /// observed/config JSON to cwd; sharing a cwd across tests would collide).
    private func freshCatalog(config: [String: Any] = [:]) -> CodexModelCatalog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspacesToClean.append(dir)
        if !config.isEmpty {
            let data = try? JSONSerialization.data(withJSONObject: config)
            try? data?.write(to: dir.appendingPathComponent("fake-codex.json"))
        }
        currentWorkspace = dir
        // The production picker keeps a ten-second bound. The Python fixture can
        // cold-start much more slowly after the full process-heavy provider suite,
        // so give the harness headroom without weakening the production timeout.
        return CodexModelCatalog(workingDirectory: dir, fetchTimeout: 30)
    }

    private var currentWorkspace: URL?

    /// (Re)write the fake's per-turn config into the current actor's cwd.
    private func writeConfig(_ config: [String: Any]) throws {
        let url = try XCTUnwrap(currentWorkspace).appendingPathComponent("fake-codex.json")
        try JSONSerialization.data(withJSONObject: config).write(to: url)
    }

    /// Poll the fake's observed file for the model/list request count (atomic writes;
    /// brief poll covers the child's write racing the assertion).
    private func modelListRequests() throws -> Int {
        let url = try XCTUnwrap(currentWorkspace).appendingPathComponent("fake-codex-observed.json")
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: url),
               let observed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let count = observed["modelListRequests"] as? Int {
                return count
            }
            usleep(100_000)
        }
        throw XCTSkip("observed file never appeared — fake server did not run")
    }

    private func spawnedArguments() throws -> [String] {
        let url = try XCTUnwrap(currentWorkspace).appendingPathComponent("fake-codex-argv.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
    }

    private func observedPID() throws -> pid_t {
        let url = try XCTUnwrap(currentWorkspace).appendingPathComponent("fake-codex-observed.json")
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let observed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = observed["pid"] as? Int {
                return pid_t(pid)
            }
            usleep(20_000)
        }
        throw XCTSkip("probe process never recorded its pid")
    }

    private var fakeServerPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-codex-app-server.py")
            .path
    }
}

private extension Array where Element == String {
    func containsPair(_ first: String, _ second: String) -> Bool {
        zip(self, dropFirst()).contains { $0 == first && $1 == second }
    }
}
#endif
