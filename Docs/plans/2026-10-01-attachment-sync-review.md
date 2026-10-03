# Attachment sync review fixes

Keep primary sync available when attachment inventory or environment discovery fails.
Preserve attachment events and file ownership until catch-up can resume safely.

1. Add v18 local recovery state: durable physical-delete acknowledgements, pending
   removal work, indexed quarantine dependencies/replay flags, and buffered deletes.
   Preserve v17 libraries and their existing work.
2. Let primary startup proceed after attachment-only errors. Retain incoming attachment
   records/assets/deletions. Retry inventory from external idle/foreground work after
   quiescing the existing engine; preserve its durable cursor and primary intent.
3. Require an explicit valid environment entitlement. Report attachment errors without
   changing account scope or stopping primary sync. Sign development builds with an
   explicit Development entitlement.
4. Reconcile touched parents through a durable work queue. Remember successful physical
   deletes beyond tombstone retention, reopening that work only on a new child delivery.
   Replay quarantine on new records or dependency changes, including late parents.
5. Remove obsolete string-based sync-state overloads. Update the failure contract in
   the design/runbook and verify focused migration, sync, CLI, and Linux tests.

No release, schema deployment, or live CloudKit request is part of this change.

## Completed

- Added v18 without altering v15–v17. Migration preserves model rows and dirty
  intent, backfills confirmed physical deletes, and queues existing removals once.
- Attachment-only errors now leave primary sync available. Buffered records retain
  file ownership and deletion evidence; retries refresh current scalar versions
  before enabling attachment sends. Engine retirement preserves its durable cursor.
- Missing/invalid environment entitlements report errors without changing scope.
  Base development entitlements now specify Development; release signing retains
  its existing Production override.
- Removal and quarantine maintenance use pending work and dependency indexes.
  Permanent delete receipts survive tombstone compaction. Observation versions
  prevent late acknowledgements from completing newer child cleanup work.
- Attachment callers use the typed sync-state API; redundant String overloads
  were removed. Updated the design and sync runbook with failure/retry behavior.

## Verification

- macOS app and CLI build succeeded with pinned dependencies.
- 154 focused Sync tests, 49 Core/storage/migration tests, and 45 attachment
  CLI/MCP contract tests passed (248 total).
- Linux CLI build and 33 focused storage/migration tests passed.
- Entitlement plist validation and `git diff --check` passed. Package.resolved
  is unchanged. No live CloudKit requests or schema deployment were performed.
- The flag remains disabled by default. Signed two-Mac Development verification
  and deployment remain separate steps before enabling it for users.
