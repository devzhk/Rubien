#!/bin/sh
# Reports an old build until the file named by $RUBIEN_STUB_MARKER exists,
# then a new one — lets the e2e test exercise mid-session recovery of the
# version gate ("update Rubien.app, retry the tool call, no restart").
if [ "$1" = "version" ]; then
  if [ -n "$RUBIEN_STUB_MARKER" ] && [ -f "$RUBIEN_STUB_MARKER" ]; then
    echo '{"version":"9.9.9","build":99}'
  else
    echo '{"version":"0.2.3","build":18}'
  fi
  exit 0
fi
# Any real subcommand (only reachable once the gate passes): empty JSON list.
echo '[]'
