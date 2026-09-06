# Sync development guidance

Implementation rules for changes to sync behavior, synced models/schema, global identities, dirty-tracking triggers, and PDF sync.

`SyncedLibrary` uses `iCloud.com.rubien.app`. Read `Docs/Sync-Runbook.md` before sync work or repairs; use `scripts/dev-launch.sh` for signed development. Do not mix Development and Production against the same sync sidecar.

- **Never rename/remove shipped CloudKit fields.** Add fields with backward-compatible decoding.
- **Preserve server change-tags:** entity mappings provide `populate(record:)`, `makeRecord`, and `init(record:)`. Populate the cached `CKRecord` rather than replacing it.
- **Global identity, not local row IDs:** preserve `syncId`, global foreign keys, and qualified record names (`<type>:<entityId>`). Follow `SyncRecordIdentity`, `SyncEntityType`, and trigger SQL; preserve proven legacy numeric identities and their compatibility fields. Never reinterpret a remote numeric identity as a current local row address.
- **Plain-value FKs, no `CKRecord.Reference`.** Resolve global parents through the existing dispatch/reconciliation paths; retain unresolved or invalid wire records in quarantine. Do not invent parents or discard records to make a fetch succeed.
- **Forward-compatible decoding:** unknown enum values use safe defaults. Keep per-device fields in local-only tables; `SyncSchemaInvariantTests` enforces synced-column coverage.
- **Durable intent:** save/delete intent must remain mutually exclusive. SQLite is authoritative; reconcile the engine's pending cache through `SyncPendingIntent`. Preserve writer-upgrade gates and tombstone eligibility; do not manually clear ambiguous or server-evidenced state.
- **Persist fetched changes before advancing the cursor:** preserve `FetchStatePersistenceGate` staging and recovery. A failed local apply must not persist advanced engine state; full-history replay completion requires a durable successful boundary.
- **No recursive timestamp triggers:** stamp `dateModified` in Swift, never via a trigger that updates its own row.
- **No engine re-entry:** never call `fetchChanges()` / `sendChanges()` from `handleEvent`, even indirectly through a `Task`. Explicit fetches originate from launch, foreground, or the idle timer.

PDFs use sibling `CDReferencePDF` records with `CKAsset`; local materialization state stays in `pdfCache`. Preserve the upload queue and identity checks. Operational repair and rollout procedures belong in the Sync runbook.
