# Unified Reference Export — Design Spec

**Date:** 2026-07-27

**Status:** Reviewed v3 — ready for implementation

**Review:** Claude design review adjudicated and incorporated on 2026-07-28.
Repository-level correctness, efficiency, and simplicity reviews were
incorporated on 2026-08-04. They clarified grouped table order, typed Core
errors, DTO byte compatibility, chunking for every unbounded ID query, and
race-safe file publication.

**Scope:** `RubienCore`, `rubien-cli`, both MCP servers, and the macOS library UI

## 1. Summary

Rubien will expose one reference-export contract across Core, CLI, MCP, and
the macOS app. A caller chooses:

1. a **scope** — the whole library, explicit reference IDs, or a saved view;
2. a **format** — Rubien JSON, BibTeX, or RIS; and
3. a surface-specific **destination** — stdout/path in the CLI, an MCP result,
   or a user-selected file in the app.

The shared Core path resolves a coherent snapshot of full references and then
encodes it. Core never prints, opens a save panel, or chooses an arbitrary
filesystem destination.

The existing command remains backward-compatible:

```bash
rubien-cli export --format bibtex
```

It still exports the whole library to stdout. The new contract adds selected
IDs, saved-view scope, safe direct-to-file output, MCP selection, and app UI.

## 2. Motivation

The current exporter is implemented entirely inside the CLI's `Export.run`:

- it starts with `AppDatabase.shared.fetchAllReferences()`, so every export is
  whole-library;
- BibTeX/RIS encoding and citation-key generation are CLI-private helpers;
- the macOS app cannot reuse the encoder even though
  `ReferenceTableView` already owns multi-selection;
- `rubien_export` says it supports “the library (or a subset),” but its schema
  exposes only `format`;
- the native and npm MCP wrappers rely on the same whole-library CLI command;
- the current `format` switch treats every unknown value as JSON;
- explicit-ID ordering is not available, and `fetchReferences(ids:)` does not
  promise caller order;
- BibTeX citation keys depend on the exported set, so naïvely adding selected
  export would let one paper change from `Smith2025` to `Smith2025a`;
- the current collision suffix pass assigns `a` to both the first and second
  reference in a collision group, so colliding exports can contain duplicate
  keys; and
- the encoders omit several bibliographic fields Rubien already stores.

Export is a read operation, but bibliographic correctness matters: silently
exporting the wrong scope or unstable keys is worse than returning an error.

## 3. Goals and non-goals

### Goals

- One testable export implementation shared by every surface.
- Whole-library, explicit-ID, and saved-view scopes.
- Exact current-view and selected-row export in the macOS app.
- Backward-compatible whole-library CLI and MCP calls.
- Deterministic ordering and scope-stable citation keys for an unchanged
  library snapshot.
- Safe, atomic CLI/app file writes.
- Strict validation with structured CLI errors that survive MCP wrapping.
- Better BibTeX/RIS coverage of existing `Reference` metadata.
- Native/npm MCP schema and output parity.
- Foundation-only Core implementation that builds on macOS and Linux.

### Non-goals

- A full-library backup or restore format. BibTeX/RIS/Rubien JSON do not include
  PDF bytes, annotations, web-reader bodies, CloudKit state, or every app
  preference.
- Exporting PDFs alongside metadata or producing a ZIP archive.
- Adding CSL-JSON, EndNote XML, CSV, or Markdown in v1.
- Exporting arbitrary inline filter expressions from the CLI/MCP. Callers use
  explicit IDs or a saved view; `list` remains the query surface.
- Interactive terminal selection.
- Allowing MCP callers to write arbitrary host filesystem paths.
- Persisting a user-editable citation-key column in v1. That would require a
  new immutable migration, CloudKit field mapping, sync round-trip coverage,
  and CLI data-layer parity.
- Expanding or breaking the existing Rubien JSON `ReferenceDTO` schema.
- Preserving byte-for-byte BibTeX/RIS output. The command/result contracts stay
  compatible, but corrected escaping, stable keys, and added metadata
  intentionally improve the generated text.
- Treating the export as an exact BibTeX import round trip. Rubien does not
  currently preserve every unknown BibTeX field or the imported entry key.

## 4. Product terminology

The umbrella capability is **Export References**:

