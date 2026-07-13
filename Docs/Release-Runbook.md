# Release Runbook

Operator runbook for cutting a Rubien release. The design rationale lives in `Docs/superpowers/specs/2026-05-16-mac-auto-updater-design.md`; this document is the recipe.

## Where releases are hosted (two repos)

The source repo `devzhk/Rubien` is **private**, but Sparkle downloads update DMGs **anonymously** — and GitHub release assets on a private repo return **HTTP 404** without auth. So hosting is split:

| Artifact | Repo | Why |
|---|---|---|
| Source, `Docs/appcast.xml`, Pages workflow | private `devzhk/Rubien` | code stays private; Pages is public even for a private repo |
| Sparkle appcast (served) | private `devzhk/Rubien` Pages → `https://devzhk.github.io/Rubien/appcast.xml` | one stable feed URL; never changes |
| DMG assets (`<enclosure url>`) | **public `devzhk/Rubien-releases`** | Sparkle can download anonymously |

**The appcast URL and the app's `SUFeedURL` never change** — only the `<enclosure>` URLs point at the public repo. That is what lets already-installed clients self-heal: repointing the enclosures in `Docs/appcast.xml` fixes every shipped install on its next check, with no new build. `release.sh` targets `$RELEASES_REPO` (default `devzhk/Rubien-releases`) for the DMG and separately runs `git tag` on the private repo for source traceability. Override `RELEASES_REPO` to host under a different account/repo.

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

Prereqs: `gh` authenticated, `CODESIGN_IDENTITY` exported, working tree clean on `main`, EdDSA private key in Keychain, and the `RubienNotary` notarytool profile in the login Keychain (from One-time setup §4 — it persists across releases; you do **not** re-run `store-credentials` each time).

> **Run the release on the interactive host — not from a sandboxed agent (e.g. Codex).** Signing (Developer ID + Sparkle EdDSA keys), notarization (the `RubienNotary` Keychain profile), the `build/` writes, and `git push` all need access a read-only sandbox denies. A sandboxed agent that cannot read the login Keychain will report `RubienNotary` (or the signing identity) as **missing** when it is in fact present — that is a sandbox limitation, not a setup gap. Drive `./scripts/release.sh` from Claude Code running on the host, or hand that step to the maintainer. (Verify a suspected-missing profile the real way: `xcrun notarytool history --keychain-profile RubienNotary` on the host — success means it is there.)

```bash
# 1. Clean state on main
git status
git checkout main && git pull

# 2. Bump the marketing version (if needed) and the build counter
$EDITOR VERSION       # e.g. 0.1.0 → 0.1.1
$EDITOR BUILD.txt     # increment by 1
./scripts/generate-cli-version.sh   # regenerate checked-in GeneratedVersion.swift — CI fails if it drifts

# 3. Set the Developer ID identity in your shell
export CODESIGN_IDENTITY="Developer ID Application: <Your Name> (9TXK4V3SS8)"

# 4. Run release.sh
./scripts/release.sh

# 5. Wait for notarization (5-15 minutes). The script blocks.

# 6. Confirm
# - https://github.com/devzhk/Rubien-releases/releases/latest shows the new DMG (public host)
# - https://devzhk.github.io/Rubien/appcast.xml has the new <item>
# - Within ~24 hours, existing installs see the "Update ready" indicator
```

**You must bump `VERSION` (if the marketing version is changing) and `BUILD.txt` (every release) before running — `release.sh` does not bump them for you. Then run `./scripts/generate-cli-version.sh` and commit the regenerated `Sources/RubienCLI/GeneratedVersion.swift` alongside the bump; the file is checked in and CI's "Verify generated CLI version is in sync" step fails the build if it drifts from `VERSION` + `BUILD.txt`.** `release.sh` is then the single entry point: it calls `scripts/build-app.sh` (which assembles + signs + embeds Sparkle, then builds the DMG), notarizes, signs the appcast item with `sign_update`, prepends the item to `Docs/appcast.xml`, commits + pushes the appcast change, tags the source commit on the private repo, and creates the GitHub release with the DMG on the public `devzhk/Rubien-releases` repo via `gh release create --repo`.

