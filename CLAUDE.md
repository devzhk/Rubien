# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Slate is a native macOS reference manager for English-speaking researchers (SwiftUI, macOS 14+). It's a fork of [SwiftLib](https://github.com/NickHood1984/SwiftLib) with the Chinese-academic-database integrations, Zotero translation-server, and Word add-in removed. Ships as a `Slate.app` bundle plus a companion `slate-cli` binary.

**Naming conventions**: internal Swift module / target names are still `SwiftLib` / `SwiftLibCore` / `SwiftLibCLI` (to avoid touching every `import` statement across the fork). User-visible artifacts — SPM products, app bundle, CLI command, `os.Logger` subsystem, bundle ID — are all renamed to `Slate` / `slate-cli`. The product-vs-target distinction means `swift build` produces `.build/debug/Slate` and `.build/debug/slate-cli` while `@testable import SwiftLib` still works in the test targets.

## Commands

Build & run (Swift Package Manager):

```bash
swift build                      # build all targets
swift run Slate                  # run the app from SPM (dev loop)
swift run slate-cli <subcmd>     # run CLI from SPM
swift test                       # run all test targets (requires full Xcode; CommandLineTools alone lacks XCTest)
swift test --filter CitationFormatterTests                       # single test class
swift test --filter SwiftLibCoreTests.CitationFormatterTests/testAPA  # single method
```

Full app bundle / DMG:

```bash
./scripts/build-app.sh           # Debug bundle + DMG → build/
./scripts/build-app.sh release   # Release bundle + DMG
```

Outputs land in `build/`: `Slate.app`, `slate-cli` (embedded under `Slate.app/Contents/Helpers/`), `Slate-{Debug,Release}.dmg`. The script drives `xcodebuild build -scheme SwiftLib` (note: the *scheme* name is still the SPM target name `SwiftLib`, while the resulting binary gets renamed to `Slate` post-build). `xcodebuild` derived data is written to `.xcodebuild/` (not `~/Library/Developer/Xcode/DerivedData/`). The bundle ID defaults to `com.slate.app` — override with `BUNDLE_ID=... ./scripts/build-app.sh`.

### Stale `.build/checkouts` after toolchain swaps

If `swift build` / `swift run Slate` suddenly errors with nonsense like:

- `'grdb.swift': the package manifest at '.build/checkouts/GRDB.swift/Package.swift' cannot be accessed`
- `'grdb.swift': Source files for target CSQLite should be located under 'Sources/CSQLite'`
- `'swift-argument-parser': invalid custom path 'Tools/generate-docc-reference' for target 'generate-docc-reference'`

…the SPM checkout cache is corrupt, usually after switching the active developer dir (`sudo xcode-select -s ...`) between CommandLineTools and Xcode. Fix:

```bash
rm -rf .build .swiftpm
swift package resolve
swift run Slate
```

This nukes the per-package local checkouts and the SwiftPM state, then refetches cleanly. It's hit this repo at least twice — it's not an edit you made, it's an SPM bug around stale state.

## Architecture

Three Swift targets sit on top of one shared core (`Package.swift`):

- **`SwiftLibCore`** (library) — everything usable without AppKit: GRDB models, migrations, metadata resolvers (CrossRef/arXiv/PubMed/ISBN/OpenAlex/Semantic Scholar), BibTeX/RIS importers, CSL/citeproc-js citation engines. This is the only target the CLI and tests depend on, so any logic that needs to be reused by `slate-cli` must live here, not in `SwiftLib`.
- **`SwiftLib`** (app executable → SPM product `Slate`) — SwiftUI views, window management, readers (PDFKit + WKWebView). Depends on `SwiftLibCore`.
- **`SwiftLibCLI`** (executable → SPM product `slate-cli`) — built with swift-argument-parser. Uses `SwiftLibCore` only.

### Data layer — GRDB + single migrator

`Sources/SwiftLibCore/Database/AppDatabase.swift` owns the only `DatabaseMigrator`. All schema changes go through new `registerMigration(...)` blocks — **never** edit an already-shipped migration, because users have live databases. `eraseDatabaseOnSchemaChange` is opt-in via `SWIFTLIB_RESET_DB_ON_SCHEMA_CHANGE=1` in DEBUG builds only; production never wipes the library. Models in `Sources/SwiftLibCore/Models/` are GRDB `Codable` records (`Reference`, `Collection`, `Tag`, `PDFAnnotationRecord`, `WebAnnotationRecord`, `MetadataIntake`, `MetadataVerification`). Full-text search uses SQLite FTS5 over reference fields.

### Metadata resolution pipeline

