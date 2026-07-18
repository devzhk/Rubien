# Native Claude Interrupt Plan

**Goal:** Interrupt an active Claude Code turn through Claude's native streaming
control protocol before falling back to process signals, accept Rubien's queued
Steer message immediately, and hand it to a successor Claude process with the
correct cooperative-interrupt session identity without waiting for output-pipe EOF.

**Context:** Claude Agent SDK streaming clients expose `interrupt()`. In Claude
Code 2.1.212 this writes a client-originated stream-json `control_request` whose
request subtype is `interrupt`. Rubien already speaks the same control protocol
directly for initialization and permission responses, but cancellation currently
jumps straight to `SIGTERM`/`SIGKILL`. Codex already uses its native
`turn/interrupt`; this plan does not change the Codex path.

## Behavioral contract

- Stop and interrupt-and-send-queued request native Claude interruption without
  blocking UI progress. If successor startup reaches the provider actor before the
  stream-termination callback, `startTurn` initiates the old turn's interruption,
  so either actor ordering remains correct.
- The controller admits the queued successor immediately, but the provider holds
  its start request until the old Claude process leader exits. This prevents two
  processes from mutating one Claude session. On the cooperative path, handoff
  requires both the interrupted `result` and observed leader exit, so the result's
  rotated ID is deterministically used by the successor's `--resume`.
- Process handoff never waits for stdout/stderr EOF or detached helpers. A
  cooperative terminal result is consumed as soon as its line arrives even when a
  helper keeps the pipe open. If no terminal result arrives by the hard-fallback
  deadline, Rubien kills/reaps the old leader, closes its output handles, records a
  degraded handoff diagnostic, and resumes from the last confirmed ID; an
  unreported rotation cannot be recovered from a CLI that did not complete its
  interrupt protocol.
- Output from a cancelled/retiring turn is parsed for terminal/session metadata but
  is never rendered into its successor.
- A turn that ignores or does not support native interruption escalates to
  process-group `SIGTERM`, then `SIGKILL`. Forced cleanup closes Rubien's output
  handles so detached inherited pipes cannot wedge the provider.
- Cancellation is token-scoped. Late callbacks and cleanup timers from an old turn
  cannot interrupt or signal a successor turn. Explicit `provider.cancel()` also
  snapshots the old token synchronously before its actor hop.
- A process-wide Claude session lease, distinct from the UI's turn gate, remains
  held until the old process leader is cleaned up. Separate provider instances in
  different windows therefore cannot overlap one Claude session or miss a rotated
  ID after the cancelled stream releases the UI gate.
- Provider shutdown force-finalizes active/retiring work and pending starts, and
  permanently rejects delayed starts that arrive after shutdown.

## Implementation

### 1. Add the native control request codec

Modify `Sources/Rubien/Assistant/ClaudeStreamParser.swift`:

- Add `ClaudeControlProtocol.interruptRequest(requestID:)` using the same compact,
  sorted stream-json encoder as `initializeRequest`.
- Encode the SDK-compatible envelope: `type: control_request`, a unique
  `request_id`, and `request: { subtype: interrupt }`.
- Add a focused codec assertion alongside the existing control-protocol tests.

### 2. Make the final control write ordered and bounded

Modify `Sources/Rubien/Assistant/SpawnedAgentProcess.swift` and
`Sources/Rubien/Assistant/ClaudeCodeProvider.swift`:

- Add a best-effort final-control-write operation. Synchronously duplicate stdin
  with an atomic close-on-exec primitive (`F_DUPFD_CLOEXEC`), mark/close the
  original writer so no later approval response can overtake interruption, set the
  duplicate nonblocking, and perform partial-write,
  `EINTR`, and `EAGAIN` handling on a background queue with a fixed deadline.
  Always close the duplicate at completion or timeout. Never use a racy
  `dup()`-then-`F_SETFD` sequence: another provider can spawn concurrently and
  inherit the old pipe. A full pipe therefore cannot serialize the actor or leak a
  thread/descriptor.
- Mark the turn cancelled before issuing that operation. Approval responses require
  the matching active, non-cancelled turn, so a response arriving after cancellation
  is rejected. A response serialized before cancellation remains ordered before the
  final interrupt write.
- Use a two-phase leader wait for **every** live Claude turn: observe exit with
  `waitid(..., WNOWAIT)` without reaping, then reap exactly once after the actor has
  classified the turn as normal or retiring. Both normal and cooperative-cancel
  finalization rendezvous terminal `result` with leader exit in either callback
  order; a bounded no-result exit timeout converts a leader that never emitted a
  result into the existing crash-notice path. A retiring turn additionally signals
  residual group children before reap. Keeping the exited leader reapable prevents
  PID reuse in that window. Because no EOF path starts an irreversible combined
  wait/reap, stdout-close then cancellation cannot race cleanup policy.

### 3. Make cancellation tokens and conversation identity explicit

