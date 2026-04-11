# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Rubien is a native macOS reference manager for English-speaking researchers (SwiftUI, macOS 14+). It's a fork of [SwiftLib](https://github.com/NickHood1984/SwiftLib) with the Chinese-academic-database integrations, Zotero translation-server, and Word add-in removed. Ships as a `Rubien.app` bundle plus a companion `rubien-cli` binary.

The name is a variant of **Rubick**, the Grand Magus hero from Dota 2 — a sorcerer who copies other heroes' abilities.

## Commands

Build & run (Swift Package Manager):

```bash
swift build                       # build all targets
swift run Rubien                  # run the app from SPM (dev loop)
swift run rubien-cli <subcmd>     # run CLI from SPM
swift test                        # run all test targets (requires full Xcode; CommandLineTools alone lacks XCTest)
swift test --filter CitationFormatterTests                          # single test class
swift test --filter RubienCoreTests.CitationFormatterTests/testAPA  # single method
```

Full app bundle / DMG:

```bash
./scripts/build-app.sh           # Debug bundle + DMG → build/
./scripts/build-app.sh release   # Release bundle + DMG
```

Outputs land in `build/`: `Rubien.app`, `rubien-cli` (embedded under `Rubien.app/Contents/Helpers/`), `Rubien-{Debug,Release}.dmg`. The script drives `xcodebuild build -scheme Rubien`. `xcodebuild` derived data is written to `.xcodebuild/` (not `~/Library/Developer/Xcode/DerivedData/`). The bundle ID defaults to `com.rubien.app` — override with `BUNDLE_ID=... ./scripts/build-app.sh`.

### Stale `.build/checkouts` after toolchain swaps

If `swift build` / `swift run Rubien` suddenly errors with nonsense like:

- `'grdb.swift': the package manifest at '.build/checkouts/GRDB.swift/Package.swift' cannot be accessed`
- `'grdb.swift': Source files for target CSQLite should be located under 'Sources/CSQLite'`
- `'swift-argument-parser': invalid custom path 'Tools/generate-docc-reference' for target 'generate-docc-reference'`

…the SPM checkout cache is corrupt, usually after switching the active developer dir (`sudo xcode-select -s ...`) between CommandLineTools and Xcode. Fix:

```bash
rm -rf .build .swiftpm
swift package resolve
swift run Rubien
```

This nukes the per-package local checkouts and the SwiftPM state, then refetches cleanly. It has hit this repo multiple times — it's an SPM bug around stale state, not something you broke.

## Architecture

Three Swift targets sit on top of one shared core (`Package.swift`):

- **`RubienCore`** (library) — everything usable without AppKit: GRDB models, migrations, metadata resolvers (CrossRef/arXiv/PubMed/ISBN/OpenAlex/Semantic Scholar), BibTeX/RIS importers, CSL/citeproc-js citation engines. This is the only target the CLI and tests depend on, so any logic that needs to be reused by `rubien-cli` must live here, not in `Rubien`.
- **`Rubien`** (app executable) — SwiftUI views, window management, readers (PDFKit + WKWebView). Depends on `RubienCore`.
- **`RubienCLI`** (executable, binary name `rubien-cli`) — built with swift-argument-parser. Uses `RubienCore` only.

### Data layer — GRDB + single migrator

`Sources/RubienCore/Database/AppDatabase.swift` owns the only `DatabaseMigrator`. All schema changes go through new `registerMigration(...)` blocks — **never** edit an already-shipped migration, because users have live databases. `eraseDatabaseOnSchemaChange` is opt-in via `SWIFTLIB_RESET_DB_ON_SCHEMA_CHANGE=1` in DEBUG builds only (env-var name kept from upstream for compatibility); production never wipes the library. Models in `Sources/RubienCore/Models/` are GRDB `Codable` records (`Reference`, `Collection`, `Tag`, `PDFAnnotationRecord`, `WebAnnotationRecord`, `MetadataIntake`, `MetadataVerification`). Full-text search uses SQLite FTS5 over reference fields.

On-disk storage: the app writes its database and PDF attachments under `~/Library/Application Support/Rubien/` (see `AppDatabase.preferredStorageRoot(named:)`).

### Metadata resolution pipeline

The resolver (`Sources/Rubien/Services/MetadataResolver.swift`, ~470 LOC) is a pure English pipeline with one entrypoint per use case (`resolveImportedPDF`, `resolveManualEntry`, `resolveSeed`, `resolveCandidate`, `retryIntake`, `refreshReference`). Internally it walks this chain:

```
DOI → arXiv → PMID → ISBN → OpenAlex title search → Semantic Scholar abstract → .seedOnly
```