The resolver (`Sources/SwiftLib/Services/MetadataResolver.swift`, ~470 LOC) is a pure English pipeline with one entrypoint per use case (`resolveImportedPDF`, `resolveManualEntry`, `resolveSeed`, `resolveCandidate`, `retryIntake`, `refreshReference`). Internally it walks this chain:

```
DOI → arXiv → PMID → ISBN → OpenAlex title search → Semantic Scholar abstract → .seedOnly
```

All identifier resolvers live in `SwiftLibCore/Services/MetadataFetcher.swift` and talk directly to public HTTP APIs (CrossRef, arXiv, PubMed/Entrez, Open Library + Google Books for ISBN, OpenAlex, Semantic Scholar). No API keys. `MetadataFetcher.contactEmail` is read from `SwiftLibPreferences.apiContactEmail` at launch and sent in the User-Agent for CrossRef/OpenAlex polite-pool access. `MetadataVerifier` (in `SwiftLibCore/Services/`) applies evidence-based auto-verification rules (`j1DOIExact`, `j2SourceRecordKey`, `t1ThesisSourceKey`, `b1ISBNOrRecordKey`) and downgrades to `.candidate` when multiple results compete.

### Citation engine

Two citation paths coexist in `Sources/SwiftLibCore/Citation/`:

- `CitationFormatter` / `CitationTextFormatting` — fast pure-Swift string formatter for the seven built-in styles (APA/MLA/Chicago/IEEE/Harvard/Vancouver/Nature). Used for hot paths (list views, CLI).
- `CiteprocJSCoreEngine` / `CSLEngine` / `CSLManager` / `CSLParser` — citeproc-js embedded via `JavaScriptCore`, loaded from `Sources/SwiftLibCore/Resources/WordAddin/` (the directory is misnamed but is the shared citation infrastructure: `dist/citeproc-bundle.js`, `CSL/*.csl`, `locales/*.xml`). Uses a warmed thread-safe engine pool to hide cold-start latency. Required for full CSL compliance and 100+ community styles.

When adding a new built-in style, update both the Swift formatter (for speed) and make sure the matching CSL file exists in `Resources/WordAddin/CSL/`.

### Readers and annotations

`PDFReaderView` (PDFKit) and `WebReaderView` (WKWebView) share an annotation vocabulary (highlight / underline / anchored note) but persist to **two different tables** — `PDFAnnotationRecord` and `WebAnnotationRecord`. Web reader content comes from the `ReaderExtraction` pipeline (`ReaderExtractionManager.swift`) which runs Defuddle → Readability → YouTube InnerTube fallback via JS bundled in `Sources/SwiftLib/Resources/`. The rich note editor is a TipTap/ProseMirror WebView whose JS bundle is built from `scripts/note-editor/` and copied into app Resources.

### CLI

`Sources/SwiftLibCLI/SwiftLibCLI.swift` is the single-file argument-parser entry with 14 subcommands (`search`, `list`, `get`, `add`, `update`, `delete`, `move`, `cite`, `import`, `export`, `collections`, `tags`, `annotations`, `styles`). JSON is the default output format — scripts depend on it, so don't change CLI output shape without updating tests in `Tests/SwiftLibCLITests/`.

## Tests

Three test targets mirror the product targets:

- `Tests/SwiftLibCoreTests/` — the bulk of business-logic coverage (citations, metadata, importers, DB).
- `Tests/SwiftLibTests/` — app-level tests that can import SwiftUI code.
- `Tests/SwiftLibCLITests/` — exercises the built `slate-cli` binary at `.build/debug/slate-cli`; keep JSON contracts stable.

Prefer adding coverage to `SwiftLibCoreTests` where possible, since those tests run without AppKit and are the fastest loop.

`swift test` requires the full Xcode toolchain (not just CommandLineTools) because it needs the XCTest framework. Verify with `xcode-select -p` — if it reports `/Library/Developer/CommandLineTools`, switch with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Conventions worth knowing

- Resources are attached with `.copy("Resources")` (not `.process`), so files keep their on-disk layout inside the bundle. JS engines and CSL styles rely on that.
- Debug logging uses `os.Logger` with subsystem `"Slate"` and per-file categories (see `AppDatabase.swift`). The resolver-internal metadata log uses `com.slate.metadata` — filter that in Console.app to see resolver traces.
- The fork is AGPL-sensitive: citeproc-js is AGPL-3.0 and remains bundled at runtime in `Resources/WordAddin/dist/citeproc-bundle.js`. Don't move its code into statically-linked Swift targets without reviewing license implications.
- `MetadataResolution.containsHanCharacters` and related helpers are retained as dead-but-harmless internal utilities — they no longer gate any resolver path, but removing them would cascade through several private helpers in `MetadataResolution.swift`.
