#!/bin/bash
# Shared codesign helpers for scripts/build-app.sh and scripts/dev-launch.sh.
# Source this file; do not execute directly.
#
# All functions assume $CODESIGN_IDENTITY is set by the caller.

# Canonical App Group identifier used by both the app and the CLI helper.
# Defined here so grep targets in verification blocks stay in sync with the
# identifier claimed in the entitlements plists.
RUBIEN_APP_GROUP_ID="9TXK4V3SS8.com.rubien.shared"

# Sign a single binary, optionally with entitlements.
#   $1  path to binary
#   $2  (optional) path to entitlements plist
rubien_codesign_binary() {
    local target="$1"
    local entitlements="${2:-}"
    if [ -n "$entitlements" ] && [ -f "$entitlements" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$entitlements" \
            --options runtime \
            --timestamp "$target"
    else
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --options runtime \
            --timestamp "$target"
    fi
}

# Assert that `codesign -d --entitlements -` shows the given grep pattern on
# the target. Exits non-zero with a contextual error if missing.
#   $1  path to signed binary/bundle
#   $2  grep pattern to match in the entitlements blob
#   $3  human-readable label (e.g. "App Group")
#   $4  (optional) extra explanation printed on failure
rubien_require_entitlement() {
    local target="$1"
    local pattern="$2"
    local label="$3"
    local hint="${4:-}"
    if codesign -d --entitlements - "$target" 2>&1 | grep -q "$pattern"; then
        echo "   ✓ $label present on $(basename "$target")"
    else
        echo "   ✗ $label MISSING on $target${hint:+ — $hint}" >&2
        exit 1
    fi
}
