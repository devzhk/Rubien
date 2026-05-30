# CloudKit Production Environment Fix — Implementation Plan

**Goal:** Make Developer-ID (DMG) release builds use the CloudKit **Production** environment instead of silently defaulting to **Development**, by pinning `com.apple.developer.icloud-container-environment = Production` into the *signed* entitlements of release builds only — while leaving `dev-launch.sh` builds on Development.

**Architecture:** One-line semantic change delivered via build-time entitlement injection in `scripts/build-app.sh` (so the base `Rubien.entitlements`, shared with `dev-launch.sh`, stays environment-agnostic). Followed by an on-device validation pass on Mac A, then a v0.1.3 re-release.

**Tech stack:** macOS Developer ID codesigning, CloudKit / CKSyncEngine, bash build scripts, GRDB SQLite, Sparkle appcast release.

---

## Background — root cause (the bug this fixes)

Symptom chain observed live on 2026-05-30:

1. Release v0.1.2 (Developer ID DMG) on Mac A pushed its full library and got **server acks**: `syncState.systemFields` repopulated from server responses for all 113 references + tags/properties/annotations + 56 PDFs. (Proof the records reached *a* CloudKit server.)
2. **Production** private DB shows **no `Library` zone** — verified two independent ways: the Mac mini (also a release build) does not pull, and the CloudKit Dashboard with *Act As iCloud Account* shows nothing.
3. **Development** private DB **has** a `Library` zone.
4. ∴ the release build's data is going to **Development**, not Production.

**Why:** `Sources/Rubien/Rubien.entitlements` does **not** contain `com.apple.developer.icloud-container-environment`. Confirmed absent from the app's *signed* entitlements (`codesign -d --entitlements`). The embedded `Rubien Developer ID Distribution` provisioning profile *does* carry `icloud-container-environment = Production`, but **the profile value alone is not honored at runtime** — for non-App-Store (Developer ID) macOS builds the key must be present in the *signed entitlements* to select Production; otherwise CloudKit uses Development. Only TestFlight/App Store builds default to Production unconditionally.

Sources:
- https://developer.apple.com/forums/thread/707098 (entitlement must be in `.entitlements`, not the profile/Info.plist)
- https://developer.apple.com/forums/thread/17499

**Pre-existing doc that is now known-wrong:** the `Docs/Sync-Runbook.md` callout (added earlier today, uncommitted) claims "the environment is chosen by the build's provisioning profile." That is the exact incorrect assumption that masked this bug; Task 4 corrects it.

---

## Key facts the implementer needs

