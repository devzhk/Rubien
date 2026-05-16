# Release Runbook

Operator runbook for cutting a Rubien release. The design rationale lives in `Docs/superpowers/specs/2026-05-16-mac-auto-updater-design.md`; this document is the recipe.

## One-time setup

1. **Apple Developer Program enrollment.** ($99/yr.)
2. **Developer ID Application certificate.** Xcode → Settings → Accounts → Manage Certificates → + → "Developer ID Application". Export as `.p12` to 1Password.
3. **EdDSA keypair for Sparkle.** Run `<path-to>/.build/.../bin/generate_keys`. Private key auto-saves to the macOS Keychain. Export with `generate_keys -x rubien-sparkle-private.key`, copy to 1Password AND an offline encrypted USB drive, then `rm` the local file. Save the printed base64 public key to `.sparkle-public-key` (gitignored).
4. **notarytool keychain profile.** Generate an app-specific password at appleid.apple.com, then:
   ```bash
   xcrun notarytool store-credentials "RubienNotary" \
       --apple-id you@example.com \
       --team-id 9TXK4V3SS8 \
       --password <app-specific>
   ```
5. **`gh` CLI.** Install once with `brew install gh`, then `gh auth login`. `scripts/release.sh` shells out to `gh release create` for the upload step; without it the script fails late.
6. **GitHub Pages.** repo Settings → Pages.

   **Gotcha — case sensitivity:** the appcast files in this repo live in `Docs/` (capital D), which matches the rest of the project's documentation convention. GitHub Pages' "Deploy from a branch" UI offers a radio for `/docs` (lowercase only), and on GitHub's Linux servers `Docs/` ≠ `docs/`. Pick one of:

   - **Recommended — rename `Docs/` to lowercase `docs/` before enabling Pages.** APFS aliases case on the local filesystem, so the rename has to round-trip through a temp name to actually land in git:
     ```bash
     git mv Docs docs.tmp
     git mv docs.tmp docs
     # Update any internal references that say `Docs/` (search CLAUDE.md, READMEs, etc.)
     git commit -m "Rename Docs/ to docs/ for GitHub Pages compatibility"
     git push
     ```
     Then in repo Settings → Pages → Source: **Deploy from a branch** → Branch: `main` → Folder: `/docs`. Save. Within ~60s, `https://devzhk.github.io/Rubien/appcast.xml` returns the (empty) channel.
   - **Alternative — leave `Docs/` capitalized and use Source: GitHub Actions.** Add a workflow that copies `Docs/appcast.xml`, `Docs/staging-appcast.xml`, and `Docs/index.md` into an artifact and uploads via `actions/deploy-pages`. More moving parts but doesn't touch the existing capital-D convention.

   Pick once, before the first release. Mixing the two later is painful.

## Per-release procedure

Prereqs: `gh` authenticated, `CODESIGN_IDENTITY` exported, working tree clean on `main`, EdDSA private key in Keychain.

```bash
# 1. Clean state on main
git status
git checkout main && git pull

# 2. Bump the marketing version (if needed) and the build counter
$EDITOR VERSION       # e.g. 0.1.0 → 0.1.1
$EDITOR BUILD.txt     # increment by 1

# 3. Set the Developer ID identity in your shell
export CODESIGN_IDENTITY="Developer ID Application: <Your Name> (9TXK4V3SS8)"

# 4. Run release.sh
./scripts/release.sh

# 5. Wait for notarization (5-15 minutes). The script blocks.

# 6. Confirm
# - https://github.com/devzhk/Rubien/releases/latest shows the new DMG
# - https://devzhk.github.io/Rubien/appcast.xml has the new <item>
# - Within ~24 hours, existing installs see the "Update ready" indicator
```

`release.sh` is the single entry point: it bumps `BUILD.txt` if you forgot, calls `scripts/build-app.sh` (which assembles + signs + embeds Sparkle, then builds the DMG), notarizes, signs the appcast item with `sign_update`, prepends the item to `Docs/appcast.xml`, commits + pushes the appcast change, and creates the GitHub release via `gh release create`.

## Staging end-to-end test (before significant updater changes)

