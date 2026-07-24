# Assistant Conversation Runtime — Architecture Options

- **Status:** selected architecture and follow-up gates, v8 (v2 revised after a first
  independent codex review; v3 after a second codex pushback that added the
  cross-window thread-staleness hazard, Option B-T, and the F1/F2 split; v4
  pruned dominated options A/C′/D/E to tombstones (§3, end); v5 incorporated
  a third codex review citing 0.145 source: resume-overrides ignored on
  loaded threads, plain re-resume does not reread the rollout, MCP runtime
  confirmed per loaded session; v6 incorporates the 0.145 behavioral spike,
  the cross-version web-off fix, and the implemented thread-lifecycle
  foundation; v7 records the partial B-T implementation; v8 records the
  live-runtime MCP inventory path and the conservative plugin/cwd boundary.
  First-review findings archived at
  `/tmp/rubien-runtime-options-review-2026-07-23.md`)
- **Date:** 2026-07-23
- **Scope:** how Rubien maps assistant *conversations* to backend *runtime
  processes*, for both providers. Written during beta, deliberately weighing
  long-term architecture over sunk cost.
- **Repo state this document is written against:** `a4e61ad "Support concurrent
  assistant conversations"` is the committed Option B baseline. The current
  working tree implements the selected partial B-T refinement while retaining
  B's one shared app-server and four-turn budget.

---

## 1. Background

### 1.1 What a "conversation" is — and what actually owns a provider

Each reader window (PDF or web) and main-window Home owns one
`ChatSessionController`, built by `ReaderChatSession.make(...)`. A conversation
is Rubien's `conversationID` (UUID) plus the provider thread/session id once one
exists. A **turn** is one user message and its streamed response.

Ownership fact that constrains every option: **the provider instance is owned by
the controller (≈ the window), not by the conversation.** "New conversation"
retains the provider; only a backend switch rebuilds it from `providerFactory`
(`ChatSessionController.swift` — see the `providerFactory` doc comment).
Scheduled runs (`ScheduledJobCoordinator`) and the Settings availability probe
construct their own short-lived providers. So the finest-grained "one runtime
per X" any option gets without extra work is **per window/controller**, not
per conversation.

### 1.2 The two backend contracts (the asymmetry that drives everything)

| | Claude Code | Codex |
|---|---|---|
| Integration contract | one-shot CLI: `claude --print --input-format stream-json --output-format stream-json [--resume <id>]` | long-lived JSON-RPC daemon: `codex app-server` over stdio (`initialize` → `thread/start`/`thread/resume` → `turn/start`) |
| Unit of work | a whole OS process **per turn**; the process *is* the turn | a request against a live server; `turn/interrupt` ends a turn, server lives on |
| Conversation state | on disk: `~/.claude/projects/<cwd>/<session>.jsonl`, rehydrated by `--resume` | in server RAM (loaded threads), durable + resumable by id (`thread/resume`) |
| Config: per **turn** | everything (plain argv flags each invocation) | `effort`, inputs (`turn/start`) |
| Config: per **thread** | n/a | `cwd`, Apps, canonical Rubien MCP full/read-only posture, `sandbox`, `approvalPolicy`/`approvalsReviewer`, `model` (`thread/start`; cwd/config also on cold `thread/resume`) |
| Config: baked at **launch** | n/a | `CodexRuntimeProfile`: web access, installed-plugin posture, and app-server cwd while plugins are enabled |
| Approvals | control protocol on the turn process's stdin/stdout | server-initiated JSON-RPC requests on the connection |
| Upstream topology precedent | n/a (only mode) | terminal TUI embeds an **in-process** app-server per invocation; **codex ≥0.145 also ships `app-server daemon` / `proxy` / Unix-socket multi-client transport** (a shared-daemon topology now exists upstream — see Option F) |

Corrections vs. v1 of this document, all decision-relevant:

