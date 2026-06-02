# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Rubien is a native macOS reference manager (SwiftUI, macOS 14+) plus a companion `rubien-cli` that also runs on Linux. Two front doors over one SQLite library.

## Pinned versions

When writing code against these libraries, verify your API references against the version below — LLM memory often defaults to older releases.

- **Swift toolchain:** 6.x (Xcode 15+ on Mac; CI Linux uses `swift:6.3-jammy`). Strict concurrency, region-based isolation, `~Copyable` are available; don't reach for pre-Swift-6 patterns from memory.
- **macOS:** deployment target is **15.0 Sequoia** (`Package.swift`); build host needs Xcode 16.3+ (GRDB 7.10 declares `swift-tools-version: 6.1`); CI + maintainer build on **macOS 26 Tahoe** (`runs-on: macos-26`). Anything added after 15.0 must be `@available`-gated. `CKSyncEngine`, the Observation framework, and recent SwiftUI/PDFKit APIs are all fair game without a gate.
- **GRDB:** 7.10 (`Package.swift` declares `from: "7.0.0"`). GRDB 7 has a different read/write concurrency surface than 5.x/6.x; check the current docs before writing query code from stale memory.
- **swift-argument-parser:** 1.7 (`from: "1.3.0"`). API stable across 1.x.
- **swift-crypto:** 3.x (Linux only; macOS uses system CryptoKit).
- **Linux PDF system libs:** poppler-glib 22.02, gdk-pixbuf 2.42, cairo system (Ubuntu 22.04 baseline). API specifics in `Docs/Linux-PDF-Backend.md`.
- **MCP server:** Node.js ≥ 20; TypeScript per `mcp-server/package.json`.

## Commands

```bash
swift build                                                # build all targets
swift run Rubien                                           # run the app from SPM (Mac dev loop)
swift run rubien-cli <subcmd>                              # run CLI from SPM
swift test                                                 # all tests; needs full Xcode for XCTest
swift test --filter CitationFormatterTests                 # single class
swift test --filter RubienCoreTests.CitationFormatterTests/testAPA   # single method

./scripts/build-app.sh           # Debug bundle + DMG → build/
./scripts/build-app.sh release   # Release bundle + DMG
```

### Foot-gun: stale `.build/checkouts` after toolchain swap

After `sudo xcode-select -s ...` between CommandLineTools and Xcode, SPM's checkout cache can corrupt with cryptic "Source files for target X should be located under …" errors. Fix:

```bash
rm -rf .build .swiftpm
swift package resolve
```

It's an SPM bug around stale state, not something you broke.

## Architecture

Five Swift targets in `Package.swift`:

- **`RubienPDFKit`** (library) — cross-platform PDF facade with Darwin (PDFKit) and Linux (poppler-glib) backends. Hosts `PDFExtractor`, `PDFService`, `ZoteroFolderImporter`. The Mac app's reader still uses PDFKit directly; the facade is for the headless extract/render path. Read `Docs/Linux-PDF-Backend.md` before touching `Sources/RubienPDFKit/Linux/`.
- **`RubienCore`** (library) — everything usable without AppKit: GRDB models, migrations, metadata resolvers, BibTeX/RIS importers, citation engines. Depends on `RubienPDFKit`. Only target the CLI/tests depend on directly.
- **`RubienSync`** (library, Mac-only) — CloudKit mapping + `CKSyncEngine`. CLI does not link it.
- **`Rubien`** (app executable, Mac-only) — SwiftUI views, readers.
- **`RubienCLI`** (executable, `rubien-cli`) — 16 subcommands on Mac, 15 on Linux (no `sync`).

### Data layer

GRDB + a single `DatabaseMigrator` in `AppDatabase.swift`. Hard rules:

- **Migrations are immutable once shipped.** Never edit a previously-released `registerMigration` block — editing it changes behavior on fresh installs while being silently a no-op on already-migrated libraries. Schema changes go in a new `registerMigration("vN", ...)`, and must be additive: to rename a column, copy data into a new column inside the migration.
- **CloudKit record fields are equally shipped.** Adding a field is fine (older peers fall back to safe defaults). **Renaming or removing one breaks already-pushed records on every device.**
- **Production never wipes the library.** Dev shouldn't either.

**On-disk storage** (`preferredStorageRoot(named:)` resolution order):

| # | Path | When |
|---|---|---|
| 0 | `$RUBIEN_LIBRARY_ROOT` (verbatim) | Explicit override |
| 1 | `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/` | Signed-with-entitlement process |
| 2 | `~/Library/Application Support/Rubien/` | Unsandboxed Mac dev builds |
| 3 | `$XDG_DATA_HOME/rubien/` (default `~/.local/share/rubien/`) | Linux |
| 4 | Temp dir | Last resort |

