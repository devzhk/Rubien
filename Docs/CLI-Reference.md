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

Import references from a BibTeX (`.bib`) or RIS (`.ris`) file. Use `"-"` to read from stdin.

```bash
rubien-cli import references.bib
cat paper.ris | rubien-cli import - --format ris
```

| Argument / Option | Type | Description |
|---|---|---|
| `file` | String (required) | File path, or `"-"` for stdin |
| `--format` | String | Format hint for stdin: `bib`, `ris` |

File size limit: 50 MB. When reading from stdin, `--format` is required.

**Output:** JSON `{"imported": N, "file": "path"}`.

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

Manage database views (saved query + display configurations).

```bash
rubien-cli views                                              # List all
rubien-cli views --create --name "Unread Papers"
rubien-cli views --create --name "Recent Reading" \
  --filters '[{"field":"readingStatus","op":"equals","value":"reading"}]' \
  --sorts '[{"field":"dateAdded","ascending":false}]'
rubien-cli views --query 3 --limit 50                         # Run a view's query
rubien-cli views --rename 3 --name "Urgent Papers"
rubien-cli views --delete 3
```

| Option | Type | Default | Description |
|---|---|---|---|
| `--create` | Flag | false | Create a new view |
| `--name` | String | — | View name (with `--create` or `--rename`) |
| `--delete` | Int64 | — | Delete view by ID (cannot delete default) |
| `--query` | Int64 | — | Execute a view's saved query |
| `-l, --limit` | Int | 0 (all) | Max results (with `--query`) |
| `--rename` | Int64 | — | Rename view by ID |
| `--filters` | String | — | JSON `[ViewFilter]` (with `--create`) |
| `--sorts` | String | — | JSON `[ViewSort]` (with `--create`) |

### ViewFilter JSON format

```json
[
  {"field": "readingStatus", "op": "equals", "value": "unread"},
  {"field": "year", "op": "greaterThan", "value": "2020"}
]
```

**Fields:** `title`, `authors`, `year`, `journal`, `referenceType`, `tags`, `readingStatus`, `dateAdded`, `dateModified`, `doi`, `publisher`, `volume`, `issue`, `pages`, `pdfAttached`

**Operators:** `equals`, `notEquals`, `contains`, `notContains`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `isEmpty`, `isNotEmpty`, `isAnyOf`

### ViewSort JSON format

```json
[{"field": "dateAdded", "ascending": false}]
```

**Output:** JSON array of `{id, name, icon, isDefault, displayOrder, scope, filters, sorts, dateCreated, dateModified}` when listing; single object on create/rename; reference array on `--query`.

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