- **BibTeX** and **RIS** are bibliography/interchange exports.
- **Rubien JSON** is the existing automation-oriented reference DTO export.
- None of the three is labeled **Back Up Library**.

App help text must say that PDFs, annotations, and notes are not included in
BibTeX/RIS. Rubien JSON retains its existing fields (including `notes`,
`readingStatus`, PDF filename, and custom-property values) for compatibility,
but it is still not a restorable archive.

### 4.1 Compatibility boundary

- Existing no-scope CLI and MCP invocations retain their meaning.
- Existing CLI stdout and MCP result *shapes* remain unchanged.
- Rubien JSON keys, omission rules, formatting, and date encoding remain
  unchanged.
- BibTeX/RIS remain valid text in the same formats, but their bytes may change
  because field coverage, collision suffixes, and escaping are deliberately
  fixed. Non-colliding citation keys retain the current `AuthorYear` shape.
- Whole-library JSON gains an explicit ID tie-breaker only when two references
  have the same `dateAdded`; this rare ordering change buys deterministic
  output and does not change any DTO.

The BibTeX/RIS behavior change is called out in release notes; it is not
presented as a byte-compatible refactor.

## 5. Normative Core contract

The shared types live in `RubienCore`:

```swift
public enum ReferenceExportFormat: String, CaseIterable, Sendable {
    case json
    case bibtex
    case ris
}

public enum ReferenceExportScope: Sendable, Equatable {
    case all
    case ids([Int64])
    case savedView(Int64)
}

public struct ReferenceExportRequest: Sendable, Equatable {
    public let format: ReferenceExportFormat
    public let scope: ReferenceExportScope
}

public struct ReferenceExportArtifact: Sendable, Equatable {
    public let format: ReferenceExportFormat
    public let data: Data
    public let referenceCount: Int
    public let filenameExtension: String
    public let mediaType: String
}

public struct ReferenceExportService: Sendable {
    public init(database: AppDatabase)
    public func export(_ request: ReferenceExportRequest) throws
        -> ReferenceExportArtifact
}

public enum ReferenceExportError: Error, Equatable, Sendable {
    case emptySelection
    case unresolvedReferenceIDs([Int64])
    case savedViewNotFound(Int64)
}
```

`ReferenceExportService` receives an `AppDatabase`; it never reaches through
`AppDatabase.shared`. Tests can therefore use an isolated database.

The initial format metadata is:

| Format | Extension | Media type | Encoding |
|---|---|---|---|
| Rubien JSON | `json` | `application/json` | UTF-8 |
| BibTeX | `bib` | `application/x-bibtex` | UTF-8 |
| RIS | `ris` | `application/x-research-info-systems` | UTF-8 |

The service produces bytes only. Suggested display filenames belong to the
calling surface because the app knows the view name and the CLI knows the
requested output path.

### 5.1 Coherent snapshot

One export observes one logical database snapshot. Scope resolution, full
reference fetches, custom-property/PDF filename data needed by Rubien JSON,
saved-view query context, and library-wide identity data needed for citation
keys are read inside one GRDB read transaction.

The implementation adds a database-level export snapshot API rather than
composing several public methods that each open an independent read. This
prevents a concurrent edit/delete from producing references from one instant
and properties or collision keys from another.

This is a deliberate AppDatabase plumbing refactor, not a thin wrapper around
the current public calls. The implementation adds the narrowly scoped
`db: Database`-taking internals needed by export and saved-view listing for:

- all-reference and explicit-ID fetches;
- saved-view scope/filter/sort resolution;
- reference/tag mappings;
- property definitions and all/scoped property values;
- materialized PDF filenames and attached-reference IDs; and
- the lightweight whole-library identity rows used for citation keys.

The saved-view query and export snapshot call the internals from one outer
read. Every unbounded `IN` query, including explicit references, property
values, and PDF filenames, is chunked at 500 IDs. Caller ordering is rebuilt
from an ID map after chunks are fetched. Public methods become wrappers only
where sharing a database-taking helper is useful; unrelated one-line reads do
not need mechanical wrapper pairs.

The snapshot contains only the data required by the chosen format:

- BibTeX/RIS do not fetch PDF filenames or custom property values.
- Rubien JSON fetches property definitions, values for the exported IDs, and
  local `pdfCache` filenames in bulk, preserving the current no-N+1 behavior.
