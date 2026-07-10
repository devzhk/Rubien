# Markdown Import — Design

**Date:** 2026-07-09
**Status:** Approved (brainstormed with user; codex-reviewed, findings folded in)
**Scope:** RubienCore, Rubien (app), RubienCLI, mcp-server, Docs

## Motivation

Rubien stores clipped web pages as markdown (`reference.webContent`,
`WebContentFormat.markdown`) and renders them in the web reader with full
annotation support — but the only ways in are live extraction (in-app URL
import, browser clipper). Users with existing markdown files — Obsidian Web
Clipper output, plain notes — have no import path. Every importer accepts only
`.bib` / `.ris` / PDF / Zotero folders.

The gap is small: a markdown file's body *is* the native `webContent`
representation, and Obsidian clipper frontmatter maps 1:1 onto Reference
fields. This feature adds the import path.

## Goals

- Import **any** `.md` file as a reference. Obsidian Web Clipper frontmatter
  is optional enrichment, not a requirement.
- App: the toolbar "Import PDF (auto)" button becomes **"Import
  PDF/Markdown"** — one panel, both types, multi-select.
- CLI: `rubien-cli import` accepts `.md` files, folders of `.md` files, and
  `--format md` stdin. MCP `rubien_import` inherits it.
- A new first-class `Markdown` reference type for URL-less notes.
- Imported notes are readable + annotatable in the web reader, FTS-searchable,
  and sync like any other reference — with **zero schema/CKRecord changes**
  beyond one new enum rawValue and one new select option.

## Non-goals

- **In-app note creation/editing.** Import only. (Manually creating a
  reference with type Markdown from the Add sheet remains possible — the
  type appears in `allCases`-driven pickers — and behaves exactly like
  `Other`: metadata-only, no reader until it has content. Accepted, not
  filtered.)
- **Attaching or moving the source file.** Content is copied into the
  library database; the `.md` file on disk stays untouched and unreferenced.
- **Frontmatter `tags` mapping.** Ignored by user decision. Folder imports
  can stamp a property via `--property`/`--value` (Zotero parity).
- **Recursive folder import.** Top-level `*.md` only, so pointing at a vault
  root can't slurp a whole vault.
- **Non-markdown text formats** (`.txt`, `.org`, …).
- **Obsidian-specific body syntax** (wiki-links `[[…]]` in the body, embeds
  `![[…]]`) — rendered as-is by the markdown renderer; no resolution.

## Decisions (brainstorm log)

| Question | Decision |
|---|---|
| `.md` without frontmatter | Import gracefully (title falls back: frontmatter → first-line `# H1` → filename → "Untitled") |
| Frontmatter `tags` | Ignore |
| App button selection | Multi-select `.md`; PDFs keep the existing one-at-a-time resolution flow (mixed selection allowed, PDFs sequential) |
| Type for URL-less notes | New `ReferenceType.markdown` (user request); clipper files with `source` URL stay `.webpage` |
| Frontmatter parser | Hand-rolled subset in RubienCore, no YAML dependency (Yams can be swapped in behind the same API if ever needed) |
| Metadata resolution | Never runs for markdown imports — frontmatter (or fallbacks) is the truth; no network |

## Design

### 1. `MarkdownImporter` (RubienCore)

New file `Sources/RubienCore/Services/MarkdownImporter.swift`, pattern-matched
to `BibTeXImporter`/`RISImporter`: a pure enum with static parse functions, no
I/O, no database. One reference per file.

```swift
public enum MarkdownImporter {
    /// filename: source basename (without extension) used as a title
    /// fallback; nil for stdin.
    public static func parse(_ content: String, filename: String?) -> Reference
}
```

**Frontmatter detection (strict, to avoid eating content):**

A candidate block exists iff the **first line** of the file (after stripping
a UTF-8 BOM; trailing `\r` tolerated) is exactly `---` and a closing `---`
line exists before EOF. The candidate is **accepted as frontmatter — and
only then stripped from the body — iff it is plausible YAML mapping**:

