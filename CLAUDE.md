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

Four Swift targets sit on top of one shared core (`Package.swift`):

- **`RubienCore`** (library) — everything usable without AppKit: GRDB models, migrations, metadata resolvers (CrossRef/arXiv/PubMed/ISBN/OpenAlex/Semantic Scholar), BibTeX/RIS importers, CSL/citeproc-js citation engines. This is the only target the CLI and tests depend on, so any logic that needs to be reused by `rubien-cli` must live here, not in `Rubien`.
- **`RubienSync`** (library) — CloudKit mapping layer, `CKSyncEngine`-based push/pull. Depends on `RubienCore` and the system `CloudKit` framework. The CLI does **not** link it.
- **`Rubien`** (app executable) — SwiftUI views, window management, readers (PDFKit + WKWebView). Depends on `RubienCore`.
- **`RubienCLI`** (executable, binary name `rubien-cli`) — built with swift-argument-parser. Links `RubienCore` and `RubienSync` (the latter for the `sync status` subcommand, which reads sync bookkeeping tables + the engine-state sidecar file).

### Data layer — GRDB + single migrator

`Sources/RubienCore/Database/AppDatabase.swift` owns the only `DatabaseMigrator`. The app has not shipped, so all schema is defined in a single consolidated `"v1"` migration. Once the app ships, new schema changes go through new `registerMigration(...)` blocks — never edit an already-shipped migration. `eraseDatabaseOnSchemaChange` is opt-in via `SWIFTLIB_RESET_DB_ON_SCHEMA_CHANGE=1` in DEBUG builds only (env-var name kept from upstream for compatibility); production never wipes the library. Models in `Sources/RubienCore/Models/` are GRDB `Codable` records (`Reference`, `Tag`, `PDFAnnotationRecord`, `WebAnnotationRecord`, `MetadataIntake`, `MetadataVerification`). Full-text search uses SQLite FTS5 over reference fields.

**On-disk storage.** `AppDatabase.preferredStorageRoot(named:)` resolves the DB root in this order:

0. **`RUBIEN_LIBRARY_ROOT` env var** — explicit override, used verbatim with `~` expanded (no `Rubien/` suffix appended, unlike entries 1–2). When set, `makeShared()` skips `migrateLegacyLibraryIfNeeded` so an empty override target doesn't silently absorb the legacy library. Production-signed GUI is sandbox-bounded — paths outside its container (e.g. `~/Library/Application Support/Rubien/`) get silently redirected to the per-app sandbox dir; the non-sandboxed `rubien-cli` and SPM dev builds can target anywhere.
1. **App Group shared container** — `~/Library/Group Containers/9TXK4V3SS8.com.rubien.shared/Rubien/`. Used whenever the running process (app or bundled `rubien-cli`) is signed with the `com.apple.security.application-groups` entitlement and the write-probe succeeds. This is the path for the signed, sandboxed app bundle + its embedded helper.
2. **Unsandboxed Application Support** — `~/Library/Application Support/Rubien/`. Used by SPM dev builds (`swift run Rubien`, `.build/debug/rubien-cli`) that don't carry the entitlement, and for any build where the App Group entitlement has been invalidated (cert revoked, provisioning profile lapsed, etc.). The write-probe in `canAccessGroupContainer` is the safety net that catches the "entitlement returns a URL but the container isn't actually reachable" case on macOS.
3. **Temp directory** — last-resort so the app still launches if both above fail.

`pdfStorageURL` (`Rubien/PDFs/`), `metadataArtifactsURL` (`Rubien/MetadataArtifacts/`), and `syncEngineStateURL` (`Rubien/sync-engine-state.bin`) all ride on the same root, so the whole app state moves together when the path changes.

