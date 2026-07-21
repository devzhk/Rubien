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
BROWSER_HOST_NAME="rubien-browser-host"
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
DSYM_ARCHIVE_DIR="$OUTPUT_DIR/dSYMs"
DSYM_ARCHIVE_PATH=""

# Xcode scheme state is user-specific and can silently leave coverage enabled
# or vary the architecture with the build host. Pin the release settings here
# so shipped binaries are coverage-free and keep the intentional Apple
# Silicon-only contract regardless of a developer machine's scheme.
XCODEBUILD_SETTINGS=()
# macOS still ships Bash 3.2, where `set -u` treats an empty array expansion as
# unset. The guarded `${array[@]+...}` form at each xcodebuild call keeps debug
# builds argument-free while preserving all release settings as separate args.
if [ "$MODE" = "release" ]; then
    XCODEBUILD_SETTINGS=(
        ARCHS=arm64
        ONLY_ACTIVE_ARCH=NO
        CLANG_ENABLE_CODE_COVERAGE=NO
        CLANG_COVERAGE_MAPPING=NO
        ENABLE_CODE_COVERAGE=NO
    )
fi

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CODESIGN_ENABLED="${CODESIGN_ENABLED:-1}"
# Outer app entitlements: App Group + Sparkle XPC mach-lookup + iCloud/CloudKit
# + file access. NOTE: the App Sandbox is deliberately absent so the app can
# spawn the Claude Code / Codex CLI runtimes for the Assistant sidebar (see
# Docs/specs/2026-07-04-assistant-chat-sidebar-design.md §D1);
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
# The browser host has the same storage needs as the CLI: App Group access,
# no App Sandbox, and no restricted app-identifier claims.
BROWSER_HOST_ENTITLEMENTS="${BROWSER_HOST_ENTITLEMENTS:-$CLI_ENTITLEMENTS}"
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
        ${XCODEBUILD_SETTINGS[@]+"${XCODEBUILD_SETTINGS[@]}"} \
        -quiet
}

build_cli() {
    echo "▸ Building $CLI_NAME ($CONFIGURATION)..."
    xcodebuild build \
        -scheme "$CLI_NAME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        ${XCODEBUILD_SETTINGS[@]+"${XCODEBUILD_SETTINGS[@]}"} \
        -quiet
}

build_browser_host() {
    echo "▸ Building $BROWSER_HOST_NAME ($CONFIGURATION)..."
    xcodebuild build \
        -scheme "$BROWSER_HOST_NAME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        ${XCODEBUILD_SETTINGS[@]+"${XCODEBUILD_SETTINGS[@]}"} \
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
    stamp_deep_link_info_plist
    stamp_sparkle_info_plist
    embed_legal_files
}