- **The launch-baked feature surface is now web and installed plugins.** Sandbox
  and model ride `thread/start`; effort rides `turn/start`; initial cwd, Apps,
  and the canonical Rubien MCP full/read-only posture ride new-thread config.
  `CodexRuntimeProfile` contains `webAccess`, `pluginsEnabled`, and a
  conditional `pluginWorkingDirectory`. With plugins off, different thread
  cwd values share one process. With plugins on, the startup cwd remains in
  the process fingerprint because project/plugin discovery has not yet been
  proven thread-local. A server respawn is therefore needed when web/plugins
  change, or when a plugin-enabled request moves to a different workspace.
- **This boundary is behavioral, not merely schema-level.** Codex 0.145's
  app-server schema accepts
  generic config overrides on `thread/start`/`thread/resume` and sticky
  cwd/model/sandbox/approvals/effort overrides on `turn/start`. The 0.145
  behavioral spike (§5.1) proved initial cwd, Rubien MCP read-only/full
  posture, and Apps posture on new threads in one server. It disproved
  per-thread web isolation and established only config-level, not runtime,
  plugin isolation. The viable result is therefore **partial B-T**, with web
  and plugins still process-scoped. **Caveat (v5/v6):**
  `thread/resume` config overrides are **ignored when the thread is already
  loaded and subscribed** — changing a *live* thread's posture requires
  `thread/unsubscribe` followed by an authoritative unload or server
  replacement before cold `thread/resume`. A successful unsubscribe alone is
  insufficient because Codex retains zero-subscriber threads in memory.
  Rubien therefore cold-recycles the server when no unrelated turn is active,
  or fails visibly until that turn drains. New threads take posture at
  `thread/start` with no transition cost.
- **Thread unloading is subscriber-conditional, and each loaded session
  carries its own MCP runtime (v5: confirmed against 0.145 session
  initialization).** Codex creates an MCP runtime/connection manager per
  loaded session and starts that session's configured MCP servers; unload
  happens ~30 min after the last `thread/unsubscribe` (start/resume
  auto-subscribes). The process model is approximately **one app-server +
  loaded threads × configured MCP children**. At the v5 baseline Rubien never
  unsubscribed and kept ids in `loadedThreadIDs` forever. The v6 lifecycle
  implementation replaces that set with generation-local, reference-counted
  leases, releases the final owner with `thread/unsubscribe`, retains a
  zero-owner cached/unknown state until it has authoritative evidence,
  reconciles `thread/closed`, and barriers resume against unsubscribe. Late
  setup responses are quarantined and balanced with unsubscribe. Upstream's
  30-minute idle unload still determines when zero-subscriber MCP children
  actually exit unless Rubien replaces the idle server first.