- BibTeX fetches lightweight identity/key context for the library in addition
  to the full scoped rows.

### 5.2 Scope semantics

#### Whole library

`.all` preserves the existing `fetchAllReferences()` order: descending
`dateAdded`, with ascending `id` as a deterministic tie-breaker. The tie-break
is an intentional whole-library JSON ordering clarification documented in the
compatibility boundary.

#### Explicit IDs

`.ids`:

1. requires at least one ID;
2. removes duplicate IDs while preserving the first occurrence;
3. returns references in that caller-provided order; and
4. fails the entire export if any requested ID is unresolved.

It never silently returns a partial bibliography. The structured CLI error is:

```json
{
  "error": "unresolved-reference-ids",
  "ids": ["57", "91"]
}
```

IDs are strings in the error envelope, matching the repository's existing
unresolved-selector convention and avoiding JSON-number portability issues.
This remains a dedicated `unresolved-reference-ids` error rather than reusing
the property-selector-specific envelope: both MCP wrappers already forward the
CLI's raw structured error, so no additional wrapper parser is introduced.

#### Saved view

`.savedView(id)` resolves the saved view's persisted scope, filters, and sorts
with no pagination. Grouping and collapsed-group presentation never remove
rows from export.

The existing CLI-private `querySavedView` logic moves behind a reusable
`AppDatabase` API; `list --view` and export call the same implementation.
An unknown view fails with:

```json
{"error":"view-not-found","id":"7"}
```

#### Current app view

“Current View” is intentionally represented as `.ids(orderedVisibleIDs)`, not
`.savedView`. At the instant the user invokes export, the table captures the
processed row IDs in displayed order. This includes:

- the active sidebar scope;
- unsaved view filters and sorts;
- transient search text; and
- all rows inside collapsed groups.

The later save-panel interaction cannot change the captured scope. Full rows
are re-fetched by ID so the table's light-row observation is never used as the
bibliographic source.

#### Empty scopes

- `.ids([])` throws `ReferenceExportError.emptySelection`; it must not
  accidentally mean “all.”
- A valid `.all` or `.savedView` that matches zero rows succeeds:
  - JSON uses the existing pretty-printed empty-array bytes plus a trailing
    newline;
  - BibTeX/RIS are zero bytes.
- App actions with zero eligible rows are disabled and explain why in help
  text, so users do not normally create empty files.

## 6. Encoding architecture

The implementation separates snapshot resolution from pure encoding:

```text
ReferenceExportRequest
        │
        ▼
database snapshot resolver
        │ ordered full references + format context
        ▼
pure format encoder
        │
        ▼
ReferenceExportArtifact
```

The pure encoders accept value types and perform no database, filesystem,
AppKit, logging, or process I/O. They are directly covered by
`RubienCoreTests`.

`ReferenceDTO` and `CustomPropertyValueDTO` move from `RubienCLI` into
`RubienCore` as public `Sendable` values, including the public mapping
initializer, without changing their encoded keys or values. The frozen shape
includes `siteName`, omitted-nil `lastReadAt`, required `readCount`, an
always-present `customProperties` array, and materialized-only `pdfPath`. Existing
`get`/`list`/`search`/`add`/JSON-export call sites use the moved types, keeping
one JSON wire model rather than creating an export-only duplicate.

## 7. Citation-key contract

Selected export must not change a paper's key merely because its colliding
neighbor was omitted. V1 therefore generates keys against the library-wide
key context from the same snapshot, then emits only scoped references.

The base key preserves the current public shape:

```text
<first-author-family><year>
```

Examples:

```text
Vaswani2017
unknown0
```

Rules:

- use the first author's family name, falling back to lowercase `unknown`;
- use `year` only when it is in `1000...9999`, otherwise fall back to `0`;
- retain ASCII letters and digits from the family name; non-ASCII scalars are
  dropped, and if nothing remains the family becomes `unknown` (v1 avoids
  platform-dependent Foundation/ICU transliteration);
- if sanitizing a nonempty family removes every character, use `unknown`;
- keys are compared case-insensitively for collision detection; and
- the algorithm is pinned by tests and is not locale-dependent.

