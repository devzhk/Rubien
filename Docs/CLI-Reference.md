# rubien-cli — Command-Line Reference

`rubien-cli` is the companion CLI for the Rubien reference manager. It operates on the same GRDB database as the app (`~/Library/Application Support/Rubien/`), so changes made via CLI are immediately visible in the GUI and vice versa.

All commands output JSON to stdout (pretty-printed, sorted keys, ISO 8601 dates). Errors go to stderr as `{"error": "..."}`.

```
rubien-cli <subcommand> [options]
```

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
| `import` | Import from BibTeX or RIS file |
| `export` | Export references as JSON, BibTeX, or RIS |
| `tags` | List or manage tags |
| `properties` | List or manage custom property definitions and per-reference values |
| `annotations` | List PDF annotations for a reference |
| `styles` | List available citation styles |
| `views` | Manage database views |

---

## search

Full-text search across title, authors, journal, abstract, notes, DOI, and other indexed fields.

```bash
rubien-cli search "neural network" --limit 10
```

| Argument / Option | Type | Default | Description |
|---|---|---|---|
| `query` | String (required) | — | Search query |
| `-l, --limit` | Int | 20 | Maximum results |

**Output:** JSON array of reference objects.

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

Add a reference via DOI/PMID/arXiv ID, BibTeX string, or manual title.

```bash
rubien-cli add --identifier "10.1038/s41586-021-03819-2"
rubien-cli add --bibtex '@article{..., title={...}, ...}'
rubien-cli add --title "My Paper"
```

| Option | Type | Description |
|---|---|---|
| `--identifier` | String | DOI, PMID, or arXiv ID — metadata is fetched automatically |
| `--bibtex` | String | BibTeX source string (can contain multiple entries) |
| `--title` | String | Title for manual entry (creates a minimal reference) |

Exactly one of `--identifier`, `--bibtex`, or `--title` is required.

**Output:** JSON reference object (or array if BibTeX contains multiple entries).

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

Import references from a BibTeX (`.bib`) or RIS (`.ris`) file, or from a Zotero "Export Collection… with files" folder. Use `"-"` to read BibTeX/RIS from stdin.

```bash
rubien-cli import references.bib
cat paper.ris | rubien-cli import - --format ris

# Zotero folder (a directory containing one .bib plus files/NNN/*.pdf)
rubien-cli import ~/Downloads/RL
rubien-cli import ~/Downloads/RL --property Project --value "RL Research"
```

| Argument / Option | Type | Description |
|---|---|---|
| `file` | String (required) | File path, folder path, or `"-"` for stdin |
| `--format` | String | Format hint for stdin: `bib`, `ris` |
| `--property` | String | Folder import only: property name to stamp (default `Tags`) |
| `--value` | String | Folder import only: value to stamp (default: folder basename) |

File size limit (single-file mode): 50 MB. When reading from stdin, `--format` is required.

### Folder import behaviour

When `file` points at a directory, Rubien expects a Zotero export layout:

```
RL/
  RL.bib
  files/835/Paper A.pdf
  files/845/Paper B.pdf
```

- The parser reads the `file = {PDF:files/…/name.pdf:application/pdf}` field on each BibTeX entry, copies the referenced PDF into `~/Library/Application Support/Rubien/PDFs/`, and sets the new reference's `pdfPath` accordingly. Non-PDF attachments are ignored.
- Each imported reference is stamped with one value on the chosen property. `Tags` (the default) routes through the Tag table; other `multiSelect`, `singleSelect`, `string`, and `url` properties are written to `propertyValue`. Passing `--property` with a `number`/`date`/`checkbox` type errors out.
- Re-importing the same folder is safe: existing references are merged (by DOI/PMID/PMCID/ISBN/arXiv/record key), tags aren't duplicated, and previously-copied PDFs aren't re-copied.
- Linked-file Zotero exports (absolute PDF paths) are reported in `missingPDFs`; re-export the collection with "Files copied into export" to attach them.

**Output (single-file mode):** JSON `{"imported": N, "file": "path"}`.

**Output (folder mode):** JSON `{"imported": N, "attached": M, "duplicatesSkipped": K, "missingPDFs": "a, b, c", "property": "Tags", "value": "RL", "file": "path"}`.

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

## tags

List or manage tags, assign/remove tags from references.

```bash
rubien-cli tags                                  # List all
rubien-cli tags --create --name "Important" --color "#FF0000"
rubien-cli tags --assign --reference 42 --tags "1,3,5"
rubien-cli tags --remove-tags --reference 42 --tags "3"
rubien-cli tags --reference 42                   # List tags for reference
rubien-cli tags --rename --id 1 --name "Critical"
rubien-cli tags --delete 3
```

| Option | Type | Default | Description |
|---|---|---|---|
| `--create` | Flag | false | Create a new tag |
| `--name` | String | — | Tag name (with `--create` or `--rename`) |
| `--color` | String | auto | Hex color (with `--create`); an unused palette color is auto-assigned if omitted |
| `--delete` | Int64 | — | Delete tag by ID |
| `--assign` | Flag | false | Append tags to a reference |
| `--remove-tags` | Flag | false | Remove tags from a reference |
| `--reference` | Int64 | — | Reference ID (with `--assign`, `--remove-tags`, or to list) |
| `--tags` | String | — | Comma-separated tag IDs (with `--assign` or `--remove-tags`) |
| `--rename` | Flag | false | Rename a tag |
| `--id` | Int64 | — | Tag ID (with `--rename`) |

**Output:** JSON array of `{id, name, color}`.

---

## properties