embed_legal_files() {
    local legal_file
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    for legal_file in LICENSE THIRD_PARTY_NOTICES; do
        if [ ! -s "$PROJECT_DIR/$legal_file" ]; then
            echo "✗ Missing required legal file: $legal_file" >&2
            exit 1
        fi
        cp "$PROJECT_DIR/$legal_file" "$APP_BUNDLE/Contents/Resources/$legal_file"
    done
    echo "   ✓ Embedded license and third-party notices"
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

stamp_deep_link_info_plist() {
    local plist="$APP_BUNDLE/Contents/Info.plist"
    local url_types="[{\"CFBundleTypeRole\":\"Viewer\",\"CFBundleURLName\":\"$BUNDLE_ID\",\"CFBundleURLSchemes\":[\"rubien\"]}]"
    /usr/bin/plutil -replace CFBundleURLTypes -json "$url_types" "$plist" 2>/dev/null \
        || /usr/bin/plutil -insert CFBundleURLTypes -json "$url_types" "$plist"
    echo "   ✓ Registered rubien:// app links"
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
    echo "▸ Embedding CLI and browser helper..."
    mkdir -p "$HELPERS_DIR"
    cp "$PRODUCTS_DIR/$CLI_NAME" "$HELPERS_DIR/$CLI_NAME"
    chmod 755 "$HELPERS_DIR/$CLI_NAME"
    cp "$PRODUCTS_DIR/$BROWSER_HOST_NAME" "$HELPERS_DIR/$BROWSER_HOST_NAME"
    chmod 755 "$HELPERS_DIR/$BROWSER_HOST_NAME"
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
    # grep must consume the full otool stream under pipefail; grep -q can give
    # otool SIGPIPE and make an existing rpath look absent.
    if ! /usr/bin/otool -l "$exe" \
        | grep "path @executable_path/../Frameworks " >/dev/null; then
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

thin_sparkle_for_release() {
    [ "$MODE" = "release" ] || return 0
    [ "$FLAVOR" = "dmg" ] || return 0

    local framework="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    local temp_dir
    temp_dir="$(mktemp -d -t RubienSparkleArm64)"
    local macho_count=0

    echo "▸ Thinning embedded Sparkle components to arm64..."
    while IFS= read -r -d '' candidate; do
        local architectures
        if ! architectures="$(/usr/bin/lipo -archs "$candidate" 2>/dev/null)"; then
            continue
        fi
        macho_count=$((macho_count + 1))

        case " $architectures " in
            *" arm64 "*) ;;
            *)
                rm -rf "$temp_dir"
                echo "✗ Embedded Sparkle binary has no arm64 slice: $candidate" >&2
                echo "  Found: $architectures" >&2
                exit 1
                ;;
        esac

        if [ "$architectures" != "arm64" ]; then
            local permissions thin_output
            permissions="$(stat -f '%Lp' "$candidate")"
            thin_output="$temp_dir/$(basename "$candidate").arm64"
            if ! /usr/bin/lipo "$candidate" -thin arm64 -output "$thin_output" \
                || ! chmod "$permissions" "$thin_output" \
                || ! mv -f "$thin_output" "$candidate"; then
                rm -rf "$temp_dir"
                echo "✗ Failed to thin embedded Sparkle binary: $candidate" >&2
                exit 1
            fi
        fi

        architectures="$(/usr/bin/lipo -archs "$candidate")"
        if [ "$architectures" != "arm64" ]; then
            rm -rf "$temp_dir"
            echo "✗ Embedded Sparkle binary is not Apple Silicon-only: $candidate" >&2
            echo "  Expected: arm64; found: $architectures" >&2
            exit 1
        fi
    done < <(find "$framework" -type f -print0)

    rm -rf "$temp_dir"
    if [ "$macho_count" -eq 0 ]; then
        echo "✗ No Mach-O binaries found in embedded Sparkle.framework" >&2
        exit 1
    fi
    echo "   ✓ Thinned + verified $macho_count Sparkle Mach-O binaries"
}

