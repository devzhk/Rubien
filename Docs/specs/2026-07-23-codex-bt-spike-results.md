# Codex B-T Behavioral Spike Results

**Date:** 2026-07-23
**Codex versions:** `codex-cli 0.142.5` and `0.145.0`
**Harness:** `scripts/codex-bt-spike.py`

## Conclusion

**Full B-T does not pass on Codex 0.145.0.** A useful partial B-T is viable,
but web access must remain a process-level posture for now.

The spike proved that one app-server can host simultaneous threads with
different Rubien MCP write posture, Apps posture, and initial cwd. It did not
prove plugin runtime isolation, and it disproved per-thread web isolation.

The spike also found a current production compatibility bug: Rubien's existing
`-c tools.web_search=false` launch override no longer disables web search on
Codex 0.145.0. The typed `-c web_search=disabled` override does, and a follow-up
control confirmed that it also works on Rubien's 0.142.5 compatibility baseline.

**Implementation status:** `CodexInvocation` now pins the user-facing toggle
authoritatively: On uses `web_search=cached`; Off uses
`web_search=disabled`.
Reference-counted generation-local thread leases, final-owner
`thread/unsubscribe`, resume barriers, and `thread/closed` reconciliation are
also implemented with shutdown/server-exit race coverage. Partial B-T is now
implemented: new and cold-resumed threads carry cwd, Apps, and the canonical
Rubien MCP full/read-only configuration; the shared process profile contains
web and installed-plugin posture, plus the app-server startup cwd only while
plugins are enabled. Scheduled ambient-MCP discovery now uses
`config/read {cwd}` on the owned app-server (verified on 0.142.5 and 0.145),
so it never starts a second Codex root beside the live runtime.

## Reproduction

From the repository root, with the debug CLI already built:

```bash
python3 scripts/codex-bt-spike.py --exercise-web
```

The compatibility-floor check can be reproduced without model turns:

```bash
python3 scripts/codex-bt-spike.py --config-read-controls-only
```

The harness:

- runs short sequential `config/read` preflights, then one main real
  `codex app-server` for the posture matrix;
- points both Rubien MCP postures at a temporary library;
- directly calls the thread-aware MCP inventory and tool-call APIs;
- exercises `config/read {cwd}` against isolated empty and populated MCP
  catalogs before using it to inventory the live ambient catalog;
- creates a sentinel only in that temporary library;
- runs low-effort, concurrent web-on/web-off control turns;
- archives the durable Codex test threads at the end;
- exits nonzero when a required B-T invariant fails.

## Results

| Check | Result | Evidence |
|---|---|---|
| Opposite initial cwd | Pass | Each new thread reported its requested workspace. |
| `config/read` MCP compatibility | Pass | Both supported Codex versions returned the expected empty and populated MCP catalog shapes. |
| Opposite Rubien MCP catalogs | Pass | Full exposed `rubien_create_reference`; read-only exposed reads but no create tool. |
| Per-thread MCP processes | Pass | One app-server owned distinct `rubien-cli mcp` and `rubien-cli mcp --read-only` children. |
| Read-only write enforcement | Pass | A direct create call was rejected and the isolated library remained unchanged. |
| Write-capable control | Pass | The full thread created the sentinel in the isolated library. |
| Apps feature and runtime posture | Pass | Feature state differed per thread; only the enabled thread reported enabled/callable Apps. |
| Plugins feature posture | Pass at config layer | `experimentalFeature/list` reported plugins on/off per thread. |
| Plugin runtime posture | Inconclusive | The safe local plugin MCP canary exposed zero tools even on the enabled control. |
| Per-thread web posture | **Fail** | Both web-on and web-off threads completed a search with 12 results. |
| Loaded subscribed resume | Pass negative control | MCP, Apps/plugins, and cwd retained the old posture; new overrides were ignored. |
| Unsubscribe then immediate resume | Mixed / full-gate fail | MCP and Apps/plugins switched immediately, but cwd stayed on the old value. |
| Cold resume after server restart | Pass | The same thread id resumed with the requested MCP and feature posture. |
| Current Rubien launch web-off key | **Fail** | `tools.web_search=false` still completed a search with 12 results. |
| Typed launch web-off key | Pass | `web_search=disabled` suppressed web-search events. |
| Same-process idle unload | Not run | Codex uses a fixed 30-minute last-subscriber idle timeout. |

