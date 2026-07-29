#!/bin/bash
set -euo pipefail
#
# Verifies that Rubien's checked-in CloudKit schema is valid for Development
# and that both live environments contain every required type, field
# signature, and grant. Live append-only extras are allowed. CloudKit does not
# expose validate-schema for Production, so the Production check uses the
# authenticated exported schema.
#
# Authentication: save a CloudKit management token in the login Keychain:
#   xcrun cktool save-token --type management --method keychain

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

readonly TEAM_ID="9TXK4V3SS8"
readonly CONTAINER_ID="iCloud.com.rubien.app"
readonly SCHEMA_FILE="$PROJECT_DIR/CloudKit/RubienSchema.ckdb"

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "✗ CloudKit schema file not found: $SCHEMA_FILE" >&2
    exit 66
fi

run_cktool() {
    xcrun cktool "$@"
}

# Emit stable, order-independent records:
#   RecordType|@type
#   RecordType|fieldName|TYPE QUERYABLE SEARCHABLE SORTABLE
#   RecordType|@grant|GRANT ...
#
# CloudKit exports include six system metadata fields on every record type.
# They are platform-owned and intentionally excluded from the comparison.
normalize_schema() {
    local schema_file="$1"
    awk '
        /^[[:space:]]*RECORD TYPE[[:space:]]+/ {
            line = $0
            sub(/^[[:space:]]*RECORD TYPE[[:space:]]+/, "", line)
            sub(/[[:space:]]*\(.*/, "", line)
            record_type = line
            print record_type "|@type"
            next
        }

        record_type != "" && /^[[:space:]]*\);/ {
            record_type = ""
            next
        }

        record_type != "" {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]*,[[:space:]]*$/, "", line)

            if (line == "" || line ~ /^"___/) {
                next
            }
            if (line ~ /^GRANT[[:space:]]+/) {
                print record_type "|@grant|" line
                next
            }

            field_name = line
            sub(/[[:space:]].*/, "", field_name)
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)

            count = split(line, tokens, /[[:space:]]+/)
            signature = tokens[1]
            queryable = searchable = sortable = ""
            for (token_index = 2; token_index <= count; token_index++) {
                if (tokens[token_index] == "QUERYABLE") queryable = " QUERYABLE"
                if (tokens[token_index] == "SEARCHABLE") searchable = " SEARCHABLE"
                if (tokens[token_index] == "SORTABLE") sortable = " SORTABLE"
            }
            print record_type "|" field_name "|" signature queryable searchable sortable
        }
    ' "$schema_file" | LC_ALL=C sort -u
}

TEMP_DIR="$(mktemp -d -t RubienCloudKitSchema)"
trap 'rm -rf "$TEMP_DIR"' EXIT

EXPECTED_SCHEMA="$TEMP_DIR/expected.normalized"
normalize_schema "$SCHEMA_FILE" > "$EXPECTED_SCHEMA"

for environment in development production; do
    echo "▸ Validating checked-in schema against CloudKit ${environment}…"
    if [ "$environment" = "development" ]; then
        if ! run_cktool validate-schema \
            --team-id "$TEAM_ID" \
            --container-id "$CONTAINER_ID" \
            --environment "$environment" \
            --file "$SCHEMA_FILE"
        then
            echo "✗ cktool rejected the checked-in schema for ${environment}." >&2
            echo "  If authentication failed, save a fresh management token with:" >&2
            echo "  xcrun cktool save-token --type management --method keychain" >&2
            exit 1
        fi
    fi

    LIVE_SCHEMA="$TEMP_DIR/${environment}.ckdb"
    LIVE_NORMALIZED="$TEMP_DIR/${environment}.normalized"
    MISSING_SCHEMA="$TEMP_DIR/${environment}.missing"

    if ! run_cktool export-schema \
        --team-id "$TEAM_ID" \
        --container-id "$CONTAINER_ID" \
        --environment "$environment" \
        --output-file "$LIVE_SCHEMA"
    then
        echo "✗ Could not export the live CloudKit ${environment} schema." >&2
        exit 1
    fi

    normalize_schema "$LIVE_SCHEMA" > "$LIVE_NORMALIZED"
    LC_ALL=C comm -23 "$EXPECTED_SCHEMA" "$LIVE_NORMALIZED" > "$MISSING_SCHEMA"

    if [ -s "$MISSING_SCHEMA" ]; then
        echo "✗ CloudKit ${environment} is missing required checked-in schema:" >&2
        sed 's/^/    /' "$MISSING_SCHEMA" >&2
        echo "  Import CloudKit/RubienSchema.ckdb into Development, deploy it," >&2
        echo "  and rerun this validation before releasing." >&2
        exit 1
    fi

    echo "   ✓ CloudKit ${environment} contains every checked-in schema requirement"
done

echo "✓ CloudKit Development and Production match RubienSchema.ckdb"