- every non-blank line inside is one of: a top-level `key: …` line (key
  matching `[A-Za-z0-9_-]+`, at indentation 0), a block-list item (`- …`)
  indented under a preceding key, an indented continuation line under a
  preceding key, or a `#` comment; **and**
- at least one top-level key is present.

Anything else — e.g. a document that opens with a `---` thematic break
followed by prose and a second `---` — fails the plausibility test and the
**entire file is preserved as body**. Parsing never silently deletes
content that isn't structurally frontmatter. A plausible block whose keys
are all unrecognized (e.g. only `aliases:`) is still stripped (frontmatter
is metadata, not content — matching how Obsidian hides it) but contributes
no fields.

**Grammar (subset, hand-rolled):**

- Recognized keys are matched **at indentation 0 only**. Indented lines
  (nested maps, continuations) are consumed as opaque units belonging to
  the preceding top-level key — `metadata:\n  title: Wrong` must NOT set a
  title.
- Block scalars (`key: |`, `key: >`, with optional `+`/`-`/indent
  modifiers) are unsupported: the key contributes no metadata and all its
  continuation lines are consumed without being re-parsed as keys.
- Scalar values may be plain, single-quoted (`''` → `'`), or double-quoted
  (`\"` → `"`, `\\` → `\`; any other escape sequence is kept literal —
  never partially corrupted).
- Lists: block lists (`- item` lines) for any recognized list-valued key;
  inline flow lists (`[a, "b, c"]`) for `author` only, split by a small
  state machine that tracks quote/escape/bracket state so commas inside
  quotes never split (`author: ["Smith, John", "[[Jane Doe]]"]` → two
  authors).

**Field mapping (recognized keys, lowercase as the Obsidian clipper emits):**

| Frontmatter | Reference field | Notes |
|---|---|---|
| `title` | `title` | |
| `source` | `url` + `siteName` (host) | Only stored when it parses as a valid `http`/`https` URL; anything else is ignored |
| `author` | `authors` | Scalar or list. Each entry: strip `[[` `]]` wiki-link wrappers, then `AuthorName.parse` (same free-text handling as the clipper path) |
| `published` | `year` / `issuedMonth` / `issuedDay` | `YYYY-MM-DD`, `YYYY-MM`, or `YYYY` (bare or quoted); see date validation below |
| `created` | `accessedDate` | Stored as the literal `YYYY-MM-DD` string; see date validation below |
| `description` | `abstract` | |
| `tags` | — | Ignored (decision) |
| anything else | — | Ignored |

**Date validation:** dates are validated with a fixed-Gregorian,
POSIX-locale parser — calendar-valid only (`2025-02-31` rejected; leap days
honored). A date token must be terminated by end-of-value, whitespace, or a
`T` datetime separator — `2025-01-0199` is rejected, `2026-07-09T10:00:00`
truncates to `2026-07-09`.

**Title fallback chain:** frontmatter `title` → first non-blank **body** line
if it is an ATX H1 (`# ` prefix; the line is then removed from the body so
the reader doesn't render the title twice) → `filename` (basename sans
extension) → `"Untitled"`.

**Body:** everything after an accepted frontmatter block (or the whole file
otherwise), trimmed, stored via
`Reference.encodeWebContent(body, format: .markdown)` — the exact
representation the in-app clipper produces, so reading, annotating, FTS
(`webContent` is an indexed FTS column), and sync all work with no further
changes. Empty body → `webContent` nil (metadata-only reference; still
valid).

**Reference type:** `url` present → `.webpage`; else → `.markdown` (see §2).
`parse` never fails — any text input yields a Reference (worst case:
title from filename, whole content as body). Failures happen only at the
file-read layer (§7).

### 2. `ReferenceType.markdown`, end-to-end

**Enum** (`Sources/RubienCore/Models/Reference.swift`):
`case markdown = "Markdown"`, icon `doc.plaintext`.

**Consumer checklist** (exhaustive switches the compiler surfaces, PLUS the
string-keyed/hard-coded sites it cannot — all updated in the same change):

