#if os(macOS)
import Darwin
import XCTest

@testable import Rubien

/// End-to-end tests for `ClaudeCodeProvider` driving the committed `fake-claude.py`
/// harness (Fixtures/), which speaks the real stream-json + control protocol. The
/// provider's binary path is injected (`executableOverride`) to point at the fake;
/// per-test behavior is a `fake-claude.json` written into the turn's workspace.
///
/// Covers (§7): streaming → events, the approval round-trip, `cancel()` killing the
/// whole process group (grandchild reaped, no orphan), stderr backpressure (no
/// deadlock), non-zero exit → clean notice, and `session_id` re-capture.
final class ClaudeCodeProviderTests: XCTestCase {

    private var workspacesToClean: [URL] = []

    override func setUpWithError() throws {
        // git preserves the +x bit, but ensure the fake is executable regardless.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeCLIPath)
    }

    override func tearDown() {
        for url in workspacesToClean { try? FileManager.default.removeItem(at: url) }
        workspacesToClean.removeAll()
    }

    // MARK: Availability

    func testIsAvailableReportsInstalledVersion() async {
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let availability = await provider.isAvailable()
        XCTAssertTrue(availability.isInstalled)
        XCTAssertTrue(availability.isAuthenticated)
        XCTAssertEqual(availability.version, "9.9.9")
        XCTAssertEqual(availability.resolvedPath, fakeCLIPath)
    }

    func testIsAvailableReportsUnauthenticatedWhenClaudeAuthStatusIsSignedOut() async throws {
        let cli = try makeClaudeAuthProbeCLI(
            authOutput: #"{"loggedIn":false,"authMethod":"none"}"#,
            authExitCode: 1)
        let provider = ClaudeCodeProvider(executableOverride: cli.path)

        let availability = await provider.isAvailable()

        XCTAssertTrue(availability.isInstalled)
        XCTAssertFalse(availability.isAuthenticated)
        XCTAssertEqual(availability.version, "9.9.9")
        XCTAssertEqual(availability.resolvedPath, cli.path)
        XCTAssertEqual(
            availability.unavailableReason,
            "Claude Code is installed but not signed in. Run claude auth login in Terminal, then recheck.")
    }

    func testIsAvailableReportsNotFoundForMissingBinary() async {
        let provider = ClaudeCodeProvider(executableOverride: "/nonexistent/claude-binary")
        let availability = await provider.isAvailable()
        XCTAssertFalse(availability.isInstalled)
        XCTAssertNotNil(availability.unavailableReason)
    }

    func testAuthIsReprobedEachCallSoMidSessionSignOutIsDetected() async throws {
        // A fake claude whose auth status is read from a sentinel file, so the second
        // isAvailable() can observe a different state than the first. Proves auth is NOT
        // cached (only path + version are) — the cached ready result otherwise made
        // Recheck a no-op after a logout / token expiry (#11).
        let workspace = try makeWorkspace()
        let stateFile = workspace.appendingPathComponent("auth-state")
        try "in".write(to: stateFile, atomically: true, encoding: .utf8)
        let cli = workspace.appendingPathComponent("fake-claude-reprobe")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' '9.9.9-fake (Claude Code)'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          if [ "$(cat '\(stateFile.path)')" = "in" ]; then
            printf '%s\\n' '{"loggedIn":true}'
            exit 0
          fi
          printf '%s\\n' '{"loggedIn":false}'
          exit 1
        fi
        exit 0
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let provider = ClaudeCodeProvider(executableOverride: cli.path)
        let first = await provider.isAvailable()
        XCTAssertTrue(first.isReady, "signed in on the first probe")

        try "out".write(to: stateFile, atomically: true, encoding: .utf8)
        let second = await provider.isAvailable()

        XCTAssertTrue(second.isInstalled, "path + version stay resolved (cached)")
        XCTAssertEqual(second.version, "9.9.9", "the cached version is reused")
        XCTAssertFalse(second.isAuthenticated, "auth re-probed → sign-out detected, not the cached ready state")
    }

    // MARK: Streaming