When multiple library rows share a base, all members receive `a`, `b`, …
according to the same deterministic whole-library order used by `.all`
(`dateAdded` descending, `id` ascending for a tie). This preserves the current
intended “first row gets `a`” behavior while fixing the implementation bug
that gives both the first and second rows `a`.

Suffixes continue `z`, `aa`, `ab`, … rather than relying on a single Unicode
scalar. For an unchanged library snapshot, a reference receives the same key
in whole-library, saved-view, current-view, and explicit-ID exports.

Scope stability deliberately wins over a cosmetically contiguous subset: a
single selected reference may be exported as `Smith2025c` even though that
file contains no `Smith2025a` or `Smith2025b`. Generated keys are not
time-stable: editing identity metadata or adding a newer colliding row can
renumber existing suffixes, as whole-library export can today. Persisted,
import-preserved citation keys are the future feature that can provide both
scope and time stability.

## 8. BibTeX contract

### 8.1 Entry types

| Rubien type | BibTeX type |
|---|---|
| Journal Article | `article` |
| Conference Paper | `inproceedings` |
| Book | `book` |
| Thesis with genre containing “master” (case-insensitive) | `mastersthesis` |
| Other Thesis | `phdthesis` |
| Web Page, Markdown, Other | `misc` |

### 8.2 Fields

Fields are emitted in the following stable order when nonempty:

| BibTeX field | Rubien source / rule |
|---|---|
| `title` | `title` (always emitted; whole value case-protected per §8.3) |
| `author` | `authors`, joined with `and` as `Family, Given` |
| `editor` | `parsedEditors`, same name grammar |
| `translator` | `parsedTranslators`; BibLaTeX-compatible extension |
| `year` | `year` |
| `month` | bare lowercase macro `jan`…`dec` from `issuedMonth` |
| `journal` | `journal`, for journal articles |
| `booktitle` | `eventTitle`, for conference papers |
| `volume` | `volume` |
| `number` | `issue` for articles; otherwise `number` |
| `pages` | `pages` |
| `publisher` | `publisher` |
| `address` | `publisherPlace`, falling back to `eventPlace` for conferences |
| `edition` | `edition` |
| `school` | `institution`, for theses |
| `series` | `collectionTitle` |
| `isbn` | `isbn` |
| `issn` | `issn` |
| `doi` | `doi` |
| `url` | `url` |
| `urldate` | `accessedDate` |
| `language` | `language` |
| `pmid` | `pmid`; extension field |
| `pmcid` | `pmcid`; extension field |

`notes`, reading activity/status, custom properties, verification provenance,
abstracts, web content, favicon, and local PDF paths are not emitted into
BibTeX. Abstracts remain available in RIS and Rubien JSON; excluding them from
default BibTeX keeps the artifact compact and avoids unexpectedly exporting
long prose.

### 8.3 Escaping and capitalization

All values use one scalar-by-scalar escaping pass. The implementation must not
perform cascading string replacements: the current backslash-then-brace helper
can re-escape braces introduced by an earlier replacement. At minimum escape
BibTeX/LaTeX structural characters `\`, `{`, `}`, `&`, `%`, `#`, `_`, `~`, and
`^`; preserve UTF-8 text. Normalize CRLF/CR to LF and prevent a field value
from closing its containing braces.

Rubien's importer intentionally strips BibTeX capitalization-protection braces
when storing a title, so the exporter cannot reconstruct which individual
words were protected in the source. To preserve the capitalization of the
stored title through common BibTeX processors, emit the entire escaped title
inside one additional protection group:

```bibtex
title = {{RNA-seq Analysis of iOS}},
```

The regular field delimiter remains the outermost brace pair; the extra inner
pair is title-specific. A semantic import/export round-trip test pins this
behavior without claiming byte-for-byte recovery of the original BibTeX.
Month is the only unbraced value: it is emitted as a standard BibTeX macro,
for example `month = jan,`.

Every entry ends with one newline and entries are separated by one blank line.
There is no locale-dependent formatting.

## 9. RIS contract

RIS keeps the current type mapping:

| Rubien type | RIS `TY` |
|---|---|
| Journal Article | `JOUR` |
| Conference Paper | `CONF` |
| Book | `BOOK` |
| Thesis | `THES` |
| Web Page | `ELEC` |
| Markdown, Other | `GEN` |

