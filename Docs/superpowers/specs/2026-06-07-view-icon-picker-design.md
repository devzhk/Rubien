# Per-view icon picker — design

**Date:** 2026-06-07
**Status:** Approved (ready for implementation plan)

## Problem

Every user-created view in the sidebar reuses one symbol, `tablecells` (the grid
glyph), hard-coded as the `DatabaseView` default. It's the same for every view,
so views are visually indistinguishable, and the glyph itself reads as cluttered.
The built-in "All References" view already uses a distinct symbol
(`books.vertical`), proving per-view icons are viable.

The `icon` field is a real per-view column that already syncs end-to-end via the
`CDDatabaseView` CloudKit record — nothing structural blocks per-view icons.

## Goal

Let users pick an icon per view from a **curated palette** when creating or
editing a view, and give new views a cleaner default than `tablecells`.

## Non-goals (YAGNI)

- **Full SF Symbols search.** A curated set is more cohesive and far less work.
- **Per-view color.** Icons keep the existing single-tint rendering (accent when
  selected, secondary otherwise).
- **Migrating existing views.** Views currently on `tablecells` keep that value
  until the user edits them. No new migration.
- **CLI `--icon` flag.** `icon` is already in the CLI's `views` JSON output;
  writing it stays UI-only for now. No CLI contract change.

## Curated palette (24 symbols)

A 4×6 grid, themed so views are easy to tell apart. All verified present on the
macOS 15 deployment target.

| Group | Symbols |
|---|---|
| Collections | `square.stack`, `rectangle.stack`, `square.grid.2x2`, `folder`, `tray.full`, `archivebox` |
| Reading/docs | `books.vertical`, `book`, `text.book.closed`, `doc.text`, `newspaper`, `bookmark` |
| Topics/research | `graduationcap`, `atom`, `brain`, `globe`, `chart.xyaxis.line`, `lightbulb` |
| Markers/status | `star`, `flag`, `pin`, `tag`, `sparkles`, `cube` |

**Default for new views:** `square.stack` — a stacked-collection glyph that reads
as "a saved lens over the library," replacing `tablecells`.

## UI / UX

- Replace the name-only **New View sheet** *and* the rename **alert** with one
  unified **View editor sheet**: a name `TextField` plus the inline icon grid
  (the curated palette, selected cell highlighted). Used for both create and edit
  — one component, one mental model.
- Sidebar context menu: **"Rename…" → "Edit View…"**, opening the editor
  pre-filled with the view's current name + icon. "Duplicate" / "Delete"
  unchanged.
- The sidebar row rendering is unchanged — it already renders whatever
  `view.icon` holds at single tint.

## Architecture / data flow

Pure-data catalog lives in `RubienCore` (consistent with existing icon strings
like `referenceType.icon`, and testable without SwiftUI); the SwiftUI grid and
sheet live in the app target.

### File-by-file

1. **`Sources/RubienCore/Models/DatabaseView.swift`** — change the init default
   `icon: String = "tablecells"` → `"square.stack"`. (Struct default only; this
   is not a migration.)

2. **`Sources/RubienCore/Models/ViewIconCatalog.swift`** *(new)* — a namespace
   exposing the curated symbols: per-group arrays plus a flattened `all: [String]`
   and `defaultIcon` (`square.stack`). **Foundation-only — no AppKit/SwiftUI.**
   RubienCore compiles and is tested on Linux, so the catalog must stay pure
   string data (no symbol *rendering* leaks into Core).

3. **`Sources/Rubien/Views/ViewIconGrid.swift`** *(new)* — a `LazyVGrid`
   rendering `ViewIconCatalog` with a `@Binding var selection: String`; highlights
   the chosen cell. macOS-only.

4. **`Sources/Rubien/Views/SidebarView.swift`** —
   - Callback shapes: `onCreateView: (String) -> Void` → `(_ name: String, _ icon: String) -> Void`;
     replace `onRenameView: (Int64, String) -> Void` with
     `onUpdateView: (_ id: Int64, _ name: String, _ icon: String) -> Void`.
   - Replace `NewViewSheet` + the rename alert with a `ViewEditorSheet`
     (name field + `ViewIconGrid`). Drive presentation with an explicit mode
     `enum ViewEditorMode: Identifiable { case create; case edit(DatabaseView) }`
     held as `@State var editorMode: ViewEditorMode?` (nil ⇒ sheet closed),
     presented via `.sheet(item:)`. A bare optional `editingView` is **not**
     enough — `nil` cannot distinguish "create" from "closed".
   - Context-menu item renamed to "Edit View…" (`.edit(view)`), opens the editor
     pre-filled.
   - The context-menu **"Duplicate"** action currently calls
     `onCreateView(view.name + " Copy")`; after the signature change it must pass
     the source icon: `onCreateView(view.name + " Copy", view.icon)` so the copy
     inherits the original's icon rather than resetting to the default.

5. **`Sources/Rubien/Views/ContentView.swift`** —
   - `createDatabaseView(name:scope:)` → `createDatabaseView(name:icon:scope:)`,
     passing `icon` into the `DatabaseView(...)` initializer.
   - `renameDatabaseView(id:name:)` → `updateDatabaseView(id:name:icon:)`, setting
     both `view.name` and `view.icon` before `saveDatabaseView`.
   - Update the `SidebarView(...)` call site (~L803–805) to the new closures.

Persistence (`saveDatabaseView` → `db.saveDatabaseView`) and CloudKit sync are
unchanged — `icon` already rides the `CDDatabaseView` record.

## Testing

- **`RubienCoreTests`** *(new)*: assert `ViewIconCatalog.all` is non-empty, has no
  duplicates, and contains both the default (`square.stack`) and `cube`.
- No change needed to `DatabaseViewRecordTests` (it constructs an explicit
  `books.vertical` icon and round-trips it; the sync path is icon-agnostic).
- No test pins the old `tablecells` default, so changing it breaks nothing.

## Risks

- **Default-change blast radius:** only *new* views get `square.stack`; existing
  rows are untouched (no migration). The shipped migration's column default
  (`tablecells` in `AppDatabase.swift`) is left as-is per the immutable-migrations
  rule — it's never exercised, since user views are always created through the
  Swift initializer that now supplies `square.stack`.
- **Callback signature churn** touches `SidebarView` + its single call site in
  `ContentView`; contained to two files.