Modify `Sources/Rubien/Assistant/AgentProvider.swift`,
`Sources/Rubien/Assistant/ChatSessionController.swift`,
`Sources/Rubien/Assistant/ScheduledJobRunner.swift`, and
`Sources/Rubien/Assistant/ClaudeCodeProvider.swift`:

- Add an optional Rubien conversation UUID to `AgentTurnRequest`. The chat
  controller supplies its existing stable `rubienConversationID` on every turn;
  New Conversation and History resume already replace it. Scheduled jobs supply
  their existing per-run UUID. Other providers may ignore it.
- This UUID, not a nullable Claude session ID, determines whether a pending request
  continues the retiring conversation. An early Steer admitted before
  `system/init` can inherit the interrupted result, while New Conversation with the
  same nil resume ID cannot.
- At `send`, publish the generated turn token through a small lock-protected holder
  before returning the stream. `cancel()` snapshots that token synchronously and
  calls `cancelIfCurrent(token:)`; it never asks the actor to cancel whichever turn
  happens to be current later. Consumer cancellation remains token-scoped through
  `onTermination`.

### 4. Add a process-wide Claude session lease

Add a small actor-isolated coordinator (new Assistant source) shared by all
`ClaudeCodeProvider` instances:

- Acquire a lease before spawning Claude, keyed by both the Rubien conversation UUID
  and every confirmed Claude session-ID alias. A provider holds the lease through
  process cleanup, not merely until its event stream finishes.
- Track the latest confirmed Claude session ID on the lease and associate each
  rotated result ID with the same canonical lease. A second window resuming an old
  alias waits and receives the latest ID when admitted; bounded inactive-lease
  retention prevents unbounded history.
- On same-conversation Steer, atomically transfer the old lease to the pending turn
  after cleanup so cross-window waiters cannot interleave. On New Conversation,
  release the old lease and acquire an independent lease for the new UUID.
- Lease acquisition must not suspend the provider actor. Run a cancellation-aware
  acquisition task and return through a token-checked actor callback; shutdown and
  pending replacement cancel waiters. Every callback rechecks provider lifecycle
  and token ownership before spawning.
- Make grant ownership linear and explicit. Every successful grant is represented by
  an idempotently releasable lease token that is either transferred exactly once to
  a spawned/current turn or released by a stale/replaced/shutdown callback.
  `cancelWaiter` handles queued and just-granted races idempotently. Executable
  resolution failure, spawn failure, normal completion, fallback cleanup, and
  shutdown cleanup all release or transfer any post-grant token; no early return may
  strand ownership.
- Keep `AssistantTurnGate` as the UI-level busy/refusal mechanism. The Claude lease
  is the process-lifetime/session-identity layer needed after cancellation releases
  that gate.

### 5. Serialize process handoff without waiting for EOF

Modify `Sources/Rubien/Assistant/ClaudeCodeProvider.swift`:

- Keep the old turn as `current` while it retires and add one actor-isolated pending
  start record containing its token, request/configuration, conversation UUID, and
  continuation but no process yet.
- Define latest-wins replacement for repeated Stop/Steer or New Conversation while
  a predecessor retires. A new start finishes/retires the prior pending token and
  replaces it; a late cancellation callback for that token is ignored. If pending
  cancellation reaches the actor first, it removes that record before the new start
  installs its replacement. Cover both actor orders.
- On active-turn cancellation, enqueue the final native interrupt, finish its event
  continuation immediately, arm bounded signal fallback, and begin leader-exit
  observation independently of stdout EOF. If `startTurn` observes a live
  predecessor first, it performs this same transition before retaining the new
  request as pending. Never overlap two Claude processes for one conversation.
- Continue parsing retiring lines without yielding them. Treat **any** terminal
  `result` for a cancelled token—including the SDK's
  `subtype: error_during_execution`—as cooperative acknowledgement: update the
  conversation's session ID and signal the old group to stop residual tool children.
- Reconcile terminal-result and leader-exit ordering without a timed drain guess. A
  cooperative handoff waits until both callbacks have reached the actor, in either
  order. Then send final `SIGKILL` to the still-stable process-group ID (removing
  children that ignored the earlier cooperative `SIGTERM`), reap, close old output
  handles, finalize the exact token, transfer/release its process-wide lease, and
  launch the latest pending request.
- If the hard fallback expires without a terminal result, force-kill and observe/
  reap the old leader, close output handles, and launch with the conversation table's
  last confirmed ID while logging degraded continuity. Do not wait for EOF.
- Preserve the existing single-reap and no-signal-after-reap/PID-reuse invariants.

### 6. Define terminal provider shutdown

Modify `Sources/Rubien/Assistant/ClaudeCodeProvider.swift` and update Claude's
contract comments in `Sources/Rubien/Assistant/AgentProvider.swift`:

- Override `shutdown()` with engine-wide teardown distinct from graceful Stop.
- Store shutdown and latest-turn-token together behind the provider's synchronous
  lock. `shutdown()` marks the provider closed before enqueueing actor teardown;
  `send()` checks that flag before publishing/scheduling a token and returns a
  finished stream when closed. The actor also sets terminal `isShuttingDown` before
  inspecting work. This covers shutdown-then-send, send-then-shutdown, delayed
  `startTurn`, lease callbacks, and handoff callbacks.