The encoder retains the current fields and adds existing extended metadata
where RIS has an established tag:

| RIS tag | Rubien source |
|---|---|
| `TI` | title |
| `AU` | one per author |
| `ED` | one per editor |
| `PY` | year |
| `DA` | issued `YYYY/MM/DD` when month/day are available |
| `JO` | journal |
| `T2` | `eventTitle` for Conference Paper; `collectionTitle` for Book; otherwise omitted |
| `VL` | volume |
| `IS` | issue |
| `SP`, `EP` | page range parsed by the rule below |
| `DO` | DOI |
| `UR` | URL |
| `SN` | one line for each nonempty ISBN and ISSN |
| `PB` | publisher |
| `CY` | publisher place / event place |
| `ET` | edition |
| `AB` | abstract |
| `LA` | language |
| `N1` | PMID/PMCID identifiers, one line each |
| `Y2` | accessed date |

Embedded CR/LF in a value is normalized to spaces so it cannot synthesize a
new RIS tag. Each record ends with `ER  -` and a blank line.

For pages, split once using the first delimiter found in this precedence:
`--`, en dash, em dash, then ASCII hyphen. Trim both sides; emit the left side
as `SP` and a nonempty right side as `EP`. When no delimiter is present, emit
the entire trimmed value as `SP` only. This keeps a BibTeX-style range such as
`123--130` from being misread as an empty endpoint.

As with BibTeX, app workflow data, annotations, web content, custom properties,
and local paths are excluded.

## 10. Rubien JSON contract

JSON export remains the existing `ReferenceDTO[]` array:

- no envelope is added;
- no existing key is removed or renamed;
- optional-key omission remains unchanged;
- custom property values and per-device PDF filename behavior remain
  unchanged; and
- output ends with a newline.

The moved encoder retains the current `.prettyPrinted` + `.sortedKeys` output
and ISO-8601 date strategy. Moving the DTO to Core is an ownership refactor,
not a formatting change.

Selection changes only which DTOs are present and their ordering.

Broader metadata coverage for JSON is a separate wire-contract proposal. It
must not be smuggled into this implementation merely because the DTO moves to
Core.

## 11. CLI contract

### 11.1 Syntax

```bash
# Existing: whole library, raw stdout
rubien-cli export --format bibtex

# Explicit IDs, preserving this order
rubien-cli export 42 57 91 --format bibtex

# Saved view, all matching rows
rubien-cli export --view 7 --format ris

# Atomic file output
rubien-cli export 42 57 --format bibtex --output papers.bib

# Explicit overwrite
rubien-cli export 42 57 --format bibtex --output papers.bib --force
```

Argument contract:

| Argument / option | Type | Default | Rule |
|---|---|---|---|
| `ids` | positional `Int64[]` | none | none means whole library; mutually exclusive with `--view` |
| `-f, --format` | `ReferenceExportFormat` | `json` | `json`, `bibtex`, `ris`; unknown values fail |
| `--view` | `Int64?` | none | mutually exclusive with positional IDs |
| `-o, --output` | path | none | none writes raw output to stdout |
| `--force` | flag | false | valid only with `--output`; permits replacement |

The CLI target adds the `ExpressibleByArgument` conformance in an extension;
`RubienCore` does not gain an ArgumentParser dependency. A typo such as
`--format bibttex` is an argument error, never a JSON fallback.

### 11.2 Output

Without `--output`, stdout remains exactly the export bytes:

- JSON array for `json`;
- plain BibTeX for `bibtex`; and
- plain RIS for `ris`.

Diagnostics/errors go to stderr. This preserves shell redirection:

```bash
rubien-cli export 42 57 -f bibtex > papers.bib
```

Raw artifacts are written with `FileHandle.standardOutput.write`; they never
pass through `print`, `printJSON`, or a `String` round-trip that could add a
newline or alter the bytes chosen by Core. JSON artifacts and file receipts use
a throwing encoder path so an encoding failure is reported rather than
silently replaced with fallback output.

With `--output`, the command atomically writes the artifact and prints this
receipt to stdout:

```json
{
  "format": "bibtex",
  "path": "/absolute/path/papers.bib",
  "referenceCount": 2
}
```