All identifier resolvers live in `Sources/RubienCore/Services/MetadataFetcher.swift` and talk directly to public HTTP APIs (CrossRef, arXiv, PubMed/Entrez, Open Library + Google Books for ISBN, OpenAlex, Semantic Scholar). No API keys. `MetadataFetcher.contactEmail` is read from `RubienPreferences.apiContactEmail` at launch and sent in the User-Agent for CrossRef/OpenAlex polite-pool access. `MetadataVerifier` applies evidence-based auto-verification rules (`j1DOIExact`, `j2SourceRecordKey`, `t1ThesisSourceKey`, `b1ISBNOrRecordKey`) and downgrades to `.candidate` when multiple results compete.

Edge case already handled: arXiv DataCite DOIs like `10.48550/arXiv.1706.03762` are detected in `MetadataFetcher.extractIdentifier` and routed to the arXiv resolver instead of CrossRef (which returns 404 for them).

### Citation engine

Two citation paths coexist in `Sources/RubienCore/Citation/`:

- `CitationFormatter` / `CitationTextFormatting` — fast pure-Swift string formatter for the seven built-in styles (APA/MLA/Chicago/IEEE/Harvard/Vancouver/Nature). Used for hot paths (list views, CLI).
- `CiteprocJSCoreEngine` / `CSLEngine` / `CSLManager` / `CSLParser` — citeproc-js embedded via `JavaScriptCore`, loaded from `Sources/RubienCore/Resources/Citeproc/` (`dist/citeproc-bundle.js`, `CSL/*.csl`, `locales/*.xml`). Uses a warmed thread-safe engine pool to hide cold-start latency. Required for full CSL compliance and 100+ community styles.

When adding a new built-in style, update both the Swift formatter (for speed) and make sure the matching CSL file exists in `Resources/Citeproc/CSL/`.

### Readers and annotations

`PDFReaderView` (PDFKit) and `WebReaderView` (WKWebView) share an annotation vocabulary (highlight / underline / anchored note) but persist to **two different tables** — `PDFAnnotationRecord` and `WebAnnotationRecord`. Web reader content comes from the `ReaderExtraction` pipeline (`ReaderExtractionManager.swift`) which runs Defuddle → Readability → YouTube InnerTube fallback via JS bundled in `Sources/Rubien/Resources/` (`ClipperDefuddle.js`, `Readability.js`, `ClipperReader.css`, `ClipperHighlighter.css`). The rich note editor is a TipTap/ProseMirror WebView whose JS bundle is built from `scripts/note-editor/` and copied into `Sources/Rubien/Resources/NoteEditor.html` by `npm run build`.

### CLI

`Sources/RubienCLI/RubienCLI.swift` is the single-file argument-parser entry with 14 subcommands (`search`, `list`, `get`, `add`, `update`, `delete`, `move`, `cite`, `import`, `export`, `collections`, `tags`, `annotations`, `styles`). JSON is the default output format — scripts depend on it, so don't change CLI output shape without updating tests in `Tests/RubienCLITests/`.

## Tests

Three test targets mirror the product targets:

- `Tests/RubienCoreTests/` — the bulk of business-logic coverage (citations, metadata, importers, DB).
- `Tests/RubienTests/` — app-level tests that can import SwiftUI code.
- `Tests/RubienCLITests/` — exercises the built `rubien-cli` binary at `.build/debug/rubien-cli`; keep JSON contracts stable.

Prefer adding coverage to `RubienCoreTests` where possible, since those tests run without AppKit and are the fastest loop.

`swift test` requires the full Xcode toolchain (not just CommandLineTools) because it needs the XCTest framework. Verify with `xcode-select -p` — if it reports `/Library/Developer/CommandLineTools`, switch with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Conventions worth knowing

- `RubienCore/Resources` is attached with `.copy("Resources")` so the `Citeproc/{dist,CSL,locales}/` subdirectory structure is preserved verbatim inside the module bundle. `CiteprocJSCoreEngine` reads them via `Bundle.module.url(forResource:..., subdirectory: "Citeproc/...")`.
- `Rubien/Resources` is attached with `.process("Resources")` so the `en.lproj/Localizable.strings` localization is picked up by SPM.
- Debug logging uses `os.Logger` with subsystem `"Rubien"` and per-file categories (see `AppDatabase.swift`). The resolver-internal metadata log uses `com.rubien.metadata` — filter that in Console.app to see resolver traces.
- The fork is AGPL-sensitive: citeproc-js is AGPL-3.0 and remains bundled at runtime in `Resources/Citeproc/dist/citeproc-bundle.js`. Don't move its code into statically-linked Swift targets without reviewing license implications.
- `MetadataResolution.containsHanCharacters` and related helpers are retained as dead-but-harmless internal utilities — they no longer gate any resolver path, but removing them would cascade through several private helpers in `MetadataResolution.swift`.
- The vendored `citeproc-bundle.js` still sets `globalThis.SwiftLibCiteproc` and has a `// swiftlib-citeproc-entry.js` comment — those are third-party bundle internals that the Swift engine no longer reads. Leave them alone.
