# Rubien

A native macOS reference manager for English-speaking researchers. Rubien is a personal fork of [SwiftLib](https://github.com/NickHood1984/SwiftLib) with the Chinese-academic-database integrations, Zotero translation-server, and Word add-in removed, and the metadata pipeline retargeted to international sources (CrossRef, arXiv, PubMed, ISBN, OpenAlex, Semantic Scholar).

The name is a variant of **Rubick**, the Grand Magus from Dota 2 — a sorcerer who copies other heroes' abilities. A fitting metaphor for a reference manager: the keeper of borrowed knowledge.

## Features

- **PDF reader + annotations** — native PDFKit rendering with highlight / underline / anchored notes. Thumbnails, outline, full-text search.
- **Web reader + clipper** — Defuddle + Readability extraction pipeline, same annotation tools as PDFs, YouTube transcript import.
- **Metadata fetching** — direct HTTP to CrossRef, arXiv, PubMed, ISBN, OpenAlex, Semantic Scholar. No API keys. In-memory response cache.
- **Citation engine** — citeproc-js embedded via JavaScriptCore. 100+ CSL styles. APA 7 default, plus IEEE / MLA / Chicago / Harvard / Vancouver / Nature.
- **FTS5 search** — SQLite full-text search across title, authors, journal, abstract, notes, DOI.
- **BibTeX / RIS import & export** — standard parsers, round-trip friendly.
- **iCloud sync** — `CKSyncEngine`-backed two-way sync of references, tags, annotations, custom properties, and views across Macs signed into the same iCloud account. Toggle in Settings → iCloud Sync.
- **CLI** — `rubien-cli` with 15 subcommands: `search`, `list`, `get`, `add`, `update`, `delete`, `cite`, `import`, `export`, `tags`, `properties`, `views`, `annotations`, `styles`, `sync`. JSON output for scripting.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel
- Xcode 15+ for building from source

## Building

```bash
# Run directly via SPM
swift run Rubien                    # the app
swift run rubien-cli list           # the CLI

# Run tests
swift test

# Build a distributable .app bundle + DMG
./scripts/build-app.sh              # Debug
./scripts/build-app.sh release      # Release
```

Build outputs land in `build/`: `Rubien.app` and `Rubien-{Debug,Release}.dmg`.

### Troubleshooting: stale SPM checkouts

If `swift build` / `swift run Rubien` suddenly fails with errors like `'grdb.swift': Source files for target CSQLite should be located under 'Sources/CSQLite'` or `'swift-argument-parser': invalid custom path 'Tools/generate-docc-reference'`, the Swift Package Manager checkout cache is corrupt — usually after switching the active developer toolchain (`sudo xcode-select -s ...`) between CommandLineTools and Xcode. Fix:

```bash
rm -rf .build .swiftpm
swift package resolve
swift run Rubien
```

This nukes the local package checkouts and SwiftPM state, then re-fetches cleanly.

## Data storage

The signed Rubien.app stores all user data in its **App Group container** so the app and the bundled `rubien-cli` share a single library:

```
~/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien/
```

This directory holds:

- `library.sqlite` (+ `-wal`, `-shm`) — references, tags, annotations, custom properties, views, sync bookkeeping
- `PDFs/` — imported PDF attachments
- `MetadataArtifacts/` — cached resolver responses
- `sync-engine-state.bin` — `CKSyncEngine` state sidecar (cursors, server change tags)

> **Back up this directory before any major version upgrade.** This is your library; nothing in `Application Support` or in iCloud's web UI is a substitute. Uninstalling the app bundle does **not** delete it.

Unsandboxed dev builds (`swift run Rubien`, `.build/debug/rubien-cli`) and any signed build whose App Group entitlement isn't honored fall back to `~/Library/Application Support/Rubien/`. The `RUBIEN_LIBRARY_ROOT` env var overrides the path explicitly.

> **Gotcha — two-library split.** The signed app (`./scripts/dev-launch.sh`) and the SPM dev app (`swift run Rubien`) read **two different libraries on the same Mac**. References you add in one won't appear in the other; iCloud sync is bound to the signed-app library only. Same applies to the two CLIs (bundled `Rubien.app/Contents/Helpers/rubien-cli` vs `.build/debug/rubien-cli`).
>
> The signed app and its bundled CLI **already** point at the App Group container — no env var needed. To force the **SPM dev builds** to read the same library, prefix the launch command:
>
> ```bash
> # SPM dev app, reading the signed-app library
> RUBIEN_LIBRARY_ROOT="$HOME/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien" \
>   swift run Rubien
>
> # SPM dev CLI, reading the signed-app library
> RUBIEN_LIBRARY_ROOT="$HOME/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien" \
>   .build/debug/rubien-cli list
> ```
>
> Or `export RUBIEN_LIBRARY_ROOT=...` once per terminal session if you'll be running several commands.

Window layout and other app preferences are stored in `~/Library/Preferences/com.rubien.app.plist` (sandboxed apps put it under `~/Library/Containers/com.rubien.app/Data/Library/Preferences/`).

## Project layout

```
Sources/
├── Rubien/                # App target (SwiftUI views, reader windows, resolver, SyncCoordinator)
├── RubienCore/            # Shared library (models, GRDB, citation engine, metadata fetchers)
├── RubienSync/            # CloudKit mapping layer + CKSyncEngine actor
└── RubienCLI/             # rubien-cli command-line interface
Tests/
├── RubienCoreTests/
├── RubienSyncTests/
├── RubienTests/
└── RubienCLITests/
scripts/
├── build-app.sh           # Builds .app + DMG
└── dev-launch.sh          # Signs + launches with CloudKit entitlements (sync dev loop)
```

## Attributions

This project bundles or derives from:

| Component | License | Use |
|---|---|---|
| [citeproc-js](https://github.com/Juris-M/citeproc-js) | AGPL-3.0 | CSL citation formatting engine, embedded in JavaScriptCore |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | SQLite ORM and reactive queries |
| [Readability.js](https://github.com/mozilla/readability) | Apache-2.0 | Web article extraction |
| [Defuddle](https://github.com/kepano/defuddle) | MIT | Web content cleaning |

citeproc-js is AGPL-3.0 and remains bundled at runtime. If you redistribute Rubien, you must comply with the AGPL's attribution and source-availability requirements for the citeproc-js component.

Upstream: the original SwiftLib by [NickHood](https://github.com/NickHood1984/SwiftLib) included additional AGPL components (Zotero translation-server, translators_CN) which are not part of Rubien.
