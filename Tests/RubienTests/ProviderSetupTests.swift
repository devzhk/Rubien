#if os(macOS)
import XCTest
import Darwin
@testable import Rubien

final class ProviderSetupTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-setup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testDiscoveryDoesNotOfferInstallForBrokenOverrideOrSymlink() throws {
        let missing = directory.appendingPathComponent("missing").path
        let link = directory.appendingPathComponent("codex").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: missing)
        let absent = ProviderInstallationDetector.inspect(provider: .codex, override: nil, candidates: [], shellPath: nil, shellSucceeded: true)
        XCTAssertTrue(absent.canInstall)
        let broken = ProviderInstallationDetector.inspect(provider: .codex, override: nil, candidates: [link], shellPath: nil, shellSucceeded: true)
        XCTAssertFalse(broken.canInstall)
        XCTAssertEqual(broken.path, link)
        let override = ProviderInstallationDetector.inspect(provider: .codex, override: missing, candidates: [], shellPath: nil, shellSucceeded: true)
        XCTAssertEqual(override.state, .selectedPathMissing)
        XCTAssertFalse(override.canInstall)
        let uncertain = ProviderInstallationDetector.inspect(provider: .claude, override: nil, candidates: [], shellPath: nil, shellSucceeded: false)
        XCTAssertEqual(uncertain.state, .inaccessible)
    }

    func testFingerprintTracksSymlinkReplacement() throws {
        let one = directory.appendingPathComponent("one")
        let two = directory.appendingPathComponent("two")
        let link = directory.appendingPathComponent("cli")
        try Data("one".utf8).write(to: one); try Data("two".utf8).write(to: two)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: one)
        let first = try XCTUnwrap(ProviderBinaryFingerprint.read(link.path))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: two)
        XCTAssertNotEqual(first, ProviderBinaryFingerprint.read(link.path))
    }

    func testShellLookupIgnoresProfileOutputAndFramesMissingResults() async throws {
        let shell = directory.appendingPathComponent("noisy-shell")
        try "#!/bin/sh\nprintf 'Agent pid 123\\nprofile loaded\\n'\n/bin/sh -c \"$3\"\nprintf 'profile finished\\n'\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let found = await ProviderShellLookup.discover(binaryName: "sh", shell: shell.path, environment: ["PATH": "/bin"])
        XCTAssertEqual(found, .init(path: "/bin/sh", completed: true))
        let missing = await ProviderShellLookup.discover(binaryName: "rubien-absent-test-provider", shell: shell.path, environment: ["PATH": "/bin"])
        XCTAssertEqual(missing, .init(path: nil, completed: true))
        let lookup = ProviderShellLookup(marker: "LOOKUP")
        XCTAssertFalse(lookup.parse("profile output\n").completed)
        XCTAssertFalse(lookup.parse("LOOKUP\n0\n/bin/sh\n").completed, "Incomplete frames must not authorize installation")
    }

    func testShellLookupAllowsSlowProfilesButDoesNotTreatTimeoutAsMissing() async throws {
        let shell = directory.appendingPathComponent("slow-shell")
        try "#!/bin/sh\n/bin/sleep 5.2\nexec /bin/sh -c \"$3\"\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let result = await ProviderShellLookup.discover(binaryName: "sh", shell: shell.path, environment: ["PATH": "/bin"])
        XCTAssertEqual(result.path, "/bin/sh")
        let timedOut = await ProviderShellLookup.discover(binaryName: "sh", shell: shell.path, environment: ["PATH": "/bin"], timeout: 0.05)
        XCTAssertFalse(timedOut.completed)
        let launchPath = await Task.detached {
            AgentBinaryProbe.shellResolve(binaryName: "sh", shell: shell.path, environment: ["PATH": "/bin"])
        }.value
        XCTAssertNil(launchPath, "The synchronous launch fallback must retain its shorter five-second deadline")
    }

    func testNonPOSIXLoginShellDelegatesLookupAndPreservesProfilePath() async throws {
        let bin = directory.appendingPathComponent("profile bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("provider's test")
        try "#!/bin/sh\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let shell = directory.appendingPathComponent("non-posix-shell")
        // This stub accepts a quoted exec invocation, not POSIX assignments,
        // substitutions, or conditionals in the login shell's command language.
        let stub = #"""
        #!/usr/bin/python3
        import os, shlex, sys
        assert sys.argv[1:3] == ['-l', '-c']
        words = shlex.split(sys.argv[3])
        assert len(words) == 4 and words[:3] == ['exec', '/bin/sh', '-c']
        print('Profile banner: ssh-agent pid 123', flush=True)
        os.environ['PATH'] = os.environ['TEST_PROFILE_BIN'] + ':/usr/bin:/bin'
        os.execve('/bin/sh', words[1:], os.environ)
        """#
        try stub.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let environment = ["TEST_PROFILE_BIN": bin.path, "PATH": "/usr/bin:/bin"]
        let found = await ProviderShellLookup.discover(binaryName: cli.lastPathComponent, shell: shell.path, environment: environment)
        XCTAssertEqual(found, .init(path: cli.path, completed: true))
        let missing = await ProviderShellLookup.discover(binaryName: "absent-provider", shell: shell.path, environment: environment)
        XCTAssertEqual(missing, .init(path: nil, completed: true))
        let launchPath = AgentBinaryProbe.shellResolve(binaryName: cli.lastPathComponent, shell: shell.path, environment: environment)
        XCTAssertEqual(launchPath, cli.path, "Setup and ordinary launches must use the same shell-compatible framing")
    }

    @MainActor
    func testInstallAndSignInRetryBriefStatusReaderContention() async throws {
        for action in ProviderSetupAction.allCases {
            let store = ProviderSetupStore(root: directory.appendingPathComponent(action.rawValue))
            let calls = SetupCallRecorder()
            let environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
            let model = ProviderSetupModel(provider: .claude, store: store, home: directory,
                run: { request in
                    XCTAssertEqual(request.environment["HOME"], environment["HOME"])
                    XCTAssertEqual(request.environment["PATH"], action == .login ? "/fake:/usr/bin:/bin" : "/usr/bin:/bin")
                    await calls.record(action.rawValue)
                    return ProviderCommandResult(exitCode: action == .install ? 22 : 0,
                        timedOut: false, output: "", truncated: false)
                }, environment: { _ in environment }, discover: { _, _ in
                    .init(state: action == .install ? .missing : .found,
                          path: action == .install ? nil : "/fake/claude", hint: .unknown, detail: nil)
                }, probe: { _, _ in .installedButUnauthenticated(version: "1.0.0", path: "/fake/claude", reason: "Sign in") })
            await model.refresh()
            var reader = try store.acquire(provider: .claude, action: action, mode: .shared)
            XCTAssertNotNil(reader)
            if action == .install { model.install() } else { model.signIn() }
            try await Task.sleep(for: .milliseconds(30))
            let beforeRelease = await calls.all()
            XCTAssertTrue(beforeRelease.isEmpty)
            withExtendedLifetime(reader) {}
            reader = nil
            try await waitUntilIdle(model)
            let executed = await calls.all()
            XCTAssertEqual(executed, [action.rawValue], "A short status check must not discard the user's action")
        }
    }

    func testActionRetryStaysBoundedAndDoesNotQueueBehindWriter() async throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        let reader = try XCTUnwrap(store.acquire(provider: .claude, mode: .shared))
        let blocked = try await store.acquireForAction(provider: .claude)
        XCTAssertNil(blocked)
        let writer = try XCTUnwrap(store.acquire(provider: .codex))
        let duplicate = try await store.acquireForAction(provider: .codex)
        XCTAssertNil(duplicate)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.acquireForAction(provider: .claude)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled setup must not acquire a lock") }
        catch is CancellationError {}
        withExtendedLifetime((reader, writer)) {}
    }

    @MainActor
    func testSignInCanBeCancelledWhileRetryingAStatusReader() async throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        let calls = SetupCallRecorder()
        let model = ProviderSetupModel(provider: .claude, store: store, home: directory,
            run: { _ in
                await calls.record("unexpected login")
                return ProviderCommandResult(exitCode: 0, timedOut: false, output: "", truncated: false)
            }, discover: { _, _ in .init(state: .found, path: "/fake/claude", hint: .unknown, detail: nil) },
            probe: { _, _ in .installedButUnauthenticated(version: "1.0.0", path: "/fake/claude", reason: "Sign in") })
        await model.refresh()
        let reader = try XCTUnwrap(store.acquire(provider: .claude, action: .login, mode: .shared))
        model.signIn()
        await Task.yield()
        model.cancel()
        try await waitUntilIdle(model)
        XCTAssertEqual(model.message, "Sign-in cancelled.")
        let executed = await calls.all()
        XCTAssertTrue(executed.isEmpty)
        XCTAssertNil(store.read(provider: .claude, action: .login))
        withExtendedLifetime(reader) {}
    }

    @MainActor
    func testSharedStatusProbesCoexistAndDoNotReportInterruptionWithoutJournal() async throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        let reader = try XCTUnwrap(store.acquire(provider: .claude, mode: .shared))
        XCTAssertNotNil(try store.acquire(provider: .claude, mode: .shared))
        XCTAssertNil(try store.acquire(provider: .claude))
        XCTAssertNil(store.maintenanceAvailability(provider: .claude))
        let model = ProviderSetupModel(provider: .claude, store: store, home: directory,
            discover: { _, _ in .init(state: .missing, path: nil, hint: .unknown, detail: nil) },
            probe: { _, _ in .notFound(reason: "absent") })
        await model.refresh()
        XCTAssertTrue(model.canInstall)
        XCTAssertNil(model.message)
        withExtendedLifetime(reader) {}
    }

    @MainActor
    func testObservedLockWithoutJournalDoesNotInventInterruption() async throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        var writer: ProviderSetupLock? = try XCTUnwrap(store.acquire(provider: .claude))
        let model = ProviderSetupModel(provider: .claude, store: store, home: directory,
            discover: { _, _ in .init(state: .missing, path: nil, hint: .unknown, detail: nil) },
            probe: { _, _ in .notFound(reason: "absent") })
        await model.refresh()
        XCTAssertEqual(model.activity, .observing("Starting"))
        withExtendedLifetime(writer) {}
        writer = nil
        try await waitUntilIdle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.canInstall)
    }

    @MainActor
    func testActivationChecksAreThrottledButExplicitChecksAndChangedFilesRefresh() async throws {
        let clock = ProviderSetupTestClock()
        let calls = SetupCallRecorder()
        let binary = directory.appendingPathComponent("claude")
        try Data("one".utf8).write(to: binary)
        let model = ProviderSetupModel(provider: .claude, store: .init(root: directory.appendingPathComponent("state")), home: directory,
            now: { clock.now() }, discover: { _, _ in
                await calls.record("discover")
                return .init(state: .found, path: binary.path, hint: .unknown, detail: nil)
            }, probe: { _, _ in .installed(version: "1.0.0", path: binary.path) })
        await model.refresh(force: false)
        await model.refresh(force: false)
        XCTAssertEqual(model.completedChecks, 1)
        await model.refresh()
        XCTAssertEqual(model.completedChecks, 2)
        clock.advance(61)
        await model.refresh(force: false)
        XCTAssertEqual(model.completedChecks, 3)
        try Data("replacement".utf8).write(to: binary, options: .atomic)
        await model.refresh(force: false)
        XCTAssertEqual(model.completedChecks, 4)
        let discoveries = await calls.all()
        XCTAssertEqual(discoveries.count, 4)
    }

    @MainActor
    func testCompletedInstallationRecoversUnfinishedJournalWithoutStickyWarning() async throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        try store.write(.init(id: UUID(), provider: .claude, action: .install,
                              stage: "Verifying", finished: false, succeeded: false, updatedAt: Date()))
        let model = ProviderSetupModel(provider: .claude, store: store, home: directory,
            discover: { _, _ in .init(state: .found, path: "/fake/claude", hint: .unknown, detail: nil) },
            probe: { _, _ in .installed(version: "1.0.0", path: "/fake/claude") })
        await model.refresh()
        XCTAssertTrue(model.availability?.isReady == true)
        XCTAssertNil(model.message)
        XCTAssertTrue(store.read(provider: .claude)?.finished == true)
        await model.refresh(notice: "An old notice")
        XCTAssertEqual(model.message, "An old notice")
        await model.refresh()
        XCTAssertNil(model.message)
    }

    func testDownloadRejectsUntrustedRedirectsAndNonScript() throws {
        let plan = ProviderInstallerPlan(provider: .codex, directory: directory)
        try "#!/bin/sh\nexit 0\n".write(to: plan.script, atomically: true, encoding: .utf8)
        try "HTTP/2 302\r\nLocation: https://example.com/payload\r\n".write(to: plan.headers, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try plan.validateDownload())
        try "HTTP/2 302\r\nLocation: https://releases.openai.com/codex/install.sh\r\nHTTP/2 200\r\n".write(to: plan.headers, atomically: true, encoding: .utf8)
        XCTAssertEqual(try plan.validateDownload().count, 64)
        try "<html>failure</html>".write(to: plan.script, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try plan.validateDownload())
        XCTAssertTrue(plan.displayedProcedure.contains("CODEX_NON_INTERACTIVE=1"))
        XCTAssertTrue(plan.displayedProcedure.contains(plan.script.path))
    }

    func testActionLockIsInheritedByChildAndExcludesAnotherProcess() async throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("shared"))
        var lock = try XCTUnwrap(store.acquire(provider: .codex))
        XCTAssertNil(try store.acquire(provider: .codex))
        XCTAssertTrue(store.maintenanceAvailability(provider: .codex)?.setupInProgress == true)
        let fd = lock.descriptor
        let child = try SpawnedAgentProcess.spawn(executablePath: "/bin/sleep", arguments: ["30"],
            environment: [:], workingDirectory: directory.path, startsNewSession: true, inheritedLock: fd)
        child.closeStdin()
        // Replacing the parent lock closes its descriptor. Only the child retains it.
        lock = try XCTUnwrap(store.acquire(provider: .claude))
        XCTAssertNil(try store.acquire(provider: .codex))
        child.signalGroup(SIGKILL)
        _ = await child.wait(); child.closeOutputHandles()
        XCTAssertNotNil(try store.acquire(provider: .codex))
        withExtendedLifetime(lock) {}
    }

    func testRunnerHasNoControllingTerminalAndKeepsOutputBounded() async throws {
        let env = ProviderSetupEnvironment.make(provider: .codex)
        let result = try await ProviderMaintenanceRunner.run(executable: "/bin/sh",
            arguments: ["-c", "if ( : </dev/tty ) 2>/dev/null; then exit 9; fi; printf '%s' \"$CODEX_NON_INTERACTIVE\"; /usr/bin/yes x | /usr/bin/head -c 700000"],
            environment: env, directory: directory, timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.hasPrefix("1"))
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.output.utf8.count, 600000)
    }

    func testRunnerPublishesOutputBeforeExit() async throws {
        let output = SetupCallRecorder()
        let cwd = directory!
        let running = Task {
            try await ProviderMaintenanceRunner.run(executable: "/bin/sh", arguments: ["-c", "echo first; sleep 1; echo second"],
                environment: [:], directory: cwd, timeout: 5, onOutput: { text in
                    Task { await output.record(text) }
                })
        }
        var intermediate: [String] = []
        for _ in 0..<80 {
            intermediate = await output.all()
            if intermediate.contains(where: { $0.contains("first") }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(intermediate.contains(where: { $0.contains("first") }))
        XCTAssertFalse(intermediate.contains(where: { $0.contains("second") }))
        let final = try await running.value
        XCTAssertTrue(final.output.contains("second"))
    }

    func testQuietRunnerDoesNotRepublishUnchangedOutput() async throws {
        let updates = LockedBox<[String]>([])
        let result = try await ProviderMaintenanceRunner.run(executable: "/bin/sh",
            arguments: ["-c", "printf 'Ready 🚀\\n'; sleep 1.1"], environment: [:], directory: directory, timeout: 5,
            onOutput: { updates.set(updates.get() + [$0]) })
        XCTAssertEqual(updates.get(), [result.output], "Quiet ticks and completion must not repeat an identical update")
        XCTAssertTrue(result.output.contains("Ready 🚀"))
        XCTAssertEqual(ProviderMaintenanceRunner.sanitize("café 🚀\u{1}\t\n"), "café 🚀\t\n")
    }

    func testStoreRecoversDeletedDirectoryAndRetainsPrivatePermissions() throws {
        let root = directory.appendingPathComponent("state")
        let store = ProviderSetupStore(root: root)
        do {
            let lock = try XCTUnwrap(store.acquire(provider: .claude))
            XCTAssertNil(try store.acquire(provider: .claude))
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            withExtendedLifetime(lock) {}
        }
        try FileManager.default.removeItem(at: root)
        let recovered = try XCTUnwrap(store.acquire(provider: .claude))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNil(try store.acquire(provider: .claude))
        withExtendedLifetime(recovered) {}
    }

    func testTypedActionReadsExistingJournalWithRemovedFields() throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        let record = ProviderSetupRecord(id: UUID(), provider: .claude, action: .login,
            stage: "Signing in", finished: false, succeeded: false, updatedAt: Date())
        try store.write(record)
        let url = store.root.appendingPathComponent("claude-login.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "login")
        XCTAssertNil(object["ownerPID"])
        XCTAssertNil(object["scriptBytes"])
        object["ownerPID"] = 123
        object["scriptBytes"] = 1024
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(store.read(provider: .claude, action: .login), record)
    }

    @MainActor
    func testInstallVerificationRequiresVersionAndPreservesPrerelease() {
        XCTAssertEqual(ProviderSetupModel.version(from: "codex-cli 1.2.3-beta.1+build.2"), "1.2.3-beta.1+build.2")
        XCTAssertNil(ProviderSetupModel.version(from: "installer failed"))
        XCTAssertEqual(AgentBinaryProbe.parseVersionString("legacy version output"), "legacy version output")
    }

    func testTimeoutAndCancellationReapChildren() async throws {
        let timeout = try await ProviderMaintenanceRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 30"],
            environment: [:], directory: directory, timeout: 0.1)
        XCTAssertTrue(timeout.timedOut)
        let cwd = directory!
        let task = Task { try await ProviderMaintenanceRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 30"],
            environment: [:], directory: cwd, timeout: 30) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should throw") } catch is CancellationError {} catch { throw error }
    }

    func testAuthOutputIsDiscardedAndDiagnosticsRedacted() async throws {
        let result = try await ProviderMaintenanceRunner.run(executable: "/bin/echo", arguments: ["secret login output"],
            environment: [:], directory: directory, timeout: 2, retainOutput: false)
        XCTAssertTrue(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let clean = ProviderMaintenanceRunner.sanitize("\u{1B}[31mError https://host/?code=abc token=SECRET sk-test123\u{1B}[0m")
        XCTAssertFalse(clean.contains("SECRET")); XCTAssertFalse(clean.contains("abc")); XCTAssertFalse(clean.contains("sk-test123"))
        let env = ProviderSetupEnvironment.make(provider: .codex, host: ["OPENAI_API_KEY": "secret", "HTTPS_PROXY": "http://proxy", "HOME": "/test"])
        XCTAssertNil(env["OPENAI_API_KEY"]); XCTAssertEqual(env["HTTPS_PROXY"], "http://proxy")
        XCTAssertNotNil(env["SHELL"])
    }

    @MainActor
    func testFailedDownloadNeverExecutesInstallerOrWritesReceipt() async throws {
        let calls = SetupCallRecorder()
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        let model = ProviderSetupModel(provider: .codex, store: store, home: directory,
            run: { request in
                await calls.record(request.executable)
                return ProviderCommandResult(exitCode: 22, timedOut: false, output: "failed", truncated: false)
            }, discover: { _, _ in .init(state: .missing, path: nil, hint: .unknown, detail: nil) },
            probe: { _, _ in XCTFail("No executable should be probed"); return .notFound(reason: "missing") })
        await model.refresh()
        XCTAssertTrue(model.canInstall)
        let initialCalls = await calls.all()
        XCTAssertTrue(initialCalls.isEmpty)
        model.install(); model.install()
        try await waitUntilIdle(model)
        let executed = await calls.all()
        XCTAssertEqual(executed, ["/usr/bin/curl"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("codex-receipt.json").path))
        XCTAssertEqual(store.read(provider: .codex)?.succeeded, false)
    }

    @MainActor
    func testSuccessfulFakeInstallRequiresVerifiedNativeTargetAndPersistsReceipt() async throws {
        let calls = SetupCallRecorder()
        let home = directory!
        let binary = home.appendingPathComponent(".local/bin/codex")
        let target = home.appendingPathComponent(".codex/packages/standalone/releases/test/codex")
        let store = ProviderSetupStore(root: home.appendingPathComponent("state"))
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "CODEX_NON_INTERACTIVE": "1"]
        let model = ProviderSetupModel(provider: .codex, store: store, home: home,
            run: { request in
                XCTAssertEqual(request.environment, environment, "Download, install, and verification must all use the injected environment")
                let executable = request.executable
                await calls.record(executable)
                if executable == "/usr/bin/curl" {
                    let plan = ProviderInstallerPlan(provider: .codex, directory: request.directory)
                    try "#!/bin/sh\nexit 0\n".write(to: plan.script, atomically: true, encoding: .utf8)
                    try "HTTP/2 200\r\n".write(to: plan.headers, atomically: true, encoding: .utf8)
                } else if executable == "/bin/sh" {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("fake executable".utf8).write(to: target)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
                    try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: target)
                } else { XCTAssertEqual(request.arguments, ["--version"]) }
                return ProviderCommandResult(exitCode: 0, timedOut: false, output: "codex-cli 1.2.3-beta.1", truncated: false)
            }, environment: { _ in environment }, discover: { _, _ in
                .init(state: FileManager.default.fileExists(atPath: binary.path) ? .found : .missing,
                      path: FileManager.default.fileExists(atPath: binary.path) ? binary.path : nil, hint: .unknown, detail: nil)
            }, probe: { _, _ in .installedButUnauthenticated(version: "1.2.3-beta.1", path: binary.path, reason: "Sign in") })
        await model.refresh(); model.install(); try await waitUntilIdle(model)
        let record = try XCTUnwrap(store.read(provider: .codex))
        XCTAssertTrue(record.succeeded, model.message ?? "")
        XCTAssertEqual(record.version, "1.2.3-beta.1")
        XCTAssertEqual(record.fingerprint?.target, target.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("codex-receipt.json").path))
        XCTAssertTrue(model.canSignIn)
        let executed = await calls.all()
        XCTAssertEqual(executed, ["/usr/bin/curl", "/bin/sh", binary.path])
    }

    @MainActor
    func testContendingModelObservesWithoutLaunchingAndRecoversInterruptedJournal() async throws {
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        var lock: ProviderSetupLock? = try XCTUnwrap(store.acquire(provider: .claude))
        let record = ProviderSetupRecord(id: UUID(), provider: .claude, action: .install,
                                        stage: "Installing", finished: false, succeeded: false, updatedAt: Date())
        try store.write(record)
        let calls = SetupCallRecorder()
        let model = ProviderSetupModel(provider: .claude, store: store, home: directory,
            run: { _ in
                await calls.record("unexpected")
                return ProviderCommandResult(exitCode: 0, timedOut: false, output: "", truncated: false)
            }, discover: { _, _ in .init(state: .missing, path: nil, hint: .unknown, detail: nil) },
            probe: { _, _ in .notFound(reason: "absent") })
        await model.refresh()
        XCTAssertEqual(model.activity, .observing("Installing"))
        model.install()
        withExtendedLifetime(lock) {}
        lock = nil
        try await waitUntilIdle(model)
        let executed = await calls.all()
        XCTAssertTrue(executed.isEmpty)
        XCTAssertTrue(model.message?.contains("interrupted") == true)
        XCTAssertTrue(store.read(provider: .claude)?.finished == true)
        await model.refresh()
        XCTAssertNil(model.message, "An interruption is reconciled once, not shown on every recheck")
    }

    @MainActor
    func testSignInCancellationIsDeduplicatedAndDoesNotRetainCredentials() async throws {
        let calls = SetupCallRecorder()
        let store = ProviderSetupStore(root: directory.appendingPathComponent("state"))
        let model = ProviderSetupModel(provider: .claude, store: store, home: directory,
            run: { request in
                XCTAssertEqual(request.arguments, ["auth", "login"])
                XCTAssertFalse(request.retainOutput)
                XCTAssertEqual(request.executable, "/fake/claude")
                XCTAssertEqual(request.timeout, 10 * 60)
                XCTAssertNotNil(request.inheritedLock)
                await calls.record("login")
                try await Task.sleep(for: .seconds(30))
                return ProviderCommandResult(exitCode: 0, timedOut: false, output: "", truncated: false)
            }, discover: { _, _ in .init(state: .found, path: "/fake/claude", hint: .unknown, detail: nil) },
            probe: { _, _ in .installedButUnauthenticated(version: "1.0.0", path: "/fake/claude", reason: "Sign in") })
        await model.refresh()
        model.signIn(); model.signIn()
        for _ in 0..<100 {
            if !(await calls.all()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.cancel()
        try await waitUntilIdle(model)
        let executed = await calls.all()
        XCTAssertEqual(executed, ["login"])
        XCTAssertEqual(store.read(provider: .claude, action: .login)?.detail, "Sign-in cancelled.")
        XCTAssertTrue(model.diagnostics.isEmpty)
    }

    func testClaudeAvailabilityReprobesWhenExecutableChanges() async throws {
        let cli = directory.appendingPathComponent("claude")
        func writeVersion(_ version: String) throws {
            let script = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo '\(version) (Claude Code)'; else echo '{\"loggedIn\":true}'; fi\n"
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        try writeVersion("1.0.0")
        let provider = ClaudeCodeProvider(executableOverride: cli.path,
            maintenanceStore: .init(root: directory.appendingPathComponent("state")))
        let first = await provider.isAvailable()
        try writeVersion("2.0.0")
        let second = await provider.isAvailable()
        XCTAssertEqual(first.version, "1.0.0")
        XCTAssertEqual(second.version, "2.0.0")
    }

    func testCodexAvailabilityReusesResolvedPathUntilExecutableChanges() async throws {
        let cli = directory.appendingPathComponent("codex")
        func writeVersion(_ version: String) throws {
            try "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli \(version)'; else echo 'Logged in using ChatGPT'; fi\n"
                .write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        try writeVersion("1.0.0")
        let calls = SetupCallRecorder()
        let provider = CodexProvider(maintenanceStore: .init(root: directory.appendingPathComponent("state")),
            resolveForAvailability: { _ in
                await calls.record("resolve")
                return cli.path
            })
        let first = await provider.isAvailable()
        let cached = await provider.isAvailable()
        XCTAssertEqual(first.version, "1.0.0")
        XCTAssertEqual(cached.version, "1.0.0")
        let initialCalls = await calls.all()
        XCTAssertEqual(initialCalls.count, 1)
        try writeVersion("2.0.0")
        let changed = await provider.isAvailable()
        XCTAssertEqual(changed.version, "2.0.0")
        let refreshedCalls = await calls.all()
        XCTAssertEqual(refreshedCalls.count, 2)
        await provider.shutdownAndWaitForTesting()
    }

    @MainActor
    private func waitUntilIdle(_ model: ProviderSetupModel) async throws {
        for _ in 0..<500 {
            if model.activity == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Setup did not become idle")
    }
}
private actor SetupCallRecorder {
    private var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
    func all() -> [String] { calls }
}

final class ProviderSetupTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}
#endif
