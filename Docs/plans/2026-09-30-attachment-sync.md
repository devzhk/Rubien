# Attachment iCloud sync

Implement the remaining sync phases of the [reviewed design](../specs/2026-09-28-reference-attachments-design.md).
Use isolated test libraries. Keep live attachment dispatch disabled until recovery,
terminal quarantine handling, and the separate upgrade inventory pass their gates.

## 1. Record handling and receive/removal

- Add strict UUID-addressed mappings for metadata, immutable assets, and annotations.
  Preserve unknown kinds/anchor versions and explicit compact removal markers.
- Validate immutable identity before the shared equal-change-tag guard. Duplicate
  delivery must preserve pending local edits and their cached server version.
- Merge removal markers monotonically; preserve the existing push-in-flight handshake.
- Stage and hash incoming assets outside database writes. Journal ownership before
  publication; retain unresolved files and retry interrupted publication safely.
- Test mappings/schema coverage, removal races, duplicate delivery, stale save
  acknowledgements, and file ownership with no live CloudKit requests.

## 2. Dispatch and recovery

- Register all three types with durable intent and dependency replay together.
- Retain unresolved attachment quarantine at actual terminal replay boundaries.
- Persist account/environment/zone-scoped parent-deletion evidence. Use it to
  reconcile late arrivals without treating missing parents as deleted.
- Add marker acknowledgement, child cleanup, and missing-record recovery. Preserve
  previously acknowledged annotations instead of blindly recreating them.

## 3. Upgrade inventory and transfers

- Traverse projected scalar fields with a separate durable cursor and type allowlist.
- Atomically commit each page, download intent, and cursor. Resume targeted asset
  downloads independently of scalar catch-up and normal sync.
- Verify primary rows, queues, system fields, assets, and live cursor stay unchanged.
- Expose attachment transfer/error/retry status through the UI and existing APIs.
- Test restart, token expiry, account scoping, offline edits, and duplicate catch-up.

## 4. Verification

Build the app and CLI; run focused Core/Sync/CLI tests and Linux parity where relevant.
Two-Mac verification needs signed Development builds with separate test libraries.
Production schema deployment and release remain separate work under the release runbook.

## Progress

- Phase 1 implemented: all three strict codecs and schema declarations; a shared
  transactional receiver; removal precedence; equal-tag protection; upload/acknowledgement
  and missing-record recovery seams; staged, verified files with journal-based retry.
- The real terminal replay path now explicitly retains attachment quarantine. A test
  covers all three unresolved types plus file ownership and successful completion.
- Phases 2 and 3 implemented behind `RUBIEN_ENABLE_ATTACHMENT_SYNC=1`: live dispatch
  and pending intent; v17 scoped observations/deletion evidence; missing-child
  recovery; acknowledgement-driven cloud deletion and local cleanup; reader/upload
  leases; a separate startup inventory and bounded targeted downloads.
- Inventory uses its own page cursor. Each page applies only attachment records
  and commits its download jobs atomically. Primary deletion events supply only
  attachment evidence. The initial inventory attempt runs before engine construction. Attachment-only
  failures allow primary sync to continue; see the recovery update below.
- Download failures keep their durable retry jobs. A normal engine asset delivery
  satisfies the same job. Retry is exposed through the details panel, CLI, and both
  MCP servers. Previously observed missing annotations remain preserved after retry.
- Scoped quarantine ownership prevents another account's unresolved records from
  replaying. Reader leases also cover chat/CLI extraction; import recovery defers
  cleanup instead of blocking while readers are open.
- Verification passed: checkout app and macOS/Linux CLI builds; 147 Sync, 48 Core,
  51 CLI/MCP, and 10 reader tests on macOS; 32 focused Linux tests; and all 101 npm
  MCP tests. Dependency pins are unchanged and `git diff --check` is clean.
- The CLI regression run also fixed startup pre-opening the library for the sync
  diagnostic and writer-upgrade commands. Those commands must inspect the existing
  schema before migration; the pre-v13 rejection test now passes.
- Schema deployment and signed two-Mac Development verification remain outstanding.
  The default app still reports local-only attachments; no Production traffic or
  deployment is authorized by the opt-in implementation work.

### October 1 review follow-up

The [recovery fixes](2026-10-01-attachment-sync-review.md) add v18 local state,
primary-sync fallback, durable buffering, strict environment validation, permanent
delete receipts, and queued maintenance. That plan records the latest verification.
