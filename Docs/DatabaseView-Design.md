# Database View System — Design Document

This document describes the Notion-style database view system that replaces the folder/collection-based organization with a flat database model where each "folder" is a saved view.

---

## Motivation

The original collection-based model forced references into a single folder hierarchy. The new system treats the entire library as one flat database and uses **views** — saved query + display configurations — to slice and present it. This mirrors Notion's database paradigm: every view is a lens over the same data, with its own columns, filters, sorts, and scope.

---

## Architecture Overview

```
┌─────────────┐     ┌──────────────────┐     ┌───────────────────┐
│  SidebarView │ ──▶ │  LibraryViewModel │ ──▶ │ ReferenceTableView │
│  (views list)│     │  (scope/filter/   │     │ (SwiftUI Table)    │
│              │     │   sort from view) │     │                    │
└─────────────┘     └──────────────────┘     └───────────────────┘
                            │
                            ▼
                    ┌──────────────┐
                    │  AppDatabase  │
                    │  (GRDB query) │
                    └──────────────┘
```

When the user selects a view in the sidebar, the `LibraryViewModel` unpacks that view's scope, filters, and sorts, then rebuilds the GRDB `ValueObservation` to stream matching references into the table.

---

## Data Model

### DatabaseView (table: `databaseView`)

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-incremented |
| `name` | TEXT | Display name |
| `icon` | TEXT | SF Symbol name |
| `scopeJSON` | TEXT | JSON-encoded `ViewScope` |
| `columnsJSON` | TEXT | JSON-encoded `[ColumnConfig]` |
| `filtersJSON` | TEXT | JSON-encoded `[ViewFilter]` |
| `sortsJSON` | TEXT | JSON-encoded `[ViewSort]` |
| `isDefault` | BOOLEAN | Exactly one row is `true` |
| `displayOrder` | INTEGER | Sidebar ordering |
| `dateCreated` | DATETIME | |
| `dateModified` | DATETIME | |

All configuration is stored as JSON TEXT columns rather than normalized tables. This matches the existing pattern used for `editors`/`translators` on `Reference` and avoids join explosion — a view's config is always loaded as a unit.

### Supporting Types

```swift
enum ViewScope: Codable {
    case all
    case collection(Int64)
    case tag(Int64)
}

struct ColumnConfig: Codable {
    var columnId: ColumnIdentifier   // which column
    var width: Double?               // nil = auto
    var isVisible: Bool
    var displayOrder: Int
}

struct ViewSort: Codable {
    var field: ColumnIdentifier
    var ascending: Bool
}

struct ViewFilter: Codable {
    var field: ColumnIdentifier
    var op: FilterOperator           // equals, contains, greaterThan, isEmpty, etc.
    var value: String
}
```

### ColumnIdentifier (16 columns)

```
title, authors, year, journal, referenceType, tags,
readingStatus, priority, dateAdded, dateModified,
doi, publisher, volume, issue, pages, pdfAttached
```

Title is always visible and first — it cannot be hidden or reordered.

---

## New Reference Fields

Two user-workflow fields were added to `Reference` (migration `v11`):

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `readingStatus` | TEXT | `"unread"` | Enum: `unread`, `reading`, `skimmed`, `read` |
| `priority` | INTEGER | `0` | Enum: `0` (none), `1` (low), `2` (medium), `3` (high) |

Both are indexed and filterable from the CLI and UI.

---

## Migrations

- **v11-reading-status-priority**: Adds `readingStatus` TEXT and `priority` INTEGER columns to `reference`, with indexes.
- **v12-database-views**: Creates `databaseView` table, inserts the default "All References" view, and converts each existing `Collection` row into a `DatabaseView` with `scope = .collection(id)`.

The `collection` table and `reference.collectionId` have been removed — collections are fully replaced by database views.

---

## UI Components

### ReferenceTableView (`Sources/Rubien/Views/ReferenceTableView.swift`)

Replaces the old `ReferenceListView` (compact 52px rows) with a SwiftUI `Table`:

