#if os(macOS)
import Darwin
import XCTest

@testable import Rubien

/// End-to-end tests for `CodexProvider` driving the committed
/// `fake-codex-app-server.py` harness (Fixtures/), which speaks the v2 JSON-RPC
/// thread/turn/item protocol like the real `codex app-server`. The binary path is
/// injected (`executableOverride`); per-turn behavior is a `fake-codex.json` in the
/// turn's workspace; the fake records what it observed into
/// `fake-codex-observed.json` (thread/turn counts, the approval decision + response
/// id TYPE, interrupts, its pid).
///
/// Covers (Phase-3b §7): the handshake + streamed turn, server/thread REUSE across
/// turns, the approval round-trip (verbatim numeric id + deny→cancel fallback), the
/// unknown-server-request reply (no wedge), stop = turn/interrupt with the server
/// surviving (review #5), stream-drop = interrupt, crash → notice → respawn, and
/// shutdown killing the server tree.
final class CodexProviderTests: XCTestCase {

    private var workspacesToClean: [URL] = []

    override func setUpWithError() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeServerPath)
    }

    override func tearDown() {
        for url in workspacesToClean { try? FileManager.default.removeItem(at: url) }
        workspacesToClean.removeAll()
    }

    // MARK: Availability

    func testIsAvailableReportsInstalledVersion() async {
        let provider = CodexProvider(executableOverride: fakeServerPath)
        let availability = await provider.isAvailable()
        XCTAssertTrue(availability.isInstalled)
        XCTAssertEqual(availability.version, "0.142.5")
        XCTAssertEqual(availability.resolvedPath, fakeServerPath)
    }

    func testIsAvailableReportsNotFoundForMissingBinary() async {
        let provider = CodexProvider(executableOverride: "/nonexistent/codex-binary")
        let availability = await provider.isAvailable()
        XCTAssertFalse(availability.isInstalled)
        XCTAssertNotNil(availability.unavailableReason)
    }

    // MARK: Streaming happy path

    func testStreamingHappyPathProducesEvents() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["Hel", "lo"], "assistantText": "Hello"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        XCTAssertTrue(events.contains(.sessionStarted(sessionID: "TH-1")))
        XCTAssertTrue(events.contains(.assistantDelta(text: "Hel")))
        XCTAssertTrue(events.contains(.assistantDelta(text: "lo")))
        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "Hello")))
        guard case .turnCompleted(let usage)? = events.last else {
            return XCTFail("expected turnCompleted last, got \(String(describing: events.last))")
        }
        XCTAssertEqual(usage?.inputTokens, 100)
        XCTAssertEqual(usage?.outputTokens, 5)
        XCTAssertEqual(usage?.cacheReadTokens, 20)
    }

    // MARK: Invocation (argv injection)

    func testArgvCarriesDisableAppsAndRubienInjection() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "ok"], into: workspace)
        let channel = MCPContentChannel(
            cliURL: URL(fileURLWithPath: "/Applications/Rubien.app/Contents/Helpers/rubien-cli"),
            libraryRoot: URL(fileURLWithPath: "/tmp/lib"))
        let provider = CodexProvider(executableOverride: fakeServerPath, contentChannel: channel)
        defer { provider.shutdown() }

        _ = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        let argv = try readSpawnedArgv(in: workspace)
        XCTAssertEqual(argv[1], "app-server")
        XCTAssertTrue(argv.containsPair("--disable", "apps"), "built-in connectors must be dropped by default")
        XCTAssertTrue(argv.containsPair(
            "-c", "mcp_servers.rubien.command=/Applications/Rubien.app/Contents/Helpers/rubien-cli"))
        XCTAssertTrue(argv.containsPair("-c", #"mcp_servers.rubien.args=["mcp","--read-only"]"#))
        XCTAssertTrue(argv.containsPair("-c", "mcp_servers.rubien.env.RUBIEN_LIBRARY_ROOT=/tmp/lib"))
        XCTAssertFalse(argv.contains("-c tools.web_search=false"), "web on by default")
    }

    func testEnvironmentPathResolvesNodeForNpmInstalledCodex() {
        // codex is a Node CLI; when it's npm-global but node came from the installer /
        // Homebrew, node lives in a DIFFERENT dir than codex — the PATH must still
        // include the standard interpreter locations or the app-server can't launch
        // ("env: node: No such file or directory"). Regression for the E2E crash.
        let env = CodexInvocation.environment(binaryDirectory: "/Users/x/.npm-global/bin")
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(dirs.first, "/Users/x/.npm-global/bin", "binary dir stays first")
        XCTAssertTrue(dirs.contains("/usr/local/bin"), "nodejs.org installer location")
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "Homebrew location")
        XCTAssertEqual(dirs.count, Set(dirs).count, "no duplicate PATH entries")
    }

    // SAFETY REGRESSION (end-to-end): the whole posture reaches the real thread/start —
    // read-only sandbox, on-request approvals, and crucially `approvalsReviewer: "user"`
    // so codex's own `~/.codex` guardian can't silently auto-approve a mutation.
    func testThreadStartSendsFullSafetyPostureToTheServer() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "ok"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        _ = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        let params = try XCTUnwrap(try readObserved(in: workspace)["lastThreadStartParams"] as? [String: Any])
        XCTAssertEqual(params["approvalsReviewer"] as? String, "user",
                       "mutations must route to Rubien's card, not codex's guardian")
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
    }

    func testWebToggleOffDisablesWebSearchInArgv() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "ok"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        _ = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace, webAccess: false)))

        let argv = try readSpawnedArgv(in: workspace)
        XCTAssertTrue(argv.containsPair("-c", "tools.web_search=false"))
    }

    // MARK: Long-lived server + thread reuse (the point of app-server)

    func testServerAndThreadReusedAcrossTurns() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "first threads={threadStarts}"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let first = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        XCTAssertTrue(first.contains(.assistantMessageCompleted(text: "first threads=1")))

        // Follow-up on the SAME provider, resuming the live thread: no new process
        // (threadStarts still 1 in the same observed file) and no thread/resume
        // (the thread is already live in this server).
        try writeConfig(["assistantText": "second threads={threadStarts}"], into: workspace)
        let second = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace, resume: "TH-1")))
        XCTAssertTrue(second.contains(.assistantMessageCompleted(text: "second threads=1")),
                      "a follow-up turn must reuse the live server + thread")
        let observed = try readObserved(in: workspace)
        XCTAssertEqual(observed["turnStarts"] as? Int, 2)
        XCTAssertEqual(observed["threadResumes"] as? Int, 0)
    }

    // MARK: Approvals

    func testApprovalAcceptRoundTripEchoesNumericId() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "approval": ["reason": "Allow writing out.txt?", "command": "touch out.txt"],
            "assistantText": "wrote it",
        ], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace))
        ) { event in
            if case .approvalRequested(let id, _, _) = event {
                provider.respondToApproval(id: id, .allowOnce)
            }
        }

        let approval = events.compactMap { event -> (String, String, String)? in
            if case .approvalRequested(let id, let tool, let summary) = event { return (id, tool, summary) }
            return nil
        }.first
        XCTAssertEqual(approval?.0, "0", "the fake's first server request id is numeric 0")
        XCTAssertEqual(approval?.1, "shell")
        XCTAssertEqual(approval?.2, "Allow writing out.txt?")
        XCTAssertTrue(events.contains(.toolUseCompleted(name: "shell")))
        XCTAssertTrue(events.containsTurnCompleted)

        let observed = try readObserved(in: workspace)
        let received = try XCTUnwrap(observed["approval"] as? [String: Any])
        XCTAssertEqual(received["decision"] as? String, "accept")
        XCTAssertEqual(received["idType"] as? String, "int",
                       "the response id must be echoed VERBATIM as a JSON number")
    }

    func testDenyFallsBackToCancelWhenDeclineNotOffered() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "approval": [
                "reason": "Allow?", "command": "touch x",
                "availableDecisions": ["accept", "cancel"],   // no "decline" (verified real shape)
            ],
            "assistantText": "done",
        ], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace))
        ) { event in
            if case .approvalRequested(let id, _, _) = event {
                provider.respondToApproval(id: id, .deny)
            }
        }

        let denied = events.contains { if case .toolDenied("shell", _) = $0 { return true }; return false }
        XCTAssertTrue(denied, "a denied command completes as a denied chip")
        let observed = try readObserved(in: workspace)
        XCTAssertEqual((observed["approval"] as? [String: Any])?["decision"] as? String, "cancel",
                       "deny must fall back to cancel when decline isn't offered")
    }

    // MARK: Unknown server request (design #6 — never wedge)

    func testUnknownServerRequestIsAnsweredNotWedged() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["unknownRequest": true, "assistantText": "survived"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "survived")))
        XCTAssertTrue(events.containsTurnCompleted)
        let observed = try readObserved(in: workspace)
        let response = try XCTUnwrap(observed["unknownResponse"] as? [String: Any],
                                     "the unsupported request must receive a reply")
        XCTAssertEqual(response["hadError"] as? Bool, true, "replied with a JSON-RPC error")
    }

    // MARK: Stop / stream-drop semantics (review #5 — the server survives)

    func testStopInterruptsTurnButServerSurvives() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["thinking…"], "hang": true], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace))
        ) { event in
            if case .assistantDelta = event { provider.cancel() }   // the stop button
        }
        XCTAssertTrue(events.containsTurnCompleted, "the interrupted turn still ends its stream")

        // The server must have survived the stop: a follow-up turn reuses it.
        try writeConfig(["assistantText": "still alive threads={threadStarts}"], into: workspace)
        let second = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace, resume: "TH-1")))
        XCTAssertTrue(second.contains(.assistantMessageCompleted(text: "still alive threads=1")),
                      "stop must interrupt the TURN, not kill the app-server")
        let observed = try readObserved(in: workspace)
        XCTAssertGreaterThanOrEqual(observed["interrupts"] as? Int ?? 0, 1)
    }

    func testCancellingTheConsumingTaskInterruptsTurnServerSurvives() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["partial"], "hang": true], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        // The product path for a dropped pane: the controller consumes the stream in
        // a Task and CANCELS it (a bare `break` with the stream still in scope does
        // not terminate an AsyncThrowingStream — cancellation does).
        let stream = provider.send(turn: turn(workspace: workspace))
        let consumer = Task {
            var events: [AgentEvent] = []
            do { for try await event in stream { events.append(event) } } catch {}
            return events
        }
        try await waitForObserved(in: workspace, timeout: 10) { observed in
            (observed["turnStarts"] as? Int ?? 0) >= 1
        }
        consumer.cancel()

        // The cancellation must translate into turn/interrupt (not a server kill).
        try await waitForObserved(in: workspace, timeout: 10) { observed in
            (observed["interrupts"] as? Int ?? 0) >= 1
        }
        try writeConfig(["assistantText": "alive threads={threadStarts}"], into: workspace)
        let second = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace, resume: "TH-1")))
        XCTAssertTrue(second.contains(.assistantMessageCompleted(text: "alive threads=1")),
                      "the server must survive a dropped stream; got \(second)")
    }

    /// The stale-turn race the fake exposed: a NEW send arriving while the prior
    /// turn's interrupted `turn/completed` is still in flight must not have that
    /// straggler leak in and instantly finish the new stream.
    func testStaleTurnCompletionDoesNotLeakIntoNextTurn() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["deltas": ["partial"], "hang": true], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        // Start a hanging turn, then send AGAIN without consuming the first stream
        // to its end — the A2 abandon path interrupts turn 1, whose interrupted
        // completion races the new turn/start.
        let firstStream = provider.send(turn: turn(workspace: workspace))
        let firstConsumer = Task {
            var events: [AgentEvent] = []
            do { for try await event in firstStream { events.append(event) } } catch {}
            return events
        }
        try await waitForObserved(in: workspace, timeout: 10) { observed in
            (observed["turnStarts"] as? Int ?? 0) >= 1
        }

        try writeConfig(["assistantText": "clean threads={threadStarts}"], into: workspace)
        let second = try await collectAllEvents(
            provider.send(turn: turn(workspace: workspace, resume: "TH-1")))
        _ = await firstConsumer.value
        XCTAssertTrue(second.contains(.assistantMessageCompleted(text: "clean threads=1")),
                      "turn 1's stale completion leaked into turn 2's stream; got \(second)")
        XCTAssertTrue(second.containsTurnCompleted)
    }

    // MARK: Crash → notice → respawn

    func testServerCrashSurfacesNoticeAndNextTurnRespawns() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["exitAfterTurnStart": 3], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        let notice = events.compactMap { event -> String? in
            if case .providerNotice(let text) = event { return text }
            return nil
        }.first
        XCTAssertTrue(notice?.contains("exit code 3") == true, "notice was: \(notice ?? "nil")")
        XCTAssertFalse(events.containsTurnCompleted)

        // The next send transparently respawns a fresh server.
        try writeConfig(["assistantText": "reborn threads={threadStarts}"], into: workspace)
        let second = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        XCTAssertTrue(second.contains(.assistantMessageCompleted(text: "reborn threads=1")))
    }

    // MARK: Concurrency regressions (from the connection review)

    /// Review #1: a second turn entering during the spawner's `await initialize` must
    /// NOT send thread/start on an un-initialized server — the handshake gate makes it
    /// wait. A slow initialize + a near-simultaneous second send would race without it.
    func testConcurrentSendDuringSlowHandshakeNeverPrecedesInitialized() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["initDelayMs": 400, "assistantText": "ok"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        // Fire two turns almost together; the second reuses the server mid-handshake.
        async let a = collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        try await Task.sleep(nanoseconds: 50_000_000)
        async let b = collectAllEvents(provider.send(turn: turn(workspace: workspace, resume: "TH-1")))
        _ = try await a
        _ = try await b

        let observed = try readObserved(in: workspace)
        XCTAssertNil(observed["protocolViolation"],
                     "a thread/start reached the server before initialized — handshake gate failed")
        XCTAssertEqual(observed["initialized"] as? Bool, true)
    }

    /// Review #2: a straggler `turn/completed` for a DIFFERENT (old/abandoned) turn id
    /// must be dropped by the positive turn-id filter, not finish the current stream
    /// early — the current turn still streams its real content to completion.
    func testStaleCompletionForOtherTurnIsDropped() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([
            "emitStaleCompletion": true, "deltas": ["real"], "assistantText": "real answer",
        ], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        // The stale TU-OLD-STALE completion arrived FIRST but must not have finished the
        // stream — the real content still comes through, then the real completion.
        XCTAssertTrue(events.contains(.assistantDelta(text: "real")))
        XCTAssertTrue(events.contains(.assistantMessageCompleted(text: "real answer")))
        let completions = events.filter { if case .turnCompleted = $0 { return true }; return false }
        XCTAssertEqual(completions.count, 1, "exactly one (the real) completion should reach the stream")
    }

    /// Review #3: a server crash must sweep the process GROUP, not just reap the leader
    /// — an orphaned MCP/helper child would otherwise survive.
    func testServerCrashKillsOrphanedChildren() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["grandchild": true, "exitAfterTurnStart": 4], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        _ = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        let pid = pid_t(try XCTUnwrap((try readObserved(in: workspace))["grandchildPID"] as? Int))
        try await assertEventuallyDead(pid, timeout: 8)
    }

    /// Review #4: if the server closes stdout but stays ALIVE (wedged), pending requests
    /// must not hang forever — the connection SIGKILLs it so the turn ends with a notice.
    func testStdoutClosedButProcessAliveDoesNotHang() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["closeStdoutStayAlive": true], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        // Must not hang: the stream ends (via a notice) within the collect timeout.
        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)), timeout: 15)
        let pid = pid_t(try XCTUnwrap((try readObserved(in: workspace))["pid"] as? Int))
        try await assertEventuallyDead(pid, timeout: 8)
        XCTAssertTrue(events.contains { if case .providerNotice = $0 { return true }; return false })
    }

    // MARK: Shutdown kills the server tree

    func testShutdownKillsTheServerProcess() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "ok"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)

        _ = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        let observed = try readObserved(in: workspace)
        let pid = pid_t(try XCTUnwrap(observed["pid"] as? Int))
        XCTAssertTrue(isAlive(pid), "the long-lived server should still be running after a turn")

        provider.shutdown()
        try await assertEventuallyDead(pid, timeout: 8)
    }

    // MARK: History over the wire (thread/list · thread/search · thread/read — 3b-4)

    func testRecentSessionsListsThreadsScopedToTheWorkspace() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([:], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let sessions = await provider.recentSessions(workspaceURL: workspace, limit: 10)

        XCTAssertEqual(sessions.map(\.id), ["TH-A", "TH-B"], "order preserved (server pre-sorts)")
        XCTAssertEqual(sessions.first?.preview, "First conversation")
        XCTAssertEqual(sessions.first?.date, Date(timeIntervalSince1970: 1700000200))
        XCTAssertNil(sessions.first?.matchSnippet, "plain recents carry no snippet")

        // The request must be workspace-scoped and include appServer (Rubien's own
        // sessions), else History would drop them.
        let observed = try readObserved(in: workspace)
        let params = try XCTUnwrap(observed["threadListParams"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, workspace.path)
        XCTAssertEqual(params["limit"] as? Int, 10)
        let sourceKinds = try XCTUnwrap(params["sourceKinds"] as? [String])
        XCTAssertTrue(sourceKinds.contains("appServer"))
    }

    func testSearchSessionsReturnsHitsWithSnippets() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([:], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let hits = await provider.searchSessions(query: "match", workspaceURL: workspace, limit: 5)

        XCTAssertEqual(hits.map(\.id), ["TH-9"])
        XCTAssertEqual(hits.first?.matchSnippet, "…the matching text…", "snippet is whitespace-collapsed")

        let observed = try readObserved(in: workspace)
        let params = try XCTUnwrap(observed["threadSearchParams"] as? [String: Any])
        XCTAssertEqual(params["searchTerm"] as? String, "match")
        XCTAssertEqual(params["cwd"] as? String, workspace.path, "search is workspace-scoped")
    }

    func testSearchSessionsFiltersOutForeignWorkspaceHits() async throws {
        let workspace = try makeWorkspace()
        // codex search is global; a hit from another workspace must be dropped.
        try writeConfig(["searchHits": [
            ["thread": ["id": "local", "preview": "Mine", "updatedAt": 1_700_000_200, "cwd": workspace.path],
             "snippet": "hit"],
            ["thread": ["id": "foreign", "preview": "Theirs", "updatedAt": 1_700_000_300, "cwd": "/some/other/ws"],
             "snippet": "hit"],
        ]], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let hits = await provider.searchSessions(query: "hit", workspaceURL: workspace, limit: 10)

        XCTAssertEqual(hits.map(\.id), ["local"], "only this workspace's hit survives the cwd filter")
    }

    func testSearchSessionsShortCircuitsBlankQueryWithoutHittingTheServer() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([:], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let hits = await provider.searchSessions(query: "   ", workspaceURL: workspace, limit: 5)

        XCTAssertTrue(hits.isEmpty)
        // No server spawned at all for an empty query (nothing observed).
        XCTAssertThrowsError(try readObserved(in: workspace))
    }

    func testSessionTranscriptDecodesTurnsToRenderRows() async throws {
        let workspace = try makeWorkspace()
        try writeConfig([:], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let rows = await provider.sessionTranscript(sessionID: "TH-7", workspaceURL: workspace)

        // userMessage → user, agentMessage → assistant, fileChange → tool chip;
        // the reasoning item renders nothing (dropped, as it is live).
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(rows[0].body, "Question?")
        XCTAssertEqual(rows[1].body, "The answer.")
        XCTAssertTrue(rows[2].body.contains("apply_patch"), "fileChange chip names apply_patch")
        XCTAssertEqual(rows.map(\.seq), [0, 1, 2])

        // Read-only preview: threadId + includeTurns, NOT a resume.
        let observed = try readObserved(in: workspace)
        let params = try XCTUnwrap(observed["threadReadParams"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "TH-7")
        XCTAssertEqual(params["includeTurns"] as? Bool, true)
        XCTAssertEqual(observed["threadResumes"] as? Int, 0, "thread/read must not resume the thread")
    }

    func testHistoryReusesTheLiveServerAcrossQueryAndTurn() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "ok"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        // A History read spawns the server; a following turn must REUSE it (same pid),
        // not respawn — the payoff of the long-lived model.
        _ = await provider.recentSessions(workspaceURL: workspace, limit: 5)
        let pidAfterQuery = pid_t(try XCTUnwrap(try readObserved(in: workspace)["pid"] as? Int))

        _ = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))
        let pidAfterTurn = pid_t(try XCTUnwrap(try readObserved(in: workspace)["pid"] as? Int))

        XCTAssertEqual(pidAfterQuery, pidAfterTurn, "the turn reused the History-spawned server")
    }

    // MARK: Harness plumbing

    private var fakeServerPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-codex-app-server.py")
            .path
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        workspacesToClean.append(url)
        return url
    }

    private func writeConfig(_ config: [String: Any], into workspace: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: workspace.appendingPathComponent("fake-codex.json"))
    }

    private func turn(
        workspace: URL, prompt: String = "hello", resume: String? = nil, webAccess: Bool = true
    ) -> AgentTurnRequest {
        AgentTurnRequest(
            workspaceURL: workspace, resumeSessionID: resume, prompt: prompt,
            webAccess: webAccess)
    }

    private func readSpawnedArgv(in workspace: URL) throws -> [String] {
        let data = try Data(contentsOf: workspace.appendingPathComponent("fake-codex-argv.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String])
    }

    private func readObserved(in workspace: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: workspace.appendingPathComponent("fake-codex-observed.json"))
        // Parse OUTSIDE XCTUnwrap: a transient empty/partial read (fixture mid-write)
        // must throw a plain error that waitForObserved's `try?` can swallow.
        // XCTUnwrap records a test failure even when its throw is later caught, so a
        // parse *inside* it taints the polling caller. XCTUnwrap now only guards the cast.
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func waitForObserved(
        in workspace: URL, timeout: TimeInterval, until predicate: ([String: Any]) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let observed = try? readObserved(in: workspace), predicate(observed) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("fake-codex-observed.json never matched the expected state within \(timeout)s")
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func assertEventuallyDead(_ pid: pid_t, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("process \(pid) still alive after \(timeout)s — shutdown leaked the server")
    }

    /// Collect a stream's events until it finishes, optionally reacting to each event
    /// (the approval-driving hook), bounded by a hard timeout.
    private func collectAllEvents(
        _ stream: AsyncThrowingStream<AgentEvent, Error>,
        timeout: TimeInterval = 25,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async throws -> [AgentEvent] {
        try await withTimeout(timeout) {
            var events: [AgentEvent] = []
            for try await event in stream {
                events.append(event)
                onEvent?(event)
            }
            return events
        }
    }
}

// MARK: - Test utilities

private struct TestTimeout: Error {}

/// Race an async operation against a timeout so a wedged turn fails fast rather than
/// hanging the suite.
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
