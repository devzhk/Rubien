# AGENTS.md

## Overview

Rubien is a native macOS agentic research library and reference manager (SwiftUI, macOS 14+) for papers, books, and web sources. Its in-library Assistant works through Claude Code or Codex. A companion `rubien-cli` also runs on Linux: two front doors over one SQLite library.

## Build and dependencies

`Package.resolved` is authoritative. Upgrade dependencies only in a separate commit with tests and an updated version list; never resolve upgrades as a side effect of unrelated work. Sparkle changes also affect signing and the DMG-size guardrail.

- **Toolchain:** Swift 6.1+ / Xcode 16.3+; `Package.swift` currently uses **Swift 5 language mode**, not strict Swift 6 mode. CI uses macOS 26 and Linux `swift:6.3-jammy`.
- **Deployment:** macOS **14.4**. Gate newer APIs; follow `Sources/Rubien/Views/BackDeploymentSupport.swift`. Keep the minimum in `Package.swift`, `scripts/build-app.sh`, and `scripts/release.sh` aligned.
- **Pinned:** GRDB 7.10.0, swift-argument-parser 1.7.1, swift-crypto 3.15.1 (Linux; system CryptoKit on Mac), swift-asn1 1.7.0, Sparkle 2.9.2 (Mac, default-enabled `Sparkle` trait). Verify APIs against these versions, especially GRDB's concurrency surface.
- **Linux PDF:** poppler-glib 22.02, gdk-pixbuf 2.42, cairo (Ubuntu 22.04 baseline); see `Docs/Linux-PDF-Backend.md`.
- **MCP:** Node.js ≥20; dependencies and scripts in `mcp-server/package.json`.

## Commands

```bash
swift build                                                # build all targets
./scripts/preview-app.sh                                   # isolated Mac UI preview with verified SDK metadata
swift run rubien-cli <subcmd>                              # run CLI from SPM
swift test                                                 # all tests; needs full Xcode for XCTest
swift test --filter CitationFormatterTests                 # single class
swift test --filter RubienCoreTests.CitationFormatterTests/testAPA   # single method

./scripts/build-app.sh           # Debug bundle + DMG → build/
./scripts/build-app.sh release   # Release bundle + DMG
```

For worktree UI checks, use `scripts/preview-app.sh` from that worktree or open its exact verified `.app` path. Avoid `open -a Rubien` / activation by app name: these may open `/Applications/Rubien.app`. Use `scripts/dev-launch.sh` when App Group / CloudKit entitlements are needed.

The preview isolates its bundle identity and library, but shares the account's provider installations and credentials. It includes `rubien-cli` for Assistant integration, but omits sync entitlements and the browser host. Use it for UI and Assistant checks; validate sync/browser integration with the appropriate signed development bundle, and follow the release runbook for delivery checks.

Tests need full Xcode (`xcode-select -p`). If a toolchain switch causes SPM errors about missing target source directories, clear `.build` / `.swiftpm` and run `swift package resolve`; preserve any release dSYMs first.

### UI preview SDK invariant

**Do not refresh a preview by copying a plain `.build/debug/Rubien` executable into its bundle or use plain `swift run Rubien` for visual validation.** Rebuild through `scripts/preview-app.sh` so its linker settings and verification run together.

On the observed Xcode 27 toolchain, Swift's `--sysroot` linker invocation can record the deployment target **14.4** as the build SDK when SDK context is absent. AppKit then selects older compatibility behavior, which caused shifted toolbar buttons and sidebar click targets. Passing the selected SDK through Clang's `-isysroot` corrected the metadata and layout. This regression returned when a manual executable copy bypassed the fix in `scripts/build-app.sh`.