The path is standardized and absolute. The receipt is additive because
`--output` is new; the raw-stdout contract does not change.

### 11.3 File safety

- The parent directory must already exist.
- A pre-existing target fails unless `--force` is present.
- `--force` without `--output` is an argument error.
- Write a sibling temporary file, flush/close it, then publish with an atomic
  no-replace operation by default or atomic replacement with `--force`.
- A check-then-rename sequence is insufficient: another process must not be
  able to create and then lose the destination between those operations.
- Clean the temporary file on every failure.
- Never delete or truncate the destination before the replacement is ready.
- MCP wrappers never forward `--output` or `--force`.

## 12. MCP contract

Both native `rubien-cli mcp` and npm `rubien-mcp-server` expose:

```jsonc
rubien_export {
  "format": "json | bibtex | ris", // optional; default json
  "ids": [42, 57],                 // optional, minItems 1
  "view": 7                        // optional
}
```

Rules:

- `ids` and `view` are mutually exclusive.
- Omitting both preserves whole-library export.
- Supplying `ids: []` is invalid and never broadens to the whole library.
- The tool remains read-only and non-destructive.
- There is no MCP output-path argument.

The native JSON Schema may express the exclusivity with `oneOf`, but the npm
Zod tool shape cannot express the same cross-field refinement in every catalog
consumer. For exact native/npm catalog parity, both published schemas keep
`ids` and `view` independently optional, with their individual minimum
constraints. Both argv adapters then perform the same pre-launch validation:
when both are present they return exactly
`provide at most one of ids / view`. Empty `ids` is rejected by the native
`minItems` and npm `.min(1)` constraints before process launch.

The wrappers remain thin argv adapters:

```text
{format:"bibtex", ids:[42,57]}
    → export 42 57 --format bibtex

{format:"ris", view:7}
    → export --view 7 --format ris
```

V1 preserves existing result shapes:

- JSON: the `ReferenceDTO[]` tool text;
- BibTeX/RIS: `{"format":"bibtex|ris","text":"..."}`.

This avoids an unrelated MCP response break. Both MCP transports retain their
existing 32 MiB captured-output ceiling and return their existing oversized
output error when an export exceeds it. Downloadable MCP artifacts and
large-result resource links are future work.

The native catalog, npm Zod schema, README, catalog tests, argv tests, and
native/npm parity tests change together. The existing
`ReferenceAttribution.toolKeys["rubien_export"] = ["ids"]` mapping becomes
active for current sessions; `view` is a view ID and must never be attributed
as a reference.

## 13. macOS app contract

### 13.1 Entry points

The app adds a dedicated **Export** menu (`square.and.arrow.up`) to the
library's `ViewChromeBar`, separate from the main toolbar's existing import
menu:

- **Export Current View**
  - BibTeX…
  - RIS…
  - Rubien JSON…
- **Export Entire Library**
  - BibTeX…
  - RIS…
  - Rubien JSON…

When table selection is active, its batch toolbar and multi-row context menu
also expose **Export Selected** with the same three formats.

The app also adds **File → Export References…** with the standard
`⇧⌘E` shortcut. Following the existing `FocusedValues` /
`UpdateMenuCommands` pattern, `ContentView` exposes a focused-scene export
action rather than making the command reach into view state. The command opens
a compact configuration sheet with:

- a scope picker for Selected (when nonempty), Current View, and Entire
  Library;
- a format picker for BibTeX, RIS, and Rubien JSON; and
- Cancel and Continue actions.

Continue opens the same save-panel flow described in §13.3. The direct chrome,
batch-toolbar, and context-menu actions remain useful shortcuts: they already
know their scope and format and therefore skip the configuration sheet.

The labels always state the scope; a bare “Export” action must not make the
user guess between selection, current view, and library.

### 13.2 Selection handoff

`ReferenceTableView` continues to own its private selection set and processed
pipeline snapshot. It passes an export request to `ContentView` through:

```swift
onExport: (ReferenceExportIntent) -> Void
```

