#!/bin/bash
set -euo pipefail

MODE="${1:-debug}"
FLAVOR="${2:-dmg}"

if [ "$MODE" = "release" ]; then
    CONFIGURATION="Release"
else
    CONFIGURATION="Debug"
fi

case "$FLAVOR" in
    dmg)
        : # default; nothing extra
        ;;
    mas)
        echo "✗ MAS flavor not yet implemented (reserved for future App Store builds)" >&2
        echo "  When implemented: --disable-default-traits + Mac App Distribution cert + Transporter upload." >&2
        exit 64
        ;;
    *)
        echo "✗ Unknown flavor '$FLAVOR'. Expected 'dmg' or 'mas'." >&2
        exit 64
        ;;
esac

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

VERSION="$(cat "$PROJECT_DIR/VERSION" | tr -d '[:space:]')"
BUILD_NUMBER="$(cat "$PROJECT_DIR/BUILD.txt" | tr -d '[:space:]')"

if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
    echo "✗ VERSION or BUILD.txt file missing or empty" >&2
    exit 1
fi

echo "▸ Building Rubien $VERSION (build $BUILD_NUMBER)"

HELPERS_DIR="$APP_BUNDLE/Contents/Helpers"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CODESIGN_ENABLED="${CODESIGN_ENABLED:-1}"
# Outer app entitlements: App Group + Sparkle XPC mach-lookup + iCloud/CloudKit
# + file access. NOTE: the App Sandbox is deliberately absent so the app can
# spawn the Claude Code / Codex CLI runtimes for the Assistant sidebar (see
# Docs/superpowers/specs/2026-07-04-assistant-chat-sidebar-design.md §D1);
# CloudKit + the App-Group library are unaffected, and Hardened Runtime
# (--options runtime, below) is retained for notarization. Default points at the
# in-repo plist; override via env var for custom builds. Without this, the outer
# codesign step silently signs with no entitlements, producing a DMG whose
# installed app can't open its library or auto-update.
CODESIGN_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-$PROJECT_DIR/Sources/Rubien/Rubien.entitlements}"
# Embedded rubien-cli gets its own entitlements so it can claim the shared
# App Group and read the same library.sqlite the app uses. Default points at
# the in-repo plist; override via env var for custom builds.
CLI_ENTITLEMENTS="${CLI_ENTITLEMENTS:-$PROJECT_DIR/Sources/RubienCLI/RubienCLI.entitlements}"
# Developer ID Distribution provisioning profile required for the dmg flavor
# when CODESIGN_ENABLED=1. AMFI rejects launch with error -413
# "No matching profile found" otherwise. Generate at developer.apple.com
# under team 9TXK4V3SS8 for App ID com.rubien.app.
PROVISION_PROFILE="${PROVISION_PROFILE:-$HOME/Downloads/Rubien_Developer_ID_Distribution.provisionprofile}"

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
    else
        mkdir -p "$APP_BUNDLE/Contents/MacOS"
        mkdir -p "$APP_BUNDLE/Contents/Resources"
        cp "$PRODUCTS_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

        for bundle in "$PRODUCTS_DIR"/*.bundle; do
            [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        done

        write_info_plist
    fi

    stamp_info_plist_version
    stamp_sparkle_info_plist
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
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
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

stamp_info_plist_version() {
    local plist="$APP_BUNDLE/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
    echo "   ✓ Stamped Info.plist: $VERSION ($BUILD_NUMBER)"
}

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

    local target="${APPCAST_TARGET:-production}"
    local feed_url
    case "$target" in
        production) feed_url="https://devzhk.github.io/Rubien/appcast.xml" ;;
        staging)    feed_url="https://devzhk.github.io/Rubien/staging-appcast.xml" ;;
        *) echo "✗ APPCAST_TARGET must be production or staging (got: $target)" >&2; exit 64 ;;
    esac

    /usr/bin/plutil -replace SUFeedURL -string                       "$feed_url"                                   "$plist"
    /usr/bin/plutil -replace SUPublicEDKey -string                   "$pubkey"                                     "$plist"
    /usr/bin/plutil -replace SUEnableAutomaticChecks -bool           YES                                           "$plist"
    # Sparkle still auto-checks on the SUScheduledCheckInterval cadence
    # above, but does NOT silently download + install. When an update is
    # found the user sees the standard "Update Available" dialog (release
    # notes + Install / Skip / Remind) and nothing lands without their
    # click. Easier to bail on a bad release during alpha; users who want
    # silent updates can flip this in UserDefaults or via a future
    # Settings toggle.
    /usr/bin/plutil -replace SUAutomaticallyUpdate -bool             NO                                            "$plist"
    /usr/bin/plutil -replace SUScheduledCheckInterval -integer       86400                                         "$plist"
    /usr/bin/plutil -replace SUEnableInstallerLauncherService -bool  YES                                           "$plist"

    echo "   ✓ Stamped Sparkle Info.plist keys (feed: $target)"
}

embed_helpers() {
    echo "▸ Embedding CLI..."
    mkdir -p "$HELPERS_DIR"
    cp "$PRODUCTS_DIR/$CLI_NAME" "$HELPERS_DIR/$CLI_NAME"
    chmod 755 "$HELPERS_DIR/$CLI_NAME"
}

embed_sparkle_framework() {
    [ "$FLAVOR" = "dmg" ] || return 0   # MAS flavor: no Sparkle

    local src="$PRODUCTS_DIR/Sparkle.framework"
    if [ ! -d "$src" ]; then
        echo "✗ Sparkle.framework not found at $src — was the Sparkle trait disabled?" >&2
        exit 1
    fi
    echo "▸ Embedding Sparkle.framework..."
    local frameworks_dir="$APP_BUNDLE/Contents/Frameworks"
    mkdir -p "$frameworks_dir"
    # Preserve symlinks: BSD cp -R preserves them by default.
    cp -R "$src" "$frameworks_dir/Sparkle.framework"

    # SwiftPM's executable target ships rpaths for the build tree only
    # (the absolute .xcodebuild/.../PackageFrameworks path and
    # @executable_path/../lib). Once the framework is embedded in
    # Contents/Frameworks, dyld at launch can't find it without the
    # canonical Mac-app rpath. Add it via install_name_tool, idempotently —
    # repeated -add_rpath errors with "file already has rpath" on rebuilds.
    local exe="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    if ! /usr/bin/otool -l "$exe" | grep -q "path @executable_path/../Frameworks "; then
        /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
        echo "   ✓ Added @executable_path/../Frameworks rpath to $APP_NAME"
    fi
}

embed_provisioning_profile() {
    [ "$FLAVOR" = "dmg" ] || return 0
    # dev-launch.sh sets CODESIGN_ENABLED=0 because it does its own signing
    # with the dev provisioning profile. Don't gate dev builds on the
    # Developer ID Distribution profile.
    [ "$CODESIGN_ENABLED" = "0" ] && return 0

    if [ ! -f "$PROVISION_PROFILE" ]; then
        echo "✗ Provisioning profile not found: $PROVISION_PROFILE" >&2
        echo "  Generate at https://developer.apple.com/account/resources/profiles/list" >&2
        echo "  (Profile Type: Developer ID, App ID: com.rubien.app, team 9TXK4V3SS8)" >&2
        echo "  Then set PROVISION_PROFILE=/path/to/file.provisionprofile" >&2
        exit 1
    fi

    echo "▸ Embedding provisioning profile..."
    cp "$PROVISION_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    echo "   ✓ Embedded $(basename "$PROVISION_PROFILE")"
}

sign_bundle() {
    if [ "$CODESIGN_ENABLED" = "0" ]; then
        return
    fi

    echo "▸ Codesigning embedded helpers and app bundle..."
    # Strip resource forks (com.apple.FinderInfo) and xattrs that codesign refuses.
    # `dot_clean -m` clears FinderInfo metadata that `xattr -cr` alone leaves
    # behind on resources copied from network shares or AFP volumes.
    dot_clean -m "$APP_BUNDLE" 2>/dev/null || true
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
    rubien_codesign_binary "$HELPERS_DIR/$CLI_NAME" "$CLI_ENTITLEMENTS"

    # Sign Sparkle.framework components in the order Sparkle's sandboxing
    # docs require, BEFORE the outer app-bundle sign below. Order matters —
    # inner components first, framework wrapper last, outer bundle last of
    # all (handled by the existing if/else below).
    if [ "$FLAVOR" = "dmg" ]; then
        rubien_codesign_sparkle_framework "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi

    # CloudKit environment is selected by the SIGNED entitlement, not the
    # provisioning profile, for Developer-ID (non-App-Store) macOS builds.
    # Rubien.entitlements omits the key (so dev-launch.sh stays on Development),
    # so the release DMG must inject Production here or the installed app
    # silently syncs against the empty Development environment. Gate on
    # MODE=release too: FLAVOR defaults to dmg even for debug builds.
    local sign_entitlements="$CODESIGN_ENTITLEMENTS"
    local prod_ent_dir=""
    if [ "$MODE" = "release" ] && [ "$FLAVOR" = "dmg" ] \
       && [ "$CODESIGN_ENABLED" = "1" ] && [ -n "$CODESIGN_ENTITLEMENTS" ]; then
        prod_ent_dir="$(mktemp -d -t rubien-release-ent)"
        sign_entitlements="$prod_ent_dir/Rubien.release.entitlements"
        cp "$CODESIGN_ENTITLEMENTS" "$sign_entitlements"
        # Add-or-set: idempotent if the base file ever gains the key.
        /usr/libexec/PlistBuddy -c \
            "Add :com.apple.developer.icloud-container-environment string Production" \
            "$sign_entitlements" 2>/dev/null \
          || /usr/libexec/PlistBuddy -c \
            "Set :com.apple.developer.icloud-container-environment Production" \
            "$sign_entitlements"
        echo "   ✓ Pinned CloudKit Production environment into release entitlements"
    fi

    # No --deep on the outer call: the embedded CLI is already signed above
    # and --deep just re-walks the signed tree, which historically chokes on
    # xattrs that get re-added between the inner and outer sign steps.
    if [ -n "$sign_entitlements" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$sign_entitlements" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    else
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --options runtime \
            --timestamp "$APP_BUNDLE"
    fi

    # Clean up temp release entitlements (no EXIT trap: would clobber any
    # script-level trap; sign_bundle returns right after this). Use an if-block,
    # NOT `[ -n … ] && rm`: under `set -e` that one-liner returns 1 when
    # prod_ent_dir is empty (every non-release build), which aborts the whole
    # script here — right after signing, before create_dmg ever runs.
    if [ -n "$prod_ent_dir" ]; then rm -rf "$prod_ent_dir"; fi
}

embed_app_icon() {
    local icon_src="$PROJECT_DIR/icon.png"
    if [ ! -f "$icon_src" ]; then
        echo "▸ Skipping icon embed (no icon.png found)"
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

    local bg="$PROJECT_DIR/Resources/dmg-background.png"
    if [ ! -f "$bg" ]; then
        echo "✗ DMG background not found at $bg" >&2
        echo "  Regenerate via: swift scripts/render-dmg-background.swift" >&2
        exit 1
    fi
    if ! command -v create-dmg >/dev/null 2>&1; then
        echo "✗ create-dmg not on PATH. Install via: brew install create-dmg" >&2
        exit 1
    fi

    # Reuse the icns embed_app_icon already produced for the volume icon
    # (.VolumeIcon.icns inside the DMG — shown when mounted on the desktop).
    local icns="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    local volicon_arg=()
    if [ -f "$icns" ]; then
        volicon_arg=(--volicon "$icns")
    fi

    # create-dmg adds the Applications symlink via --app-drop-link, runs
    # AppleScript to position icons + apply the background, then converts
    # the resulting image to UDZO. Coordinates match render-dmg-background.swift's
    # layout assumptions (Rubien at x=165, Applications at x=495, both at y=200).
    create-dmg \
        --volname "$APP_NAME" \
        --background "$bg" \
        "${volicon_arg[@]}" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 165 200 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 495 200 \
        --no-internet-enable \
        --hdiutil-quiet \
        "$DMG_PATH" \
        "$STAGING_DIR/" >/dev/null

    # Set the .dmg file's own Finder icon (what users see in Safari/Finder
    # downloads BEFORE mounting). create-dmg's --volicon only covers the
    # mounted-volume icon. NSWorkspace.setIcon writes the file's
    # com.apple.ResourceFork + FinderInfo, which Finder honors.
    if [ -f "$icns" ]; then
        /usr/bin/env swift -e "
        import Cocoa
        let img = NSImage(contentsOfFile: \"$icns\")!
        NSWorkspace.shared.setIcon(img, forFile: \"$DMG_PATH\", options: [])
        " 2>/dev/null || echo "   ⚠ failed to stamp .dmg file icon (cosmetic only)"
    fi
}

build_app
build_cli
assemble_app_bundle
embed_app_icon
embed_helpers
embed_sparkle_framework
embed_provisioning_profile
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
