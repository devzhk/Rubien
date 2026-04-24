# Database View — Filter, Sort, Group

Notion/Airtable-style filter/sort/group system for Rubien's reference table. A
"view" is a persisted `DatabaseView` row (name + icon + scope + columns +
filters + sorts + groupBy) that the UI renders via a pure-Swift pipeline
running after the scope-narrowed fetch.

This doc is for engineers extending the system — adding field types, operators,
value editors, or new engines. End-user behavior is not described here.

---

## Data Model

All types live in `Sources/RubienCore/Models/`. Engines live in
`Sources/RubienCore/Filters/`.

### `FieldTarget`

Tagged union identifying any filterable/sortable/groupable column. Built-ins
come from `ColumnIdentifier` (title, authors, year, readingStatus, dateAdded,
tags, pdfAttached, etc.); custom columns reference `PropertyDefinition.id`.

```swift
enum FieldTarget {
    case builtin(ColumnIdentifier)
    case custom(Int64)
}
```

`FieldTarget.valueKind(propertyDefs:)` returns a `FieldValueKind` (`.text`,
`.number`, `.date`, `.singleSelect`, `.multiSelect`, `.checkbox`). Every
downstream decision — which operators are allowed, which value editor shows,
whether the column can be sorted or grouped — keys off this kind.

### `FilterValue`

Typed payload. Operator chooses the variant; the value editor switches on the
matching case. `.none` is used for nullary operators (`isEmpty`, `isChecked`,
etc.).

```swift
enum FilterValue {
    case text(String)
    case number(Double)
    case date(Date)
    case datePreset(DatePreset)
    case selectKeys([String])
    case bool(Bool)
    case none
}
```

`DatePreset` covers the closed set `today | yesterday | tomorrow | thisWeek |
thisMonth | thisYear | nextWeek | nextMonth | lastNDays(Int) | nextNDays(Int)`.
`DatePresetResolver` turns a preset into a `Range<Date>` around a reference
`now`, which is threaded through `PipelineContext` so tests and single render
passes are deterministic.

### `ViewFilter`, `ViewSort`, `GroupConfig`

```swift
struct ViewFilter { var target: FieldTarget; var op: FilterOperator; var value: FilterValue }
struct ViewSort   { var target: FieldTarget; var ascending: Bool }
struct GroupConfig {
    var target: FieldTarget
    var dateBin: DateBin?      // week | month | year, only for date targets
    var customOrder: [String]? // drag-reordered group keys
    var collapsed: Set<String> // UI state, per-view
    var showEmpty: Bool        // only meaningful for finite single-select universes
}
```

### `DatabaseView`

GRDB record backing the `databaseView` table. Holds string-encoded JSON
blobs plus metadata:

| Column            | Content                                                           |
|-------------------|-------------------------------------------------------------------|
| `scopeJSON`       | `ViewScope` — `all` or `tag(Int64)`                               |
| `columnsJSON`     | `[ColumnConfig]` — visibility + order                             |
| `filtersJSON`     | `[ViewFilter]`                                                    |
| `sortsJSON`       | `[ViewSort]`                                                      |
| `groupByJSON`     | `GroupConfig?` (nullable)                                         |
| `columnWrapsJSON` | `[String]` — sorted `customizationID`s whose columns render wrapped. Presence ≡ wrapped. Array (not `[String: Bool]`) so the dirty-compare baseline is stable and `{}` vs `{"foo": false}` can't diverge. |

Decoders live on the struct (`parsedFilters`, `parsedSorts`, `parsedGroupBy`,
`parsedColumnWraps`, etc.) so call sites work with typed values, not raw JSON.

---

## JSON Contract

`FieldTarget`, `FilterValue`, and `DatePreset` have **custom `Codable`**
producing `{"kind": "...", "value": ...}` rather than Swift's synthesized
`{"builtin": {"_0": "year"}}`. The custom shape is part of the CLI contract;
the synthesized shape was rejected as fragile and ugly for hand-authored
payloads.

