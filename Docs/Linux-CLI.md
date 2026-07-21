# Linux CLI

`rubien-cli` runs on Linux x86_64 and arm64. The SwiftUI app and iCloud sync remain Mac-only. PDF text extraction, page rendering, and metadata extraction use the poppler-glib backend described in [Linux PDF Backend](Linux-PDF-Backend.md).

## Install the prebuilt binary

The published Linux archive targets Ubuntu 22.04 or later on x86_64 with glibc 2.35 or later. Download `rubien-cli-<version>-linux-x86_64.tar.gz` from the [latest release](https://github.com/devzhk/Rubien-releases/releases/latest).

Install the runtime dependencies:

```bash
sudo apt install -y libsqlite3-0 libcurl4 libxml2 libpoppler-glib8 libcairo2 libgdk-pixbuf-2.0-0 libglib2.0-0 ca-certificates
```

Extract the archive somewhere stable:

```bash
mkdir -p ~/.local/rubien-cli
tar -xzf rubien-cli-*-linux-x86_64.tar.gz -C ~/.local/rubien-cli
export RUBIEN_CLI=~/.local/rubien-cli/rubien-cli
```

Keep `rubien-cli` and the accompanying `*.resources` directories together. Citation styles are loaded through `Bundle.module`; installing only the executable breaks the `styles` and `cite` commands.

Keep the CLI current with:

```bash
"$RUBIEN_CLI" self-update
```

The updater downloads the latest signed release and verifies its Ed25519 signature before replacing the executable.

## Build from source

Use Ubuntu 22.04 or another Linux distribution with the Swift 6.3 toolchain. Install the development dependencies:

```bash
sudo apt-get install -y libsqlite3-dev libpoppler-glib-dev libcairo2-dev libgdk-pixbuf-2.0-dev pkg-config
```

Build a release binary:

```bash
swift build --product rubien-cli -c release
```

Install the executable and its resource bundles together:

```bash
sudo install -m 755 .build/release/rubien-cli /usr/local/bin/rubien-cli
sudo cp -r .build/release/*.resources /usr/local/bin/
rubien-cli --help
```

For a user-local installation, copy both the executable and resource directories to a directory on `PATH`, such as `~/bin`.

For local development, build without `-c release` and use `.build/debug/rubien-cli`.

## Library location

Linux stores the library under `$XDG_DATA_HOME/rubien/`, normally `~/.local/share/rubien/`. Set `RUBIEN_LIBRARY_ROOT` to use a different location.

See [Data storage and backups](Data-Storage.md) for the full storage resolution order and [CLI Reference](CLI-Reference.md) for commands and JSON output.
