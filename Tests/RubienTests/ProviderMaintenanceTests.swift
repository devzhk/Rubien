#if os(macOS)
import XCTest
import Combine
import Darwin
@testable import Rubien

final class ProviderMaintenanceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rubien-maintenance-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    private struct Fixture: Sendable {
        let prefix: URL
        let package: URL
        let launcher: URL
        let installation: ProviderInstallation
        let snapshot: ProviderReleaseSnapshot
        func probe(_ request: ProviderMaintenanceRequest, registry: String = "https://registry.npmjs.org/") -> ProviderCommandResult {
            let output: String
            if request.arguments == ["prefix", "--global"] { output = prefix.path }
            else if request.arguments == ["config", "get", "registry"] { output = registry }
            else { output = "undefined" }
            return .init(exitCode: 0, timedOut: false, output: output, truncated: false)
        }
    }
    private func fixture() throws -> Fixture {
        let package = try write("prefix/lib/node_modules/@openai/codex/bin/codex.js", "#!/bin/sh\nread line\n")
            .deletingLastPathComponent().deletingLastPathComponent()
        _ = try write("prefix/lib/node_modules/@openai/codex/package.json", #"{"name":"@openai/codex","version":"0.153.4","bin":{"codex":"bin/codex.js"}}"#)
        let npm = try write("prefix/lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\nexit 0\n")
        _ = try write("prefix/bin/node", "#!/bin/sh\nexit 0\n")
        let launcher = root.appendingPathComponent("prefix/bin/codex")
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: package.appendingPathComponent("bin/codex.js"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("prefix/bin/npm"), withDestinationURL: npm)
        return Fixture(prefix: root.appendingPathComponent("prefix"), package: package, launcher: launcher,
            installation: .init(state: .found, path: launcher.path, hint: .npm, detail: nil),
            snapshot: .init(installedVersion: "0.153.4", availableVersion: "0.160.0", source: .codexNPM,
                fingerprint: ProviderBinaryFingerprint.read(launcher.path)!, checkedAt: Date()))
    }
    func testNPMPlanKeepsPrefixInterpreterPackageAndExactVersion() async throws {
        let f = try fixture()
        let plan = try await ProviderMaintenancePlanner.make(provider: .codex, installation: f.installation,
            snapshot: f.snapshot, home: root, run: { f.probe($0) })
        XCTAssertEqual(plan.root, f.package.path)
        XCTAssertEqual(plan.executable, f.prefix.appendingPathComponent("bin/node").path)
        XCTAssertEqual(plan.arguments.suffix(1), ["@openai/codex@0.160.0"])
        XCTAssertTrue(plan.arguments.contains(f.prefix.path))
        XCTAssertTrue(plan.allowsAutomaticInstall)
        XCTAssertTrue(plan.unchanged())
        try "changed".write(to: f.launcher, atomically: false, encoding: .utf8)
        XCTAssertFalse(plan.unchanged())
    }
    func testCustomRegistryCannotBecomePublicRegistryUpdate() async throws {
        let f = try fixture()
        do {
            _ = try await ProviderMaintenancePlanner.make(provider: .codex, installation: f.installation,
                snapshot: f.snapshot, home: root, run: { f.probe($0, registry: "https://private.example/") })
            XCTFail("Custom registries must not be overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("registry")) }
    }
    func testWrongPackageBinAndVersionAreRejected() async throws {
        let f = try fixture()
        try #"{"name":"unrelated","version":"0.153.4","bin":{"codex":"bin/codex.js"}}"#
            .write(to: f.package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        do {
            _ = try await ProviderMaintenancePlanner.make(provider: .codex, installation: f.installation,
                snapshot: f.snapshot, home: root, run: { f.probe($0) })
            XCTFail("Wrong owner must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("own")) }
    }
    func testSharedUsageExcludesMutationAndPendingIntentExcludesNewStarts() throws {
        let f = try fixture()
        try ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            let directory = try ProviderUsageCoordinator.directory(f.package.path)
            var first = try XCTUnwrap(ProviderUsageCoordinator.acquireUsage(path: f.launcher.path))
            let second = try XCTUnwrap(ProviderUsageCoordinator.acquireUsage(path: f.launcher.path))
            XCTAssertNil(try ProviderSetupLock(url: directory.appendingPathComponent("usage.lock")))
            let intent = try XCTUnwrap(ProviderSetupLock(url: directory.appendingPathComponent("intent.lock")))
            XCTAssertTrue(ProviderUsageCoordinator.pending(path: f.launcher.path))
            XCTAssertThrowsError(try ProviderUsageCoordinator.acquireUsage(path: f.launcher.path))
            withExtendedLifetime((first, second, intent)) {}
            first = second
        }
    }
    func testTemporaryLauncherRemovalStillBlocksStartsAndDuplicateInstall() async throws {
        let f = try fixture()
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            let dir = try ProviderUsageCoordinator.directory(f.package.path)
            let intent = try XCTUnwrap(ProviderSetupLock(url: dir.appendingPathComponent("intent.lock")))
            try FileManager.default.removeItem(at: f.launcher)
            XCTAssertTrue(ProviderUsageCoordinator.pending(path: f.launcher.path))
            XCTAssertThrowsError(try ProviderUsageCoordinator.acquireUsage(path: f.launcher.path))
            let found = await ProviderInstallationDetector.discover(provider: .codex, override: f.launcher.path, home: root)
            XCTAssertFalse(found.canInstall)
            XCTAssertEqual(found.state, .found)
            withExtendedLifetime(intent) {}
        }
    }

    func testExplicitDescriptorSurvivesExecAndParentReferenceClosing() async throws {
        let url = root.appendingPathComponent("inherit.lock")
        var lease: ProviderSetupLock? = try XCTUnwrap(ProviderSetupLock(url: url))
        let process = try SpawnedAgentProcess.spawn(executablePath: "/bin/sleep", arguments: ["20"],
            environment: ["PATH":"/usr/bin:/bin"], workingDirectory: root.path, inheritedLock: lease!.descriptor)
        lease = nil
        XCTAssertNil(try ProviderSetupLock(url: url), "Child must own lock after the parent reference closes")
        process.signalGroup(SIGKILL)
        _ = await process.wait()
        XCTAssertNotNil(try ProviderSetupLock(url: url))
    }
    func testCancelledTaskStillReapsExitedLeaderAndResidualChildren() async throws {
        let process = try SpawnedAgentProcess.spawn(executablePath: "/bin/sh",
            arguments: ["-c", "/bin/sleep 20 & exit 0"], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: root.path)
        process.closeStdin()
        let observed = await process.observeExit()
        XCTAssertTrue(observed)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await process.reap(timeout: 3)
        }
        let result = await cancelled.value
        XCTAssertNotNil(result, "Cancellation must not abandon the group cleanup before reaping the leader")
        process.signalGroup(SIGKILL)
        _ = await process.wait()
        process.closeOutputHandles()
        XCTAssertNotEqual(kill(process.pid, 0), 0, "No leader zombie may survive the cancelled probe")
    }
    func testSpawnAdmissionAndOwnerCapability() async throws {
        let f = try fixture()
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            let dir = try ProviderUsageCoordinator.directory(f.package.path)
            let intent = try XCTUnwrap(ProviderSetupLock(url: dir.appendingPathComponent("intent.lock")))
            let exclusive = try XCTUnwrap(ProviderSetupLock(url: dir.appendingPathComponent("usage.lock")))
            XCTAssertThrowsError(try SpawnedAgentProcess.spawn(executablePath: f.launcher.path,
                arguments: [], environment: [:], workingDirectory: root.path))
            let owner = ProviderUsageOwner(root: f.package.path, usage: exclusive, intent: intent)
            let process = try SpawnedAgentProcess.spawn(executablePath: f.launcher.path, arguments: [],
                environment: [:], workingDirectory: root.path, maintenanceOwner: owner)
            process.closeStdin()
            _ = await process.wait()
        }
    }
    @MainActor
    func testConsentIsSharedByInstallationAndDefaultsOff() async throws {
        let f = try fixture()
        let store = root.appendingPathComponent("actions")
        let first = ProviderUpdateActionModel(provider: .codex, root: store, home: root, override: { f.launcher.path }, refreshed: {}, run: { f.probe($0) })
        await first.prepare(installation: f.installation, snapshot: f.snapshot)
        XCTAssertFalse(first.policy.enabled)
        first.setAutomatic(true)
        let second = ProviderUpdateActionModel(provider: .codex, root: store, home: root, override: { f.launcher.path }, refreshed: {}, run: { f.probe($0) })
        await second.prepare(installation: f.installation, snapshot: f.snapshot)
        XCTAssertTrue(second.policy.enabled)
        second.setAutomatic(false)
        await first.prepare(installation: f.installation, snapshot: f.snapshot)
        XCTAssertFalse(first.policy.enabled)
    }
    @MainActor
    func testCancelWhileAnotherProcessUsesPackageNeverStartsMutation() async throws {
        let f = try fixture()
        let mutations = LockedBox(0)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"), home: root, override: { f.launcher.path }, refreshed: {}, run: { request in
            if request.arguments.contains("install") { mutations.set(mutations.get() + 1) }
            return f.probe(request)
        })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            let usage = try XCTUnwrap(ProviderUsageCoordinator.acquireUsage(path: f.launcher.path))
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.update()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(model.stage?.contains("Waiting") == true)
            XCTAssertTrue(model.canCancel)
            model.cancel()
            let deadline = Date().addingTimeInterval(2)
            while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(mutations.get(), 0)
            XCTAssertFalse(ProviderUsageCoordinator.pending(path: f.launcher.path))
            withExtendedLifetime(usage) {}
        }
    }
    @MainActor
    func testAutomaticUpdateRequiresConsentAndQuietPeriod() async throws {
        let f = try fixture()
        let mutations = LockedBox(0)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"), home: root, override: { f.launcher.path },
            refreshed: {}, idleSeconds: { 100 }, run: { request in
                if request.executable == "/bin/ps" { return .init(exitCode: 0, timedOut: false, output: "", truncated: false) }
                if request.arguments.contains("install") {
                    mutations.set(mutations.get() + 1)
                    return .init(exitCode: 0, timedOut: false, output: "updated", truncated: false)
                }
                if request.arguments == ["--version"] { return .init(exitCode: 0, timedOut: false, output: "codex-cli 0.160.0", truncated: false) }
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            let now = Date()
            await model.considerAutomaticUpdate(now: now)
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(60))
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(mutations.get(), 0)
            model.setAutomatic(true)
            await model.considerAutomaticUpdate(now: now)
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(29))
            XCTAssertFalse(model.isRunning)
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(31))
            let deadline = Date().addingTimeInterval(2)
            while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(mutations.get(), 1, model.stage ?? "no stage")
        }
    }

    @MainActor
    func testStaleReleaseCannotEnableUpdate() async throws {
        let f = try fixture()
        let model = ProviderUpdateActionModel(provider: .codex, root: root, home: root, override: { f.launcher.path }, refreshed: {}, run: { f.probe($0) })
        let stale = ProviderReleaseSnapshot(installedVersion: "0.153.4", availableVersion: "0.160.0", source: .codexNPM,
            fingerprint: f.snapshot.fingerprint, checkedAt: Date().addingTimeInterval(-26 * 3600))
        await model.prepare(installation: f.installation, snapshot: stale)
        XCTAssertFalse(model.canUpdate)
        XCTAssertTrue(model.explanation?.contains("refresh") == true)
    }
    func testNativeCodexPreservesLatestPolicyAndRejectsPinnedInstall() async throws {
        let release = ".codex/packages/standalone/releases/0.159.1-aarch64-apple-darwin"
        let binary = try write(release + "/bin/codex", "#!/bin/sh\necho codex-cli 0.159.1\n")
        let nativeRoot = root.appendingPathComponent(".codex/packages/standalone")
        try FileManager.default.createSymbolicLink(at: nativeRoot.appendingPathComponent("current"),
            withDestinationURL: binary.deletingLastPathComponent().deletingLastPathComponent())
        _ = try write(".codex/packages/standalone/auto-update-version", "0.159.1-aarch64-apple-darwin")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        let launcher = root.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: nativeRoot.appendingPathComponent("current/bin/codex"))
        let found = ProviderInstallation(state: .found, path: launcher.path, hint: .native, detail: nil)
        let snapshot = ProviderReleaseSnapshot(installedVersion: "0.159.1", availableVersion: "0.160.0", source: .codexNative,
            fingerprint: try XCTUnwrap(ProviderBinaryFingerprint.read(launcher.path)), checkedAt: Date())
        let plan = try await ProviderMaintenancePlanner.make(provider: .codex, installation: found, snapshot: snapshot, home: root)
        XCTAssertFalse(plan.allowsAutomaticInstall)
        XCTAssertFalse(plan.needsUsageExclusion)
        XCTAssertFalse(plan.arguments.contains("--release"), "An explicit version would pin the native installation")
        try FileManager.default.removeItem(at: nativeRoot.appendingPathComponent("auto-update-version"))
        do {
            _ = try await ProviderMaintenancePlanner.make(provider: .codex, installation: found, snapshot: snapshot, home: root)
            XCTFail("Pinned installation must keep its policy")
        } catch { XCTAssertTrue(error.localizedDescription.contains("policy")) }
    }

    @MainActor
    func testChangedSelectionRejectsPreparedManualAndAutomaticUpdates() async throws {
        let f = try fixture()
        var selected: String? = f.launcher.path
        let calls = LockedBox(0)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"),
            home: root, override: { selected }, refreshed: {}, idleSeconds: { 100 }, run: { request in
                calls.set(calls.get() + 1)
                return f.probe(request)
            })
        await model.prepare(installation: f.installation, snapshot: f.snapshot)
        model.setAutomatic(true)
        XCTAssertTrue(model.canUpdate)
        selected = root.appendingPathComponent("other/bin/codex").path
        let before = calls.get()
        model.update()
        model.update(automatic: true)
        await model.considerAutomaticUpdate()
        XCTAssertFalse(model.canUpdate)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(calls.get(), before)
        await model.prepare(installation: f.installation, snapshot: f.snapshot)
        XCTAssertNil(model.plan, "A stale setup result must not bind the old path to the new selection")
    }

    @MainActor
    func testMutationRechecksAutomaticDiscovery() async throws {
        let f = try fixture()
        let mutations = LockedBox(0)
        let other = ProviderInstallation(state: .found, path: root.appendingPathComponent("other/bin/codex").path,
            hint: .npm, detail: nil)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"),
            home: root, override: { nil }, discover: { _, _, _ in other }, refreshed: {}, run: { request in
                if request.executable == "/bin/ps" { return .init(exitCode: 0, timedOut: false, output: "", truncated: false) }
                if request.arguments.contains("install") { mutations.set(mutations.get() + 1) }
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.update()
            try await waitUntilIdle(model)
            XCTAssertEqual(mutations.get(), 0)
            XCTAssertTrue(model.stage?.contains("changed") == true)
        }
    }

    @MainActor
    func testConcurrentPreparationSharesPackageManagerProbes() async throws {
        let f = try fixture()
        let calls = LockedBox(0)
        let model = ProviderUpdateActionModel(provider: .codex, root: root, home: root,
            override: { f.launcher.path }, refreshed: {}, run: { request in
                calls.set(calls.get() + 1)
                try await Task.sleep(for: .milliseconds(20))
                return f.probe(request)
            })
        async let first: Void = model.prepare(installation: f.installation, snapshot: f.snapshot)
        async let second: Void = model.prepare(installation: f.installation, snapshot: f.snapshot)
        _ = await (first, second)
        XCTAssertEqual(calls.get(), 3)
        XCTAssertTrue(model.canUpdate)
    }

    @MainActor
    func testIdlePolicyChecksPublishOnlyExternalChanges() async throws {
        let f = try fixture()
        let store = root.appendingPathComponent("actions")
        let first = ProviderUpdateActionModel(provider: .codex, root: store, home: root,
            override: { f.launcher.path }, refreshed: {}, idleSeconds: { 0 }, run: { f.probe($0) })
        let second = ProviderUpdateActionModel(provider: .codex, root: store, home: root,
            override: { f.launcher.path }, refreshed: {}, run: { f.probe($0) })
        await first.prepare(installation: f.installation, snapshot: f.snapshot)
        await second.prepare(installation: f.installation, snapshot: f.snapshot)
        var publications = 0
        let subscription = first.$policy.dropFirst().sink { _ in publications += 1 }
        for _ in 0..<3 { await first.considerAutomaticUpdate() }
        XCTAssertEqual(publications, 0)
        second.setAutomatic(true)
        await first.considerAutomaticUpdate()
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(first.policy.enabled)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testReleaseCheckDuringLauncherReplacementPreservesProgress() async throws {
        let f = try fixture()
        let release = ProviderUpdateModel(provider: .codex,
            store: .init(root: root.appendingPathComponent("releases")), override: { f.launcher.path },
            discover: { _, _ in f.installation }, version: { _, _ in "0.153.4" },
            fetch: { _ in ProviderReleaseVersion("0.160.0")! })
        let gate = MaintenanceTestGate()
        let entered = LockedBox(false)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"),
            home: root, override: { f.launcher.path }, refreshed: {}, run: { request in
                if request.executable == "/bin/ps" { return .init(exitCode: 0, timedOut: false, output: "", truncated: false) }
                if request.arguments.contains("install") {
                    try FileManager.default.removeItem(at: f.launcher)
                    entered.set(true)
                    await gate.wait()
                    try FileManager.default.createSymbolicLink(at: f.launcher,
                        withDestinationURL: f.package.appendingPathComponent("bin/codex.js"))
                    return .init(exitCode: 0, timedOut: false, output: "updated", truncated: false)
                }
                if request.arguments == ["--version"] { return .init(exitCode: 0, timedOut: false, output: "codex-cli 0.160.0", truncated: false) }
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await release.check()
            let snapshot = release.record.snapshot
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.update()
            let deadline = Date().addingTimeInterval(3)
            while !entered.get(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(entered.get())
            await release.check(manual: true)
            XCTAssertEqual(release.record.snapshot, snapshot)
            XCTAssertNil(release.record.lastError)
            XCTAssertNotNil(model.presentedPlan)
            release.invalidateSelection()
            XCTAssertNil(release.notice)
            XCTAssertNotNil(model.presentedPlan, "Operation presentation must outlive the release notice")
            model.dismissProgress()
            XCTAssertNotNil(model.presentedPlan, "Running progress cannot be dismissed")
            await gate.release()
            try await waitUntilIdle(model)
            XCTAssertTrue(model.stage?.contains("Updated") == true, model.stage ?? "no status")
            XCTAssertNotNil(model.presentedPlan, "Keep the result visible until dismissed")
            await model.prepare(installation: nil, snapshot: nil)
            XCTAssertNotNil(model.presentedPlan, "An unsuccessful release refresh must preserve the update result")
            model.dismissProgress()
            XCTAssertNil(model.presentedPlan)
        }
    }

    @MainActor
    func testExternalSessionDefersAutomaticUpdateThenRetriesWithoutSuspension() async throws {
        let f = try fixture()
        let external = LockedBox(true)
        let mutations = LockedBox(0)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"),
            home: root, override: { f.launcher.path }, refreshed: {}, idleSeconds: { 100 }, run: { request in
                if request.executable == "/bin/ps" {
                    if external.get() { request.stdoutConsumer?(Data("987654 1 \(f.launcher.path) resume\n".utf8)) }
                    return .init(exitCode: 0, timedOut: false, output: "", truncated: false)
                }
                if request.arguments.contains("install") {
                    mutations.set(mutations.get() + 1)
                    return .init(exitCode: 0, timedOut: false, output: "updated", truncated: false)
                }
                if request.arguments == ["--version"] { return .init(exitCode: 0, timedOut: false, output: "codex-cli 0.160.0", truncated: false) }
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.setAutomatic(true)
            model.update(automatic: true)
            try await waitUntilIdle(model)
            XCTAssertEqual(mutations.get(), 0)
            XCTAssertTrue(model.stage?.contains("987654") == true)
            XCTAssertFalse(model.policy.suspended)
            XCTAssertEqual(model.policy.failures, 0)
            XCTAssertTrue(model.policy.enabled)
            let retry = try XCTUnwrap(model.policy.retryAt)
            XCTAssertFalse(ProviderUsageCoordinator.pending(path: f.launcher.path))
            external.set(false)
            await model.considerAutomaticUpdate(now: retry.addingTimeInterval(-1))
            XCTAssertFalse(model.isRunning)
            await model.considerAutomaticUpdate(now: retry)
            await model.considerAutomaticUpdate(now: retry.addingTimeInterval(31))
            try await waitUntilIdle(model)
            XCTAssertEqual(mutations.get(), 1)
            XCTAssertEqual(model.policy.failures, 0)
            XCTAssertFalse(model.policy.suspended)
        }
    }

    @MainActor
    func testAutomaticPreflightDefersQuietlyWithBackoffAndResumesAfterSessionCloses() async throws {
        let f = try fixture()
        let external = LockedBox(true)
        let scans = LockedBox(0)
        let otherCommands = LockedBox(0)
        let mutations = LockedBox(0)
        let store = root.appendingPathComponent("actions")
        let usageRoot = root.appendingPathComponent("locks")
        let model = ProviderUpdateActionModel(provider: .codex, root: store, home: root,
            override: { f.launcher.path }, refreshed: {}, idleSeconds: { 100 }, run: { request in
                if request.executable == "/bin/ps" {
                    scans.set(scans.get() + 1)
                    if external.get() { request.stdoutConsumer?(Data("987654 1 \(f.launcher.path) resume\n".utf8)) }
                    return .init(exitCode: 0, timedOut: false, output: "", truncated: false)
                }
                otherCommands.set(otherCommands.get() + 1)
                if request.arguments.contains("install") {
                    mutations.set(mutations.get() + 1)
                    return .init(exitCode: 0, timedOut: false, output: "updated", truncated: false)
                }
                if request.arguments == ["--version"] { return .init(exitCode: 0, timedOut: false, output: "codex-cli 0.160.0", truncated: false) }
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(usageRoot) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.setAutomatic(true)
            let directory = store.appendingPathComponent(try XCTUnwrap(model.plan).identity)
            let originalFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            let policyFile = directory.appendingPathComponent("policy.json")
            let originalPolicyBytes = try Data(contentsOf: policyFile)
            let originalPolicy = model.policy
            otherCommands.set(0)
            var now = Date()
            for (index, delay) in [60.0, 300, 900, 900].enumerated() {
                await model.considerAutomaticUpdate(now: now)
                let checkedAt = now.addingTimeInterval(31)
                await model.considerAutomaticUpdate(now: checkedAt)
                XCTAssertEqual(scans.get(), index + 1)
                XCTAssertEqual(otherCommands.get(), 0, "A blocked preflight must run only ps")
                XCTAssertFalse(model.isRunning)
                XCTAssertNil(model.presentedPlan)
                XCTAssertNil(model.stage)
                XCTAssertEqual(model.output, "")
                XCTAssertEqual(model.policy, originalPolicy)
                XCTAssertEqual(try Data(contentsOf: policyFile), originalPolicyBytes)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), originalFiles,
                    "No action lock or journal should be created")
                XCTAssertFalse(FileManager.default.fileExists(atPath: usageRoot.path), "No intent or usage lock should be created")
                await model.considerAutomaticUpdate(now: checkedAt.addingTimeInterval(delay - 1))
                XCTAssertEqual(scans.get(), index + 1)
                now = checkedAt.addingTimeInterval(delay)
            }
            external.set(false)
            await model.considerAutomaticUpdate(now: now)
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(31))
            try await waitUntilIdle(model)
            XCTAssertEqual(scans.get(), 6, "A clear preflight must still be followed by the final inventory")
            XCTAssertEqual(mutations.get(), 1)
            XCTAssertTrue(model.stage?.contains("Updated") == true)
        }
    }

    @MainActor
    func testFailedAutomaticInventoryStaysSilentAndDoesNotStartAction() async throws {
        let f = try fixture()
        let scans = LockedBox(0)
        let usageRoot = root.appendingPathComponent("locks")
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"), home: root,
            override: { f.launcher.path }, refreshed: {}, idleSeconds: { 100 }, run: { request in
                if request.executable == "/bin/ps" {
                    scans.set(scans.get() + 1)
                    return .init(exitCode: 1, timedOut: false, output: "", truncated: false)
                }
                XCTAssertFalse(request.arguments.contains("install"))
                return f.probe(request)
            })
        await ProviderUsageCoordinator.$storageRoot.withValue(usageRoot) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.setAutomatic(true)
            let policy = model.policy
            let now = Date()
            await model.considerAutomaticUpdate(now: now)
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(31))
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(50))
            XCTAssertEqual(scans.get(), 1)
            XCTAssertFalse(model.isRunning)
            XCTAssertNil(model.stage)
            XCTAssertNil(model.presentedPlan)
            XCTAssertEqual(model.policy, policy)
            XCTAssertFalse(FileManager.default.fileExists(atPath: usageRoot.path))
        }
    }

    @MainActor
    func testAutomaticPreflightDeduplicatesAndRechecksConsentAfterAwait() async throws {
        let f = try fixture()
        let gate = MaintenanceTestGate()
        let scans = LockedBox(0)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"), home: root,
            override: { f.launcher.path }, refreshed: {}, idleSeconds: { 100 }, run: { request in
                if request.executable == "/bin/ps" {
                    scans.set(scans.get() + 1)
                    await gate.wait()
                    return .init(exitCode: 0, timedOut: false, output: "", truncated: false)
                }
                XCTAssertFalse(request.arguments.contains("install"))
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.setAutomatic(true)
            let now = Date()
            await model.considerAutomaticUpdate(now: now)
            let pending = Task { await model.considerAutomaticUpdate(now: now.addingTimeInterval(31)) }
            let deadline = Date().addingTimeInterval(3)
            while scans.get() == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(32))
            XCTAssertEqual(scans.get(), 1)
            let otherWindow = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"), home: root,
                override: { f.launcher.path }, refreshed: {}, run: { f.probe($0) })
            await otherWindow.prepare(installation: f.installation, snapshot: f.snapshot)
            otherWindow.setAutomatic(false)
            await gate.release()
            await pending.value
            XCTAssertFalse(model.isRunning)
            XCTAssertFalse(model.policy.enabled)
            XCTAssertNil(model.presentedPlan)
            XCTAssertNil(model.stage)
        }
    }

    func testPreflightIgnoresOwnDescendantsButFinalInventoryIncludesThem() {
        let launcher = "/test/bin/codex"
        let listing = Data("""
        987651 987650 \(launcher) app-server
        987653 987652 \(launcher) app-server
        987654 1 \(launcher) resume
        987652 987650 /usr/bin/node wrapper
        987650 1 /Applications/Rubien.app/Contents/MacOS/Rubien
        """.utf8)
        let early = ProviderProcessInventory(root: "/test/package", launcher: launcher, ignoringDescendantsOf: 987650)
        early.append(listing)
        XCTAssertEqual(early.finish(), [987654])
        let final = ProviderProcessInventory(root: "/test/package", launcher: launcher)
        final.append(listing)
        XCTAssertEqual(final.finish(), [987651, 987653, 987654])
    }

    @MainActor
    func testSessionOpenedAfterAutomaticPreflightStillBlocksMutation() async throws {
        let f = try fixture()
        let scans = LockedBox(0)
        let mutations = LockedBox(0)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"), home: root,
            override: { f.launcher.path }, refreshed: {}, idleSeconds: { 100 }, run: { request in
                if request.executable == "/bin/ps" {
                    scans.set(scans.get() + 1)
                    // The first snapshot contains our own idle child; a Terminal
                    // session appears before the final snapshot under exclusion.
                    let parent = scans.get() == 1 ? ownPID : 1
                    request.stdoutConsumer?(Data("987654 \(parent) \(f.launcher.path) app-server\n".utf8))
                    return .init(exitCode: 0, timedOut: false, output: "", truncated: false)
                }
                if request.arguments.contains("install") { mutations.set(mutations.get() + 1) }
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.setAutomatic(true)
            let now = Date()
            await model.considerAutomaticUpdate(now: now)
            await model.considerAutomaticUpdate(now: now.addingTimeInterval(31))
            try await waitUntilIdle(model)
            XCTAssertEqual(scans.get(), 2)
            XCTAssertEqual(mutations.get(), 0)
            XCTAssertTrue(model.stage?.contains("987654") == true)
            XCTAssertFalse(model.policy.suspended)
            XCTAssertEqual(model.policy.failures, 0)
        }
    }

    @MainActor
    func testBusyUsageAndFailedInventoryDoNotCountAsAutomaticFailures() async throws {
        let f = try fixture()
        let scans = LockedBox(0)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"),
            home: root, override: { f.launcher.path }, refreshed: {}, idleSeconds: { 100 }, run: { request in
                if request.executable == "/bin/ps" {
                    scans.set(scans.get() + 1)
                    return .init(exitCode: 1, timedOut: false, output: "", truncated: false)
                }
                XCTAssertFalse(request.arguments.contains("install"))
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            model.setAutomatic(true)
            var usage = try ProviderUsageCoordinator.acquireUsage(path: f.launcher.path)
            model.update(automatic: true)
            try await waitUntilIdle(model)
            XCTAssertEqual(scans.get(), 0)
            XCTAssertEqual(model.policy.failures, 0)
            XCTAssertFalse(model.policy.suspended)
            withExtendedLifetime(usage) {}
            usage = nil
            model.update(automatic: true)
            try await waitUntilIdle(model)
            XCTAssertEqual(scans.get(), 1)
            XCTAssertEqual(model.policy.failures, 0)
            XCTAssertFalse(model.policy.suspended)
            XCTAssertNotNil(model.policy.retryAt)
        }
    }

    func testProcessInventoryMatchesOnlySelectedInstallationWithoutTotalOutputCap() async throws {
        let selectedRoot = "/test/npm/lib/node_modules/@openai/codex"
        let launcher = "/test/npm/bin/codex"
        let inventory = ProviderProcessInventory(root: selectedRoot, launcher: launcher)
        let listing = String(repeating: "876500 1 /unrelated/program with a long command line\n", count: 40000) + """
        876501 1 codex resume
        876502 1 /test/native/bin/codex resume
        876503 1 /other/npm/bin/codex resume
        876504 1 /test/npm/bin/codex-other resume
        876505 1 /test/npm/lib/node_modules/@openai/codex-other/bin/codex
        876506 1 \(launcher) resume
        876507 1 /usr/bin/node \(selectedRoot)/bin/codex.js resume
        876508 1 /prefix\(launcher) resume
        """
        let file = try write("processes.txt", listing)
        let result = try await ProviderMaintenanceRunner.run(.init(executable: "/bin/cat", arguments: [file.path],
            environment: ["PATH": "/usr/bin:/bin"], directory: root, timeout: 10, retainOutput: false,
            stdoutConsumer: { inventory.append($0) }))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(inventory.finish(), [876506, 876507])
        XCTAssertFalse(result.output.contains("program"), "Raw process arguments must not enter diagnostics")
    }

    func testUsageCoordinationExcludesInstructionsOnlyInstallations() throws {
        for path in ["prefix/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                     "prefix/Caskroom/codex/1.0/bin/codex", "prefix/Caskroom/claude-code/1.0/bin/claude"] {
            let binary = try write(path, "#!/bin/sh\nexit 0\n")
            XCTAssertNil(ProviderUsageCoordinator.packageRoot(binary.path))
            XCTAssertNil(try ProviderUsageCoordinator.acquireUsage(path: binary.path))
        }
    }

    @MainActor
    func testTerminationWaitsForMutationCancelsObserversAndRepliesOnce() async throws {
        let f = try fixture()
        let gate = MaintenanceTestGate()
        let entered = LockedBox(false)
        let store = root.appendingPathComponent("actions")
        let runner: ProviderMaintenancePlanner.Run = { request in
            if request.executable == "/bin/ps" { return .init(exitCode: 0, timedOut: false, output: "", truncated: false) }
            if request.arguments.contains("install") {
                entered.set(true)
                await gate.wait()
                return .init(exitCode: 0, timedOut: false, output: "updated", truncated: false)
            }
            if request.arguments == ["--version"] { return .init(exitCode: 0, timedOut: false, output: "codex-cli 0.160.0", truncated: false) }
            return f.probe(request)
        }
        let model = ProviderUpdateActionModel(provider: .codex, root: store, home: root,
            override: { f.launcher.path }, refreshed: {}, run: runner)
        let observer = ProviderUpdateActionModel(provider: .codex, root: store, home: root,
            override: { f.launcher.path }, refreshed: {}, run: runner)
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            await observer.prepare(installation: f.installation, snapshot: f.snapshot)
            model.update()
            let deadline = Date().addingTimeInterval(3)
            while !entered.get(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(entered.get())
            observer.update()
            let termination = ProviderUpdateTermination()
            var replies = 0
            XCTAssertEqual(termination.request(actions: [model, observer]) { replies += 1 }, .terminateLater)
            XCTAssertEqual(termination.request(actions: [model, observer]) { replies += 1 }, .terminateLater)
            try await waitUntilIdle(observer)
            XCTAssertTrue(model.isRunning)
            XCTAssertFalse(model.canCancel)
            XCTAssertEqual(replies, 0)
            observer.update()
            XCTAssertFalse(observer.isRunning, "No new actions may start while quitting")
            await gate.release()
            try await waitUntilIdle(model)
            for _ in 0..<20 where replies == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(replies, 1)
            XCTAssertTrue(model.stage?.contains("Updated") == true, model.stage ?? "no status")
        }
    }

    @MainActor
    func testTerminationWithoutUpdatesIsImmediate() {
        let model = ProviderUpdateActionModel(provider: .codex, root: root, home: root, override: { nil })
        XCTAssertEqual(ProviderUpdateTermination().request(actions: [model]) { XCTFail("No deferred reply needed") }, .terminateNow)
    }

    func testReleaseStoreRecoversAfterDirectoryRemoval() throws {
        let store = ProviderUpdateStore(root: root.appendingPathComponent("release-store"))
        try store.modify("codex") { $0.automaticChecks = false }
        try FileManager.default.removeItem(at: store.root)
        var check = try store.acquireCheck("codex")
        XCTAssertNotNil(check)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        withExtendedLifetime(check) {}
        check = nil
        try store.modify("codex") { $0.automaticChecks = false }
        XCTAssertFalse(store.read("codex").automaticChecks)
    }

    @MainActor
    private func waitUntilIdle(_ model: ProviderUpdateActionModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isRunning)
    }

    @MainActor
    func testActionVerifiesVersionAndDoesNotRepeatMutation() async throws {
        let f = try fixture()
        let calls = LockedBox(0)
        let refreshed = LockedBox(false)
        let model = ProviderUpdateActionModel(provider: .codex, root: root.appendingPathComponent("actions"), home: root, override: { f.launcher.path },
            refreshed: { refreshed.set(true) }, run: { request in
                if request.executable == "/bin/ps" { return .init(exitCode: 0, timedOut: false, output: "", truncated: false) }
                if request.arguments.contains("@openai/codex@0.160.0") {
                    calls.set(calls.get() + 1)
                    XCTAssertNotNil(request.maintenanceOwner)
                    try "#!/bin/sh\necho codex-cli 0.160.0\n".write(to: f.launcher, atomically: false, encoding: .utf8)
                    return .init(exitCode: 0, timedOut: false, output: "updated", truncated: false)
                }
                if request.arguments == ["--version"] { return .init(exitCode: 0, timedOut: false, output: "codex-cli 0.160.0", truncated: false) }
                return f.probe(request)
            })
        try await ProviderUsageCoordinator.$storageRoot.withValue(root.appendingPathComponent("locks")) {
            await model.prepare(installation: f.installation, snapshot: f.snapshot)
            XCTAssertTrue(model.canUpdate)
            model.update()
            model.update()
            let deadline = Date().addingTimeInterval(5)
            while model.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(calls.get(), 1)
            XCTAssertTrue(refreshed.get())
            XCTAssertTrue(model.stage?.contains("Updated to 0.160.0") == true, model.stage ?? "no status")
        }
    }
}

private actor MaintenanceTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
#endif