**Legacy library migration.** `migrateLegacyLibraryIfNeeded` runs once inside `makeShared()` before opening the DB. If the resolved destination has no `library.sqlite` yet but a legacy location does (old per-app container at `~/Library/Containers/com.rubien.app/Data/...`, or the unsandboxed path), it (a) WAL-checkpoints the source, (b) copies `library.sqlite` + sidecars (`-wal`/`-shm`, `sync-engine-state.bin`, `PDFs/`, `MetadataArtifacts/`) into a PID-scoped `.migrating-<pid>/` staging dir, (c) atomically promotes the staging dir to the destination (race-safe: if another process beat it, it bails without touching their work), and (d) verifies integrity + deletes the source. Copy-then-delete means an interrupted run always leaves the authoritative library at the source, and the next launch retries automatically. Idempotent: once `destination/library.sqlite` exists, subsequent calls no-op.

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

### Sync (RubienSync)

`RubienSync` maps local GRDB entities to CloudKit `CKRecord` objects and drives `CKSyncEngine`. The target is pre-Phase-B4 — the engine actor lives in the plan but not the repo yet; what's landed so far is the dirty-tracking schema in `AppDatabase.swift` plus the per-entity mapping files under `Sources/RubienSync/`. When adding the next entity's mapping, follow these patterns — they're load-bearing and easy to drift from.

**Per-entity mapping file shape.** Each synced entity (Reference, Tag, ReferenceTag, …) gets its own `*Record.swift` under `Sources/RubienSync/` with three pieces on an extension of the model:

