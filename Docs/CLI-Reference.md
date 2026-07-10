# rubien-cli — Command-Line Reference

`rubien-cli` is the companion CLI for the Rubien reference manager. It operates on the same GRDB database as the app, so changes made via CLI are immediately visible in the GUI and vice versa.

All commands output JSON to stdout (pretty-printed, sorted keys, ISO 8601 dates). Errors go to stderr as `{"error": "..."}`.

```
rubien-cli <subcommand> [options]
```

## Database location

| CLI binary | Resolved `library.sqlite` |
|---|---|
| Mac, embedded helper (`/Applications/Rubien.app/Contents/Helpers/rubien-cli`) | `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/library.sqlite` |
| Mac, SPM build | `~/Library/Application Support/Rubien/library.sqlite` |
| Linux | `$XDG_DATA_HOME/rubien/library.sqlite` (default: `~/.local/share/rubien/`) |

The signed app and its embedded helper share the App Group path; SPM dev builds use a separate path so experiments don't touch the real library. The first run between those modes performs a one-shot migration — see CLAUDE.md "Data layer" for the mechanics. Override anywhere with `RUBIEN_LIBRARY_ROOT=/path/to/dir`.

## Installing on `$PATH`

**Mac (signed app installed):** symlink the bundled helper. Updates pick up the new binary automatically.

```sh
sudo ln -sf /Applications/Rubien.app/Contents/Helpers/rubien-cli /usr/local/bin/rubien-cli
```

**Linux (or Mac SPM build):** install a release build.

```sh
swift build --product rubien-cli -c release
sudo install -m 755 .build/release/rubien-cli /usr/local/bin/rubien-cli
```