- `ReferenceType.icon` (Reference.swift)
- `MetadataResolution.workKind(for:)` → same bucket as `.other`
- BibTeX entry-type mapping → `@misc` (precedent: `.webpage` already
  collapses to `@misc`, `Reference.swift:6`)
- RIS type mapping → `TY  - GEN`
- `ReferenceType.cslType` (`Reference+CSLJSON.swift`) and
  `CSLEngine.mapReferenceType` → CSL `document`
- `MetadataVerifier` type handling (compiler-surfaced)
- `CitationFormatter` — verified: does not branch on `referenceType`; no
  change
- Hard-coded lists: `Docs/CLI-Reference.md` type list,
  `Docs/Sync-Runbook.md` six-option description, `ReferenceTests`
  count-of-six assertion, model comments claiming `.webpage` alone gates
  the reader (§3 changes that)
- Final sweep: `grep -rn "Web Page\|allCases"` over Sources/ and Docs/ for
  stragglers

**Tolerant decoding (two layers):**

- Custom `ReferenceType.init(from decoder:)` falling back to `.other` —
  `Reference` is embedded in persisted JSON (pending metadata-intake
  queue), and the synthesized Codable decoder would throw on an unknown
  rawValue read by an older binary.
- `Reference.init(row:)` GRDB decode: rawValue fetch with `?? .other`
  fallback (currently `row["referenceType"]` traps on unknown values —
  downgrade / app-CLI skew on a shared `RUBIEN_LIBRARY_ROOT` hazard),
  mirroring the CKRecord convention (`ReferenceRecord.swift:233`).

**Migration (`v6` in the library migrator, `AppDatabase.swift`):** append
`{"value": "Markdown", "color": "#5AC8FA"}` to the Type PropertyDefinition's
`optionsJSON` iff no option with value `"Markdown"` exists (idempotent),
selected by `defaultFieldKey = 'referenceType'`. Follows the **v5
precedent** (v5 rewrote the same column under a `syncSession
applyingRemote` guard so the rewrite does not dirty the synced record; every
device runs the migration locally, no sync churn). Mechanics:

- **Structural JSON append**, not decode-as-`[SelectOption]`-and-re-encode:
  parse with `JSONSerialization` as an array of objects, append one object,
  preserving existing objects (order, colors, any unknown fields)
  byte-for-byte in content. If `optionsJSON` does not parse as a JSON
  array, the migration **leaves it untouched** (fail-safe no-op; the §2
  reconciliation below is the backstop) rather than replacing undecodable
  data or aborting launch.
- A `runV6MigrationForTesting(on:)` helper mirrors the existing
  `runV2MigrationForTesting` pattern so tests can drive a true v5-shaped
  database.

**Sync reconciliation (closes the convergence hole):** `optionsJSON` is
itself synced, and applying a remote PropertyDefinition preserves the
peer's JSON verbatim — so an older peer pushing the six-option Type
definition would silently remove the Markdown option from an upgraded
device, and the migration never reruns. Fix: when a remote **Type built-in**
PropertyDefinition is applied, reconcile its options against
`ReferenceType.allCases` — append any missing enum-backed values (incoming
order and colors preserved; defaults for appended ones) **without marking
the record dirty** (local deterministic healing on every device, same
philosophy as the migration; no push-back churn). Old peers receiving a
7-option list just show an extra string option — harmless, and their
pushes get re-healed on arrival.

**Old-peer degradation (accepted):** a peer running an older version decodes
`Markdown` records as `.other` (existing CKRecord fallback). If that old
peer then edits and pushes the same reference, the type downgrades to
`Other` remotely. Standard forward-compat trade-off the sync design already
accepts for every enum; noted, not mitigated.

**CLI/MCP surfaces:** `--type Markdown` works automatically (`rawValue`
init; the `allCases`-derived error text self-updates). Type mentions in CLI
help / MCP schemas are non-enumerated examples — no changes required.

### 3. Web reader gate loosening

`Reference.canOpenWebReader` (`Reference.swift:740`) currently requires
`referenceType == .webpage`, which would strand URL-less notes. New rule,
content-driven:

- non-empty `webContent` → **true, for any reference type**;
- else `.webpage` with a valid resolved URL → true (live mode, unchanged);
- else false.

Mirror the same change in the app-side copy
(`ReferenceDetailView.swift:1231`): `hasStoredWebContent ||
(referenceType == .webpage && resolvedWebReaderURLString != nil)`.

Verified: `WebReaderView` already guards every URL use (re-extract disabled
at `WebReaderView.swift:1787`; live-mode loads conditional), so a nil-URL
reference with clip content renders reading mode correctly. Double-click
routing (`ContentView.openReader`: PDF first, else web reader) composes
unchanged. Side benefit: fixes the latent case where changing a clipped
page's type to e.g. Journal Article made its reader unopenable.

### 4. App UI (Rubien target)

- **Button** (`ContentView.swift:919`): label key
  `content.toolbar.importPDFAuto` retitled to "Import PDF/Markdown" (icon
  `doc.badge.plus` unchanged); `.help` text updated. `en.lproj` strings
  updated.
- **Panel** (`OpenPanelPicker`): new
  `pickImportableFiles() -> [URL]` — `allowedContentTypes:
  [.pdf, UTType(filenameExtension: "md") ?? .plainText]`,
  `allowsMultipleSelection = true`.
- **Flow** (`ContentView`): `importPDFWithMetadata()` becomes
  `importFilesWithMetadata()`, the **single owner of batch state**
  (`isImporting`, progress text, accumulated errors, final summary,
  cleanup). Selection splits by extension:
  - `.md` files: read (same 50 MB / UTF-8 guards as the CLI, applied here
    too) + `MarkdownImporter.parse` each → one
    markdown-import transaction (§8 merge policy) → summary toast
    "Imported N markdown file(s)"; per-file read failures are accumulated
    and reported once, without aborting the batch.
  - PDFs: the current single-PDF body is extracted into
    `importSinglePDF(url:) async -> PDFImportOutcome` — a **pure per-file
    step** that returns imported/queued/failed plus its message and does
    NOT mutate `isImporting`/progress/global error state (today's body
    clears them itself; that behavior moves to the outer coordinator so a
    multi-file batch doesn't appear idle after the first PDF or let a
    per-file toast overwrite the aggregate result). PDFs are awaited
    sequentially; resolution/pending-queue semantics per file are
    unchanged.

### 5. CLI (`RubienCLI.swift` `Import` subcommand)

- **Extension switch** gains `case "md", "markdown"` → read file (existing
  50 MB / UTF-8 guards) → `MarkdownImporter.parse(content, filename:
  basename)` → markdown import (§8) → existing JSON contract
  `{"imported": "1", "file": path}`.
- **Stdin**: `--format md` accepted; `filename: nil` (title chain ends at
  "Untitled").
- **Folder routing** (currently unconditional Zotero): a directory argument
  is probed at top level —
  - `.bib` present and no `.md` → Zotero folder import (unchanged);
  - `.md` present and no `.bib` → **markdown folder import**;
  - **both present** → error: `"Ambiguous folder: contains both .bib and
    .md. Pass --format bib or --format md to choose."` (`--format` now also
    steers folder routing; no silent ignoring of either kind);
  - neither → error `"No importable files found (expected .bib or .md)"`.