- **Columns**: Title, Authors, Status, Priority, Date Added (sortable via header click). Tags, Year, Journal in the inner `ReferenceTableContent` struct.
- **Inline editing**: Reading Status and Priority use borderless `Menu` pickers — click to change in-place.
- **Tags column**: Colored capsule pills via `TagsCellView`.
- **Multi-selection**: `Set<Reference.ID>` with batch toolbar for delete, refresh metadata, move.
- **Context menu**: Per-row and batch operations.

The table is split into `ReferenceTableView` (outer shell with toolbar, batch actions, empty state) and `ReferenceTableContent` (the `Table` itself, extracted to help the Swift type checker with complex generic inference).

### ColumnConfigPopover (`Sources/Rubien/Views/ColumnConfigPopover.swift`)

Triggered by the slider icon in the table toolbar. Notion-style popover with:
- **Visible** section: toggles ON, drag handle for reorder
- **Hidden** section: toggles OFF
- Search field to filter by column name
- Title row is locked (no toggle, no drag)
- Changes apply immediately

### ViewFilterBar (`Sources/Rubien/Views/ViewFilterBar.swift`)

Horizontal bar above the table showing active filters as removable pills:
- Each pill shows: `field` `operator` `value` `×`
- "Add Filter" button opens `AddFilterPopover` with field/operator/value pickers
- "Clear" button removes all filters

### SidebarView (`Sources/Rubien/Views/SidebarView.swift`)

Replaced collections/tags sections with:
1. **Default View**: "All References" (always first, not deletable)
2. **My Views**: User-created views with context menu (rename, duplicate, delete)
3. **Smart Collections**: Auto-generated keyword clusters (retained from original)

"New View" button opens a sheet to name the view.

---

## CLI

The CLI gained `--reading-status`, `--priority`, `--sort-by` flags on `list`/`update`, and a new `views` subcommand. See [CLI-Reference.md](CLI-Reference.md) for full documentation.

---

## File Map

| File | Layer | What it does |
|------|-------|-------------|
| `RubienCore/Models/DatabaseView.swift` | Core | `DatabaseView`, `ColumnIdentifier`, `ColumnConfig`, `ViewSort`, `ViewFilter`, `ViewScope`, `FilterOperator` — all model types |
| `RubienCore/Models/Reference.swift` | Core | `ReadingStatus`, `Priority` enums + fields on `Reference` |
| `RubienCore/Database/AppDatabase.swift` | Core | Migrations v11/v12, `DatabaseView` CRUD, `observeReferenceTagMappings()`, filter extensions |
| `Rubien/Views/ReferenceTableView.swift` | App | SwiftUI `Table` + inline editing cells + batch toolbar |
| `Rubien/Views/ColumnConfigPopover.swift` | App | Column show/hide/reorder popover |
| `Rubien/Views/ViewFilterBar.swift` | App | Filter pills bar + add-filter popover |
| `Rubien/Views/SidebarView.swift` | App | Views-based sidebar (replaced collections/tags) |
| `Rubien/Views/ContentView.swift` | App | `LibraryViewModel` with view observation, tag map, wiring |
| `RubienCLI/RubienCLI.swift` | CLI | `Views` subcommand, updated `list`/`update` flags, `ReferenceDTO` |

---

## Design Decisions

1. **JSON TEXT over normalized tables** for view config: a view's columns/filters/sorts are always loaded as a unit, never queried across views. JSON avoids join explosion and matches the existing `editors`/`translators` pattern.

2. **`collection` table removed**: Collections have been fully replaced by database views. The `collection` table and `reference.collectionId` are no longer present.

3. **SwiftUI `Table` over NSTableView**: The app targets macOS 14+ exclusively. SwiftUI `Table` integrates cleanly with `NavigationSplitView` and gained `TableColumnCustomization` in macOS 14. The reference list (hundreds to low-thousands of rows) is well within its performance envelope.

4. **`ReadingStatus` as String, `Priority` as Int**: ReadingStatus has no inherent numeric ordering, so String raw values are clearer. Priority uses Int raw values for natural SQL `ORDER BY` without a CASE expression.

5. **Type checker workaround**: The `Table` body is extracted into `ReferenceTableContent` as a separate struct because SwiftUI's `@TableColumnBuilder` hits the type checker's complexity limit with 8+ columns in a single closure.