- **Conversations cross windows.** History resume works from any surface
  ("Home may open a reader conversation and vice versa" —
  `ChatSessionController.resume`), so the *same provider thread* can be
  driven from different windows over time. Any topology with more than one
  server must answer: what happens when server A holds thread T in memory
  while server B appends a turn to T? (See Option C's staleness hazard.)

### 1.3 Process footprint and the shared library

Rubien's library channel is the bundled `rubien-cli mcp` run as a **stdio
child** of each agent runtime (`MCPContentChannel`). Additional per-server
costs that v1 undercounted:

- Even with `loadUserTools == false`, user-configured `~/.codex` MCP servers
  still load (per the invocation comments in `CodexProvider.swift`) — and they
  load **per loaded thread**, not per server (§1.2). A consequence worth
  stating: for the same set of loaded threads, B and C carry the **same** MCP
  child count; the footprint delta between them is only the extra app-server
  processes themselves.
- The resident MCP host spawns a further `rubien-cli` subprocess per tool call
  (`MCPServer.swift`), and agent shell tools/subagents add children.
- SQLite/WAL is multi-process **safe**, but there is one writer and Rubien's
  busy timeout is 5 s (`AppDatabase.swift`): N agents issuing concurrent write
  tools can *fail operations* (not corrupt data). Functional correctness under
  contention needs load testing, not a footnote.

### 1.4 Evidence that concurrent app-servers are not free

Two places in the code record *reproduced* failures from overlapping servers:
`sharedModelCatalog` exists because "a standalone metadata app-server racing
the first real turn reproduced the cold-start initialize failures"
(`CodexProvider.swift`), and availability probes are preempted/reaped before a
turn's server may spawn. **Any multi-server option therefore keeps a
process-wide spawn/probe/reap coordinator** — what gets deleted is turn
*multiplexing*, never launch coordination.

### 1.5 Two layers — only one is in question

1. **Session plane** (admission semantics): one active turn per provider
   session, independent conversations concurrent, same-owner supersession,
   scheduled + interactive coexistence. Note precisely where these live:
   `AssistantTurnGate` covers *interactive resumes with a known session id*;
   scheduled runs bypass it; supersession lives in each provider; Claude's
   reap-safety lives in `ClaudeSessionLeaseCoordinator`. These semantics are
   settled (OpenClaw's per-session lanes + global cap are the same shape) and
   every option keeps them.
2. **Runtime layer** (Codex process topology): the decision below. Claude needs
   no persistent-process topology choice — its per-turn engine and lease are
   already the right fit — so all options leave Claude as-is.

---

## 2. Invariants any option must preserve

1. **No session forking.** Two turns never concurrently resume the same
   provider session/thread.
2. **Turn posture honored, at the correct scope.** Web and installed plugins
   need a compatible process; cwd, Apps, Rubien MCP, sandbox, model, and
   approvals are per-thread; effort is per-turn.
3. **Interactive approvals** (`approvalsReviewer: "user"` pinned — rules out
   `codex exec` for interactive chat; see the Option E tombstone).
4. **Scheduled + interactive coexistence** without mutual starvation.
5. **Durable transcripts unaffected** (`AgentEventEnvelope` seam;
   `runtimeGeneration` may simplify per option).
6. **Turn-scoped cancel vs window-close shutdown** remain distinct.
7. **Truthful failure**: a dead/wedged runtime surfaces as failed turns on the
   affected conversations, never a silent hang. (A SIGSTOP-style wedge needs
   *detection* under every option — no topology solves it by itself.)
8. **Global resource budget.** Some app-wide cap on concurrent Codex turns and
   live app-servers, plus serialized cold-start, survives in every option (one
   account, one rate-limit budget, one `~/.codex`).
9. **Metadata arbitration.** Availability probes, History reads, and model
   catalog queries never race a turn's server lifecycle (§1.4).

---

## 3. Options

Live options: **B-T** (selected and implemented), **B+** (fallback if residual
serialization proves material), **C** (fallback
simplification), **F1/F2** (conditional). Dominated options are tombstoned at
the end of this section.

### Option B — one shared app-server, N concurrent turns *(committed baseline)*

The broker multiplexes up to `maxConcurrentTurns = 4` over one registry-pinned
server; over-cap or profile-mismatched work queues FIFO; threads stay loaded;
notifications route by turn id.

- **Pros**
  - One warm server: bring-up paid once per launch; new conversations and
    follow-ups start fast *while a compatible server is live* (a profile flip
    or the availability probe's deliberate kill-and-recheck still cold-starts).
  - Minimal resident footprint regardless of open windows.
  - Session-plane semantics mirror OpenClaw's proven lane model — with the
    caveat that OpenClaw's agent loop is embedded in-process, so its version of
    "shared runtime" carries none of the cross-process broker cost ours does.
  - Committed, tested, reviewed — zero migration cost.
- **Cons**
  - **Head-of-line profile serialization.** Admission requires an empty queue
    *and* an exact profile match (`canAdmitImmediately`): once an incompatible
    turn reaches the FIFO head, later work queues even with free capacity —
    the tests encode this. Before partial B-T, scheduled read-only runs and
    different config cwd values therefore never overlapped interactive work;
    any remaining web/plugin difference still behaves this way. Active turns aren't
    paused, but new admissions stall behind each posture transition's
    drain-and-respawn.
  - **Broker complexity**: turn-id routing, per-owner identity retirement,
    handshake gating, reservation handoff — the region where the 2026-07-22
    review found majors.
  - **Crash blast radius = the active turns on that server generation (≤4) plus
    pending metadata.** `serverClosed` fails only those; idle conversations
    stay durable and the next send transparently respawns (tested). A *wedge*
    (unresponsive-but-alive) is worse — all conversations stall until detected
    — but that's invariant 7, needed everywhere.
  - **Loaded-thread accumulation is now bounded by ownership plus Codex's idle
    unload window** (§1.2). The former grow-only `loadedThreadIDs` behavior is
    remediated by reference-counted unsubscribe.

### Option B-T — B with partial thread-scoped posture *(implemented in v7)*

Keep the single shared server and committed broker, but move only the
behaviorally proven dimensions down to new-thread config: cwd, Rubien MCP
read-only/full posture, and Apps posture. Keep web and plugins in the launch
profile. This removes the avoidable profile serialization attributable to
cwd/MCP/Apps without multiplying servers.
It does **not** remove every scheduled↔interactive conflict by itself:
web/plugin differences retain B's existing drain-and-respawn boundary, and a
plugin-enabled workspace change also retains that boundary.

- **Pros:** removes the proven thread-scopable portion of B's functional flaw;
  keeps the single crash domain, committed broker, and one event dialect; and
  is the smallest evidence-backed delta from HEAD. Scheduled runs start
  **new** threads, so their cwd/MCP/Apps posture takes effect at
  `thread/start` with zero live-thread transition cost. A remaining
  process-scoped plugin difference can still serialize them when an interactive
  conversation has explicitly opted into installed plugins. Plugin-disabled
  threads may use different cwd values concurrently; plugin-enabled threads
  share only when their startup workspace is also the same.
- **Not free for live threads (v5).** Changing posture on an
  already-loaded-and-subscribed thread (e.g. changing its cwd, Apps, or MCP posture)
  requires `thread/unsubscribe` → authoritative unload/server replacement →
  cold `thread/resume` with the new config, paying replacement, handshake,
  rehydration, and MCP restart. Rubien performs that replacement only with no
  unrelated active turn; otherwise it reports the conflict and waits for an
  explicit retry.
- **Lifecycle prerequisite completed:** generation-local leases now track
  owners, subscribed/cached/unknown state, and the effective profile; the final
  owner sends `thread/unsubscribe`, `thread/closed` reconciles state, uncertain
  outcomes remain quarantined, and late setup responses are cleaned up.
- **Behavioral gate resolved only for the partial scope.** A new unattended
  read-only thread demonstrably lacked mutation tools and rejected a direct
  create call; full and read-only Rubien MCP children coexisted under one
  server; Apps and cwd differed by thread. Web failed isolation, and plugins
  lacked a valid runtime control, so neither moves.
- **Compatibility floor preserved:** the new-thread cwd, Rubien MCP, and Apps
  controls pass behaviorally on both the existing 0.142.5 baseline and 0.145,
  so partial B-T does not require raising Rubien's Codex floor.
- **Scheduled isolation stays inside the owned root:** scheduled threads use
  app-server `config/read {cwd}` to enumerate effective ambient MCP entries,
  then disable each enabled server by name in thread config before restoring
  Rubien's canonical read-only entry. This method and response shape were
  verified on 0.142.5 and 0.145. Rubien no longer starts a concurrent
  `codex mcp list` root beside a live app-server. A scheduled resume also
  fails closed if that thread is still subscribed with an interactive profile;
  cached mismatches use the same safe cold-recycle rule.

### Option B+ — B for interactive, private per-run server for scheduled *(hybrid)*

Keep the shared server for chat; give each scheduled run its own short-lived
app-server (spawn → run → reap), eliminating the scheduled↔interactive profile
conflict while keeping one event dialect and the committed broker.

- **Not safe to adopt first.** The code records *reproduced* failures from
  concurrent app-server roots (§1.4), and the current recovery gate is
  broker-local — a private scheduled broker would bypass it. B+ is gated on:
  (1) the process-wide spawn/probe/reap coordinator, then (2) a realistic
  two-server coexistence soak. **Fallback if the B-T spike fails**, not the
  near-term default.

### Option C — one app-server per window/controller (lazy spawn, idle reap)

Each `ChatSessionController`'s provider owns a private broker + server, spawned
on first turn, reaped on window close/idle; reopening resumes by thread id.
(*Per-window*, not per-conversation — see §1.1; per-conversation would
additionally require rotating providers on every New Conversation.)

- **Pros**
  - Deletes cross-conversation turn multiplexing: turn-id routing across
    owners, profile-transition drain, reservation handoff, the 4-turn scheduler.
  - Fault containment: a crashed/wedged server affects one window.
  - Full posture freedom: scheduled and interactive overlap trivially; a
    user's web-toggle flip respawns only their window's server.
- **Cons / honest scope (v1 understated all of these)**
  - **Cross-window thread staleness — a correctness hazard C *introduces*
    (v3).** Conversations cross windows (§1.2), and the broker's fast path
    skips `thread/resume` for any id in `loadedThreadIDs`
    (`CodexProvider.swift`). Under C: window A's server loads thread T →
    window B's server resumes T and appends a turn → back in A, the fast path
    runs `turn/start` against **stale in-memory history**. The turn gate only
    prevents *simultaneous* turns, not this. Neither B (one server, one memory
    image) nor Claude (always rehydrates from disk) can exhibit it. **The
    cheap fix is dead (v5):** a matching `thread/resume` *rejoins the
    existing in-memory thread without rereading the rollout* (0.145 source
    review), so merely dropping the `loadedThreadIDs` fast path does nothing.
    Surviving fixes, all real coordination machinery: unsubscribe + forced
    session teardown + cold resume on the stale server; session→runtime
    affinity; an explicit atomic ownership-transfer protocol; or recycling
    the stale window's server. Each erodes C's simplicity advantage
    substantially — C sits further down the decision tree than v3/v4
    suggested.
  - **Not "flip a flag."** `CodexProvider(shareAppServer: false)` exists but is
    a test seam. Production C still needs: the process-wide spawn/probe/reap
    coordinator (§1.4); global turn + server budget (invariant 8); per-broker
    metadata arbitration, same-owner supersession, and identity retirement
    (they are not sharing artifacts); and a **model-catalog redesign** —
    `sharedModelCatalog` hardcodes the shared runtime precisely because a
    standalone catalog server racing a turn reproduced cold-start failures.
  - **Cold starts are unproven at Rubien's cost structure.** The terminal-TUI
    precedent does not transfer: the TUI embeds the server in-process and pays
    no external spawn/handshake/MCP-wiring. §5 measurements are a *gate*, not
    a formality — including simultaneous cold starts (the reproduced failure
    mode) and long-thread `thread/resume` rehydration.
  - **Footprint is per-window × §1.3's multiplier** (user MCP servers load per
    server even with `loadUserTools == false`), bounded only by the global
    budget + idle reaper — never "unbounded" by design, but the budget must be
    built, not assumed.
  - Migration must be feature-flagged with both topologies co-existing through
    a beta soak (telemetry: latency P50/P95, RSS, process counts, failures)
    before any B machinery is deleted — otherwise there is no rollback.

### Options F1/F2 — socket/daemon transports *(needs a spike; split in v3)*

Installed codex (0.145) exposes `app-server daemon`, `proxy`, Unix-socket
transport, and multi-client subscriptions. Per-window Rubien *connections* to
one server could simplify event routing while preserving **one authoritative
in-memory thread** (which also avoids C's staleness hazard by construction).
Two distinct shapes with different ownership/upgrade/shutdown/recovery
semantics — do not conflate:

- **F1 — Rubien-owned socket-listening child**: Rubien spawns and owns the
  process; lifecycle is app-scoped like today's stdio server.
- **F2 — Codex's detached managed daemon**: survives the app; upgrade and
  recovery are Codex's, not Rubien's; interacts with the "stale binary after
  npm upgrade" failure mode already seen with broker chains.

Caveats for both: all connections share one crash/wedge domain and resource
budget (this is **B's isolation profile with better routing, not C's**), and
the socket/WebSocket transport is documented **experimental / unsupported for
production**. Evaluate only if B-T fails and before committing to C.

### Dominated options — tombstones *(pruned in v4)*

Removed as live options; recorded with their killers and resurrection
conditions so they aren't re-proposed from scratch.

- **A — shared server, single turn** *(the pre-`a4e61ad` shipped behavior and
  the reported defect: "Codex is busy with another Rubien conversation")*.
  Strictly dominated by B, which is committed and keeps every property of A
  while adding concurrency. Historical baseline only; no resurrection
  condition.
- **C′ — one app-server per turn.** Dominated by C: pays full spawn +
  handshake + MCP wiring + rollout rehydration (cost grows with transcript
  length) on *every message*, for isolation C already achieves per window.
  Codex's server model is built to stay warm; Claude's per-turn model works
  only because its CLI is one-shot-optimized. No resurrection condition.
- **D — profile-keyed server pool.** Every benefit is captured cheaper
  elsewhere: B-T removes the profile boundary entirely, B+ removes the
  scheduled conflict, C provides real isolation. Its residual niche — B-T
  failed AND interactive profile churn is common AND C is blocked — doesn't
  justify pool lifecycle plus B's broker per pool entry (and it inherits C's
  cross-window staleness hazard across entries). Resurrect only if that exact
  conjunction materializes.
- **E — `codex exec` for scheduled runs.** Weakly dominated by B+: same
  decoupling with one event dialect and the committed broker, where E must
  re-solve approval-policy pinning, read-only Rubien-MCP injection, durable
  session-id capture, outcome/usage/interruption mapping, and process-group
  cancellation (`ScheduledJobRunner` derives all of these from the app-server
  stream today). **Resurrection condition:** the B+ two-server coexistence
  soak fails — `codex exec` is a one-shot process rather than a second
  app-server root, so it may sidestep the reproduced concurrent-root failures
  that gate B+.

---

## 4. Comparison

N = open assistant windows. Entries assume the global budget (invariant 8)
exists in every option.

| | B (baseline) | B-T (selected) | B+ | C (per-window) | F1/F2 |
|---|---|---|---|---|---|
| Concurrent interactive conversations | ≤4, then queue | ≤4, no profile queue | ≤4, then queue | ≤ budget | TBD |
| Scheduled ↔ interactive overlap | ✗ (head-of-line) | ✓ | ✓ | ✓ | TBD |
| Cross-window thread continuity | ✓ (one server) | ✓ | ✓ (jobs don't resume chat threads) | **✗ until staleness fix (§5.2)** | ✓ (one authoritative thread) |
| Crash blast radius | active turns on server (≤4) | same | same, jobs isolated | one window | all connections (one domain) |
| Wedge blast radius (until detected) | all | all | interactive all | one window | all |
| Resident processes | 1 server + threads × MCP (needs unsubscribe) | same as B (unsubscribe is prerequisite) | B + 1 server per running job | N servers + threads × MCP (reaped) | 1 server + threads × MCP |
| New-conversation latency | warm* | warm (no profile respawns) | warm* | cold spawn (measure) | TBD |
| Posture-flip cost | global drain+respawn | new thread: free; live thread: unsubscribe→cold resume | global (interactive) | one window respawn | TBD |
| Broker complexity | highest | highest (unchanged) | highest + coordinator | low + shared coordinator | TBD |
| Migration from baseline | none | **completed** | small (coordinator + soak first) | medium (flag + soak + catalog redesign + staleness fix) | spike first |

\* warm only while a compatible server is live; profile flips and the
availability probe's kill-and-recheck cold-start it.

---

## 5. Measurements and spikes gating any move beyond partial B-T

Ordered by leverage (v3 — the first two are cheap, local, and can each
collapse the decision tree):

1. **B-T spike — completed on 0.145:** behaviorally proved new-thread cwd,
   Apps, and Rubien MCP read-only/full isolation; disproved per-thread web;
   plugin runtime remained inconclusive. Loaded subscribed resume retained old
   posture; immediate unsubscribe/resume switched MCP and Apps but not cwd;
   cold resume after server restart switched all proven dimensions. The
   surviving new-thread partial B-T implementation is complete. A follow-up run against
   the existing 0.142.5 baseline also passed cwd, Rubien MCP enforcement, and
   Apps runtime isolation, so no version-floor increase is required.
2. **Live-thread transition behavior — completed; cross-server catch-up still
   gated:** source review and the checked-in live spike confirm that a matching
   `thread/resume` rejoins the cached in-memory thread without rereading the
   rollout, even after immediate unsubscribe. The retained implementation now
   uses unsubscribe → idle server replacement → cold resume for a changed or
   uncertain profile. Measuring cold-resume catch-up after a *different
   process* appended turns remains a gate for C, B+, or E.
3. **MCP-per-thread behavioral confirmation — partially completed:** distinct
   full and read-only Rubien MCP children were observed for two threads.
   Verifying child exit after Codex's fixed idle-unload window remains.
4. **End-to-first-token latency** (not just `thread/start` accepted): P50/P95
   for cold spawn — including **simultaneous cold starts** (the reproduced
   failure mode), with a realistic user `~/.codex` MCP configuration.
5. **`thread/resume` rehydration cost** vs. transcript length (C's reopen
   path).
6. **RSS per app-server** including MCP children under real config; realistic
   N (open windows) on a maintainer machine.
7. **B long-uptime growth — implementation remediated:** the grow-only set is
   replaced by reference-counted leases and final-owner unsubscribe. A
   long-duration observation across the upstream idle window remains useful,
   but is no longer an architecture blocker.
8. **SQLite write contention**: N agents issuing concurrent write tools against
   the 5 s busy timeout — measure operation-failure rate.
9. **Wedge drill — completed for retained B:** a literal `SIGSTOP` now proves
   generation-wide detection, visible failure for every affected turn,
   process-group reap, and clean resume on the next explicit send. Repeat
   under a C prototype only if C is revived.
10. **F1/F2 spike** (only if B-T fails): socket/daemon transports —
    per-connection posture isolation, multi-client behavior, experimental
    transport status, ownership/upgrade semantics per shape.

---

## 6. Recommendation *(v8)*

**Completed prerequisites — safe and needed under every option:**

1. **Wedge detection + auto-respawn — completed.** Quiet active turns use a
   local JSON-RPC liveness probe; a failed probe reaps the exact generation,
   fails every affected stream without replay, and the next explicit send
   spawns cleanly. A plain request timeout must also fail the probe before it
   can recycle the shared runtime.
2. **Reference-counted `thread/unsubscribe` + per-thread state — completed.**
   The implementation now has owner-counted generation-local leases,
   unsubscribe/resume barriers, cached/unknown quarantine,
   `thread/closed` reconciliation, and late-response cleanup, including
   shutdown, timeout, and server-exit race coverage.

**Process-scoped plugin policy — decided and implemented:**

- The explicit user-tools opt-in controls both Codex Apps and installed
  plugins. Rubien pins both directions so user/project Codex configuration
  cannot contradict the toggle: Off disables both; On enables both. Scheduled
  requests force the opt-in Off, disabling both Apps and plugins; read-only
  invocation also enforces plugins-off defensively. Plugin posture remains a
  process-profile boundary and changes use the existing controlled
  drain/respawn path. While plugins are enabled, startup cwd remains in the
  process fingerprint until project/plugin discovery is proven thread-local.

**Selected topology — implemented, preserving the 0.142.5 compatibility baseline:**

- **Partial B-T for new and genuinely cold threads:** cwd, Rubien MCP
  read-only/full posture, and Apps posture now ride `thread/start` and cold
  `thread/resume` config.
  Web and installed plugins remain process-scoped. Scheduled default-web runs
  can now overlap default interactive runs on the same PID with their own
  read-only Rubien MCP session. Live subscribed threads keep their recorded
  effective profile; a subscribed scheduled mismatch fails closed rather than
  borrowing interactive access. A cached or uncertain mismatch cold-recycles
  the idle server before resume, and reports a visible retry condition while
  another turn is active. Scheduled MCP inventory is read through the owned
  app-server's `config/read` method, so this path starts no second Codex root.

**Next decision gate:**

- Residual serialization instrumentation is implemented. Rubien now keeps one
  local aggregate report of Codex turn count, profile-vs-capacity waits and
  durations, and controlled profile respawns, with web/plugin/workspace
  breakdowns. It contains no prompts, paths, IDs, or per-turn timestamps and
  can be copied or reset from Settings ▸ Assistant. Profile-wait timing stays
  open through replacement and initialization, not merely until the scheduler
  reserves a slot.
- Collect a representative window that includes normal conversations,
  web-toggle changes, and plugin opt-in changes. If profile-only waiting and
  respawn churn are not material relative to total turns and the capacity
  control, stop: retained B plus partial B-T is the long-term choice.

**Only if residual serialization is material:**

- **B+** for the scheduled↔interactive conflict — sequenced strictly as:
  process-wide spawn/probe/reap coordinator first, two-server coexistence
  soak second, adoption third.
- **C** remains the fallback simplification, but further down the tree than
  v3/v4 placed it: its cheapest staleness fix is dead (plain re-resume rejoins
  stale memory — §5.2), so it carries *three* gates: the cold-start
  measurements (§5.4–5.6), a staleness protocol chosen from the §3 surviving
  list (teardown+cold-resume / affinity / ownership transfer / server
  recycle), and the feature-flag beta soak before any B machinery is deleted.
- **F1/F2** evaluated separately (experimental transport; B's isolation
  profile, not C's) — most interesting if §5.2 shows in-memory threads are
  the only authoritative copy, since one shared server then has structural
  value beyond footprint.

**Decision-tree summary:** the process-scoped plugin policy is settled →
new/genuinely-cold-thread partial B-T is implemented on the verified
0.142.5/0.145 surface → collect the implemented residual-serialization report.
Only a material profile-only impact reopens B+; C and F1/F2 remain behind
their existing gates.

### Final combined verification

- Complete non-Sparkle suite:
  `swift test --disable-default-traits` — 2,204 tests executed, 9
  live-network tests skipped, 0 failures.
- Focused lifecycle/measurement regression set — 8 passed, including sticky
  cached cwd, setup-overlap safety, unsubscribe timeout and unknown status,
  late setup cleanup, exact resumed identity, and replacement-handshake
  timing.
- Final independent correctness, test-coverage, and simplification reviews
  reported no actionable findings.
- Python syntax validation for the live spike and fake app-server fixtures,
  plus `git diff --check`, passed.

Premises broken by review, recorded so the reasoning isn't re-lost:

- *v1 → v2 (first codex review):* posture is mostly thread-scoped, not
  launch-baked; C's migration is not "flip a flag" (test seam; coordinator /
  budget / catalog work remains); B's crash radius is active turns (≤4) with
  transparent tested resume, not "all conversations"; the terminal-TUI
  precedent doesn't price external spawns (it embeds the server in-process).
- *v2 → v3 (second codex review):* C introduces a cross-window thread
  staleness hazard (conversations cross surfaces; the `loadedThreadIDs` fast
  path skips `thread/resume`); the remaining launch-profile boundary is
  plausibly Rubien's argv choice, not a Codex constraint (→ B-T); B+ is not
  safe *first* (broker-local recovery gate + reproduced concurrent-root
  failures); F is B-shaped isolation with better routing, split F1/F2, and
  its socket transport is experimental; MCP state may scale per loaded
  thread (→ unsubscribe priority).
- *v4 → v5 (third codex review, citing 0.145 source):* `thread/resume`
  config overrides are ignored on a loaded+subscribed thread — B-T's
  live-thread posture flip costs unsubscribe → cold resume ("per-thread,
  free" was wrong); a matching `thread/resume` rejoins in-memory state
  without rereading the rollout — C's cheapest staleness fix is dead; MCP
  runtime per loaded session is confirmed — unsubscribe is a B-T
  prerequisite, and B-vs-C footprint differs only by the server processes
  themselves.
