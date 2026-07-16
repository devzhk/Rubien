# View Icon Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users pick a per-view icon from a curated palette when creating/editing a sidebar view, and give new views a cleaner default (`square.stack`) than `tablecells`.

**Architecture:** A pure-data curated catalog lives in `RubienCore` (Foundation-only, Linux-safe); a SwiftUI `ViewIconGrid` renders it; a unified `ViewEditorSheet` (driven by a `ViewEditorMode` enum) replaces the old name-only New View sheet *and* the rename alert, handling both create and edit. Persistence + CloudKit sync are unchanged — the `icon` field already rides the `CDDatabaseView` record.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), GRDB (untouched here), XCTest. SF Symbols for the curated glyphs.

**Spec:** `Docs/specs/2026-06-07-view-icon-picker-design.md`
**Codex review of spec:** `/tmp/view-icon-spec-review.md` (its two corrections — Duplicate must carry the icon; `editingView == nil` is ambiguous → use an explicit mode enum — are baked into this plan).

---

## Prerequisites

- **Branch first.** We're on `main`. Create a feature branch before any commit:
  `git checkout -b feat/view-icon-picker`
- **Leave unrelated edits alone.** The working tree has pre-existing modifications
  (`RubienApp.swift`, `RubienPreferences.swift`, `ReaderWindowManager.swift`,
  `RubienSettingsView.swift`, `RubienPreferencesTests.swift`) unrelated to this work.
  Every commit step below stages **only** the exact files it names — never `git add -A`.
- **Full Xcode for tests.** `swift test` needs the full toolchain. Verify:
  `xcode-select -p` should point at `…/Xcode.app/…`; if not,
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `Sources/RubienCore/Models/ViewIconCatalog.swift` | Curated SF Symbol names + `defaultIcon`. Foundation-only. | Create |
| `Sources/RubienCore/Models/DatabaseView.swift` | Change struct default `icon` to `ViewIconCatalog.defaultIcon`. | Modify (L163) |
| `Tests/RubienCoreTests/ViewIconCatalogTests.swift` | Assert catalog non-empty/unique/contents + default icon. | Create |
| `Sources/Rubien/Views/ViewIconGrid.swift` | SwiftUI grid rendering the catalog with a selection binding. | Create |
| `Sources/Rubien/Views/SidebarView.swift` | New callback signatures; `ViewEditorMode` + `ViewEditorSheet`; context menu. | Modify |
| `Sources/Rubien/Views/ContentView.swift` | `createDatabaseView(name:icon:scope:)`, `updateDatabaseView(id:name:icon:)`, call site. | Modify |

**Build-green ordering:** Task 1 (Core) and Task 2 (new UI file) each compile alone. Task 3 changes `SidebarView`'s callback *types* and `ContentView`'s matching call site **together** (one atomic commit) so the project always compiles.

---

## Task 1: Curated catalog + cleaner default (RubienCore, TDD)

**Files:**
- Create: `Tests/RubienCoreTests/ViewIconCatalogTests.swift`
- Create: `Sources/RubienCore/Models/ViewIconCatalog.swift`
- Modify: `Sources/RubienCore/Models/DatabaseView.swift:163`

- [ ] **Step 1: Write the failing tests**

Create `Tests/RubienCoreTests/ViewIconCatalogTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class ViewIconCatalogTests: XCTestCase {

    func testCatalogIsNonEmpty() {
        XCTAssertFalse(ViewIconCatalog.all.isEmpty)
    }

    func testCatalogHasNoDuplicates() {
        XCTAssertEqual(
            ViewIconCatalog.all.count,
            Set(ViewIconCatalog.all).count,
            "Curated icon catalog must not contain duplicate symbols"
        )
    }

    func testCatalogContainsDefaultAndCube() {
        XCTAssertTrue(ViewIconCatalog.all.contains(ViewIconCatalog.defaultIcon))
        XCTAssertTrue(ViewIconCatalog.all.contains("cube"))
    }

    func testNewViewUsesCatalogDefaultIcon() {
        let view = DatabaseView(name: "Untitled")
        XCTAssertEqual(view.icon, ViewIconCatalog.defaultIcon)
        XCTAssertEqual(view.icon, "square.stack")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail (don't compile)**

Run: `swift test --filter ViewIconCatalogTests`
Expected: build failure — `cannot find 'ViewIconCatalog' in scope`.

- [ ] **Step 3: Create the catalog**

Create `Sources/RubienCore/Models/ViewIconCatalog.swift`:

```swift
import Foundation

/// Curated SF Symbol names offered in the per-view icon picker.
///
/// Pure string data — **no AppKit/SwiftUI** — because `RubienCore` compiles and
/// is tested on Linux. Symbol *rendering* lives in the app target (`ViewIconGrid`).
public enum ViewIconCatalog {

