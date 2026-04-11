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
- **CLI** — `rubien-cli` with 14 subcommands: `search`, `list`, `get`, `add`, `update`, `delete`, `move`, `cite`, `import`, `export`, `collections`, `tags`, `annotations`, `styles`. JSON output for scripting.

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

## Project layout

```
Sources/
├── Rubien/                # App target (SwiftUI views, reader windows, resolver)
├── RubienCore/            # Shared library (models, GRDB, citation engine, metadata fetchers)
└── RubienCLI/             # rubien-cli command-line interface
Tests/
├── RubienCoreTests/
├── RubienTests/
└── RubienCLITests/
scripts/
└── build-app.sh           # Builds .app + DMG
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