List or manage **custom property definitions** (built-in "default" properties such as DOI/Year/Type are read-only via this command — use `update` for those) and per-reference **property values**.

```bash
rubien-cli properties                                              # List all definitions
rubien-cli properties --visible                                    # Only visible definitions
rubien-cli properties --create --name "Status" \
  --type singleSelect --options "todo,doing,done"
rubien-cli properties --create --name "Tags2" \
  --type multiSelect --options "ml,nlp,vision"
rubien-cli properties --rename --id 42 --name "Stage"
rubien-cli properties --show --id 42                               # Mark visible
rubien-cli properties --hide --id 42
rubien-cli properties --add-option --id 42 --value "blocked"
rubien-cli properties --delete 42                                  # Deletes a custom definition; built-ins are refused
rubien-cli properties --set --reference 7 --id 42 --value "doing"
rubien-cli properties --set --reference 7 --id 43 --value "ml,nlp" # multiSelect: CSV → stored as JSON [String]
rubien-cli properties --clear --reference 7 --id 42
rubien-cli properties --reference 7                                # List values set on reference 7
```

| Option | Type | Default | Description |
|---|---|---|---|
| `--visible` | Flag | false | Restrict the default list to visible definitions |
| `--create` | Flag | false | Create a new definition (requires `--name` and `--type`) |
| `--name` | String | — | Property name (with `--create` or `--rename`) |
| `--type` | String | — | Property type (with `--create`): `string`, `url`, `number`, `singleSelect`, `multiSelect`, `date`, `checkbox` |
| `--options` | String | — | Comma-separated option values for `singleSelect`/`multiSelect` (with `--create`); colors auto-assigned |
| `--delete` | Int64 | — | Delete a definition by ID; built-in (`isDefault: true`) definitions are refused |
| `--rename` | Flag | false | Rename a definition (requires `--id` and `--name`) |
| `--show` | Flag | false | Mark a definition visible (requires `--id`) |
| `--hide` | Flag | false | Mark a definition hidden (requires `--id`) |
| `--add-option` | Flag | false | Append a select option (requires `--id` and `--value`; color auto-assigned if `--color` omitted) |
| `--id` | Int64 | — | Property definition ID |
| `--value` | String | — | Option value (with `--add-option` or `--set`); for `multiSelect` pass comma-separated values |
| `--color` | String | auto | Hex color (with `--add-option`); unused palette color auto-assigned if omitted |
| `--set` | Flag | false | Upsert a value on a reference (requires `--reference`, `--id`, `--value`); refused for built-in properties |
| `--clear` | Flag | false | Delete a value on a reference (requires `--reference` and `--id`); refused for built-in properties |
| `--reference` | Int64 | — | Reference ID (with `--set`, `--clear`, or alone to list that reference's values) |

**Output shapes:**

Listing (default): JSON array of `PropertyDefinition` objects:

```json
{
  "id": "1",
  "name": "Status",
  "type": "singleSelect",
  "options": [
    {"value": "todo",  "color": "#007AFF"},
    {"value": "doing", "color": "#34C759"},
    {"value": "done",  "color": "#FF9500"}
  ],
  "sortOrder": 5,
  "isDefault": false,
  "defaultFieldKey": null,
  "isVisible": true
}
```

Listing with `--reference <id>`: JSON array of values on that reference:

```json
[{ "propertyId": "1", "name": "Status", "type": "singleSelect", "value": "doing" }]
```

For `--set` on a `multiSelect` property, `value` in the output echoes the JSON-encoded string array the CLI stored (e.g. `"[\"ml\",\"nlp\"]"`), matching what the app decodes.

Create/rename/show/hide/add-option: single `PropertyDefinition` object (same shape as listing entries). `--delete`/`--set`/`--clear` return a short confirmation dict.

**Guards:**
- `--delete` on a built-in definition (e.g. Type, Year) returns an error and leaves the row untouched. Use `update --clear-field <name>` on the reference instead for built-in values.
- `--set` / `--clear` on a built-in property return an error — built-in properties live on the `Reference` fields, not the `propertyValue` table. Use `update` for those.

---

## annotations

List PDF annotations for a reference.

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
`referenceType`, `tags`, `readingStatus`, `dateAdded`, `dateModified`, `doi`,
`publisher`, `volume`, `issue`, `pages`, `pdfAttached`.

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
  "abstract": "The dominant sequence transduction models...",
  "referenceType": "Conference Paper",
  "dateAdded": "2024-01-15T10:30:00Z",
  "dateModified": "2024-01-15T10:30:00Z",
  "pdfPath": "/path/to/file.pdf",
  "notes": null,
  "isbn": null,
  "issn": null,
  "publisher": null,
  "language": "en",
  "edition": null,
  "readingStatus": "unread",
  "customProperties": [
    {"propertyId": "17", "name": "Status", "type": "singleSelect", "value": "doing"},
    {"propertyId": "18", "name": "Tags2",  "type": "multiSelect",  "value": "[\"ml\",\"nlp\"]"}
  ]
}
```

`customProperties` is always present (may be an empty array). Each entry corresponds to a **non-default** property definition that has a value set on this reference; built-in fields like `year` and `doi` live at the top level. For `multiSelect`, `value` is a JSON-encoded `[String]` literal — decode it client-side.

---

## Reference Types

Valid values for `--type`:

```
Journal Article, Magazine Article, Newspaper Article, Preprint,
Book, Book Section, Conference Paper, Thesis, Dataset, Software,
Standard, Manuscript, Interview, Presentation, Blog Post,
Forum Post, Legal Case, Legislation, Web Page, Report, Patent, Other
```