Linux needs system deps first — see [Linux CLI](../README.md#linux-cli). For dev iteration, `.build/debug/rubien-cli` (or `swift run rubien-cli`) is the canonical path on both platforms.

---

## Subcommands

| Command | Description |
|---------|-------------|
| `search` | Full-text search across the library |
| `list` | List references with filtering and sorting |
| `get` | Fetch a single reference by ID |
| `add` | Add a reference via identifier, BibTeX, or manual entry |
| `update` | Update fields on an existing reference |
| `delete` | Delete references by ID |
| `cite` | Generate formatted citations |
| `import` | Import from a BibTeX, RIS, Markdown, or PDF file; a direct PDF/Markdown URL; or a Zotero / Markdown folder |
| `export` | Export references as JSON, BibTeX, or RIS |
| `properties` | List or manage property definitions, options, and per-reference values (covers tags via the built-in `Tags` property) |
| `annotations` | List PDF annotations for a reference |
| `styles` | List available citation styles |
| `version` | Print the CLI marketing version and monotonic build number as JSON (`{"build":8,"version":"0.1.7"}`); the MCP server's version guard requires `build >= MIN_CLI_BUILD` |
| `self-update` | (Linux) Download the latest signed release and replace `rubien-cli` in place after verifying an ed25519 signature; `--check` reports `{current, latest, updateAvailable}` as JSON and changes nothing. On macOS it is a no-op (Rubien.app/Sparkle manages the bundled CLI). |
| `views` | Manage database views |
| `pdf info` | Probe PDF: page count, text-layer flag, and outline-derived sections |
| `pdf text` | Extract text from a reference's PDF by page range or section title |
| `pdf page-image` | Render a PDF page as a base64-encoded JPEG/PNG |
| `pdf status` | Show PDF cache + upload-queue state for a reference (JSON only) |
| `pdf download` | Fetch the open-access PDF for a reference and attach it (skip-if-attached; `--force` to replace) |
| `web get` | Read the extracted body of a clipped web reference |
| `web annotations` | List web-page annotations for a reference |
| `mcp` | Run a Model Context Protocol server over stdio, exposing the read APIs as MCP tools (the in-app Assistant content channel; a Node-free replacement for `rubien-mcp-server`). Mac **and** Linux. |
| `sync status` | Inspect iCloud sync state (JSON only). **Mac-only** — Linux builds omit this subcommand entirely. |

---

## search

Full-text search across the library. By default queries all 12 indexed FTS columns: `title`, `authorsNormalized` (alias `authors`), `journal`, `abstract`, `notes`, `webContent`, `siteName`, `doi`, `publisher`, `isbn`, `issn`, `institution`. Use `--in` to constrain (e.g. topic searches that should ignore notes/web content) and `--op or` to find references mentioning any of several terms.

```bash
rubien-cli search "neural network" --limit 10
rubien-cli search "transformer attention" --in title,abstract
rubien-cli search "diffusion gan" --op or --in title --limit 50
```

| Argument / Option | Type | Default | Description |
|---|---|---|---|
| `query` | String (required) | — | Search query (space-separated tokens) |
| `-l, --limit` | Int | 20 | Maximum results |
| `--in` | Comma list | (all 12 FTS columns) | Constrain to columns: `title`, `abstract`, `notes`, `authors`, `journal`, `doi`, `publisher`, `isbn`, `issn`, `institution`, `webContent`, `siteName` |
| `--op` | `and` \| `or` | `and` | Combinator across query tokens — `and` = every token must match; `or` = any token |

**Output:** JSON array of reference objects, ranked by full-text relevance (bm25, best match first). (`list --keyword` stays newest-first; use `search` when you want relevance ranking.)

---

## list

List references with comprehensive filtering and sorting.

```bash
rubien-cli list --author Smith --year-from 2020 --has-pdf
rubien-cli list --reading-status unread --sort-by year --asc
rubien-cli list --tag 3
```

| Option | Type | Default | Description |
|---|---|---|---|
| `-l, --limit` | Int | 0 (all) | Maximum results |
| `--offset` | Int | 0 | Skip first N results (pagination) |
| `--tag` | Int64 | — | Filter by tag ID |
| `--author` | String | — | Filter by author name (fuzzy) |
| `--year-from` | Int | — | Year lower bound |
| `--year-to` | Int | — | Year upper bound |
| `--journal` | String | — | Filter by journal (fuzzy) |
| `--type` | String | — | Filter by reference type (e.g. `"Journal Article"`) |
| `--has-pdf` | Flag | false | Only references with a PDF |
| `--keyword` | String | — | Keyword search across title, abstract, notes |
| `--reading-status` | String | — | Filter: `unread`, `reading`, `skimmed`, `read` |
| `--sort-by` | String | — | Sort field: `year`, `dateAdded`, `title` |
| `--asc` | Flag | false | Sort ascending (default descending) |

**Output:** JSON array of reference objects.

---

## get

Fetch a single reference by ID.

```bash
rubien-cli get 42
```

| Argument | Type | Description |
|---|---|---|
| `id` | Int64 (required) | Reference ID |

**Output:** JSON reference object.

---

## add

Add a reference via DOI / arXiv / PMID / PMCID / ISBN / paper-landing URL, BibTeX string, or manual title.

```bash
rubien-cli add --identifier "10.1038/s41586-021-03819-2"
rubien-cli add --identifier "2106.04561" --download-pdf
rubien-cli add --identifier "PMC4587766"
rubien-cli add --identifier "https://pmc.ncbi.nlm.nih.gov/articles/PMC4587766/"
rubien-cli add --identifier "https://openreview.net/forum?id=YicbFdNTTy" --download-pdf
rubien-cli add --identifier "https://aclanthology.org/2025.acl-long.1141.pdf" --download-pdf
rubien-cli add --identifier "https://openaccess.thecvf.com/content/CVPR2025/html/Wang_VGGT_Visual_Geometry_Grounded_Transformer_CVPR_2025_paper.html" --download-pdf
rubien-cli add --bibtex '@article{..., title={...}, ...}'
rubien-cli add --title "My Paper"
```

| Option | Type | Description |
|---|---|---|
| `--identifier` | String | DOI, arXiv ID, PMID, PMCID, ISBN, or a paper landing-page URL — metadata is fetched automatically. Supported URL hosts: `openreview.net`, `aclanthology.org`, `openaccess.thecvf.com`, `papers.nips.cc`, `proceedings.neurips.cc`, `proceedings.mlr.press`, `ieeexplore.ieee.org`, `dl.acm.org`, `nature.com`, `link.springer.com`, `sciencedirect.com`. Paper URLs are scraped via `<meta name="citation_*">` tags; if the page includes a `citation_doi`, the resolver re-fetches via CrossRef for canonical fields. Direct PDF URLs (e.g. `aclanthology.org/<id>.pdf`) are rewritten to their landing pages before scraping. PMCIDs (`PMC1234567` or `pmc.ncbi.nlm.nih.gov/articles/PMC.../`) resolve via NCBI's ID converter then delegate to PubMed/CrossRef. |
| `--bibtex` | String | BibTeX source string (can contain multiple entries) |
| `--title` | String | Title for manual entry (creates a minimal reference) |
| `--download-pdf` | Flag | Only valid with `--identifier`. After metadata lookup, fetch the open-access PDF. For DOI / arXiv / PMID / PMCID inputs, the open-access PDF is resolved via arXiv (preprints) or OpenAlex's best-OA-location (any DOI). For paper-URL inputs, the PDF URL is taken from `citation_pdf_url` on the scraped page — this makes `--download-pdf` work on OpenReview / CVF / PMLR papers that have no DOI. The reference is saved either way; PDF failures are reported in the envelope rather than aborting. |

Exactly one of `--identifier`, `--bibtex`, or `--title` is required.

**Output:** JSON envelope `{ "reference": ReferenceDTO, "status": "created" | "existing", "pdfDownload": PDFDownloadStatusDTO | null }`. For `--bibtex`, output is a JSON array of envelopes, one per parsed entry.

- `status` is always one of:
  - `"created"` — a new reference row was inserted.
  - `"existing"` — the input matched an existing reference (deduped by normalized DOI / PMID / PMCID / ISBN / URL / ISSN+title+year); `mergedReference` folded any non-empty incoming fields into the existing row. `reference.id` is the existing row's id.
- `pdfDownload` is always present (explicit `null`, not omitted):
  - `null` when `--download-pdf` was not set.
  - `{ "ok": Bool, "action": String?, "filename": String?, "error": String? }` when `--download-pdf` was set. `action` values: `"downloaded"`, `"already-attached"`, `"already-pending"` (cache row exists but the file hasn't been materialized yet — sync will deliver it), `"skipped"` (no DOI/arXiv identifier AND no scraped `citation_pdf_url` — happens for raw title-only entries or DOI-less paper URLs whose landing page omitted the PDF link). The command exits 0 regardless of `pdfDownload.ok`.

---

## update

Update fields on an existing reference.

```bash
rubien-cli update 42 --title "New Title" --year 2024
rubien-cli update 42 --reading-status read
rubien-cli update 42 --clear-field doi --clear-field abstract
```

| Argument / Option | Type | Description |
|---|---|---|
| `id` | Int64 (required) | Reference ID |
| `--title` | String | Title |
| `--year` | Int | Publication year |
| `--authors` | String | Authors (`"Last, First; Last, First"`) |
| `--type` | String | Reference type (e.g. `"Book"`) |
| `--journal` | String | Journal name |
| `--volume` | String | Volume |
| `--issue` | String | Issue |
| `--pages` | String | Pages (e.g. `"100-110"`) |
| `--doi` | String | DOI |
| `--url` | String | URL |
| `--abstract` | String | Abstract |
| `--notes` | String | Notes |
| `--publisher` | String | Publisher |
| `--isbn` | String | ISBN |
| `--issn` | String | ISSN |
| `--language` | String | Language |
| `--edition` | String | Edition |
| `--reading-status` | String | `unread`, `reading`, `skimmed`, `read` |
| `--clear-field` | String (repeatable) | Clear a field (e.g. `--clear-field doi --clear-field abstract`) |

Valid `--clear-field` values: `year`, `journal`, `volume`, `issue`, `pages`, `doi`, `url`, `abstract`, `notes`, `publisher`, `isbn`, `issn`, `language`, `edition`.

**Output:** JSON updated reference object.

---

## delete

Delete references by ID.

```bash
rubien-cli delete 42 43 44
rubien-cli delete 42 --force
```

| Argument / Option | Type | Default | Description |
|---|---|---|---|
| `ids` | Int64 array | — | Reference IDs to delete |
| `-f, --force` | Flag | false | Skip confirmation prompt |

**Output:** JSON `{"deleted": "id1,id2,..."}`.

---

## cite

Generate formatted citations.

```bash
rubien-cli cite 42 --style apa
rubien-cli cite 42 43 --style ieee --format bibliography
```

| Argument / Option | Type | Default | Description |
|---|---|---|---|
| `ids` | Int64 array (required) | Reference IDs |
| `-s, --style` | String | `apa` | Style: `apa`, `mla`, `chicago`, `ieee`, `harvard`, `vancouver`, `nature` |
| `--format` | String | `text` | Output format: `text`, `bibliography`, `docx-cc` |

**Output formats:**

- **`text`:** `{"style": "...", "inline": "...", "bibliography": ["..."]}`
- **`bibliography`:** `{"style": "...", "entries": ["..."]}`
- **`docx-cc`:** `{"tag": "...", "text": "...", "style": "...", "isShortTag": bool, "fallbackPayload": "..."}`

---

## import

Import references from a BibTeX (`.bib`), RIS (`.ris`), Markdown (`.md` / `.markdown`), or PDF (`.pdf`) file; from a direct HTTP(S) PDF/Markdown file URL; or from a Zotero "Export Collection… with files" folder or a folder of Markdown files. Use `"-"` to read from stdin (pass `--format`).

```bash
rubien-cli import references.bib
cat paper.ris | rubien-cli import - --format ris

# Markdown note or Obsidian Web Clipper file
rubien-cli import "Solving OPSD.md"
cat note.md | rubien-cli import - --format md

# Local PDF or a direct PDF/Markdown URL
rubien-cli import ./papers/attention-is-all-you-need.pdf
rubien-cli import https://arxiv.org/pdf/1706.03762.pdf
rubien-cli import https://example.com/notes/reading-list.markdown

# Zotero folder (a directory containing one .bib plus files/NNN/*.pdf)
rubien-cli import ~/Downloads/RL
rubien-cli import ~/Downloads/RL --property Project --value "RL Research"

# Markdown folder (a directory of .md notes / clippings)
rubien-cli import ~/Obsidian/Clippings
rubien-cli import ~/Obsidian/Clippings --property Tags --value reading-list
```

| Argument / Option | Type | Description |
|---|---|---|
| `file` | String (required) | Local file/folder path, direct HTTP(S) URL with a `.pdf`, `.md`, or `.markdown` path extension, or `"-"` for stdin |
| `--format` | String | Format hint: `bib`, `ris`, or `md`. Required for stdin; also forces folder routing (see below). It cannot override a direct URL's extension. |
| `--property` | String | Folder import only: property name to stamp (default `Tags`) |
| `--value` | String | Folder import only: value to stamp (default: folder basename) |

Text-file size limit (single-file, and per file inside a folder): 50 MB; text input must be UTF-8. When reading from stdin, `--format` is required.

### PDF files and direct URLs

Local PDF paths may be relative to the current working directory. A direct URL must use `http` or `https` and have a `.pdf`, `.md`, or `.markdown` path extension; Rubien validates the response before importing it. PDF responses require a 2xx status, `application/pdf` content type, and PDF magic bytes. Markdown responses require a compatible text content type, valid UTF-8, and a 50 MB maximum.

PDFs enter the same metadata verification pipeline as the app. A completed import reports the normal count/file fields plus `status: "imported"`; an unresolved result is retained in the pending-metadata queue and reports `status: "queued"` with `intakeId`:

```json
{"file":"./paper.pdf","imported":"1","status":"imported"}
{"file":"https://example.com/paper.pdf","imported":"1","status":"queued","intakeId":42}
```

Acquisition and validation errors exit non-zero and write the standard JSON error envelope to stderr, for example `{"error":"Unsupported import file type: .html"}`. URL downloads are temporary and are removed after the import completes or fails.

### Markdown files

A `.md` / `.markdown` file — an Obsidian Web Clipper export or any plain note — imports as one reference. A leading YAML frontmatter block is parsed for metadata (only when it is plausible YAML; a stray `---` thematic break is never mistaken for frontmatter), and everything after it becomes the reference's Markdown **body**, readable and annotatable in the web reader. A file with no frontmatter and no body still imports as a metadata-only reference.

Frontmatter keys map to reference fields as follows (keys lowercase, as the Obsidian clipper emits them):

| Frontmatter key | Reference field | Notes |
|---|---|---|
| `title` | `title` | |
| `source` | `url` + `siteName` | Only when it parses as a valid `http`/`https` URL; anything else is ignored |
| `author` | `authors` | Scalar or list; `[[wiki-link]]` wrappers are stripped, then free-text name parsing (`author: ["Smith, John", "[[Jane Doe]]"]` → two authors) |
| `published` | `year` / `issuedMonth` / `issuedDay` | `YYYY-MM-DD`, `YYYY-MM`, or `YYYY`; calendar-validated (`2025-02-31` rejected), datetimes truncate at `T` |
| `created` | `accessedDate` | Stored as the literal `YYYY-MM-DD` |
| `description` | `abstract` | |
| `tags` | — | Ignored |
| anything else | — | Ignored |

The **title** falls back through: frontmatter `title` → a leading `# ` H1 line (which is then removed from the body so it isn't rendered twice) → the filename (basename without extension) → `Untitled` (for stdin). A file with a valid `source` URL imports as reference type `Web Page`; a URL-less note imports as `Markdown`.

**Re-import merge (fill-only).** Markdown imports use a conservative fill-only merge rather than the BibTeX/RIS merge:

- A **clipper file** (has a `source` URL) matches the existing reference for that URL — dedup keys are DOI → PMID → PMCID → ISBN → exact URL → ISSN+title+year, so a re-import merges into the reference created by the in-app web clipper too. Existing curated fields (`title`, `authors`, `abstract`, dates, `siteName`) are filled only when currently empty and are **never overwritten**; the **longer** body wins (a shortened re-clip won't replace a longer stored one — this protects annotation anchors).
- A **URL-less note** has no match key, so re-importing it **creates a duplicate** (title-based matching of arbitrary notes is unsafe — two different `Meeting notes.md` must not merge).

### Folder import

When `file` is a directory, Rubien routes by the files it contains (top level only — folder imports are **not** recursive):

- `.bib` present and no `.md` → **Zotero folder import** (see below);
- `.md` present and no `.bib` → **Markdown folder import**;
- **both** present → error `Ambiguous folder: contains both .bib and .md. Pass --format bib or --format md to choose.`;
- **neither** present → error `No importable files found (expected .bib or .md)`.

`--format bib` or `--format md` forces the branch (and errors `No .bib files found in folder` / `No .md files found in folder` if the folder lacks that kind).

**Markdown folder.** Every top-level `.md` file (sorted by name) parses exactly as a single Markdown file (above) and imports in one batch with the same fill-only merge. Each reference is stamped with one property value — `--property` (default `Tags`) set to `--value` (default: the folder's basename) — using the same property-stamping machinery as the Zotero path below (the built-in `Tags` value routes through the Tag table; a `number`/`date`/`checkbox` property is rejected). Unreadable, non-UTF-8, or oversized files are skipped and reported in `failed`.

**Zotero folder.** Expects an "Export Collection… with files" layout:

```
RL/
  RL.bib
  files/835/Paper A.pdf
  files/845/Paper B.pdf
```

- The parser reads the `file = {PDF:files/…/name.pdf:application/pdf}` field on each BibTeX entry, copies the referenced PDF into the library's PDF storage directory, and registers it in `pdfCache` so the reference appears as having a PDF. Non-PDF attachments are ignored.
- Each imported reference is stamped with one value on the chosen property. `Tags` (the default) routes through the Tag table; other `multiSelect`, `singleSelect`, `string`, and `url` properties are written to `propertyValue`. Passing `--property` with a `number`/`date`/`checkbox` type errors out.
- Re-importing the same folder is safe: existing references are merged (by DOI/PMID/PMCID/ISBN/arXiv/record key), tags aren't duplicated, and previously-copied PDFs aren't re-copied.
- Linked-file Zotero exports (absolute PDF paths) are reported in `missingPDFs`; re-export the collection with "Files copied into export" to attach them.

**Output (single-file / stdin):** JSON `{"imported": N, "file": "path"}`.

**Output (Markdown folder):** JSON `{"imported": N, "failed": "bad.md", "property": "Tags", "value": "Clippings", "file": "path"}` — `failed` is a comma-joined list of skipped basenames, empty string when none.

**Output (Zotero folder):** JSON `{"imported": N, "attached": M, "duplicatesSkipped": K, "missingPDFs": "a, b, c", "property": "Tags", "value": "RL", "file": "path"}`.

---

## export

Export references as JSON, BibTeX, or RIS.

```bash
rubien-cli export --format bibtex
rubien-cli export --format ris
```

| Option | Type | Default | Description |
|---|---|---|---|
| `-f, --format` | String | `json` | `json`, `bibtex`, `ris` |

**Output:** JSON array (default), or plain-text BibTeX/RIS to stdout.

---

## properties

Manage **property definitions**, **options**, and **per-reference values**. The seeded built-in `Tags` PropertyDefinition (`defaultFieldKey: "tags"`) routes through the `Tag` + `ReferenceTag` tables transparently, so all tag operations live here too — there is no separate `tags` subcommand.

> **Migrating from `rubien-cli tags`** (retired)
>
> | Old `tags` command | New `properties` equivalent |
> |---|---|
> | `tags` | `properties --name Tags` |
> | `tags --reference 42` | `properties --reference 42` (Tags appears in the listed values) |
> | `tags --create --name X --color #abc` | `properties --add-option --id <Tags id> --value X --color #abc` (returns the new tag's id as `value`) |
> | `tags --rename --id 5 --name Y` | `properties --rename-option --id <Tags id> --from 5 --to Y` |
> | `tags --delete 5` | `properties --delete-option --id <Tags id> --value 5 [--replace-with <other tag id>]` |
> | `tags --assign --reference 42 --tags 1,3,5` | `properties --set --add-value --reference 42 --id <Tags id> --value "1,3,5"` |
> | `tags --remove-tags --reference 42 --tags 3` | `properties --set --remove-value --reference 42 --id <Tags id> --value "3"` |
>
> Resolve `<Tags id>` once with `properties --name Tags` (or look it up by `defaultFieldKey == "tags"`).

```bash
rubien-cli properties                                              # List all definitions
rubien-cli properties --visible                                    # Only visible definitions
rubien-cli properties --id 3 --id 7                                # Subset by id (repeatable)
rubien-cli properties --name Tags --name modality                  # Subset by name (repeatable, exact)
rubien-cli properties --create --name "Status" \
  --type singleSelect --options "todo,doing,done"
rubien-cli properties --create --name "Themes" \
  --type multiSelect --options "ml,nlp,vision"
rubien-cli properties --rename --id 42 --name "Stage"
rubien-cli properties --show --id 42                               # Mark visible
rubien-cli properties --hide --id 42

# Options
rubien-cli properties --add-option --id 42 --value "blocked"       # Append option (creates a Tag for the Tags property)
rubien-cli properties --rename-option --id 42 --from "blocked" --to "stalled"
rubien-cli properties --delete-option --id 42 --value "stalled" --replace-with "doing"
rubien-cli properties --delete-option --id 42 --value "stalled" --clear-in-use   # clear it from affected references instead of migrating

# Definition lifecycle
rubien-cli properties --delete 42                                  # Deletes a custom definition; built-ins are refused

# Per-reference values
rubien-cli properties --set --reference 7 --id 42 --value "doing"
rubien-cli properties --set --reference 7 --id 43 --value "ml,nlp"           # multiSelect: replace
rubien-cli properties --set --add-value --reference 7 --id 43 --value "rl"   # multiSelect: idempotent add
rubien-cli properties --set --remove-value --reference 7 --id 43 --value "ml" # multiSelect: idempotent remove
rubien-cli properties --clear --reference 7 --id 42
rubien-cli properties --reference 7                                # List values set on reference 7
```

| Option | Type | Default | Description |
|---|---|---|---|
| `--visible` | Flag | false | Restrict the default list to visible definitions. Ignored when `--id` / `--name` is supplied — explicit selectors always win. |
| `--id` | Int64 (repeatable) | — | With operations: single property target. With list: repeatable filter selector. Errors with `unresolved-selectors` when any id doesn't exist. |
| `--name` | String (repeatable) | — | With `--create` / `--rename`: target name (single value). With list: repeatable filter selector (exact, case-sensitive). Errors with `unresolved-selectors` when any name doesn't match. |
| `--create` | Flag | false | Create a new definition (requires `--name` and `--type`) |
| `--type` | String | — | Property type (with `--create`): `string`, `url`, `number`, `singleSelect`, `multiSelect`, `date`, `checkbox` |
| `--options` | String | — | Comma-separated option values for `singleSelect`/`multiSelect` (with `--create`); colors auto-assigned |
| `--delete` | Int64 | — | Delete a definition by ID; built-in (`isDefault: true`) definitions are refused |
| `--rename` | Flag | false | Rename a definition (requires `--id` and `--name`) |
| `--show` | Flag | false | Mark a definition visible (requires `--id`) |
| `--hide` | Flag | false | Mark a definition hidden (requires `--id`) |
| `--add-option` | Flag | false | Append a select option (requires `--id` and `--value`). For the Tags property, creates a new Tag; the response's option `value` is the new tag's id. |
| `--rename-option` | Flag | false | Rename a select option (requires `--id`, `--from`, `--to`). Bulk-updates affected references. For Tags, `--from` is the stringified tag id; renames the underlying Tag without touching pivots. |
| `--delete-option` | Flag | false | Remove a select option (requires `--id`, `--value`). Errors `optionInUse` for in-use options unless `--replace-with` or `--clear-in-use` is supplied. For Tags, `--value` is the stringified tag id; `--replace-with` re-tags affected references before removing the old tag. |
| `--value` | String | — | Option value. For `multiSelect` (incl. Tags): comma-separated. With `--add-option` / `--rename-option` / `--delete-option` / `--set`. |
| `--color` | String | auto | Hex color (with `--add-option`); unused palette color auto-assigned if omitted |
| `--from` | String | — | Existing option value to rename (with `--rename-option`). For Tags, the stringified tag id. |
| `--to` | String | — | New option value (with `--rename-option`). For Tags, the new display name. |
| `--replace-with` | String | — | Replacement option for in-use values when deleting (with `--delete-option`). For Tags, the stringified id of another tag. |
| `--clear-in-use` | Flag | false | When deleting an in-use option (with `--delete-option`), clear it from affected references instead of refusing (singleSelect loses its value; multiSelect drops just this option). Mutually exclusive with `--replace-with`. |
| `--set` | Flag | false | Upsert a value on a reference (requires `--reference`, `--id`, `--value`). Replace semantics for `multiSelect`. Refused for column-backed built-ins (Status / Type / Year / DOI / URL); allowed for the Tags property (routes through `setTags`). |
| `--add-value` | Flag | false | Sub-mode of `--set`: additive on `multiSelect` (idempotent). |
| `--remove-value` | Flag | false | Sub-mode of `--set`: subtractive on `multiSelect` (idempotent). |
| `--clear` | Flag | false | Delete a value on a reference (requires `--reference` and `--id`). Refused for column-backed built-ins; for Tags it removes all of the reference's tag assignments. |
| `--reference` | Int64 | — | Reference ID (with `--set`, `--clear`, or alone to list that reference's values) |

**Output shapes:**

Listing (default): JSON array of `PropertyDefinition` objects. For the Tags property, `options` is one entry per Tag row:

```json
[
  {
    "id": "3",
    "name": "Tags",
    "type": "multiSelect",
    "options": [
      {"value": "1", "label": "Important", "color": "#FF0000"},
      {"value": "2", "label": "Read-Later", "color": "#34C759"}
    ],
    "sortOrder": 2,
    "isDefault": true,
    "defaultFieldKey": "tags",
    "isVisible": true
  },
  {
    "id": "7",
    "name": "modality",
    "type": "multiSelect",
    "options": [
      {"value": "ml",     "label": "ml",     "color": "#007AFF"},
      {"value": "nlp",    "label": "nlp",    "color": "#34C759"},
      {"value": "vision", "label": "vision", "color": "#FF9500"}
    ],
    "sortOrder": 12,
    "isDefault": false,
    "defaultFieldKey": null,
    "isVisible": true
  }
]
```

For non-Tags select properties, `value` and `label` are equal — they're both the option string. Always render `label`; address mutations by `value`. The Tags property uses the **stable tag id as `value`** so renames don't break stored references.

Listing with `--reference <id>`: JSON array of values on that reference (Tags appears here too when the reference has any tags, with `value` being the JSON-encoded array of stringified tag ids):

```json
[
  { "propertyId": "1", "name": "Status", "type": "singleSelect", "value": "doing" },
  { "propertyId": "3", "name": "Tags",   "type": "multiSelect",  "value": "[\"1\",\"2\"]" }
]
```

For `--set` on a `multiSelect` property, `value` in the output echoes the JSON-encoded string array the CLI stored (e.g. `"[\"ml\",\"nlp\"]"`), matching what the app decodes. For `--add-value` / `--remove-value`, the response is a confirmation dict naming the mode and the values applied.

Create/rename/show/hide/add-option/rename-option/delete-option: single `PropertyDefinition` object (same shape as listing entries). `--delete`/`--set`/`--clear` return a short confirmation dict.

**Selector behavior:**
- `--id` / `--name` are repeatable on the list operation. Operations that take a single target (`--rename`, `--set`, etc.) error if more than one is supplied.
- Explicit selectors override `--visible` filtering — passing `--id <hidden>` returns the property regardless.
- Any unresolved id or name aborts with a non-zero exit and `{"error": "unresolved-selectors", "ids": [...], "names": [...]}` on stdout.

**Guards:**
- `--delete` on a built-in definition (Tags, Type, Year, etc.) returns an error and leaves the row untouched.
- `--set` / `--clear` on a column-backed built-in (Status, Type, Year, DOI, URL) return an error — those properties live on the `Reference` fields. Use `update` for them. The Tags property is the exception: it routes through `setTags` transparently.

---

## annotations

List PDF annotations for a reference. PDF references only — for web-page annotations, use `web annotations`.

```bash
rubien-cli annotations 42
```

| Argument | Type | Description |
|---|---|---|
| `referenceId` | Int64 (required) | Reference ID |

**Output:** JSON array of `{id, type, color, pageIndex, selectedText, noteText}`.

---

## styles

List available citation styles.

```bash
rubien-cli styles
```

No options.

**Output:** JSON array of `{id, title, isBuiltin, citationKind}`.

---

## version

Print the CLI's marketing version and monotonic build number. The values are
baked into the binary at build time from `VERSION` / `BUILD.txt` (regenerated
into `Sources/RubienCLI/GeneratedVersion.swift` by
`scripts/generate-cli-version.sh`; `release.sh` regenerates and commits it each
release). The MCP server probes this on startup and refuses to run against a CLI
older than its `MIN_CLI_BUILD`, so `build` is the field that gates
compatibility — not the marketing `version`.

```bash
rubien-cli version
```

No options.

**Output:**

```json
{
  "build": 8,
  "version": "0.1.7"
}
```

---

## self-update

Update `rubien-cli` in place from the latest signed GitHub release. **Linux only** — on macOS it prints a no-op notice (Rubien.app updates the bundled CLI via Sparkle).

```
rubien-cli self-update [--check]
```

- `--check` — report the latest available version as JSON and change nothing.

On Linux, `self-update` downloads the latest `rubien-cli-*-linux-x86_64.tar.gz` and its `.sig` from the public releases repo, verifies the ed25519 signature with the public key compiled into the binary, and only then replaces the binary and its `*.resources` bundles (transactionally, with rollback on failure). It refuses to replace the binary with a build that is not strictly newer than the running one.

**Output** (`--check`):
```json
{
  "current" : "0.1.7",
  "latest" : "0.1.8",
  "updateAvailable" : true
}
```

---

## views

Manage database views (saved filter/sort/group configurations). `--query`
runs the full filter → sort → group pipeline client-side against the view's
scope.

```bash
rubien-cli views                                              # List all
rubien-cli views --create --name "Unread Papers"
rubien-cli views --create --name "Recent Reading" \
  --filters '[{"target":{"kind":"builtin","value":"readingStatus"},"op":"isAnyOf","value":{"kind":"selectKeys","value":["reading","read"]}}]' \
  --sorts '[{"target":{"kind":"builtin","value":"dateAdded"},"ascending":false}]' \
  --group-by '{"target":{"kind":"builtin","value":"dateAdded"},"dateBin":"month","collapsed":[],"showEmpty":false}'
rubien-cli views --query 3 --limit 50                         # Run the view's pipeline
rubien-cli views --rename 3 --name "Urgent Papers"
rubien-cli views --delete 3
```

| Option | Type | Default | Description |
|---|---|---|---|
| `--create` | Flag | false | Create a new view |
| `--name` | String | — | View name (with `--create` or `--rename`) |
| `--delete` | Int64 | — | Delete view by ID (default view cannot be deleted) |
| `--query` | Int64 | — | Execute the view's pipeline, print matching references |
| `-l, --limit` | Int | 0 (all) | Max results (with `--query`) |
| `--rename` | Int64 | — | Rename view by ID |
| `--filters` | String | `[]` | JSON `[ViewFilter]` (with `--create`) |
| `--sorts` | String | default sort | JSON `[ViewSort]` (with `--create`) |
| `--group-by` | String | — | JSON `GroupConfig` (with `--create`) |

### FieldTarget

Identifies the column a filter/sort/group targets. Tagged union:

```json
{"kind": "builtin", "value": "year"}
{"kind": "custom",  "value": 42}
```

Built-in `value` is one of: `title`, `authors`, `year`, `journal`,
`referenceType`, `tags`, `readingStatus`, `dateAdded`, `dateModified`,
`lastReadAt`, `readCount`, `doi`, `publisher`, `volume`, `issue`, `pages`,
`pdfAttached`.

Custom `value` is a `propertyDefinition.id` (from `rubien-cli properties`).

### FilterValue

Tagged union; the variant must match the operator's expected payload type:

```json
{"kind": "text",       "value": "transformer"}
{"kind": "number",     "value": 2017}
{"kind": "date",       "value": "2026-01-15T00:00:00Z"}
{"kind": "datePreset", "value": {"preset": "lastNDays", "n": 7}}
{"kind": "selectKeys", "value": ["reading", "read"]}
{"kind": "bool",       "value": true}
{"kind": "none"}
```

Date presets: `today`, `yesterday`, `tomorrow`, `thisWeek`, `thisMonth`,
`thisYear`, `nextWeek`, `nextMonth`, `lastNDays` (requires `n`), `nextNDays`
(requires `n`).

`none` is used for the nullary operators (`isEmpty`, `isNotEmpty`,
`isChecked`, `isUnchecked`).

### Operators by field kind

Each column has a kind (derived from the field type). The valid operators
depend on the kind:

| Kind | Operators |
|---|---|
| text | `equals`, `notEquals`, `contains`, `notContains`, `startsWith`, `endsWith`, `isEmpty`, `isNotEmpty` |
| number | `equals`, `notEquals`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `isEmpty`, `isNotEmpty` |
| date | `equals`, `notEquals`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `isWithin`, `isEmpty`, `isNotEmpty` |
| singleSelect | `equals`, `notEquals`, `isAnyOf`, `isNoneOf`, `isEmpty`, `isNotEmpty` |
| multiSelect | `contains`, `notContains`, `containsAnyOf`, `containsNoneOf`, `containsAllOf`, `isEmpty`, `isNotEmpty` |
| checkbox | `isChecked`, `isUnchecked` |

`isWithin` expects a `datePreset` value. `isAnyOf`/`isNoneOf`/`contains*`
expect `selectKeys`. `contains`/`notContains` on multiSelect read only the
first element of `selectKeys` (the UI funnels them through the same editor).

### ViewFilter JSON format

```json
[
  {
    "target": {"kind": "builtin", "value": "readingStatus"},
    "op": "isAnyOf",
    "value": {"kind": "selectKeys", "value": ["unread", "reading"]}
  },
  {
    "target": {"kind": "builtin", "value": "year"},
    "op": "greaterThan",
    "value": {"kind": "number", "value": 2020}
  }
]
```

Filters AND together — a reference passes iff every filter matches.

### ViewSort JSON format

```json
[
  {"target": {"kind": "builtin", "value": "dateAdded"}, "ascending": false},
  {"target": {"kind": "builtin", "value": "title"},     "ascending": true}
]
```

Multi-column: first sort is primary, later sorts break ties. Nulls always
sort last. Sorts targeting a multiSelect kind are silently dropped.

### GroupConfig JSON format

```json
{
  "target": {"kind": "builtin", "value": "tags"},
  "dateBin": null,
  "customOrder": null,
  "collapsed": [],
  "showEmpty": false
}
```

Fields: `target` (required), `dateBin` (one of `week`, `month`, `year`; only
meaningful for date targets), `customOrder` (optional array of keys
overriding natural order), `collapsed` (UI state), `showEmpty` (seeds empty
buckets for every known option of a finite single-select). Grouping on text
or number kinds is disallowed.

### Output

Listing and create/rename emit a `DatabaseViewDTO`:

```json
{
  "id": 3,
  "name": "Recent Reading",
  "icon": "tablecells",
  "isDefault": false,
  "displayOrder": 1,
  "scope": {"all": {}},
  "columns": [/* [ColumnConfig] */],
  "filters": [/* [ViewFilter] — tagged-union shape above */],
  "sorts":   [/* [ViewSort]   — tagged-union shape above */],
  "groupBy": null,
  "dateCreated": "2026-04-15T10:30:00Z",
  "dateModified": "2026-04-15T10:30:00Z"
}
```

`--query` emits a reference array (same shape as `list` / `search`).

---

## pdf

Inspect, fetch, and extract content from a reference's attached PDF. The
read subcommands (`info` / `text` / `page-image`) operate on the local
file resolved via `AppDatabase.pdfFilename(for:)` (the per-device
`pdfCache` row's `localFilename`, joined to the library's PDF storage
directory). Text extraction is text-layer only (no OCR); scanned /
image-only PDFs return `hasTextLayer: false` and you should fall back to
`pdf page-image`. `pdf download` mutates: it fetches the open-access PDF
and attaches it to the reference.

### pdf info

Probe a PDF's structure before fetching content. Returns page count,
text-layer signal (sampled across first/middle/last page), file size,
encryption flag, embedded title, and the flattened outline. The outline's
`endPage` is computed via the "next entry at same-or-shallower level − 1"
rule so a parent section's range correctly spans all its descendants.

```bash
rubien-cli pdf info 42
```

| Argument | Type | Description |
|---|---|---|
| `id` | Int64 (required) | Reference ID |

**Output:**

```json
{
  "id": 42,
  "pageCount": 14,
  "hasTextLayer": true,
  "fileBytes": 1842331,
  "isEncrypted": false,
  "documentTitle": "Attention Is All You Need",
  "sections": [
    { "title": "1 Introduction", "level": 1, "startPage": 1, "endPage": 2 },
    { "title": "2 Background", "level": 1, "startPage": 3, "endPage": 4 },
    { "title": "3 Model Architecture", "level": 1, "startPage": 5, "endPage": 8 },
    { "title": "5 Conclusion", "level": 1, "startPage": 13, "endPage": 14 }
  ]
}
```

`sections` is `null` when the PDF has no outline at all — fall back to
`--pages` ranges in that case.

### pdf text

Extract page-keyed text. Two mutually-exclusive selection modes:

- `--pages <range>` — explicit page numbers (e.g. `1-3`, `1-3,8-10`, `12-`).
- `--section <title>` — case-insensitive substring match against the
  outline (repeatable; multiple flags union their ranges). Errors with
  `{"error":"no-outline"}` when the PDF has no outline.

```bash
rubien-cli pdf text 42 --pages 1-3
rubien-cli pdf text 42 --section Introduction --section Conclusion
rubien-cli pdf text 42 --section "Related Work" --max-chars 20000
```

| Argument / Option | Type | Default | Description |
|---|---|---|---|
| `id` | Int64 (required) | — | Reference ID |
| `--pages` | String | (all pages) | Page range, e.g. `1-3,8-10`. Mutually exclusive with `--section`. |
| `--section` | String (repeatable) | — | Section title substring (case-insensitive). Mutually exclusive with `--pages`. |
| `--max-chars` | Int | 50000 | Cap total returned characters. Truncates at page boundary; first page always included. |

**Output:**

```json
{
  "id": 42,
  "pageCount": 14,
  "selection": {
    "mode": "section",
    "requested": ["Related Work", "Conclusion"],
    "matchedSections": ["2 Related Work", "5 Conclusion"],
    "unmatched": []
  },
  "pages": [
    { "index": 3, "text": "...", "sectionPath": ["2 Related Work", "2.1 Transformers"] },
    { "index": 4, "text": "...", "sectionPath": ["2 Related Work", "2.2 Attention"] },
    { "index": 13, "text": "...", "sectionPath": ["5 Conclusion"] },
    { "index": 14, "text": "...", "sectionPath": ["5 Conclusion"] }
  ],
  "truncated": false,
  "hasTextLayer": true
}
```

`sectionPath` is the breadcrumb of containing sections (shallowest →
deepest); when several siblings share a page, the deepest/later one wins.
A page outside the outline gets `sectionPath: []`.

### pdf page-image

Render a single page as a base64-encoded image — useful for tables,
figures, equations, or pages where text extraction is sparse.

JPEG by default with quality stepdown to honor `--max-bytes`; PNG mode is
opt-in for lossless output but hard-fails on the byte cap.

```bash
rubien-cli pdf page-image 42 --page 7
rubien-cli pdf page-image 42 --page 1 --scale 3.0 --format png
```

| Argument / Option | Type | Default | Description |
|---|---|---|---|
| `id` | Int64 (required) | — | Reference ID |
| `--page` | Int (required) | — | Page number (1-indexed) |
| `--scale` | Double | 2.0 | Render scale (≈ 192 DPI at 2.0). 1.0 ≈ 96 DPI. |
| `--max-bytes` | Int | 2000000 | Hard cap on image bytes; JPEG retries at quality 0.9→0.75→0.6→0.45 |
| `--format` | `jpeg` \| `png` | `jpeg` | Output format |

**Output:**

```json
{
  "id": 42,
  "page": 7,
  "mimeType": "image/jpeg",
  "data": "<base64-encoded image bytes>",
  "widthPx": 1632,
  "heightPx": 2112,
  "qualityUsed": 0.9
}
```

`qualityUsed` is `null` for PNG output. The MCP wrapper decodes `data`
and re-emits as an MCP image content block so claude.ai chat displays
the page directly.

### pdf status

Diagnostic dump of a reference's `pdfCache` row + upload-queue state.
Used to answer "is this PDF cached locally on this device? what's its
hash? is it still pending upload?" without spelunking SQLite. Reads
only — never mutates.

```bash
rubien-cli pdf status 42
```

| Argument | Type | Description |
|---|---|---|
| `id` | Int64 (required) | Reference ID |

**Output (cached locally):**

```json
{
  "referenceId": 42,
  "cached": true,
  "localFilename": "abc-123_paper.pdf",
  "contentHash": "deadbeef...",
  "assetVersion": 1,
  "materializedAt": "2026-04-29T22:00:00Z",
  "lastOpenedAt": "2026-04-29T22:00:00Z",
  "inUploadQueue": false
}
```

**Output (no cache row at all):**

```json
{
  "referenceId": 999,
  "cached": false
}
```

When the reference has no `pdfCache` row, only `referenceId` and
`cached: false` are emitted — the optional fields are omitted entirely
so callers can rely on key presence as a signal. `cached` is `true`
only when `materializedAt` is non-null (the file has actually been
written to local storage on this device); a row whose `materializedAt`
is `null` is a pull-side placeholder waiting to be downloaded.

### pdf download

Fetch the open-access PDF for a reference and attach it. Resolution order:
arXiv direct (if the reference has an arXiv ID), then bioRxiv/medRxiv
direct (when `doi` starts with `10.1101/` AND `journal` is `bioRxiv` or
`medRxiv`), then OpenAlex OA lookup by DOI. Skip-if-attached by default;
`--force` detaches the existing PDF (file + cache row) and re-downloads.
Mirrors the GUI's detail-view "Download PDF" button.

```bash
rubien-cli pdf download 42
rubien-cli pdf download 42 --force
```

| Argument / Option | Type | Description |
|---|---|---|
| `id` | Int64 (required) | Reference ID |
| `--force` | Flag | Replace an existing attached PDF instead of skipping. Detaches and removes the old file before fetching. |

**Output (success):**

```json
{
  "id": 42,
  "ok": true,
  "action": "downloaded",
  "filename": "abc-2106.04561.pdf"
}
```

`action` values:

- `"downloaded"` — first attach for this reference.
- `"replaced"` — `--force` swapped out a prior PDF.
- `"already-attached"` — skip path; the file is on disk locally. `filename` is the existing filename.
- `"already-pending"` — a `pdfCache` row exists but `materializedAt` is `null` (sync will deliver the asset). `filename` is `null`. We do not re-fetch in this state to avoid colliding with the incoming sync delivery.

**Failure modes** (exit non-zero, `{"error": ...}` on stderr):

- Reference not found.
- Reference has no DOI or arXiv identifier (`canDownloadPDF` is false).
- Network failure or non-PDF response from the upstream source.
- DB write failure on attach.
- Verification read failure after attach (rare; library may need reconciliation — run `pdf download <id>` again).

**Cross-process sync kick.** After a successful attach, the CLI posts a
Darwin notification (`PDFUploadQueueBroadcaster`); the running app's
`SyncCoordinator` subscribes and kicks the PDF upload-queue drainer
immediately, so the new attachment uploads to CloudKit without waiting
for the next app launch.

---

## web

Read the extracted text and annotations of a clipped web reference.
Mirrors the `pdf` family for PDF references. Read-only — neither
subcommand fetches anything from the network; both surface what the
in-app WebReader has already extracted into the library.

```bash
rubien-cli web get 42
rubien-cli web get 42 --max-chars 5000 --start 0
rubien-cli web annotations 42
```

### web get

Returns the decoded body of `reference.webContent` along with `url`,
`siteName`, and an `annotationCount` so an agent can decide whether to
follow up with `web annotations`. The body is paginated by character
offset.

| Argument / Option | Type | Default | Description |
|---|---|---|---|
| `id` | Int64 (required) | — | Reference ID |
| `--max-chars` | Int | 50000 | Cap returned characters (must be > 0) |
| `--start` | Int | 0 | Character offset into the decoded body (must be >= 0) |

**Output:**

```json
{
  "id": 599,
  "url": "https://thinkingmachines.ai/blog/on-policy-distillation/",
  "siteName": "thinkingmachines.ai",
  "contentFormat": "html",
  "content": "<figure>...</figure><div>...</div>",
  "contentLength": 61273,
  "start": 0,
  "returnedChars": 50000,
  "truncated": true,
  "annotationCount": 3
}
```

- `contentFormat` is `"markdown"` (most pages — Defuddle/Readability
  output) or `"html"` (a small subset where the clipper preserved
  markup; the leading `<!-- rubien:web-content:html -->` sentinel that
  marks these in storage is stripped before output). Treat HTML output
  as a fragment, not a complete document.
- `contentLength` is the total decoded body length. Loop with `--start`
  bumped by `returnedChars` to read past the cap.
- `--start` past end-of-content returns `{ "content": "",
  "returnedChars": 0, "truncated": false }` (success, not error) so
  pagination loops terminate cleanly.

**Errors (stderr `{"error": "..."}`, exit 1):**
- Reference not found.
- Reference exists but has no web content (e.g. a PDF-only reference).
- Invalid `--max-chars` (<= 0) or `--start` (< 0).

### web annotations

Returns highlights, underlines, and anchored notes the user has made on
a clipped web reference.

| Argument | Type | Description |
|---|---|---|
| `referenceId` | Int64 (required) | Reference ID |

**Output:** JSON array of

```json
{
  "id": 7,
  "type": "highlight",
  "color": "#FFDE59",
  "noteText": "user's attached note, if any",
  "anchorText": "...",
  "prefixText": "... (text immediately before the anchor) ...",
  "suffixText": "... (text immediately after the anchor) ...",
  "dateCreated": "2026-04-22T10:14:00.000Z",
  "dateModified": "2026-04-22T10:14:00.000Z"
}
```

- `anchorText` is the highlighted string itself — what the in-app
  sidebar displays — and also the locator used to find the highlight
  inside the body returned by `web get`.
- `prefixText` / `anchorText` / `suffixText` form a W3C
  TextQuoteSelector: `prefixText` and `suffixText` disambiguate when
  `anchorText` appears more than once on the page.
- Empty array (not error) when the reference has no web annotations or
  the reference ID doesn't exist — same convention as the PDF
  `annotations` subcommand.

---

## mcp

Run a **Model Context Protocol (MCP) server over stdio**, exposing Rubien's
read APIs as MCP tools. This is the in-app Assistant sidebar's *content
channel* — the coding-agent runtime (Claude Code / Codex) connects to it and
reads the document under discussion through these tools — and a **Node-free**
replacement for the `rubien-mcp-server` npm package: the tool names, input
schemas, and outputs mirror it exactly, so the two are drop-in interchangeable.
Available on macOS **and** Linux.

```bash
# Wire into Claude Code (the app does this automatically via --mcp-config):
claude mcp add rubien -- rubien-cli mcp --read-only

# Or drive it by hand — newline-delimited JSON-RPC 2.0 on stdio:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rubien_get","arguments":{"id":1}}}' \
  | rubien-cli mcp --read-only
```

| Option | Type | Default | Description |
|---|---|---|---|
| `--read-only` | Flag | (implied) | Register only read-only tools. Currently the only supported mode — writes are not yet exposed over MCP, so the flag is accepted for forward-compatibility and the server is read-only with or without it. |

**Protocol.** Speaks JSON-RPC 2.0 over stdio (newline-delimited messages, one
per line): `initialize` (echoes the client's `protocolVersion`, advertises the
`tools` capability and `serverInfo`), `tools/list`, `tools/call`, and `ping`.
Notifications (`notifications/initialized`, etc.) get no response. Unknown
methods return error `-32601`; unknown tools return `-32602`. Diagnostics go to
stderr; stdout carries only protocol messages.

**Tools** (all `readOnlyHint: true`) — the read tools from the four content
families, each mapping to the identical subcommand documented above:

| Tool | Backing subcommand |
|---|---|
| `rubien_search` | `search` |
| `rubien_list` | `list` |
| `rubien_get` | `get` |
| `rubien_pdf_info` | `pdf info` |
| `rubien_pdf_text` | `pdf text` |
| `rubien_pdf_page_image` | `pdf page-image` (returned as an MCP `image` content block + a text metadata block) |
| `rubien_annotations_list` | `annotations` |
| `rubien_web_get` | `web get` |
| `rubien_web_annotations` | `web annotations` |

**Errors.** A tool whose backing command exits non-zero (e.g. a missing
reference, a reference with no attached PDF) returns a normal result with
`isError: true` and the CLI's error message as text — not a protocol error —
so the agent sees it in-band. Missing/invalid arguments surface the same way.

**Library selection.** Like every other subcommand, the server resolves the
library via `RUBIEN_LIBRARY_ROOT` / the standard storage-root order; the
running app sets `RUBIEN_LIBRARY_ROOT` so the server reads the app's live
library. Each `tools/call` runs the corresponding `rubien-cli` subcommand as a
child process, so tool output is byte-identical to that subcommand.

---

## sync status

**Mac-only.** The subcommand is not registered on Linux builds (CloudKit doesn't exist there); `rubien-cli sync --help` returns "unknown subcommand".

Prints iCloud sync state as JSON. Never instantiates the CloudKit sync
engine — reads `syncState` / `tombstone` / `syncSession` tables directly
and probes entitlement / iCloud availability via OS-level APIs. Safe to
run while the app is using the library (acquires and releases the sync
file lock only to read `appLockHeld`).

### Example

```bash
$ rubien-cli sync status
{
  "appLockHeld" : false,
  "baselineState" : "complete",
  "containerIdentifier" : "iCloud.com.rubien.app",
  "dirtyByEntityType" : { "reference" : 3, "tag" : 0 },
  "enabled" : true,
  "entitlementPresent" : true,
  "iCloudAccountAvailable" : true,
  "pdfBackfillRemaining" : 0,
  "schemaVersion" : "v1",
  "syncEngineState" : {
    "sidecarExists" : true,
    "sidecarLastModified" : "2026-04-22T14:32:11Z",
    "sidecarPath" : "/Users/.../Rubien/sync-engine-state.bin"
  },
  "tombstoneCount" : { "confirmed" : 12, "unconfirmed" : 0 }
}
```

### Fields

- `enabled` — user's preference value (UserDefaults `"rubien.sync.enabled"`)
- `containerIdentifier` — resolved container ID, with env-var override applied
- `entitlementPresent` — Info.plist entitlement probe
- `iCloudAccountAvailable` — `FileManager.ubiquityIdentityToken != nil`
- `appLockHeld` — non-blocking probe of the sync file lock; `true` means the app is currently using CloudKit
- `baselineState` — `"pending"` or `"complete"`
- `dirtyByEntityType` — per-table count of rows with `isDirty=1`
- `tombstoneCount` — `.confirmed` (server ack'd) vs `.unconfirmed` (pending delete)
- `pdfBackfillRemaining` — count of `pdfUploadQueue` rows pending push (B8). Drains automatically when sync is enabled and the flag is on; non-zero means PDFs imported on this device haven't been pushed to CloudKit yet
- `syncEngineState` — sidecar-file metadata
- `schemaVersion` — DB migration version

---

## Reference JSON Shape

All commands that return references use this structure:

```json
{
  "id": 42,
  "title": "Attention Is All You Need",
  "authors": "Ashish Vaswani, Noam Shazeer, ...",
  "year": 2017,
  "journal": "Advances in Neural Information Processing Systems",
  "volume": "30",
  "issue": null,
  "pages": null,
  "doi": "10.48550/arXiv.1706.03762",
  "url": "https://arxiv.org/abs/1706.03762",
  "siteName": "arxiv.org",
  "abstract": "The dominant sequence transduction models...",
  "referenceType": "Conference Paper",
  "dateAdded": "2024-01-15T10:30:00Z",
  "dateModified": "2024-01-15T10:30:00Z",
  "pdfPath": "abc-1706.03762.pdf",
  "notes": null,
  "isbn": null,
  "issn": null,
  "publisher": null,
  "language": "en",
  "edition": null,
  "readingStatus": "unread",
  "lastReadAt": "2026-05-12T15:30:00.000Z",
  "readCount": 3,
  "customProperties": [
    {"propertyId": "17", "name": "Status", "type": "singleSelect", "value": "doing"},
    {"propertyId": "18", "name": "Tags2",  "type": "multiSelect",  "value": "[\"ml\",\"nlp\"]"}
  ]
}
```

`customProperties` is always present (may be an empty array). Each entry corresponds to a **non-default** property definition that has a value set on this reference; built-in fields like `year` and `doi` live at the top level. For `multiSelect`, `value` is a JSON-encoded `[String]` literal — decode it client-side.

`pdfPath` is the **local filename** of the attached PDF (relative to the library's PDF storage directory), resolved per-device through `pdfCache`. Compose it with the library's PDF directory (printed by `rubien-cli sync status` or visible in Settings) to get an absolute path. The field is `null` when this device has no materialized PDF for the reference — it may still arrive via sync.

`lastReadAt` is the most-recent reader-open timestamp (ISO-8601), stamped automatically whenever the PDF or web reader opens the reference. The field is **omitted entirely** (not `null`) when the reference has never been opened in a reader post-v4 — Swift `Date?` semantics. Sort or filter by it via the standard sort/filter DSL (key: `"lastReadAt"`).

`readCount` is the count of distinct reading sessions. Each reader open bumps the counter at most once per ~10-minute window (so quick-toggle flows don't inflate it). Always present in JSON; `0` for references that haven't been opened. Sort or filter by it via `"readCount"`.

`siteName` is the source-site name for a clipped web reference (e.g. `"arxiv.org"`, `"thinkingmachines.ai"`). Omitted entirely (not `null`) for references that aren't web clips. `webContent` (the extracted body) is **not** included in this DTO — fetch it via `rubien-cli web get <id>` to keep `list`/`search`/`export` payloads predictable in size.

---

## Reference Types

Valid values for `--type`:

```
Journal Article, Conference Paper, Book, Thesis, Web Page, Markdown, Other
```