**FieldTarget:**
```json
{"kind": "builtin", "value": "year"}
{"kind": "custom",  "value": 42}
```

**FilterValue:**
```json
{"kind": "text",       "value": "transformer"}
{"kind": "number",     "value": 2017}
{"kind": "date",       "value": "2026-01-15T00:00:00Z"}
{"kind": "datePreset", "value": {"preset": "lastNDays", "n": 7}}
{"kind": "selectKeys", "value": ["reading", "read"]}
{"kind": "bool",       "value": true}
{"kind": "none"}
```

**ViewFilter** example (filtering references read in the last 30 days):
```json
{
  "target": {"kind": "builtin", "value": "dateAdded"},
  "op": "isWithin",
  "value": {"kind": "datePreset", "value": {"preset": "lastNDays", "n": 30}}
}
```

**GroupConfig** example (group by month of `dateAdded`, week-level bucketing):
```json
{
  "target": {"kind": "builtin", "value": "dateAdded"},
  "dateBin": "month",
  "collapsed": [],
  "showEmpty": false
}
```

The app has not shipped; the consolidated `v1` migration edits in place and
dev databases reset via `SWIFTLIB_RESET_DB_ON_SCHEMA_CHANGE=1` (or `rm -rf
~/Library/Application\ Support/Rubien/`). Once shipped, any JSON change needs
a migration path.

---

## Pipeline

The engines are pure functions; none touch the database directly. The app wires
them into the table view in `ReferenceTableView.body`:

```
observed rows ── FilterEngine ── SortEngine ── GroupEngine? ── render
                        └──────── PipelineContext ────────┘
```

`PipelineContext` carries everything the engines need that isn't on a
`Reference`: `tagMap` (reference → tags), `propertyValueMap` (reference →
propertyId → raw string), `propertyDefs`, and `now`. Built once per body
render and threaded through.

### `FieldResolver`

The shared bridge between raw data and the engines. Given a `FieldTarget` + a
`Reference` + the context maps, it returns a `ResolvedValue` — one of `.text`,
`.number`, `.date`, `.singleSelect`, `.multiSelect`, `.checkbox`. Custom-select
and multi-select JSON decoding happens here, exactly once per (row, target)
combo. All three engines consume `ResolvedValue`.

For built-ins:
- `.tags` resolves to `multiSelect` of stringified tag IDs (keys are `String(tag.id)`, not tag names).
- `.readingStatus` / `.referenceType` resolve to `singleSelect` of the enum `rawValue`.
- `.pdfAttached` resolves to `checkbox(row.pdfPath != nil && !isEmpty)`.

### `FilterEngine`

`apply(rows, filters:, context:)` → filtered `[Reference]`. Flat AND: a row
passes iff every filter's `evaluate` returns true. No nested groups.

Per-kind evaluator methods dispatch on `ResolvedValue`. `isEmpty`/`isNotEmpty`
short-circuit before kind dispatch and use `ResolvedValue.isEmpty`. Text
comparisons are locale-aware (`localizedCaseInsensitiveCompare`,
`localizedCaseInsensitiveContains`). Date equality uses `Calendar.isDate(_:
inSameDayAs:)`, so times don't matter.

### `SortEngine`

Multi-column stable sort with:
- **Primary/tiebreaker chain:** first `ViewSort` is primary; ties fall through.
- **Nulls last:** regardless of direction, missing values always end up at the bottom. `nullsLast` pre-flips the nil side so the caller's ascending/descending flip cancels out.
- **ID tiebreaker:** when all user sorts resolve equal, `reference.id` provides a deterministic final order (stable across re-renders).
- **Multi-select drop:** sorts on `multiSelect` targets are filtered out before sorting (disallowed by spec; defensive here).

### `GroupEngine`

