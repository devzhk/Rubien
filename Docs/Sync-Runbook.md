# iCloud Sync — operational setup runbook

Post-enrollment steps to take Rubien's sync from `.unavailable` to actually syncing.

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
5. Create a reference on Mac A; verify it appears on Mac B within ~10s
6. Edit the same reference on both within a few seconds; observe "server wins" behavior (whichever pushed first, other side overwrites — documented quirk of v1 merge policy)
7. Delete on Mac A; verify removal on Mac B within ~10s

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

### 7. Reset (destructive, only if stuck)

To force a full re-sync:

```bash
# Stop the app first
rm "$HOME/Library/Application Support/Rubien/sync-engine-state.bin"
# Launch the app; next startup reconciliation will push every row dirty
```

To wipe the iCloud copy (can't be undone): use the CloudKit Dashboard "Delete Zone" action in the Library zone. The next app launch with sync enabled will re-upload everything as a fresh baseline.

### 8. Schema migrations (v1 → v2 → vN)

`rubien-cli sync status` reports the live schema version under `schemaVersion`. The constant lives at `AppDatabase.currentSchemaVersion` and must be bumped in lock-step with each new `migrator.registerMigration(...)` block.

- **v1** (shipped) — initial schema. CloudKit container live with real data.
- **v2** (B8) — added per-device `pdfCache` + `pdfUploadQueue` tables, dropped the `reference.pdfPath` column. Backfills existing pdfPaths into both tables with `contentHash='pending'` (the push path re-hashes on first send).
- **v3** (Type prune + Status case fixup, 2026-05) — collapsed `ReferenceType` from 21 cases to 6 (`Journal Article`, `Conference Paper`, `Book`, `Thesis`, `Web Page`, `Other`), bulk-remapping the 15 dropped values per a fixed table (e.g. `Magazine Article` → `Journal Article`, `Blog Post` → `Web Page`, `Software` → `Other`). Also normalized `reference.readingStatus` from lowercase enum raw values to capitalized labels (`unread` → `Unread`, etc.) so they match the seeded Status PropertyDefinition. Refreshed Type PropertyDefinition's `optionsJSON` to advertise the 6-option set. **No schema change** — `referenceType` and `readingStatus` stay TEXT columns. Migration body wraps in `applyingRemote=1` so the dirty triggers don't queue every migrated row for a redundant CloudKit push.

**Forward-only.** Migrations are one-way. A v1 binary opening a v2 DB errors with `no such column: pdfPath` (the failure mode that hit the dev when the worktree migrated the live library before the matching binary shipped). Always upgrade the binary first, then let it migrate the DB on launch.

**Cross-device skew.**
- v1 device + v2 cloud: a v1 device on the same iCloud account does not push `CDReferencePDF` records — those are introduced by v2. Once that device upgrades and runs the v2 migration, its existing PDFs ride the upload queue to the cloud and become visible to all other v2 devices.
- v2 device + v3 cloud: the v3 migration only normalizes column values that the CKRecord schema already carries as String; nothing was added or removed. A still-on-v2 peer pulling a v3-migrated reference whose `referenceType` is now (say) `Other` instead of `Software` decodes the unknown value via the existing forward-compat fallback to `.other`. Same for `readingStatus = "Unread"` (capitalized) — v2's `ReadingStatus(rawValue:)` returns nil, falls back to `.unread`, and on next mutation writes `"unread"` (lowercase) back. The next v3 device that pulls that row will re-normalize it. Single-user / single-Mac libraries are unaffected; multi-device users should upgrade all peers in the same session to avoid the back-and-forth.

**Procedure for v3+.**

1. Add a new `migrator.registerMigration("v3") { db in ... }` block in `AppDatabase.swift`. Never edit v2 (or v1).
2. Bump `AppDatabase.currentSchemaVersion = "v3"`.
3. Update the `XCTAssertEqual(json?["schemaVersion"] as? String, "vN")` assertion in `Tests/RubienCLITests/SyncStatusCommandTests.swift`.
4. Add a one-paragraph entry to this section summarizing what changed and any forward/backward-compat implications.
5. If the change adds a column to a synced table or alters a CloudKit record shape, also follow the rules in `CLAUDE.md`'s Sync section (CKRecord field names match DB columns; never remove fields; `SyncSchemaInvariantTests` must stay green).

## Known follow-ups

- A-pks migration (UUID primary keys) — currently using stringified Int64 rowIDs; two devices inserting independently offline can collide on rowID. Sync one device first before inserting on the second until A-pks ships.
- Field-level LWW merge — current policy is server-wins on conflict; planned refinement uses `dateModified` for finer-grained merges.
- `rubien-cli sync push / pull / reset` subcommands — deferred; only `sync status` ships in v1.
- xcconfig-driven entitlement injection for `scripts/build-app.sh` — use Xcode GUI signing for first testing.
