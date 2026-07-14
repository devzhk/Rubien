# Unified Write Tools & `{op}_{target}` Catalog — Design Spec

**Date:** 2026-07-14
**Status:** Draft v6 — v5 + the `views_query`→`list_references {view}` fold (user, 2026-07-14; output shapes verified identical) and the old-`views_query` attribution latent-bug fix. Codex-reviewed four times (v1: 20 findings / v2: 18 / v3: 9 / v4: 5, converging); all incorporated. The v4 pass confirmed the §4.3 seed table clean (all 30 names/keys/types) and §§4.4–4.5 internally consistent; v5 pins the last §5.3 reporting semantics (per-input item cardinality, inline-BibTeX continue [deliberate change], Zotero missing-PDF-as-diagnostic, source-level synthetic failures, npm-only write-route tests).
**Context:** Follow-up to the unified read tools (`880ddc6`, spec 2026-07-11) and precursor to Assistant Phase 4 (library writes behind the approval card). This spec consolidates the write surface and completes the catalog-wide naming migration so Phase 4 mirrors a clean, final contract into the native `rubien-cli mcp` server instead of porting 12 `properties_*` tools and consolidating later.

## 1. Motivation

Four problems, one stroke:

1. **The write surface is 20 tools, 12 of them `rubien_properties_*`.** The CLI already unifies them under one flag-dispatched `properties` subcommand; the MCP layer re-explodes it into flat tools. Several are the same operation differing only by a mode (`set`/`add_values`/`remove_values`/`clear`; `hide`/`show`).
2. **Editing a cell is split across two tools by an implementation detail.** Column-backed built-ins are edited via `rubien_update`; custom properties via `rubien_properties_set` — and the latter *refuses* the former with a "use update" error (`RubienCLI.swift:1611`). The agent can't see why; the model is one operation: *edit a cell of a row*.
3. **Getting a paper *into* the library has two doors** — `add` (identity in) vs `import` (artifact in) — forking on input form, and the fork leaks: a PDF URL is accepted by both with different pipelines, forcing agent-side routing by description prose.
4. **The catalog carries three naming generations**: bare verbs (`add`, `get`), noun-first (`properties_set`, `views_query`), and verb-first (`read_text`, `grep_text` — the newest, from the read unification).

The fix is the database model the app itself presents: everything is **{create | update | delete} × {property (column) | option | reference (row) | view}**, named `{op}_{target}`, with per-reference property values folded into `update_reference` as a cell payload (the Notion `PATCH page` shape) and `import` folded into `create_reference` (one door in, routing in the CLI). Reads sweep to the same convention in the same release — one naming generation, one breaking change, at alpha (two test users; npm server upgrades in lockstep — same posture as the read unification).

## 2. Goals / Non-goals

**Goals**
- One predictable grid: `{create,update,delete}_{property,option,reference,view}` — an agent can guess any tool's name.
- One door for cell edits: `update_reference` accepts built-in *and* custom property values; the built-in/custom seam disappears from the tool surface.
- One door into the library: `create_reference` takes any input form (identifier / URL / file / folder / BibTeX / title); routing lives in the CLI.
- Merge same-operation tools: value ops (4→0, folded into `update_reference`), `hide`/`show`/`rename` (3→1 `update_property`), option rename (+ new recolor) → `update_option`, `import` → `create_reference`.
- Full catalog rename to `{op}_{target}` (35 → 27 tools), including reads.
- Routing/validation stays in the CLI (single source of truth for both MCP servers); MCP wrappers remain thin 1:1 argv shells.
- Structured CLI error envelopes actually reach MCP callers **verbatim** (today they are lost on nonzero exit — §4.6).
- No information loss vs today's outputs: the unified `create_reference` envelope carries the full reference DTOs and every route diagnostic current outputs expose (§5.4).
- History attribution (`ReferenceAttribution`) recognizes **both** naming generations — old session files are immutable and keep old tool names forever.
- Both catalogs in lockstep: npm `rubien-mcp-server` ships the full contract now; the native `rubien-cli mcp` read-only catalog renames its 8 read tools now.

**Non-goals**
- **No write tools in the native `rubien-cli mcp` catalog yet** — that is Phase 4 (approval-card wiring); this spec finalizes the contract Phase 4 mirrors.
- No CLI subcommand *renames*. The CLI keeps its flag idiom; capability changes only (`update --properties`, `add --source`, `properties --update`/`--update-option`, value-write flags removed) plus one subcommand *removal* (`import`, absorbed by `add`).
- No tag auto-creation by label in the cell payload (Tags values stay stable stringified tag ids; create via `create_option` first).
- No `update_view` beyond rename (filters/columns/sorts editing is future work; see the duplicate-view shallow-copy gap).
- No bulk/multi-reference update; one row per `update_reference` call.
- No remote `.bib`/`.ris` URL acquisition (v1): file URLs are PDF/Markdown only, matching the existing materializer (`ImportSourceMaterializer.swift:268`); remote BibTeX/RIS is a possible follow-up.
- No BibTeX parser diagnostics (v1): the parser silently skips malformed entries today (`BibTeXImporter.swift:27`); surfacing skip diagnostics is a follow-up, documented as a known limit in the tool description.
- No changes to synced *schema* — no new tables/columns/CKRecord fields. (Timestamp *behavior* is tightened in §4.5.)

## 3. Tool surface — the grid

### Writes (13 tools; was 20) — 12 in the grid + 1 non-grid (`download_pdf`)

| Target | create | update | delete |
|---|---|---|---|
| **property** (column) | `rubien_create_property` — name, type, options | `rubien_update_property` — name and/or visible | `rubien_delete_property` |
| **option** | `rubien_create_option` — value, color | `rubien_update_option` — name and/or color | `rubien_delete_option` — replaceWith / clearInUse |
| **reference** (row) | `rubien_create_reference` — **one door**: identifier, URL, file, folder, BibTeX, title (§5) | `rubien_update_reference` — metadata fields + `properties` cell payload (§4) | `rubien_delete_reference` |
| **view** | `rubien_create_view` | `rubien_update_view` — rename | `rubien_delete_view` |