- Release outer-app signing happens in `scripts/build-app.sh` → `sign_bundle()` (lines ~265-299). The outer `codesign` call uses `--entitlements "$CODESIGN_ENTITLEMENTS"` (lines 289-293).
- `CODESIGN_ENTITLEMENTS` defaults to `$PROJECT_DIR/Sources/Rubien/Rubien.entitlements` (line 66).
- `$FLAVOR = dmg` already gates the Developer-ID release path (Sparkle framework signing at line 282). The injection should use the **same gate**, so non-DMG/MAS flavors are untouched (MAS always uses Production regardless).
- `dev-launch.sh` calls `CODESIGN_ENABLED=0 ./scripts/build-app.sh debug` (lines 60-61) — so `sign_bundle()` (and the injection) is **skipped entirely** — then signs independently in its own block (helper sign `83-90`, app sign `92-95`) using `ENTITLEMENTS` (default base `Rubien.entitlements`) and the **Development** profile (`Rubien_Mac_Dev.provisionprofile`). Its `rubien_require_entitlement` checks only look for app-id + App Group, not the env key, so they still pass. Net: dev builds stay on Development. (Corrected per Codex review — the earlier draft wrongly said dev-launch doesn't call build-app.sh.)
- The existing distribution profile already authorizes `icloud-container-environment = Production`, so no new provisioning profile is required — `codesign` will accept the injected key.
- Live library on Mac A: `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/` (note: `group.`-prefixed; this is `AppDatabase.appGroupID`). Sync bookkeeping tables in `library.sqlite`: `syncSession` (holds `baselineState`), `syncState` (`systemFields` BLOB per entity, `isDirty`), `tombstone`.

---

## Task 1: Inject `Production` into release (DMG) signing only

**Files:**
- Modify: `scripts/build-app.sh` — `sign_bundle()` (lines ~285-298)

- [ ] **Step 0: Verify the distribution profile actually authorizes Production** (Codex flagged this is asserted, not validated).

```bash
security cms -D -i "$HOME/Downloads/Rubien_Developer_ID_Distribution.provisionprofile" 2>/dev/null \
  | /usr/libexec/PlistBuddy -c "Print Entitlements:com.apple.developer.icloud-container-environment" /dev/stdin 2>/dev/null \
  || echo "(profile missing Production env — regenerate at developer.apple.com before proceeding)"
```

Expected: `Production`. If absent, the injected entitlement won't be authorized and signing/launch fails (AMFI -413); regenerate the profile first. *(Already confirmed `Production` earlier this session, but keep this as a guard.)*

- [ ] **Step 1: Add the injection before the outer codesign call.**

Replace the existing outer-sign block (current lines 286-298):

```bash
    # No --deep on the outer call: the embedded CLI is already signed above
    # and --deep just re-walks the signed tree, which historically chokes on
    # xattrs that get re-added between the inner and outer sign steps.
    if [ -n "$CODESIGN_ENTITLEMENTS" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$CODESIGN_ENTITLEMENTS" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    else
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    fi
```

with:

```bash
    # Developer-ID (DMG) release builds must pin CloudKit Production into the
    # SIGNED entitlements. The value in the provisioning profile is NOT honored
    # at runtime for non-App-Store macOS builds, so without this the installed
    # app silently uses the CloudKit *Development* environment (empty for end
    # users). The base Rubien.entitlements stays environment-agnostic so
    # dev-launch.sh builds remain on Development; we inject only here, gated on
    # the same FLAVOR=dmg used for Sparkle signing above.
    # Release (Production) artifact ONLY. Per Codex review: FLAVOR defaults to
    # dmg even for MODE=debug (build-app.sh:4-5), so gate on MODE too, plus real
    # signing. Inject (vs a 2nd checked-in entitlements file) so the base file
    # stays the single source of truth — a future key added to the base can't go
    # silently missing from releases; dev-launch.sh (keyless base) stays on
    # Development.
    local sign_entitlements="$CODESIGN_ENTITLEMENTS"
    local prod_ent_dir=""
    if [ "$MODE" = "release" ] && [ "$FLAVOR" = "dmg" ] \
       && [ "$CODESIGN_ENABLED" = "1" ] && [ -n "$CODESIGN_ENTITLEMENTS" ]; then
        # mktemp -d (not `mktemp ...).plist`, which leaked a bare temp file on
        # macOS); name the plist inside the dir, clean the dir up after signing.
        prod_ent_dir="$(mktemp -d -t rubien-release-ent)"
        sign_entitlements="$prod_ent_dir/Rubien.release.entitlements"
        cp "$CODESIGN_ENTITLEMENTS" "$sign_entitlements"
        # Add-or-set so it's idempotent if the base file ever gains the key.
        /usr/libexec/PlistBuddy -c \
            "Add :com.apple.developer.icloud-container-environment string Production" \
            "$sign_entitlements" 2>/dev/null \
          || /usr/libexec/PlistBuddy -c \
            "Set :com.apple.developer.icloud-container-environment Production" \
            "$sign_entitlements"
        echo "   ✓ Injected CloudKit Production environment into release entitlements"
    fi

    # No --deep on the outer call: the embedded CLI is already signed above
    # and --deep just re-walks the signed tree, which historically chokes on
    # xattrs that get re-added between the inner and outer sign steps.
    if [ -n "$sign_entitlements" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$sign_entitlements" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    else
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    fi

    # Clean up temp release entitlements. No `trap ... EXIT` (would clobber any
    # script-level EXIT trap); sign_bundle() returns right after this.
    [ -n "$prod_ent_dir" ] && rm -rf "$prod_ent_dir"
```