The UI-local intent contains the Core request and suggested basename.
`ReferenceTableView` derives ordered IDs by flattening the displayed group
buckets in bucket order (or using processed rows when ungrouped), stable-
deduplicating IDs for multi-select groups, and only then filtering selection.
It never iterates the unordered `Set` and never uses `visibleTableRowIDs`,
which intentionally omits rows in collapsed groups. It also supplies
`ViewChromeBar` with closures that capture the same snapshot, so the parent
does not maintain a second, eventually-consistent copy of visible IDs.

- Selected export uses selected rows in grouped display order.
- Current-view export uses all rows in grouped display order, including rows
  inside collapsed groups and with multi-group duplicates removed.
- Entire-library export uses `.all`.
- Export does not clear the current selection.

### 13.3 Saving

The parent `ContentView` presents an `NSSavePanel` configured for the chosen
extension. Once the user approves a destination, it invokes
`ReferenceExportService` and atomically writes the returned bytes. Suggested
filenames are:

| Scope | Suggested basename |
|---|---|
| Selected | `rubien-selected-<count>` |
| Current named view | `rubien-<sanitized-view-name>` |
| Current unnamed/transient view | `rubien-current-view` |
| Entire library | `rubien-library` |

Normalize a view name to NFC, replace `/`, `:`, NUL, control characters, and
each run of whitespace with `-`, collapse repeated hyphens, and trim leading
or trailing punctuation. Limit the result to 80 user-perceived characters,
then trim again. If nothing remains, use `current-view`. Append the
format-specific extension only after truncating the basename.

The save panel owns overwrite confirmation. App writes use atomic replacement
and surface failures through the existing app error presentation. Cancellation
does not generate an error or write a file. Success shows a concise
“Exported N references” confirmation.

Selected/current-view row identities and order are captured before the panel
opens; entire-library `.all` is intentionally resolved by Core after approval.
reference metadata is read in the coherent export snapshot after the user
approves the destination. Export work runs off the main actor; only panel
presentation and UI state updates run on it. No library-change or sync
notification is emitted because export does not mutate the library.

## 14. Failure semantics

All validation occurs before destination mutation.

| Failure | Behavior |
|---|---|
| Unknown format | argument/schema error |
| IDs plus view | argument/schema error |
| Empty explicit ID list | argument/schema error |
| Missing reference IDs | structured `unresolved-reference-ids`; no output file |
| Missing view | structured `view-not-found`; no output file |
| Existing CLI destination without `--force` | error; original untouched |
| Encode failure | error; original untouched |
| Temporary write/rename failure | error; original untouched where atomic filesystem semantics permit |
| App save cancellation | clean cancellation |

Unsupported app-only fields are intentionally excluded according to the format
tables; their absence is not a per-reference warning.

Optional derived metadata retains the models' current tolerant behavior. For
example, malformed stored editor/translator JSON yields an empty parsed list,
so that optional field is omitted rather than making the entire export fail.
Tests pin this behavior so the export path does not accidentally become
stricter than existing reference reads.

Errors continue to use the CLI's existing JSON-to-stderr convention so both
MCP wrappers preserve structured details on a nonzero exit.

## 15. Testing

### 15.1 `RubienCoreTests`

Add pure encoder and isolated-database coverage:

1. all seven `ReferenceType` mappings;
2. BibTeX extended-field mapping and stable field order;
3. RIS extended-field mapping and stable tag order;
4. author/editor/translator encoding;
5. Unicode and every escaped BibTeX structural character;
6. the backslash/brace regression (one-pass escaping);
7. whole-title capitalization protection and semantic re-import;
8. RIS embedded-newline injection prevention;
9. semantic re-import of representative BibTeX/RIS output;
10. page-range delimiter precedence and single-page handling;
11. absence of notes/workflow/custom/PDF/abstract fields from BibTeX;
12. empty-format outputs;
13. explicit-ID input order and first-occurrence deduplication;
14. unresolved-ID all-or-nothing behavior;
15. saved-view scope/filter/sort behavior;
16. whole-library deterministic tie-breaking;
17. citation-key equality across all/IDs/view scopes;
18. collision uniqueness, including the former duplicate-`a` regression;
19. collision ordering past `z` and subset suffix gaps;
20. missing-field citation-key fallbacks;
21. tolerant omission of malformed optional editor/translator metadata;
22. a structural assertion, through a database wrapper/test hook, that one
    export invokes exactly one outer GRDB read transaction; and
23. byte-for-byte Rubien JSON regression fixtures.

