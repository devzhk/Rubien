# Unified Read Tools (`rubien_read_text` / `rubien_read_annotations`) — Design Spec

**Date:** 2026-07-11
**Status:** Draft for review
**Context:** Feature 1 of a two-feature arc. Feature 2 (unified body-text grep, `rubien_grep_text`) builds on the routing and conventions established here; its earlier PDF-only draft is `Docs/superpowers/specs/2026-06-26-pdf-grep-design.md`, to be revised separately.

## 1. Motivation

The MCP surface forks every document read by storage kind: `rubien_pdf_text` vs `rubien_web_get` for body text, `rubien_annotations_list` vs `rubien_web_annotations` for annotations. An agent that just wants "the text of reference 42" must first detect the kind (call `rubien_get`, inspect `pdfPath` / `siteName`) or guess and burn a turn on a "has no web content" error. In practice the agent does not care where the bytes live.

This feature replaces the four kind-specific MCP tools with two kind-agnostic ones. Kind routing moves into the CLI (single source of truth for both MCP servers). The four kind-specific CLI subcommands are **removed in the same stroke** — a deliberate breaking change at this alpha stage (two test users; the npm server upgrades in lockstep) that keeps one clean read surface instead of two generations of it.

## 2. Goals / Non-goals

**Goals**
- One MCP tool returns the body text of *any* reference (PDF or clipped web page); one returns its annotations.
- Preserve each kind's native addressing: structural (`pages`/`sections`) for PDFs, character-offset (`start`) for web bodies. No lossy common denominator.
- Routing implemented once, in Swift, behind the new CLI subcommands; both MCP servers (npm `rubien-mcp-server` and `rubien-cli mcp`) stay thin and in lockstep.
- Remove the superseded kind-specific CLI subcommands (`pdf text`, `web get`, `annotations`, `web annotations`) — the `read` family becomes the only body/annotation read surface.
- Deterministic behavior for references that have **both** a PDF and web content.
- Existing envelope fields keep their exact names and semantics so agent knowledge (and our docs) transfer.

**Non-goals**
- No merge of the genuinely PDF-only tools (`rubien_pdf_info`, `rubien_pdf_page_image`, `rubien_pdf_download`, `pdf status`).
- No body-text search (that is feature 2), no OCR, no annotation writes, no app-UI changes.
- No multi-reference reads. One reference per call.

## 3. Tool surface changes

### MCP (both catalogs: `mcp-server/src/tools/*.ts` and `Sources/RubienCLI/MCPToolCatalog.swift`)

| Action | Tool | Notes |
|---|---|---|
| **Remove** | `rubien_pdf_text` | replaced by `rubien_read_text` |
| **Remove** | `rubien_web_get` | replaced by `rubien_read_text` |
| **Remove** | `rubien_annotations_list` | replaced by `rubien_read_annotations` |
| **Remove** | `rubien_web_annotations` | replaced by `rubien_read_annotations` |
| **Add** | `rubien_read_text` | body text of any reference |
| **Add** | `rubien_read_annotations` | annotations of any reference, both kinds merged |

Registered tool count: 36 → 34. MCP tools are discovered dynamically per session, so their removal does not break configured clients. The CLI removal below *does* break the already-published `rubien-mcp-server` 0.1.x (it shells the removed argv) — accepted at alpha: 0.2.0 publishes in the same release, and 0.1.x gets `npm deprecate rubien-mcp-server@"<0.2.0"` pointing at the upgrade.

Surviving tool descriptions that cross-reference removed names are updated in the same commit: `rubien_pdf_info` ("call this before `rubien_read_text` when you plan to use `sections`…"), `rubien_pdf_page_image` (fallback guidance), and any other hits from the repo-wide sweep (§10). Naming note: the unified tools take `id` (matching `rubien_get` / `rubien_pdf_*`), retiring the `referenceId` spelling the web/annotations tools used.

### CLI (replacement)

