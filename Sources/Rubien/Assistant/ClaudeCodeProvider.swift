#if os(macOS)
import Darwin
import Foundation
import RubienCore

// MARK: - ClaudeCodeProvider (Phase 2a)
//
// Spawns and drives the real `claude` CLI, one process per turn (D3), streaming
// stream-json events out and answering `can_use_tool` control requests on stdin
// (§4.2). Process mechanics are normative (§4.1): a minimal ALLOWLISTED env (never
// the app env), each turn in its OWN process group, process-tree kill on cancel,
// independent stdout/stderr draining, and a stale-process guard.
//
// The public type is a `Sendable` `final class`; all mutable turn state lives on an
// internal `actor` (`ClaudeTurnEngine`) so the synchronous protocol methods
// (`send`/`respondToApproval`/`cancel`) can forward without data races.
//
// **One conversation per instance:** a `ClaudeCodeProvider` runs one live process at
// a time. A process-wide Claude session lease outlives the UI gate and prevents a
// second window from resuming an old/rotated alias until the former leader is reaped.
//
// The full native MCP library channel is wired per turn through
// `--mcp-config`/`--strict-mcp-config`; availability still probes only the
// provider binary, while channel resolvability is handled by `MCPContentChannel`.

final class ClaudeCodeProvider: AgentProvider {
    let kind: AgentProviderKind = .claude

    private let engine: ClaudeTurnEngine
    /// An explicit binary path that wins over discovery. Injected by tests (the fake
    /// CLI) and, in production, by the Settings "binary path" override (a later
    /// phase wires `RubienPreferences` here).
    private let executableOverride: String?
    /// The native MCP library channel — the bundled `rubien-cli mcp` server pointed
    /// at the app's library, attached via `--mcp-config`. nil ⇒ the
    /// turn runs without document tools (the channel couldn't be resolved).
    private let contentChannel: MCPContentChannel?
    /// `send`, `cancel`, and `shutdown` are synchronous protocol requirements. This
    /// tiny locked box establishes their ordering before any actor hop.
    private let controlState = ClaudeProviderControlState()

    init(
        executableOverride: String? = nil,
        contentChannel: MCPContentChannel? = nil,
        leaseCoordinator: ClaudeSessionLeaseCoordinator = .shared
    ) {
        self.executableOverride = executableOverride
        self.contentChannel = contentChannel
        self.engine = ClaudeTurnEngine(leaseCoordinator: leaseCoordinator)
    }

    func isAvailable() async -> AgentAvailability {
        await engine.isAvailable(override: executableOverride)
    }

    func send(turn: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        sendEvents(turn: turn, identityObserver: nil)
    }

    func sendEnvelopes(
        turn: AgentTurnRequest,
        attempt: AssistantAttemptIdentity,
        identityObserver: AgentIdentityObserver?
    ) -> AsyncThrowingStream<AgentEventEnvelope, Error> {
        let events = sendEvents(turn: turn, identityObserver: identityObserver)
        // Cancelling visible consumption retires the native turn. The engine
        // retains `identityObserver` until the exact process is reaped.
        return forwardingAgentStream(events) { event in
            AgentEventEnvelope(
                attempt: attempt,
                providerItemID: nil,
                event: event
            )
        }
    }

