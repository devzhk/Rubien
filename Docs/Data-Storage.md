# Data storage and backups

Rubien keeps the SQLite library, PDFs, metadata artifacts, and sync state under one storage root so the library can be backed up or moved as a unit.

## Storage resolution order

Rubien selects the first available location:

1. `$RUBIEN_LIBRARY_ROOT` exactly as provided.
2. `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/` for a Mac process with the App Group entitlement.
3. `~/Library/Application Support/Rubien/` for an unsigned Mac development build.
4. `$XDG_DATA_HOME/rubien/`, normally `~/.local/share/rubien/`, on Linux.
5. A temporary directory as a last resort.

The active App Group identifier includes `group.`. The older `9TXK4V3SS8.com.rubien.shared` container is a legacy location and is not the current signed-app root.

## Contents

The storage root can contain:

- `library.sqlite`, `library.sqlite-wal`, and `library.sqlite-shm` — references, annotations, properties, views, and sync bookkeeping
- `PDFs/` — imported PDF attachments
- `MetadataArtifacts/` — cached metadata resolver responses
- `sync-engine-state.bin` — CloudKit sync-engine state

Window layout and other Mac app preferences are stored separately in `~/Library/Preferences/com.rubien.app.plist`. Sandboxed apps may place that preferences file under `~/Library/Containers/com.rubien.app/Data/Library/Preferences/`.

## Backups

Back up the entire storage root rather than copying only `library.sqlite`. PDFs, metadata artifacts, and sync state live beside the database. Quit Rubien before making a manual filesystem copy so SQLite's database, WAL, and shared-memory files are consistent.

Uninstalling the app bundle does not delete the library.

## Signed app versus development builds

The signed app and its bundled CLI use the App Group container. Unsigned builds launched with `swift run Rubien` and `.build/debug/rubien-cli` normally use Application Support. They can therefore show different libraries on the same Mac.

To make development builds use the signed app's library, set the override explicitly:

```bash
RUBIEN_LIBRARY_ROOT="$HOME/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien" \
  swift run Rubien

RUBIEN_LIBRARY_ROOT="$HOME/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien" \
  .build/debug/rubien-cli list
```

Use this deliberately: development commands will read and write the same production library as the signed app.

## Finding the running app's database

Several `library.sqlite` files can coexist, including legacy containers and timestamped backups. To inspect the database actually opened by the running signed app, ask the process rather than selecting the first search result:

```bash
lsof -p "$(pgrep -f 'Rubien.app/Contents/MacOS/Rubien')" | grep library.sqlite
```

The CLI is unsigned when run from a development checkout, so it uses Application Support unless `RUBIEN_LIBRARY_ROOT` is set.