1. Build a synthetic 0.1.0 baseline DMG (set `VERSION=0.1.0`, `BUILD.txt=1`).
2. Install on a clean macOS Sequoia VM.
3. Bump `VERSION` to `0.1.1`, `BUILD.txt` to `2`.
4. Run `APPCAST_TARGET=staging ./scripts/release.sh` — this writes to `Docs/staging-appcast.xml`, not the production feed.
5. On the test VM, swap `SUFeedURL` in the installed app's `Info.plist` to point at `staging-appcast.xml`:
   ```bash
   /usr/bin/plutil -replace SUFeedURL -string \
       "https://devzhk.github.io/Rubien/staging-appcast.xml" \
       /Applications/Rubien.app/Contents/Info.plist
   ```
   (Or build a debug variant with that swap baked in.)
6. Wait for the scheduled check, or trigger via Settings → Check Now to exercise the user-initiated path.
7. Observe: toolbar badge appears, menu item enables, Settings shows "Update 0.1.1 ready", click "Install and Relaunch" — app swaps and relaunches.
8. About panel shows 0.1.1.

## If a release goes wrong

```bash
# 1. Stop the bleeding — pull the bad item from the appcast
$EDITOR Docs/appcast.xml             # delete the bad <item>
git commit -am "Pull v0.1.X from appcast (regression: …)"
git push                              # GitHub Pages updates within ~60s

# 2. Flag the GitHub release publicly
gh release edit v0.1.X --prerelease=true
gh release edit v0.1.X --notes-file pulled.md

# 3. Fix forward — bump VERSION + BUILD.txt, fix the bug, normal release
```

For genuine emergencies (data corruption, crash-on-launch), add `<sparkle:criticalUpdate/>` to the fix-forward `<item>` so Sparkle checks more aggressively.

## EdDSA key compromise — recovery

Sparkle 2 accepts a release where **either** the Developer ID cert OR the EdDSA key changes (but not both). So if the EdDSA private key leaks:

1. Generate a new EdDSA keypair with `generate_keys`.
2. Update `.sparkle-public-key` with the new public key.
3. Cut a release signed with the **new EdDSA key** but the **unchanged Developer ID cert**. Existing clients accept it because the cert chain still validates.
4. All subsequent releases use the new key.
5. Back up the new private key (Keychain + 1Password + offline drive).

Avoid losing both anchors simultaneously by storing them in independent failure domains.

## Cert / notarization edge cases

| Situation | Effect on installed apps | Recovery |
|---|---|---|
| Developer ID cert expires | None (signature is timestamped) | Renew via Xcode → Settings → Accounts for next release |
| Developer ID cert revoked by Apple | Existing installs keep running; new installs blocked by Gatekeeper | Appeal to Apple; ship a release with a new cert (single-anchor rotation via the dual-trust path above) |
| Notarization ticket revoked for one release | That release fails Gatekeeper on fresh installs | Pull from appcast; ship a re-notarized fix-forward |
| EdDSA private key lost (not leaked) | Existing installs keep updating from cached state; you cannot publish new updates | Rotate via dual-trust (see EdDSA section); back the new key up immediately |

## File locations

- `VERSION` — marketing version string, becomes `CFBundleShortVersionString`.
- `BUILD.txt` — monotonic build counter, becomes `CFBundleVersion`. Named with the `.txt` extension because APFS is case-insensitive by default and a bare `BUILD` file would alias the `build/` output directory.
- `.sparkle-public-key` — gitignored; base64 EdDSA public key (private key in Keychain + backups).
- `Docs/appcast.xml` — production Sparkle feed (served by GitHub Pages).
- `Docs/staging-appcast.xml` — staging feed for end-to-end tests.
- `Docs/index.md` — GitHub Pages landing page.
- `scripts/release.sh` — orchestrator. Bumps `BUILD.txt`, calls `build-app.sh`, notarizes, signs the appcast item, commits + pushes, calls `gh release create`.
- `scripts/build-app.sh` — assembles + signs the `.app` bundle and the DMG. Also usable standalone for dev builds.
  - The `embed_sparkle_framework` step inside this script manually copies `Sparkle.framework` into the bundle's `Contents/Frameworks/`. SwiftPM-via-`xcodebuild` does not auto-embed framework dependencies into the assembled bundle, so the script handles it explicitly before code-signing runs.
- `scripts/lib/codesign.sh` — ordered Sparkle component signing. The order matters: `Installer.xpc → Downloader.xpc → Autoupdate → Updater.app → Sparkle.framework`. Never use `--deep`. `Downloader.xpc` needs `--preserve-metadata=entitlements`.
- `scripts/lib/appcast.sh` — renders + prepends an `<item>` block to the chosen appcast.