    func testStreamingHappyPathProducesDeltasMessageAndCompletion() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["Hel", "lo"], "assistantText": "Hello"], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        XCTAssertEqual(events.first, .sessionStarted(sessionID: "fake-session-init"))
        XCTAssertTrue(events.contains(.assistantDelta(text: "Hel")))
        XCTAssertTrue(events.contains(.assistantDelta(text: "lo")))
        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "Hello")))
        XCTAssertTrue(events.containsTurnCompleted)
    }

    func testImageAttachmentIsSentBeforePromptAsBase64Content() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "ok"], into: workspace)
        let imageURL = workspace.appendingPathComponent("figure.png")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        try imageData.write(to: imageURL)
        let image = ChatAttachment(
            id: UUID(), displayName: "figure.png", kind: .image,
            stagedURL: imageURL, mediaType: "image/png",
            byteCount: Int64(imageData.count), sourceIdentity: "figure")
        let textURL = workspace.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: textURL)
        let text = ChatAttachment(
            id: UUID(), displayName: "notes.txt", kind: .text,
            stagedURL: textURL, mediaType: "text/plain",
            byteCount: 5, sourceIdentity: "notes")
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        _ = try await collectAllEvents(provider.send(turn: turn(
            workspace: workspace, prompt: "What is shown?", attachments: [image, text])))

        let data = try Data(contentsOf: workspace.appendingPathComponent("fake-claude-user.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, imageData.base64EncodedString())
        XCTAssertEqual(content[1]["text"] as? String, "What is shown?")
    }

    func testUnreadableImageFailsBeforeSpawningClaude() async throws {
        let workspace = try makeWorkspace()
        let missingURL = workspace.appendingPathComponent("missing.png")
        let image = ChatAttachment(
            id: UUID(), displayName: "missing.png", kind: .image,
            stagedURL: missingURL, mediaType: "image/png", byteCount: 4,
            sourceIdentity: "missing")
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        do {
            for try await _ in provider.send(turn: turn(
                workspace: workspace, attachments: [image])) {}
            XCTFail("expected an unreadable attachment error")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .attachmentUnreadable("missing.png"))
            XCTAssertEqual(
                error.localizedDescription,
                "The attachment missing.png could not be read before sending.")
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("fake-claude-argv.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("fake-claude-user.json").path))
    }

    // MARK: MCP content channel (Phase 2b-ii)

    func testContentChannelInjectsMCPConfigIntoSpawnedArgv() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["ok"], "assistantText": "ok"], into: workspace)
        let channel = MCPContentChannel(
            cliURL: URL(fileURLWithPath: "/Applications/Rubien.app/Contents/Helpers/rubien-cli"),
            libraryRoot: URL(fileURLWithPath: "/tmp/lib"))
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath, contentChannel: channel)

        _ = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        // The fake claude recorded the exact argv it was spawned with.
        let argv = try readSpawnedArgv(in: workspace)
        let idx = try XCTUnwrap(argv.firstIndex(of: "--mcp-config"))
        XCTAssertEqual(argv[idx + 1], channel.configArgument())
        XCTAssertTrue(argv.contains("--strict-mcp-config"))
    }

    func testNoContentChannelOmitsMCPConfigFromSpawnedArgv() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["ok"], "assistantText": "ok"], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)  // no channel

        _ = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        let argv = try readSpawnedArgv(in: workspace)
        XCTAssertFalse(argv.contains("--mcp-config"))
        XCTAssertFalse(argv.contains("--strict-mcp-config"))
    }

    private func readSpawnedArgv(in workspace: URL) throws -> [String] {
        let data = try Data(contentsOf: workspace.appendingPathComponent("fake-claude-argv.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
    }

    func testSessionIDRecapturedFromResult() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["sessionInit": "sess-init-xyz", "sessionResult": "sess-rotated-xyz"],
                        into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        let sessionIDs = events.compactMap { event -> String? in
            if case let .sessionStarted(id) = event { return id }
            return nil
        }
        // init id first, then the ROTATED id from `result` (D5 / Risk #5).
        XCTAssertEqual(sessionIDs, ["sess-init-xyz", "sess-rotated-xyz"])
    }

    // MARK: Approval round-trip (control protocol)

    func testApprovalAllowContinuesTurn() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "deltas": ["Working"],
            "approval": ["requestId": "req-xyz", "toolName": "Write", "toolUseId": "toolu_xyz",
                         "input": ["file_path": "note.txt", "content": "hi"], "description": "note.txt"],
            "afterApprovalText": "All done",
        ], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let stream = provider.send(turn: turn(workspace: workspace))

        let events = try await withTimeout(25) { () -> [AgentEvent] in
            var collected: [AgentEvent] = []
            for try await event in stream {
                collected.append(event)
                if case let .approvalRequested(id, _, _) = event {
                    provider.respondToApproval(id: id, .allowOnce)  // writes control_response
                }
            }
            return collected
        }

        XCTAssertTrue(events.contains(
            .approvalRequested(id: "req-xyz", toolName: "Write", summary: "note.txt")))
        // The turn CONTINUED past the approval only because our control_response
        // reached the child's stdin.
        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "All done")))
        XCTAssertTrue(events.containsTurnCompleted)
    }

    func testApprovalDenyBlocksToolAndReportsDenial() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "deltas": ["Working"],
            "approval": ["requestId": "req-deny", "toolName": "Write", "toolUseId": "toolu_deny",
                         "input": ["file_path": "note.txt"], "description": "note.txt"],
            "afterApprovalText": "SHOULD NOT APPEAR",
        ], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let stream = provider.send(turn: turn(workspace: workspace))

        let events = try await withTimeout(25) { () -> [AgentEvent] in
            var collected: [AgentEvent] = []
            for try await event in stream {
                collected.append(event)
                if case let .approvalRequested(id, _, _) = event {
                    provider.respondToApproval(id: id, .deny)
                }
            }
            return collected
        }

        XCTAssertTrue(events.contains(.toolDenied(name: "Write", reason: "Permission denied")))
        XCTAssertFalse(events.contains(.assistantMessageCompleted(text: "SHOULD NOT APPEAR")))
    }

    // MARK: Cancellation → process-group kill

    func testCancelKillsWholeProcessGroupWithNoOrphan() async throws {
        let workspace = try makeWorkspace()
        // A turn that spawns a grandchild and then hangs, never emitting a result.
        try writeConfig(["grandchild": true, "hang": true, "emitResult": false,
                         "deltas": ["streaming…"]], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let stream = provider.send(turn: turn(workspace: workspace))

        let consumer = Task { () -> Void in
            for try await _ in stream {}
        }

        let grandchildPID = try await waitForGrandchildPID(in: workspace, timeout: 12)
        XCTAssertTrue(isAlive(grandchildPID), "grandchild should be alive before cancel")

        provider.cancel()

        // The stream must finish promptly once the group is signalled.
        try await withTimeout(12) { _ = try? await consumer.value }
        // …and the grandchild must be gone — killpg reached the whole tree.
        try await assertEventuallyDead(grandchildPID, timeout: 10)
    }

    func testBreakingStreamTerminatesProcess() async throws {
        // Consuming side stops early (e.g. window closed) → dropping the iterator
        // fires onTermination(.cancelled) → the process group is killed.
        let workspace = try makeWorkspace()
        try writeConfig(["grandchild": true, "hang": true, "emitResult": false], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let stream = provider.send(turn: turn(workspace: workspace))

        let consumer = Task { () -> Void in
            for try await _ in stream {}
        }

        let grandchildPID = try await waitForGrandchildPID(in: workspace, timeout: 12)
        XCTAssertTrue(isAlive(grandchildPID))

        consumer.cancel()  // drop the iterator → stream onTermination → killpg

        try await assertEventuallyDead(grandchildPID, timeout: 10)
    }

    // MARK: One-turn-per-instance lifecycle (A1 / A2)

    func testCancelBeforeTurnRegistersLeavesNoLingeringProcess() async throws {
        // A1: fire send() then cancel IMMEDIATELY, repeatedly, to race the window
        // before `startTurn` registers the turn. A fresh provider each time isolates
        // this from the A2 (overlap) path. A grandchild that spawns must never
        // survive — the pre-register bug would leak one (cancel no-ops, then
        // `startTurn` spawns something nothing kills).
        var workspaces: [URL] = []
        for _ in 0..<20 {
            let workspace = try makeWorkspace()
            workspaces.append(workspace)
            try writeConfig(["grandchild": true, "hang": true, "emitResult": false], into: workspace)
            let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
            let stream = provider.send(turn: turn(workspace: workspace))
            let consumer = Task { () -> Void in for try await _ in stream {} }
            consumer.cancel()
        }
        // Event-driven: poll until no workspace holds a LIVING grandchild (bounded).
        func livingGrandchildren() -> [pid_t] {
            workspaces.compactMap { try? readGrandchildPID(in: $0) }.filter { isAlive($0) }
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !livingGrandchildren().isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(livingGrandchildren().isEmpty,
                      "cancel-before-register leaked live processes: \(livingGrandchildren())")
    }

    func testSecondTurnFinalizesAnUnfinishedFirstTurn() async throws {
        // A2: one conversation per instance. Turn 1 hangs (never finishes on its own);
        // starting turn 2 on the SAME provider must finalize turn 1 (kill its group,
        // finish its stream) rather than orphan it, and run turn 2 cleanly.
        let workspace1 = try makeWorkspace()
        try writeConfig(["grandchild": true, "hang": true, "emitResult": false], into: workspace1)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let stream1 = provider.send(turn: turn(workspace: workspace1))
        let consumer1 = Task { () -> Void in for try await _ in stream1 {} }

        let grandchildPID = try await waitForGrandchildPID(in: workspace1, timeout: 12)
        XCTAssertTrue(isAlive(grandchildPID))

        let workspace2 = try makeWorkspace()
        try writeConfig(["deltas": ["second"], "assistantText": "second answer"], into: workspace2)
        let events2 = try await collectAllEvents(provider.send(turn: turn(workspace: workspace2)))

        XCTAssertTrue(events2.contains(.assistantMessageCompleted(text: "second answer")))
        XCTAssertTrue(events2.containsTurnCompleted)
        // Turn 1 was finalized, not orphaned: its stream ended and its group died.
        try await withTimeout(12) { _ = try? await consumer1.value }
        try await assertEventuallyDead(grandchildPID, timeout: 10)
    }

    func testTwoSequentialTurnsOnOneProviderBothComplete() async throws {
        // Normal reuse: turn 1 fully finalizes (current cleared) before turn 2 starts,
        // so turn 2 is NOT treated as an overlap — both complete cleanly.
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        let workspace1 = try makeWorkspace()
        try writeConfig(["assistantText": "first"], into: workspace1)
        let events1 = try await collectAllEvents(provider.send(turn: turn(workspace: workspace1)))
        XCTAssertTrue(events1.contains(.assistantMessageCompleted(text: "first")))
        XCTAssertTrue(events1.containsTurnCompleted)

        let workspace2 = try makeWorkspace()
        try writeConfig(["assistantText": "second"], into: workspace2)
        let events2 = try await collectAllEvents(provider.send(turn: turn(workspace: workspace2)))
        XCTAssertTrue(events2.contains(.assistantMessageCompleted(text: "second")))
        XCTAssertTrue(events2.containsTurnCompleted)
    }

    // MARK: stderr backpressure

    func testStderrFloodDoesNotDeadlock() async throws {
        let workspace = try makeWorkspace()
        // Flood stderr before the result: a provider that didn't drain stderr on an
        // independent task would block the child's stderr write and never see the
        // result → this would time out.
        try writeConfig(["floodStderr": 400_000, "deltas": ["ok"]], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        XCTAssertTrue(events.containsTurnCompleted)
    }

    // MARK: Error exit

    func testNonZeroExitSurfacesCleanNoticeAndFinishes() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["emitResult": false, "exitCode": 3, "deltas": ["partial"]], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        // A clean notice (not a thrown error / not a completion).
        XCTAssertTrue(events.contains { if case .providerNotice = $0 { return true }; return false })
        XCTAssertFalse(events.containsTurnCompleted)
    }

    func testFailureNoticeCarriesStderrTail() async throws {
        // A5: the stderr drain may still be catching up at exit; the failure notice
        // must wait for its EOF and include the real error message.
        let workspace = try makeWorkspace()
        try writeConfig(
            ["emitResult": false, "exitCode": 3, "deltas": ["x"],
             "stderrMessage": "AUTH_ERROR_XYZZY_9f2c"], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        let notice = events.compactMap { event -> String? in
            if case let .providerNotice(message) = event { return message }
            return nil
        }.first
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.contains("AUTH_ERROR_XYZZY_9f2c") == true,
                      "failure notice must carry the stderr tail; got: \(notice ?? "nil")")
    }

    func testSpawnFailureThrowsExecutableNotFound() async {
        let workspace = (try? makeWorkspace()) ?? FileManager.default.temporaryDirectory
        let provider = ClaudeCodeProvider(executableOverride: "/nonexistent/claude-binary")
        do {
            for try await _ in provider.send(turn: turn(workspace: workspace)) {}
            XCTFail("expected the stream to throw for a missing binary")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .executableNotFound("/nonexistent/claude-binary"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Seed / flags plumbing (pure, no spawn)

    func testBuildArgumentsIncludesSeedResumeAndWebToggle() {
        let request = AgentTurnRequest(
            workspaceURL: URL(fileURLWithPath: "/ws"), resumeSessionID: "sess-42",
            prompt: "hi", seed: "You are discussing reference ID 7.",
            webAccess: false, codexSandbox: .readOnly, modelOverride: "claude-x",
            effortOverride: "high")
        let args = ClaudeCLIInvocation.arguments(for: request)

        XCTAssertTrue(args.containsPair("--input-format", "stream-json"))
        XCTAssertTrue(args.containsPair("--output-format", "stream-json"))
        XCTAssertTrue(args.contains("--include-partial-messages"))
        XCTAssertTrue(args.containsPair("--permission-prompt-tool", "stdio"))
        XCTAssertTrue(args.containsPair("--setting-sources", ""))
        XCTAssertTrue(args.containsPair("--resume", "sess-42"))
        XCTAssertTrue(args.containsPair("--append-system-prompt", "You are discussing reference ID 7."))
        XCTAssertTrue(args.containsPair("--model", "claude-x"))
        XCTAssertTrue(args.containsPair("--effort", "high"))
        XCTAssertTrue(args.containsPair("--disallowedTools", "WebFetch WebSearch"))
        // No content channel injected in this request (see MCPContentChannelTests
        // for the wired case).
        XCTAssertFalse(args.contains("--mcp-config"))
    }

    func testBuildArgumentsOmitsOptionalFlagsWhenAbsent() {
        let request = AgentTurnRequest(
            workspaceURL: URL(fileURLWithPath: "/ws"), prompt: "hi", webAccess: true)
        let args = ClaudeCLIInvocation.arguments(for: request)
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertFalse(args.contains("--append-system-prompt"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("--effort"))
        XCTAssertFalse(args.contains("--disallowedTools"))  // web access on
    }

    func testMinimalEnvironmentIsAllowlistedAndNeverLeaksAppEnv() {
        let env = ClaudeCLIInvocation.environment(binaryDirectory: "/opt/homebrew/bin")
        XCTAssertEqual(env["TERM"], "dumb")
        XCTAssertEqual(env["NO_COLOR"], "1")
        XCTAssertEqual(env["FORCE_COLOR"], "0")
        XCTAssertEqual(env["CLAUDE_CODE_ENTRYPOINT"], "rubien-assistant")
        // Binary dir first, then the standard interpreter/tool dirs (deduped) — a Node
        // CLI like codex needs `node` resolvable even when it isn't beside the binary.
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        // Secrets a GUI app may carry must never be forwarded.
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["GITHUB_TOKEN"])
        XCTAssertNil(env["SSH_AUTH_SOCK"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
    }

    // MARK: - Helpers

    private var fakeCLIPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-claude.py")
            .path
    }

    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspacesToClean.append(dir)
        return dir
    }

    private func writeConfig(_ config: [String: Any], into workspace: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: workspace.appendingPathComponent("fake-claude.json"))
    }

    private func makeClaudeAuthProbeCLI(authOutput: String, authExitCode: Int) throws -> URL {
        let workspace = try makeWorkspace()
        let cli = workspace.appendingPathComponent("fake-claude-auth")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' '9.9.9-fake (Claude Code)'
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          cat <<'JSON'
        \(authOutput)
        JSON
          exit \(authExitCode)
        fi
        exit 0
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli
    }

    private func turn(
        workspace: URL, prompt: String = "hello", attachments: [ChatAttachment] = []
    ) -> AgentTurnRequest {
        AgentTurnRequest(workspaceURL: workspace, prompt: prompt, attachments: attachments)
    }

    private func readGrandchildPID(in workspace: URL) throws -> pid_t {
        let text = try String(
            contentsOf: workspace.appendingPathComponent("grandchild.pid"), encoding: .utf8)
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TestTimeout()
        }
        return pid
    }

    private func waitForGrandchildPID(in workspace: URL, timeout: TimeInterval) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = try? readGrandchildPID(in: workspace) { return pid }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TestTimeout()
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func assertEventuallyDead(_ pid: pid_t, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("process \(pid) still alive after \(timeout)s — process-group kill leaked an orphan")
    }

    private func collectAllEvents(
        _ stream: AsyncThrowingStream<AgentEvent, Error>, timeout: TimeInterval = 25
    ) async throws -> [AgentEvent] {
        try await withTimeout(timeout) {
            var events: [AgentEvent] = []
            for try await event in stream { events.append(event) }
            return events
        }
    }
}

// MARK: - Test utilities

private struct TestTimeout: Error {}

/// Race an async operation against a timeout so a wedged turn fails fast (and its
/// stream is cancelled → the process group killed) rather than hanging the suite.
private func withTimeout<Value: Sendable>(
    _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeout()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private extension Array where Element == AgentEvent {
    var containsTurnCompleted: Bool {
        contains { if case .turnCompleted = $0 { return true }; return false }
    }
}

private extension Array where Element == String {
    /// True when `flag` appears immediately followed by `value` (an argv `--k v` pair).
    func containsPair(_ flag: String, _ value: String) -> Bool {
        for index in indices.dropLast() where self[index] == flag && self[index + 1] == value {
            return true
        }
        return false
    }
}
#endif
