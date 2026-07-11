# PDF/Markdown Path and URL Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the app, `rubien-cli`, and `rubien_import` accept local PDF/Markdown paths and direct HTTP(S) file URLs through one validated acquisition and import path.

**Architecture:** `ImportSourceMaterializer` in RubienCore identifies a supported local file or materializes a validated URL into a caller-owned temporary directory. `PDFDownloadService` gains a reusable temporary-download path, while a RubienPDFKit coordinator shares the existing PDF metadata resolution and persistence semantics between the app and CLI. The SwiftUI sheet only stages input and reports acquisition errors; the existing batch coordinator owns library progress and summaries.

**Tech Stack:** Swift 6.3, Foundation/FoundationNetworking, SwiftUI/AppKit, GRDB 7, swift-argument-parser 1.x, TypeScript/Zod/Vitest.

## Global Constraints

- Preserve the existing `.md`/`.markdown`, BibTeX, RIS, stdin, and folder-import contracts.
- A remote URL must be `http`/`https` and have a `.pdf`, `.md`, or `.markdown` path extension before downloading.
- PDFs require a 2xx response, `application/pdf` content type, and `%PDF` magic bytes; Markdown requires a 2xx compatible text content type, valid UTF-8, and a 50 MB maximum.
- Remote temporary files preserve the URL filename, are cleaned after import, and never become a permanent library file until the existing import path copies them.
- App typed paths accept absolute paths and `~/…`; CLI retains relative-path behavior; MCP documents an absolute host path or HTTP(S) URL.
- Keep CLI JSON output backward-compatible: existing Markdown/BibTeX/RIS output remains unchanged; PDF output adds only optional status/intake fields.
- Do not change schema, migrations, or CloudKit record fields.
- Use `RubienLogger` rather than `OSLog` in cross-platform code; RubienCore and RubienCLI must continue to compile on Linux.

---

### Task 1: Source materialization and temporary PDF download

**Files:**
- Create: `Sources/RubienCore/Services/ImportSourceMaterializer.swift`
- Modify: `Sources/RubienCore/Services/PDFDownloadService.swift`
- Create: `Tests/RubienCoreTests/ImportSourceMaterializerTests.swift`
- Modify: `Tests/RubienCoreTests/PDFDownloadServiceTests.swift`

**Interfaces:**
- Produces `ImportSourceKind` (`pdf`, `markdown`), `MaterializedImportSource` (`input`, `fileURL`, `kind`, `temporaryDirectoryURL`), and `ImportSourceMaterializer.materialize(_:localPathPolicy:session:) async throws`.
- Produces `PDFDownloadService.downloadTemporary(from:suggestedFilename:destinationDirectory:session:) async throws -> URL`; the existing `download(from:suggestedFilename:)` delegates to it before moving the validated file into library storage.
- `MaterializedImportSource.cleanup()` removes only its non-nil temporary directory.

- [ ] **Step 1: Write failing materializer tests**

Add URLProtocol-backed tests proving that a local `.markdown` file is classified without cleanup ownership; a remote `text/plain` `.md` file is materialized with its original filename and removed by `cleanup()`; HTML, invalid UTF-8, non-2xx, unsupported extensions, non-regular local paths, and values over 50 MB are rejected with `LocalizedError` text.

- [ ] **Step 2: Verify the tests fail because the materializer does not exist**

Run: `swift test --filter ImportSourceMaterializerTests`

Expected: compile failure naming `ImportSourceMaterializer`.

- [ ] **Step 3: Implement the smallest shared acquisition API**

Add an enum-based error surface with stable user-facing descriptions. Classify only `.pdf`, `.md`, and `.markdown`; expand `~` for local paths; require absolute local paths only when the caller selects that policy; require a regular file. For remote Markdown, accept `text/markdown`, `text/x-markdown`, `text/plain`, `application/markdown`, or `application/octet-stream`; reject HTML and other content types. Copy/move validated downloads into `RubienImport-<UUID>/` with the URL basename.

- [ ] **Step 4: Add temporary-PDF tests and implementation**

Test a valid `application/pdf` `%PDF` body writes to the requested temporary directory and invalid content type/magic data throw `DownloadError.notAPDF`. Refactor `PDFDownloadService.download` to reuse the same validation path, preserving its permanent-storage JSON-facing behavior.

Run: `swift test --filter ImportSourceMaterializerTests && swift test --filter PDFDownloadServiceTests`

Expected: both suites pass.

- [ ] **Step 5: Commit the isolated acquisition layer**

```bash
git add Sources/RubienCore/Services/ImportSourceMaterializer.swift Sources/RubienCore/Services/PDFDownloadService.swift Tests/RubienCoreTests/ImportSourceMaterializerTests.swift Tests/RubienCoreTests/PDFDownloadServiceTests.swift
git commit -m "feat(core): materialize PDF and markdown import sources"
```

