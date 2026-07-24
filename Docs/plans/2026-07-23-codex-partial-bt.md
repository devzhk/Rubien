# Codex partial B-T implementation plan

**Date:** 2026-07-23
**Status:** Implemented and verified

## Contract

Adopt only the new-thread posture dimensions proven on Codex 0.142.5 and
0.145:

- keep **web search** and **installed plugins** in the app-server process
  profile; while plugins are enabled, keep the app-server startup cwd in that
  profile too;
- move **cwd**, **Apps**, and the canonical **Rubien MCP full/read-only
  configuration** to `thread/start` and cold `thread/resume`;
- keep unattended scheduled jobs on Apps-off, plugins-off, read-only Rubien
  MCP, with every ambient MCP server disabled by name;
- allow plugin-disabled turns with the same process profile to share the
  server even when their cwd or Rubien MCP posture differs;
- do not pretend that an already-loaded, subscribed thread accepted a changed
  posture; scheduled work fails closed rather than reusing an interactive
  profile;
- after the last owner unsubscribes, retain the thread as cached until
  `thread/closed` or server replacement proves a cold state. A changed or
  uncertain cached profile forces an idle-server recycle before resume; if
  another turn is active, fail visibly and let the user retry after it drains.

These rules preserve the spike's sticky-cwd finding. A genuinely cold resume
receives the requested thread config; a currently subscribed thread keeps its
recorded effective thread profile, and successful unsubscribe alone is not
treated as proof of cold rehydration.

## Implementation

1. Reduce `CodexRuntimeProfile` to process-scoped web/plugin fields (plus cwd
   only for plugin-enabled discovery) and add a generation-local thread
   profile for cwd/Apps/Rubien MCP posture.
2. Extend the protocol encoders so `thread/start` and cold `thread/resume`
   carry `config`, with resume also carrying cwd.
3. Replace launch-time Apps/Rubien MCP arguments with a pure per-thread config
   builder. Resolve scheduled ambient MCP names with `config/read {cwd}` on
   the already-owned app-server and disable them in scheduled thread config;
   never start a second Codex root beside the live server.
4. Preserve thread lease ownership and record the effective profile that was
   actually applied. Reusing a subscribed thread must not pretend that a new
   profile took effect; reject a scheduled resume when its requested
   read-only profile differs from the loaded profile. Retain cached/unknown
   zero-owner state and force a cold server replacement before applying a
   different profile.
5. Update the fake app-server and tests:
   - exact start/resume config payloads;
   - full vs read-only Rubien server shape;
   - Apps pinning without a per-thread plugins override;
   - different cwd and scheduled/default-interactive concurrency on one PID;
   - web/plugin differences and plugin-enabled cwd changes remain
     process-profile serialization boundaries;
   - live `config/read` inventory and fail-closed scheduled resume behavior.
   - sticky cached cwd, unsubscribe timeout, and late setup-response cleanup.
6. Update the architecture decision and spike result documents to mark partial
   B-T complete and identify residual web/plugin serialization as the next
   measurement.

## Verification

- Live `config/read` empty/populated catalog controls passed on Codex 0.142.5
  and 0.145.0.
- Independent review and the repository's reuse/quality/efficiency simplify
  passes completed; findings were addressed before final verification.
- Final combined runtime verification totals are recorded in the architecture
  decision document.