    private func sendEvents(
        turn: AgentTurnRequest,
        identityObserver: AgentIdentityObserver?
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        guard let ticket = controlState.beginSend() else {
            Task { await identityObserver?.close() }
            return AsyncThrowingStream { $0.finish() }
        }
        let token = ticket.token
        let engine = self.engine
        let override = executableOverride
        let mcpConfig = contentChannel?.configArgument(
            readOnly: turn.executionMode == .scheduled
        )
        return AsyncThrowingStream { continuation in
            // Breaking/cancelling the consumed stream (e.g. window closed mid-turn)
            // kills this turn's process group — turn-scoped so it can't clobber a
            // later turn.
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                Task { await engine.cancelIfCurrent(
                    token: token, sequence: ticket.sequence) }
            }
            Task {
                await engine.startTurn(
                    token: token, sequence: ticket.sequence, request: turn,
                    executableOverride: override, mcpConfig: mcpConfig,
                    continuation: continuation,
                    identityObserver: identityObserver)
            }
        }
    }

    func respondToApproval(id: String, _ decision: ApprovalDecision) {
        let engine = self.engine
        Task { await engine.respond(id: id, decision: decision) }
    }

    func cancel() {
        guard let ticket = controlState.currentTicket() else { return }
        let engine = self.engine
        Task { await engine.cancelIfCurrent(
            token: ticket.token, sequence: ticket.sequence) }
    }

    func shutdown() {
        controlState.close()
        let engine = self.engine
        Task { await engine.shutdown() }
    }

    /// Light read of Claude's own session store for the History picker (§5.3).
    /// A scoped listing (`referenceID` set) scans file bodies for attribution.
    func recentSessionsResult(
        workspaceURL: URL, limit: Int, referenceID: Int64?, deadline: Date?
    ) async -> AgentSessionQueryResult {
        .completed(await storeRead {
            ClaudeSessionStore().recentSessions(
                workspaceURL: workspaceURL, limit: limit, referenceID: referenceID)
        })
    }

    /// A picked session's full transcript (resume restores the conversation's
    /// content).
    func sessionTranscript(sessionID: String, workspaceURL: URL) async -> [ChatRenderMessage] {
        await storeRead {
            ClaudeSessionStore().fullTranscript(sessionID: sessionID, workspaceURL: workspaceURL)
        }
    }

    /// Content search over the store's sessions (History picker's search field).
    func searchSessionsResult(
        query: String, workspaceURL: URL, limit: Int, referenceID: Int64?,
        deadline: Date?
    ) async -> AgentSessionQueryResult {
        .completed(await storeRead {
            ClaudeSessionStore().searchSessions(
                query: query, workspaceURL: workspaceURL, limit: limit, referenceID: referenceID)
        })
    }

    /// Run one blocking session-store read off the main actor. The closure's value
    /// parameters are its only captures (the store + FileManager are created inside
    /// the detached task). Detachment breaks structured cancellation, so the
    /// caller's cancellation is forwarded explicitly — a superseded scan (search
    /// keystroke, History scope flip) stops at its next per-file check instead of
    /// running to completion.
    private func storeRead<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let scan = Task.detached(priority: .userInitiated, operation: body)
        return await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }
}

private final class ClaudeProviderControlState: @unchecked Sendable {
    struct Ticket {
        let token: UUID
        let sequence: UInt64
    }

    private let lock = NSLock()
    private var latestTicket: Ticket?
    private var sequence: UInt64 = 0
    private var isClosed = false

    func beginSend() -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return nil }
        sequence &+= 1
        let token = UUID()
        let ticket = Ticket(token: token, sequence: sequence)
        latestTicket = ticket
        return ticket
    }

    func currentTicket() -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        return latestTicket
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }
}

// MARK: - Turn engine (all mutable state is actor-isolated)