    /// Default symbol for a newly created view (a stacked-collection glyph).
    public static let defaultIcon = "square.stack"

    /// Collections / structure.
    public static let collections = [
        "square.stack", "rectangle.stack", "square.grid.2x2",
        "folder", "tray.full", "archivebox",
    ]

    /// Reading / documents.
    public static let readingDocs = [
        "books.vertical", "book", "text.book.closed",
        "doc.text", "newspaper", "bookmark",
    ]

    /// Topics / research.
    public static let topicsResearch = [
        "graduationcap", "atom", "brain",
        "globe", "chart.xyaxis.line", "lightbulb",
    ]

    /// Markers / status.
    public static let markersStatus = [
        "star", "flag", "pin",
        "tag", "sparkles", "cube",
    ]

    /// Ordered groups for sectioned rendering.
    public static let groups: [[String]] = [
        collections, readingDocs, topicsResearch, markersStatus,
    ]

    /// Flattened catalog in display order.
    public static let all: [String] = groups.flatMap { $0 }
}
```

- [ ] **Step 4: Run the tests again**

Run: `swift test --filter ViewIconCatalogTests`
Expected: 3 of 4 pass; `testNewViewUsesCatalogDefaultIcon` FAILS
(`("tablecells") is not equal to ("square.stack")`) — the default isn't wired yet.

- [ ] **Step 5: Change the struct default**

In `Sources/RubienCore/Models/DatabaseView.swift`, the `init` parameter at line 163:

```swift
        icon: String = "tablecells",
```

becomes:

```swift
        icon: String = ViewIconCatalog.defaultIcon,
```

(Same module — no import needed. Do **not** touch the shipped migration's column
default in `AppDatabase.swift`; migrations are immutable and that default is never
exercised because views are always built through this initializer.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter ViewIconCatalogTests`
Expected: all 4 PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/RubienCore/Models/ViewIconCatalog.swift \
        Sources/RubienCore/Models/DatabaseView.swift \
        Tests/RubienCoreTests/ViewIconCatalogTests.swift
git commit -m "feat(views): add curated icon catalog + square.stack default" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: ViewIconGrid component (app target)

A standalone SwiftUI grid. No XCTest here — this repo doesn't unit-test SwiftUI
view bodies; correctness is verified by `swift build` (compiles) now and a manual
visual check in Task 3. The component depends only on `ViewIconCatalog` (Task 1).

**Files:**
- Create: `Sources/Rubien/Views/ViewIconGrid.swift`

- [ ] **Step 1: Create the grid view**

Create `Sources/Rubien/Views/ViewIconGrid.swift`:

```swift
#if os(macOS)
import SwiftUI
import RubienCore

/// A compact grid of curated SF Symbols for choosing a view's icon.
/// Selection is two-way bound; the chosen cell is highlighted in the accent color.
struct ViewIconGrid: View {
    @Binding var selection: String

    private let columns = Array(
        repeating: GridItem(.fixed(34), spacing: 6),
        count: 6
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(ViewIconCatalog.all, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 34, height: 30)
                        .foregroundStyle(
                            selection == symbol
                                ? Color.white
                                : Color.primary.opacity(0.8)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    selection == symbol
                                        ? Color.accentColor
                                        : Color.primary.opacity(0.06)
                                )
                        )
                        .contentShape(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(symbol)
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: build succeeds (the new file compiles; it's not referenced yet, which is fine).

- [ ] **Step 3: Commit**

```bash
git add Sources/Rubien/Views/ViewIconGrid.swift
git commit -m "feat(views): add ViewIconGrid icon-picker grid" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Wire the picker through SidebarView + ContentView (atomic)

This changes `SidebarView`'s callback *types* and `ContentView`'s matching call
site together so the project compiles. It also adds the `ViewEditorMode` enum and
`ViewEditorSheet`, retires the rename alert and `NewViewSheet`, and renames the
context-menu item to "Edit View…". Duplicate now carries the source icon.

**Files:**
- Modify: `Sources/Rubien/Views/SidebarView.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift` (`createDatabaseView`,
  `renameDatabaseView`→`updateDatabaseView`, call site ~L803–805)

- [ ] **Step 1: Change SidebarView callback declarations**

In `Sources/Rubien/Views/SidebarView.swift`, lines 10–12:

```swift
    let onCreateView: (String) -> Void
    let onDeleteView: (Int64) -> Void
    let onRenameView: (Int64, String) -> Void
```

become:

```swift
    let onCreateView: (_ name: String, _ icon: String) -> Void
    let onDeleteView: (Int64) -> Void
    let onUpdateView: (_ id: Int64, _ name: String, _ icon: String) -> Void
```

- [ ] **Step 2: Replace the editor state**

In `SidebarView`, replace the four `@State` vars (lines 14–17):

```swift
    @State private var showNewViewSheet = false
    @State private var newViewName = ""
    @State private var renamingViewId: Int64?
    @State private var renamingViewName = ""
```

with a single mode:

```swift
    @State private var editorMode: ViewEditorMode?
```

- [ ] **Step 3: Point the "+" button at the create editor**

In the "Views" header (line ~52):

```swift
                        Button { showNewViewSheet = true } label: {
```

becomes:

```swift
                        Button { editorMode = .create } label: {
```

- [ ] **Step 4: Update the context menu (Edit + Duplicate-with-icon)**

Replace the `.contextMenu { … }` block on the user-views `ForEach` (lines ~79–91):

```swift
                            .contextMenu {
                                Button("Rename…") {
                                    renamingViewId = view.id
                                    renamingViewName = view.name
                                }
                                Button("Duplicate") {
                                    onCreateView(view.name + " Copy")
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    if let id = view.id { onDeleteView(id) }
                                }
                            }
```

with:

```swift
                            .contextMenu {
                                Button("Edit View…") {
                                    editorMode = .edit(view)
                                }
                                Button("Duplicate") {
                                    onCreateView(view.name + " Copy", view.icon)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    if let id = view.id { onDeleteView(id) }
                                }
                            }
```

- [ ] **Step 5: Replace the sheet + alert with the unified editor sheet**

Replace the `.sheet(isPresented:)` + `.alert("Rename View", …)` modifiers
(lines ~104–125) with a single item-driven sheet:

```swift
        .sheet(item: $editorMode) { mode in
            ViewEditorSheet(mode: mode) { name, icon in
                switch mode {
                case .create:
                    onCreateView(name, icon)
                case .edit(let view):
                    if let id = view.id { onUpdateView(id, name, icon) }
                }
                editorMode = nil
            }
        }
```

(`.sheet(item:)` sets `editorMode` back to `nil` automatically when the sheet is
dismissed via Cancel, so no extra reset is needed there.)

- [ ] **Step 6: Replace NewViewSheet with ViewEditorMode + ViewEditorSheet**

Delete the entire `// MARK: - New View Sheet` section and the `NewViewSheet` struct
(lines ~273–302) and replace it with:

```swift
// MARK: - View Editor

/// Distinguishes "create a new view" from "edit this existing view". A bare
/// optional `DatabaseView?` can't express this — `nil` would be ambiguous
/// between "creating" and "sheet closed" — so the mode is explicit.
private enum ViewEditorMode: Identifiable {
    case create
    case edit(DatabaseView)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let view): return "edit-\(view.id.map(String.init) ?? "new")"
        }
    }
}

private struct ViewEditorSheet: View {
    let mode: ViewEditorMode
    let onSave: (_ name: String, _ icon: String) -> Void

    @State private var name: String
    @State private var icon: String
    @Environment(\.dismiss) private var dismiss

    init(mode: ViewEditorMode, onSave: @escaping (String, String) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _icon = State(initialValue: ViewIconCatalog.defaultIcon)
        case .edit(let view):
            _name = State(initialValue: view.name)
            _icon = State(initialValue: view.icon)
        }
    }

    private var title: String {
        switch mode {
        case .create: return "New View"
        case .edit: return "Edit View"
        }
    }

    private var saveLabel: String {
        switch mode {
        case .create: return "Create"
        case .edit: return "Save"
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            TextField("View name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            ViewIconGrid(selection: $icon)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName, icon)
    }
}
```

- [ ] **Step 7: Add `icon` to `createDatabaseView` (ContentView)**

In `Sources/Rubien/Views/ContentView.swift`, `createDatabaseView` (lines ~512–524):

```swift
    func createDatabaseView(name: String, scope: ViewScope = .all) {
        let maxOrder = databaseViews.map(\.displayOrder).max() ?? 0
        var view = DatabaseView(
            name: name,
            scope: scope,
            isDefault: false,
            displayOrder: maxOrder + 1
        )
        saveDatabaseView(&view)
        if let id = view.id {
            selectedSidebar = .view(id)
        }
    }
```

becomes:

```swift
    func createDatabaseView(name: String, icon: String = ViewIconCatalog.defaultIcon, scope: ViewScope = .all) {
        let maxOrder = databaseViews.map(\.displayOrder).max() ?? 0
        var view = DatabaseView(
            name: name,
            icon: icon,
            scope: scope,
            isDefault: false,
            displayOrder: maxOrder + 1
        )
        saveDatabaseView(&view)
        if let id = view.id {
            selectedSidebar = .view(id)
        }
    }
```

