#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="${1:-$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")}"
OUTPUT_DIR="${2:-$PROJECT_DIR/build}"
ARTIFACT_NAME="Rubien-Browser-Extension-${VERSION}.zip"

STAGING_ROOT="$(mktemp -d -t RubienBrowserExtension)"
trap 'rm -rf "$STAGING_ROOT"' EXIT

EXTENSION_DIR="$STAGING_ROOT/Rubien-Browser-Extension"
mkdir -p "$EXTENSION_DIR/dist" "$EXTENSION_DIR/icons" "$OUTPUT_DIR"

cp "$PROJECT_DIR/BrowserExtension/manifest.json" "$EXTENSION_DIR/manifest.json"
cp "$PROJECT_DIR/BrowserExtension/service-worker.js" "$EXTENSION_DIR/service-worker.js"
cp "$PROJECT_DIR/BrowserExtension/popup.html" "$EXTENSION_DIR/popup.html"
cp "$PROJECT_DIR/BrowserExtension/popup.css" "$EXTENSION_DIR/popup.css"
cp "$PROJECT_DIR/BrowserExtension/popup.js" "$EXTENSION_DIR/popup.js"
cp "$PROJECT_DIR/BrowserExtension/README.md" "$EXTENSION_DIR/README.md"
cp "$PROJECT_DIR/BrowserExtension/icons/icon-16.png" "$EXTENSION_DIR/icons/icon-16.png"
cp "$PROJECT_DIR/BrowserExtension/icons/icon-32.png" "$EXTENSION_DIR/icons/icon-32.png"
cp "$PROJECT_DIR/BrowserExtension/icons/icon-48.png" "$EXTENSION_DIR/icons/icon-48.png"
cp "$PROJECT_DIR/BrowserExtension/icons/icon-128.png" "$EXTENSION_DIR/icons/icon-128.png"
cp "$PROJECT_DIR/Sources/Rubien/Resources/ClipperDefuddle.js" \
    "$EXTENSION_DIR/dist/ClipperDefuddle.js"

# Keep generated browser bundles out of the source tree. The archive uses the
# checked-in app resource generated from the same Defuddle entry point.
(
    cd "$STAGING_ROOT"
    COPYFILE_DISABLE=1 /usr/bin/zip -q -r -X \
        "$STAGING_ROOT/$ARTIFACT_NAME" "Rubien-Browser-Extension"
)
mv -f "$STAGING_ROOT/$ARTIFACT_NAME" "$OUTPUT_DIR/$ARTIFACT_NAME"

echo "   Browser extension: $OUTPUT_DIR/$ARTIFACT_NAME"