- [ ] **Step 2: Build a real Developer-ID-signed bundle (no notarization needed to validate).**

```bash
cd /Users/hzzheng/CodeHub/Rubien
CODESIGN_IDENTITY="Developer ID Application: Hongkai Zheng (9TXK4V3SS8)" \
  ./scripts/build-app.sh release
```

Expected: build succeeds; console prints `✓ Injected CloudKit Production environment into release entitlements`.

- [ ] **Step 3: Verify the entitlement is now in the SIGNED bundle.**

```bash
codesign -d --entitlements :- "build/Rubien.app" 2>/dev/null \
  | grep -A1 -i "icloud-container-environment"
```

Expected: shows `<key>com.apple.developer.icloud-container-environment</key>` → `<string>Production</string>`.

- [ ] **Step 4: Confirm the base file is still keyless (dev path unaffected).**

```bash
grep -c "icloud-container-environment" Sources/Rubien/Rubien.entitlements
```

Expected: `0`.

- [ ] **Step 5: Commit.**

```bash
git add scripts/build-app.sh
git commit -m "build: pin CloudKit Production env into release entitlements (Developer ID builds defaulted to Development)"
```

---

## Task 2: Validate on Mac A — release build reaches Production

**Why a reset is needed:** the current `syncState.systemFields` are *Development* server change-tags, and `baselineState=complete` blocks re-push. To push cleanly into the (empty) Production zone we clear the Development-tainted bookkeeping so every row re-pushes as a fresh create. **Per Codex review, the reset must also `DELETE FROM tombstone`** — startup unconditionally re-enqueues every tombstone row (`SyncStateStore.swift:199-214`, `SyncedLibrary.swift:389-403`), so the 3206 Development-acked tombstones would otherwise replay as deletes into the fresh Production zone (surfacing as `.unknownItem` churn).

- [ ] **Step 1: Install the new build and quit any running Rubien.**

Replace `/Applications/Rubien.app` with the freshly built `build/Rubien.app`, ensure the app is fully quit (`pgrep -x Rubien` returns nothing).

- [ ] **Step 2: Reset sync bookkeeping on the live library (same reset proven earlier today).**

```bash
ROOT="$HOME/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien"
DB="$ROOT/library.sqlite"
cp -f "$DB" "$ROOT/.backup-pre-prod-switch-$(date +%Y%m%d-%H%M%S).sqlite"
sqlite3 "$DB" "DELETE FROM syncSession WHERE key='baselineState'; DELETE FROM syncState; DELETE FROM tombstone; PRAGMA wal_checkpoint(TRUNCATE);"
rm -f "$ROOT/sync-engine-state.bin"
```

- [ ] **Step 3: Launch the new build, enable sync, keep it foreground.**

Cmd-, → iCloud Sync → toggle on. Watch "Uploading N of 100 PDFs."

- [ ] **Step 4: Confirm Production now has the zone + data (reliable Zones view, not Records query).**

CloudKit Dashboard → **Production** → Private DB → **Zones** → expect a `Library` zone with a climbing record count. (`Zones` view does not hit the "recordName not queryable" index error.)

- [ ] **Step 5: Confirm server-ack locally.**

```bash
.build/debug/rubien-cli sync status | python3 -c "import json,sys;d=json.load(sys.stdin);print('dirty',sum(d['dirtyByEntityType'].values()),'pdfRemaining',d['pdfBackfillRemaining'])"
```

Expected: trends toward `dirty 0 pdfRemaining 0`.

---

## Task 3: Cut v0.1.3 release

- [ ] **Step 1:** Bump `VERSION` → `0.1.3`, `BUILD.txt` → `4`.
- [ ] **Step 2:** From clean `main`, run `./scripts/release.sh` (notarize + EdDSA sign + appcast + GitHub release).
- [ ] **Step 3:** Update `Docs/CLI-Reference.md` only if CLI surface changed (it did not — skip).
- [ ] **Step 4:** On the Mac mini, update to v0.1.3 (Sparkle or fresh DMG), confirm it **pulls** the library from Production. (Pre-req: mini signed into the same `devzhk@gmail.com` as Mac A — verify first; a different Apple ID is a separate, non-code fix.)