New top-level parent `read` with two children (a parent: it mirrors the MCP pair's naming and gives the kind-agnostic read surface — which feature 2 extends — one home):

```
rubien-cli read text <id> [--pages <range>] [--section <title>]... [--start <offset>]
                          [--max-chars <n>] [--source pdf|web]
rubien-cli read annotations <id> [--source pdf|web]
```

Both print JSON to stdout like every other subcommand.

**Removed subcommands:** `pdf text` (the `pdf` parent keeps `info`, `page-image`, `status`, `download`), the entire `web` parent (`web get` + `web annotations` were its only children), and top-level `annotations`. Their `RubienCLITests` are deleted with them; behavioral coverage migrates to the `read` equivalents (§9). `Docs/CLI-Reference.md` deletes their sections, gains the `read` section, and swaps the MCP↔CLI mapping rows, all in the same commit (lockstep rule).

## 4. Routing semantics

**Availability** is resolved from the library, per source:

- `pdf` has four states, so error messages can say *why* a PDF isn't readable: `notAttached` (no `pdfCache` row), `notMaterialized` (cache row exists but `materializedAt` is NULL — attached in the library, not fetched to this device), `missingFile` (materialized but the file is absent on disk), `available`. Only `available` is readable. Note: `AppDatabase.pdfFilename(for:)` alone cannot produce these states (it filters `materializedAt IS NOT NULL`, `AppDatabase.swift:1322-1328`, collapsing the first two states); the probe derives them from the same signals `pdf status` already surfaces (cache-row presence, `materializedAt`, file existence).
- `web` is available ⇔ the reference exists and `decodedWebContent` is non-nil (same check `web get` performs today). Content that decodes to nil — including whitespace-only or marker-only bodies — counts as **unavailable** and takes the §8 error path; there is no "success with empty body" state.

**Source selection (read text),** in order:

1. Explicit `source` param wins. Requesting a source that is not available is an error (naming the PDF state where relevant).
2. Otherwise, kind-scoped params imply the source: `pages`/`sections` → `pdf`; `start` → `web`. The implied source must be available, else error. Passing params from both families together (e.g. `pages` + `start`) is an error.
3. Otherwise (no source, no kind-scoped params): **PDF wins** when both are available — the attached paper is normally the primary artifact; the clip is often a landing page.

Neither source available is an error whose message says *why* per source (e.g. "no web content; PDF attached but not materialized on this device — see `pdf status`").

**Transparency:** every `read text` response carries
- `source` — `"pdf"` or `"web"`, whichever was actually read;
- `available` — the array of currently readable sources (`["pdf"]`, `["web"]`, or `["pdf","web"]`),

so an agent always sees that another body exists and can flip with `source`.

**Annotations need no precedence:** the default result is the union of both kinds in one array, each item tagged with `source`. `--source` filters to one kind.

## 5. `read text` contract

### Parameters

| Param | Applies to | Semantics |
|---|---|---|
| `id` (required) | — | reference id |
| `source` | both | `"pdf"` \| `"web"`; overrides PDF-wins precedence |
| `maxChars` | both | default 50 000; unified bound **1–500 000 enforced in the CLI** (single source of truth; the Node zod schema repeats the bound, the Swift catalog advertises it — a deliberate unification: today only the PDF tool caps at 500 000 and the web tool is uncapped). PDF truncates at page boundaries and always returns at least the first selected page, so returned characters can exceed `maxChars` when a single page does (existing `PDFExtractor` behavior, now documented); web truncates at the character boundary |
| `pages` | PDF only | range string `"1-3,8-10"`, `"12-"` — exactly `pdf text --pages` |
| `sections` | PDF only | repeatable title substrings — exactly `pdf text --section`; still mutually exclusive with `pages`; still errors `no-outline` when the PDF has no outline |
| `start` | web only | character offset, default 0 — exactly `web get --start`; past end-of-content returns `content:""`, `truncated:false` |

**Validation:** with the §4 inference rule, a kind-scoped param can only conflict with the *resolved* source when the caller passed an explicit contradicting `source` — e.g. `source:"web"` + `pages` → error `"pages/sections require a PDF source (requested source: web; available: [\"web\"])"`; `source:"pdf"` + `start` errors symmetrically. Mixing param families (`pages`/`sections` + `start`) is an error regardless of `source`. Nothing is ever silently ignored, and error text includes the resolved/requested source, `available`, and the PDF state when relevant, so the agent self-corrects in one turn.

### Envelopes

The old shapes are reused verbatim per kind, plus the two new routing fields. PDF-source response (= `PdfTextOutput` + `source`/`available`):

```json
{ "id": 42, "source": "pdf", "available": ["pdf", "web"],
  "pageCount": 12, "selection": { "mode": "page", "pages": "1-3" },
  "pages": [ { "index": 1, "text": "…", "sectionPath": ["1 Introduction"] } ],
  "truncated": false, "hasTextLayer": true }
```

Web-source response (= `WebGetOutput` + `source`/`available`):

```json
{ "id": 7, "source": "web", "available": ["web"],
  "url": "https://…", "siteName": "…", "contentFormat": "markdown",
  "content": "…", "contentLength": 84213, "start": 0,
  "returnedChars": 50000, "truncated": true, "annotationCount": 3 }
```

## 6. `read annotations` contract

**Parameters:** `id` (required), `source` (optional filter, `"pdf"` \| `"web"`).

**Output:** a JSON array. Every item carries the common fields `source`, `id`, `type`, `color`, `noteText?`, `dateCreated`, `dateModified`; kind-specific anchor fields are present only on their kind and omitted otherwise (`encodeIfPresent`, the established DTO pattern):

- `source:"pdf"` items add `pageIndex`, `selectedText?` (from `PDFAnnotationRecord`; dates exist on the record — including them is additive relative to the old `annotations` DTO, which omitted them).
- `source:"web"` items add `anchorText`, `prefixText?`, `suffixText?` (the W3C TextQuoteSelector triple, as today; the description keeps the guidance that the triple locates the highlight inside the `read text` web body).

**Ordering (deterministic):** PDF items first, sorted by `(pageIndex, id)`; then web items sorted by `(dateCreated, id)`. This sort is applied **explicitly in the new subcommand's DTO layer** — the reused queries order differently today (PDF by `pageIndex, dateCreated`, `AppDatabase.swift:2607-2613`; web by `dateCreated` only) and neither tie-breaks on `id`.

**Empty-array semantics:** a missing reference or a reference with no annotations of the requested kind(s) returns `[]`, not an error — matching *both* existing tools (`annotations` has no not-found guard; `rubien_web_annotations` documents "not an error").

## 7. Implementation shape

- **RubienCLI:** new `Read` parent + `ReadText` / `ReadAnnotations` subcommands; the old subcommand structs (`PdfText`, `WebGet`, `Annotations`, `WebAnnotations`, the `Web` parent) are deleted. Their extraction bodies *move* rather than being rewritten: the PDF path keeps calling `PDFExtractor.extractText` exactly as `PdfText.run` does today; `WebGet`'s slice logic (offset/window/truncated computation, `RubienCLI.swift:2611-2631`) and both annotation DTO mappings relocate into the `read` subcommands.
- **Availability probe:** one small helper resolves per-reference source state — PDF as the §4 four-state enum (with the URL when `available`), web as available/unavailable — plus the derived `available` array, ordered `["pdf","web"]` (pinned). Feature 2's `grep` reuses it.
- **Node `mcp-server`:** new `src/tools/read.ts` registering both tools (argv → `read text …` / `read annotations …`); `web.ts` and `annotations.ts` deleted; `pdf.ts` drops the `rubien_pdf_text` registration; `server.ts` registration list updated. `schemas.ts` DTO mirrors: the two read-text envelopes and the source-tagged annotation-item union are **newly introduced** mirrors (today `schemas.ts` holds only a permissive PDF-shaped `AnnotationDTO`, `schemas.ts:155-162` — no `PdfTextOutput`/`WebGetOutput` mirrors exist to remove); pin optionality exactly: `source`/`id`/`type`/`color`/`dateCreated`/`dateModified` required on every item, anchor fields optional by kind.
- **Swift `MCPToolCatalog`:** the four removed entries replaced by two new `MCPTool`s whose `buildArgv` emits the same `read …` argv the Node server uses; cross-argument validation stays in the CLI (catalog convention, `MCPToolCatalog.swift:6-14`).
- **versionGuard:** the guard gates on the **monotonic build number**, not the marketing version (`MIN_CLI_BUILD` in `versionGuard.ts`, currently 19; there is no `MIN_CLI_VERSION`). Implementation: bump `BUILD.txt` 19 → 20 as the build that ships `read`, set `MIN_CLI_BUILD = 20`, and bump the npm package to **0.2.0** in `package.json` + `package-lock.json` + the server's advertised `SERVER_INFO` version together (tool removals; absorbs the unpublished 0.1.2). The `VERSION` marketing string (currently 0.2.3) is untouched by the guard. The guard only enforces server→CLI minimums, not the reverse, so published 0.1.x servers *run* against the new CLI and fail at call time on the removed argv — accepted (§3); the `npm deprecate` of 0.1.x is the pointer out.
- **Assistant seed prompt:** `AssistantContext.seed` (`Sources/Rubien/Assistant/AssistantContext.swift:70-73`) currently instructs the sidebar agent to use three of the removed tools by name — rewrite it to name `rubien_read_text` / `rubien_read_annotations` (keeping `rubien_get`, `rubien_pdf_page_image`, `rubien_search`), which also lets the seed stop teaching kind-routing.

## 8. Error handling

| Condition | `read text` | `read annotations` |
|---|---|---|
| Reference not found | error `"Reference N not found"` | `[]` |
| Neither source available | error naming the per-source reason (no web content / PDF notAttached / notMaterialized / missingFile) | `[]` |
| `source` (explicit or param-implied) unavailable | error incl. `available` + PDF state when relevant | `[]` (explicit filter over nothing) |
| Explicit `source` contradicts a kind-scoped param | error incl. requested source + `available` | n/a |
| Param families mixed (`pages`/`sections` + `start`) | error | n/a |
| `start` on a both-available ref, no `source` | **not an error** — implies `source:"web"` (§4 rule 2) | n/a |
| `pages` + `sections` together | error (existing rule, kept) | n/a |
| `sections` on outline-less PDF | `no-outline` error (existing, passes through) | n/a |
| `start` past end of web body | success, `content:""`, `truncated:false` (existing) | n/a |
| `maxChars` out of bounds | CLI rejects outside 1–500 000 (Node zod schema repeats the bound) | n/a |
| Invalid `--source` value | argument-parse error (enum) | same |

## 9. Testing

- **RubienCLITests** (contract tests against the built binary): the removed subcommands' tests are deleted with them; every *behavior* they pinned (page/section selection, web windowing, annotation DTOs) must reappear as a `read` test below before this feature merges. `read text` on a PDF-only ref, a web-only ref, a both-ref (PDF wins + `--source web` override), neither (error text), missing ref, `--pages`/`--section`/`--start`/`--max-chars` pass-through, each misapplied-param error. Plus, per the review findings:
  - **`available` pinned exactly** (value *and* `["pdf","web"]` ordering) in every successful envelope and in requested-unavailable error payloads, across PDF-only / web-only / both / missing-file cases.
  - **Non-materialized PDF states:** a ref with a `pdfCache` row but NULL `materializedAt` — alone (error names `notMaterialized`) and with web content (default routes to web; `--source pdf` errors with the state); a materialized row whose file was deleted (`missingFile`).
  - **Param-implied source:** `--start` on a both-ref → web; `--pages` on a both-ref → pdf; `--pages --start` together → error; `--start` on a PDF-only ref → error naming web unavailable.
  - **`maxChars` semantics:** ≤ 0 rejected; web truncation at the exact character boundary; PDF page-boundary truncation including the first-page-exceeds-`maxChars` overshoot case.
  - `read annotations`: pdf-only / web-only / both (explicit `(pageIndex,id)` then `(dateCreated,id)` ordering incl. equal-page and equal-date ties) / `--source` filter / missing ref → `[]`. Reuses the existing PDF fixtures and web-content seeding harness.
- **MCPServerTests** (Swift): catalog contains the two new tools and none of the four removed; argv construction for every param of both tools.
- **mcp-server vitest:** `server.test.ts` registration list; `schemas.test.ts` pins the new DTO mirrors (both read-text envelopes, both annotation-item variants, incl. the 1–500 000 `maxChars` schema bound); e2e-stdio smoke updated if it names tools.
- **Sweep (manual, pre-merge):** `rg "rubien_pdf_text|rubien_web_get|rubien_annotations_list|rubien_web_annotations"` across the repo, plus a second sweep for invocations of the removed subcommands (`pdf text`, `web get`, `web annotations`, bare `annotations`) in `scripts/`, `Docs/`, and `mcp-server/`, then **classify every hit**: production/doc sites must migrate (known today: `AssistantContext.seed`, `ChatSidebarHarness.swift:44-46`, `mcp-server/README.md`, `Docs/CLI-Reference.md`, surviving tool descriptions); test fixtures that use the names as opaque payload (`ClaudeSessionStoreTests.swift`, `CodexAppServerProtocolTests.swift`) are whitelisted as historical unless trivially updatable; historical documents (CHANGELOG, old specs) stay.

## 10. Docs (same commit)

- `Docs/CLI-Reference.md`: new `read` section (synopsis, flags, JSON shapes, error modes, the source-selection rules); the four removed subcommands' sections deleted; MCP mapping table rows swapped.
- `mcp-server/README.md`: tool-catalog table rows (§128-138 today) collapse the "PDFs"/"Web clips" read entries into the unified pair; prose paragraphs updated.
- Tool descriptions themselves are documentation for agents: each new tool's description names its sibling (`read_text` ↔ `read_annotations`), the PDF-wins rule, `available`, and — once feature 2 lands — `rubien_grep_text` as the "find where" counterpart.

## 11. Relation to feature 2 (unified grep)

`rubien_grep_text` (CLI name pinned in that spec) answers "*where* does the body say X" — pattern in, page/section-anchored snippets out — and composes with `read_text` for the actual reading. It reuses this feature's availability probe, PDF-wins + `source` override, and `available` field. The 2026-06-26 PDF-only draft is superseded accordingly; nothing named `rubien_pdf_search` ever ships.
