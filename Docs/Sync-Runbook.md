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
   Confirm the full set from `SyncConstants.RecordType` is present (`CDReference`,
   `CDReferencePDF`, `CDTag`, `CDReferenceTag`, `CDPDFAnnotation`, `CDWebAnnotation`,
   `CDMetadataIntake`, `CDMetadataEvidence`, `CDPropertyDefinition`, `CDPropertyValue`,
   `CDDatabaseView`).
2. **Deploy Schema Changes…** → review the diff → **Deploy to Production**. This copies
   record types + indexes only — **never data**.
3. Production schema is effectively append-only (you can add types/fields later, not remove
   them), so deploy from a Development schema you're willing to ship.

**Seeding Production with an existing library.** Schema deploy moves no records. To populate
Production, a Production (release) build must push the data: quit the app, delete
`sync-engine-state.bin` from the library folder (see §7) so the engine re-pushes a full
baseline, then launch the release build with sync on. Other release devices then pull it.

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
- **v3** (Type prune + Status case fixup, 2026-05) — collapsed `ReferenceType` from 21 cases to 6 (`Journal Article`, `Conference Paper`, `Book`, `Thesis`, `Web Page`, `Other`), bulk-remapping the 15 dropped values per a fixed table (e.g. `Magazine Article` → `Journal Article`, `Blog Post` → `Web Page`, `Software` → `Other`). Also normalized `reference.readingStatus` from lowercase enum raw values to capitalized labels (`unread` → `Unread`, etc.) so they match the seeded Status PropertyDefinition. Refreshed Type PropertyDefinition's `optionsJSON` to advertise the 6-option set (v6 later appends a seventh, `Markdown` — see below). **No schema change** — `referenceType` and `readingStatus` stay TEXT columns. Migration body wraps in `applyingRemote=1` so the dirty triggers don't queue every migrated row for a redundant CloudKit push.
- **v6** (Markdown type option, 2026-07) — appended a seventh `ReferenceType` case, `Markdown` (for imported Markdown notes; chip color `#5AC8FA`), to the Type PropertyDefinition's `optionsJSON` via the shared `TypeOptionsReconciler` — a fail-safe structural JSON append that preserves existing options, colors, and unknown fields, leaves malformed `optionsJSON` untouched, and (like v3) wraps in `applyingRemote=1` so it queues no CloudKit push. Because `optionsJSON` syncs verbatim, an old six-option peer's push would otherwise re-drop `Markdown`, so RubienSync's remote-apply path re-heals any missing enum-backed Type option on every incoming Type PropertyDefinition — without dirtying the record — so no peer can remove it. **No schema change** — `referenceType` stays a TEXT column and no CKRecord field was added.

**Forward-only.** Migrations are one-way. A v1 binary opening a v2 DB errors with `no such column: pdfPath` (the failure mode that hit the dev when the worktree migrated the live library before the matching binary shipped). Always upgrade the binary first, then let it migrate the DB on launch.

**Cross-device skew.**
- v1 device + v2 cloud: a v1 device on the same iCloud account does not push `CDReferencePDF` records — those are introduced by v2. Once that device upgrades and runs the v2 migration, its existing PDFs ride the upload queue to the cloud and become visible to all other v2 devices.
- v2 device + v3 cloud: the v3 migration only normalizes column values that the CKRecord schema already carries as String; nothing was added or removed. A still-on-v2 peer pulling a v3-migrated reference whose `referenceType` is now (say) `Other` instead of `Software` decodes the unknown value via the existing forward-compat fallback to `.other`.
- **`readingStatus` lowercase escape.** Same shape but with a sharper edge: v2's `ReadingStatus(rawValue:)` returns nil for the new capitalized values `"Unread"` / `"Reading"` / `"Skimmed"` / `"Read"`, falls back to `.unread`, and on next mutation writes back `"unread"` (lowercase). v3 decode is now free-form and **passes whatever it pulls through unchanged** — there is no second normalization pass, so the v3 device will then read and store the lowercase string verbatim. Once that has happened, the only thing that fixes it is another local edit that round-trips through a v3 mutation, or a manual run of the v3 migration body via `runV3MigrationForTesting` (which is a one-shot helper, not the production migrator). Practical implication for multi-device users: upgrade all peers in the same session before mutating Status from a v2 device. Single-user / single-Mac libraries are unaffected.
- pre-v6 device + v6 cloud: `Markdown` is a new `referenceType` rawValue; an older peer pulling a Markdown reference decodes the unknown value via the existing forward-compat fallback to `.other`, and the new Type option itself can't be lost — every up-to-date peer re-heals it on apply (see v6 above).

**Procedure for v3+.**

1. Add a new `migrator.registerMigration("v3") { db in ... }` block in `AppDatabase.swift`. Never edit v2 (or v1).
2. Bump `AppDatabase.currentSchemaVersion = "v3"`.
3. Update the `XCTAssertEqual(json?["schemaVersion"] as? String, "vN")` assertion in `Tests/RubienCLITests/SyncStatusCommandTests.swift`.
4. Add a one-paragraph entry to this section summarizing what changed and any forward/backward-compat implications.
5. If the change adds a column to a synced table or alters a CloudKit record shape, also follow the rules in `CLAUDE.md`'s Sync section (CKRecord field names match DB columns; never remove fields; `SyncSchemaInvariantTests` must stay green).

## Known follow-ups

- **Push-driven live fetch (Layer B).** Today incremental remote changes arrive only on launch / foreground / a ~90s idle poll (`SyncConstants.idleFetchInterval`). True push-driven sync needs the `aps-environment` entitlement (dev/release split like `icloud-container-environment`), Push enabled on the `com.rubien.app` App ID, and on-device verification that a Developer-ID DMG build actually receives CloudKit silent pushes. Planned with the iOS port. See `Docs/superpowers/specs/2026-06-01-sync-incremental-fetch-design.md`.
- A-pks migration (UUID primary keys) — currently using stringified Int64 rowIDs; two devices inserting independently offline can collide on rowID. Sync one device first before inserting on the second until A-pks ships.
- Field-level LWW merge — current policy is server-wins on conflict; planned refinement uses `dateModified` for finer-grained merges.
- `rubien-cli sync push / pull / reset` subcommands — deferred; only `sync status` ships in v1.
- xcconfig-driven entitlement injection for `scripts/build-app.sh` — use Xcode GUI signing for first testing.