PDF storage, metadata artifacts, and the sync state sidecar all ride this same root, so the whole library moves together. A startup migration auto-promotes an existing library when you switch between sandboxed/unsandboxed modes.

**Foot-gun — finding the app's *live* `library.sqlite`:** several copies coexist on disk, so `find … -name library.sqlite | head` or hand-typing the path will silently hit the wrong one. Known traps: timestamped `.backup-*` / `.empty-backup-*` siblings next to the live DB; a **legacy `9TXK4V3SS8.com.rubien.shared` container (no `group.`)** left over from before the App Group id gained the `group.` prefix (the active id is `9TXK4V3SS8.group.com.rubien.shared`, per `AppDatabase.appGroupID`); and `rubien-cli` (unsigned → no entitlement) resolving to `~/Library/Application Support/Rubien/`, a *different* library, unless you pass `RUBIEN_LIBRARY_ROOT`. To inspect the **running app's** actual DB, ask the process itself: `lsof -p "$(pgrep -f 'Rubien.app/Contents/MacOS/Rubien')" | grep library.sqlite`.

### Metadata resolution

Pipeline in `Sources/Rubien/Services/MetadataResolver.swift`: `DOI → arXiv → PMID → ISBN → OpenAlex title search → Semantic Scholar → .seedOnly`. Identifier resolvers in `Sources/RubienCore/Services/MetadataFetcher.swift` talk directly to public HTTP APIs — no keys. `MetadataVerifier` applies evidence-based rules and downgrades to `.candidate` when multiple results compete.

**Foot-gun:** arXiv DataCite DOIs (`10.48550/arXiv.1706.03762`) must route to the arXiv resolver, not CrossRef (which returns 404 for them). Already handled in `extractIdentifier`.

### Citation engine

`CitationFormatter` (pure Swift, seven built-in styles APA/MLA/Chicago/IEEE/Harvard/Vancouver/Nature) and `CSLEngine` / `CSLManager` (pure Swift, user-imported `.csl` files) handle every live citation path. `CiteprocJSCoreEngine` + the `Resources/Citeproc/` tree are parked — kept in-tree but never invoked; adding a built-in style only needs `CitationFormatter`.

### Readers and annotations

PDF reader and web reader share an annotation vocabulary (highlight / underline / anchored note) but persist to **two different tables**. Web extraction runs through `ReaderExtractionManager` (Defuddle → Readability → YouTube fallback). The rich note editor is a TipTap/ProseMirror WebView; rebuild it via `npm run build` in `scripts/note-editor/`.

### Sync (RubienSync)

Sync is fully landed and running against `iCloud.com.rubien.app`. See `Docs/Sync-Runbook.md` for ops, `scripts/dev-launch.sh` for the dev-signing loop.

Rules every new sync work must follow:

- **Each synced entity has a `populate(record:) / makeRecord(...) / init(record:)` triple** on a model extension. `populate` mutates an existing `CKRecord` so the cached server change-tag survives — never re-allocate.
- **`CKRecord.ID.recordName` is the canonical identity.** Local rowIDs are never encoded into the record. Composite-key pivot rows use `<id1>/<id2>` as the recordName; this format is mirrored by the dirty-tracking trigger SQL, so drift silently breaks dirty-queue lookups.
- **FKs between entities are plain values, never `CKRecord.Reference`.** Cascade semantics live in SQLite locally.
- **Forward-compat decode.** Unknown enum rawValues fall back to safe defaults rather than throwing — a newer peer writing a novel case must not crash an older decoder.
- **Triggers do NOT self-`UPDATE` `dateModified`.** SQLite's `recursive_triggers = ON` would loop. Stamp `dateModified` in the Swift mutation layer.
- **Synced tables hold no local-only columns.** Enforced by `SyncSchemaInvariantTests`. Add a column to a synced table → must add the corresponding CKRecord field.

PDF binaries sync as a sibling `CDReferencePDF` record carrying a `CKAsset`; per-device materialization state lives in a local-only `pdfCache` table (never observed by sync triggers). iOS on-demand fetch / LRU eviction is deferred to the iOS-port plan.

### CLI

`Sources/RubienCLI/RubienCLI.swift` is single-file argument-parser. JSON output is the contract — scripts depend on it; don't change shape without updating `RubienCLITests`. Tag operations route through `properties` against the seeded built-in Tags PropertyDefinition.

- **CLI ↔ data-layer lockstep.** Any new model, table, field, or mutation in `RubienCore` extends the CLI — new subcommand for new entities, fold new fields into existing `get`/`list`/`export` JSON. UI-only changes don't need CLI parity; the line is "is this a new way to read or write data?"
- **Keep `Docs/CLI-Reference.md` current.** Any commit changing CLI subcommands, flags, or JSON output shape updates the doc in the same commit.

## Tests

Five test targets:

- `RubienCoreTests` — bulk of business-logic coverage. Fastest loop; prefer adding coverage here.
- `RubienSyncTests` — CKRecord ↔ model round-trip per entity. Pure in-memory.
- `RubienTests` — app-level tests that import SwiftUI.
- `RubienCLITests` — exercises `.build/debug/rubien-cli` via Process. Keep JSON contracts stable.
- `RubienPDFKitTests` — cross-backend parity tests. **Mac-only** by `Package.swift` conditional dep; linking poppler into the Linux test bundle triggers a swift-corelibs-xctest+libdispatch hang. Linux contributors who want to run them locally: see `scripts/run-linux-parity-tests.sh`.

`swift test` needs the full Xcode toolchain (not just CommandLineTools). Verify with `xcode-select -p` and switch with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if needed.

## Releases

Rubien ships as a signed + notarized DMG via GitHub Releases, with Sparkle 2 auto-update from `Docs/appcast.xml` (served by GitHub Pages).

- **Cut a release:** see `Docs/Release-Runbook.md`. Short version: bump `VERSION` (e.g. `0.1.0` → `0.1.1`), bump `BUILD.txt`, run `./scripts/release.sh` from a clean `main`.
- **DMGs are hosted on the public `devzhk/Rubien-releases` repo**, not the private source repo — Sparkle downloads anonymously and private-repo release assets 404. The appcast and `SUFeedURL` stay on the private repo's Pages (`devzhk.github.io/Rubien/appcast.xml`), so repointing the `<enclosure>` URLs there fixes already-installed clients with no new build. `release.sh` sets `RELEASES_REPO`, tags the private source, then runs `gh release create --repo "$RELEASES_REPO"`.
- **`release.sh` reads `RELEASE_NOTES_TEXT` and `CODESIGN_IDENTITY` from the environment, and both fail *silently* if wrong.** A `RELEASE_NOTES_TEXT` left exported from a prior release makes the new version republish the **previous** version's notes to *both* the GitHub release and the appcast `<description>` — pass it fresh each release (`RELEASE_NOTES_TEXT="…this version's changes…" ./scripts/release.sh`) or `unset` it first. Missing `CODESIGN_IDENTITY` (`Developer ID Application: … (9TXK4V3SS8)`) → everything ad-hoc-signs (`Signature=adhoc`) and notarization rejects every binary; export it first (runbook §prereqs).
- **Sparkle is gated by a package trait** (`Sparkle`, enabled by default in `Package.swift`). DMG builds get it; a future Mac App Store flavor opts out via `swift build --disable-default-traits` so `Sparkle.framework` is absent from the bundle. Don't `import Sparkle` outside `#if canImport(Sparkle)` blocks — that gate covers both the MAS-flavor opt-out (Sparkle product dep absent → canImport false) and non-macOS platforms (Linux CI → canImport false) in one check.
- **codesign rule:** never `--deep`. Sign Sparkle components individually in the order written in `scripts/lib/codesign.sh` (`Installer.xpc → Downloader.xpc → Autoupdate → Updater.app → Sparkle.framework`). `Downloader.xpc` specifically needs `--preserve-metadata=entitlements`. Get this wrong and the failure surfaces as opaque "Failed to gain authorization" XPC errors at runtime.
- **Versioning:** `CFBundleShortVersionString` is the `VERSION` file (SemVer 0.x while in alpha, advancing to 1.0.0 at first stable). `CFBundleVersion` is the `BUILD.txt` file (monotonic integer; Sparkle's "is this newer" check uses this, not the marketing version). The `.txt` suffix avoids APFS aliasing `BUILD` with the `build/` output directory.

## Development workflow for non-trivial changes

For multi-file features or refactors:

1. **Scope tightly.** Each commit is one coherent step that builds + passes tests. Split big features into phases. Write a plan file before coding when the feature crosses more than a handful of files.
2. **Implement → build → test.**
3. **Independent review.** Ask `codex-rescue` to review the uncommitted diff.
4. **`/simplify` sweep.** Three parallel reviews (reuse, quality, efficiency).
5. **Decide what to fix.** Not every flag warrants a change.
6. **Build + test again**, then commit.

Skip the cycle for trivial diffs (typos, single-line edits, doc tweaks).

## Conventions worth knowing

- **Cross-platform logging:** use `RubienLogger` (shim in `Sources/RubienCore/Logging/`). Don't `import os.Logger` directly in code that compiles on Linux.
- **Built-in property mutability has two buckets.** "Fixed" options when they're coupled to BibTeX/CSL/export schemas (currently only Type/`referenceType`); "user-extensible" otherwise (Status/`readingStatus` today, and any future built-in). The split is encoded in `Properties.optionsMutable(for:)` in `RubienCLI.swift`; pick the right bucket when adding a new built-in. Custom (non-default) properties are always user-extensible.
