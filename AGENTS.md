# AGENTS.md

This file is the single source of guidance for coding agents (Claude Code, Codex, and others) working in this repository. `CLAUDE.md` is a symlink to this file — Claude Code only auto-loads `CLAUDE.md`, so the symlink keeps every agent reading the same instructions with nothing to sync.

## Overview

Rubien is a native macOS agentic research library and reference manager (SwiftUI, macOS 14+) for papers, books, and web sources. Its in-library Assistant works through Claude Code or Codex. A companion `rubien-cli` also runs on Linux: two front doors over one SQLite library.

## Pinned versions

When writing code against these libraries, verify your API references against the version below — LLM memory often defaults to older releases.

- **Swift toolchain:** 6.x (Xcode 15+ on Mac; CI Linux uses `swift:6.3-jammy`). Strict concurrency, region-based isolation, `~Copyable` are available; don't reach for pre-Swift-6 patterns from memory.
- **macOS:** deployment target is **14.4 Sonoma** (`Package.swift`); build host needs Xcode 16.3+ (GRDB 7.10 declares `swift-tools-version: 6.1`); CI + maintainer build on **macOS 26 Tahoe** (`runs-on: macos-26`). Anything added after 14.4 must be `@available`-gated — macOS 15 SwiftUI shims (`pointerStyle`, `presentationSizing(.fitted)`, `Color.mix`) live in `Sources/Rubien/Views/BackDeploymentSupport.swift`; follow that pattern. `CKSyncEngine` and the Observation framework (both macOS 14.0) and `TableColumnForEach` (14.4) are fair game without a gate; any SwiftUI/PDFKit API introduced after 14.4 needs one. Keep the three min-version sources in lockstep when changing the floor: `Package.swift` `.macOS(...)`, `LSMinimumSystemVersion` in `scripts/build-app.sh`, and `MIN_SYSTEM_VERSION` in `scripts/release.sh`.
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

### Launching from a worktree

For ordinary UI checks from a git worktree, run the app from that worktree:

```bash
swift run Rubien
```

Avoid `open -a Rubien` or AppleScript activation by app name when verifying worktree changes; macOS may bring forward `/Applications/Rubien.app` instead. Use `./scripts/dev-launch.sh` only when you need signed-app behavior such as App Group / CloudKit entitlements.

### Foot-gun: stale `.build/checkouts` after toolchain swap

After `sudo xcode-select -s ...` between CommandLineTools and Xcode, SPM's checkout cache can corrupt with cryptic "Source files for target X should be located under …" errors. Fix:

```bash
rm -rf .build .swiftpm
swift package resolve
```

It's an SPM bug around stale state, not something you broke.

## Architecture

Five Swift targets in `Package.swift`:

- **`RubienPDFKit`** (library) — cross-platform PDF facade with Darwin (PDFKit) and Linux (poppler-glib) backends. Hosts `PDFExtractor`, `PDFService`, `ZoteroFolderImporter`. Depends on `RubienCore`. The Mac app's reader still uses PDFKit directly; the facade is for the headless extract/render path. Read `Docs/Linux-PDF-Backend.md` before touching `Sources/RubienPDFKit/Linux/`.
- **`RubienCore`** (library) — everything usable without AppKit: GRDB models, migrations, metadata resolvers, BibTeX/RIS importers, citation engines. Depends on no other Rubien target (it is the root library; `RubienPDFKit` depends on *it*, not vice versa).
- **`RubienSync`** (library, Mac-only) — CloudKit mapping + `CKSyncEngine`. CLI does not link it.
- **`Rubien`** (app executable, Mac-only) — SwiftUI views, readers.
- **`RubienCLI`** (executable, `rubien-cli`) — 18 subcommands on Mac, 17 on Linux (no `sync`).

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

**Supported paper URL registry:** `Docs/Supported-Paper-URLs.md` is the canonical list of supported hosts and URL patterns. Any change to a `KnownPaperHost` classification or URL rewrite must also update the registry and the related extraction, classification, rewrite, and resolver tests. Other user-facing docs should link to the registry instead of duplicating its host list.

**Foot-gun:** arXiv DataCite DOIs (`10.48550/arXiv.1706.03762`) must route to the arXiv resolver, not CrossRef (which returns 404 for them). Already handled in `extractIdentifier`.

### Citation engine

