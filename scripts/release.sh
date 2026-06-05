#!/bin/bash
set -euo pipefail
#
# scripts/release.sh — end-to-end Rubien release pipeline.
# Run from a clean working tree on `main` after editing VERSION and BUILD.txt.
# This script does NOT bump VERSION/BUILD.txt — set them yourself first. BUILD.txt
# must increase every release: Sparkle's "is newer" check AND the MCP server's
# version guard both compare it.
#
# Required env (one-time set up via xcrun notarytool store-credentials):
#   CODESIGN_IDENTITY  — e.g. "Developer ID Application: <Name> (9TXK4V3SS8)"
#
# Optional env:
#   NOTARY_PROFILE      — keychain profile name (default: "RubienNotary")
#   APPCAST_TARGET      — "production" (default) or "staging"
#   PROVISION_PROFILE   — Developer ID Distribution provisioning profile
#                         (default: ~/Downloads/Rubien_Developer_ID_Distribution.provisionprofile).
#                         Required for the DMG flavor. Must authorize App
#                         Groups + iCloud capabilities for App ID
#                         com.rubien.app under team 9TXK4V3SS8. AMFI rejects
#                         launch with error -413 without it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

source "$SCRIPT_DIR/lib/appcast.sh"

NOTARY_PROFILE="${NOTARY_PROFILE:-RubienNotary}"
RELEASES_REPO="${RELEASES_REPO:-devzhk/Rubien-releases}"   # public DMG host (Sparkle downloads anonymously; private-repo assets 404)
APPCAST_TARGET="${APPCAST_TARGET:-production}"
case "$APPCAST_TARGET" in
    production) APPCAST_PATH="$PROJECT_DIR/Docs/appcast.xml" ;;
    staging)    APPCAST_PATH="$PROJECT_DIR/Docs/staging-appcast.xml" ;;
    *) echo "✗ APPCAST_TARGET must be production or staging" >&2; exit 64 ;;
esac
export APPCAST_PATH APPCAST_TARGET

# 1. Clean working tree check
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ Working tree not clean; commit or stash first" >&2
    exit 1
fi
if [ "$APPCAST_TARGET" = "production" ] && [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "✗ Production releases must be on main (currently on $(git rev-parse --abbrev-ref HEAD))" >&2
    exit 1
fi

# 2. Read VERSION and BUILD
VERSION="$(cat VERSION | tr -d '[:space:]')"
BUILD_NUMBER="$(cat BUILD.txt | tr -d '[:space:]')"
# Regenerate the CLI version constant so the built binary reports this release's
# version/build (the MCP version guard compares the build number).
"$PROJECT_DIR/scripts/generate-cli-version.sh"
echo "▸ Releasing Rubien $VERSION (build $BUILD_NUMBER) → $APPCAST_TARGET appcast"

# 3. Build
"$SCRIPT_DIR/build-app.sh" release dmg

DMG_NAME="Rubien-Release.dmg"
DMG_PATH="$PROJECT_DIR/build/$DMG_NAME"
if [ ! -f "$DMG_PATH" ]; then
    echo "✗ Expected DMG not produced at $DMG_PATH" >&2
    exit 1
fi

# 4. Notarize
echo "▸ Submitting $DMG_NAME to notarytool (this can take 5–15 min)…"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json | tee "$PROJECT_DIR/build/notarytool-result.json"

# 5. Staple
echo "▸ Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# 6. Per-component signature integrity (catches any --deep slip, missing
#    Sparkle component, or post-hoc tamper). Each line emits 'valid on disk'
#    + 'satisfies its Designated Requirement' or release.sh fails.
APP="$PROJECT_DIR/build/Rubien.app"
FW="$APP/Contents/Frameworks/Sparkle.framework"
for path in \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/Autoupdate" \
    "$FW/Versions/B/Updater.app" \
    "$FW" \
    "$APP"
do
    codesign --verify --strict --verbose=2 "$path"
done

# 7. Belt-and-suspenders deep verification of the assembled app bundle
codesign --verify --deep --strict --verbose=2 "$APP"

# 8. Gatekeeper sanity check happens inside step 11 (mount DMG, spctl the
#    .app). DMGs themselves are not code-signed by Apple's notarization
#    flow — they get a stapled ticket but no code signature — so any spctl
#    check directly on the .dmg file rejects with "no usable signature".
#    The stapler validate at step 5 already proved the ticket is attached;
#    step 11 below validates what Gatekeeper actually sees when the user
#    opens the .app from the mounted volume.

# 9. EdDSA-sign the DMG
echo "▸ Computing Sparkle EdDSA signature…"
# -perm -111 requires every execute bit (u+g+o) set — matches the SPM
# artifact bundle's installed permissions. Earlier the script used the
# slash form (-perm /111) which is documented portable but does NOT work
# on macOS Tahoe (BSD find regression — returns empty result silently).
SIGN_UPDATE="$(find .build -name 'sign_update' -type f -perm -111 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
    echo "✗ sign_update tool not found in .build/. Run swift build first." >&2
    exit 1
fi
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
# sign_update outputs: sparkle:edSignature="…" length="…"
ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
DMG_SIZE_BYTES="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$DMG_SIZE_BYTES" ]; then
    echo "✗ Failed to parse sign_update output:" >&2
    echo "$SIGN_OUTPUT" >&2
    exit 1