Plus one non-grid write (unique verb, no target suffix needed): `rubien_download_pdf` (was `pdf_download`) — fetches/attaches a PDF to an *existing* reference, so it is not a create form. `rubien_import` is **absorbed into `create_reference`** (§5).

### Full rename map (all 35 current tools)

| Current (0.2.0) | New | Notes |
|---|---|---|
| `rubien_add` | `rubien_create_reference` | absorbs `import`; gains `source` locator (§5) |
| `rubien_import` | — | folded into `create_reference` (§5) |
| `rubien_update` | `rubien_update_reference` | gains `properties` payload (§4); `clearField` → `clearFields` (breaking field rename, §4.1) |
| `rubien_properties_set` | — | folded into `update_reference` |
| `rubien_properties_add_values` | — | folded (payload `{"add": [...]}`) |
| `rubien_properties_remove_values` | — | folded (payload `{"remove": [...]}`) |
| `rubien_properties_clear` | — | folded (payload `null`) |
| `rubien_delete` | `rubien_delete_reference` | |
| `rubien_pdf_download` | `rubien_download_pdf` | |
| `rubien_properties_create` | `rubien_create_property` | + rejects all-digit names (§4.2) |
| `rubien_properties_rename` | `rubien_update_property` | merged: `name` field |
| `rubien_properties_hide` / `_show` | `rubien_update_property` | merged: `visible` field |
| `rubien_properties_delete` | `rubien_delete_property` | |
| `rubien_properties_add_option` | `rubien_create_option` | |
| `rubien_properties_rename_option` | `rubien_update_option` | + new optional `color` (§6) |
| `rubien_properties_delete_option` | `rubien_delete_option` | |
| `rubien_views_create` | `rubien_create_view` | |
| `rubien_views_rename` | `rubien_update_view` | |
| `rubien_views_delete` | `rubien_delete_view` | |
| `rubien_get` | `rubien_get_reference` | |
| `rubien_list` | `rubien_list_references` | `readingStatus` filter enum → free string (§4.4 note) |
| `rubien_search` | `rubien_search_references` | |
| `rubien_properties_list` | `rubien_list_properties` | |
| `rubien_views_list` | `rubien_list_views` | |
| `rubien_views_query` | — | folded into `list_references` (`view` param — same operation, identical output shape: "`--query` emits a reference array (same shape as `list`/`search`)") |
| `rubien_styles_list` | `rubien_list_styles` | |
| `rubien_pdf_info` | `rubien_get_pdf_info` | |
| `rubien_pdf_page_image` | `rubien_render_pdf_page` | |
| `rubien_sync_status` | `rubien_get_sync_status` | |
| `rubien_read_text` / `rubien_read_annotations` / `rubien_grep_text` | unchanged | already `{op}_{target}` |
| `rubien_cite` / `rubien_export` | unchanged | unique verbs, unambiguous |