---

## Task 4: Correct the Sync-Runbook environment documentation

**Files:**
- Modify: `Docs/Sync-Runbook.md` (the uncommitted callout + §2.5)

- [ ] **Step 1:** Replace the "environment is chosen by the build's provisioning profile" claim with: the environment is selected by `com.apple.developer.icloud-container-environment` in the **signed entitlements**; release (DMG) builds inject `Production` via `build-app.sh`; `dev-launch.sh` (keyless base entitlements) → Development; profile value alone is not authoritative for Developer-ID macOS builds.
- [ ] **Step 2:** Note that a Developer-ID build with the key *absent* lands on **Development**, and how to verify: `codesign -d --entitlements :- /Applications/Rubien.app | grep icloud-container-environment`.
- [ ] **Step 3:** Commit Tasks 1+4 together (or sequence per workflow).

---

## Open questions for review

1. **Injection vs. a checked-in `Rubien.Release.entitlements`.** Build-time `PlistBuddy` injection keeps a single source of truth but hides the `Production` value from static repo grep. Is an explicit second entitlements file (more auditable, risks drift) preferable here?
2. **Gate choice.** Is `FLAVOR = dmg` the right condition, or should injection key off "`CODESIGN_IDENTITY` is a real Developer ID (not adhoc `-`)"? Any path where `build-app.sh` produces a Production-intended bundle with `FLAVOR != dmg`?
3. **Profile sufficiency.** Confirm the existing `Rubien Developer ID Distribution` profile authorizing `Production` is enough and no new profile/regeneration is required once the key is in the signed entitlements.
4. **dev-launch isolation.** Verify nothing in `dev-launch.sh` or its `rubien_require_entitlement` checks breaks, and dev builds genuinely stay on Development.
5. **Reset completeness.** ✅ *Resolved by Codex review:* `tombstone` rows **must** also be deleted (otherwise replayed into Production) — now in Task 2. The cloudd MMCS cache is Apple-managed and keyed per-environment, so it is not a conflict. `DELETE syncState` (nil systemFields → no stale change-tags) + clear `baselineState` + remove `sync-engine-state.bin` + `DELETE tombstone` is the complete reset.
6. **Conflict risk.** Confirm clearing `systemFields` avoids `serverRecordChanged` errors pushing into the fresh Production zone (records carry no stale Development change-tag).
7. **Orphaned Development data.** Any downside to leaving the populated Development `Library` zone in place, or should the plan delete it?
8. **MAS flavor.** ✅ *Resolved:* the `mas` flavor exits unimplemented today (`build-app.sh:17-20`); the `FLAVOR = dmg` gate excludes it regardless, and MAS forces Production when it eventually lands. No action now; revisit when MAS ships.

---

## Resolution log (Codex review, 2026-05-30)

- **FLAW — injection (Q2):** gate widened wrongly (FLAVOR=dmg fires for MODE=debug) + macOS temp-file leak + no cleanup → **fixed** in Task 1 (gate `MODE=release && FLAVOR=dmg && CODESIGN_ENABLED=1`, `mktemp -d`, explicit `rm -rf`).
- **FLAW — reset (Q5):** missing `DELETE FROM tombstone` would replay 3206 Development-acked deletes into Production → **fixed** in Task 2.
- **UNCERTAIN — profile (Q4):** added Step 0 to verify the profile carries `Production` before signing.
- **Correction — dev isolation (Q3):** dev-launch *does* call `build-app.sh debug` with `CODESIGN_ENABLED=0` (skips `sign_bundle`), not "doesn't call it" — Key-facts bullet corrected; line refs fixed (helper 83-90 / app 92-95).
- **UNCERTAIN — root cause (Q1):** not provable from repo code (Apple runtime behavior), but all observed evidence is consistent; Task 2 is itself the empirical confirmation (Production gets the zone once the signed entitlement flips).
- **Design call — injection vs checked-in file:** kept **injection** for single-source-of-truth (drift-free: release = base + 1 key); Codex noted a checked-in `Rubien.release.entitlements` is also valid and avoids temp logic. Reversible if preferred.
