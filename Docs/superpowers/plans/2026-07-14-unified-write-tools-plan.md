# Unified Write Tools & `{op}_{target}` Catalog — Implementation Plan

**Date:** 2026-07-14 (v4 — three codex plan reviews: 12 → 7 → 4 findings [final round: no blockers]; all incorporated)
**Spec:** `Docs/superpowers/specs/2026-07-14-unified-write-tools-design.md` (Draft v6 — 4 codex review rounds; user-blessed 2026-07-14 incl. the 6 product calls + the `views_query`→`list_references {view}` fold).

**Shape (the review's core correction):** the old C→D ordering broke the repo between commits — every CLI removal orphaned the checked-in npm server, which still shells the removed argv. So the plan is now **additive phases → one atomic cutover commit**: A–C add every new capability while old forms keep working; D is the single commit that removes old surfaces *and* ships the npm catalog *and* bumps the build/version guards — the repo is never in a state where a checked-in component calls a missing surface. Same-stroke/lockstep, interpreted at repo scope.

## Phase 0 — Branch discipline

Create `unified-write-tools` off `main`; **first commit = the settled spec + this plan** (they're untracked — parallel worktrees branched from `main` wouldn't contain them). A/B may then run in parallel worktrees **branched from that commit**; both touch `AppDatabase.swift`, so merge order is stated up front: **A merges first, B rebases on A** and resolves. E is independent of D and may parallel it. Merge to `main` `--no-ff`, CI-gated (Linux CI is the only catcher for `os(macOS)` guards / CF imports).

## Phase A — RubienCore: the mutation engines (additive)

**Files:** `Sources/RubienCore/Database/AppDatabase.swift` (+ new `ReferenceEdit.swift`), `Tests/RubienCoreTests/`.

1. **Classification table** (spec §4.3): static structure mapping all 30 seeded `defaultFieldKey`s → `{class, clearable}`; conversions per spec (editors/translators via `encodeNames(parseList)`, accessedDate `YYYY-MM-DD` literal, year int, type/status validated). **Exhaustiveness test enumerates the spec's table** (intended class each), not just "something classified".
2. `ReferenceEdit` input model + pure payload-JSON decoding (`PropertyEntry = replace | addRemove | clear`).
3. **`applyReferenceEdit(id:edit:)`** — ONE `dbWriter.write`: resolve (digit=Int64-id w/ overflow error, exact name, duplicate-resolution error) → conflicts (post-canonicalization incl. `clearFields`) → validate (§4.4; non-nullable/read-only/unknown distinct errors) → apply (column setters, propertyValue upsert/delete, **Tags pivot diff** — never `setTags`) → one captured `now` on changed rows only; no-op = no write (ordered-exact for custom multiSelect, set for Tags).
4. **Combined property/option mutation APIs** (review #2 — current rename/visibility/option writes each own separate transactions, `AppDatabase.swift:3358,3390,3421`): new atomic `updatePropertyDefinition(id:name:visible:)` and `updatePropertyOption(propertyId:option:newName:color:)` (Tags recolor = Tag row; Type gate intact), each one transaction. **All-digit name guard lives in these Core paths** (and create), not CLI validation.
5. **Tests:** §9 validation matrix, resolution/conflict/error taxonomy, atomicity rollback, no-op/timestamp (unchanged tag set touches no pivots), editors round-trip, combined-mutation atomicity.

**Done:** `swift test --filter RubienCoreTests` green; zero CLI/app changes.
**Linux:** checkbox `true` vs `1` = CFBoolean type-id check → `#if canImport(CoreFoundation)` (precedent `MCPToolCatalog.swift`); CRLF-normalize any line parsing.

## Phase B — Import `ItemOutcome` plumbing (additive)

**Files:** `Sources/RubienCore/` + `Sources/RubienPDFKit/`, tests per below.

1. `ItemOutcome {reference: Reference?, disposition, intakeId?, input, error?}` in RubienCore (never CLI-private `ReferenceDTO`; Package.swift dependency direction confirmed by review).
2. **Pinned detailed signature** (review #5 — parsers return only `[Reference]`, so provenance must ride in): `batchImportReferencesDetailed(_ entries: [(input: String, reference: Reference)]) -> [ItemOutcome]` (or equivalent wrapper type), alignment precondition documented; **a batch-transaction failure THROWS** — the CLI catches and synthesizes the one-failed-item-per-parsed-entry representation. Existing aggregate signatures delegate; ~32 call sites untouched.
3. Zotero (root-`.bib` failure throws = source-level; `missingPDFs` stay diagnostics; provenance `<bib path>#bibtex[<ordinal>]`). **Markdown-folder outcomes are NOT Phase B** — that orchestration is CLI-private (`RubienCLI.swift:1243`), so its per-file outcome work lands in C2a where the code lives.
3b. **Detailed PDF result (additive):** `PDFImportOutcome`/`MetadataPersistenceResult` expose verified/queued but not created/existing — add a detailed variant carrying the full disposition while preserving the existing enum cases and app-facing call sites unchanged.
4. **Test placement** (review #6): PDF/Zotero outcome mapping extends the **existing Mac-gated files in `RubienCoreTests`** (`PDFImportCoordinatorTests.swift`, `ZoteroFolderImporterTests.swift`); pure batch-outcome tests (incl. intra-batch dup → two items one reference) go in a **non-gated** RubienCore test file so Linux CI runs them. `RubienPDFKitTests` (cross-backend parity target, no GRDB dep) is NOT the home.

**Done:** filtered tests green; behavior identical (reporting only).

## Phase C — CLI surface, ADDITIVE ONLY (three commits; old forms all still work)

**Files:** `Sources/RubienCLI/RubienCLI.swift`, `Docs/CLI-Reference.md` (additions documented same commit), `Tests/RubienCLITests/`.

**C1 — `update --properties` + the stderr-envelope helper:** JSON flag → `applyReferenceEdit`. Introduce one general "structured envelope → stderr" helper (review #4) and use it for `update`; **migrate the existing `properties` `unresolved-selectors` stdout-envelope path + its test** (`SwiftLibCLITests.swift:900` parses stdout today) to assert empty stdout + exact stderr fields. Old `properties --set/...` untouched.
**C2a — routing/envelope machinery, in RubienCore:** the import-routing engine (steps 0–3 incl. path-beats-DOI, registry, extension, implied-`downloadPdf`) and the items/summary/diagnostics envelope/outcome assembly are **RubienCore additions** (the URL registry and importers already live there; `RubienCLITests` is deliberately black-box with no `RubienCLI` target dep — adding one would pull poppler into Linux XCTest, the documented hang — so the machinery's unit tests live in `RubienCoreTests`, portable and Linux-covered). The CLI keeps only argv→engine glue. Also: tri-state `--download-pdf` via `@Flag(inversion: .prefixedNo)` (`--download-pdf`/`--no-download-pdf`/absent — bare spelling stays valid, so the checked-in npm server's bare-flag emission keeps working; no D-phase conversion needed), markdown-folder per-file outcome plumbing (Core-level preparation/result service — the v2-review's first option; the CLI-private orchestration migrates onto it), per-route failure semantics (inline per-entry `do/catch` continue; batch-throw → per-entry failed items; source-level synthetic item; zero-parsed-entries failure; all-failed envelope → stderr; exit nonzero iff zero succeeded) — wired behind **`add --source`** as a NEW flag. `--identifier`, `import`, old `add` envelope all still work (adapters preserve current external contracts).
**C2b — new-path tests (scoped to what the staged CLI can express):** the §9 routing matrix black-box via `--source` (`RubienCLITests`), plus the envelope/outcome machinery unit tests in **`RubienCoreTests`** (inline-BibTeX continuation, failed items, title provenance — these routes aren't `--source`-reachable and their public envelopes don't flip until D; Core placement is what makes them testable pre-cutover). The **black-box `--bibtex`/`--title` unified-envelope activation + matrix moves to D** (their old envelopes can't represent failed items, so activation is inherently a cutover change).
**C3 — `properties --update` / `--update-option` / `list --view` (new modes):** thin CLI over Phase-A combined APIs (`--set-visible`, `--option/--to/--color`); `list --view <id>` (mutually exclusive with inline filters). Old `--rename/--show/--hide/--rename-option/--from` and `views --query` still work.

**Done per commit:** `swift build` + `swift test --filter RubienCLITests` green (never bare `swift test` — hangs on RubienCLITests). Repo-wide green is real: npm server still shells only old forms, which all still exist.

## Phase D — THE CUTOVER (one atomic commit)

Everything that breaks old surfaces, together, so no checked-in component ever calls a missing one:

1. **CLI removals + rejection tests:** `properties --set/--add-value/--remove-value/--clear/--rename/--show/--hide/--rename-option/--from`; `add --identifier`; `import` subcommand; `views --query`; **unified-envelope activation on `--bibtex`/`--title`** (replacing their old envelopes) + their black-box matrix tests (deferred from C2b).
2. **npm server → 27-tool catalog** (grid names, payload/`source`/`view` passthrough, `clearFields`, `readingStatus` free string, `create_reference` `destructiveHint:false` + 300 s timeout, numeric ids), **raw stderr-envelope pass-through** (replace `cli.ts` `{"error"}`-extraction) + exact-field test, tri-state `downloadPdf` emission, count/registration tests.
3. **Version cutover** (review #1 — guards and build move together, not in F): bump `BUILD.txt`, regenerate `GeneratedVersion.swift`, `MIN_CLI_BUILD` → that build, `package.json` 0.3.0 + both lock versions + `SERVER_INFO`, `versionGuard.test.ts`/`guard-startup.test.ts` stubs, README deprecation prose → `<0.3.0`.
4. **e2e gate that cannot silently skip — as a checked-in CI job**, not a local convention (today `ci.yml` has only Swift jobs; the whole cutover could merge with the gate never running): new workflow job **pinned to the existing Linux job's environment** (`swift:6.3-jammy` container + its poppler/cairo/gdk-pixbuf dependency install steps — a fresh Ubuntu runner has neither Swift 6.3 nor the system libs, so an unpinned job fails before reaching npm) + Node setup, `npm ci`, `swift build --product rubien-cli`, `npm run build`, `npm test` with isolated `RUBIEN_LIBRARY_ROOT`, and an assertion that the write-route suite executed (fail, never skip).
5. **Docs sweep — npm/CLI-owned only** (ownership split resolves the D/E ordering ambiguity; each phase documents its own component, so D and E can land in either order): CLI-Reference removals + migration tables (`old → new` for every removed form); `Docs/Supported-Paper-URLs.md`; `.github/workflows/linux-cli-release.yml` smoke; `AGENTS.md`/`README.md` subcommand counts; npm tool-description cross-links. Retain: historical specs, immutable session fixtures, both-generation attribution tests.

## Phase E — Native catalog + assistant touchpoints (ONE commit; parallel with D)

The app and its bundled server ship together — renaming the native tools while the seed still teaches old names (or vice versa) would break the assistant between commits, so these co-commit:

1. **Native `rubien-cli mcp`:** rename the 8 read tools in `MCPToolCatalog.swift`; **`list_references` gains the `view` field + argv passthrough** (`--view <id>`; inline-filter-conflict + npm-parity tests — the contract requires `view` in BOTH catalogs); `readingStatus` free string; raw-stderr preservation in `MCPServer.swift` with a **test seam** (review #9 — inject the child executable/stub so an exact fabricated `error/ids/names` envelope test exists alongside a black-box read-failure test; the 8 content reads never naturally emit the multi-field envelope).
2. **Assistant seed** (`AssistantContext.swift:72` + tests): `rubien_get`→`get_reference`, `rubien_pdf_page_image`→`render_pdf_page`, `rubien_search`→`search_references`.
3. **Native/assistant docs + active names** (E-owned half of the sweep): native tool-description cross-links, assistant/renderer/harness fixtures that exercise live tool names.
4. **`ReferenceAttribution`:** old-generation rules verbatim (existing tests pass unmodified) + old `views_query` joins never-attribute (latent-bug fix); new-generation table (`update_reference` → top-level `id` only w/ payload-trap test; `delete_reference`/`cite` ids; property/option/view CRUD never-attribute).

**Files:** `Tests/RubienTests/` files all `#if os(macOS)`-guarded. **Verification runs BOTH suites:** `swift build --product rubien-cli` then `swift test --filter RubienCLITests` (the native MCP catalog/server tests live there and silently skip when the executable is absent — `MCPServerTests.swift:39`), plus `swift test --filter 'RubienTests\..*'` (bare `RubienTests` runs 0 tests).

## Phase F — Release (user-driven, interactive host)

Verify (not introduce) the D version values; then **commit the version bump before invoking the script** (`release.sh` rejects a dirty tree): edit `VERSION` → 0.4.0 (breaking surface), regenerate `GeneratedVersion.swift`, commit both on clean `main` (D's `BUILD.txt` value retained), then `./scripts/release.sh` per runbook (fresh `RELEASE_NOTES_TEXT` as `$'…'`, `CODESIGN_IDENTITY` exported); Linux CLI workflow; **npm publish 0.3.0 + `npm deprecate rubien-mcp-server@"<0.3.0"`** after CLI assets exist; npx smoke against the new build.

## Cross-cutting

- **Review cadence:** codex-rescue + `/simplify` per phase pre-commit. Effort: `--effort high` per the user's standing rule (2026-07-12, current codex 0.144.x — 5 clean high-effort runs this feature), dropping to medium on stall; AGENTS.md's blanket-medium guidance predates this and should be updated separately (review #12 noted the conflict).
- **Execution mode:** decide per phase at kickoff — inline vs subagent-driven (Opus/medium implementer+reviewer) for A–C.
- **Out of scope (tracked in spec):** Phase 4 proper (native write registration + approval + name-based `isSilentReadTool`), parser diagnostics, remote `.bib`/`.ris` URLs, `update_view` filters, stdout-envelope audit of untouched commands.

## Requirement-level traceability (review #11 — replaces the section-level table)

| Requirement (spec ref) | Phase |
|---|---|
| Classification table + exhaustiveness test (§4.3) | A |
| Payload resolution/validation/conflicts/atomicity/timestamps (§4.2–4.5) | A |
| Combined property/option atomic mutations + all-digit guard in Core (§6, §4.2) | A |
| `ItemOutcome` + pinned detailed signature + throw-on-batch-failure (§5.3) | B |
| Zotero outcome mapping + test placement (§5.3) | B |
| `update --properties` CLI + stderr helper + stdout-test migration (§4.1, §4.6, §4.7) | C1 |
| `add --source` routing incl. path-precedence/implied-downloadPdf/tri-state inversion pair (§5.1–5.2) | C2a |
| Markdown-folder per-file outcomes (CLI-private orchestration) (§5.3) | C2a |
| Unified envelope machinery + `--source` black-box + internal route tests (§5.3–5.4) | C2a/C2b |
| `--bibtex`/`--title` unified-envelope activation + black-box matrix (§5.4) | D |
| Detailed PDF persistence result preserving app-facing cases (§5.3) | B |
| `properties --update` / `--update-option` / `list --view` CLI modes (§6, §3) | C3 |
| Every old-form removal + rejection test (§4.7, §5.5, §6, §3) | D |
| npm 27-tool catalog + annotations + timeout + tri-state emission (§3, §5.1) | D |
| Raw stderr-envelope pass-through, npm + exact-field test (§4.6) | D |
| Version cutover: BUILD/GeneratedVersion/MIN_CLI_BUILD/0.3.0/guard stubs (§8) | D |
| Non-skippable write-route e2e **as a checked-in CI job** (§9) | D |
| Docs sweep: CLI-Reference migration tables, registry doc, CI smoke, counts (§8) | D |
| Tool-description cross-links (column/cell + one-door triangles) (§3) | D (npm) / E (native) |
| Native read renames + `list_references{view}` parity + readingStatus string + stderr seam tests (§8, §3, §4.6) | E |
| Active harness/renderer/assistant fixture name sweep (§8) | E |
| Seed migration (§7) | E |
| Attribution: both generations + old `views_query` fix + payload trap (§7) | E |
| Exactly-one-input + `"-"` MCP rejection + route-option rejection (§5.1) | C2a (CLI) / D (schema) |
| Release + publish + deprecate (§8) | F |
