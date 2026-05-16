#!/bin/bash
# scripts/lib/appcast.sh — render a Sparkle <item> block and prepend to
# docs/appcast.xml. Sourced by scripts/release.sh.
#
# Required environment variables:
#   VERSION                 — marketing version (e.g. 0.1.1)
#   BUILD_NUMBER            — monotonic integer
#   DMG_PATH                — local path to the signed+notarized+stapled DMG
#   DMG_URL                 — public URL of the DMG on GitHub Releases
#   ED_SIGNATURE            — base64 sparkle:edSignature from sign_update
#   DMG_SIZE_BYTES          — file size in bytes
#   MIN_SYSTEM_VERSION      — sparkle:minimumSystemVersion (e.g. 15.0)
#   RELEASE_NOTES_TEXT      — plain text release notes (escaped for CDATA)
#   APPCAST_PATH            — path to docs/appcast.xml (or staging-appcast.xml)

rubien_appcast_render_item() {
    local pubdate
    pubdate="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

    cat <<XML
        <item>
            <title>Rubien ${VERSION}</title>
            <description><![CDATA[${RELEASE_NOTES_TEXT}]]></description>
            <pubDate>${pubdate}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
            <enclosure
                url="${DMG_URL}"
                sparkle:edSignature="${ED_SIGNATURE}"
                length="${DMG_SIZE_BYTES}"
                type="application/octet-stream"
            />
        </item>
XML
}

# Prepend the rendered <item> just before </channel> in the given appcast.
# Idempotency: refuses to write if an <item> with the same sparkle:version
# already exists (caller should bump BUILD before re-running).
rubien_appcast_prepend_item() {
    local appcast="$APPCAST_PATH"

    if grep -q "<sparkle:version>${BUILD_NUMBER}</sparkle:version>" "$appcast"; then
        echo "✗ Appcast already has an item with build ${BUILD_NUMBER}; bump BUILD before re-running" >&2
        exit 1
    fi

    local item
    item="$(rubien_appcast_render_item)"

    # Insert the rendered <item> on the line before </channel>.
    /usr/bin/awk -v insert="$item" '
        /<\/channel>/ { print insert }
        { print }
    ' "$appcast" > "$appcast.new"

    mv "$appcast.new" "$appcast"
    /usr/bin/xmllint --noout "$appcast" || { echo "✗ Resulting appcast is not valid XML" >&2; exit 1; }

    echo "   ✓ Prepended <item> for ${VERSION} (build ${BUILD_NUMBER}) to $appcast"
}
