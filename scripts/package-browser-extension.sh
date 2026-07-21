#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="${1:-$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")}"
OUTPUT_DIR="${2:-$PROJECT_DIR/build}"
ARTIFACT_NAME="Rubien-Browser-Extension-${VERSION}.zip"

validate_chrome_version() {
    local value="$1"
    local component
    local has_nonzero=0
    local version_parts=()

    if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
        echo "✗ Chrome extension version must contain one to four dot-separated integers: $value" >&2
        exit 1
    fi

    IFS='.' read -r -a version_parts <<< "$value"
    for component in "${version_parts[@]}"; do
        if [ "${#component}" -gt 1 ] && [ "${component#0}" != "$component" ]; then
            echo "✗ Chrome extension version components cannot have leading zeroes: $value" >&2
            exit 1
        fi
        if (( 10#$component > 65535 )); then
            echo "✗ Chrome extension version components cannot exceed 65535: $value" >&2
            exit 1
        fi
        if (( 10#$component != 0 )); then
            has_nonzero=1
        fi
    done
    if [ "$has_nonzero" -ne 1 ]; then
        echo "✗ Chrome extension version cannot be all zeroes: $value" >&2
        exit 1
    fi
}

validate_chrome_version "$VERSION"

STAGING_ROOT="$(mktemp -d -t RubienBrowserExtension)"
trap 'rm -rf "$STAGING_ROOT"' EXIT

EXTENSION_DIR="$STAGING_ROOT/Rubien-Browser-Extension"
mkdir -p "$EXTENSION_DIR/dist" "$EXTENSION_DIR/icons" "$OUTPUT_DIR"

cp "$PROJECT_DIR/BrowserExtension/manifest.json" "$EXTENSION_DIR/manifest.json"
/usr/bin/plutil -replace version -string "$VERSION" "$EXTENSION_DIR/manifest.json"
cp "$PROJECT_DIR/BrowserExtension/service-worker.js" "$EXTENSION_DIR/service-worker.js"
cp "$PROJECT_DIR/BrowserExtension/popup.html" "$EXTENSION_DIR/popup.html"
cp "$PROJECT_DIR/BrowserExtension/popup.css" "$EXTENSION_DIR/popup.css"
cp "$PROJECT_DIR/BrowserExtension/popup.js" "$EXTENSION_DIR/popup.js"
cp "$PROJECT_DIR/BrowserExtension/README.md" "$EXTENSION_DIR/README.md"
cp "$PROJECT_DIR/LICENSE" "$EXTENSION_DIR/LICENSE"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES" "$EXTENSION_DIR/THIRD_PARTY_NOTICES"
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

/usr/bin/unzip -tq "$OUTPUT_DIR/$ARTIFACT_NAME"
PACKAGED_VERSION="$({
    /usr/bin/unzip -p "$OUTPUT_DIR/$ARTIFACT_NAME" \
        "Rubien-Browser-Extension/manifest.json"
} | /usr/bin/plutil -extract version raw -o - -- -)"
if [ "$PACKAGED_VERSION" != "$VERSION" ]; then
    echo "✗ Packaged extension version mismatch: expected $VERSION, found $PACKAGED_VERSION" >&2
    exit 1
fi

for legal_file in LICENSE THIRD_PARTY_NOTICES; do
    if ! /usr/bin/unzip -p "$OUTPUT_DIR/$ARTIFACT_NAME" \
        "Rubien-Browser-Extension/$legal_file" | grep -q '[^[:space:]]'; then
        echo "✗ Packaged extension is missing $legal_file" >&2
        exit 1
    fi
done

echo "   Browser extension: $OUTPUT_DIR/$ARTIFACT_NAME (manifest $PACKAGED_VERSION)"
