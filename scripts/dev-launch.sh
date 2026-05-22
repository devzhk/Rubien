#!/bin/bash
# One-command signed-and-relaunch loop for the sandboxed Rubien.app with
# CloudKit entitlements. For sync testing — everyday dev work that doesn't
# need sync can still use `swift run Rubien`, which is faster but has no
# entitlement (sync stays .unavailable).
#
# What this does:
#   1. Kill any running Rubien.app
#   2. Build via scripts/build-app.sh with signing DISABLED (we do it here)
#   3. Embed the provisioning profile + re-sign WITHOUT hardened runtime
#      (hardened runtime strips com.apple.application-identifier from the
#      DER entitlements blob, which causes cloudd to reject the connection
#      with CKError 8; signing without it preserves the identifier)
#   4. Launch the signed .app via `open`
#
# Configurable via env vars (defaults in [brackets]):
#   CODESIGN_IDENTITY  signing identity to use [Apple Development]
#   PROVISION_PROFILE  path to .provisionprofile [~/Downloads/Rubien_Mac_Dev.provisionprofile]
#   ENTITLEMENTS       path to .entitlements  [Sources/Rubien/Rubien.entitlements]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck source=lib/codesign.sh
source "$SCRIPT_DIR/lib/codesign.sh"

# Foot-gun guard: release.sh requires `export CODESIGN_IDENTITY="Developer
# ID Application: …"`. If that's still set in the shell when dev-launch
# runs, the bundle gets signed with the release identity, and AMFI
# rejects launch with POSIX 163 — the dev provisioning profile we embed
# below can't pair with a Developer ID signature. Override locally
# without touching the caller's shell, so a subsequent release.sh in the
# same session still sees the original value.
if [[ "${CODESIGN_IDENTITY:-}" == Developer\ ID* ]]; then
    echo "⚠️  CODESIGN_IDENTITY=\"$CODESIGN_IDENTITY\" is a release identity;"
    echo "    overriding with 'Apple Development' for this dev-launch."
    CODESIGN_IDENTITY="Apple Development"
fi
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
PROVISION_PROFILE="${PROVISION_PROFILE:-$HOME/Downloads/Rubien_Mac_Dev.provisionprofile}"
ENTITLEMENTS="${ENTITLEMENTS:-$PROJECT_DIR/Sources/Rubien/Rubien.entitlements}"
RUBIEN_CLI_ENTITLEMENTS="${RUBIEN_CLI_ENTITLEMENTS:-$PROJECT_DIR/Sources/RubienCLI/RubienCLI.entitlements}"

APP_BUNDLE="$PROJECT_DIR/build/Rubien.app"

if [ ! -f "$PROVISION_PROFILE" ]; then
    echo "❌ Provisioning profile not found: $PROVISION_PROFILE" >&2
    echo "   Download from https://developer.apple.com/account/resources/profiles/list" >&2
    echo "   or set PROVISION_PROFILE=/path/to/file.provisionprofile" >&2
    exit 1
fi

echo "▸ Stopping any running Rubien.app..."
pkill -f "Rubien.app/Contents/MacOS/Rubien" 2>/dev/null || true
sleep 1

echo "▸ Building (signing deferred to this script)..."
CODESIGN_ENABLED=0 ./scripts/build-app.sh debug

echo "▸ Embedding provisioning profile..."
cp "$PROVISION_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"

echo "▸ Staging + signing (in /tmp to dodge fileprovider xattr)..."
# macOS auto-applies `com.apple.fileprovider.fpfs#P` + `com.apple.FinderInfo`
# xattrs to files under the project tree (CloudKit/iCloud tracking path).
# codesign rejects these as "resource fork, Finder information, or similar
# detritus not allowed". Staging in /tmp avoids the auto-apply and lets us
# strip cleanly. After signing we copy the bundle back to build/ — the
# signature metadata is intrinsic to the bundle, so xattrs later re-added
# to build/Rubien.app don't invalidate it.
STAGE="/tmp/Rubien-sign-$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE/Rubien.app"

xattr -cr "$STAGE/Rubien.app"
cp "$PROVISION_PROFILE" "$STAGE/Rubien.app/Contents/embedded.provisionprofile"
xattr -cr "$STAGE/Rubien.app"

# Sign helpers first, strip again, then sign outer bundle with entitlements.
# The helper needs its own entitlements so it can claim the shared App Group
# and read the same library.sqlite as the app.
if [ -f "$STAGE/Rubien.app/Contents/Helpers/rubien-cli" ]; then
    rubien_codesign_binary \
        "$STAGE/Rubien.app/Contents/Helpers/rubien-cli" \
        "$RUBIEN_CLI_ENTITLEMENTS"
fi
xattr -cr "$STAGE/Rubien.app"
codesign --force --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp=none \
    "$STAGE/Rubien.app"

# Copy signed bundle back to build/
rm -rf "$APP_BUNDLE"
cp -R "$STAGE/Rubien.app" "$APP_BUNDLE"
rm -rf "$STAGE"

echo "▸ Verifying entitlements landed..."
rubien_require_entitlement "$APP_BUNDLE" \
    "com.apple.application-identifier" \
    "app-identifier" \
    "CloudKit will reject connections"
rubien_require_entitlement "$APP_BUNDLE" \
    "$RUBIEN_APP_GROUP_ID" \
    "App Group" \
    "app and CLI will see different DBs"
if [ -f "$APP_BUNDLE/Contents/Helpers/rubien-cli" ]; then
    rubien_require_entitlement "$APP_BUNDLE/Contents/Helpers/rubien-cli" \
        "$RUBIEN_APP_GROUP_ID" \
        "App Group" \
        "rubien-cli will hit unsandboxed DB, not the shared one"
fi

echo "▸ Launching..."
open "$APP_BUNDLE"
sleep 2

PID=$(pgrep -f "Rubien.app/Contents/MacOS/Rubien" | head -1 || true)
if [ -n "$PID" ]; then
    echo "✅ Rubien.app running (PID $PID)"
    echo "   Sandbox DB: $HOME/Library/Containers/com.rubien.app/Data/Library/Application Support/Rubien/"
    echo "   Logs: /usr/bin/log show --predicate 'process == \"Rubien\"' --last 2m --info"
else
    echo "❌ Failed to launch. Check Console.app for crash reports." >&2
    exit 1
fi