- Finish/retire any pending start without spawning it. Force-kill and force-finalize
  its UI stream and close its handles immediately, and cancel timers/lease waiters.
  Transfer the process plus its held lease token to a strongly retained background
  cleanup that observes exit, signals residual children, reaps the leader, and only
  then releases the lease. Engine/provider deallocation cannot abandon that cleanup,
  and a different provider waiting on the same alias cannot spawn early.

### 7. Extend the fake Claude protocol peer

Modify `Tests/RubienTests/Fixtures/fake-claude.py`:

- Recognize a client `control_request` with subtype `interrupt`, record the request,
  and return its matching successful `control_response`.
- Support cooperative interruption by emitting Claude's SDK result shape
  (`subtype: error_during_execution`) with a configurable rotated session ID, then
  exiting.
- Add configurable ignored-interrupt, delayed-result-ingestion, stdin-backpressure,
  and approval/cancellation race behaviors.
- Preserve detached-output-holder and same-process-group-grandchild probes.

### 8. Protect native, fallback, continuity, replacement, and shutdown

Modify `Tests/RubienTests/ClaudeCodeProviderTests.swift` and the existing protocol
test file:

- Assert consumer cancellation sends the correctly scoped native request in both
  cancellation-first and successor-first actor orderings.
- Rotate the interrupted result ID and assert a same-conversation successor's argv
  resumes it, while New Conversation never does—even when both requests captured a
  nil Claude session ID.
- Delay terminal ingestion until after leader-exit observation and beyond the former
  grace interval; cooperative handoff must still wait for and use the rotated ID.
  Separately assert the no-result hard fallback uses the last confirmed ID without
  waiting for EOF.
- For an ordinary successful turn, deliver its result callback after leader-exit
  observation and assert finalization still publishes completion and the rotated
  session ID. Also cover a leader exit that never emits a result reaching the
  bounded crash-notice fallback.
- Assert detached inherited output pipes do not delay a result/leader-based handoff,
  and cleanup closes the old parent handles.
- Assert ignored native interruption escalates and kills the original group. Assert
  cooperative leader exit also removes a lingering same-group grandchild before
  reaping, including a grandchild that ignores `SIGTERM`.
- Close stdout while keeping the Claude leader alive, then cancel; assert the shared
  WNOWAIT observer follows retiring cleanup and no earlier EOF callback reaps first.
- Assert explicit `provider.cancel()` followed immediately by `send` captures the
  old token. Assert stale approval responses cannot reach Claude or mutate after
  cancellation.
- Spawn an unrelated Claude process concurrently with final-control duplication and
  assert it cannot inherit the old turn's stdin write descriptor.
- Assert two rapid interrupt-and-send cycles and New Conversation replacement in
  both pending-cancel actor orders; only the latest pending token may spawn.
- With two independent provider instances, cancel one turn and attempt to resume
  the same Claude session from the other after the UI gate would have released.
  Assert the second provider waits for old-leader cleanup, never overlaps the old
  process, and launches with the shared rotated ID. Assert same-conversation Steer
  receives atomic lease transfer ahead of unrelated waiters.
- Force lease-grant-versus-cancel replacement, grant-then-spawn-failure, and normal
  completion followed by reacquisition. Each must release ownership exactly once
  and leave later providers unblocked.
- Assert shutdown during cooperative and ignored interruption discards pending
  work, kills/closes/reaps the old process, and send-then-immediate-shutdown cannot
  spawn after the terminal engine state. Also cover shutdown-then-send and a
  cancelled lease waiter. With another provider waiting on the shutdown turn's
  session alias, assert its spawn remains blocked until background reap releases the
  lease.
- Keep pre-registration cancellation and normal completion covered.

No data model, migration, CLI JSON contract, CloudKit field, or user-facing
documentation changes are required.

## Verification

- `swift test --filter ClaudeStreamParserTests`
- `swift test --filter ClaudeCodeProviderTests`
- `swift test --filter ChatSessionControllerTests --filter ClaudeCodeProviderTests --filter CodexProviderTests`
- `swift build`
- `git diff --check`
- Independent correctness/concurrency review of the implementation, followed by
  the repository's reuse, quality, and efficiency simplification passes; address
  accepted findings and rerun affected checks.

## Review questions

1. Does the retiring-current/pending-successor state machine plus process-wide lease
   prevent same-session overlap within one provider and across windows while
   avoiding any dependency on output-pipe EOF?
2. Can a blocked native-control write, stale approval, pending replacement, or
   delayed actor hop affect the wrong turn?
3. Is every cooperative rotated session ID handed only to the matching Rubien
   conversation, including early nil-ID and repeated-interruption cases?
4. Can every normal, fallback, and shutdown path reap the leader exactly once and
   clean residual/detached children without signaling a recycled PID?
5. Does unsupported native control degrade to the bounded signal path with an
   explicit last-confirmed-session fallback?
