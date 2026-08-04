# Reference Export Implementation Plan

**Status:** Complete — merged into `main` as `ada5b75` on 2026-08-04

**Branch:** `codex/reference-export`

**Worktree:** `.claude/worktrees/reference-export`

## Delivery slices

1. Land the reviewed Core contract: typed requests/errors/artifacts, one-read
   snapshot resolution, public JSON DTO ownership, pure JSON/BibTeX/RIS
   encoders, and focused Core tests.
2. Replace the CLI-local exporter with the Core service, add ID/view selection
   and race-safe file output, then extend both MCP adapters and their docs/tests.
3. Add macOS current-view, selected-row, and entire-library export entry
   points. Capture grouped display order before the save panel and write the
   artifact off the main actor.
4. Run targeted and full builds/tests, perform independent correctness and
   simplify reviews, address accepted findings, and relaunch the worktree app
   for verification.

## Review amendments incorporated

- Chunk every unbounded ID query and preserve first-occurrence caller order.
- Keep the existing `ReferenceDTO` byte/omission contract exactly.
- Use typed Core failures for empty IDs, unresolved IDs, and missing views.
- Flatten group buckets and stable-deduplicate IDs for app display-order export.
- Publish CLI files atomically without a check-then-overwrite race.
- Keep current locale/calendar saved-view behavior shared with `list --view`;
  cross-platform collation changes are outside this feature.