### Task 2: Shared PDF metadata and persistence coordinator

**Files:**
- Create: `Sources/RubienPDFKit/ImportedPDFMetadataResolver.swift`
- Create: `Sources/RubienPDFKit/PDFImportCoordinator.swift`
- Modify: `Sources/Rubien/Services/MetadataResolver.swift`
- Create: `Sources/RubienCore/Services/MetadataResolutionPipeline.swift`
- Create: `Tests/RubienPDFKitTests/PDFImportCoordinatorTests.swift`

**Interfaces:**
- `MetadataResolutionPipeline.resolve(seed:fallback:) async -> MetadataResolutionResult` owns the PDF-only DOI → ISBN → book-title → OpenAlex-title → seed-only decision sequence and its evidence/verification merge.
- `ImportedPDFMetadataResolver.resolve(url:extracted:) async -> MetadataResolutionResult` only builds the PDF seed/fallback then delegates to that Core pipeline; `MetadataResolver.resolveImportedPDF` delegates to this adapter.
- `PDFImportCoordinator.importPDF(from:database:resolver:) async throws -> PDFImportOutcome`, where the `resolver` parameter defaults to `ImportedPDFMetadataResolver.resolve` and `PDFImportOutcome` is `.imported(Reference)` or `.queued(MetadataIntake)`.

- [ ] **Step 1: Write failing coordinator tests**

Use a real fixture PDF plus injectable resolver closure/strategy to assert that a verified outcome creates/attaches a library PDF and an intake outcome leaves the copied PDF referenced by the pending intake. Assert a persistence failure deletes the copied permanent PDF but does not delete the caller-owned source file.

- [ ] **Step 2: Verify red**

Run: `swift test --filter PDFImportCoordinatorTests`

Expected: compile failure naming `PDFImportCoordinator`.

- [ ] **Step 3: Extract the imported-PDF resolver behavior**

Move only the imported-PDF resolution algorithm into `MetadataResolutionPipeline` in RubienCore. Keep manual-entry, refresh, candidate-selection, and app logging in `MetadataResolver`; make its `resolveImportedPDF` delegate through the RubienPDFKit adapter. Preserve all current evidence, fallback merge, candidate, blocked, rejected, and seed-only behavior.

- [ ] **Step 4: Implement the persistence coordinator**

Have the coordinator call `PDFService.prepareImportedPDF`, resolve metadata, and call `AppDatabase.persistMetadataResolution` with `.importedPDF` and the copied filename. Return `.imported`/`.queued`; delete only a copied permanent PDF when preparation succeeded but persistence throws. Do not delete an intake-backed PDF.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter PDFImportCoordinatorTests && swift test --filter MetadataResolverTests`

Expected: both suites pass.

```bash
git add Sources/RubienPDFKit Sources/Rubien/Services/MetadataResolver.swift Sources/RubienCore/Services/MetadataResolutionPipeline.swift Tests/RubienPDFKitTests/PDFImportCoordinatorTests.swift Tests/RubienTests/MetadataResolverTests.swift
git commit -m "feat(pdf): share imported PDF resolution across front doors"
```

### Task 3: CLI and MCP parity

**Files:**
- Modify: `Sources/RubienCLI/RubienCLI.swift`
- Modify: `Tests/RubienCLITests/SwiftLibCLITests.swift`
- Modify: `mcp-server/src/tools/io.ts`
- Modify: `mcp-server/test/import-tool.test.ts`
- Modify: `mcp-server/package.json`, `mcp-server/package-lock.json`, `mcp-server/src/server.ts`
- Modify: `Docs/CLI-Reference.md`, `mcp-server/README.md`

**Interfaces:**
- `Import` conforms to `AsyncParsableCommand`; a single `file` argument accepts all existing inputs plus a local PDF or direct HTTP(S) PDF/Markdown URL.
- PDF imports use `ImportSourceMaterializer` and `PDFImportCoordinator`; Markdown URLs use the existing parser/merge behavior from their materialized temporary file.
- PDF success output adds `status: "imported"`; a pending result adds `status: "queued"` and `intakeId`, while retaining `imported` and `file`.
- MCP retains its `file` field name and forwards it unchanged; its description explicitly says absolute host path or direct HTTP(S) URL.

- [ ] **Step 1: Write failing CLI and MCP tests**

Add CLI tests for a missing `.pdf` path yielding a JSON file-read error rather than “Unsupported file format,” plus a local Markdown path continuing to produce its unchanged envelope. Add MCP tests that inspect the tool schema and verify an HTTPS PDF URL is passed verbatim to `rubien-cli import`.

- [ ] **Step 2: Verify red**

Run: `swift test --filter RubienCLITests/testImportPDFPath` and `npm test -- --run test/import-tool.test.ts`

Expected: the CLI test fails because PDF is unsupported and the MCP schema test fails because URL wording is absent.

- [ ] **Step 3: Implement CLI routing**

Keep folder/stdin behavior synchronous and unchanged; make the command async only for the one-source materialization branch. Pass the CLI current directory as the local-path base. Defer temporary-source cleanup around Markdown parsing or the PDF coordinator. Post the library-change notification after any successful import or queued PDF intake.

- [ ] **Step 4: Update MCP and docs**

Update the MCP Zod tool copy, release patch version, package lock, server version, CLI reference examples/error contract, and README tool guidance. Do not add an MCP stdin route or a format override that bypasses URL-extension validation.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter RubienCLITests && npm test && npm run build`

