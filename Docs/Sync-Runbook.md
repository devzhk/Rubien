# iCloud Sync — operational setup runbook

Post-enrollment steps to take Rubien's sync from `.unavailable` to actually syncing.

> **⚠️ The #1 gotcha: two isolated CloudKit environments.** CloudKit has separate
> **Development** and **Production** environments, and data never crosses between them.
> The environment is selected by the **signed** `com.apple.developer.icloud-container-environment`
> entitlement — **not** the provisioning profile (the profile's value alone is NOT honored at
> runtime for Developer-ID / non-App-Store macOS builds). The base
> `Sources/Rubien/Rubien.entitlements` deliberately **omits** the key so dev builds stay on
> Development; `scripts/build-app.sh` **injects `…=Production` into release (DMG) builds only**
> at sign time. Omitting the injection makes a Developer-ID build silently use **Development**
> (the bug that shipped in v0.1.2 — data landed in Development while Production stayed empty).
>
> | Build | How signed | CloudKit env |
> |---|---|---|
> | `scripts/dev-launch.sh`, Xcode debug | base entitlements (keyless) + Development profile | **Development** |
> | `scripts/build-app.sh release` DMG | base **+ injected `…=Production`** (in the signature) | **Production** |
>
> Verify a built app's environment:
> `codesign -d --entitlements :- <App>.app | grep icloud-container-environment`.
> You must also deploy the schema to Production (§2.5) before any release build can sync, and
> Production starts empty even when Development is full. Symptom of a build on the wrong env: an
> empty library + 0 KB PDF cache while another build on the same iCloud account syncs fine.

## Prerequisites

- Active paid Apple Developer Program membership
- Bundle ID `com.rubien.app` on your developer team
- Mac mini + MacBook (or any two Macs) signed into the same iCloud account

## Steps (do in order)

### 1. Create the CloudKit container

1. Sign in at <https://icloud.developer.apple.com>
2. Click **New Container**
3. Identifier: `iCloud.com.rubien.app` (must exactly match `SyncConstants.containerIdentifier`)
4. Save

### 2. Add the CloudKit capability in Xcode

If building via Xcode's GUI:

1. Open the project in Xcode → select the Rubien target
2. Signing & Capabilities tab
3. Click **+ Capability** → choose **iCloud**
4. Check **CloudKit**
5. Under **Containers**, click **+** and select the `iCloud.com.rubien.app` container created above
6. Xcode updates the entitlements file automatically; the CloudKit capability's container should match the `<array><string>iCloud.com.rubien.app</string></array>` entry we ship dormant.

If building via `scripts/build-app.sh` (which calls `xcodebuild`):

- A signing identity with the CloudKit capability on the `com.rubien.app` bundle ID must be present in your keychain
- Without it, the build produces an unsigned app whose entitlements are stripped and sync stays in `.unavailable`
- xcconfig-driven signing is a separate follow-up; for first smoke test, use the Xcode GUI path

### 2.5 Deploy the schema to Production (before shipping a release build)

Development auto-creates record types the first time a dev build saves a record.
**Production never auto-creates them** — you deploy explicitly. Skip this and every
release-build user syncs against an empty Production container (no `Library` zone, no
record types), so a fresh install shows an empty library and 0 KB PDF cache.

1. CloudKit Dashboard → `iCloud.com.rubien.app` → **Development** → **Schema → Record Types**.
   Confirm the exact 14-type set from `SyncConstants.RecordType` is present:
   `CDReference`, `CDReferencePDF`, `CDTag`, `CDReferenceTag`, `CDPDFAnnotation`,
   `CDWebAnnotation`, `CDMetadataIntake`, `CDMetadataEvidence`, `CDPropertyDefinition`,
   `CDPropertyValue`, `CDDatabaseView`, `CDReadingActivity`, `CDAssistantActivity`, and
   `CDActivityEpoch`.
2. Import the checked-in `CloudKit/RubienSchema.ckdb` into Development and review the
   additive diff. `CloudKitSchemaFileTests` keeps that file aligned with every key written by
   the `populate(record:)` mappings under `Sources/RubienSync/`. Development infers an
   optional field only after a record is saved with a non-`nil` value; a sparse sample library
   can therefore make a record type look complete while silently omitting fields. Do not rely
   on representative sample data to materialize the schema.