- Require `LC_BUILD_VERSION.sdk` to match the selected build SDK and `minos` to remain **14.4**. Keep these values distinct; do not raise the deployment target to fix layout or hardcode the SDK to 27.0.
- The preview script checks the executable before and after packaging. For another build route, run `scripts/verify-macos-sdk.py <actual-bundle-executable> "$(xcrun --sdk macosx --show-sdk-version)"` before UI validation. A successful build or signature check does not establish correct SDK metadata.
- If these symptoms recur, inspect the running executable's path and SDK metadata before changing SwiftUI padding, offsets, or toolbar placement.
- After replacing a preview, click the visible centers of Home and All References and toggle Activity/Details. Verify navigation and right-edge placement; accessibility activation alone can miss displaced mouse targets.

## Architecture

Main targets in `Package.swift`:

- **RubienCore:** shared GRDB models, migrations, metadata, importers, citations; no dependency on other Rubien targets.
- **RubienPDFKit:** PDF facade over PDFKit / Linux poppler, plus PDF extraction and Zotero import; depends on Core. Read `Docs/Linux-PDF-Backend.md` before changing its Linux backend.
- **RubienSync:** CloudKit mappings and `SyncedLibrary` / `CKSyncEngine`; linked by the app **and macOS CLI**.
- **Rubien:** SwiftUI app and readers; includes a portable Assistant subset compiled on Linux.
- **RubienCLI:** `rubien-cli`, argument-parser commands and native MCP server; `sync` is Mac-only.
- **RubienBrowserHost:** `rubien-browser-host`, Chrome native messaging validation and import through Core.
- **RubienExceptionCatcher:** Objective-C exception bridge used by Mac app/sync code.

### Data layer

GRDB migrations live in `Sources/RubienCore/Database/AppDatabase.swift`.

- **Never edit shipped migrations.** Add a new additive migration and advance `currentSchemaVersion`. Renames require copying data into a new column.
- **Never wipe a library**, including during development.

Storage is selected by `AppDatabase.preferredStorageRoot`: `RUBIEN_LIBRARY_ROOT` overrides the whole path; otherwise Mac uses the accessible App Group `9TXK4V3SS8.group.com.rubien.shared/Rubien`, then Application Support/Rubien; Linux uses `$XDG_DATA_HOME/rubien` or `~/.local/share/rubien`. Temporary storage is the last resort. PDFs, metadata artifacts, and sync sidecars share this root; startup handles legacy library promotion.

**Find the live database from the running process**, using `lsof -p <exact-app-pid>` and locating `library.sqlite`. Do not pick the first filesystem match: backups, the legacy container without `group.`, and unsigned CLI/dev libraries may all coexist. Pass `RUBIEN_LIBRARY_ROOT` when the CLI must inspect the same library as the app.

### Metadata resolution

`Sources/Rubien/Services/MetadataResolver.swift` coordinates identifier resolution and title search; fetchers live in `Sources/RubienCore/Services/MetadataFetcher.swift`. `MetadataVerifier` evaluates evidence and ambiguous candidates. Route arXiv DataCite DOIs (`10.48550/arXiv.…`) to arXiv, not CrossRef.

`Docs/Supported-Paper-URLs.md` is the canonical host/pattern registry. Changes to `KnownPaperHost` or URL rewrites must update that registry and the related extraction, classification, rewrite, and resolver tests. Link to it instead of duplicating host lists.

### Citation engine

`CitationFormatter` provides seven built-in styles; `CSLEngine` / `CSLManager` handle user-imported `.csl` files. All are pure Swift.

### Readers and annotations

PDF reader and web reader share an annotation vocabulary (highlight / underline / anchored note) but persist to **two different tables**. Web extraction runs through `ReaderExtractionManager` (Defuddle → Readability → YouTube fallback). The rich note editor is a TipTap/ProseMirror WebView; rebuild it via `npm run build` in `scripts/note-editor/`.

### Sync (RubienSync)

Read [Docs/Sync-Development.md](Docs/Sync-Development.md) before changing sync behavior, synced models or schema, identity/foreign-key handling, dirty-tracking triggers, or PDF sync. For CloudKit setup, diagnostics, rollout, or repair, also read [Docs/Sync-Runbook.md](Docs/Sync-Runbook.md).