`CitationFormatter` (pure Swift, seven built-in styles APA/MLA/Chicago/IEEE/Harvard/Vancouver/Nature) and `CSLEngine` / `CSLManager` (pure Swift, user-imported `.csl` files) handle every citation path; adding a built-in style only needs `CitationFormatter`. (A parked citeproc-js JSCore engine + bundled `Resources/Citeproc/` tree were removed in July 2026 — recover from git history if CSL-JS fidelity is ever needed.)

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
- **Never call `CKSyncEngine.fetchChanges()` / `sendChanges()` from inside `handleEvent(_:syncEngine:)`.** CloudKit asserts against re-entering the engine from its own delegate callback (`EXC_BREAKPOINT`/SIGTRAP), and wrapping the call in a `Task {}` does **not** help when it's kicked as a consequence of an event (e.g. a deferred fetch off `.didFetchChanges`/idle). This shipped as the 0.1.9 crash (`d339dbf`, reverted in 0.1.10). Kick explicit fetches from launch / foreground / idle-timer instead — never from within `handleEvent`.

PDF binaries sync as a sibling `CDReferencePDF` record carrying a `CKAsset`; per-device materialization state lives in a local-only `pdfCache` table (never observed by sync triggers). iOS on-demand fetch / LRU eviction is deferred to the iOS-port plan.

### CLI

`Sources/RubienCLI/RubienCLI.swift` is single-file argument-parser. JSON output is the contract — scripts depend on it; don't change shape without updating `RubienCLITests`. Tag operations route through `properties` against the seeded built-in Tags PropertyDefinition.

- **CLI ↔ data-layer lockstep.** Any new model, table, field, or mutation in `RubienCore` extends the CLI — new subcommand for new entities, fold new fields into existing `get`/`list`/`export` JSON. UI-only changes don't need CLI parity; the line is "is this a new way to read or write data?"
- **Keep `Docs/CLI-Reference.md` current.** Any commit changing CLI subcommands, flags, or JSON output shape updates the doc in the same commit.

## Tests

Five test targets:

- `RubienCoreTests` — bulk of business-logic coverage. Fastest loop; prefer adding coverage here.
- `RubienSyncTests` — CKRecord ↔ model round-trip per entity. Pure in-memory.
- `RubienTests` — app-level tests that import SwiftUI. **Every file in this target must be wrapped in `#if os(macOS)` … `#endif`** — SwiftPM compiles all test targets on Linux CI even for a filtered run, and the Mac-only `Rubien` module doesn't exist there ("no such module 'Rubien'"). A macOS build won't catch a missing guard; only Linux CI does.
- `RubienCLITests` — exercises `.build/debug/rubien-cli` via Process. Keep JSON contracts stable.
- `RubienPDFKitTests` — cross-backend parity tests. **Mac-only** by `Package.swift` conditional dep; linking poppler into the Linux test bundle triggers a swift-corelibs-xctest+libdispatch hang. Linux contributors who want to run them locally: see `scripts/run-linux-parity-tests.sh`.

`swift test` needs the full Xcode toolchain (not just CommandLineTools). Verify with `xcode-select -p` and switch with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if needed.

## Releases

Before preparing, cutting, verifying, recovering, or publishing any Rubien release, read `Docs/Release-Runbook.md` in full and follow its order exactly. It is the single source of truth for versioning, CI gating (including the narrow docs-only exception), release notes, agent-approval and host-access requirements, signing/notarization, artifact hosting and verification, dSYM retention, Linux CLI publication, and the coupled MCP npm package.

An agent may run the signed release pipeline only after explicit user approval and must use the elevated host access required by the runbook. If release behavior or policy changes, update `Docs/Release-Runbook.md` rather than duplicating the procedure here.

## Development workflow for non-trivial changes

For multi-file features or refactors:

1. **Scope tightly.** Each commit is one coherent step that builds + passes tests. Split big features into phases. Write a plan file before coding when the feature crosses more than a handful of files.
2. **Implement → build → test.**
3. **Independent review.** Ask `codex-rescue` to review the uncommitted diff.
4. **`/simplify` sweep.** Three parallel reviews (reuse, quality, efficiency).
5. **Decide what to fix.** Not every flag warrants a change.
6. **Build + test again**, then commit.

Skip the cycle for trivial diffs (typos, single-line edits, doc tweaks).

### Codex review foot-guns

The `codex-rescue` step shells out to the vendored codex-companion runtime (`~/.claude/plugins/cache/openai-codex/codex/<ver>/scripts/codex-companion.mjs`). Two traps have silently eaten whole reviews:

- **Long reviews die at the 10-minute Bash cap → zombie job.** The `codex:codex-rescue` subagent runs `codex-companion.mjs task` in the **foreground and blocks** (it strips `--background` by design). The harness Bash tool is hard-capped at 600 s, so any review needing >10 min is killed mid-run, leaving the job frozen at `status:"running"` with no result and no notification. **Fix:** for a big diff/plan review, don't rely on the blocking forwarder — either run the foreground `task` call via a Bash `run_in_background: true` command (its stdout is the full rendered review, delivered when it exits, with no 10-min cap), or drive the companion **detached** with `task --background` (returns a `jobId` immediately) and poll `status <jobId>` / `result <jobId>` with short calls. Quick small-diff reviews through the subagent are fine.
- **Codex's sandbox is read-only — never ask it to write a file.** A prompt that says "write findings to /tmp/…" makes Codex burn its time budget on doomed writes (and shell-quoting retries) instead of reviewing — which is exactly what pushed a run past the 10-min cap. Always tell it to **return findings inline**; capture them yourself.
- **Recovering a stuck/finished review:** job records + logs live under `~/.claude/plugins/data/codex-openai-codex/state/<workspace-slug>-<hash>/jobs/` (`<jobId>.json` has `rawOutput`; `<jobId>.log` is the live trace). Clear a zombie with `codex-companion.mjs cancel <jobId>`.
- **Run reviews at `--effort medium`, not the `xhigh` config default.** At `xhigh` (`~/.codex/config.toml`) a turn can stall forever: it reaches `response.in_progress`, streams nothing, and codex has no turn timeout — so the job hangs at `status:"running"` with empty `rawOutput` (distinct from the Bash-cap zombie; happens even backgrounded). **Fix:** `codex-companion.mjs task --background --effort medium < prompt-file`, poll `status`/`result`; if it stalls ~2 min, `cancel <jobId>` and retry at medium. Confirm the stall signature in `~/.codex/logs_2.sqlite` (table `logs`) if needed.
- **Model:** never pass `--model` — stay on the config default gpt-5.5; never downgrade (not gpt-4.1, not gpt-5.4). For a stall, change *effort*, never the model.

## Conventions worth knowing

- **Cross-platform logging:** use `RubienLogger` (shim in `Sources/RubienCore/Logging/`). Don't `import os.Logger` directly in code that compiles on Linux.
- **The Mac-only `Rubien` app target still COMPILES on Linux CI** (SwiftPM builds the whole package graph for `swift test`), surviving via a two-tier file convention: most files are wrapped whole-file in `#if os(macOS)`, but a deliberate **portable subset of `Sources/Rubien/Assistant/`** (`AgentProvider`, `ClaudeStreamParser`, `ClaudeSessionStore`, `CodexAppServerProtocol`, `ChatTranscriptModels`, `ChatTranscriptJS`, `AssistantTurnGate`, `AssistantModelOptions`, `AssistantAttachments`, `MCPContentChannel`) is Foundation-only and un-gated. Two rules follow: (1) a new app-target file must either take the `os(macOS)` guard or stay Foundation-pure (CryptoKit → the `canImport(CryptoKit)`/`Crypto` dance, and the target needs the Linux-conditional `Crypto` product dep — already added); (2) any type referenced FROM a portable file must itself live in a portable file. A macOS build won't catch a violation — only Linux CI does (shipped example: the attachments feature's Mac-framework files defining types used by portable `AgentProvider`/history readers; fixed in `c7e7f6e`).
- **CoreFoundation on Linux needs an explicit import.** swift-corelibs-foundation does **not** re-export CF symbols (`CFGetTypeID`, `CFBooleanGetTypeID`, …) through `import Foundation`. Any file that compiles on Linux and touches CF needs `#if canImport(CoreFoundation)` / `import CoreFoundation` / `#endif` (precedent: `Sources/RubienCLI/MCPToolCatalog.swift`). A macOS build won't catch the omission — only Linux CI does. Common trigger: the CFBoolean type-id check that distinguishes JSON `true` from `1` (the only reliable test; `NSNumber(1) is Bool` is `true` on Apple platforms).
- **Built-in property mutability has two buckets.** "Fixed" options when they're coupled to BibTeX/CSL/export schemas (currently only Type/`referenceType`); "user-extensible" otherwise (Status/`readingStatus` today, and any future built-in). The split is encoded in `Properties.optionsMutable(for:)` in `RubienCLI.swift`; pick the right bucket when adding a new built-in. Custom (non-default) properties are always user-extensible.
- **`RubienPreferences` is not observable** — it's an `enum` of `UserDefaults.standard` statics. A SwiftUI control bound with `Binding(get: { pref }, set: { pref = $0 })` **straight to it** *persists* the change but the view never invalidates, so the control only reflects the new value **after a relaunch** — a silent bug (unit tests pass; it "works" next launch). Back the control with a `@State` mirror (seed on appear, write through via `.onChange`), or `@AppStorage` when the pref has no custom empty/default logic. The theme picker is the misleading exception: it refreshes only because its setter *also* flips `NSApplication.appearance`, which forces a redraw. `SettingsActionButtonStyle` / the assistant Settings pane show the mirror pattern.
- **Reader windows are reused per reference.** `ReaderWindowManager.openWebReader` / `openPDFReader` cache one `NSWindow` per `reference.id`, so reopening an already-open document does **not** re-run the reader's `init`. Anything read only at init (e.g. a just-changed setting) won't refresh for an open reader — apply live-changing state on a user action instead (the assistant sidebar re-reads its defaults on "New conversation", not just at window open).