- **Markdown folder import:** parse every top-level `.md` (sorted by name),
  import in one transaction, and stamp a property exactly like the Zotero
  path (`--property` default `Tags`, `--value` default folder basename).
  Unreadable/non-UTF-8/oversized files are skipped and reported. Output
  mirrors the Zotero envelope:

  ```json
  {"imported": "12", "failed": "note-bad-encoding.md", "property": "Tags",
   "value": "Clippings", "file": "/path/Clippings"}
  ```

  (`failed` = comma-joined basenames, empty string when none — same
  convention as Zotero's `missingPDFs`.)
- **`Docs/CLI-Reference.md`** updated in the same commit (import section:
  `.md`, folder routing rules incl. the ambiguity error, `--format md`,
  stamping defaults — plus the reference-type list gaining `Markdown`).

### 6. MCP server (`mcp-server`)

`src/tools/io.ts` `rubien_import`: `format` enum becomes
`["bib", "ris", "md"]`; title/description mention markdown files and
folders; `property`/`value` descriptions lose the "(Zotero folder only)"
qualifier (they stamp markdown folders too). Patch-level version bump in
`package.json` **and `package-lock.json`**. Add a schema/argument-forwarding
test for `format: "md"` and markdown-folder stamping. (The Swift-side
`MCPToolCatalog.swift` is read-only tools — no import tool there; no
change.)

### 7. Errors

- File layer (app + CLI): unreadable file, non-UTF-8, >50 MB → per-file
  error; **batches continue** past failed files and report them (CLI:
  `failed` field / single-file JSON error; app: accumulated summary via the
  §4 coordinator).
- Parse layer: never fails (§1). Frontmatter-only and empty files import as
  metadata-only references.

### 8. Dedup & merge policy for markdown imports

Duplicate detection reuses `findDuplicateReferenceID` (DOI → PMID → PMCID →
ISBN → **exact URL** → ISSN+title+year). But markdown imports do **not**
reuse the generic bib/ris merge (`mergedReference`) — that policy prefers
incoming title/authors, and the importer *always* synthesizes a title, so a
frontmatter-less re-import could overwrite a curated title with a filename.
Instead, a markdown-specific merge (new
`AppDatabase.importMarkdownReferences(_:)` wrapper, same transaction and
dedup machinery):

| Field | On URL match with existing reference |
|---|---|
| `webContent` | longest-wins (today's behavior; annotation-anchor-safe) |
| `title` | fill-only: written when the existing title is empty; an existing title is **never** overwritten (references always have one, so in practice merge keeps it — a filename fallback can never clobber a curated title) |
| `authors`, `abstract`, `year`/`issuedMonth`/`issuedDay`, `accessedDate`, `siteName` | fill-only: written when the existing field is empty/nil, never overwriting curated values |
| everything else | untouched |

Stated consequences:

- Re-importing a **clipper file** (has `source` URL) merges into the
  existing reference for that URL — including one created by the in-app
  clipper. Curated metadata survives; longer clip content wins.
- A shortened/corrected clip body does **not** replace a longer stored one
  (longest-wins is deliberately conservative to protect annotation
  anchors). Documented in CLI reference.
- Re-importing a **URL-less note** has no match key and **creates a
  duplicate**. Accepted for v1: title-based matching for arbitrary notes is
  unsafe (two distinct "Meeting notes.md" files must not merge). Documented
  in CLI reference.

### 9. Sync/compat summary

- No new columns, no new CKRecord fields → `SyncSchemaInvariantTests`
  untouched. All mapped fields (`webContent`, `url`, `abstract`,
  `accessedDate`, `issuedMonth/Day`, …) already sync.
- New enum rawValue `"Markdown"`: old peers fall back to `.other` on decode
  (existing CKRecord fallback + the two new tolerant-decode layers in §2).
- New select option: appended by local deterministic migration (v5
  pattern) **plus** remote-apply reconciliation (§2) so an old peer's push
  can't remove it. Neither path marks the record dirty.

### 10. Testing

**RubienCoreTests / `MarkdownImporterTests`** (primary loop):
- Real Obsidian clipping fixture → full field mapping (title, url, siteName,
  authors with `[[…]]` stripping, published → y/m/d, created → accessedDate,
  description → abstract, body stripped of frontmatter, format `.markdown`).
- Fallback chain: no frontmatter + H1 first line (title taken, H1 removed
  from body); no H1 → filename; nil filename → "Untitled".
- Frontmatter plausibility: thematic-break document (`---` prose `---`) →
  body fully preserved, no metadata; unclosed `---` → whole file body;
  plausible-but-unrecognized keys (`aliases:` only) → stripped, no fields.
- Indentation/nesting: `metadata:\n  title: Wrong` sets no title; `|` and
  `>` block scalars (with modifiers) consume continuations and yield no
  fields.
- Quoting/flow lists: `author: ["Smith, John", "[[Jane Doe]]"]` → exactly
  two authors; single/double-quote unescaping; unsupported escapes kept
  literal.
- Date validation: `YYYY-MM-DD`/`YYYY-MM`/`YYYY`; `2025-02-31` rejected;
  leap day accepted; `2025-01-0199` rejected; `2026-07-09T10:00:00` →
  `2026-07-09`.
- Non-http(s) `source` ignored → type `.markdown`; http source →
  `.webpage`; frontmatter-only → `webContent` nil; empty file imports.
- `canOpenWebReader`: any type + content → true; `.markdown` no content →
  false; `.webpage` URL-only → true.
- **Merge policy (§8):** re-import of an existing URL keeps the curated
  title (fill-only); fill-only fields never overwrite; longest-content-wins
  for the body.
- **FTS integration:** import a note with a unique body token via
  `AppDatabase`, find it through `searchReferences`.
- **Migration v6:** fresh DB has the Markdown option once; via
  `runV6MigrationForTesting` a v5-shaped DB appends exactly once
  (idempotent); existing option order/colors/unknown JSON fields preserved;
  malformed `optionsJSON` left untouched (no wipe); **no dirty-queue entry
  emitted** (applyingRemote suppression verified).
- **Reconciliation:** applying a remote six-option Type definition on an
  upgraded device re-appends Markdown without dirtying the record.
- Decode hardening: GRDB row AND Codable JSON decode of an unknown
  `referenceType` string → `.other` (no trap, no throw).
- Export mappings: `.markdown` → BibTeX `@misc`, RIS `TY  - GEN`, CSL
  `document`.

**RubienCLITests** (JSON contracts):
- `import note.md` → `{"imported":"1"}`; fields visible via `get`.
- `import folder/` with `.md` files → envelope incl. default stamping
  (`Tags` = basename); `--property`/`--value` override; `failed` reporting.
- Folder with `.bib` only → Zotero; **both `.bib` and `.md` → ambiguity
  error; `--format md` forces markdown routing**; neither → error.
- `echo … | import - --format md` works; stdin without frontmatter titles
  "Untitled".
- `update --type Markdown` round-trips; `list --type Markdown` filters.

**RubienSyncTests:** CKRecord round-trip for a `.markdown` reference;
unknown-type record decodes to `.other`; old-peer-six-options →
reconciliation test (finding-1 scenario).

**mcp-server:** schema/argument-forwarding test for `format: "md"` and
markdown-folder `property`/`value`.

**App target:** reader rendering and annotation persistence for a URL-less
note stay **manual** — WKWebView tests deadlock the suite (known
constraint, see swift-test CLI hang note); multi-select panel and batch
summary verified manually alongside.

### 11. Implementation sequencing

1. **Core:** enum case + consumer checklist + tolerant decodes + v6
   migration (+ testing helper) + remote-apply reconciliation +
   `canOpenWebReader` + `MarkdownImporter` + merge policy +
   RubienCoreTests. (Builds and tests green on its own.)
2. **CLI:** import ext switch + folder routing (incl. ambiguity error) +
   stamping + stdin + `Docs/CLI-Reference.md` + RubienCLITests.
3. **App:** panel + button strings + `importFilesWithMetadata` coordinator
   split + `ReferenceDetailView` gate mirror + manual verify.
4. **MCP:** `io.ts` schema/descriptions + version + lockfile + test.

Each step is one coherent commit per the repo workflow (build + test +
codex-rescue + /simplify before each commit).

## Review log

- 2026-07-09: codex-rescue review (gpt-5.6-sol, effort medium) returned 15
  findings; 14 folded in (sync-convergence reconciliation, frontmatter
  plausibility rule, markdown-specific merge policy, structural JSON
  append, indentation/block-scalar/flow-list grammar tightening, tolerant
  Codable decode, coordinator-owned app batch state, FTS/migration/dirty-
  suppression/reconciliation tests, consumer checklist with hard-coded
  docs/tests, date validation, folder ambiguity error, MCP
  descriptions/lockfile/test). 1 adjusted: `.markdown` in manual-creation
  pickers is documented as accepted behavior rather than filtered.