/// Internal for deterministic actor-order regression tests; production access is
/// still exclusively through `ClaudeCodeProvider`.
actor ClaudeTurnEngine {
    private var current: Turn?
    private var pending: PendingStart?
    private var cancelledTokens: Set<UUID> = []
    private var isShuttingDown = false
    private var latestStartSequence: UInt64 = 0
    private var cachedResolution: (path: String, version: String)?
    private let leaseCoordinator: ClaudeSessionLeaseCoordinator
    private let logger = RubienLogger(subsystem: "com.rubien.assistant", category: "ClaudeProvider")

    private static let settleSoftKillDelay: Double = 3.0
    private static let settleHardKillDelay: Double = 5.0
    private static let interruptSoftKillDelay: Double = 0.5
    private static let interruptHardKillDelay: Double = 2.0
    private static let noResultExitGrace: Double = 2.0

    init(leaseCoordinator: ClaudeSessionLeaseCoordinator) {
        self.leaseCoordinator = leaseCoordinator
    }

    private final class PendingStart {
        let token: UUID
        let request: AgentTurnRequest
        let executableOverride: String?
        let mcpConfig: String?
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        let identityObserver: AgentIdentityObserver?
        var acquisitionTask: Task<Void, Never>?

        init(
            token: UUID,
            request: AgentTurnRequest,
            executableOverride: String?,
            mcpConfig: String?,
            continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
            identityObserver: AgentIdentityObserver?
        ) {
            self.token = token
            self.request = request
            self.executableOverride = executableOverride
            self.mcpConfig = mcpConfig
            self.continuation = continuation
            self.identityObserver = identityObserver
        }
    }

    private final class Turn {
        let token: UUID
        let process: SpawnedAgentProcess
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        let conversationID: UUID?
        let lease: ClaudeSessionLeaseCoordinator.Grant
        let identityObserver: AgentIdentityObserver?
        var parser = ClaudeStreamParser()
        var pendingApprovals: [String: ClaudeControlProtocol.PendingApproval] = [:]
        let stderr = StderrRingBuffer()
        var latestSessionID: String?
        var sawResult = false
        var cancelled = false
        var finished = false
        var leaderExited = false
        var forceFinalize = false
        var finalizing = false
        var terminationTask: Task<Void, Never>?

        init(
            token: UUID, process: SpawnedAgentProcess,
            continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
            conversationID: UUID?,
            lease: ClaudeSessionLeaseCoordinator.Grant,
            latestSessionID: String?,
            identityObserver: AgentIdentityObserver?
        ) {
            self.token = token
            self.process = process
            self.continuation = continuation
            self.conversationID = conversationID
            self.lease = lease
            self.latestSessionID = latestSessionID
            self.identityObserver = identityObserver
        }
    }

    // MARK: Turn lifecycle

    func startTurn(
        token: UUID,
        sequence: UInt64,
        request: AgentTurnRequest,
        executableOverride: String?,
        mcpConfig: String?,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        identityObserver: AgentIdentityObserver? = nil
    ) async {
        guard !isShuttingDown else {
            continuation.finish()
            await identityObserver?.close()
            return
        }
        let wasCancelledBeforeStart = cancelledTokens.remove(token) != nil
        guard sequence >= latestStartSequence else {
            continuation.finish()
            await identityObserver?.close()
            return
        }
        latestStartSequence = sequence
        if wasCancelledBeforeStart {
            continuation.finish()
            await identityObserver?.close()
            return
        }

        let start = PendingStart(
            token: token, request: request, executableOverride: executableOverride,
            mcpConfig: mcpConfig, continuation: continuation,
            identityObserver: identityObserver)
        if let replaced = pending { await cancelPending(replaced) }
        pending = start

        if let turn = current {
            beginRetirement(turn)
        } else {
            acquireLease(for: start)
        }
    }

    private func acquireLease(for start: PendingStart) {
        guard pending?.token == start.token, start.acquisitionTask == nil else { return }
        let waiterID = UUID()
        let coordinator = leaseCoordinator
        start.acquisitionTask = Task { [self] in
            let grant = await coordinator.acquire(
                waiterID: waiterID,
                conversationID: start.request.conversationID,
                resumeSessionID: start.request.resumeSessionID)
            if Task.isCancelled {
                if let grant {
                    await coordinator.release(grant, latestSessionID: grant.latestSessionID)
                }
                await leaseAcquired(nil, token: start.token)
                return
            }
            await leaseAcquired(grant, token: start.token)
        }
    }

    private func leaseAcquired(
        _ grant: ClaudeSessionLeaseCoordinator.Grant?, token: UUID
    ) async {
        guard let start = pending, start.token == token,
              !isShuttingDown, current == nil
        else {
            if let grant {
                await leaseCoordinator.release(grant, latestSessionID: grant.latestSessionID)
            }
            return
        }
        start.acquisitionTask = nil
        guard let grant else {
            await cancelPending(start)
            return
        }
        await spawn(start, lease: grant, resumeSessionID: grant.latestSessionID)
    }

    private func spawn(
        _ start: PendingStart,
        lease: ClaudeSessionLeaseCoordinator.Grant,
        resumeSessionID: String?
    ) async {
        let images: [ClaudeImageInput]
        switch Self.imageInputs(from: start.request.attachments) {
        case .success(let inputs):
            images = inputs
        case .failure(let error):
            await fail(start, lease: lease, resumeSessionID: resumeSessionID, error: error)
            return
        }
        let userMessage = ClaudeControlProtocol.userMessage(
            prompt: start.request.prompt, images: images)

        guard let executable = Self.resolveExecutable(override: start.executableOverride) else {
            await fail(
                start, lease: lease, resumeSessionID: resumeSessionID,
                error: AgentProviderError.executableNotFound(
                    start.executableOverride ?? "claude"))
            return
        }

        let arguments = ClaudeCLIInvocation.arguments(
            for: start.request,
            mcpConfig: start.mcpConfig,
            resumeSessionID: resumeSessionID)
        let environment = ClaudeCLIInvocation.environment(
            binaryDirectory: (executable as NSString).deletingLastPathComponent)

        let process: SpawnedAgentProcess
        do {
            process = try SpawnedAgentProcess.spawn(
                executablePath: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: start.request.workspaceURL.path)
        } catch let error as AgentProviderError {
            await fail(start, lease: lease, resumeSessionID: resumeSessionID, error: error)
            return
        } catch {
            await fail(
                start, lease: lease, resumeSessionID: resumeSessionID,
                error: AgentProviderError.spawnFailed(code: -1))
            return
        }

        guard !isShuttingDown, pending?.token == start.token else {
            process.signalGroup(SIGKILL)
            process.closeOutputHandles()
            Task { [coordinator = leaseCoordinator, identityObserver = start.identityObserver] in
                guard await process.observeExit() else { return }
                process.signalGroup(SIGKILL)
                guard await process.reap() != nil else { return }
                await coordinator.release(lease, latestSessionID: resumeSessionID)
                await identityObserver?.close()
            }
            start.continuation.finish()
            return
        }

        logger.info("claude turn spawned pid=\(process.pid) resume=\(resumeSessionID != nil)")
        let turn = Turn(
            token: start.token, process: process, continuation: start.continuation,
            conversationID: start.request.conversationID, lease: lease,
            latestSessionID: resumeSessionID,
            identityObserver: start.identityObserver)
        pending = nil
        current = turn
        startReaders(turn: turn)

        // The control protocol handshake, then the prompt — both on stdin, which
        // stays open (it is also the approval bus) until the result / cancel.
        process.writeLine(ClaudeControlProtocol.initializeRequest(requestID: UUID().uuidString))
        process.writeLine(userMessage)
    }

    private func fail(
        _ start: PendingStart,
        lease: ClaudeSessionLeaseCoordinator.Grant,
        resumeSessionID: String?,
        error: Error
    ) async {
        if pending?.token == start.token { pending = nil }
        start.continuation.finish(throwing: error)
        await leaseCoordinator.release(lease, latestSessionID: resumeSessionID)
        await start.identityObserver?.close()
    }

    /// Materialize all native image blocks before any process is spawned or stdin
    /// bytes are written. Text attachments remain path-backed in Rubien's manifest.
    private static func imageInputs(
        from attachments: [ChatAttachment]
    ) -> Result<[ClaudeImageInput], AgentProviderError> {
        var inputs: [ClaudeImageInput] = []
        for attachment in attachments where attachment.kind == .image {
            guard attachment.mediaType == "image/png" || attachment.mediaType == "image/jpeg",
                  let data = try? Data(contentsOf: attachment.stagedURL)
            else {
                return .failure(.attachmentUnreadable(attachment.displayName))
            }
            inputs.append(ClaudeImageInput(
                mediaType: attachment.mediaType,
                base64Data: data.base64EncodedString()))
        }
        return .success(inputs)
    }

    /// Feed one stdout line into the turn. Stale lines (from a superseded/killed
    /// process) are dropped — the stale-process guard (§4.1).
    func ingest(token: UUID, line: String) async {
        guard let turn = current, turn.token == token, !turn.finished else { return }

        // Record approval bookkeeping BEFORE emitting the event, so a caller that
        // answers immediately finds the pending entry. (Actor serialization means
        // `respond` can't interleave until we suspend/return anyway.) B2: only the
        // rare control-request lines carry the "can_use_tool" token, so skip the
        // second full JSON parse on every frequent `stream_event` delta.
        if line.contains("can_use_tool"),
           let pending = ClaudeControlProtocol.decodeCanUseTool(line: line) {
            if AssistantToolApprovalPolicy.isSilentReadTool(pending.toolName) {
                turn.process.writeLine(ClaudeControlProtocol.controlResponse(
                    for: pending,
                    decision: .allowForConversation
                ))
                return
            }
            turn.pendingApprovals[pending.requestID] = pending
        }

        for event in turn.parser.parse(line: line) {
            if case .sessionStarted(let sessionID) = event {
                turn.latestSessionID = sessionID
                // Publish a fresh/rotated alias before exposing it to the UI. A
                // different provider can immediately attempt History resume from
                // that visible id; it must join this already-held lease rather
                // than creating a second live owner.
                await leaseCoordinator.update(turn.lease, latestSessionID: sessionID)
                await turn.identityObserver?.sessionStarted(
                    sessionID,
                    runtimeGeneration: nil
                )
            }
            if !turn.cancelled { turn.continuation.yield(event) }
            if case .turnCompleted = event { onResult(turn) }
        }
    }

    private func leaderExited(token: UUID) {
        guard let turn = current, turn.token == token, !turn.finished else { return }
        turn.leaderExited = true
        if turn.sawResult || turn.forceFinalize {
            beginFinalize(turn)
        } else if !turn.cancelled {
            scheduleNoResultFallback(turn)
        }
    }

    // MARK: External controls

    func respond(id: String, decision: ApprovalDecision) {
        guard let turn = current, !turn.finished, !turn.cancelled,
              let pending = turn.pendingApprovals[id]
        else { return }
        turn.pendingApprovals[id] = nil
        turn.process.writeLine(ClaudeControlProtocol.controlResponse(for: pending, decision: decision))
    }

    func cancelIfCurrent(token: UUID, sequence: UInt64) async {
        if let turn = current, turn.token == token {
            beginRetirement(turn)
        } else if let start = pending, start.token == token {
            await cancelPending(start)
        } else if sequence > latestStartSequence {
            // A newer send can be cancelled before either its own start task or an
            // older delayed start reaches the actor. Advancing the watermark makes
            // that older start stale; discard an already-registered older pending
            // acquisition as well. A live older turn is left alone because the
            // cancelled successor never became an interruption request.
            latestStartSequence = sequence
            if let olderPending = pending { await cancelPending(olderPending) }
            cancelledTokens.insert(token)
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if let start = pending { await cancelPending(start) }
        guard let turn = current, !turn.finished else { return }
        turn.cancelled = true
        turn.forceFinalize = true
        turn.pendingApprovals.removeAll()
        turn.terminationTask?.cancel()
        turn.continuation.finish()
        turn.process.closeStdin()
        turn.process.closeOutputHandles()
        turn.stderr.finish()
        turn.process.signalGroup(SIGKILL)
        if turn.leaderExited { beginFinalize(turn) }
    }

    // MARK: Internals

    private func onResult(_ turn: Turn) {
        guard !turn.sawResult else { return }
        turn.sawResult = true
        if turn.cancelled {
            turn.process.signalGroup(SIGTERM)
        } else {
            turn.process.closeStdin()
            scheduleTermination(
                turn,
                softAfter: Self.settleSoftKillDelay,
                hardAfter: Self.settleHardKillDelay)
        }
        if turn.leaderExited { beginFinalize(turn) }
    }

    private func beginRetirement(_ turn: Turn) {
        guard !turn.finished, !turn.cancelled else { return }
        turn.cancelled = true
        turn.pendingApprovals.removeAll()
        turn.continuation.finish()
        turn.process.writeFinalLine(
            ClaudeControlProtocol.interruptRequest(requestID: UUID().uuidString))
        scheduleTermination(
            turn,
            softAfter: Self.interruptSoftKillDelay,
            hardAfter: Self.interruptHardKillDelay)
        if turn.leaderExited, turn.sawResult { beginFinalize(turn) }
    }

    private func cancelPending(_ start: PendingStart) async {
        guard pending?.token == start.token else { return }
        pending = nil
        start.acquisitionTask?.cancel()
        start.continuation.finish()
        cancelledTokens.remove(start.token)
        await start.identityObserver?.close()
    }

    private func beginFinalize(_ turn: Turn) {
        guard !turn.finished, !turn.finalizing, turn.leaderExited else { return }
        turn.finalizing = true
        turn.terminationTask?.cancel()
        turn.process.signalGroup(SIGKILL)
        turn.process.closeOutputHandles()
        turn.stderr.finish()
        let token = turn.token
        let process = turn.process
        Task { [self] in
            guard let status = await process.reap() else {
                reapFailed(token: token)
                return
            }
            await cleanupCompleted(token: token, status: status)
        }
    }

    private func reapFailed(token: UUID) {
        guard let turn = current, turn.token == token, turn.finalizing else { return }
        logger.error("waitpid failed for claude pid=\(turn.process.pid); retaining session lease")
        turn.finalizing = false
    }

    private func cleanupCompleted(token: UUID, status: Int32) async {
        guard let turn = current, turn.token == token, !turn.finished else { return }
        turn.finished = true
        if !turn.cancelled && !turn.sawResult {
            turn.continuation.yield(.providerNotice(
                await AgentProcessExit.crashNotice(waitStatus: status, stderr: turn.stderr)))
        }
        if !turn.cancelled { turn.continuation.finish() }
        cancelledTokens.remove(turn.token)
        current = nil

        await leaseCoordinator.update(turn.lease, latestSessionID: turn.latestSessionID)
        await turn.identityObserver?.close()
        if !isShuttingDown,
           let start = pending,
           let conversationID = turn.conversationID,
           start.request.conversationID == conversationID {
            await spawn(start, lease: turn.lease, resumeSessionID: turn.latestSessionID)
            return
        }

        await leaseCoordinator.release(turn.lease, latestSessionID: turn.latestSessionID)
        if !isShuttingDown, let start = pending { acquireLease(for: start) }
    }

    /// Independent stdout (line → event) and stderr (bounded ring buffer) drains, so
    /// a full stderr pipe can never deadlock stdout parsing (§4.1).
    private func startReaders(turn: Turn) {
        let token = turn.token
        let process = turn.process

        Task { [weak self] in
            do {
                for try await line in process.stdoutHandle.bytes.lines {
                    await self?.ingest(token: token, line: line)
                }
            } catch {
                // A read error is just an early EOF for our purposes.
            }
        }

        Task { [self] in
            guard await process.observeExit() else {
                observationFailed(token: token)
                return
            }
            leaderExited(token: token)
        }

        // stderr on a background thread doing bounded blocking reads (NOT per-byte
        // actor hops — a flood must stay cheap).
        let ring = turn.stderr
        let handle = process.stderrHandle
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                ring.append(chunk)
            }
            ring.finish()   // A5: signal EOF so the failure path can read the final bytes
        }
    }

    private func scheduleTermination(
        _ turn: Turn, softAfter: Double, hardAfter: Double
    ) {
        let token = turn.token
        turn.terminationTask?.cancel()
        turn.terminationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(softAfter * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.softKill(token: token)
            let remaining = hardAfter - softAfter
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.forceKill(token: token)
        }
    }

    private func scheduleNoResultFallback(_ turn: Turn) {
        let token = turn.token
        turn.terminationTask?.cancel()
        turn.terminationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noResultExitGrace * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.forceKill(token: token)
        }
    }

    private func softKill(token: UUID) {
        guard let turn = current, turn.token == token, !turn.finished else { return }
        turn.process.signalGroup(SIGTERM)
    }

    private func forceKill(token: UUID) {
        guard let turn = current, turn.token == token, !turn.finished else { return }
        turn.forceFinalize = true
        if turn.cancelled, !turn.sawResult {
            logger.error(
                "claude interrupt fallback lost cooperative result pid=\(turn.process.pid) session=\(turn.latestSessionID ?? "none")")
        }
        turn.process.signalGroup(SIGKILL)
        if turn.leaderExited { beginFinalize(turn) }
    }

    private func observationFailed(token: UUID) {
        guard let turn = current, turn.token == token, !turn.finished else { return }
        logger.error("waitid failed for claude pid=\(turn.process.pid); retaining session lease")
    }

    // MARK: Availability

    func isAvailable(override: String?) async -> AgentAvailability {
        // Resolve the binary + --version once and cache THAT (expensive: candidate walk,
        // possibly a login-shell `command -v`, plus the version subprocess). Auth is
        // re-probed on EVERY call so a mid-session sign-out / token expiry is reflected —
        // caching the ready result made Recheck a no-op after logout (#11).
        let path: String
        let version: String
        let environment: [String: String]
        if let cached = cachedResolution {
            path = cached.path
            version = cached.version
            environment = ClaudeCLIInvocation.environment(
                binaryDirectory: (path as NSString).deletingLastPathComponent)
        } else {
            guard let resolved = Self.resolveExecutable(override: override) else {
                return .notFound(
                    reason: "Claude Code CLI wasn’t found. Install Claude Code or set the binary path in Settings → Assistant, then recheck.")
            }
            environment = ClaudeCLIInvocation.environment(
                binaryDirectory: (resolved as NSString).deletingLastPathComponent)
            guard let probedVersion = await AgentBinaryProbe.probeVersion(
                executablePath: resolved, environment: environment)
            else {
                return .notFound(reason: "Found claude at \(resolved) but it did not respond to --version.")
            }
            cachedResolution = (path: resolved, version: probedVersion)
            path = resolved
            version = probedVersion
        }
        if await AgentAuthProbe.probeClaude(executablePath: path, environment: environment) == .unauthenticated {
            return .installedButUnauthenticated(
                version: version,
                path: path,
                reason: "Claude Code is installed but not signed in. Run claude auth login in Terminal, then recheck.")
        }
        return .installed(version: version, path: path)
    }

    /// Well-known claude install dirs; resolution control flow is shared (§5.5).
    static func resolveExecutable(override: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentBinaryProbe.resolveExecutable(
            override: override,
            candidates: [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.npm-global/bin/claude",
            ],
            binaryName: "claude")
    }
}