3. For the July 2026 repair specifically, verify these additions are visible in Development:

   | Record type | Required addition | CloudKit type |
   |---|---|---|
   | `CDReference` | `notes`, `favicon`, `editorsJSON`, `translatorsJSON`, `eventPlace`, `genre`, `institution`, `number`, `pmid`, `pmcid`, `issn`, `issue`, `volume`, `accessedDate`, `numberOfPages` | String |
   | `CDReference` | `issuedMonth`, `issuedDay` | Int(64) |
   | `CDMetadataEvidence` | `sourceURL` | String |
   | `CDMetadataEvidence` | `referenceId` | Int(64) |
   | `CDMetadataIntake` | `originalInput` | String |
   | `CDDatabaseView` | `groupByJSON` | String |
   | `CDReadingActivity` | record type and all fields from `ReadingActivity.RecordField` | mixed |
   | `CDAssistantActivity` | record type and all fields from `AssistantActivity.RecordField` | mixed |
   | `CDActivityEpoch` | record type and all fields from `ActivityEpoch.RecordField` | mixed |

4. **Deploy Schema Changes…** → review the diff → **Deploy to Production**. This copies
   schema—record types, fields, and indexes—only. It **never copies data**.
5. Switch the Dashboard to **Production** and repeat the type-and-field audit. Do not treat a
   successful deploy dialog as verification. Run `./scripts/validate-cloudkit-schema.sh`;
   it must validate and export both environments without reporting a missing requirement.
6. Production schema is effectively append-only (you can add types/fields later, not remove
   them), so deploy from a Development schema you're willing to ship.

**Seeding Production with an existing library.** Schema deploy moves no records. There is
currently no supported full-rebaseline operation for a library whose baseline has already
completed. Deleting only `sync-engine-state.bin` resets CloudKit change tokens, but it does
not clear `syncSession.baselineState` or mark clean local rows dirty. Seed an empty Production
environment from a fresh, isolated library/import path whose first baseline has not completed,
or add a purpose-built atomic rebaseline operation. Do not delete a Production zone expecting
an existing library to upload itself again automatically.

**Don't mix flavors on one machine.** Dev and release builds share one `sync-engine-state.bin`
per library; alternating them makes the two environments fight over the same state tokens.
For multi-Mac testing, run the same flavor on every machine.

### 3. Smoke test

On the Mac you use for development:

1. Build and launch Rubien
2. Cmd+, to open Settings → iCloud Sync pane
3. Flip the toggle on; confirm the first-run sheet
4. Toolbar cloud icon should go blue (syncing), then to accent color (idle) within ~10s
5. Open Console.app, filter `subsystem:Rubien category:SyncedLibrary`; you should see `reconciled N pending changes` followed by `sent N records`

### 4. Second-Mac verification

1. Sign into the same iCloud account on a second Mac
2. Build + install Rubien
3. Cmd+, → iCloud Sync → toggle on + confirm
4. Library should populate from the cloud within ~30s
5. Create a reference on Mac A. Mac B pulls it on its **next fetch trigger**, not instantly: bring Mac B to the foreground (or wait up to one idle-poll interval, `SyncConstants.idleFetchInterval`, ~90s, while it's frontmost). Incremental remote changes are fetched on app launch, on app foreground, and on the idle timer — there is **no push-driven live fetch yet** (that's Layer B / the iCloud push entitlement, deferred to the iOS port).
6. Edit the same reference on both within a few seconds; on the next fetch each side observes "server wins" behavior (whichever pushed first, other side overwrites — documented quirk of v1 merge policy)
7. Delete on Mac A; bring Mac B to the foreground (or wait one idle-poll interval) and verify the removal

### 5. PDF asset sync smoke test (post-B8)

After enabling sync on two Macs running B8 builds:

1. **Mac A:** Import a small PDF (5–10 MB) onto a new Reference. Watch Settings → Sync → "Uploading 1 of 1 PDF to iCloud" briefly; the indicator should clear within ~30s on a normal connection.
2. **Mac B:** Wait ~30–60s for the next pull cycle. Open the same Reference. The PDF should render in the reader.
3. **Mac A:** Edit the Reference's `notes` field. The CDReferencePDF asset should NOT re-upload — it's a separate record from CDReference, so scalar edits don't touch it. Confirm via `rubien-cli sync status`: `pdfBackfillRemaining` stays 0.
4. **Mac A:** Delete the Reference. Mac B should drop both the Reference row AND the local PDF file via tombstone propagation + FK cascade on `pdfCache`.
5. **iCloud quota smoke:** if you have a small free-tier account and want to verify quota handling, use a large library — when the engine returns `.quotaExceeded`, the existing sync banner surfaces.

If any step fails, see the general "Failure diagnostics" section below. Asset-specific diagnostic: `rubien-cli pdf status <id>` shows the cache row state for one Reference (cached/version/hash/inUploadQueue).

### 6. Failure diagnostics

From the CLI: `swift run rubien-cli sync status` gives JSON.

- `entitlementPresent: false` → Xcode signing didn't grant the entitlement; check team + provisioning
- `iCloudAccountAvailable: false` → user not signed into iCloud on this Mac
- `enabled: false` → user hasn't flipped the toggle on
- `dirtyByEntityType` not draining → engine isn't pushing; check Console for CKError codes
- `tombstoneCount.unconfirmed > 0` after pushes drain → deletes aren't being ack'd by the server (likely transient; retry on next app foreground)

### 7. Replay CloudKit history on a receiving device

Use this only after the Production schema is verified and the installed build contains every
required database migration. The cloud/source library must be authoritative, and the receiving
device must not contain unique local data. Resetting the sidecar makes that device fetch
CloudKit history from the beginning; it does **not** mark clean local rows dirty or force a
full upload.

Do not run a full-history replay on v0.7.1 or earlier. During a cross-batch FK apply failure,
those builds can persist CKSyncEngine's advanced cursor even though the corresponding SQLite
transaction rolled back, permanently skipping the failed portion of history on that device.
Updated builds stage engine state until every fetched batch commits. If an apply fails, they
discard the advanced cursor and recreate the engine from the last durable sidecar on the next
launch, foreground, or idle fetch. A log sequence containing
`transient FK orphans tolerated` followed by `FK violations after remote apply ... rolling back`
is the signature of this older-build failure.

Updated builds also split a mixed fetched event into an orphan-tolerant modification transaction
and an FK-enforced deletion transaction. CloudKit can deliver a child modification before its
parent even when that event also contains unrelated deletions; the split allows that temporary
orphan to commit without disabling local `ON DELETE CASCADE` behavior.

During a known full-history replay (the engine started with no durable sidecar), updated builds
reconcile any child whose parent still never arrived at the successful end-of-zone boundary.
Synced children are deleted locally and queued as CloudKit tombstones so later devices do not
inherit the same stale records; orphaned PDF cache files are unlinked only after the cleanup
transaction commits. Optional metadata-intake links are cleared rather than deleting their
intake history. Ordinary incremental fetches never infer server absence from a locally missing
parent: their change delta is not a complete CloudKit snapshot. An unknown FK shape during a
full replay fails reconciliation and keeps the fetch cursor non-durable instead of silently
accepting a persistently inconsistent library. A durable database marker is written before
CKSyncEngine can start and is cleared only after both terminal cleanup and the end-of-fetch
cursor are durable. If the marker survives a crash, startup discards any ambiguous sidecar and
replays from nil again.

One v0.7.1 upgrade path had a second failure mode: transient sync orphans in a v10 database
caused GRDB's whole-database FK check to reject the pending v11 repair migration. Startup then
silently substituted an in-memory database while CKSyncEngine continued writing its cursor
sidecar beside the unopened persistent library. Updated builds apply that exact v10 → v11 repair
with FK enforcement left on (preserving existing orphans while preventing new ones) and never
fall back to an implicit in-memory library. A running packaged app should therefore always hold
an open `library.sqlite` file; no matching handle in the first diagnostic below is a startup
failure, not evidence that SQLite is idle.

1. While Rubien is running, resolve the actual live database instead of guessing:

   ```bash
   lsof -p "$(pgrep -f 'Rubien.app/Contents/MacOS/Rubien')" | grep library.sqlite
   ```

