# Developer ID Provisioning + App Group Rename Fix Plan

**Date:** 2026-05-21
**Branch:** `main` (33 commits ahead of origin)
**Goal:** Make the Developer ID-signed Rubien.app launch on a notarized Mac by satisfying AMFI's "matching profile required" rule for managed entitlements (iCloud + App Groups), and fix the unrelated `$(PRODUCT_BUNDLE_IDENTIFIER)` placeholder bug in the Sparkle mach-lookup entitlements.

## Context

Phase 10 dry run on the dev Mac failed at AMFI:
```
amfid: /Applications/Rubien.app/Contents/MacOS/Rubien not valid:
  Error Domain=AppleMobileFileIntegrityError Code=-413
  "No matching profile found"
```

Diagnosis:
1. **No `embedded.provisionprofile` in the bundle.** AMFI requires one for Developer ID-signed binaries claiming managed entitlements (iCloud, App Groups).
2. **App Group never wired to App ID.** The existing dev provisioning profile (`Rubien_Mac_Dev.provisionprofile`) does not authorize `com.apple.security.application-groups`. The dev build "works" only because Apple Development signing without hardened runtime is permissive about unauthorized App Group claims; Developer ID Distribution signing is strict.
3. **Apple's 2026 portal enforces `group.` prefix for new App Group identifiers**, so the identifier we're creating is `group.com.rubien.shared`. The effective entitlement string becomes `9TXK4V3SS8.group.com.rubien.shared` — different from the existing `9TXK4V3SS8.com.rubien.shared` baked into the code and entitlement files. We have to update both, and migrate user data from the old container path to the new one.
4. **`$(PRODUCT_BUNDLE_IDENTIFIER)` placeholders never substituted.** `Sources/Rubien/Rubien.entitlements` declares `<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>` for Sparkle XPC mach-lookup names. Xcode substitutes these at build time; SPM + `codesign --entitlements` does not. The literal `$()` ends up in the embedded entitlements blob, breaking Sparkle's XPC lookup at runtime (silent today because Sparkle XPC is only invoked during an actual update). Fix by hard-coding `com.rubien.app-spks` and `com.rubien.app-spki`.

## Operator prerequisite (out of band)

User registers on developer.apple.com under team `9TXK4V3SS8`:

- ✅ iCloud container `iCloud.com.rubien.app` (already exists)
- ✅ App ID `com.rubien.app` with iCloud capability (already exists)
- ⏳ App Group identifier `group.com.rubien.shared` (creating now)
- ⏳ App Groups capability on the App ID, configured with the new group (next)
- ⏳ Developer ID Distribution provisioning profile linking the App ID + the Developer ID Application cert + the new App Group (next)
- ⏳ Download as `~/Downloads/Rubien_DeveloperID.provisionprofile`

## Code changes (this commit)

### Edit 1 — `Sources/RubienCore/Database/AppDatabase.swift:754`

```diff
-    static let appGroupID = "9TXK4V3SS8.com.rubien.shared"
+    static let appGroupID = "9TXK4V3SS8.group.com.rubien.shared"
```

This is the single Swift constant; `PDFUploadQueueBroadcaster.notifyName` and `LibraryChangeBroadcaster.notifyName` use string interpolation off it, so they update automatically.

### Edit 2 — `Sources/Rubien/Rubien.entitlements:9`

```diff
 <key>com.apple.security.application-groups</key>
 <array>
-    <string>9TXK4V3SS8.com.rubien.shared</string>
+    <string>9TXK4V3SS8.group.com.rubien.shared</string>
 </array>
```

### Edit 3 — `Sources/Rubien/Rubien.entitlements` (mach-lookup placeholder fix)

```diff
 <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
 <array>
-    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
-    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
+    <string>com.rubien.app-spks</string>
+    <string>com.rubien.app-spki</string>
 </array>
```

### Edit 4 — `Sources/RubienCLI/RubienCLI.entitlements:25`

```diff
 <key>com.apple.security.application-groups</key>
 <array>
-    <string>9TXK4V3SS8.com.rubien.shared</string>
+    <string>9TXK4V3SS8.group.com.rubien.shared</string>
 </array>
```

### Edit 5 — `scripts/lib/codesign.sh:10`

```diff
-RUBIEN_APP_GROUP_ID="9TXK4V3SS8.com.rubien.shared"
+RUBIEN_APP_GROUP_ID="9TXK4V3SS8.group.com.rubien.shared"
```

### Edit 6 — `Sources/RubienCore/Database/AppDatabase.swift:903-911` (add migration source)

