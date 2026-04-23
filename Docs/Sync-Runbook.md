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

### 5. Failure diagnostics

From the CLI: `swift run rubien-cli sync status` gives JSON.

- `entitlementPresent: false` → Xcode signing didn't grant the entitlement; check team + provisioning
- `iCloudAccountAvailable: false` → user not signed into iCloud on this Mac
- `enabled: false` → user hasn't flipped the toggle on
- `dirtyByEntityType` not draining → engine isn't pushing; check Console for CKError codes
- `tombstoneCount.unconfirmed > 0` after pushes drain → deletes aren't being ack'd by the server (likely transient; retry on next app foreground)

### 6. Reset (destructive, only if stuck)

To force a full re-sync:

```bash
# Stop the app first
rm "$HOME/Library/Application Support/Rubien/sync-engine-state.bin"
# Launch the app; next startup reconciliation will push every row dirty
```

To wipe the iCloud copy (can't be undone): use the CloudKit Dashboard "Delete Zone" action in the Library zone. The next app launch with sync enabled will re-upload everything as a fresh baseline.

## Known follow-ups

- A-pks migration (UUID primary keys) — currently using stringified Int64 rowIDs; two devices inserting independently offline can collide on rowID. Sync one device first before inserting on the second until A-pks ships.
- Field-level LWW merge — current policy is server-wins on conflict; planned refinement uses `dateModified` for finer-grained merges.
- `rubien-cli sync push / pull / reset` subcommands — deferred; only `sync status` ships in v1.
- xcconfig-driven entitlement injection for `scripts/build-app.sh` — use Xcode GUI signing for first testing.
