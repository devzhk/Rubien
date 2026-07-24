# Codex Thread Lifecycle Foundation

- **Date:** 2026-07-23
- **Status:** implemented and verified
- **Decision context:** retain Option B and prepare only the proven subset of
  B-T. This change does not move any launch posture to thread configuration.

## Objective

Replace the app-server generation's grow-only `loadedThreadIDs` set with
reference-counted thread leases. A live `CodexProvider` wrapper owns at most
one loaded thread. Rebinding or closing the last owning wrapper sends
`thread/unsubscribe`; the zero-owner lease remains classified as cached until
`thread/closed` or server replacement proves that Codex discarded its
in-memory state.

This bounds the per-thread MCP runtimes retained by the shared app-server and
provides the ownership barrier needed by later thread-local posture work.

## Invariants

1. Thread loading remains local to one app-server generation. A server exit or
   replacement discards every lease for that generation.
2. Multiple wrappers may own the same thread. Closing one does not unsubscribe
   while another owner remains.
3. An owner rebinds only after the new `thread/start` or `thread/resume`
   resolves. Its prior thread is then released.
4. The final owner is not released while that owner's active, queued,
   starting, or identity-retiring turn still exists.
5. A thread with an in-flight unsubscribe is never treated as subscribed. A
   resume of that id waits for the unsubscribe response before deciding
   whether the cached thread can be reused or needs a cold server replacement.
6. `thread/closed` is authoritative: it removes the lease and any owner
   mappings for that thread. The next turn explicitly resumes it.
7. A successful unsubscribe does not imply unload: Codex may retain the thread
   in memory until its idle timeout. A failed, timed-out, or unrecognized
   unsubscribe leaves the lease in an unknown state rather than assuming that
   a later profile change is safe.
8. Timed-out `thread/start` and `thread/resume` requests retain a late-response
   tombstone. A late success is quarantined and balanced with
   `thread/unsubscribe` so it cannot leak an unowned subscription.

## Implementation

### 1. Protocol and fixture

- Add the pure `thread/unsubscribe` request encoder.
- Extend the fake app-server to record unsubscribe ids, support a delayed
  response, flag a resume received while unsubscribe is pending, and emit
  `thread/closed`.
- Add an optional fixture path that emits `thread/closed` after a completed
  turn so reconciliation is testable independently of wrapper shutdown.

### 2. Generation-local lease state

- Replace `loadedThreadIDs` with:
  - a thread-id → lease record containing owners, subscription state, and the
    effective `CodexThreadProfile` fingerprint;
  - an owner-id → thread-id reverse index.
- Treat only a subscribed lease as the existing-thread fast path.
- Store an unsubscribe task/token as the transition barrier so actor
  reentrancy cannot race a new resume ahead of the unsubscribe response.
- Retain successful zero-owner releases as cached leases; classify uncertain
  unsubscribe outcomes as unknown.
- Reuse a cached thread only when its requested profile matches. When it does
  not match, recycle the idle shared server before resuming; if an unrelated
  turn is active, surface a visible wait-and-retry failure instead of
  pretending the new profile took effect.

### 3. Owner lifecycle

- Bind the wrapper owner after thread start/resume succeeds.
- On rebind, remove it from its prior lease and begin unsubscribe if the prior
  lease reaches zero owners.
- On wrapper shutdown, interrupt/cancel its current work and request owner
  release even when the app-server connection is shared.
- Defer that release until all work and identity retirement for the owner has
  drained.

### 4. Server notification reconciliation

- Route `thread/closed` before turn-scoped notification lookup, because it can
  arrive with no active turn.
- Remove the matching lease and reverse owner mappings. Do not route it through
  a turn parser.
- Retain late-request effects after caller timeout. A late setup success
  quarantines the returned thread id and initiates unsubscribe; an idle server
  with unresolved effects is recycled instead of being trusted indefinitely.

### 5. Verification

- Protocol encoder unit test.
- Provider integration tests:
  - two owners of one thread unsubscribe only after the second release;
  - rebinding one owner unsubscribes its prior thread;
  - resume waits for an in-flight unsubscribe;
  - shutdown during an active turn interrupts/drains before unsubscribe;
  - `thread/closed` forces the next follow-up through `thread/resume`;
  - a changed profile on a cached thread forces a true cold resume;
  - unsubscribe timeout prevents unsafe reuse until a cold resume is safe;
  - late start/resume responses are unsubscribed rather than leaked.
- Run `CodexAppServerProtocolTests`, `CodexProviderTests`, the full Swift test
  suite, and `git diff --check`.
- Run the repository's independent review and simplify sweep before delivery.

## Outcome

Implemented on 2026-07-23. Independent review found and the implementation
fixed two shutdown races:

- a successful `thread/start`/`thread/resume` response now records its lease
  before honoring cancellation, so closing during the RPC cannot leak a
  subscribed thread;
- a resume waiting on unsubscribe fails cleanly when that server generation
  exits, and the shared request path rejects stale server objects before
  installing a continuation.

The simplify sweep removed timing-based lifecycle assertions, narrowed
`thread/closed` cleanup to the lease's exact owners, and corrected shutdown
documentation. A later runtime-architecture review tightened the contract
further after a live Codex spike proved that successful unsubscribe alone
does not evict cached thread state:

- cached or uncertain state now requires a genuinely cold server replacement
  before a changed profile is applied;
- unsubscribe failures remain quarantined rather than being treated as safe;
- late setup responses are tracked and cleaned up after caller timeout.

The final verification totals for the combined runtime change are recorded in
the architecture decision document.

## Non-goals

- Moving cwd, Apps, plugins, Rubien MCP posture, or web access to per-thread
  configuration.
- Waiting 30 minutes in tests for Codex's zero-subscriber idle unload.
- Solving wedge detection or the cross-server stale-thread problem.
- Changing the four-turn admission cap or runtime-profile scheduling.