- `populate(record:)` — mutate an existing `CKRecord` in place. This is the hot path: the caller holds a cached record carrying server-assigned system fields (for optimistic concurrency with `.ifServerRecordUnchanged`); reallocating drops the change-tag.
- `makeRecord(recordName:...)` — first-push convenience when there's no cached record yet.
- `init(record:)` — decode. Non-failable with safe fallbacks for optional-ish fields; use `init?` only when a missing field makes the row semantically meaningless (e.g. a pivot's FK pair).

`RecordField` is a per-entity enum of static-let field-name strings so field keys aren't scattered as literals. Field names match the DB column names for easy grepping.

**Identity rules.**

- The local rowID (`Reference.id`, `Tag.id`, …) is **never** encoded into the `CKRecord`. `CKRecord.ID.recordName` is the canonical identity; decoded models keep `id = nil` and the caller resolves the local rowID.
- Composite-key pivot rows (currently only `ReferenceTag`) use `"<id1>/<id2>"` as the recordName. The format must match the SQL expression emitted by the dirty-tracking triggers in `AppDatabase.swift` (see `pkExpression(table:prefix:)`). These two layers communicate via that string shape; drift silently breaks dirty-queue lookups.
- FKs between entities are stored as plain values (Int64 today, String UUID post-A-pks), never as `CKRecord.Reference`. Cascade semantics belong to SQLite FKs locally; CloudKit's action types would fight us.

**Forward-compat decode.** Unknown enum rawValues fall back to safe defaults (`.other`, `.unread`, `.legacy`) rather than throwing, per CKSyncEngine guidance — a newer peer writing a novel case must not crash an older decoder. Same rule applies to missing optional fields; treat absent as nil, not as an error.

**Dirty-tracking triggers.** `AppDatabase.swift`'s v1 migration emits AFTER INSERT/UPDATE/DELETE triggers per synced table (driven by the `syncedTables` helper). They upsert `syncState.isDirty=1` or insert a `tombstone` row, and gate on `(SELECT value FROM syncSession WHERE key='applyingRemote') IS NULL` so the pull handler's transaction (which inserts that row) doesn't re-dirty the rows it's applying.

Triggers do **not** self-`UPDATE` `dateModified`. SQLite has `recursive_triggers = ON` by default, so a trigger touching its own table loops. Stamp `dateModified` in the Swift mutation layer instead (matches the existing `Reference` mutation methods in `AppDatabase.swift`).

**Constants.** Container ID, zone ID, and record-type names (`CDReference`, `CDTag`, `CDReferenceTag`, …) live in `Sources/RubienSync/SyncConstants.swift`. The CKRecord type names carry a `CD` prefix ("CloudKit Data") so grepping for `CDReference` vs. `Reference` disambiguates the sync-layer type from the local model.

### CLI

`Sources/RubienCLI/RubienCLI.swift` is the single-file argument-parser entry with 15 subcommands (`search`, `list`, `get`, `add`, `update`, `delete`, `cite`, `import`, `export`, `tags`, `properties`, `views`, `annotations`, `styles`, `sync`). JSON is the default output format — scripts depend on it, so don't change CLI output shape without updating tests in `Tests/RubienCLITests/`.

**Keep the CLI in sync with data-layer changes.** Any time `RubienCore` gains a new model, table, field, or mutation (e.g. custom property definitions, property values, new reference metadata fields), extend the CLI to cover it — new subcommand for new entities, fold new fields into existing `get`/`list`/`export` JSON. UI-only changes (column reorder, popover layout, detail-panel widths) do **not** need CLI parity; the line is "is this a new way to read or write data?" If yes, the CLI must expose it and `RubienCLITests` must cover the JSON contract.

**Keep `Docs/CLI-Reference.md` current.** Any commit that changes CLI subcommands, flags, or JSON output shape must update the doc in the same commit: the subcommand table, the per-subcommand section (flags + example JSON), and the "Reference JSON Shape" block if `ReferenceDTO` changed. The doc is the scripting contract for users who don't read Swift source.

## Tests

Four test targets mirror the product targets:

- `Tests/RubienCoreTests/` — the bulk of business-logic coverage (citations, metadata, importers, DB, dirty-tracking triggers).
- `Tests/RubienSyncTests/` — CKRecord ↔ model round-trip per entity. Pure in-memory; no CloudKit calls.
- `Tests/RubienTests/` — app-level tests that can import SwiftUI code.
- `Tests/RubienCLITests/` — exercises the built `rubien-cli` binary at `.build/debug/rubien-cli`; keep JSON contracts stable.

Prefer adding coverage to `RubienCoreTests` where possible, since those tests run without AppKit and are the fastest loop.

`swift test` requires the full Xcode toolchain (not just CommandLineTools) because it needs the XCTest framework. Verify with `xcode-select -p` — if it reports `/Library/Developer/CommandLineTools`, switch with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Development workflow for non-trivial changes

For multi-file features or refactors, follow this cycle:

1. **Scope tightly.** Each commit should be one coherent step that builds cleanly and passes tests. For big features, split into phases — each phase shippable in isolation. Write the plan file before coding when the feature touches more than a handful of files.
2. **Implement → build → test.**
3. **Independent review.** Ask `codex-rescue` to review the uncommitted diff and surface correctness, contract, and edge-case concerns.
4. **`/simplify` sweep.** Run the three parallel reviews (reuse, quality, efficiency) to catch duplication, leaky abstractions, and hot-path concerns.
5. **Decide what to fix.** Apply findings that are clearly worth it; note the rest. Not every flag warrants a change.
6. **Build + test again**, then commit.

Skip the full cycle for trivial diffs (typos, single-line edits, doc tweaks, mechanical refactors). Apply it when the diff crosses files or introduces new abstractions.

## Conventions worth knowing

- `RubienCore/Resources` is attached with `.copy("Resources")` so the `Citeproc/{dist,CSL,locales}/` subdirectory structure is preserved verbatim inside the module bundle. `CiteprocJSCoreEngine` reads them via `Bundle.module.url(forResource:..., subdirectory: "Citeproc/...")`.
- `Rubien/Resources` is attached with `.process("Resources")` so the `en.lproj/Localizable.strings` localization is picked up by SPM.
- Debug logging uses `os.Logger` with subsystem `"Rubien"` and per-file categories (see `AppDatabase.swift`). The resolver-internal metadata log uses `com.rubien.metadata` — filter that in Console.app to see resolver traces.
- The fork is AGPL-sensitive: citeproc-js is AGPL-3.0 and remains bundled at runtime in `Resources/Citeproc/dist/citeproc-bundle.js`. Don't move its code into statically-linked Swift targets without reviewing license implications.
- `MetadataResolution.containsHanCharacters` and related helpers are retained as dead-but-harmless internal utilities — they no longer gate any resolver path, but removing them would cascade through several private helpers in `MetadataResolution.swift`.
- The vendored `citeproc-bundle.js` still sets `globalThis.SwiftLibCiteproc` and has a `// swiftlib-citeproc-entry.js` comment — those are third-party bundle internals that the Swift engine no longer reads. Leave them alone.