// MARK: - CLI invocation (pure argv + env construction; unit-tested)

/// The exact `claude` argv and the minimal allowlisted child environment (D3/§4.1).
/// Extracted from the engine so it can be verified without spawning anything.
enum ClaudeCLIInvocation {

    /// The per-turn argv (D3/§4.2). `mcpConfig`, when present, is the inline
    /// `--mcp-config` JSON for the native Rubien library channel.
    static func arguments(
        for request: AgentTurnRequest,
        mcpConfig: String? = nil,
        resumeSessionID: String? = nil
    ) -> [String] {
        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
        ]
        if request.executionMode == .scheduled {
            // No approval bypass: scheduled runs keep Claude's normal permission
            // boundary and the runner deterministically denies any prompt.
            args += ["--permission-mode", "default"]
        }
        if !request.loadUserTools {
            // Default isolation (D6): drops ambient settings/MCP/plugins while
            // subscription auth survives. Opted-in conversations omit this flag so
            // Claude loads its normal user/project/local configuration.
            args += ["--setting-sources", ""]
        }
        if let resume = resumeSessionID ?? request.resumeSessionID, !resume.isEmpty {
            args += ["--resume", resume]
        }
        // `--append-system-prompt` is invocation-scoped: `--resume` restores the
        // transcript, but not this flag. The controller therefore carries the same
        // trusted instructions into every Claude turn.
        if let seed = request.seed, !seed.isEmpty {
            args += ["--append-system-prompt", seed]
        }
        if let model = request.modelOverride, !model.isEmpty {
            args += ["--model", model]
        }
        // `--effort` needs the same modern CLI surface the rest of this argv already
        // requires (--permission-prompt-tool stdio / --setting-sources, verified on
        // 2.1.201) — an older CLI never ran these turns at all, so no capability
        // probe. Like --model, the value passes through raw (Settings may send
        // future levels); an invalid one fails the turn visibly via the §4.5 notice.
        if let effort = request.effortOverride, !effort.isEmpty {
            args += ["--effort", effort]
        }
        if !request.webAccess {
            // Bash `curl` still prompts (control protocol), so this is not a silent
            // bypass (D6).
            args += ["--disallowedTools", "WebFetch WebSearch"]
        }
        // The native MCP library channel: an inline `--mcp-config` naming the
        // bundled full `rubien-cli mcp` server. In the default posture,
        // `--strict-mcp-config` means ONLY Rubien loads (and
        // pairs with `--setting-sources ''`). The explicit user-tools opt-in keeps
        // Rubien's config but omits strict mode, merging the user's normal MCP and
        // plugin environment. Absent when the channel couldn't be resolved; the turn
        // still runs, just without Rubien document tools.
        if let mcpConfig, !mcpConfig.isEmpty {
            args += ["--mcp-config", mcpConfig]
            if !request.loadUserTools {
                args.append("--strict-mcp-config")
            }
        }
        return args
    }

    /// The shared minimal ALLOWLISTED environment (`SpawnedAgentProcess`) + Claude's
    /// entrypoint marker. `HOME` (in the shared allowlist) is required so config-dir-
    /// relative subscription auth survives `--setting-sources ''`.
    static func environment(binaryDirectory: String) -> [String: String] {
        var env = SpawnedAgentProcess.minimalEnvironment(binaryDirectory: binaryDirectory)
        env["CLAUDE_CODE_ENTRYPOINT"] = "rubien-assistant"
        return env
    }
}

#endif