fi

# 10. Verify the EdDSA signature round-trips against the keychain key
#     that produced it. Sparkle 2.9+ `sign_update --verify` only takes
#     <file> <signature> (no public-key arg); it derives the public key
#     from the keychain's stored private key.
#
#     This catches signature corruption but NOT a mismatch between the
#     keychain's private key and the public key baked into the app's
#     Info.plist via .sparkle-public-key. That mismatch would surface as
#     Sparkle rejecting the update on the user's machine. We protect
#     against it by stamping SUPublicEDKey from .sparkle-public-key at
#     build time (see build-app.sh:stamp_sparkle_info_plist) — that file
#     is generated together with the private key by generate_keys, so
#     drift requires deliberate manual edits.
if ! "$SIGN_UPDATE" --verify "$DMG_PATH" "$ED_SIGNATURE" >/dev/null; then
    echo "✗ EdDSA signature verification failed" >&2
    exit 1
fi

# 11. Verify the bundled app inside the DMG passes Gatekeeper from inside
#     the mounted image (catches problems that disappear once the user
#     drags-to-Applications). Read-only mount via hdiutil. We run both
#     codesign --verify (structural integrity) and spctl --assess (the
#     "what Gatekeeper says" check, which must return Notarized Developer
#     ID — anything else means notarization didn't take or the staple is
#     misapplied).
MOUNT_POINT="$(mktemp -d -t RubienDmgVerify)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
trap 'hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/Rubien.app"
spctl --assess --verbose=2 "$MOUNT_POINT/Rubien.app"
hdiutil detach "$MOUNT_POINT" -force >/dev/null
trap - EXIT

# 12. Rename DMG to versioned name and prepare URL
VERSIONED_DMG="Rubien-${VERSION}.dmg"
mv "$DMG_PATH" "$PROJECT_DIR/build/$VERSIONED_DMG"
DMG_PATH="$PROJECT_DIR/build/$VERSIONED_DMG"
# Production publishes this DMG to $RELEASES_REPO (step 16 below). For
# APPCAST_TARGET=staging no asset is uploaded (the gh release is production-
# gated), so for staging this is a placeholder URL — same as before the
# public-repo move, when it pointed at an equally-absent private-repo asset.
DMG_URL="https://github.com/${RELEASES_REPO}/releases/download/v${VERSION}/${VERSIONED_DMG}"
export VERSION BUILD_NUMBER DMG_PATH DMG_URL ED_SIGNATURE DMG_SIZE_BYTES
export MIN_SYSTEM_VERSION="15.0"
export RELEASE_NOTES_TEXT="${RELEASE_NOTES_TEXT:-Rubien ${VERSION} (Beta). See GitHub release notes for details.}"

# 13. Update appcast
rubien_appcast_prepend_item

# 14. Push appcast change first
git add "$APPCAST_PATH" Sources/RubienCLI/GeneratedVersion.swift
git commit -m "Release v${VERSION} (build ${BUILD_NUMBER}): update ${APPCAST_TARGET} appcast"
if [ "$APPCAST_TARGET" = "production" ]; then
    git push origin main
fi

# 15. Tag the source commit on the PRIVATE repo. The gh release below now
#     targets the public releases repo, so without this explicit tag the
#     source would be left untagged for this version (gh release create was
#     previously the only step creating the v$VERSION tag).
if [ "$APPCAST_TARGET" = "production" ]; then
    git tag -a "v${VERSION}" -m "Rubien ${VERSION} (build ${BUILD_NUMBER})"
    git push origin "v${VERSION}"
fi

# 16. Create the GitHub release with the DMG on the PUBLIC releases repo so
#     Sparkle (anonymous) can download it. The appcast itself stays on the
#     private repo's Pages (Docs/appcast.xml -> devzhk.github.io/Rubien/appcast.xml).
if [ "$APPCAST_TARGET" = "production" ]; then
    gh release create "v${VERSION}" "$DMG_PATH" \
        --repo "$RELEASES_REPO" \
        --title "Rubien ${VERSION} — Beta" \
        --notes "$RELEASE_NOTES_TEXT" \
        --latest
fi

# 17. Dispatch the Linux rubien-cli build (async, best-effort). The Mac release
#     above is already LIVE; a Linux build/upload failure does NOT affect Mac.
#     gh defaults to the origin (private source) repo, where the workflow lives.
if [ "$APPCAST_TARGET" = "production" ]; then
    if gh workflow run linux-cli-release.yml -f tag="v${VERSION}"; then
        sleep 3
        RUN_URL="$(gh run list --workflow=linux-cli-release.yml --limit=1 --json url --jq '.[0].url' 2>/dev/null || true)"
        echo "   ↗ Linux CLI build dispatched: ${RUN_URL:-<not yet listed — use: gh run watch>}"
        echo "     If it fails, re-run: gh workflow run linux-cli-release.yml -f tag=v${VERSION}"
    else
        echo "   ⚠ Linux CLI dispatch FAILED (Mac release is still fine)."
        echo "     Run manually: gh workflow run linux-cli-release.yml -f tag=v${VERSION}"
    fi
fi

echo "✓ Release $VERSION complete."
echo "   DMG: $DMG_PATH"
echo "   Appcast: $APPCAST_PATH"
