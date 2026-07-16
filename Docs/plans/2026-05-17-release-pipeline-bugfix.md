# Release Pipeline Bugfix Plan (Phase 10 preflight)

**Date:** 2026-05-17
**Branch:** `main` (32 commits ahead of origin, unpushed)
**Goal:** Fix three bugs in the release pipeline that surfaced during Phase 10 preflight, before running the first staging test on a separate Mac mini.

## Context

Following the Mac auto-updater implementation plan (`Docs/plans/2026-05-16-mac-auto-updater.md`), Phases 1–9 are merged onto `main` and Phase 0 operator prerequisites are complete (Developer ID cert installed, `RubienNotary` profile stored, GitHub Pages workflow committed at `04326c3`).

Before running Phase 10's staging dry run (build → notarize → staple → install on a separate Mac mini → exercise the Sparkle update flow against `staging-appcast.xml`), a preflight pass on `scripts/release.sh` + `scripts/build-app.sh` + `scripts/lib/appcast.sh` found three real bugs and one cosmetic comment issue. Two of the bugs are silently masked by Tahoe's case-insensitive APFS; one would actively break the staging test.

This plan fixes all four in a single focused commit.

## Bugs

### Bug 1 (silent on APFS-CI, breaks APFS-CS): path case mismatch

`scripts/release.sh:24-25` resolves the appcast path with a lowercase `docs/`:

```bash
production) APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml" ;;
staging)    APPCAST_PATH="$PROJECT_DIR/docs/staging-appcast.xml" ;;
```

The actual files live at `Docs/appcast.xml` (capital). Tahoe's default APFS is case-insensitive, so the path resolves correctly today, but:

- A user with case-sensitive APFS hits a file-not-found.
- The Pages workflow at `.github/workflows/pages.yml` reads from `Docs/` (capital). GitHub's runners are Linux (case-sensitive), so consistency matters.
- The implementation plan and runbook reference `Docs/`. Mixing cases invites future drift.

### Bug 2 (active, load-bearing for staging): SUFeedURL hardcoded to production

`scripts/build-app.sh:163-184` (`stamp_sparkle_info_plist`) hardcodes:

```bash
/usr/bin/plutil -replace SUFeedURL -string "https://devzhk.github.io/Rubien/appcast.xml" "$plist"
...
echo "   ✓ Stamped Sparkle Info.plist keys (feed: production)"
```

There is no staging branch. A build invoked with `APPCAST_TARGET=staging` will:

- Have its appcast `<item>` correctly appended to `Docs/staging-appcast.xml` (release.sh handles this part).
- But ship a DMG whose `Info.plist` `SUFeedURL` still points at `…/Rubien/appcast.xml` (production).

When that staging DMG runs on the Mac mini and Sparkle polls for updates, it queries the production feed — defeating the entire purpose of staging. The staging test would silently exercise production state.

### Bug 3 (latent, silently masked): `APPCAST_TARGET` not explicitly exported

`scripts/release.sh:22` sets:

```bash
APPCAST_TARGET="${APPCAST_TARGET:-production}"
```

If the user invokes `APPCAST_TARGET=staging ./scripts/release.sh`, the env-var-prefix form auto-exports it for that process, so it reaches the `build-app.sh release dmg` subshell at line 46 and Bug 2's fix would observe it.

But if the user runs `./scripts/release.sh` without the prefix (e.g., relies on a script-internal default or a later edit), the variable is set in release.sh's scope but not exported, so `build-app.sh` sees an empty value and falls back to its default. This is brittle. Make it explicit.

### Bug 4 (cosmetic): `scripts/lib/appcast.sh` comments reference `docs/`

Lines 3 and 14 use lowercase `docs/appcast.xml` in comments only. No runtime effect, but invites confusion.

## Fixes

Single commit, four edits.

### Edit 1 — `scripts/release.sh:24-25`

```diff
-    production) APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml" ;;
-    staging)    APPCAST_PATH="$PROJECT_DIR/docs/staging-appcast.xml" ;;
+    production) APPCAST_PATH="$PROJECT_DIR/Docs/appcast.xml" ;;
+    staging)    APPCAST_PATH="$PROJECT_DIR/Docs/staging-appcast.xml" ;;
```

### Edit 2 — `scripts/release.sh`, near existing `export APPCAST_PATH`

```diff
-export APPCAST_PATH
+export APPCAST_PATH APPCAST_TARGET
```

### Edit 3 — `scripts/build-app.sh:163-184`