### CLI

The command entry point is `Sources/RubienCLI/RubienCLI.swift`; sync and MCP also have separate files. JSON output is a contract: update `RubienCLITests` when changing it. Tags route through `properties` and the built-in Tags definition.

- New Core data or mutations need CLI parity; UI-only changes do not.
- Update `Docs/CLI-Reference.md` alongside changed commands, flags, or JSON.
- Keep native and npm MCP tool schemas/behavior aligned when changing their shared capabilities.

## Tests

Use focused tests for the changed behavior:

- `RubienCoreTests`: shared business logic.
- `RubienSyncTests`: record mappings, durable state, identity, and recovery.
- `RubienTests`: app behavior; wrap files in `#if os(macOS)` so Linux can compile the test graph.
- `RubienCLITests`: CLI process and JSON contracts.
- `RubienBrowserHostTests`: native messaging, import, and deduplication.
- `RubienPDFKitTests`: PDF backend parity. Keep its PDF dependency Mac-only in the umbrella test graph: linking poppler into Linux XCTest has caused hangs. See `scripts/run-linux-parity-tests.sh` for standalone Linux checks.
- npm MCP: `npm run build && npm test` in `mcp-server/`.

**Known suite-ordering hang:** `ActivityRecordTests/testActivityDeletionRequeuesPreviouslyConfirmedTombstone` previously hung in grouped runs on clean main. Until verified resolved, run it alone and the broader suite with `--skip ActivityRecordTests`; do not wait indefinitely or assume the feature caused it.

## Releases

Read `Docs/Release-Runbook.md` **in full before any release preparation, signing, publication, verification, or recovery**, and follow its order. It owns CI/CloudKit gates, human checks, explicit approval, elevated host access, versioning, notes, signing/notarization, Mac/Linux/extension/npm publication, and private dSYM retention. Change release policy there rather than duplicating it here.

## Development workflow for non-trivial changes

For multi-file features or refactors:

1. **Scope tightly.** Each commit is one coherent step that builds + passes tests. Split big features into phases. Write a plan file before coding when the feature crosses more than a handful of files.
2. **Implement → build → test.**
3. **Confirm reviews before committing.** Only when non-trivial changes are ready to commit, ask the user whether to run the independent review and `/simplify` sweep. The user may skip either or both. Do not run these reviews during implementation or routine fix iterations.
4. **Run approved reviews.** Independent review: use one subagent to review the uncommitted diff. `/simplify` sweep: three parallel reviews (reuse, quality, efficiency).
5. **Decide what to fix.** Not every flag warrants a change.
6. **Build + test again**, then commit.

Skip the cycle for trivial diffs (typos, single-line edits, doc tweaks).

## Conventions worth knowing

- **Linux portability:** use `RubienLogger`, not `os.Logger`, in shared code. App-target files must be Mac-gated or portable; types referenced by the portable Assistant subset must also be portable. Use conditional CryptoKit/Crypto imports. Mac builds do not catch Linux violations.
- **CoreFoundation:** Linux needs an explicit conditional `import CoreFoundation` for CF symbols. Use CFBoolean type IDs to distinguish JSON booleans from numbers; see `MCPToolCatalog.swift`.
- **Property options:** Type/`referenceType` options are fixed by export schemas; Status/`readingStatus` and custom options are user-extensible. Follow `Properties.optionsMutable(for:)` when adding built-ins.
- **Preferences:** `RubienPreferences` statics are not observable. SwiftUI controls need a `@State` mirror with persistence or suitable `@AppStorage`; a direct binding to a static can save without redrawing.
- **Reader windows:** `ReaderWindowManager` reuses windows per reference. Reopening does not rerun `init`; refresh changing preferences on the relevant action or observe them explicitly.
