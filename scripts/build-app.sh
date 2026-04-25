#!/bin/bash
set -euo pipefail

MODE="${1:-debug}"
if [ "$MODE" = "release" ]; then
    CONFIGURATION="Release"
else
    CONFIGURATION="Debug"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck source=lib/codesign.sh
source "$SCRIPT_DIR/lib/codesign.sh"

DERIVED_DATA="$PROJECT_DIR/.xcodebuild"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
OUTPUT_DIR="$PROJECT_DIR/build"
STAGING_DIR="$OUTPUT_DIR/dmg-staging"

APP_NAME="Rubien"
CLI_NAME="rubien-cli"
BUNDLE_ID="${BUNDLE_ID:-com.rubien.app}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-${CONFIGURATION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

HELPERS_DIR="$APP_BUNDLE/Contents/Helpers"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CODESIGN_ENABLED="${CODESIGN_ENABLED:-1}"
CODESIGN_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-}"
# Embedded rubien-cli gets its own entitlements so it can claim the shared
# App Group and read the same library.sqlite the app uses. Default points at
# the in-repo plist; override via env var for custom builds.
CLI_ENTITLEMENTS="${CLI_ENTITLEMENTS:-$PROJECT_DIR/Sources/RubienCLI/RubienCLI.entitlements}"

build_app() {
    echo "▸ Building $APP_NAME app ($CONFIGURATION)..."
    xcodebuild build \
        -scheme "$APP_NAME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet
}

build_cli() {
    echo "▸ Building $CLI_NAME ($CONFIGURATION)..."
    xcodebuild build \
        -scheme "$CLI_NAME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet
}

assemble_app_bundle() {
    echo "▸ Assembling $APP_NAME.app..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$OUTPUT_DIR"

    if [ -d "$PRODUCTS_DIR/$APP_NAME.app" ]; then
        cp -R "$PRODUCTS_DIR/$APP_NAME.app" "$APP_BUNDLE"
        update_info_plist_bundle_id
        return
    fi

    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    cp "$PRODUCTS_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

    for bundle in "$PRODUCTS_DIR"/*.bundle; do
        [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    done

    write_info_plist
}

write_info_plist() {
    cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST
}

update_info_plist_bundle_id() {
    # xcodebuild may ship a default bundle identifier; override with BUNDLE_ID.
    local plist="$APP_BUNDLE/Contents/Info.plist"
    [ -f "$plist" ] || return 0
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$plist"
}

embed_helpers() {
    echo "▸ Embedding CLI..."
    mkdir -p "$HELPERS_DIR"
    cp "$PRODUCTS_DIR/$CLI_NAME" "$HELPERS_DIR/$CLI_NAME"
    chmod 755 "$HELPERS_DIR/$CLI_NAME"
}

sign_bundle() {
    if [ "$CODESIGN_ENABLED" = "0" ]; then
        return
    fi

    echo "▸ Codesigning embedded helpers and app bundle..."
    # Strip xattrs (Finder info, resource forks) that codesign refuses.
    # Downloaded JS bundles and icons often carry these from the toolchain.
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
    # Embedded CLI gets its own entitlements so it joins the shared App Group.
    # Ad-hoc ("-") signing can claim the entitlement structurally but it won't
    # validate at runtime; fine for dev smoke-builds.
    rubien_codesign_binary "$HELPERS_DIR/$CLI_NAME" "$CLI_ENTITLEMENTS"

    # Outer bundle keeps its own path here because --deep + --options runtime
    # are specific to the release flow (dev-launch.sh deliberately avoids
    # --options runtime for cloudd compatibility), so the shared helper
    # doesn't fit.
    if [ -n "$CODESIGN_ENTITLEMENTS" ]; then
        codesign --force --deep --sign "$CODESIGN_IDENTITY" \
            --entitlements "$CODESIGN_ENTITLEMENTS" \
            --timestamp=none --options runtime "$APP_BUNDLE"
    else
        codesign --force --deep --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_BUNDLE"
    fi
}

embed_app_icon() {
    local icon_src="$PROJECT_DIR/图标.png"
    if [ ! -f "$icon_src" ]; then
        echo "▸ Skipping icon embed (no 图标.png found)"
        return
    fi
    echo "▸ Embedding app icon..."
    local iconset
    iconset="$(mktemp -d).iconset"
    mkdir -p "$iconset"
    sips -z 16   16   "$icon_src" --out "$iconset/icon_16x16.png"    >/dev/null
    sips -z 32   32   "$icon_src" --out "$iconset/icon_16x16@2x.png" >/dev/null
    sips -z 32   32   "$icon_src" --out "$iconset/icon_32x32.png"    >/dev/null
    sips -z 64   64   "$icon_src" --out "$iconset/icon_32x32@2x.png" >/dev/null
    sips -z 128  128  "$icon_src" --out "$iconset/icon_128x128.png"       >/dev/null
    sips -z 256  256  "$icon_src" --out "$iconset/icon_128x128@2x.png"    >/dev/null
    sips -z 256  256  "$icon_src" --out "$iconset/icon_256x256.png"       >/dev/null
    sips -z 512  512  "$icon_src" --out "$iconset/icon_256x256@2x.png"    >/dev/null
    sips -z 512  512  "$icon_src" --out "$iconset/icon_512x512.png"       >/dev/null
    sips -z 1024 1024 "$icon_src" --out "$iconset/icon_512x512@2x.png"    >/dev/null
    iconutil -c icns "$iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$iconset"
    if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist"
    else
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_BUNDLE/Contents/Info.plist"
    fi
}

create_dmg() {
    echo "▸ Creating DMG..."
    rm -rf "$STAGING_DIR" "$DMG_PATH"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_BUNDLE" "$STAGING_DIR/"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
}

build_app
build_cli
assemble_app_bundle
embed_app_icon
embed_helpers
sign_bundle
create_dmg

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1 | xargs)
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1 | xargs)

echo ""
echo "✅ Done!  App=${APP_SIZE}  DMG=${DMG_SIZE}"
echo "   App: $APP_BUNDLE"
echo "   DMG: $DMG_PATH"
echo ""
echo "   Run:      open \"$APP_BUNDLE\""
echo "   DMG:      \"$DMG_PATH\""