Expected: all commands pass, and existing import output tests remain unchanged.

```bash
git add Sources/RubienCLI/RubienCLI.swift Tests/RubienCLITests/SwiftLibCLITests.swift mcp-server Docs/CLI-Reference.md
git commit -m "feat(cli): import PDF and markdown URLs"
```

### Task 4: App import sheet and batch integration

**Files:**
- Create: `Sources/Rubien/Views/ImportSourceSheet.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`
- Modify: `Sources/Rubien/Helpers/OpenPanelPicker.swift`
- Modify: `Sources/Rubien/Resources/en.lproj/Localizable.strings`
- Create: `Tests/RubienTests/ImportSourceSheetModelTests.swift`

**Interfaces:**
- `ImportSourceSheet` owns one typed string or staged `[URL]`; typing clears selection, choosing clears text, and `onImport([MaterializedImportSource])` receives valid source files.
- The existing `ContentView` batch coordinator accepts materialized inputs, routes Markdown through `MarkdownImporter` and PDFs through `PDFImportCoordinator`, and calls `cleanup()` after every branch.
- `OpenPanelPicker.pickImportableFiles()` remains the existing multi-select panel; it accepts `.pdf`, `.md`, and `.markdown`.

- [ ] **Step 1: Write failing sheet-state tests**

Test the pure state model behind the sheet: typing clears staged selections, choosing multiple files clears typed text, zero selection disables Import, and the summary uses a filename for one item versus an item count for many.

- [ ] **Step 2: Verify red**

Run: `swift test --filter ImportSourceSheetModelTests`

Expected: compile failure naming the sheet-state model.

- [ ] **Step 3: Build the sheet with existing hover styles**

Use the exact localized text-field prompt from the approved design. Apply `SLPrimaryButtonStyle` to Import and `SLSecondaryButtonStyle` to Choose… and Cancel so all three retain the repository’s animated hover and pressed states. Show inline errors while acquiring typed input; disable interaction and dismissal during acquisition; retain staged selection after a chooser cancel.

- [ ] **Step 4: Integrate the existing batch coordinator**

Replace the direct open-panel toolbar action with sheet presentation. Feed staged local files directly and typed URLs through the materializer. Refactor `importSinglePDF` to call `PDFImportCoordinator`; keep only progress/selection/pending-notice presentation in ContentView. Ensure every temporary materialized source is cleaned in a `defer`, including PDF failure, queued intake, and Markdown batch failure.

- [ ] **Step 5: Verify visual and automated behavior, then commit**

Run: `swift test --filter ImportSourceSheetModelTests && swift test --filter RubienTests && swift build`

Manual smoke test with a scratch library: open the sheet, verify hover/pressed states on Choose…, Cancel, and Import; stage multiple local files; import one `~/…` Markdown path; reject an HTML `.md` URL inline; import a direct PDF URL; confirm the resulting summary/pending queue and that no `RubienImport-*` temporary directory remains.

```bash
git add Sources/Rubien/Views/ImportSourceSheet.swift Sources/Rubien/Views/ContentView.swift Sources/Rubien/Helpers/OpenPanelPicker.swift Sources/Rubien/Resources/en.lproj/Localizable.strings Tests/RubienTests/ImportSourceSheetModelTests.swift
git commit -m "feat(app): add path and URL import sheet"
```

### Task 5: Final contract review and verification

**Files:**
- Modify only files required by review findings.

- [ ] **Step 1: Inspect the complete diff for source ownership and contract drift**

Run: `git diff main...HEAD --check && git diff main...HEAD --stat`

Expected: no whitespace errors; changes confined to the import flow, documented contracts, and tests.

- [ ] **Step 2: Run the complete verification matrix**

Run: `swift test && npm --prefix mcp-server test && npm --prefix mcp-server run build`

Expected: Swift and MCP suites pass with no new warnings attributable to this feature.

- [ ] **Step 3: Independent review and simplify sweep**

Request a medium-effort `codex-rescue` review of the uncommitted diff, return findings inline, decide which findings merit fixes, and run the repository’s three `/simplify` review lenses (reuse, quality, efficiency). Re-run the verification matrix after any edits.

- [ ] **Step 4: Commit final review fixes if needed**

```bash
git add -A
git commit -m "fix: polish import source flow"
```