2. Record the directory containing that exact `library.sqlite`, then quit Rubien completely.
3. Copy the **entire resolved library root** to a sibling backup while the app is stopped.
   Preserve `library.sqlite`, any `-wal`/`-shm` files, PDFs, metadata artifacts, and the
   sync sidecar together. A sidecar-only backup is not a database rollback.
4. In the original library root, move `sync-engine-state.bin` aside if it exists.
5. Launch the updated app. It migrates the local database before replaying CloudKit history.

On the receiving device, confirm the reference count reaches the source count and that
`dirtyByEntityType` drains. Keep the full backup until both checks pass. To roll back, quit
Rubien, move the current library root aside, and restore the full quit-time backup as one unit.
Do not restore only the sidecar, and do not reset the source device during this recovery.

Do not use CloudKit Dashboard's **Delete Zone** action as routine recovery. It permanently
removes the cloud copy, and an already-baselined local library is not automatically marked for
full re-upload.

### 8. Schema migrations (v1 → v2 → vN)

`rubien-cli sync status` reports the live schema version under `schemaVersion`. The constant lives at `AppDatabase.currentSchemaVersion` and must be bumped in lock-step with each new `migrator.registerMigration(...)` block.

- **v1** (shipped) — initial schema. CloudKit container live with real data.
- **v2** (B8) — added per-device `pdfCache` + `pdfUploadQueue` tables, dropped the `reference.pdfPath` column. Backfills existing pdfPaths into both tables with `contentHash='pending'` (the push path re-hashes on first send).
- **v3** (Type prune + Status case fixup, 2026-05) — collapsed `ReferenceType` from 21 cases to 6 (`Journal Article`, `Conference Paper`, `Book`, `Thesis`, `Web Page`, `Other`), bulk-remapping the 15 dropped values per a fixed table (e.g. `Magazine Article` → `Journal Article`, `Blog Post` → `Web Page`, `Software` → `Other`). Also normalized `reference.readingStatus` from lowercase enum raw values to capitalized labels (`unread` → `Unread`, etc.) so they match the seeded Status PropertyDefinition. Refreshed Type PropertyDefinition's `optionsJSON` to advertise the 6-option set (v6 later appends a seventh, `Markdown` — see below). **No schema change** — `referenceType` and `readingStatus` stay TEXT columns. Migration body wraps in `applyingRemote=1` so the dirty triggers don't queue every migrated row for a redundant CloudKit push.
- **v6** (Markdown type option, 2026-07) — appended a seventh `ReferenceType` case, `Markdown` (for imported Markdown notes; chip color `#5AC8FA`), to the Type PropertyDefinition's `optionsJSON` via the shared `TypeOptionsReconciler` — a fail-safe structural JSON append that preserves existing options, colors, and unknown fields, leaves malformed `optionsJSON` untouched, and (like v3) wraps in `applyingRemote=1` so it queues no CloudKit push. Because `optionsJSON` syncs verbatim, an old six-option peer's push would otherwise re-drop `Markdown`, so RubienSync's remote-apply path re-heals any missing enum-backed Type option on every incoming Type PropertyDefinition — without dirtying the record — so no peer can remove it. **No schema change** — `referenceType` stays a TEXT column and no CKRecord field was added.
- **v7** (activity sync, 2026-07) — added mergeable reading counters, Assistant activity, reset epochs, pending-clear state, and activity quarantine. The three synced entities require `CDReadingActivity`, `CDAssistantActivity`, and `CDActivityEpoch` in Production.
- **v8** (scheduled jobs, 2026-07) — added local-only scheduled Assistant definitions and run history. No CloudKit schema change.
- **v9** (hidden run history, 2026-07) — added the local-only `scheduledJobRun.hiddenAt` marker. No CloudKit schema change.
- **v10** (Assistant transcripts, 2026-07) — added Rubien-owned local transcript tables and scheduled-run transcript state. No CloudKit schema change.
- **v11** (pre-release schema repair, 2026-07) — conditionally restores `activityQuarantine.referenceId`, backfills it from quarantined `ReadingActivity` payloads, replaces the stale quarantine index, and reconciles non-unique scheduled-run indexes found in development libraries created before the released v7/v8 migrations. Healthy released databases already have the column; v11 checks `db.columns(in:)` first and is an idempotent no-op for their data. No CloudKit schema change.

