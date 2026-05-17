#!/usr/bin/env bash
# Re-capture HTML for citation-meta test fixtures.
#
# Usage: ./Scripts/refresh-citation-fixtures.sh <fixture-name> <source-url>
#
# Example:
#   ./Scripts/refresh-citation-fixtures.sh openreview-forum \
#     https://openreview.net/forum?id=ABCD
#
# Output:
#   - Saves the full page <head> to Tests/RubienCoreTests/Fixtures/CitationMeta/<fixture-name>.html
#   - Updates the comment header with source URL and capture date
#   - Prints a diff against the previous version

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <fixture-name> <source-url>" >&2
    exit 1
fi

FIXTURE_NAME="$1"
SOURCE_URL="$2"
FIXTURE_DIR="$(cd "$(dirname "$0")"/.. && pwd)/Tests/RubienCoreTests/Fixtures/CitationMeta"
mkdir -p "$FIXTURE_DIR"
FIXTURE_PATH="$FIXTURE_DIR/${FIXTURE_NAME}.html"
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

CAPTURE_DATE="$(date -u +%Y-%m-%d)"
USER_AGENT="Rubien/1.0 (fixture-refresh; mailto:devzhk@gmail.com)"

echo "Fetching $SOURCE_URL ..."
curl -sSL --fail-with-body -A "$USER_AGENT" -o "$TMPFILE" "$SOURCE_URL"

# Prepend a comment header
{
    echo "<!--"
    echo "SOURCE: $SOURCE_URL"
    echo "CAPTURED: $CAPTURE_DATE"
    echo "-->"
    cat "$TMPFILE"
} > "$FIXTURE_PATH.new"

if [[ -f "$FIXTURE_PATH" ]]; then
    echo "Diff against existing fixture:"
    diff -u "$FIXTURE_PATH" "$FIXTURE_PATH.new" || true
fi

mv "$FIXTURE_PATH.new" "$FIXTURE_PATH"
echo "Updated $FIXTURE_PATH"
echo
echo "Next steps:"
echo "  1. Inspect $FIXTURE_PATH manually."
echo "  2. Run: swift test --filter CitationMetaScraperParseTests"
echo "  3. If assertions need updating, edit Tests/RubienCoreTests/CitationMetaScraperParseTests.swift"
