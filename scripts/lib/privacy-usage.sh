#!/bin/bash
# Info.plist usage strings for Assistant dictation, shared by
# scripts/build-app.sh and scripts/preview-app.sh. Source this file; do not
# execute directly.
#
# macOS terminates the process on its first microphone or speech-recognition
# request when the matching Info.plist string is missing, so every bundle that
# can run the Assistant must carry both strings.

# Parallel arrays (macOS bash 3.2 has no associative arrays): key N pairs with
# text N. Both functions below iterate these, so a new entry is stamped and
# checked together.
RUBIEN_PRIVACY_USAGE_KEYS=(
    NSMicrophoneUsageDescription
    NSSpeechRecognitionUsageDescription
)
RUBIEN_PRIVACY_USAGE_TEXTS=(
    "Rubien uses the microphone so you can dictate messages to the Assistant. Speech is transcribed on this Mac."
    "Rubien transcribes your dictation on this Mac to fill in Assistant messages."
)

# Insert or overwrite every usage string.
#   $1  path to Info.plist
rubien_stamp_privacy_usage() {
    local plist="$1"
    local index
    for index in "${!RUBIEN_PRIVACY_USAGE_KEYS[@]}"; do
        /usr/bin/plutil -replace "${RUBIEN_PRIVACY_USAGE_KEYS[$index]}" \
            -string "${RUBIEN_PRIVACY_USAGE_TEXTS[$index]}" "$plist"
    done
}

# Exit non-zero unless every usage string is present and non-empty.
#   $1  path to Info.plist
rubien_require_privacy_usage() {
    local plist="$1"
    local key value
    for key in "${RUBIEN_PRIVACY_USAGE_KEYS[@]}"; do
        value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
        if [ -z "$value" ]; then
            echo "   ✗ $key MISSING in $plist — dictation would terminate the app" >&2
            exit 1
        fi
    done
    echo "   ✓ Microphone and speech-recognition usage strings present"
}
