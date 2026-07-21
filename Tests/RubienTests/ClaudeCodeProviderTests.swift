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

    func testUserToolsOptInReachesSpawnedClaudeInvocation() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["ok"], "assistantText": "ok"], into: workspace)
        let channel = MCPContentChannel(
            cliURL: URL(fileURLWithPath: "/Applications/Rubien.app/Contents/Helpers/rubien-cli"),
            libraryRoot: URL(fileURLWithPath: "/tmp/lib"))
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath, contentChannel: channel)
        let request = AgentTurnRequest(
            workspaceURL: workspace, prompt: "hello", loadUserTools: true)

        _ = try await collectAllEvents(provider.send(turn: request))

        let argv = try readSpawnedArgv(in: workspace)
        XCTAssertTrue(argv.contains("--mcp-config"))
        XCTAssertFalse(argv.contains("--strict-mcp-config"))
        XCTAssertFalse(argv.contains("--setting-sources"))
        XCTAssertTrue(argv.containsPair("--permission-prompt-tool", "stdio"))
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

    private func readSpawnRecords(in workspace: URL) throws -> [[String: Any]] {
        let text = try String(
            contentsOf: workspace.appendingPathComponent("fake-claude-spawns.jsonl"),
            encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
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

    func testRubienMCPApprovalAllowContinuesTurnAndMutatesExactlyOnce() async throws {
        let workspace = try makeWorkspace()
        let libraryRoot = workspace.appendingPathComponent("library")
        try writeConfig([
            "deltas": ["Working"],
            "approval": [
                "requestId": "req-xyz",
                "toolName": "mcp__rubien__rubien_create_reference",
                "toolUseId": "toolu_xyz",
                "input": ["title": "Claude Approved"],
                "description": "Create reference Claude Approved",
                "mutation": referenceMutation(
                    title: "Claude Approved",
                    libraryRoot: libraryRoot
                ),
            ],
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

        XCTAssertTrue(events.contains(.approvalRequested(
            id: "req-xyz",
            toolName: "mcp__rubien__rubien_create_reference",
            summary: "Create reference Claude Approved"
        )))
        // The turn CONTINUED past the approval only because our control_response
        // reached the child's stdin.
        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "All done")))
        XCTAssertTrue(events.containsTurnCompleted)
        XCTAssertEqual(try referenceTitles(libraryRoot: libraryRoot), ["Claude Approved"])
    }

    func testRubienMCPApprovalDenyBlocksToolWithoutMutation() async throws {
        let workspace = try makeWorkspace()
        let libraryRoot = workspace.appendingPathComponent("library")
        try writeConfig([
            "deltas": ["Working"],
            "approval": [
                "requestId": "req-deny",
                "toolName": "mcp__rubien__rubien_create_reference",
                "toolUseId": "toolu_deny",
                "input": ["title": "Must Not Exist"],
                "description": "Create reference Must Not Exist",
                "mutation": referenceMutation(
                    title: "Must Not Exist",
                    libraryRoot: libraryRoot
                ),
            ],
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

        XCTAssertTrue(events.contains(.toolDenied(
            name: "mcp__rubien__rubien_create_reference",
            reason: "Permission denied"
        )))
        XCTAssertFalse(events.contains(.assistantMessageCompleted(text: "SHOULD NOT APPEAR")))
        XCTAssertEqual(try referenceTitles(libraryRoot: libraryRoot), [])
    }

    func testReadOnlyApprovalIsAnsweredAtProviderBoundary() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "approval": [
                "requestId": "req-read",
                "toolName": "mcp__rubien__rubien_read_text",
                "toolUseId": "toolu_read",
                "input": ["id": 1690, "pages": "1-2"],
                "description": "Read pages 1-2",
            ],
            "afterApprovalText": "Read completed",
        ], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)

        let events = try await withTimeout(25) {
            try await self.collectAllEvents(provider.send(turn: self.turn(workspace: workspace)))
        }

        XCTAssertFalse(events.contains { event in
            if case .approvalRequested = event { return true }
            return false
        })
        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "Read completed")))
        XCTAssertTrue(events.containsTurnCompleted)
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
        let interrupt = try await waitForFile(
            named: "fake-claude-interrupt.json", in: workspace, timeout: 3)
        let interruptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: interrupt) as? [String: Any])
        XCTAssertEqual(
            (interruptObject["request"] as? [String: Any])?["subtype"] as? String,
            "interrupt",
            "native interruption must precede the signal fallback")
        // …and the grandchild must be gone — killpg reached the whole tree.
        try await assertEventuallyDead(grandchildPID, timeout: 10)
    }

    func testNativeInterruptHandsRotatedSessionToSameConversationSuccessor() async throws {
        let workspace = try makeWorkspace()
        let conversationID = UUID()
        try writeConfig([
            "hang": true,
            "emitResult": false,
            "cooperativeInterrupt": true,
            "sessionInit": "session-before-interrupt",
            "sessionResult": "session-after-interrupt",
            "delayInterruptResultMs": 150,
        ], into: workspace)
        let provider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath,
            leaseCoordinator: ClaudeSessionLeaseCoordinator())
        let first = provider.send(turn: turn(
            workspace: workspace, conversationID: conversationID))
        let firstConsumer = Task { () -> Void in for try await _ in first {} }
        _ = try await waitForFile(
            named: "fake-claude-user.json", in: workspace, timeout: 12)

        // Match controller Steer: cancel the consumed stream, then immediately
        // submit a successor carrying the same stable Rubien conversation UUID.
        firstConsumer.cancel()
        try writeConfig([
            "deltas": ["continued"],
            "assistantText": "continued after interrupt",
            "sessionResult": "session-successor-result",
        ], into: workspace)
        let successor = provider.send(turn: turn(
            workspace: workspace,
            prompt: "steered prompt",
            conversationID: conversationID,
            resumeSessionID: "session-before-interrupt"))

        let events = try await collectAllEvents(successor, timeout: 12)
        XCTAssertTrue(events.contains(
            .assistantMessageCompleted(text: "continued after interrupt")))
        let interruptData = try Data(contentsOf: workspace.appendingPathComponent(
            "fake-claude-interrupt.json"))
        let interrupt = try XCTUnwrap(
            JSONSerialization.jsonObject(with: interruptData) as? [String: Any])
        XCTAssertEqual(interrupt["type"] as? String, "control_request")
        XCTAssertEqual(
            (interrupt["request"] as? [String: Any])?["subtype"] as? String,
            "interrupt")

        let argv = try readSpawnedArgv(in: workspace)
        let resumeIndex = try XCTUnwrap(argv.firstIndex(of: "--resume"))
        XCTAssertEqual(argv[resumeIndex + 1], "session-after-interrupt")
        _ = try? await firstConsumer.value
    }

    func testExplicitCancelSnapshotsOldTokenBeforeImmediateSend() async throws {
        let workspace = try makeWorkspace()
        let conversationID = UUID()
        try writeConfig([
            "hang": true,
            "emitResult": false,
            "cooperativeInterrupt": true,
            "sessionResult": "explicit-cancel-rotated",
        ], into: workspace)
        let provider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath,
            leaseCoordinator: ClaudeSessionLeaseCoordinator())
        let first = provider.send(turn: turn(
            workspace: workspace, conversationID: conversationID))
        let firstConsumer = Task { () -> Void in for try await _ in first {} }
        _ = try await waitForFile(
            named: "fake-claude-user.json", in: workspace, timeout: 12)

        // `cancel()` is synchronous at the API boundary: it captures the old
        // token before this immediately following send publishes its token.
        provider.cancel()
        try writeConfig(["assistantText": "survived scoped cancel"], into: workspace)
        let successor = provider.send(turn: turn(
            workspace: workspace,
            prompt: "next",
            conversationID: conversationID,
            resumeSessionID: "fake-session-init"))
        let events = try await collectAllEvents(successor, timeout: 12)

        XCTAssertTrue(events.contains(
            .assistantMessageCompleted(text: "survived scoped cancel")))
        let argv = try readSpawnedArgv(in: workspace)
        let resumeIndex = try XCTUnwrap(argv.firstIndex(of: "--resume"))
        XCTAssertEqual(argv[resumeIndex + 1], "explicit-cancel-rotated")
        _ = try? await firstConsumer.value
    }

    func testRepeatedSteerWhileRetiringSpawnsOnlyLatestPendingTurn() async throws {
        let workspace = try makeWorkspace()
        let conversationID = UUID()
        try writeConfig([
            "hang": true,
            "emitResult": false,
            "cooperativeInterrupt": true,
            "delayInterruptResultMs": 200,
            "sessionResult": "rapid-steer-rotated",
        ], into: workspace)
        let provider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath,
            leaseCoordinator: ClaudeSessionLeaseCoordinator())
        let first = provider.send(turn: turn(
            workspace: workspace, conversationID: conversationID))
        let firstConsumer = Task { () -> Void in for try await _ in first {} }
        _ = try await waitForFile(
            named: "fake-claude-user.json", in: workspace, timeout: 12)

        firstConsumer.cancel()
        try writeConfig(["assistantText": "superseded pending"], into: workspace)
        let second = provider.send(turn: turn(
            workspace: workspace,
            prompt: "second",
            conversationID: conversationID,
            resumeSessionID: "fake-session-init"))
        let secondTask = Task { try await self.collectAllEvents(second, timeout: 12) }

        try writeConfig(["assistantText": "latest pending"], into: workspace)
        let third = provider.send(turn: turn(
            workspace: workspace,
            prompt: "third",
            conversationID: conversationID,
            resumeSessionID: "fake-session-init"))
        let thirdEvents = try await collectAllEvents(third, timeout: 12)

        let secondEvents = try await secondTask.value
        XCTAssertTrue(secondEvents.isEmpty)
        XCTAssertTrue(thirdEvents.contains(
            .assistantMessageCompleted(text: "latest pending")))
        XCTAssertEqual(try readSpawnRecords(in: workspace).count, 2)
        let argv = try readSpawnedArgv(in: workspace)
        let resumeIndex = try XCTUnwrap(argv.firstIndex(of: "--resume"))
        XCTAssertEqual(argv[resumeIndex + 1], "rapid-steer-rotated")
        _ = try? await firstConsumer.value
    }

    func testCancellationCannotWedgeBehindFullStdinPipe() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "stdinBackpressure": true,
            "emitResult": false,
        ], into: workspace)
        let provider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath,
            leaseCoordinator: ClaudeSessionLeaseCoordinator())
        let stream = provider.send(turn: turn(
            workspace: workspace,
            prompt: String(repeating: "large-prompt-", count: 200_000),
            conversationID: UUID()))
        let consumer = Task { () -> Void in for try await _ in stream {} }
        let leaderPID = try await waitForPID(
            named: "stdin-backpressure.pid", in: workspace, timeout: 12)

        provider.cancel()

        try await withTimeout(5) { _ = try? await consumer.value }
        try await assertEventuallyDead(leaderPID, timeout: 8)
    }

    func testNewConversationDoesNotInheritInterruptedRotatedSession() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "hang": true,
            "emitResult": false,
            "cooperativeInterrupt": true,
            "sessionResult": "must-not-leak",
        ], into: workspace)
        let provider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath,
            leaseCoordinator: ClaudeSessionLeaseCoordinator())
        let first = provider.send(turn: turn(
            workspace: workspace, conversationID: UUID()))
        let firstConsumer = Task { () -> Void in for try await _ in first {} }
        _ = try await waitForFile(
            named: "fake-claude-user.json", in: workspace, timeout: 12)

        firstConsumer.cancel()
        try writeConfig(["assistantText": "fresh"], into: workspace)
        let fresh = provider.send(turn: turn(
            workspace: workspace, prompt: "new conversation", conversationID: UUID()))
        let events = try await collectAllEvents(fresh, timeout: 12)

        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "fresh")))
        XCTAssertFalse(try readSpawnedArgv(in: workspace).contains("--resume"))
        _ = try? await firstConsumer.value
    }

    func testProcessWideLeaseBlocksSecondProviderUntilInterruptedLeaderIsReaped() async throws {
        let workspace = try makeWorkspace()
        let conversationID = UUID()
        let coordinator = ClaudeSessionLeaseCoordinator()
        try writeConfig([
            "hang": true,
            "emitResult": false,
            "cooperativeInterrupt": true,
            "sessionInit": "shared-before",
            "sessionResult": "shared-after",
            "delayInterruptResultMs": 350,
        ], into: workspace)
        let firstProvider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath, leaseCoordinator: coordinator)
        let secondProvider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath, leaseCoordinator: coordinator)
        let first = firstProvider.send(turn: turn(
            workspace: workspace,
            conversationID: conversationID,
            resumeSessionID: "shared-before"))
        let firstConsumer = Task { () -> Void in for try await _ in first {} }
        _ = try await waitForFile(
            named: "fake-claude-user.json", in: workspace, timeout: 12)

        firstConsumer.cancel()
        try writeConfig(["assistantText": "second window"], into: workspace)
        let secondTask = Task { try await self.collectAllEvents(
            secondProvider.send(turn: self.turn(
                workspace: workspace,
                conversationID: conversationID,
                resumeSessionID: "shared-before")),
            timeout: 12)
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(
            try readSpawnRecords(in: workspace).count, 1,
            "the second provider must wait while the old session process owns its lease")

        let events = try await secondTask.value
        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "second window")))
        XCTAssertEqual(try readSpawnRecords(in: workspace).count, 2)
        let argv = try readSpawnedArgv(in: workspace)
        let resumeIndex = try XCTUnwrap(argv.firstIndex(of: "--resume"))
        XCTAssertEqual(argv[resumeIndex + 1], "shared-after")
        _ = try? await firstConsumer.value
    }

    func testFreshInitAliasJoinsLiveProcessWideLeaseBeforeUIExposesIt() async throws {
        let workspace = try makeWorkspace()
        let coordinator = ClaudeSessionLeaseCoordinator()
        try writeConfig([
            "hang": true,
            "emitResult": false,
            "cooperativeInterrupt": true,
            "sessionInit": "fresh-live-alias",
            "sessionResult": "fresh-rotated-alias",
        ], into: workspace)
        let firstProvider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath, leaseCoordinator: coordinator)
        let secondProvider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath, leaseCoordinator: coordinator)
        let initSeen = expectation(description: "fresh init alias exposed")
        let first = firstProvider.send(turn: turn(
            workspace: workspace, conversationID: UUID()))
        let firstConsumer = Task { () -> Void in
            for try await event in first {
                if event == .sessionStarted(sessionID: "fresh-live-alias") {
                    initSeen.fulfill()
                }
            }
        }
        // This assertion starts only after the fake CLI publishes its init alias;
        // process-heavy full-suite runs can delay the Python harness itself well
        // beyond its normal subsecond startup. The behavior under test is lease
        // publication ordering, not interpreter launch latency.
        await fulfillment(of: [initSeen], timeout: 30)

        // A second window can act on the visible init id immediately, but alias
        // publication must already point it at the first process's held lease.
        let secondTask = Task { try await self.collectAllEvents(
            secondProvider.send(turn: self.turn(
                workspace: workspace,
                conversationID: UUID(),
                resumeSessionID: "fresh-live-alias")),
            timeout: 30)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(try readSpawnRecords(in: workspace).count, 1)

        try writeConfig(["assistantText": "after fresh alias wait"], into: workspace)
        firstConsumer.cancel()
        let events = try await secondTask.value
        XCTAssertTrue(events.contains(
            .assistantMessageCompleted(text: "after fresh alias wait")))
        let argv = try readSpawnedArgv(in: workspace)
        let resumeIndex = try XCTUnwrap(argv.firstIndex(of: "--resume"))
        XCTAssertEqual(argv[resumeIndex + 1], "fresh-rotated-alias")
        _ = try? await firstConsumer.value
    }

    func testShutdownIsTerminalKillsAndReapsLeaderAndRejectsLaterSend() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "hang": true,
            "emitResult": false,
        ], into: workspace)
        let provider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath,
            leaseCoordinator: ClaudeSessionLeaseCoordinator())
        let stream = provider.send(turn: turn(
            workspace: workspace, conversationID: UUID()))
        let consumer = Task { () -> Void in for try await _ in stream {} }
        _ = try await waitForFile(
            named: "fake-claude-user.json", in: workspace, timeout: 12)
        let record = try XCTUnwrap(readSpawnRecords(in: workspace).first)
        let leaderPID = try XCTUnwrap((record["pid"] as? NSNumber)?.int32Value)

        provider.shutdown()
        try await withTimeout(8) { _ = try? await consumer.value }
        try await assertEventuallyDead(leaderPID, timeout: 8)

        let afterShutdown = provider.send(turn: turn(
            workspace: workspace, prompt: "must not spawn", conversationID: UUID()))
        let afterShutdownEvents = try await collectAllEvents(afterShutdown, timeout: 2)
        XCTAssertTrue(afterShutdownEvents.isEmpty)
        XCTAssertEqual(try readSpawnRecords(in: workspace).count, 1)
    }

    func testConsumerCancellationFinishesStreamAndAllowsImmediateSuccessorWhenDetachedHelperKeepsOutputPipeOpen() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "escapedOutputHolder": true,
            "hang": true,
            "emitResult": false,
        ], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let stream = provider.send(turn: turn(workspace: workspace))
        let streamFinished = expectation(description: "cancelled stream finished")
        let consumer = Task { () -> Void in
            for try await _ in stream {}
            streamFinished.fulfill()
        }

        let holderPID = try await waitForPID(
            named: "escaped-output-holder.pid", in: workspace, timeout: 12)
        defer {
            consumer.cancel()
            _ = kill(holderPID, SIGKILL)
        }
        XCTAssertTrue(isAlive(holderPID))

        // Match the UI's interrupt-and-steer path: cancelling the consumer triggers
        // token-scoped termination, then the queued prompt starts immediately. The
        // late cancellation callback for the retired token must not touch its successor.
        try writeConfig([
            "deltas": ["successor"],
            "assistantText": "successor",
        ], into: workspace)
        consumer.cancel()
        let successor = provider.send(turn: turn(workspace: workspace, prompt: "steered prompt"))

        await fulfillment(of: [streamFinished], timeout: 8)
        let successorEvents = try await collectAllEvents(successor, timeout: 12)
        XCTAssertTrue(successorEvents.contains(.assistantMessageCompleted(text: "successor")))
        XCTAssertTrue(successorEvents.containsTurnCompleted)
        let pipeState = try await probeEscapedOutputHandles(in: workspace, timeout: 3)
        XCTAssertEqual(pipeState, "closed,closed")
        XCTAssertTrue(
            isAlive(holderPID),
            "the detached helper proves EOF did not finish the stream; the cancel watchdog did")
    }

    func testResultFinishesStreamWhenDetachedHelperKeepsOutputPipeOpen() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["escapedOutputHolder": true], into: workspace)
        let provider = ClaudeCodeProvider(executableOverride: fakeCLIPath)
        let stream = provider.send(turn: turn(workspace: workspace))
        let streamFinished = expectation(description: "completed stream finished")
        let consumer = Task { () -> Void in
            for try await _ in stream {}
            streamFinished.fulfill()
        }

        let holderPID = try await waitForPID(
            named: "escaped-output-holder.pid", in: workspace, timeout: 12)
        defer {
            consumer.cancel()
            _ = kill(holderPID, SIGKILL)
        }

        await fulfillment(of: [streamFinished], timeout: 12)
        let pipeState = try await probeEscapedOutputHandles(in: workspace, timeout: 3)
        XCTAssertEqual(pipeState, "closed,closed")
        XCTAssertTrue(isAlive(holderPID))
    }

    func testTerminalResultAfterLeaderExitStillRotatesAndCompletes() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "emitResult": false,
            "detachedResultDelayMs": 1_100,
            "sessionResult": "rotated-after-leader-exit",
            "assistantText": "late terminal result",
        ], into: workspace)
        let provider = ClaudeCodeProvider(
            executableOverride: fakeCLIPath,
            leaseCoordinator: ClaudeSessionLeaseCoordinator())

        let events = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace, conversationID: UUID())),
            timeout: 8)

        XCTAssertTrue(events.contains(.sessionStarted(
            sessionID: "rotated-after-leader-exit")))
        XCTAssertTrue(events.containsTurnCompleted)
        XCTAssertFalse(events.contains { event in
            if case .providerNotice = event { return true }
            return false
        })
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

    func testNewerPreStartCancellationMakesOlderDelayedStartStale() async throws {
        let engine = ClaudeTurnEngine(
            leaseCoordinator: ClaudeSessionLeaseCoordinator())
        let olderToken = UUID()
        let newerToken = UUID()
        let (olderStream, olderContinuation) = makeEventStream()
        let (newerStream, newerContinuation) = makeEventStream()
        let request = turn(workspace: try makeWorkspace(), conversationID: UUID())

        // Deterministic actor order: cancellation #2 arrives before delayed starts
        // #1 and #2. Neither request may reach lease acquisition or spawn.
        await engine.cancelIfCurrent(token: newerToken, sequence: 2)
        await engine.startTurn(
            token: olderToken, sequence: 1, request: request,
            executableOverride: fakeCLIPath, mcpConfig: nil,
            continuation: olderContinuation)
        await engine.startTurn(
            token: newerToken, sequence: 2, request: request,
            executableOverride: fakeCLIPath, mcpConfig: nil,
            continuation: newerContinuation)

        let olderEvents = try await collectAllEvents(olderStream, timeout: 2)
        let newerEvents = try await collectAllEvents(newerStream, timeout: 2)
        XCTAssertTrue(olderEvents.isEmpty)
        XCTAssertTrue(newerEvents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: request.workspaceURL.appendingPathComponent(
                "fake-claude-spawns.jsonl").path))
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
        XCTAssertTrue(args.contains("--print"), "stream-json input requires print mode")

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

    func testScheduledArgumentsPinDefaultPermissionMode() {
        let request = AgentTurnRequest(
            workspaceURL: URL(fileURLWithPath: "/ws"),
            prompt: "scheduled",
            executionMode: .scheduled
        )
        let args = ClaudeCLIInvocation.arguments(for: request)
        XCTAssertTrue(args.containsPair("--permission-mode", "default"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
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

    private var rubienCLIBinaryPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/rubien-cli")
            .path
    }

    private func referenceMutation(title: String, libraryRoot: URL) -> [String: Any] {
        [
            "executable": rubienCLIBinaryPath,
            "arguments": ["add", "--title", title],
            "environment": ["RUBIEN_LIBRARY_ROOT": libraryRoot.path],
        ]
    }

    private func referenceTitles(libraryRoot: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rubienCLIBinaryPath)
        process.arguments = ["list"]
        var environment = ProcessInfo.processInfo.environment
        environment["RUBIEN_LIBRARY_ROOT"] = libraryRoot.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return rows.compactMap { $0["title"] as? String }
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
        workspace: URL,
        prompt: String = "hello",
        conversationID: UUID? = nil,
        resumeSessionID: String? = nil,
        attachments: [ChatAttachment] = []
    ) -> AgentTurnRequest {
        AgentTurnRequest(
            workspaceURL: workspace,
            conversationID: conversationID,
            resumeSessionID: resumeSessionID,
            prompt: prompt,
            attachments: attachments)
    }

    private func waitForFile(
        named filename: String, in workspace: URL, timeout: TimeInterval
    ) async throws -> Data {
        let url = workspace.appendingPathComponent(filename)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TestTimeout()
    }

    private func makeEventStream() -> (
        AsyncThrowingStream<AgentEvent, Error>,
        AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        var captured: AsyncThrowingStream<AgentEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<AgentEvent, Error> { captured = $0 }
        return (stream, captured)
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
        try await waitForPID(named: "grandchild.pid", in: workspace, timeout: timeout)
    }

    private func waitForPID(
        named filename: String, in workspace: URL, timeout: TimeInterval
    ) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(
                contentsOf: workspace.appendingPathComponent(filename), encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TestTimeout()
    }

    private func probeEscapedOutputHandles(
        in workspace: URL, timeout: TimeInterval
    ) async throws -> String {
        try Data().write(to: workspace.appendingPathComponent("probe-output-pipes"))
        let resultURL = workspace.appendingPathComponent("escaped-output-holder-result")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? String(contentsOf: resultURL, encoding: .utf8),
               !result.isEmpty {
                return result
            }
            try await Task.sleep(nanoseconds: 50_000_000)
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
