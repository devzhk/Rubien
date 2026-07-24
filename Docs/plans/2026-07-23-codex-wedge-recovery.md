# Codex Wedge Detection and Recovery

- **Date:** 2026-07-23
- **Status:** implemented and verified
- **Decision context:** this is a topology-independent runtime invariant. It
  hardens the existing shared app-server before any partial B-T posture move.

## Objective

Detect an app-server process that is still alive but no longer services its
stdio JSON-RPC connection. End every affected turn with a truthful notice,
kill and reap that exact server generation, and let the next user-initiated
turn transparently spawn a clean generation.

Rubien must not automatically replay the failed turn: it may already have
performed tools or other side effects before the wedge.

## Liveness signal

Silence alone is not failure. A model can reason, run a long tool, or wait for
user approval without emitting an event.

After an active turn has produced no inbound frames for the silence interval,
Rubien sends an intentionally unsupported `rubien/liveness` JSON-RPC request.
Any response, including the expected invalid-request error, proves that the
local stdio dispatcher is alive. Only failure to answer that probe within its
short deadline declares the generation wedged.

This signal was behaviorally verified against both supported endpoints:

| Codex | `rubien/liveness` result |
|---|---|
| 0.142.5 | immediate JSON-RPC error response (`-32600`) |
| 0.145.0 | immediate JSON-RPC error response (`-32600`) |

The probe is local, side-effect free, independent of authentication and model
availability, and available without adding an experimental protocol method.

## Invariants

1. The watchdog exists only while at least one turn is active on its server
   generation.
2. Any inbound frame counts as activity. Regular streaming therefore avoids
   probes.
3. A successful or error probe response means alive and starts a fresh silence
   interval.
4. A probe timeout is generation-scoped. It cannot kill a replacement server.
5. Wedge recovery fails every live turn from that generation with the same
   visible notice, discards generation-local thread leases, kills the process
   group, and installs the existing reap gate before new work can spawn.
6. Recovery never replays a turn. The next explicit Retry/send resumes its
   durable thread on a newly initialized app-server.
7. Window close, normal server exit, profile replacement, and app shutdown
   cancel their generation's watchdog.
8. Failure to prove that the old process group reaped retains the existing
   safety behavior: block a replacement rather than overlap two app-servers in
   Codex's shared home.

## Implementation

1. Add the pure `rubien/liveness` request encoder and a protocol test.
2. Add generation-local inbound activity and watchdog state to `Server`.
3. Start the watchdog after `turn/start` resolves; share one watchdog across
   all active turns in that generation.
4. On a probe timeout, use the existing process-group kill/reap recovery gate
   and finish all affected streams with a dedicated unresponsive-runtime
   notice.
5. If an individual setup request times out, probe before recycling the
   shared generation. A responsive server fails only that request; a late
   `turn/start` response is interrupted so it cannot continue headlessly.
6. Extend the fake server to record and answer liveness probes.
7. Add integration coverage that:
   - observes a successful probe during a deliberately silent but responsive
     turn;
   - sends `SIGSTOP` to the live fake app-server;
   - verifies the affected stream finishes with the wedge notice and the
     stopped process is killed;
   - verifies the next turn respawns and resumes on a different process.

## Verification

- Run `CodexAppServerProtocolTests` and `CodexProviderTests`.
- Run the full Swift test suite.
- Run a real process `SIGSTOP` recovery drill through the integration test.
- Run Python syntax validation and `git diff --check`.
- Complete the repository's independent review and simplify sweep before
  delivery.

## Outcome

Implemented on 2026-07-23. Independent review caught two shared-runtime
hazards before delivery:

- an ordinary `thread/start`, `thread/resume`, or `turn/start` timeout no
  longer recycles the generation until the local liveness probe also fails;
- the persistent watchdog starts only after `turn/start` succeeds, rather
  than while thread setup is still in flight.

The recovery drill now covers both a dedicated provider and two simultaneous
owners of one shared server. In the shared case, both affected streams receive
exactly one notice, the stopped process is reaped once, and the next explicit
send resumes through a new generation. A separate slow-`turn/start` test
proves that a responsive dispatcher is not recycled and that the unrelated
conversation survives. Timed-out turn starts are tombstoned at the
actor-isolated timeout edge, their late responses are interrupted, and an
unresolved tombstone forces generation cleanup once all live turns drain.

Final verification:

- `CodexAppServerProtocolTests`: 49 passed;
- `CodexProviderTests`: 86 passed;
- complete non-Sparkle suite: 2,177 passed, 9 live-network tests skipped,
  0 failures;
- the 11 optional Sparkle-only tests passed separately, avoiding the real
  updater's delayed modal during a long XCTest process;
- real 0.142.5 and 0.145.0 app-servers both returned the expected immediate
  JSON-RPC error to the unsupported liveness request;
- Python fixture syntax validation and whitespace checks passed.