```diff
 static func defaultLegacyRoots() -> [URL] {
     let home = URL(fileURLWithPath: NSHomeDirectory())
     return [
+        // Old App Group identifier (before group. prefix was enforced
+        // by Apple's developer portal in 2026). Migrate any data parked
+        // at the old path to the new container.
+        home.appendingPathComponent("Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien"),
         // Old sandbox per-app container (before App Group adoption).
         home.appendingPathComponent("Library/Containers/com.rubien.app/Data/Library/Application Support/Rubien"),
         // Old unsandboxed path (SPM dev builds, ad-hoc signed builds).
         home.appendingPathComponent("Library/Application Support/Rubien"),
     ]
 }
```

The existing `migrateLegacyLibraryIfNeeded()` already handles the copy-verify-delete pattern. Adding the new path here is sufficient; ordering matters (legacy App Group container first so it's preferred over Application Support husks).

### Edit 7 — `scripts/build-app.sh` (embed provisioning profile for DMG flavor)

Add a new function `embed_provisioning_profile()` called immediately after `embed_sparkle_framework()` and before `sign_bundle()`. Skipped for MAS flavor (MAS uses a different profile type embedded by the App Store submission process) AND skipped when `CODESIGN_ENABLED=0`, so `scripts/dev-launch.sh` (which calls `build-app.sh debug` with codesigning deferred) keeps working without needing the Developer ID profile during dev.

```bash
PROVISION_PROFILE="${PROVISION_PROFILE:-$HOME/Downloads/Rubien_DeveloperID.provisionprofile}"

embed_provisioning_profile() {
    [ "$FLAVOR" = "dmg" ] || return 0
    # dev-launch.sh sets CODESIGN_ENABLED=0 because it does its own signing.
    # Don't gate dev builds on the Developer ID provisioning profile.
    [ "$CODESIGN_ENABLED" = "0" ] && return 0
    if [ ! -f "$PROVISION_PROFILE" ]; then
        echo "✗ Provisioning profile not found: $PROVISION_PROFILE" >&2
        echo "  Generate at https://developer.apple.com/account/resources/profiles/list" >&2
        echo "  (Profile Type: Developer ID, App ID: com.rubien.app)" >&2
        exit 1
    fi
    echo "▸ Embedding provisioning profile..."
    cp "$PROVISION_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    echo "   ✓ Embedded $(basename "$PROVISION_PROFILE")"
}
```

Main flow update:

```diff
 build_app
 build_cli
 assemble_app_bundle
 embed_app_icon
 embed_helpers
 embed_sparkle_framework
+embed_provisioning_profile
 sign_bundle
 create_dmg
```

### Edit 8 — `Docs/CLI-Reference.md:15` (cosmetic doc update)

```diff
-| Mac, embedded helper (`/Applications/Rubien.app/Contents/Helpers/rubien-cli`) | `~/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien/library.sqlite` |
+| Mac, embedded helper (`/Applications/Rubien.app/Contents/Helpers/rubien-cli`) | `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/library.sqlite` |
```

### Edit 9 — `Docs/superpowers/specs/2026-05-16-mac-auto-updater-design.md:129` (cosmetic)

```diff
-- Shared `9TXK4V3SS8.com.rubien.shared` App Group — library, PDF storage, sync state sidecar all colocated regardless of channel.
+- Shared `9TXK4V3SS8.group.com.rubien.shared` App Group — library, PDF storage, sync state sidecar all colocated regardless of channel.
```

### Edit 10 — `scripts/release.sh` (document new env var)

Extend the env-var contract comment so an operator knows about the new `PROVISION_PROFILE` variable:

```diff
 # Required env (one-time set up via xcrun notarytool store-credentials):
 #   CODESIGN_IDENTITY  — e.g. "Developer ID Application: <Name> (9TXK4V3SS8)"

 # Optional env:
 #   NOTARY_PROFILE      — keychain profile name (default: "RubienNotary")
 #   APPCAST_TARGET      — "production" (default) or "staging"
+#   PROVISION_PROFILE   — path to Developer ID provisioning profile
+#                         (default: ~/Downloads/Rubien_DeveloperID.provisionprofile)
+#                         Required for the DMG flavor when CODESIGN_ENABLED=1.
+#                         Must authorize App Groups + iCloud capabilities on
+#                         com.rubien.app under team 9TXK4V3SS8.
```

## Verification plan

1. **Build:** `CODESIGN_IDENTITY="Developer ID Application: Hongkai Zheng (9TXK4V3SS8)" ./scripts/build-app.sh release dmg`. Expect "Embedded Rubien_DeveloperID.provisionprofile" + clean codesign of all components.

2. **Static checks:**
   - `codesign -d --entitlements - /Applications/Rubien.app` shows `9TXK4V3SS8.group.com.rubien.shared` (not the old name) and `com.rubien.app-spks` / `com.rubien.app-spki` (not the `$()` literals).
   - `ls /Applications/Rubien.app/Contents/embedded.provisionprofile` exists.
   - `xcrun stapler validate` + `spctl --assess` both pass.

3. **Launch test (dev Mac):**
   - Drag DMG-installed `.app` to /Applications, launch from Finder.
   - Expect Gatekeeper acceptance dialog + clean launch (no AMFI rejection).
   - On first launch: migration runs, library copied from `9TXK4V3SS8.com.rubien.shared/Rubien` to `9TXK4V3SS8.group.com.rubien.shared/Rubien`, source dir deleted.
   - Quit, relaunch — confirm second launch finds the migrated library directly (idempotent migration short-circuits at line 931).

4. **Sparkle smoke:** Rubien → Check for Updates. Since we haven't pushed Pages yet, expect a benign network error or "no updates available," not a crash.

## Risks / open questions

- **Dev provisioning profile** (`Rubien_Mac_Dev.provisionprofile`) doesn't authorize App Groups at all (the existing profile dump confirms — no `com.apple.security.application-groups` key in its Entitlements dict). With Apple Development signing + no hardened runtime, claiming the entitlement currently "works" because macOS is permissive; *however*, `AppDatabase.preferredStorageRoot` runs a write-probe at line 826-838 and falls back silently to `~/Library/Application Support/Rubien/` if the App Group container isn't writable. After prod migration (which deletes the source at the legacy App Group path), the dev build under the new App Group ID may end up writing to a fresh-and-empty Application Support dir if the dev profile + signing combo refuses the new container. This is a known, intentional fallback — not a surprise — but flagged here so future-us doesn't chase a phantom "where did my library go" bug. Fix when needed: regenerate `Rubien_Mac_Dev.provisionprofile` after the App ID is updated with App Groups capability.
- **`BUNDLE_ID` override constraint:** `build-app.sh` accepts a `BUNDLE_ID` env override (line 42) that re-patches `Info.plist`'s `CFBundleIdentifier`. The hardcoded mach-lookup strings `com.rubien.app-spks/-spki` (Edit 3) assume the default bundle ID. If anyone ever sets `BUNDLE_ID=com.something.else`, the Sparkle XPC names won't match and updates will silently fail to launch. Acceptable for now (we never override BUNDLE_ID in practice). If the project ever forks, document this constraint at the top of `Rubien.entitlements`.
- **CKSyncEngine state** stored as `sync-engine-state.bin` in the App Group container will move along with the rest of the library via the existing `migrationEntries` whitelist. Verify by reading `migrationEntries` to confirm it includes the sidecar.
- **CloudKit data on Apple's servers** is keyed by container ID (`iCloud.com.rubien.app`), unchanged — so sync resumes seamlessly from where it left off.
- **The legacy App Group dir is deleted after migration** (per `deleteSourceEntries` line 964). The dev build (with appGroupID also updated) will use the new path, so there's no "split data" risk after the migration runs.
- **CLI helper signed with the same updated entitlement** — verified by Edit 4 + the existing codesign flow.

## Out of scope

- Updating the dev provisioning profile to authorize App Groups (strict-mode dev signing).
- Removing the `defaultLegacyRoots()` entry for the old App Group container later (can stay indefinitely; idempotent no-op after first migration).
- Wiring `PROVISION_PROFILE` into `release.sh` env contract (default location works; can be parameterized later if needed).

## Commit message

```
provisioning + App Group fix: rename to group.com.rubien.shared, embed profile, substitute mach-lookup tokens

Three bundled changes needed to make the Developer ID-signed bundle
launch under macOS AMFI:

1. Apple's developer portal in 2026 enforces "group." prefix on new
   App Group identifiers. Rename from 9TXK4V3SS8.com.rubien.shared to
   9TXK4V3SS8.group.com.rubien.shared across the Swift constant, both
   entitlements files, and the codesign helper. Add a migration source
   for the old App Group container so existing libraries move forward
   on first launch.

2. Hardcode literal "com.rubien.app-spks" and "com.rubien.app-spki" in
   the Sparkle mach-lookup entitlements. SPM doesn't substitute the
   $(PRODUCT_BUNDLE_IDENTIFIER) placeholders Xcode normally would, and
   the literal $() ends up in the embedded entitlements blob, breaking
   the Sparkle XPC connection at update time.

3. Add embed_provisioning_profile to build-app.sh, called between
   embed_sparkle_framework and sign_bundle. Required for Developer ID
   Distribution signing — AMFI rejects launch otherwise with
   "No matching profile found" (error -413).

Operator: download Rubien_DeveloperID.provisionprofile from
developer.apple.com (App ID com.rubien.app, capabilities iCloud +
App Groups) to ~/Downloads/ before invoking build-app.sh.
```