**Forward-only.** Migrations are one-way. A v1 binary opening a v2 DB errors with `no such column: pdfPath` (the failure mode that hit the dev when the worktree migrated the live library before the matching binary shipped). Always upgrade the binary first, then let it migrate the DB on launch.

**Cross-device skew.**
- v1 device + v2 cloud: a v1 device on the same iCloud account does not push `CDReferencePDF` records — those are introduced by v2. Once that device upgrades and runs the v2 migration, its existing PDFs ride the upload queue to the cloud and become visible to all other v2 devices.
- v2 device + v3 cloud: the v3 migration only normalizes column values that the CKRecord schema already carries as String; nothing was added or removed. A still-on-v2 peer pulling a v3-migrated reference whose `referenceType` is now (say) `Other` instead of `Software` decodes the unknown value via the existing forward-compat fallback to `.other`.
- **`readingStatus` lowercase escape.** Same shape but with a sharper edge: v2's `ReadingStatus(rawValue:)` returns nil for the new capitalized values `"Unread"` / `"Reading"` / `"Skimmed"` / `"Read"`, falls back to `.unread`, and on next mutation writes back `"unread"` (lowercase). v3 decode is now free-form and **passes whatever it pulls through unchanged** — there is no second normalization pass, so the v3 device will then read and store the lowercase string verbatim. Once that has happened, the only thing that fixes it is another local edit that round-trips through a v3 mutation, or a manual run of the v3 migration body via `runV3MigrationForTesting` (which is a one-shot helper, not the production migrator). Practical implication for multi-device users: upgrade all peers in the same session before mutating Status from a v2 device. Single-user / single-Mac libraries are unaffected.
- pre-v6 device + v6 cloud: `Markdown` is a new `referenceType` rawValue; an older peer pulling a Markdown reference decodes the unknown value via the existing forward-compat fallback to `.other`, and the new Type option itself can't be lost — every up-to-date peer re-heals it on apply (see v6 above).
- malformed pre-release v7 device + v11 build: upgrade the binary before resetting sync-engine state. v11 repairs the local quarantine query that otherwise rolls back any fetched batch containing an applied Reference. Released v7 databases already have the correct column and index.

**Procedure for every new migration.**

1. Add a new `migrator.registerMigration("vN") { db in ... }` block in `AppDatabase.swift`. Never edit an earlier migration.
2. Bump `AppDatabase.currentSchemaVersion = "vN"`.
3. Keep the schema-version contract in `Tests/RubienCLITests/SyncStatusCommandTests.swift` green.
4. Add a one-paragraph entry to this section summarizing what changed and any forward/backward-compat implications.
5. If the change adds a column to a synced table or alters a CloudKit record shape, also follow the rules in `CLAUDE.md`'s Sync section (CKRecord field names match DB columns; never remove fields; `SyncSchemaInvariantTests` must stay green).

## Known follow-ups

- **Push-driven live fetch (Layer B).** Today incremental remote changes arrive only on launch / foreground / a ~90s idle poll (`SyncConstants.idleFetchInterval`). True push-driven sync needs the `aps-environment` entitlement (dev/release split like `icloud-container-environment`), Push enabled on the `com.rubien.app` App ID, and on-device verification that a Developer-ID DMG build actually receives CloudKit silent pushes. Planned with the iOS port. See `Docs/specs/2026-06-01-sync-incremental-fetch-design.md`.
- A-pks migration (UUID primary keys) — currently using stringified Int64 rowIDs; two devices inserting independently offline can collide on rowID. Sync one device first before inserting on the second until A-pks ships.
- Field-level LWW merge — current policy is server-wins on conflict; planned refinement uses `dateModified` for finer-grained merges.
- `rubien-cli sync push / pull / reset` subcommands — deferred; only `sync status` ships in v1.
- xcconfig-driven entitlement injection for `scripts/build-app.sh` — use Xcode GUI signing for first testing.