Launch-control compatibility:

| Codex | `tools.web_search=false` | `web_search=disabled` |
|---|---|---|
| 0.142.5 | Pass | Pass |
| 0.145.0 | **Fail** | Pass |

New-thread partial B-T compatibility:

| Codex | `config/read` | cwd | Rubien MCP full/read-only | Apps runtime |
|---|---|---|---|---|
| 0.142.5 | Pass | Pass | Pass | Pass via thread-aware `app/list` |
| 0.145.0 | Pass | Pass | Pass | Pass via thread-aware `app/installed` |

The useful subset therefore preserves Rubien's existing 0.142.5 compatibility
baseline; no version-floor increase is required.

## Decision impact

The architecture sequence should now be:

1. **Keep the completed authoritative web-toggle mapping.** Rubien now pins
   On to `web_search=cached` and Off to `web_search=disabled`; retain the
   behavioral probe as the real enforcement check.
2. **Reference-counted thread ownership and `thread/unsubscribe` — completed.**
   This bounds the former grow-only ownership state and supplies the transition
   barrier required by later thread-local work.
3. **Wedge detection + auto-respawn — completed.** A local dispatcher probe
   now gates generation-wide recovery, shared affected turns fail visibly
   without replay, and the next explicit send spawns and resumes cleanly.
4. **Process-scoped plugin policy — decided and implemented.** The explicit
   user-tools opt-in now pins both Codex Apps and installed plugins: Off
   disables both, On enables both, and user/project config cannot contradict
   either state. Scheduled jobs force the opt-in Off, disabling both; the
   read-only invocation path additionally enforces plugins-off defensively.
   **Partial B-T is implemented:** new-thread and cold-resume config now carry
   cwd, Rubien MCP read-only/full posture, and Apps posture. Scheduled
   default-web work can overlap default interactive work on one app-server.
   A scheduled resume fails closed while the requested thread is still loaded
   with an interactive profile.
5. **Keep web process-scoped.** Continue using the existing drain/respawn
   profile boundary for web changes until a future Codex version passes the
   behavioral matrix.
6. **Keep plugins process-scoped until a real enabled control exists.** Config
   flag acceptance alone is insufficient. Rubien's policy is now explicit:
   disable plugins in the default no-user-tools and scheduled postures, and
   enable them only after the interactive user-tools opt-in. Switching that
   posture continues to use controlled drain/respawn. While plugins are
   enabled, the app-server startup cwd also remains part of the process
   fingerprint; different workspaces serialize and respawn until a runtime
   canary proves project/plugin discovery is thread-local.
7. **Measure the remaining boundary — implemented.** Production shared Codex
   turns now feed a local aggregate report separating process-profile waits
   from ordinary capacity waits, timing both, and counting controlled
   profile respawns with web/plugin/workspace breakdowns. The report is
   available to copy or reset in Settings ▸ Assistant and stores no prompts,
   paths, IDs, or per-turn timestamps. Collect a representative window before
   reopening topology work.
8. **Do not move to C.** Its stale in-memory thread hazard remains, and this
   spike found no evidence that C is needed to obtain the useful subset of
   thread isolation.

This is a **partial B-T / retained B** outcome, not the v5 document's
“B-T passes: adopt and stop” branch.

The next step is to use Rubien normally across web/plugin postures, then
inspect the aggregate report. Only material profile-only delay or respawn
churn should reopen B+; otherwise this is the stopping point. Live thread
posture changes remain outside the proven surface: immediate
unsubscribe/resume did not switch cwd on 0.145.