## Artifact-size guardrails

`scripts/build-app.sh release` makes release size deterministic rather than
inheriting user-specific Xcode scheme state:

- Both first-party Mac executables are pinned to exactly `arm64`, matching
  Rubien's Apple Silicon-only release policy, and code coverage is explicitly
  disabled. The copied Sparkle binary framework is thinned to arm64 too, and
  the build rejects any non-arm64 Mach-O anywhere in the assembled app.
- The assembled app and CLI binaries are checked for LLVM coverage sections,
  then stripped with `strip -S -x` before codesigning. Before stripping, their
  UUID-matched dSYMs are preserved in a compressed, UUID-keyed archive under
  `build/dSYMs/Rubien-<version>-<build>-<uuid-hash>.dSYMs.zip`.
  The build fails if the architecture is not exactly `arm64`, a matching dSYM
  is missing, or `__LLVM_COV` / `__llvm_prf_*` is present.
- The DMG uses APFS + ULFO/LZFSE. The custom mounted-volume icon remains by
  design; it is the Rubien disk icon shown after mounting.
- The `.dmg` file itself does not receive a Finder ResourceFork icon. Resource
  forks are not part of GitHub/HTTP file uploads, and `du` counts them even
  though users never download them.

After a release build, these checks should succeed before notarization:

```bash
APP=build/Rubien.app
DSYM_ZIP=$(cat "build/dSYMs/Rubien-$(tr -d '[:space:]' < VERSION)-$(tr -d '[:space:]' < BUILD.txt).latest.txt")

# Expected: every line begins with exactly "arm64" (currently seven Mach-Os:
# the app, CLI, Sparkle framework, Autoupdate, Updater, and two XPC services).
find "$APP/Contents" -type f -print0 | while IFS= read -r -d '' binary; do
  archs=$(lipo -archs "$binary" 2>/dev/null) || continue
  printf '%s\t%s\n' "$archs" "${binary#$APP/Contents/}"
done

# Expected: both negated checks exit zero with no output.
! otool -l "$APP/Contents/MacOS/Rubien" | grep -E '(__LLVM_COV|__llvm_prf_)'
! otool -l "$APP/Contents/Helpers/rubien-cli" | grep -E '(__LLVM_COV|__llvm_prf_)'

# Expected: the manifest lists the same UUIDs as the two binaries above.
dwarfdump --uuid "$APP/Contents/MacOS/Rubien" "$APP/Contents/Helpers/rubien-cli"
unzip -p "$DSYM_ZIP" '*/UUIDs.txt'

# This is the downloadable byte count used by Sparkle/GitHub. Do not use du.
stat -f '%z bytes' build/Rubien-Release.dmg
```

`release.sh` compares the exact byte count with the latest appcast
`<enclosure length="…">` both before notarization and after stapling, and
aborts on growth over 2 MiB.
Rubien 0.3.1, before these guardrails, was 18,978,423 bytes. Feature-driven
growth is acceptable, but audit it first and rerun with
`ALLOW_DMG_SIZE_GROWTH=1`; coverage sections, unstripped symbol tables, missing
or unexpected architecture slices (including dependencies), or new duplicate
payloads are not acceptable overrides.
An ad-hoc-signed 0.3.1 arm64 validation image with the mounted-volume icon
retained measured 12,344,233 bytes before notarization; Developer ID signing,
Finder layout metadata, and stapling can move the final number slightly.
After publishing, copy the printed dSYM zip to durable private storage;
`build/` is ignored local output and is not a backup.

## Linux `rubien-cli` build (automatic)

`release.sh` dispatches the `linux-cli-release.yml` workflow automatically after publishing the Mac release (production target). It builds a static-stdlib x86_64 binary, smoke-tests it from the tarball in a clean container, signs it (ed25519), and uploads the `.tar.gz` + `.tar.gz.sig` to `devzhk/Rubien-releases`. To re-run manually:

```bash
gh workflow run linux-cli-release.yml -f tag=vX.Y.Z
gh run watch
```

**Required CI secrets** (private source repo → Settings → Secrets and variables → Actions):
- `RELEASES_UPLOAD_TOKEN` — fine-grained PAT with **Contents: Read and write** on `devzhk/Rubien-releases`.
- `RUBIEN_CLI_SIGNING_KEY` — the dedicated **ed25519 private key (PEM)** that signs the tarball (public key is compiled into `rubien-cli`; `self-update` verifies it). Generate per Phase F1. **Back it up like the Sparkle key — losing/rotating it breaks `self-update` for shipped binaries.**

## Publish the MCP server to npm (after the release is live)

Gated on **G1**: the just-cut release must be live and its `rubien-cli` must report `build >= 8` (`rubien-cli version`). Only then:

```bash
cd mcp-server && npm publish
```

This runs `prepublishOnly` (build + tests) first, and prompts for npm 2FA. The published package is platform-agnostic; it resolves `rubien-cli` at runtime on the user's host.

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

## Validate `self-update` (after a second signed release exists)

> **Known limitation:** the in-place update swaps the `*.resources` bundles, then atomically `rename(2)`s the binary last, restoring backups on any error. A power loss or `SIGKILL` mid-swap is not transactional across *both* the binary and resources — but it leaves either the prior binary intact (rename hadn't run) or recoverable `*.bak` bundles beside the binary; re-running `self-update` (or re-extracting the tarball) recovers. There is no remote bricking.

On a clean Linux x86_64 box with only the runtime deps + the extracted prior tarball:

```bash
rubien-cli self-update --check     # JSON: {current, latest, updateAvailable}
rubien-cli self-update             # downloads, verifies signature, replaces in place
rubien-cli version                 # reports the new build
```

Negative checks (must REFUSE without replacing the binary):
- **Tamper:** a corrupted tarball with the real `.sig` (or a flipped byte) → exits non-zero with "signature verification FAILED".
- **Rollback:** a higher tag whose signed tarball is an OLDER build → exits non-zero ("build … is not newer").

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

## Split-release failure policy

The Mac DMG + appcast go live immediately when `release.sh` finishes; the Linux `rubien-cli` build is **asynchronous** (CI). A Linux build/upload failure does **not** affect the Mac release — fix it by re-running the workflow (`gh workflow run linux-cli-release.yml -f tag=vX.Y.Z`; uploads are idempotent via `--clobber`). Release notes may note the Linux asset lags the Mac DMG by a few minutes.

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
- `Docs/appcast.xml` — production Sparkle feed (served by GitHub Pages from the private repo; its `<enclosure>` DMG URLs point at the public `devzhk/Rubien-releases` repo).
- `Docs/staging-appcast.xml` — staging feed for end-to-end tests.
- `Docs/index.md` — GitHub Pages landing page.
- `scripts/release.sh` — orchestrator. Reads (does not bump) `VERSION` + `BUILD.txt`, calls `build-app.sh`, notarizes, signs the appcast item, commits + pushes the appcast, tags the source on the private repo, and calls `gh release create --repo "$RELEASES_REPO"` to upload the DMG to the public releases repo.
- `scripts/build-app.sh` — assembles + signs the `.app` bundle and the DMG. Also usable standalone for dev builds.
  - The `embed_sparkle_framework` step inside this script manually copies `Sparkle.framework` into the bundle's `Contents/Frameworks/`. SwiftPM-via-`xcodebuild` does not auto-embed framework dependencies into the assembled bundle, so the script handles it explicitly before code-signing runs.
- `scripts/lib/codesign.sh` — ordered Sparkle component signing. The order matters: `Installer.xpc → Downloader.xpc → Autoupdate → Updater.app → Sparkle.framework`. Never use `--deep`. `Downloader.xpc` needs `--preserve-metadata=entitlements`.
- `scripts/lib/appcast.sh` — renders + prepends an `<item>` block to the chosen appcast.