### 15.2 `RubienCLITests`

Cover:

- existing no-ID whole-library commands;
- one and multiple positional IDs;
- saved view;
- IDs/view mutual exclusion;
- unknown format rejection;
- raw stdout for all formats;
- `--output` receipt and file bytes;
- no-overwrite default;
- `--force` atomic replacement;
- `--force` without output;
- missing parent directory;
- structured missing-ID/view errors; and
- selected BibTeX keys matching whole-library keys.

Each test continues to use its own temporary `RUBIEN_LIBRARY_ROOT` and
database, matching the current `RubienCLITests` isolation model. Closely
related assertions may share a fixture within one test method, but the suite
must not introduce a mutable database shared across test cases.

### 15.3 MCP tests

In both native and npm suites:

- schema includes `ids` and `view`;
- empty IDs and IDs+view reject before process launch;
- IDs+view returns exactly `provide at most one of ids / view` from both
  adapters;
- argv mapping preserves ID order;
- native/npm catalog parity remains exact;
- representative JSON/BibTeX/RIS results remain shape-compatible;
- missing-ID structured errors survive; and
- assistant attribution includes explicit reference IDs but not view IDs.

### 15.4 App tests and manual QA

Every new `RubienTests` file remains whole-file `#if os(macOS)` guarded.

Test pure scope/filename helpers and callback ordering. Manually verify:

- one selected row and a discontiguous multi-selection;
- current filtered/sorted/grouped view;
- collapsed groups still export all matching rows;
- entire library;
- format-specific extension and suggested filename;
- cancel;
- overwrite confirmation;
- read-only/unwritable destination error;
- success confirmation;
- selection remains after export; and
- app responsiveness on a large library.

## 16. Documentation

The implementation updates in the same commit(s):

- `Docs/CLI-Reference.md` with IDs, `--view`, `--output`, `--force`, receipts,
  examples, and error semantics;
- `mcp-server/README.md` with `rubien_export` selection;
- CLI/MCP help and descriptions, removing the currently false “or a subset”
  claim until the subset arguments land;
- app localization strings and help text; and
- any assistant tool-policy or contract snapshots affected by the schema.

No host list, Linux PDF backend, sync runbook, or release-runbook change is
required.

## 17. Delivery sequence

Keep each step buildable and testable:

1. **Core snapshot + encoders (highest risk):** first extract database-taking
   query internals and prove the one-read boundary, then add shared types,
   saved-view selection, the JSON DTO move, deterministic keys, and format
   tests.
2. **CLI surface:** IDs/view/output/force, structured errors, CLI docs/tests.
3. **MCP parity:** native and npm schemas/adapters/tests/README in lockstep.
4. **macOS UI:** export menu, selection callback, save panel, localization,
   app tests/manual QA.

Before committing the non-trivial implementation, follow the repository
workflow: build/test, independent `codex-rescue` review, three-way `/simplify`
sweep, decide/fix findings, then build/test again.

## 18. Acceptance criteria

The feature is complete when:

- the same Core encoder serves CLI, MCP, and app;
- existing `rubien-cli export --format <format>` behavior remains compatible;
- selected IDs and saved views export the exact intended references in
  deterministic order;
- current-view app export matches the visible processed rows at invocation;
- a paper has the same generated BibTeX key across scopes for an unchanged
  library;
- subset exports may contain intentional citation-key suffix gaps, and every
  emitted key remains unique;
- invalid/partial scopes never silently broaden or partially export;
- CLI/app file writes cannot truncate an existing destination before a
  successful replacement;
- native and npm MCP catalogs and representative results are identical;
- BibTeX/RIS exclude private app workflow data;
- JSON output remains byte-shape compatible; and
- macOS and Linux build/test gates pass.

## 19. Future work

- Persist and sync user-editable/import-preserved citation keys.
- Add CSL-JSON.
- Return large MCP exports as downloadable resources/artifacts.
- Decide whether `cite` should adopt export's strict unresolved-ID behavior or
  retain its current partial-result semantics; do not change that separate
  contract implicitly.
- Add a true library archive containing metadata, PDFs, annotations, web
  content, collections/views, and a manifest suitable for restore.
- Add configurable BibTeX dialects or citation-key templates if real usage
  warrants them.