Count: 35 → 27 (−4 value ops, −2 hide/show/rename merge, −1 import fold, −1 views_query fold). Naming rule, stated once for future tools: **grid (CRUD) operations always take the target suffix; a bare verb is allowed only when the operation is unique in the catalog and its target is unambiguous** (`cite`, `export`). Verb choice locked: `create`, not `add` — "add" stays reserved for *assignment* (the payload's `{"add": [...]}`), so `create_option` can't be misread as "add an option to a paper".

Tool descriptions carry the layer boundaries explicitly (the routing-triangle pattern from the read/grep/search descriptions):

- **Column vs cell:** `update_reference`'s payload description says "to create/rename/delete the *choices themselves*, use the option tools"; each option tool points back at `update_reference` for assigning values to a paper.
- **One door in:** `create_reference` takes *anything* — identifier, URL, file, folder, BibTeX, title — and the CLI routes it (§5). Its description states it may return multiple items (multi-entry BibTeX, folders) and may return `existing` (dedup) rather than a fresh row. `download_pdf`'s description clarifies it attaches to an *existing* reference (creation fetches PDFs itself).
- **One door for rows out:** `list_references` gains an optional `view` param (Int64) — rows filtered/sorted by a **saved view** instead of inline filters (`views_query` retires; its output was already "a reference array (same shape as `list`/`search`)"). `view` is **mutually exclusive with inline filter params** (error on both, ambiguous intent); CLI: `list --view <id>`, routing through the saved view's query engine CLI-side as always (`views --query` retires — superseded surface). `list_views` discovers the ids.

## 4. `update_reference` — the cell payload

### 4.1 MCP schema

```jsonc
rubien_update_reference {
  "id": 42,                                    // numeric, as today
  // ...existing metadata fields (title, year, authors, doi, ...) unchanged,
  //    EXCEPT readingStatus: now a plain string (live-validated by the CLI, §4.4)
  "clearFields": ["abstract"],                 // RENAMED from `clearField` (was plural-valued
                                               // with a singular name; breaking, documented)
  "properties": {                              // NEW, optional
    "Status": "doing",                         // replace (scalar)
    "7": ["ml", "nlp"],                       // replace (multiSelect full set)
    "Tags": {"add": ["12"], "remove": ["3"]},  // idempotent add/remove (multiSelect only)
    "Themes": null                             // clear the cell (nullable cells only, §4.3)
  }
}
```

### 4.2 Key resolution

- ASCII-digit-only keys are property **ids**; anything else is an exact, case-sensitive property **name** (PropertyDefinition names are UNIQUE). A digit-only key that does not parse into `Int64` is an **invalid-selector error** — it never falls back to name resolution.
- **Duplicate resolution is an error**: if two payload keys resolve to the same property (`{"7": …, "Themes": …}` where 7 *is* Themes), reject the whole call — never let dictionary order decide.
- A property whose name is all digits is unaddressable by name (id still works). Going forward, `create_property` / `update_property` **reject all-digit names** so the shadow can't be minted; a pre-existing one (unlikely) is addressable by id.
- Unresolved keys fail the whole call with the `unresolved-selectors` envelope (§4.6) — no partial application.

### 4.3 Built-in routing — the normative classification table

The database seeds **exactly 30 column-backed built-in definitions** (6 visible + 22 hidden at `AppDatabase.swift:354,371` + Last Read / Read Count in v5 at `:597`), and today's CLI refuses *every* default except Tags. The payload replaces that refusal with routing per the table below — **this table is the contract**, encoded in one place in code; the exhaustiveness test asserts every seeded `defaultFieldKey` appears in it exactly once *with the classification below* (fail-closed: a seeded key missing from the code table is rejected at runtime as read-only). Note the payload addresses *seeded definitions* only — `title` / `authors` / `abstract` / `notes` are Reference columns with top-level fields but no seeded definition, so a payload key naming them is `unresolved-selectors` (use the top-level field).

| Seeded name → `defaultFieldKey` | Class | Semantics |
|---|---|---|
| Type → `referenceType` | writable-converted | valid `ReferenceType` label (today's `--type` validation); **non-nullable** |
| Status → `readingStatus` | writable-converted | live-validated against the current option set, case-sensitive; **non-nullable** |
| Tags → `tags` | pivot exception | stringified tag ids; diffed pivots (§4.5); `null` clears all |
| Year → `year` | writable-converted | JSON integer (§4.4 `number` rule); clearable |
| DOI → `doi`, URL → `url` | writable-simple | verbatim string (matching today's flags — no format validation on these two); clearable |
| Journal `journal`, Volume `volume`, Issue `issue`, Pages `pages`, Publisher `publisher`, Place `publisherPlace`, Edition `edition`, ISBN `isbn`, ISSN `issn`, Event `eventTitle`, Event Place `eventPlace`, Genre `genre`, Institution `institution`, Number `number`, Series `collectionTitle`, Pages Count `numberOfPages`, Language `language`, PMID `pmid`, PMCID `pmcid` | writable-simple | verbatim string; clearable |
| Editors → `editors`, Translators → `translators` | writable-converted | accept the `--authors` display grammar (`"Last, First; Last, First"`); stored as **JSON-encoded author arrays** via `Reference.encodeNames(AuthorName.parseList(…))` (`Reference.swift:304,314`) — verbatim storage would corrupt them; clearable |
| Accessed Date → `accessedDate` | writable-converted | seeded as `string` (not `date` — `AppDatabase.swift:383`); accepts `YYYY-MM-DD` (calendar-validated) and stores the literal string, matching the markdown importer; clearable |
| Last Read → `lastReadAt`, Read Count → `readCount` | **read-only** | app-managed reading telemetry; rejected with the `read-only built-in` error, never persisted as shadow `propertyValue` rows |

- **Non-nullable rule (payload-`null` only):** `referenceType` and `readingStatus` are non-null columns (`AppDatabase.swift:105`) — payload `null` for Type/Status is rejected with a `non-nullable built-in` error, **distinct from** the unknown-field error.
- **`clearFields` spellings**: accepted values are exactly today's lowercase `--clear-field` list (the existing contract, `RubienCLI.swift:822` — which already excludes Type and Status, so those spellings are simply *unknown fields* there; the non-nullable distinction exists only on the payload-`null` path). Conflict detection (§4.4) maps `clearFields` entries into the same canonical `defaultFieldKey` space as payload keys before comparing.

### 4.4 Value validation (normative table)

| Property type | Accepted | Rejected | Stored form |
|---|---|---|---|
| `string` | JSON string | non-strings | verbatim (writable-converted built-ins excepted — §4.3) |
| `number` | JSON integer | decimals (v1), strings, bools | canonical integer string (matches the app editor's integer handling) |
| `date` | `"YYYY-MM-DD"` (calendar-validated, same grammar as the markdown importer) | datetimes, offsets, other formats | the app's existing ISO-8601 storage form (UTC midnight) |
| `url` (custom) | absolute `http`/`https` URL | relative, other schemes | verbatim |
| `checkbox` | JSON `true`/`false` | `0`/`1`, strings | existing bool encoding |
| `singleSelect` | string matching an **existing option** | unknown options | option value |
| `multiSelect` | array of strings (each an existing option / tag id), or one string (coerced to a one-element set) | non-string elements — numbers/bools are never silently stringified | JSON-encoded string array (canonicalized below) |

- **multiSelect canonicalization:** duplicates are removed (first occurrence wins); stored order = incoming order for replace, existing-then-appended for `{"add"}`. `[]` (and a `remove` that empties the set) is equivalent to `null`: the value row is **deleted**, matching existing behavior (`AppDatabase.swift:3970`) — `"[]"` is never stored. **No-op comparison for custom multiSelects is exact** (canonicalized incoming array equals the stored array, order included ⇒ no write). **Tags are a set, not a list**: `referenceTag`'s key is `(referenceId, tagId)` with no ordering column (`AppDatabase.swift:175`), so Tags use **set equality** — same membership ⇒ no write; order in the incoming array is ignored.
- `{"add"}`/`{"remove"}` accept arrays of strings only, multiSelect only; `add` applies before `remove` when both are present.
- Empty string is an **error** (ambiguous — `null` is the clear form).
- DOI note: the seeded DOI definition is `url`-typed but stores bare `10.x/…` values — irrelevant here because DOI routes as a *built-in* to `Reference.doi` (§4.3); the strict `url` rule applies to *custom* url properties only.
- `readingStatus` (top-level field and payload "Status") is **live-validated** against the current user-extensible option set, case-sensitively — the npm schema's frozen lowercase enum (`references.ts:198`) is already wrong today and becomes a free string in both catalogs (the CLI is the validator).

**Conflict detection** runs *after* selector resolution and canonical `defaultFieldKey` mapping, and covers all pairs: top-level value vs payload value, top-level value vs payload `null`, `clearFields` entry vs payload value or `null` for the same column (with `clearFields` matched case-insensitively, as the CLI already lowercases them). Any overlap → error naming both spellings.

### 4.5 Atomicity & timestamps

The existing mutation methods each open their **own** `dbWriter.write` transaction (`saveReference`, `setPropertyValue`, multiSelect mutation, `setTags`), and `Update.run` mutates the row *outside* any transaction — composing them cannot honor an atomicity promise. Therefore:

- **New RubienCore entry point** — `AppDatabase.applyReferenceEdit(id:fields:clears:properties:)` (name indicative): one `dbWriter.write` that fetches the row, resolves and validates *everything* (selectors, types, conflicts, read-only/non-null guards), then applies all mutations. The CLI's `update` becomes a thin caller. Existing per-op methods remain for the app UI (consolidating the UI onto the new entry point is a possible follow-up, out of scope).
- **Tags are diffed, not replaced**: today's `setTags` deletes every pivot and reinserts even for an unchanged set (`AppDatabase.swift:2783`), which would violate the no-op rule below. `applyReferenceEdit` computes the pivot diff inside its transaction (insert added, delete removed, leave unchanged pivots untouched) and does **not** call `setTags`. Tests cover unchanged and partially-changed tag sets, including untouched pivot timestamps.
- **Timestamps:** one `now` is captured per call and stamped on **every row actually changed** — the `Reference` row when any of its columns change, each inserted/updated `PropertyValue` row (fixing today's missed stamp on value updates), and only the pivots actually inserted/removed. A no-op entry (incoming value equals stored value) performs **no write** — no timestamp churn, no dirty-queue traffic, no spurious sync upload.

### 4.6 Structured errors must reach the agent — verbatim

Today the CLI prints the `unresolved-selectors` envelope to **stdout** and exits nonzero — and *both* MCP wrappers discard stdout on nonzero exit; worse, their stderr handling **parses `{"error": …}` and drops every other field** (`cli.ts:116`, `MCPServer.swift:276`), so structured payloads like `ids`/`names` would still vanish. For every command this spec touches (`update`, `add`, `properties` modes):

- Structured JSON error envelopes print to **stderr**; stdout is reserved for success JSON (matching `import`'s existing behavior).
- Both wrappers, when stderr parses as a JSON object, deliver the **raw envelope text unchanged** as the tool-error content — no field extraction. Tests assert exact envelope fields (`error`, `ids`, `names`) survive through both wrappers.
- Auditing the remaining commands for the same stdout-envelope pattern is a noted follow-up, not in scope.

### 4.7 CLI backend (lockstep)

```
rubien-cli update <id> [field flags] [--clear-field ...] [--properties <json>]
```

`--properties` takes exactly the MCP payload JSON (1:1 passthrough — one tool call = one CLI invocation = one transaction). Precedent for JSON-valued flags: `views --filter`. (The CLI keeps the existing `--clear-field` flag spelling; only the MCP field is renamed to `clearFields`.)

**Removed in the same stroke** (superseded-surface rule): `properties --set`, `--add-value`, `--remove-value`, `--clear` and their `--reference`-targeting write forms. The read form `properties --reference <id>` stays.

## 5. `create_reference` — one door into the library

Today's split — `add` (identity in: resolver pipeline) vs `import` (artifact in: file/folder/URL ingestion) — forks on input *form*, and the fork leaks: a PDF URL is accepted by both with different pipelines, forcing agent-side routing by description prose. Same anti-pattern the read unification killed; same fix: **route in the CLI, once, for both MCP servers.**

### 5.1 MCP schema

```jsonc
rubien_create_reference {
  "source": "…",          // ANY locator: DOI / arXiv / PMID / PMCID / ISBN,
                           // paper URL, PDF/Markdown file URL, local file path, or folder path
  "bibtex": "…",          // inline BibTeX (can hold multiple entries)
  "title": "…",           // minimal manual row
  // exactly one of source / bibtex / title
  "downloadPdf": true,     // identity route only: fetch OA PDF after resolution
  "format": "bib|ris|md",  // file route only: format hint (forces folder routing as today)
  "property": "…",         // folder route only: property to stamp (default Tags)
  "value": "…"             // folder route only: value to stamp (default folder basename)
}
```

- Options that don't apply to the resolved route are rejected (`"downloadPdf requires an identifier or paper-URL source"`), not ignored — silent no-ops train agents wrong.
- **`downloadPdf` is tri-state** (absent / `true` / `false`) — §5.2's implied-`true` rule needs "explicitly false" to be representable. Today's CLI Boolean `@Flag` can't express it (omitted ≡ false, `RubienCLI.swift:652`), and the npm helper omits false flags. So the CLI uses an **inversion pair** — `@Flag(inversion: .prefixedNo)`: `--download-pdf` / `--no-download-pdf` / absent (= router decides). Bare `--download-pdf` stays valid forever (today's npm server emits exactly that spelling — no transitional break), and the wrapper emits `--download-pdf` or `--no-download-pdf` whenever the field is present. Tests cover all three states end-to-end.
- **`"-"` (stdin) is rejected in the MCP schema** — the wrappers close the child's stdin (`cli.ts:89`; the native server nulls it), so stdin can never carry content over MCP. Stdin remains a **CLI-only** routing step (below).
- MCP annotations: `destructiveHint: false` (creation/dedup-merge never destroys existing data — matching today's `rubien_add`; today's `rubien_import` said `true`, which was wrong by the same standard). Wrapper timeout: **300 s route-independent** (the max of today's identity-add 120–300 s and import 180 s — a thin wrapper can't pick per-route before the CLI routes).

### 5.2 Routing rule (in the CLI — normative order)

Given `source`:
0. **`"-"` (CLI only)** → stdin (requires `--format`, as today's `import -`).
1. **Existing local path** (file or directory) → import machinery (file-type / folder routing exactly as today's `import`). **Paths win over identifiers**: a DOI like `10.1234/foo` that happens to match an existing relative path routes as a file — deterministic, documented, with the escape hatch `https://doi.org/10.1234/foo` (and the reverse escape for weird filenames: `./10.1234/foo`).
2. **URL** (`http`/`https`): known paper host per the `Supported-Paper-URLs` registry → **resolver route** (incl. the existing PDF-URL→landing-page rewrite); else a `.pdf`/`.md`/`.markdown` path extension → **download-import route** (today's validation: magic bytes, content type, 50 MB, GitHub `/blob/` rewrite); else → resolver route (identifier extraction attempt; failure = clear error). Remote `.bib`/`.ris` URLs are **not** supported (v1 non-goal; the error says to download the file first).
   - **PDF-URL intent is preserved on the resolver route:** a `.pdf`-extension URL that routes to the resolver (registered host) implies `downloadPdf: true` unless the caller explicitly passed `false` — the caller handed us a PDF link; resolving to metadata-only would silently drop the PDF they pointed at. (Consequence, documented + tested: `arxiv.org/pdf/…` — arXiv is *not* in the registry — takes the download-import route and attaches the file; `aclanthology.org/….pdf` — registered — takes the resolver route and *also* ends up with the PDF via the implied `downloadPdf`.)
3. **Bare string**: identifier patterns (DOI / arXiv / PMID / PMCID / ISBN) → resolver route; else error listing the accepted forms *and* noting the path-not-found case (a typo'd file path lands here — the error must say so).

The registry and resolver already live CLI-side; routing adds no new dependency. Wrapper stays thin: one tool call = one CLI invocation.

### 5.3 Per-item outcomes require new Core plumbing (not just a new envelope)

The current import APIs return only aggregates — `batchImportReferences` yields count/IDs (`AppDatabase.swift:1801`), `PDFImportOutcome` has no created/existing disposition (`PDFImportCoordinator.swift:9`), `ZoteroFolderImporter` returns totals (`ZoteroFolderImporter.swift:87`). The unified envelope therefore specifies **new typed per-item outcome values** threaded through those pipelines (behavior — dedup keys, merge rules, folder stamping, transaction shapes — unchanged; they gain *reporting*, not new semantics):

- **Type boundary:** the outcome type lives in **RubienCore** and carries the domain model — `ItemOutcome = {reference: Reference?, disposition: created|existing|queued|failed, intakeId?, input, error?}`. It must **not** reference `ReferenceDTO`, which is CLI-private (`RubienCLI.swift:152`); the CLI maps successful references to full DTOs after commit. (`RubienPDFKit` may depend on `RubienCore`, never the reverse.)
- **Additive API:** per-item reporting is added as new detailed overloads / an `items` field on the existing result types — the ~32 existing `batchImportReferences` call sites and the app-facing `PDFImportOutcome` / `ZoteroFolderImporter.Result` contracts keep compiling unchanged.
- **Item cardinality is per parsed input, not per distinct reference**: one item per parsed entry/file/locator, so provenance is always 1:1 and summaries count inputs. Intra-batch duplicates (two entries deduping to one reference — the batch loop can resolve the same id repeatedly, `AppDatabase.swift:1830`) yield **two items pointing at the same reference** (the later one `existing`); tested explicitly.
- **`input` provenance (per route):** the original locator for single-source routes (for the manual-`title` route: the title string; for inline BibTeX the constant `bibtex` — never echo the payload); the file path for folder-markdown entries; `bibtex[<ordinal>]` / `ris[<ordinal>]` (0-based parsed-entry index) for inline multi-entry sources; `<file path>#bibtex[<ordinal>]` for file/Zotero BibTeX entries. Entries failed by a batch rollback all carry their own provenance and a shared error.
- **Source-level failures produce one synthetic `failed` item** (the envelope has no top-level error field): unreadable file/URL, unenumerable folder, unreadable Zotero root `.bib`, or a BibTeX/RIS source parsing to **zero entries** — `input` = the locator, `error` = the cause, exit nonzero (zero succeeded). Zero-parsed-entries is a deliberate small change for the *file* route (today it returns success with `imported: 0`, `RubienCLI.swift:1053`; inline already errors) — uniform is better than silently importing nothing.

**Failure semantics per route (normative):**
- **Inline BibTeX:** persists per entry (`saveReference` per parsed entry, `RubienCLI.swift:695`). Today the loop has **no per-entry catch** — a failure stops processing with earlier entries committed. This spec **deliberately changes it to continue past entry failures** (per-entry `do/catch`; each failure = one `failed` item, remaining entries still attempted) — uniform with folder read semantics, better for agents, CLI-only path (no app UI shares it). Decision-logged as a behavior change, not "reporting only."
- **File BibTeX/RIS:** parse, then persist the parsed batch in **one transaction** (`AppDatabase.swift:1821`); a persistence failure fails the whole source — reported as one `failed` item **per parsed entry** (shared error), so counts stay meaningful. Unchanged.
- **Folder markdown:** per-file *read* failures continue past (failed items with file-path provenance); all successfully-read files persist as **one batch** (`RubienCLI.swift:1292`) — a batch persistence failure fails every read entry, same per-entry reporting rule. Unchanged (continuation applies to read failures only; persistence stays batch-atomic).
- **Zotero folder:** reads **one root `.bib`** (`ZoteroFolderImporter.swift:152`) — a root-read failure is a *source-level* failure (synthetic item, above). Missing or failed **PDF copies are not item failures**: their references import successfully and the paths land in `diagnostics.missingPDFs` (`ZoteroFolderImporter.swift:241`), exactly as today. Persistence is batch-atomic as today.
- **Malformed BibTeX entries** are silently skipped by the parser today (`BibTeXImporter.swift:27`) — kept in v1, called out in the tool description; parser diagnostics are a listed follow-up (§2 non-goals).
- **PDF route:** `created`/`existing` when resolved, `queued` (+`intakeId`) when pending verification, `failed` on validation/acquisition errors.
- **Exit code:** nonzero **iff zero items succeeded** (succeeded = created/existing/queued); partial success exits 0 with failures visible in `items`/`summary.failed`. **On the all-failed nonzero path the full unified envelope is written to stderr** (§4.6 rule applied to §5.4's shape — both wrappers discard stdout on nonzero exit, and a bare `{"error"}` replacement would lose the per-item detail); partial-success envelopes go to stdout with exit 0.

### 5.4 Unified output envelope — no information loss

One shape for every route, carrying everything today's outputs carry (`add`'s full post-merge `ReferenceDTO`; import's `file`, folder `property`/`value`, Zotero `attached`/`duplicatesSkipped`/`missingPDFs`, markdown failed filenames):

```jsonc
{
  "items": [
    { "reference": { /* full ReferenceDTO, as `add` returns today */ },  // absent for queued-unlinked / failed
      "status": "created" | "existing" | "queued" | "failed",
      "intakeId": 7,          // queued only (a queued intake may have no reference yet — MetadataIntake.swift:19)
      "input": "…",          // provenance: the source entry / file path this item came from (always present)
      "pdfDownload": {...},   // present when a PDF fetch/attach was attempted
      "error": "…" }          // failed only
  ],
  "summary": { "created": 1, "existing": 0, "queued": 0, "failed": 0 },
  "diagnostics": {            // route-specific, present when the route produces them
    "file": "…",             // single-file/URL routes
    "property": "…", "value": "…",              // folder stamping
    "attached": 3, "duplicatesSkipped": 1, "missingPDFs": ["files/12/x.pdf"]  // Zotero
  }
}
```

Reference ids inside `reference` stay in the `ReferenceDTO`'s existing (numeric) shape — no stringly ids; the CLI maps Core's `Reference` outcomes to DTOs post-commit (§5.3 type boundary). Dedup/merge semantics per route are unchanged. On the all-failed nonzero-exit path this exact envelope goes to **stderr** (§5.3). The tool description states both non-obvious outcomes: multiple items, and `existing` when dedup matched.

### 5.5 CLI (lockstep)

`rubien-cli add` gains `--source <locator>` (+ the file-route flags `--format` / `--property` / `--value`) and internally reuses the import machinery; stdin stays supported (`--source - --format ris`, CLI only). **The `import` subcommand is removed in the same stroke**; `--identifier` is retired in favor of `--source` (one locator flag; `--bibtex` / `--title` unchanged). `Docs/CLI-Reference.md`: the `## import` section folds into `## add` with a migration table (old `import …` / `add --identifier …` → new `add --source …`).

## 6. Remaining write tools — schemas

- **`rubien_update_property`** `{id, name?, visible?}` — at least one of `name`/`visible`. CLI: new combined mode `properties --update --id <id> [--name <new>] [--set-visible true|false]` replacing `--rename`/`--show`/`--hide` (one call, one transaction). **The flag is `--set-visible`, not `--visible`** — bare `--visible` is already the list-mode filter flag (`RubienCLI.swift:1341`) and cannot double as a Boolean-valued option. Built-in rename refusal unchanged (Tags et al.); all-digit names rejected (§4.2).
- **`rubien_update_option`** `{propertyId, option, name?, color?}` — `option` addresses the existing option by its **original identity** (for Tags: the stringified tag id); at least one of `name`/`color`. Combined rename+recolor applies in **one transaction** addressed by that original identity. `color` accepts `#RRGGBB` only. **Type's options stay fully immutable — recolor included** (`Properties.optionsMutable(for:)` gate unchanged). Tags recolor updates the `Tag` row; other selects update `optionsJSON`; rename bulk-updates affected references as today. CLI: `properties --update-option --id <pid> --option <value> [--to <new>] [--color <hex>]` replacing `--rename-option`/`--from`.
- **`rubien_create_option`** `{propertyId, value, color?}` — unchanged semantics (`properties --add-option`); for Tags, creates a Tag and returns its id as `value`.
- **`rubien_delete_option`** `{propertyId, value, replaceWith?, clearInUse?}` — unchanged semantics incl. the `optionInUse` error and the mutual exclusion.
- **`rubien_create_property`** `{name, type, options?}` (+ all-digit-name rejection) / **`rubien_delete_property`** `{id}` — otherwise unchanged semantics (built-in delete refused).
- **`rubien_create_view` / `rubien_update_view` / `rubien_delete_view`** — semantics of today's create/rename/delete; `update_view` is `{id, name}` v1.
- **`rubien_delete_reference` / `rubien_download_pdf`** — rename only, schemas unchanged.

## 7. Assistant integration touchpoints (same commit, not Phase 4)

- **The reference seed teaches tool names and must migrate.** `AssistantContext.swift:72` explicitly instructs the agent to use `rubien_get`, `rubien_read_text`, `rubien_read_annotations`, `rubien_pdf_page_image`, `rubien_search`; `AssistantContextTests` pins `rubien_get`. Both move to the new names (`get_reference`, `render_pdf_page`, `search_references`; `read_*` unchanged) in this commit — otherwise every conversation starts by recommending tools that no longer exist.
- **`ReferenceAttribution` (AgentProvider.swift:234) — add the new generation, keep the old *verbatim*.** The existing rules are *correct for old sessions and must not change*: the `rubien_properties_` prefix rule routes old value-ops to their `reference` argument (existing tests pin `properties_set {reference: 42, id: 7}` → ref 42), and old definition/option tools carry no `reference` key so they naturally attribute nothing. Added rules for the new generation: `update_reference` attributes its top-level `id` (never payload keys — regression test: `update_reference {id: 42, properties: {"7": …}}` → ref 42, not property 7); `delete_reference`/`cite` keep the `ids` mapping under their names; `create/update/delete_{property,option,view}` are an explicit **never-attribute** set (their `id`/`propertyId` are property/option/view ids). **Old-generation fix in passing:** `rubien_views_query`'s scalar `id` is a *view* id, and the default rule attributes bare `id` keys (`AgentProvider.swift:274`) — a **pre-existing latent mis-attribution** for historical sessions; old `views_query` joins the never-attribute set. Completing the audit of renamed id-bearing tools: `get_reference` / `get_pdf_info` / `render_pdf_page` carry reference ids (default rule correct); `list_properties` / `list_views` carry no bare `id` (safe); `list_references`' new `view` param is not an attribution key (safe by construction). Note: `export` currently takes no `ids` (whole-library export) — its dormant mapping is retained for historical sessions only, not a claim about the current tool.
- **`isSilentReadTool`** auto-approves by the `mcp__rubien__` prefix — rename-safe as-is, **but Phase 4's write tools will share that prefix**, so this spec locks the contract now: when write tools first register, the silent-read allowlist becomes name-based and its test **catalog-driven** (every registered read-only tool is silent, every registered write prompts — derived from the catalog, not a hand-copied count).

## 8. Migration & release

- **npm `rubien-mcp-server` 0.3.0** — full artifact checklist (each has bitten before): bump `BUILD.txt`, regenerate `GeneratedVersion.swift`, set `MIN_CLI_BUILD` to that build, bump `package.json` + both `package-lock.json` version fields + `SERVER_INFO`, update the stub-CLI builds and hard-coded build expectations in `versionGuard.test.ts` / `guard-startup.test.ts`, move the README upgrade/deprecation prose from `<0.2.0` to `<0.3.0`, then `npm deprecate rubien-mcp-server@"<0.3.0"` on publish. MCP tools are discovered per-session, so configured clients pick up new names automatically; agent *memory* of old names fails loudly (unknown tool) rather than silently.
- **CLI migration table** (in `Docs/CLI-Reference.md`, mirroring the retired-`tags` table) covers **every** removed form: `properties --set / --add-value / --remove-value / --clear` → `update --properties`; `properties --rename / --show / --hide` → `properties --update [--name] [--set-visible]`; `properties --rename-option / --from / --to` → `properties --update-option --option [--to] [--color]`; `import …` and `add --identifier …` → `add --source …`; `views --query <id>` → `list --view <id>`. Each removed flag gets an explicit rejection test (scripts must fail loudly, not misparse).
- **Native `rubien-cli mcp` read catalog** (`MCPToolCatalog.swift`): rename the 8 read tools; stays drop-in interchangeable with the npm server's read subset; `--read-only` flag semantics unchanged; `readingStatus` filter enum → free string here too.
- **Old-name sweep with a classification rule** (not a blind replace): **migrate** active surfaces — assistant seed + tests, `ReferenceAttribution` additions, npm catalog + tests, native catalog + `MCPServerTests`, both READMEs, `Docs/CLI-Reference.md`, **`Docs/Supported-Paper-URLs.md`** (names `add --identifier`), **`.github/workflows/linux-cli-release.yml`** (smoke-tests `add --identifier`), **`AGENTS.md`/`README.md` CLI subcommand counts** (18/17 changes with `import` removed), any harness/renderer fixtures that exercise live tool names. **Retain** old names deliberately — historical specs, immutable session fixtures, and the both-generations attribution tests (they are the compatibility evidence). The read-tools spec had this rule; it applies verbatim.
- **No DB migration**: no schema change. The new `applyReferenceEdit` entry point changes transaction *shape*, not schema.

## 9. Tests

- `RubienCLITests` — `update --properties`: every §4.4 table row (accept + reject per type), key resolution (digit=id, name, duplicate-resolution error, all-digit name guard, Int64-overflow selector, unresolved envelope), built-in routing (writable-simple, writable-converted editors/translators round-trip through `encodeNames`, read-only rejection, Type/Status null rejection, unknown-vs-non-nullable error distinction, Tags), **seed-classification exhaustiveness** (every seeded `defaultFieldKey` classified exactly once), conflict matrix (value/value, value/null, clearFields overlap, case-insensitive), atomicity (a failing payload entry rolls back metadata edits in the same call), timestamp/no-op (unchanged value writes nothing; unchanged tag set touches no pivots — Tags compared as a *set*, custom multiSelect as exact ordered array), stderr envelope propagation (exact fields). `add --source` routing: existing path, folder, path-beats-DOI + `doi.org` escape, known-host URL, known-host `.pdf` URL (implied `downloadPdf`), arXiv `.pdf` URL (download-import route), extension URL, `.bib` URL rejection, bare identifier, typo'd-path error text, `-` accepted (CLI) / rejected (MCP schema), `--download-pdf`/`--no-download-pdf`/absent tri-state through the npm wrapper; unified envelope shapes (single w/ full DTO, multi-entry BibTeX w/ ordinal provenance, intra-batch duplicate → two items one reference, inline entry-failure continues, source-level synthetic item incl. zero-parsed-entries, folder w/ diagnostics, Zotero missing-PDF-as-diagnostic-not-failure, dedup-existing, queued w/o reference, partial failure exit-0, all-failed exit-nonzero w/ full envelope on stderr); §4.3 classification table exhaustiveness (all 30 seeds, intended class each) incl. editors/translators `encodeNames` round-trip and Last Read/Read Count rejection. **Wrapper scoping:** write-route end-to-end tests run through the **npm** wrapper only (the native catalog registers no write tools until Phase 4 — §2 non-goal); the native server tests the generic raw-stderr-envelope preservation helper, which its read tools already exercise. `properties --update` / `--update-option` modes + removed-flag rejections. `list --view <id>` (saved-view rows; mutual exclusion with inline filters). MCP server tests: renamed read tools.
- npm server tests: renamed registrations, payload/`source` passthrough argv, count 27, version-guard updates, raw stderr envelope surfaced unchanged, `create_reference` annotations (`destructiveHint: false`) + 300 s timeout.
- `RubienTests`: `ReferenceAttribution` both-generations table — old names unchanged behavior (existing tests keep passing untouched), new-generation rules, the payload trap case, old `views_query` never-attributes (latent-bug fix); assistant seed migration.
- Contract note: JSON output shapes of *surviving* operations are unchanged **except** the two documented breaks: the unified `create_reference` envelope (§5.4) and `clearField`→`clearFields` (§4.1).

## 10. Decision log

| Decision | Alternatives rejected |
|---|---|
| `{op}_{target}` verb-first grid, full-catalog sweep now (user, 2026-07-14) | writes-only rename (leaves 3 naming generations); noun-first `properties_option_create` (unguessable) |
| Verb `create`, not `add` (user, 2026-07-14) | `add_*` (shorter, but re-blurs creation vs assignment — `add_option` misreads as "add option to a paper") |
| `import` folded into `create_reference`; routing in the CLI (user, 2026-07-14) | two doors + description-prose routing (agent-side routing = the anti-pattern the read unification killed); MCP-only merge with wrapper routing (would be duplicated in the native server at Phase 4) |
| Cell values fold into `update_reference` (Notion `PATCH page` shape) | `set_value {mode}` tool (keeps the built-in/custom seam); per-mode tools (today's shape) |
| Payload keys: ASCII-digit-only = id (Int64-bounded, no name fallback), else exact name; duplicate resolution = error; all-digit names rejected going forward | id-only (extra resolve turn); name-only (renames break scripts); silent last-writer-wins on aliases |
| Fail-closed built-in classification table (writable-simple / writable-converted / read-only), exhaustiveness-tested | "derive from the seed" hand-waving (seed has no setter/mutability metadata); hand-enumerating "the five" (there are ~29; silent `propertyValue` shadow rows would "succeed" invisibly); verbatim strings for `editors`/`translators` (they're JSON author arrays — corruption) |
| Strict type validation (integer-only numbers, `YYYY-MM-DD` dates, JSON bools, existing-option checks); empty string = error; exact-array no-op canonicalization; `[]` ≡ `null` ≡ row deletion | permissive strings (today's CLI) — unvalidated cells render wrong in the app and diverge between servers; storing `"[]"` |
| New single-transaction `applyReferenceEdit` RubienCore entry point; Tags pivots **diffed** inside it | composing existing per-op writes (each opens its own transaction — atomicity would be fictional); calling today's `setTags` (delete-all+reinsert churns unchanged pivots) |
| One captured `now`, stamped only on rows actually changed; no-ops write nothing | stamping everything every call (dirty-queue churn, spurious sync uploads) |
| Structured error envelopes → stderr; wrappers pass the raw envelope through **verbatim** | stdout envelopes (both MCP wrappers provably drop them on nonzero exit); wrappers' current `{"error"}`-field extraction (drops `ids`/`names`) |
| `--set-visible` on `properties --update` | `--visible` (collides with the existing bare list-filter flag) |
| MCP `clearField` → `clearFields`; ids stay numeric | keeping the singular name for an array (misleading); stringly ids (diverges from today) |
| `hide`/`show`/`rename` → one `update_property` | keep 3 (same operation: field edits on the column row) |
| CLI keeps flag idiom; `import` removed, `--identifier` → `--source`; stdin stays CLI-only (`-` rejected in MCP schemas) | CLI subcommand renames (churn, no agent-facing gain); keeping `import` (two generations of the same surface); pretending MCP can carry stdin (wrappers close it) |
| Paths win over identifier-looking strings; escapes: `https://doi.org/…` / `./path` | identifier-first (a DOI-named file becomes unreachable); heuristic guessing (non-deterministic routing) |
| Registered-host `.pdf` URL → resolver route with **implied `downloadPdf: true`** (explicit `false` wins) | metadata-only (silently drops the PDF the caller pointed at); import-route for registered hosts (loses canonical metadata + dedup) |
| Per-item outcomes via new typed Core plumbing (`ItemOutcome` carries `Reference?`, CLI maps to DTO post-commit; additive overloads) | id+title-only items (loses `add`'s full DTO and import's diagnostics — v2 had this, caught in review); `ReferenceDTO` in Core (CLI-private type, dependency inversion); breaking ~32 `batchImportReferences` call sites |
| Failure semantics pinned to today's per-route transaction shapes (file/folder = batch-atomic persistence, read-continue), with **one deliberate change**: inline BibTeX gains per-entry continue-past-failure (today: stop-on-first-error, prefix committed, no catch) | inventing uniform semantics ("atomic per source" / "continue past failures" — v3 had both, each contradicting a route's current code); keeping stop-on-first-error (unattempted entries would need "not attempted" pseudo-failures — worse contract than just continuing) |
| Items are per parsed input (1:1 with provenance; intra-batch dupes = two items, one reference); source-level failures = one synthetic failed item (zero-parsed-entries now fails uniformly) | items per distinct reference (undefined under intra-batch dedup); top-level error field (second envelope shape); file-route zero-entries "success" with `imported: 0` (silently importing nothing) |
| Zotero missing/failed PDF copies stay `diagnostics.missingPDFs` on successful items; root `.bib` read failure = source-level failure | treating attachment failures as failed reference items (contradicts today: the references import fine) |
| `--download-pdf` / `--no-download-pdf` inversion pair (tri-state, bare spelling back-compatible) | Boolean `@Flag` (omitted ≡ explicit false — the §5.2 implied-true rule needs the distinction); valued `--download-pdf true\|false` (breaks the checked-in npm server's bare-flag emission mid-branch) |
| `create_reference` `destructiveHint: false`, 300 s wrapper timeout | inheriting `import`'s `destructiveHint: true` (wrong by the delete_* standard); per-route timeouts in a thin wrapper (can't know the route pre-CLI) |
| Tags no-op = set equality; custom multiSelect = exact ordered array | one rule for both (`referenceTag` has no ordering column — ordered equality is unimplementable for Tags) |
| `views_query` folds into `list_references {view}` (user, 2026-07-14); old name joins never-attribute (pre-existing latent mis-attribution) | standalone `query_view` (same operation, identical output — an invented name for a filter-source fork) |
| Tags payload values = stringified tag ids | labels with auto-create (rename-unsafe, hides Tag creation from the Phase-4 approval surface) |
| Old attribution names kept forever, rules verbatim | never-attribute set covering old names (WRONG — old value-ops carry a `reference` arg that existing tests pin as attributed; v1 of this spec had this bug, caught in review) |