- [ ] **Step 8: Replace `renameDatabaseView` with `updateDatabaseView`**

In the same file, lines ~526–530:

```swift
    func renameDatabaseView(id: Int64, name: String) {
        guard var view = databaseViews.first(where: { $0.id == id }) else { return }
        view.name = name
        saveDatabaseView(&view)
    }
```

becomes:

```swift
    func updateDatabaseView(id: Int64, name: String, icon: String) {
        guard var view = databaseViews.first(where: { $0.id == id }) else { return }
        view.name = name
        view.icon = icon
        saveDatabaseView(&view)
    }
```

- [ ] **Step 9: Update the SidebarView call site**

In the same file, the `SidebarView(...)` closures (lines ~803–805):

```swift
                onCreateView: { name in viewModel.createDatabaseView(name: name) },
                onDeleteView: { viewModel.deleteDatabaseView(id: $0) },
                onRenameView: { id, name in viewModel.renameDatabaseView(id: id, name: name) }
```

become:

```swift
                onCreateView: { name, icon in viewModel.createDatabaseView(name: name, icon: icon) },
                onDeleteView: { viewModel.deleteDatabaseView(id: $0) },
                onUpdateView: { id, name, icon in viewModel.updateDatabaseView(id: id, name: name, icon: icon) }
```

- [ ] **Step 10: Build**

Run: `swift build`
Expected: build succeeds. (If `renameDatabaseView`/`onRenameView`/`NewViewSheet`
are reported as unresolved anywhere, a reference was missed — grep and fix.)

- [ ] **Step 11: Run the full test suite**

Run: `swift test`
Expected: all tests pass (no behavior change to data/sync; `DatabaseViewRecordTests`
still round-trips its explicit `books.vertical` icon).

- [ ] **Step 12: Manual smoke test**

Run: `swift run Rubien` (or `./scripts/build-app.sh` then launch). Verify:
1. Sidebar "+" opens a **New View** sheet with a name field and the icon grid;
   `square.stack` is preselected.
2. Pick `cube`, name it, Create → the new row shows the cube glyph.
3. Right-click a user view → **Edit View…** → sheet opens pre-filled with its
   current name + icon; change the icon, Save → the row updates.
4. Right-click a view → **Duplicate** → the copy keeps the **same** icon.
5. Existing pre-feature views still show their old `tablecells` glyph (no migration).

- [ ] **Step 13: Independent review before commit (per repo workflow)**

This is a non-trivial diff, so follow the project's pre-commit cycle:
1. `codex-rescue` on the uncommitted diff (default model). Capture output to
   `/tmp/view-icon-impl-review.md` and address any real findings.
2. `/simplify` sweep (reuse / quality / efficiency); apply worthwhile fixes.
3. Re-run `swift build` and `swift test` after any changes.

- [ ] **Step 14: Commit**

```bash
git add Sources/Rubien/Views/SidebarView.swift \
        Sources/Rubien/Views/ContentView.swift
git commit -m "feat(views): per-view icon picker (create + edit), retire rename alert" \
           -m "Unified ViewEditorSheet replaces NewViewSheet + the rename alert; Duplicate carries the source icon." \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Final verification + close-out

**Files:** none (verification + spec status update only)

- [ ] **Step 1: Full build + test once more from a clean state**

Run: `swift build && swift test`
Expected: build succeeds; full suite green.

- [ ] **Step 2: Confirm no stragglers**

Run: `grep -rn "tablecells\|onRenameView\|renameDatabaseView\|NewViewSheet\|showNewViewSheet" Sources/ Tests/`
Expected: no matches in `Sources/Rubien` or `Tests` (the only `tablecells` left is
the immutable migration column default in `AppDatabase.swift`, which is expected).

- [ ] **Step 3: Mark the spec implemented**

In `Docs/specs/2026-06-07-view-icon-picker-design.md`, change the
`**Status:**` line to `Implemented (<commit-sha>)`.

- [ ] **Step 4: Commit the doc update**

```bash
git add Docs/specs/2026-06-07-view-icon-picker-design.md
git commit -m "docs(views): mark icon-picker spec implemented" \
           -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes / out of scope

- **CLI/MCP:** no change. `icon` is already in the CLI `views` JSON output, and
  CLI-created views inherit the new `square.stack` default automatically via the
  `DatabaseView` initializer. No new subcommand or flag (writing icon stays UI-only).
- **No migration:** existing `tablecells` views keep that value until edited.
- **No per-view color, no full SF Symbols search** (YAGNI — see spec non-goals).
