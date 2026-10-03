#!/bin/bash
# Build an isolated UI preview with the same SDK compatibility mode as packaging.
# Isolation covers the app identity and library, not shared provider installs/auth.
# Includes the CLI helper for Assistant integration. It omits sync entitlements
# and the browser host; use the signed development build for those integrations
# and the release runbook for delivery.
# Usage: scripts/preview-app.sh [--no-launch]
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--no-launch" ) ]]; then
    echo "Usage: $0 [--no-launch]" >&2
    exit 64
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

# --sysroot alone can record the deployment target as the linked SDK. AppKit
# then chooses old layout behavior even though SwiftUI compiled with a new SDK.
SWIFT_FLAGS=(
    --disable-automatic-resolution
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH"
)
swift build --product Rubien "${SWIFT_FLAGS[@]}"
swift build --product rubien-cli "${SWIFT_FLAGS[@]}"
PRODUCTS_DIR="$(swift build --show-bin-path "${SWIFT_FLAGS[@]}")"

python3 "$PROJECT_DIR/scripts/verify-macos-sdk.py" "$PRODUCTS_DIR/Rubien" "$SDK_VERSION"

# Keep the established preview identity and library; never replace the published
# app or choose a library from the first matching database on disk.
PREVIEW_DIR="$PROJECT_DIR/build/ProviderSetupPreview"
APP_BUNDLE="$PREVIEW_DIR/Rubien Setup Preview.app"
mkdir -p "$PREVIEW_DIR/Library"
python3 - "$APP_BUNDLE" <<'PY'
import subprocess
import sys

executable = sys.argv[1] + "/Contents/MacOS/Rubien"
processes = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
if executable in processes.splitlines():
    sys.exit("Quit Rubien Setup Preview before replacing its bundle, then rerun this script.")
PY

STAGE="$(mktemp -d "$PREVIEW_DIR/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/Rubien Setup Preview.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Frameworks"
mkdir -p "$STAGED_APP/Contents/Helpers"
cp "$PRODUCTS_DIR/Rubien" "$STAGED_APP/Contents/MacOS/Rubien"
cp "$PRODUCTS_DIR/rubien-cli" "$STAGED_APP/Contents/Helpers/rubien-cli"
ditto "$PRODUCTS_DIR/Rubien_Rubien.bundle" "$STAGED_APP/Contents/Resources/Rubien_Rubien.bundle"
ditto "$PRODUCTS_DIR/GRDB_GRDB.bundle" "$STAGED_APP/Contents/Resources/GRDB_GRDB.bundle"
ditto "$PRODUCTS_DIR/Sparkle.framework" "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$STAGED_APP/Contents/MacOS/Rubien"

python3 - "$STAGED_APP" "$PREVIEW_DIR/Library" <<'PY'
import plistlib
import sys
from pathlib import Path

info = {
    "CFBundleDisplayName": "Rubien Setup Preview",
    "CFBundleName": "Rubien Setup Preview",
    "CFBundleIdentifier": "com.rubien.provider-setup-preview",
    "CFBundleExecutable": "Rubien",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "dev",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.4",
    "NSHighResolutionCapable": True,
    "SUEnableAutomaticChecks": False,
    "SUAutomaticallyUpdate": False,
    "LSEnvironment": {"RUBIEN_LIBRARY_ROOT": sys.argv[2]},
}
with (Path(sys.argv[1]) / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump(info, stream)
PY

xattr -cr "$STAGED_APP"
codesign --force --sign - "$STAGED_APP/Contents/Helpers/rubien-cli"
codesign --verify "$STAGED_APP/Contents/Helpers/rubien-cli"
codesign --force --sign - "$STAGED_APP"
codesign --verify "$STAGED_APP"
python3 "$PROJECT_DIR/scripts/verify-macos-sdk.py" "$STAGED_APP/Contents/MacOS/Rubien" "$SDK_VERSION"

# Only this generated preview bundle is replaced. Its sibling library survives.
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"
echo "Preview: $APP_BUNDLE"
if [[ "${1:-}" != "--no-launch" ]]; then
    open --env RUBIEN_LIBRARY_ROOT="$PREVIEW_DIR/Library" "$APP_BUNDLE"
fi
