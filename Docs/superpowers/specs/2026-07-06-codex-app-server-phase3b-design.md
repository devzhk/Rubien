# Codex app-server provider (Phase 3b) — Design

**Date:** 2026-07-06
**Status:** Empirical spike COMPLETE against live `codex-cli 0.142.5` (all high-risk unknowns resolved); implementation not started. Extends the master design (`2026-07-04-assistant-chat-sidebar-design.md` §4.3 / D3 / D6 / Risks #2/#8/#16) with the version-exact protocol.
**Decision:** *app-server now* (user, 2026-07-06) — build the full `codex app-server` approval-channel provider in Phase 3b (not exec-first). Rationale: honors the master doc's v4 correction (Codex gains a real per-action approval channel, no longer "read-only-forever"), and front-loads the approval infra that Phase 4 library-writes will need.

## 1. Summary

`CodexProvider` drives a **long-lived `codex app-server`** subprocess — stdio JSON-RPC 2.0, the **v2 thread → turn → item** protocol — as the Codex analogue of `ClaudeCodeProvider`. Codex gains a real per-action approval channel: mutations (shell/file/MCP) elicit **server-initiated approval requests** that surface on the same native approval card as Claude's control protocol. Reads run silently inside the OS sandbox. Driven the same way as Claude — per-invocation params/flags over the real `~/.codex`, **no managed config home** (§4). Verified end-to-end: handshake, streamed turn, per-request approval/effort override, rubien `-c` de-dup, and the mutation → approval → resume flow.

The existing `AgentProvider` protocol, `AgentEvent`/`ApprovalDecision` enums, and the (already provider-agnostic) `ChatSessionController` accommodate Codex with **no protocol changes** — the whole delta is a new provider + its transport.

## 2. Verified protocol (the contract — live 0.142.5)

Captured frames: `frames-baseflow`, `frames-isolation`, `frames-approval` (spike harness `spike.mjs`; curated into fixtures in 3b-1). Schema is authoritative from `codex app-server generate-ts --experimental` / `generate-json-schema --experimental`.

### 2.1 Process + transport
- **`codex app-server`** (no subcommand) → stdio JSON-RPC 2.0, **newline-delimited** messages (default `--listen stdio://`).
- **Long-lived + stateful:** ONE `initialize` handshake, then N threads/turns over the process lifetime. (Contrast Claude: one process per turn.) This is the D3 "long-lived stdin loop" model — mandatory here, not the deferred optimization.
- **Handshake:** client `initialize {clientInfo:{name,title,version}, capabilities:{experimentalApi:true, requestAttestation:false}}` → response `{userAgent, codexHome, platformFamily, platformOs}`; then client `initialized` notification. **`experimentalApi:true` is REQUIRED** for the v2 thread/turn methods.
- **Three inbound message kinds** must be demultiplexed: (a) **responses** to our client requests (our id space: 1,2,3…), (b) **server-initiated requests** needing a response (server id space, **starts at 0** — a *separate* counter; correlate the approval response by echoing the server's id), (c) **notifications** (no id).

### 2.2 Turn flow (new conversation)
```
→ thread/start {cwd, sandbox:"read-only", approvalPolicy:"on-request",
                developerInstructions:<reference seed>, model?, config?, ephemeral:false}
← {thread:{id, sessionId, preview, ...}, model:"gpt-5.5", sandbox:{type:"readOnly",networkAccess:false},
   approvalPolicy:"on-request", reasoningEffort:"medium", ...}
→ turn/start {threadId, input:[{type:"text", text:<prompt>, text_elements:[]}], effort:"low"}
← {turn:{id, status:"inProgress", ...}}
```
Streamed notifications (each carries `threadId`/`turnId`); handled ones in bold, rest ignored:
- **`thread/started {thread}`** → `.sessionStarted(thread.id)` (thread id is STABLE across a thread's turns — no per-turn rotation, unlike Claude).
- **`turn/started {threadId, turn}`** → capture `turn.id` (the `turn/interrupt` target).
- **`item/started {item, threadId, turnId}`** — `item.type` ∈ {userMessage, agentMessage, reasoning, commandExecution, fileChange, mcpToolCall, webSearch, …}. Tool-bearing types → `.toolUseStarted(name, detail)`.
- **`item/agentMessage/delta {itemId, delta}`** → `.assistantDelta(delta)`.
- **`item/completed {item}`** — agentMessage → `.assistantMessageCompleted(item.text)`; tool item → `.toolUseCompleted(name)` (or `.toolDenied` when `status:"declined"`/`"failed"`).
- **`thread/tokenUsage/updated {tokenUsage:{total:{inputTokens,outputTokens,cachedInputTokens,…}}}`** → accumulate (see 2.5).
- **`turn/completed {turn:{status, error, durationMs}}`** → `.turnCompleted(usage)`.
- **`error {error:{message}, willRetry, turnId}`** → `.providerNotice(message)`.
- Ignored noise: `thread/settings/updated`, `thread/status/changed`, `mcpServer/startupStatus/updated`, `account/rateLimits/updated`, `remoteControl/status/changed`, `serverRequest/resolved` (except to clear a pending card).

### 2.3 Resume + History (over the wire — NO file parsing)
- **Transcript preview uses `thread/read {threadId, includeTurns:true}`** (or `thread/turns/list`), **NOT `thread/resume`** (review #3): `resume` loads/subscribes the thread for later turns (creates loaded-thread state + notifications + a stale subscription) — wrong for a read-only History preview. Reserve `thread/resume {threadId, …}` for when the user actually **continues** a picked session (then `turn/start`). Walk `thread.turns[].items[]` → rows (userMessage/agentMessage) + completed tool chips.
- **`thread/list {cwd:<workspace>, sourceKinds:["appServer","cli","vscode"], limit, sortDirection:"desc"}`** → threads `{id, preview, updatedAt}` → `AgentSessionSummary`. **`sourceKinds` MUST be explicit** (review #2): omitted defaults to interactive sources only (`cli`/`vscode`) and would **drop Rubien's own `appServer` threads** from History. Include `appServer` always; add `cli`/`vscode` to also show same-folder CLI sessions, or `["appServer"]` for Rubien-only. (`cwd` filter scopes to the working folder — D5; confirm the exact default empirically in 3b-4.)
- **`thread/search {searchTerm, sourceKinds:[…], …}`** → content search → `AgentSessionSummary` with a snippet.
- **Store scoping:** threads land in the shared `~/.codex` store (no managed home — §4), so History scopes by the **`cwd` filter** (the working folder — D5), exactly as Claude scopes its shared `~/.claude/projects` by cwd. Codex sessions in *other* folders are excluded; a session the user ran via the `codex` CLI in the *same* working folder could appear — acceptable, identical to Claude's per-folder History semantics.

### 2.4 Approvals — server-initiated requests (the mutation gate, D6)
Verified: under `sandbox:"read-only"` + `approvalPolicy:"on-request"`, a write attempt produced:
```
← item/started {item.type:"commandExecution", status:"inProgress"}
← thread/status/changed {status:{type:"active", activeFlags:["waitingOnApproval"]}}
⇐ item/commandExecution/requestApproval  (SERVER REQUEST, id=0)
   {threadId, turnId, itemId, reason:"Allow creating spike.txt…", command:"/bin/zsh -lc …",
    cwd, commandActions:[…], availableDecisions:["accept", {acceptWithExecpolicyAmendment…}, "cancel"]}
→ {id:0, result:{decision:"accept"}}          (echo the server id)
← serverRequest/resolved {requestId:0}
← item/completed {item.type:"commandExecution", status:"completed"}
```
- Server approval methods → `.approvalRequested(id:<serverReqId>, toolName, summary:<reason>)`:
  `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/requestUserInput`.
- Response echoes the server id: `{decision: <D>}` for command/file. **The JSON-RPC id must be echoed VERBATIM in its original type** (review #1): the verified frame used a **numeric** `id:0`, but Rubien's `AgentEvent.approvalRequested(id:)` is a `String`. The connection must store the raw id (`RawJSONRPCID.number | .string`) keyed by the UI-facing string, and write the *raw* id in the response — serializing `"0"` for a numeric `0` would fail to correlate. Fake-server test asserts the response id type matches the request. Decision enums (verified): `CommandExecutionApprovalDecision`/`FileChangeApprovalDecision` = `"accept" | "acceptForSession" | "decline" | "cancel"`. **Map:** `allowOnce → accept`, `allowForConversation → acceptForSession`, `deny → decline` (fall back to `cancel` when `availableDecisions` omits `decline`).
- `serverRequest/resolved {requestId}` confirms the ack → clear the pending card. A turn's stream can raise several approvals (parallel tool calls) — the FIFO approval-queue lesson from Phase 2c applies (a single card slot wedges parallel approvals).
- `permissions`/`elicitation` requests have richer response shapes (§ verified types); v1 answers them conservatively (decline unknown/unsupported) and surfaces a notice — full support is a follow-up.

### 2.5 Usage, errors, cancel
- **Usage:** `turn/completed.turn.items` is `[]` (`itemsView:"notLoaded"`) — usage is **NOT** inline. `ThreadTokenUsage` carries both `total` (thread-**cumulative**) and `last` (this request). `AgentUsage` is per-turn accounting (mirrors Claude's `result` usage), so use **`tokenUsage.last`**, not `.total` — attaching the cumulative total would inflate later turns (review #7). Map `last` → `AgentUsage{inputTokens, outputTokens, cacheReadTokens: cachedInputTokens}`, captured from the latest `thread/tokenUsage/updated` before `turn/completed`. (Test: two turns; per-turn stays bounded.)
- **Failure:** `turn/completed.turn.status:"failed"` + `turn.error.message`, or an `error` notification → `.providerNotice`. `TurnStatus` = `completed | interrupted | failed | inProgress`.
- **Cancel/stop:** `turn/interrupt {threadId, turnId}` → the turn ends `interrupted`. Teardown additionally kills the process group.

## 3. AgentEvent mapping

| app-server method | AgentEvent |
|---|---|
| `thread/started` | `.sessionStarted(thread.id)` |
| `item/agentMessage/delta` | `.assistantDelta(delta)` |
| `item/completed` (agentMessage) | `.assistantMessageCompleted(item.text)` |
| `item/started` (commandExecution/fileChange/mcpToolCall/webSearch) | `.toolUseStarted(name, detail)` |
| `item/completed` (tool; status completed) | `.toolUseCompleted(name)` |
| `item/completed` (tool; status declined/failed) | `.toolDenied(name, reason)` |
| `item/*/requestApproval`, `mcpServer/elicitation/request` (server req) | `.approvalRequested(id, toolName, summary)` |
| `thread/tokenUsage/updated` | (accumulate `.last`; not emitted) |
| `turn/completed` | `.turnCompleted(usage)` |
| `error`, non-zero server exit | `.providerNotice(message)` |
| unknown **notification** | ignored (tolerant) |
| unknown **server request** (has an `id`) | **must reply** — a conservative decline/cancel (when the shape is known) or a JSON-RPC error, plus a `.providerNotice`; never silently dropped (review #6 — an unanswered request wedges the server) |

**Intentionally not surfaced in v1** (review #8): `turn/plan/updated`, `turn/diff/updated`, `item/plan/delta`, reasoning-summary/text deltas, `command/exec/outputDelta` — no `AgentEvent` for them and the current chip model doesn't need them. Command/tool chip detail comes from the final `item/completed` fields (`aggregatedOutput` / `exitCode` / `error`) rather than streamed output deltas.

## 4. Config posture: the Claude-parallel — per-invocation levers, NO managed home (user decision 2026-07-06)

Codex is driven **the same way as Claude**: keep the user's real `~/.codex` (auth + config resolve normally — exactly as Claude keeps `~/.claude`), and neutralize the ambient config through **per-invocation levers**, not a relocated/managed config home. **No `CODEX_HOME` override, no `auth.json` symlink, no Rubien-written `config.toml`.** (This supersedes the earlier managed-`CODEX_HOME` sketch — over-engineered; the Claude approach is flags/params, and even forbids relocating `CLAUDE_CONFIG_DIR` because it breaks auth.)

- **Permission / sandbox / effort — per-request params (verified to override the user's `~/.codex` defaults):** `approvalPolicy:"on-request"` + `sandbox:"read-only"` (or `"workspace-write"`) on `thread/start`; `effort:<pinned>` on `turn/start`. The spike confirmed these win over the user's config (got `on-request` / `effort=medium` despite the user's defaults — **pins away the `xhigh` stall, Risk #8**). This is ordinary per-conversation configuration, not "isolation."
- **Rubien MCP channel — a per-spawn `-c` KEY override (verified to de-dup):**
  `codex app-server -c mcp_servers.rubien.command=<bundled rubien-cli> -c 'mcp_servers.rubien.args=["mcp","--read-only"]' -c mcp_servers.rubien.env.RUBIEN_LIBRARY_ROOT=<resolved root>`.
  Because it overrides the `rubien` **key**, it replaces any user-configured `rubien` entry — **verified: exactly one `rubien` server loads (ours), no double-load / tool-name collision.**
- **Drop codex's built-in connectors — `--disable apps` (verified):** removes the built-in `codex_apps` MCP server (codex's own app connectors — the surface that could otherwise reach cloud data like mail/chat/docs). Verified: with `--disable apps`, `codex_apps` no longer loads. This closes the one *net-new* confidentiality surface vs Claude (see below).
- **Env:** minimal allowlist (`HOME,USER,LANG,LC_ALL,TMPDIR`, `TERM=dumb`, `NO_COLOR=1`) + `PATH` (binary dir + `/usr/bin:/bin`); keep `HOME` so `~/.codex` resolves; never inherit the app env (§4.1 master). **No `CODEX_HOME`.**

**Accepted consequence — scoped precisely (user-directed 2026-07-06):** `codex app-server` config **merges** and has **no `--strict-mcp-config` analogue** (verified: no `--ignore-user-config`; whole-table `-c mcp_servers={…}` still merged — `node_repl` persisted). So the user's **own configured** codex MCP servers still load alongside the injected rubien. This is *not* the blanket confidentiality hole it first looks like — the exposure decomposes:
- **Silent LOCAL reads are already an accepted residual risk for BOTH providers.** Verified: under `read-only` + `on-request`, codex runs read shell commands **with no prompt** (a `/etc/hostname` read executed silently; it only failed because macOS lacks that path) — the same posture as Claude's unscoped `Read` tool (master doc Risk #1, accepted for public docs). So a *local-tooling* server like `node_repl` ≈ that already-accepted risk, **not** a new hole.
- **The one NET-NEW exposure vs Claude is cloud-CONNECTOR reads** (mail/chat/docs) that Claude's strict config can't reach. Codex's built-in connector surface (`codex_apps`) is **dropped by `--disable apps`** (verified). What remains is any *user-configured cloud-connector* MCP server in `~/.codex` — which this user does not have (only `node_repl`, local).
- **Ask vs Auto (the modes):** in the default **Ask mode**, side-effecting tool calls prompt (Rubien cards any non-rubien tool it is asked to approve — `isSilentReadTool` allowlists only `mcp__rubien__*` + builtins); a *read-only-annotated* tool from another server may run silently (codex doesn't elicit approval for read-only MCP). In **Auto mode** (`autoApprove`, opt-in) everything runs silently by the user's explicit choice.
- **Net:** for a `~/.codex` of local tooling, **no managed home + `--disable apps` ≈ Claude's accepted posture**. The residual (a read-only *cloud-connector* tool running silently in Ask mode) only materializes if the user adds a cloud-connector MCP server to `~/.codex`; at that point a **"Strict Codex"** mode (a minimal managed home so only rubien loads) is the fix, surfaced as a Settings note (§ 3b-3). Risk #16 downgraded (rubien de-dup via the `-c` key override); Risk #8 (effort stall) handled per-request.

**Relationship to the "Use my other MCP servers" opt-in (master §5.5, deferred increment — framing settled with the user 2026-07-06):** the toggle swings exactly one thing — the **tool environment** — between two postures:
- **OFF (default) = isolate.** Only rubien. Claude: `--setting-sources '' --strict-mcp-config`. Codex: `--disable apps` + the `-c` rubien injection (with the known no-strict-analogue residual above; a paired **Strict Codex** managed home is what would make codex's OFF as tight as Claude's).
- **ON = wrap the user's own agent.** The user's full codex/claude toolset loads — their MCP servers, connectors (Notion, Google Docs, …), settings — and Rubien adds only its **context**: it is *their* agent, now aware of the paper. Positive use case (the reason the toggle exists): *"summarize this paper and save it to my Notion"* — the connector **write** rides the approval card in Ask mode (a confirmation, not a blocker). Codex: omit `--disable apps` (their servers already load). Claude: load the user's MCP config alongside rubien with the §5.5 de-dup. ON = the user's normal agent + context; no extra per-call gating by default ("confirm every connector call" is at most an optional extra-strict sub-setting, NOT the default — it would make ON behave unlike their normal agent).
- **Constant in BOTH postures:** (a) the **Rubien context** — the injected rubien MCP server + the one-line reference seed; (b) the **transport + approval plumbing** — stream-json / JSON-RPC and the approval channel pinned to prompt (`--permission-prompt-tool stdio` / `approvalPolicy:"on-request"`). (b) is not lockdown; it is what makes the Ask/Auto cards function at all — ON must never inherit e.g. a user `approval_policy="never"`, which would silence Rubien's approval UI.
- **3b-2 wiring:** `CodexInvocation` takes `loadUserTools: Bool` (default `false`) gating `--disable apps`, so today's locked-down default is expressed through the same lever the opt-in will flip — no hardcode to unwind later.

## 5. Architecture

```
CodexProvider : AgentProvider  (final class, Sendable)
 └── CodexAppServerConnection (actor)     — the long-lived server + all mutable state
       ├── SpawnedAgentProcess            — posix_spawn own-process-group child (SHARED with Claude)
       ├── JSON-RPC framing               — outbound id→continuation map; inbound demux (resp/serverReq/notif)
       ├── CodexAppServerProtocol (pure)  — encode requests/responses; decode → typed frame; map → AgentEvent
       ├── turn router                    — routes the active turn's notifications into its AsyncThrowingStream
       └── lifecycle                      — lazy start+handshake; keep-alive across turns; turn/interrupt on
                                            cancel; SIGTERM→SIGKILL process-group kill on teardown/EOF
 └── CodexInvocation (pure)               — argv (`app-server` + `-c mcp_servers.rubien.*`) + minimal env;
                                            unit-tested; mirrors ClaudeCLIInvocation. NO managed CODEX_HOME.
```
- **One connection per `CodexProvider` instance = one conversation/window** (parallels Claude's "one conversation per instance"). The server starts lazily on the first `send`, is reused for every follow-up turn (just `turn/start` on the live thread — the payoff of the long-lived model), and is torn down on `teardown`/window close. Multiple windows ⇒ multiple servers (v1; a shared multi-thread server is a Phase-4 optimization).
- **Stream-termination semantics DIVERGE from Claude — do not copy the `AgentProvider` `onTermination` comment literally** (review #5). Claude kills the process group when the per-turn stream is dropped (its process *is* the turn). Codex must NOT: the server is reused across turns. Rule: a per-turn stream terminating **while its turn is active** → `turn/interrupt {threadId, turnId}` (turn ends, **server lives**); terminating **after `turn/completed`** → just detach/finish that stream. **Only `teardown`/window-close (or the server's own EOF/crash)** kills the process group. Update the Codex `send` `onTermination` accordingly.
- **`SpawnedAgentProcess` (shared):** extract `PosixSpawnedProcess` + the minimal-allowlisted-env builder out of `ClaudeCodeProvider.swift` into a shared file both providers use (Altitude: generalize, don't copy). Claude keeps its per-turn spawn; Codex spawns once and keeps the handles for the connection's lifetime.
- **`AgentProvider` unchanged:** `send(turn:)` returns a per-turn stream (the connection tees the active turn's events into it); `respondToApproval(id:_:)` writes a `{decision}` response echoing the server id; `cancel()` = `turn/interrupt`; `recentSessions/searchSessions/sessionTranscript` = `thread/list`/`thread/search`/`thread/resume`.
- **`ChatSessionController` unchanged** (already provider-agnostic via `any AgentProvider` + `providerKind`). The picker (3b-3) swaps which provider the composition root builds.

## 6. Sub-phasing (each: green build + codex-rescue + /simplify + commit)

- **3b-1 — Protocol codec + fixtures (pure, AppKit-free, no spawning).** `CodexAppServerProtocol.swift` (JSON-RPC message model; encode client requests + approval responses; decode inbound → `.response`/`.serverRequest`/`.notification`; map notifications + server-requests → `AgentEvent` + a pending-approval record; usage accumulator; tolerant of unknown methods). Curate captured frames → `Tests/RubienTests/Fixtures/Codex/*.jsonl`. `CodexAppServerProtocolTests` (event sequences, approval request→`{decision}`, unknown-line tolerance, usage accumulation, thread-id capture) — mirrors `ClaudeStreamParserTests`.
- **3b-2 — Invocation + connection + provider + fake server.** Extract `SpawnedAgentProcess` (shared). `CodexInvocation.swift` (pure argv + minimal-env builder: `app-server` + `-c mcp_servers.rubien.*` injection + `--disable apps` gated on `loadUserTools: Bool = false` — the opt-in lever, §4; NO managed `CODEX_HOME` — §4). `CodexAppServerConnection` (actor: spawn+handshake, request/response correlation, server-request routing, per-turn notification routing, lifecycle). `CodexProvider: AgentProvider`. A committed **fake app-server** test executable (emits controlled JSON-RPC incl. an approval request, floods, delays, exits non-zero) → drives handshake, turn routing, approval round-trip, `turn/interrupt`, process-group kill (no orphan), unknown-method tolerance — mirrors the fake-claude harness.
- **3b-3 — Provider picker + wiring + Settings.** `ReaderChatSession.make` selects the provider from a new `RubienPreferences.assistantProvider`; composer-header **provider picker** (Claude ▾ / Codex ▾ — switch = fresh conversation on the other runtime, rebuilding the controller). `AssistantModelOptions` codex model list. Settings ▸ Assistant: codex model override, reasoning effort (default **medium**), default sandbox (`read-only`) + `workspace-write` opt-in, web default, codex auth status + Recheck, disclosure of codex's session store (real `~/.codex`). **Note the MCP posture (§4):** Codex loads your own configured `~/.codex` MCP servers (built-in connectors dropped via `--disable apps`); a Settings disclosure explains this + names any loaded non-rubien servers, with a **"Strict Codex" toggle (default off, follow-up)** that would isolate to rubien-only for users with cloud-connector servers.
- **3b-4 — Codex History over the wire.** `recentSessions`→`thread/list` (explicit `sourceKinds` incl. `appServer`), `searchSessions`→`thread/search`, `sessionTranscript`→**`thread/read {includeTurns}`** (read-only preview — NOT `thread/resume`; walk turns→items), actual continuation resumes via `thread/resume`+`turn/start`, into the existing provider-agnostic History popover (incl. the search field).

## 7. Testing

- **Codec (bulk):** committed fixture JSONL → event sequences; unknown-line + partial tolerance; the approval request→response round-trip; usage accumulation; stable thread-id capture. `RubienTests`, AppKit-free (`swift test --filter RubienTests`).
- **Fake app-server harness:** handshake, multi-turn on one thread, approval round-trip (request → `{decision}` on the wire → continue), `turn/interrupt`, non-zero exit → notice, process-group kill (no orphan grandchild), unknown-method tolerance.
- **Manual E2E:** read-only Q&A with a formula; write attempt → approval card (accept runs it / deny → declined chip); resume from Codex History (context continues); History search; provider switch Claude↔Codex (fresh conversation); Web toggle; the `xhigh`-user's effort pinned (no stall).

## 8. Risks & open questions

| # | Risk | Mitigation |
|---|---|---|
| C1 | v2 protocol is `[experimental]` (needs `experimentalApi:true`); may drift across codex updates | Tolerant parser (ignore unknown methods/fields — already the house rule); pinned fixtures; version logged per turn; `generate-json-schema` re-checkable |
| C2 | Server-request id space is separate from client requests (starts at 0) | Correlate approvals by **echoing the server's request id**, never a shared counter (verified) |
| C3 | No `--strict-mcp-config` analogue → the user's own configured codex MCP servers load alongside injected rubien; a read-only *cloud-connector* tool could be invoked silently by a hostile doc | **Scoped & accepted** (user 2026-07-06, §4): silent LOCAL reads are already-accepted for both providers (Risk #1); built-in connectors dropped via `--disable apps`; net-new risk = user-configured *cloud* connectors only (this user has none — `node_repl` is local). Mutations still gate via the approval card. Fix if needed = the **"Strict Codex"** toggle (managed home, rubien-only) surfaced in Settings (§ 3b-3) |
| C4 | Long-lived process leak/orphan (server outlives the window) | Process-group kill on teardown/EOF; idle-teardown; fake-harness no-orphan test; one server per conversation, torn down deterministically |
| C5 | Web toggle → codex web-search config key not yet pinned | Confirm the exact `config` key (`WebSearchToolConfig`/tools) empirically in 3b-3; default on |
| C6 | `permissions`/`mcpServer/elicitation` approval requests have richer shapes than command/file | v1 maps command/file/generic to the card; answers unknown elicitations conservatively (decline) + notice; full support is a follow-up |
| C7 | Auth: uses the real `~/.codex` (no relocation) | Same as Claude keeping `~/.claude`; `isAvailable()` surfaces "not logged in"; `codex login` escape hatch (§4.5 master) |

## 9. What this does NOT change

- No `AgentProvider`/`AgentEvent`/`ApprovalDecision` protocol changes. No `ChatSessionController` logic changes (only the composition root picks the provider). No renderer changes. No library writes (still Phase 4 — Codex mutations in v1 are the agent operating on the *workspace folder*, gated by the approval card; the MCP content channel stays **read-only**). Rubien still persists nothing (D5) — codex owns its session store in the real `~/.codex` (no managed home; History scopes by `cwd` — §2.3).