`apply(rows, config:, context:)` → `[GroupBucket]`. Each bucket has a `key`
(raw resolver key — tag id, enum raw value, date-bin string), a `label`
(display string — tag name, enum `.label`, localized month), and ordered
references.

- **Multi-select grouping** (e.g., tags): a reference appears in each bucket it has a key for. Empty set means the reference gets the `__empty__` bucket.
- **Date grouping:** `dateBin` maps date → key/label pair. `.week` uses `yearForWeekOfYear`; `.month` uses `yyyy-MM` / `MMMM yyyy`; `.year` uses `yyyy`.
- **Number grouping disallowed** (including year — sort, don't group).
- **Bucket order:** `customOrder` first (drag-reorder in popover), then alphabetical for the rest. `showEmpty` seeds buckets for every known single-select option before sorting.

`GroupConfig.collapsed` is persisted state but the group engine doesn't
consume it — the table view uses it to hide rows without recomputing buckets.

---

## Operator Matrix

Allowed operators per kind (see `FilterOperator.allowed(for:)`):

| Kind          | Operators                                                                  |
|---------------|----------------------------------------------------------------------------|
| `text`        | `equals`, `notEquals`, `contains`, `notContains`, `startsWith`, `endsWith`, `isEmpty`, `isNotEmpty` |
| `number`      | `equals`, `notEquals`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `isEmpty`, `isNotEmpty` |
| `date`        | `equals`, `notEquals`, `greaterThan`, `lessThan`, `greaterOrEqual`, `lessOrEqual`, `isWithin`, `isEmpty`, `isNotEmpty` |
| `singleSelect`| `equals`, `notEquals`, `isAnyOf`, `isNoneOf`, `isEmpty`, `isNotEmpty`       |
| `multiSelect` | `contains`, `notContains`, `containsAnyOf`, `containsNoneOf`, `containsAllOf`, `isEmpty`, `isNotEmpty` |
| `checkbox`    | `isChecked`, `isUnchecked`                                                 |

`isWithin` only accepts `.datePreset` values. `isAnyOf`/`isNoneOf` take
`.selectKeys`. Multi-select's singular `contains`/`notContains` take
`.selectKeys` but only read the first element.

---

## UI Structure

```
ViewChromeBar
├── Row 1: view name + dirty indicator + Save/Discard buttons
└── Row 2: FilterChromeBar + Sort button + Group button

FilterChromeBar
├── leading filter icon
├── FlowLayout of filter pills (one per ViewFilter)
└── "+ Add filter" ChromeBarPill  → FilterEditorPopover

Sort button ChromeBarPill → SortEditorPopover
Group button ChromeBarPill → GroupEditorPopover
```

- **Filter pill click** opens `FilterEditorPopover` in edit mode. `×` removes.
- **FilterEditorPopover** routes on `(kind, op)` to render the right value editor: `TextField`, number field (separate `@State numberInput: String` to distinguish untouched from typed-zero), `DatePicker`, `datePresetPicker`, or a wrapping `FlowLayout` of select chips using the shared `chipBackground(_:)` style.
- **SortEditorPopover** is a drag-reorderable `List { ForEach ... }.onMove`; primary sort is the top row. Disabled when every target is already used.
- **GroupEditorPopover** has a field picker (text/number targets excluded), conditional `DateBin` segmented control, `showEmpty` toggle (only when the target has a known option universe), and a drag-reorderable bucket list that writes `GroupConfig.customOrder`. "Remove grouping" clears the config.

### Header sort + visibility

Column headers are native SwiftUI `TableColumn` (which constrains `Label ==
Text` — custom header context menus aren't possible without an AppKit bridge).
Click-to-sort updates the primary sort while preserving popover-configured
tiebreakers (see `ReferenceTableView.onChange(of: tableSortOrder)`). Column
show/hide goes through the built-in `columnCustomization` right-click menu;
order persists via `RubienPreferences.tableColumnCustomizationKey` in
`UserDefaults`.

### Dirty / draft flow

`LibraryViewModel` stashes per-view draft edits in memory. On view switch, the
current view's draft is preserved so the user can flip views without losing
unsaved work. `isCurrentViewDirty` is a cached `@Published` (not recomputed on
every render). **Save** writes the draft to `DatabaseView`; **Discard**
reverts to the persisted state.

---

## Performance

Target: <0.1s for filter/sort/group edits on 100k references. The architecture
is lean:
- `FilterEngine` is a single pass of `allSatisfy`; no allocations per row beyond `FieldResolver` lookups.
- `SortEngine` uses `Array.sorted`; the comparator short-circuits on the first unequal sort column.
- `GroupEngine` is O(rows) for partition, then O(buckets log buckets) for ordering.
- `processedReferences` and `GroupEngine.apply(...)` are hoisted to body-level `let` bindings in `ReferenceTableView` to avoid re-running the pipeline 3–4× per render.

Benchmark validation is pending (Phase 5C of the rollout plan).

---

## CLI Contract

`rubien-cli views` exposes the full model:

```
rubien-cli views --create \
  --name "Reading" \
  --filters '[{"target":{"kind":"builtin","value":"readingStatus"},"op":"equals","value":{"kind":"selectKeys","value":["reading"]}}]' \
  --sorts '[{"target":{"kind":"builtin","value":"dateAdded"},"ascending":false}]' \
  --group-by '{"target":{"kind":"builtin","value":"dateAdded"},"dateBin":"month","collapsed":[],"showEmpty":false}'
```

Output from `rubien-cli views` (`DatabaseViewDTO`):
```json
{
  "id": 3,
  "name": "Reading",
  "icon": "tablecells",
  "isDefault": false,
  "displayOrder": 1,
  "scope": {...},
  "columns": [...],
  "filters": [...],
  "sorts": [...],
  "groupBy": {...} | null,
  "dateCreated": "...",
  "dateModified": "..."
}
```

`rubien-cli views --query <id>` applies the view's filter/sort pipeline
client-side and prints `[Reference]` JSON. If the view has no
filters/sorts/groupBy, there's a fast path that pushes the limit down to SQL
and skips the engines. Grouping-aware output is not yet defined — currently
the query returns a flat sorted list, ignoring the group config.

`RubienCLITests` locks the JSON contract; any change to the DTO shape needs
an accompanying test update and a `Docs/CLI-Reference.md` revision.

---

## Extending the System

| Adding…                    | Touch                                                                 |
|----------------------------|-----------------------------------------------------------------------|
| A new built-in column      | `ColumnIdentifier` case, `valueKind`, `FieldResolver.resolveBuiltin` |
| A new custom property kind | `PropertyType` case, `valueKind`, `FieldResolver.resolveCustom`, editor cell |
| A new operator             | `FilterOperator` case, `allowed(for:)`, engine evaluator for its kind |
| A new date preset          | `DatePreset` case, `DatePresetResolver`, popover menu entry           |
| A new date bin             | `DateBin` case, `GroupEngine.dateKeyLabel`, popover picker            |
| A new value editor         | `FilterEditorPopover.valueEditor` switch                              |

Every extension point keys off `FieldValueKind` — keep that mapping accurate
or the value editor, operator picker, and engine evaluators will drift.

---

## Non-Goals

- **Nested filter groups (OR trees).** v1 is flat AND only.
- **Sort on `multiSelect`.** Disallowed in UI and silently dropped in `SortEngine`.
- **Group on `text` or `number`.** Excluded from the group field picker. Use sort for year.
- **Day-level date grouping or relative bins.** Only week/month/year.
- **Custom header context menus.** Blocked by SwiftUI's `TableColumn.Label == Text` constraint on macOS. Sort goes through header click or the Sort popover; column visibility goes through the native `columnCustomization` menu.
