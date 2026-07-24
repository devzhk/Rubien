# Codex residual serialization measurement

**Date:** 2026-07-23
**Status:** Implemented; collecting representative local evidence

## Decision being measured

Retain the implemented single-broker partial B-T topology unless process-level
web/plugin differences cause material real-world waiting or respawn churn.
This phase instruments that remaining decision gate; it does not change
admission, respawn, or resume behavior.

## Measurement contract

Persist one local aggregate snapshot with:

- observation-period start and total Codex turn requests;
- capacity-queue incidents and accumulated wait time;
- process-profile-queue incidents and accumulated wait time;
- process-profile queue breakdown for web, plugin toggle, and
  plugin-enabled workspace differences;
- controlled process-profile respawns and the same three-dimensional
  breakdown.

A profile incident may increment more than one dimension when more than one
process-level setting differs. Capacity waits remain a control group and must
not be attributed to the residual architecture boundary. One queued turn may
contribute to both categories: its timer changes from capacity to profile when
a full batch opens a slot but the incompatible active batch must still drain.

## Privacy and lifecycle

- Store only aggregate counters and millisecond durations in local
  `UserDefaults`.
- Never store prompts, model output, thread/turn/run identifiers, workspace
  paths, profile values, or timestamps for individual turns.
- Do not sync the snapshot through the Rubien library or CloudKit.
- Allow the user to copy a JSON report and reset the observation period from
  Settings ▸ Assistant.
- Resetting diagnostics must not affect conversations, preferences, or the
  Codex runtime.

## Implementation

1. Make the pure scheduler classify each current queue phase as either capacity
   or a process-profile boundary, including the changed profile dimensions.
2. Add a thread-safe, injectable `CodexRuntimeMetricsStore` with versioned
   Codable persistence, saturated counters, JSON export, and reset.
3. Record each accepted turn request, completed/cancelled queue phase, and
   controlled profile respawn. Queue timing uses monotonic uptime; Reset
   invalidates all later metrics from turns accepted in an older observation
   period. Capacity timing ends when a scheduler reservation is available;
   process-profile timing remains open through replacement, initialization,
   and the app-server readiness handshake so the report captures the full
   architecture-induced wait.
4. Add a compact Settings section with observation start, turn count,
   profile/capacity wait summaries, respawn summary, Copy, Refresh, and Reset.
5. Cover classification, persistence/export/reset, provider integration, and
   Settings-facing formatting with deterministic tests.

## Decision use

The instrumentation is now live for production shared Codex turns. Review or
copy the aggregate report from Settings ▸ Assistant after a representative mix
of normal conversations, web-toggle changes, and plugin opt-in changes.

Compare profile waits and respawns against total turns and the capacity-wait
control. No automatic threshold or topology migration is encoded in the app.
A material profile-only impact reopens the documented B+ gate; otherwise
retained B plus partial B-T remains the long-term choice.

## Verification

- Independent review plus reuse/quality/efficiency simplify passes completed;
  the follow-up review confirmed accepted-send tickets close the Reset race
  across delayed queue and controlled-respawn metrics. A subsequent review
  added a delayed-initialization regression proving profile wait does not stop
  at scheduler reservation.
- Final combined runtime verification totals are recorded in the architecture
  decision document.