prepare_release_artifacts() {
    [ "$MODE" = "release" ] || return 0

    echo "▸ Verifying release artifacts and stripping binaries..."
    mkdir -p "$DSYM_ARCHIVE_DIR"

    local all_uuids=""
    local names=("$APP_NAME" "$CLI_NAME" "$BROWSER_HOST_NAME")
    local binaries=(
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
        "$HELPERS_DIR/$CLI_NAME"
        "$HELPERS_DIR/$BROWSER_HOST_NAME"
    )
    local dsyms=(
        "$PRODUCTS_DIR/$APP_NAME.dSYM"
        "$PRODUCTS_DIR/$CLI_NAME.dSYM"
        "$PRODUCTS_DIR/$BROWSER_HOST_NAME.dSYM"
    )
    if [ "${#names[@]}" -ne "${#binaries[@]}" ] \
        || [ "${#names[@]}" -ne "${#dsyms[@]}" ]; then
        echo "✗ Internal release-artifact list mismatch" >&2
        exit 1
    fi

    local index name binary dsym binary_uuids dsym_uuids uuid_record
    for index in "${!names[@]}"; do
        name="${names[$index]}"
        binary="${binaries[$index]}"
        dsym="${dsyms[$index]}"

        local architectures
        architectures="$(/usr/bin/lipo -archs "$binary")"
        if [ "$architectures" != "arm64" ]; then
            echo "✗ Release binary must be Apple Silicon-only: $binary" >&2
            echo "  Expected: arm64; found: $architectures" >&2
            exit 1
        fi

        # strip(1) removes symbols but deliberately leaves LLVM coverage maps
        # and counters. Reject them before signing so a scheme-setting
        # regression cannot silently ship an instrumented release again.
        # Do not use grep -q here: with pipefail, its early exit gives otool a
        # SIGPIPE and can make a real match look like a failed pipeline.
        if /usr/bin/otool -l "$binary" \
            | /usr/bin/grep -E '(__LLVM_COV|__llvm_prf_)' >/dev/null; then
            echo "✗ Coverage instrumentation found in release binary: $binary" >&2
            echo "  Ensure the xcodebuild coverage overrides above remain disabled." >&2
            exit 1
        fi

        if [ ! -d "$dsym" ]; then
            echo "✗ Missing release dSYM: $dsym" >&2
            exit 1
        fi
        binary_uuids="$(dwarfdump --uuid "$binary" | awk '{ print $2, $3 }' | LC_ALL=C sort)"
        dsym_uuids="$(dwarfdump --uuid "$dsym" | awk '{ print $2, $3 }' | LC_ALL=C sort)"
        if [ -z "$binary_uuids" ] || [ "$binary_uuids" != "$dsym_uuids" ]; then
            echo "✗ dSYM UUID mismatch for $name" >&2
            echo "  Binary: ${binary_uuids:-<none>}" >&2
            echo "  dSYM:   ${dsym_uuids:-<none>}" >&2
            exit 1
        fi
        uuid_record="$name"$'\n'"$binary_uuids"
        if [ -n "$all_uuids" ]; then all_uuids+=$'\n'; fi
        all_uuids+="$uuid_record"

        local before_size after_size
        before_size="$(stat -f '%z' "$binary")"
        /usr/bin/strip -S -x "$binary"
        after_size="$(stat -f '%z' "$binary")"
        echo "   ✓ Verified + stripped $name ($architectures): ${before_size} → ${after_size} bytes"
    done

    # Catch universal slices in every bundled dependency, not just binaries we
    # compile ourselves. Sparkle is copied from a binary target and therefore
    # does not inherit ARCHS=arm64 from the xcodebuild invocations above.
    local bundled_macho_count=0 candidate architectures
    while IFS= read -r -d '' candidate; do
        if ! architectures="$(/usr/bin/lipo -archs "$candidate" 2>/dev/null)"; then
            continue
        fi
        bundled_macho_count=$((bundled_macho_count + 1))
        if [ "$architectures" != "arm64" ]; then
            echo "✗ Bundled Mach-O must be Apple Silicon-only: $candidate" >&2
            echo "  Expected: arm64; found: $architectures" >&2
            exit 1
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
    if [ "$bundled_macho_count" -eq 0 ]; then
        echo "✗ No Mach-O binaries found in assembled app" >&2
        exit 1
    fi
    echo "   ✓ Verified all $bundled_macho_count bundled Mach-O binaries are arm64-only"

    local symbol_id existing_uuids
    symbol_id="$(printf '%s' "$all_uuids" | shasum -a 256 | awk '{ print substr($1, 1, 12) }')"
    DSYM_ARCHIVE_PATH="$DSYM_ARCHIVE_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER-$symbol_id.dSYMs.zip"

    if [ -e "$DSYM_ARCHIVE_PATH" ]; then
        if ! existing_uuids="$(unzip -p "$DSYM_ARCHIVE_PATH" '*/UUIDs.txt')" \
            || [ "$existing_uuids" != "$all_uuids" ] \
            || ! unzip -tq "$DSYM_ARCHIVE_PATH" >/dev/null; then
            echo "✗ Existing dSYM archive is invalid or has different UUIDs: $DSYM_ARCHIVE_PATH" >&2
            exit 1
        fi
        echo "   ✓ Preserved existing UUID-matched dSYM archive"
    else
        local archive_temp archive_root
        archive_temp="$(mktemp -d -t RubienDSYMs)"
        archive_root="$archive_temp/$APP_NAME-$VERSION-$BUILD_NUMBER.dSYMs"
        if ! mkdir -p "$archive_root"; then
            rm -rf "$archive_temp"
            echo "✗ Failed to create temporary dSYM archive directory" >&2
            exit 1
        fi
        for index in "${!names[@]}"; do
            if ! cp -R "${dsyms[$index]}" "$archive_root/${names[$index]}.dSYM"; then
                rm -rf "$archive_temp"
                echo "✗ Failed to stage ${names[$index]}.dSYM" >&2
                exit 1
            fi
        done
        if ! printf '%s\n' "$all_uuids" > "$archive_root/UUIDs.txt" \
            || ! ditto -c -k --sequesterRsrc --keepParent "$archive_root" "$DSYM_ARCHIVE_PATH" \
            || ! unzip -tq "$DSYM_ARCHIVE_PATH" >/dev/null; then
            rm -rf "$archive_temp"
            rm -f "$DSYM_ARCHIVE_PATH"
            echo "✗ Failed to create verified dSYM archive" >&2
            exit 1
        fi
        rm -rf "$archive_temp"
        echo "   ✓ Archived dSYMs: $DSYM_ARCHIVE_PATH"
    fi
    printf '%s\n' "$DSYM_ARCHIVE_PATH" \
        > "$DSYM_ARCHIVE_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.latest.txt"
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
    rubien_codesign_binary "$HELPERS_DIR/$BROWSER_HOST_NAME" "$BROWSER_HOST_ENTITLEMENTS"

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
    # AppleScript to position icons + apply the background, then converts the
    # resulting image to the selected compressed format. Coordinates match
    # render-dmg-background.swift's layout assumptions (Rubien at x=165,
    # Applications at x=495, both at y=200).
    # ULFO is smaller than UDZO for Rubien's mixed Mach-O/PNG payload, mounts
    # quickly, and avoids hdiutil's deprecated UDBZ format.
    create-dmg \
        --volname "$APP_NAME" \
        --background "$bg" \
        "${volicon_arg[@]}" \
        --filesystem APFS \
        --format ULFO \
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

    # Do not stamp a custom icon onto the .dmg file itself with
    # NSWorkspace.setIcon. That creates a large ResourceFork xattr which is not
    # included in an HTTP/GitHub asset upload and makes local `du` output
    # overstate the downloadable size. The intentional mounted-volume icon
    # above remains embedded inside the DMG as .VolumeIcon.icns.
}

build_app
build_cli
build_browser_host
assemble_app_bundle
embed_app_icon
embed_helpers
embed_sparkle_framework
embed_provisioning_profile
thin_sparkle_for_release
prepare_release_artifacts
sign_bundle
create_dmg
"$SCRIPT_DIR/package-browser-extension.sh" "$VERSION" "$OUTPUT_DIR"

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1 | xargs)
DMG_SIZE_BYTES=$(stat -f '%z' "$DMG_PATH")
DMG_SIZE=$(awk -v bytes="$DMG_SIZE_BYTES" 'BEGIN { printf "%.1f MiB", bytes / 1048576 }')

echo ""
echo "✅ Done!  App=${APP_SIZE}  DMG=${DMG_SIZE}"
echo "   DMG data fork: ${DMG_SIZE_BYTES} bytes"
echo "   App: $APP_BUNDLE"
echo "   DMG: $DMG_PATH"
echo "   Browser extension: $OUTPUT_DIR/Rubien-Browser-Extension-$VERSION.zip"
if [ "$MODE" = "release" ]; then
    echo "   dSYMs: $DSYM_ARCHIVE_PATH"
fi
echo ""
echo "   Run:      open \"$APP_BUNDLE\""
echo "   DMG:      \"$DMG_PATH\""