```diff
 stamp_sparkle_info_plist() {
     [ "$FLAVOR" = "dmg" ] || return 0   # MAS flavor: no Sparkle, no keys

     local plist="$APP_BUNDLE/Contents/Info.plist"
     local pubkey_file="$PROJECT_DIR/.sparkle-public-key"

     if [ ! -f "$pubkey_file" ]; then
         echo "✗ Missing .sparkle-public-key — generate with Sparkle's generate_keys tool" >&2
         exit 1
     fi
     local pubkey
     pubkey="$(cat "$pubkey_file" | tr -d '[:space:]')"

-    /usr/bin/plutil -replace SUFeedURL -string                       "https://devzhk.github.io/Rubien/appcast.xml" "$plist"
+    local target="${APPCAST_TARGET:-production}"
+    local feed_url
+    case "$target" in
+        production) feed_url="https://devzhk.github.io/Rubien/appcast.xml" ;;
+        staging)    feed_url="https://devzhk.github.io/Rubien/staging-appcast.xml" ;;
+        *) echo "✗ APPCAST_TARGET must be production or staging (got: $target)" >&2; exit 64 ;;
+    esac
+
+    /usr/bin/plutil -replace SUFeedURL -string                       "$feed_url" "$plist"
     /usr/bin/plutil -replace SUPublicEDKey -string                   "$pubkey"                                     "$plist"
     /usr/bin/plutil -replace SUEnableAutomaticChecks -bool           YES                                           "$plist"
     /usr/bin/plutil -replace SUAutomaticallyUpdate -bool             YES                                           "$plist"
     /usr/bin/plutil -replace SUScheduledCheckInterval -integer       86400                                         "$plist"
     /usr/bin/plutil -replace SUEnableInstallerLauncherService -bool  YES                                           "$plist"

-    echo "   ✓ Stamped Sparkle Info.plist keys (feed: production)"
+    echo "   ✓ Stamped Sparkle Info.plist keys (feed: $target)"
 }
```

### Edit 4 — `scripts/lib/appcast.sh:3,14`

```diff
-# docs/appcast.xml. Sourced by scripts/release.sh.
+# Docs/appcast.xml. Sourced by scripts/release.sh.
...
-#   APPCAST_PATH            — path to docs/appcast.xml (or staging-appcast.xml)
+#   APPCAST_PATH            — path to Docs/appcast.xml (or staging-appcast.xml)
```

## Verification

1. **Static checks** — `bash -n scripts/release.sh scripts/build-app.sh scripts/lib/appcast.sh` for syntax.

2. **Lossless behavior check on production** — `APPCAST_TARGET=production ./scripts/release.sh` (dry run, abort before notarytool) should resolve `APPCAST_PATH=$PROJECT_DIR/Docs/appcast.xml` and stamp `SUFeedURL=https://devzhk.github.io/Rubien/appcast.xml`. We expect no observable behavior change vs. today on Tahoe APFS-CI.

3. **Staging path works** — `APPCAST_TARGET=staging ./scripts/build-app.sh release dmg` should produce a DMG whose `/Applications/Rubien.app/Contents/Info.plist` reads:
   ```
   SUFeedURL = https://devzhk.github.io/Rubien/staging-appcast.xml
   ```
   verified via `/usr/bin/plutil -extract SUFeedURL raw build/Rubien.app/Contents/Info.plist`.

4. **No accidental capture** — `grep -rn 'docs/' scripts/` should return zero matches after the fix (the cosmetic Edit 4 finishes this off).

## Risks / Open questions

- **Does `embed_sparkle_framework` or any other build-script function depend on `APPCAST_TARGET`?** Audit confirms no — only `stamp_sparkle_info_plist` reads it. Good.
- **Does the staging URL `https://devzhk.github.io/Rubien/staging-appcast.xml` correspond to the actual filename in the Pages workflow?** Yes — `.github/workflows/pages.yml` copies `Docs/staging-appcast.xml` to `_site/staging-appcast.xml`.
- **Is `Docs/staging-appcast.xml` actually published by GitHub Pages?** Yes — it's in the workflow's three explicit paths.
- **Does Sparkle re-read `SUFeedURL` from `Info.plist` on every launch or cache it?** Sparkle 2 reads it on each `SPUUpdater` initialization. A user who installs a staging build, then re-installs a production build on top, will pick up the production feed on the next launch. No persistence-related gotcha.
- **Will this fix break the existing v0.1.0 build that's already staged in BUILD.txt=1?** No — `VERSION=0.1.0`, `BUILD.txt=1` are inputs, not outputs. The next `./scripts/build-app.sh release` after the fix rebuilds from source.

## Commit message

```
release.sh + build-app.sh: fix path case + thread APPCAST_TARGET through

Three preflight findings before Phase 10 staging test:

1. release.sh referenced docs/ (lowercase) for APPCAST_PATH while the
   files live at Docs/. Silently worked on Tahoe APFS-CI; broken on
   case-sensitive APFS and inconsistent with .github/workflows/pages.yml.

2. build-app.sh's stamp_sparkle_info_plist hardcoded the production
   SUFeedURL. APPCAST_TARGET=staging would correctly write to the
   staging appcast XML but ship a DMG that polls the production feed,
   defeating the purpose of staging.

3. release.sh set APPCAST_TARGET locally without exporting it; only
   the env-var-prefix invocation form happened to work. Made the
   export explicit so any invocation path reaches build-app.sh.

Plus cosmetic: lib/appcast.sh comments updated to match.
```

## Out of scope

- The Pages workflow path filter (already correctly references `Docs/...`).
- Any change to `VERSION`, `BUILD.txt`, `.sparkle-public-key`.
- Any push to origin/main — that decision still belongs to Phase 10 step 30 (cut public release).
