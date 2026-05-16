# Main-window toolbar redesign

**Status:** approved 2026-05-16
**Scope:** UI only — `Sources/Rubien/Views/ContentView.swift`, `Sources/Rubien/RubienApp.swift`, `Sources/Rubien/Views/ReferenceTableView.swift`, `Sources/Rubien/Views/AddReferenceView.swift`, plus matching localization keys.
**Out of scope:** metadata resolver, queue persistence, sync engine, `ViewChromeBar` (filters/sort/group/display row), any data-layer change.

## Problem

Three concrete UI issues in the main reference window today:

1. The iCloud sync icon (`RubienApp.swift:40-44`) is declared as `ToolbarItem(placement: .primaryAction)`. The search button (`ContentView.swift:872`) is also `.primaryAction`. SwiftUI packs primary actions together on the right edge, so the sync icon visually crowds search — especially at narrower window widths.
2. The toolbar's add-reference actions are ordered against frequency of use. The most-frequent entry points — **Add by identifier** and **Web clip** — are split across two `ControlGroup`s alongside less-frequent actions. Users are also unsure how **New entry** differs from **Import PDF**; the labels do not convey that one is manual data entry while the other runs the metadata resolver against a picked file.
3. The **Pending Metadata Queue** button is always rendered but is `.disabled` when the queue is empty (`ContentView.swift:912`). Empty is the steady state for most users, so the button is dead toolbar real estate.

## Goals

- Sync status remains a glanceable, always-present indicator without colliding with primary actions.
- The most-frequent add flows sit together and read first.
- The manual-entry flow is verbally distinct from the auto-metadata-from-PDF flow.
- Toolbar shows only widgets the user can act on right now.
- Zero changes to underlying flows: no new sheets, no removed sheets, no resolver edits, no migrations.

## Non-goals

- Replacing or restyling `ViewChromeBar` (the filters / sort / group / display row inside the list column).
- Removing the pending queue feature itself — only its visibility when empty.
- Restructuring `AddReferenceView`'s form — the existing optional PDF-attach field already covers the "manual entry with PDF" case.
- Reworking localization for already-shipped strings; we add new keys rather than mutate existing ones.

## Design

### Title and sync icon — principal slot

The live title is `.navigationTitle(...)` and `.navigationSubtitle(subtitleText)` on `ReferenceTableView.swift:86-87` (not `ReferenceListView`). The plan:

- **Remove** `.navigationTitle(String(localized: "References", bundle: .module))` from `ReferenceTableView.swift:86`. Leaving it in place would race with our custom principal item — `.unified(showsTitle: true)` honours `navigationTitle` by populating the principal slot automatically, and AppKit's resolution of "two principal sources" is non-deterministic on macOS 15.
- **Remove** `.navigationSubtitle(subtitleText)` from `ReferenceTableView.swift:87`. On macOS 15 unified-style toolbars, the subtitle is rendered through the same nav-system pipeline as the title; a custom principal item suppresses its automatic layout. To preserve the existing "Recently added · N" affordance, render `subtitleText` as a thin caption row at the top of the list-column content (inside `ReferenceTableView`'s body, above `tableContentView`). The exact placement is a single `HStack { Text(subtitleText).font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.top, 6)`.
- **Add** a `ToolbarItem(placement: .principal)` inside `ContentView.swift`'s `.toolbar { ... }` block, rendering an `HStack(spacing: 6)` containing:
  - `Text("References", bundle: .module).font(.headline)` — `.headline` is the closest match to the system title weight under `.unified(showsTitle: true)`. Implementer should compare side-by-side and adjust to `.system(size: 13, weight: .semibold)` if `.headline` reads visibly bolder.
  - The existing `SyncStatusIcon(status: syncCoordinator.status)` unchanged.
- **Remove** the current sync-icon `ToolbarItem(placement: .primaryAction)` block from `RubienApp.swift:40-44`. `SyncCoordinator` is already injected into `ContentView` via `.environmentObject(syncCoordinator)` (`RubienApp.swift:18`), so the new principal toolbar item reads `syncCoordinator.status` directly through `@EnvironmentObject`.

`ReferenceTableView`'s existing `.toolbar { ToolbarItem(placement: .navigation) { Properties button } }` block (`ReferenceTableView.swift:88-104`) is unaffected — `.navigation` and `.principal` are independent slots that merge across views.

### Toolbar actions — two groups, conditional pending button

The right-side toolbar (`ContentView.swift:869-942`) is reorganized as the following sequence inside the existing `ToolbarItemGroup(placement: .primaryAction)`:

1. **Search** button (`magnifyingglass`, ⌘F) — unchanged behaviour, unchanged position.
2. **Primary add group** — `ControlGroup` containing, in order:
   - **Add by identifier** (`text.magnifyingglass`) — opens `AddByIdentifierView`. Same action as today; reordered to lead.
   - **Web clip** (`globe`) — opens `WebImportView`. Same action; relocated from the prior first group.
3. **Secondary add group** — `ControlGroup` containing, in order:
   - **Add manually** (`square.and.pencil`) — opens `AddReferenceView`. Rename of today's "New entry"; sheet behaviour unchanged.
   - **Import PDF (auto)** (`doc.badge.plus`) — runs `importPDFWithMetadata()`. Rename of today's "Import PDF"; behaviour unchanged.
4. **Pending queue button** — rendered with an `if !viewModel.pendingMetadataIntakes.isEmpty { ... }` guard so it appears only when the queue is non-empty. The `.disabled` modifier is dropped (it cannot be reached now). The orange count badge is preserved.
5. **More import menu** (`tray.and.arrow.down`) — unchanged contents: Batch import, BibTeX, RIS, Zotero folder, CSL styles.

### Sheet heading

In `AddReferenceView.swift:62`, change the in-sheet heading `Text("New reference", bundle: .module)` to `Text("Add reference manually", bundle: .module)` so the sheet matches the new button label. No other change to that view.

### Localization

Strings live in `Sources/Rubien/Resources/en.lproj/Localizable.strings` (a classic `.strings` file, not a catalog). Add three new keys to the `// MARK: - Content view / main shell` section, alphabetized to match the file's convention:

```
"addReference.sheet.title" = "Add reference manually";
"content.toolbar.addManually" = "Add manually";
"content.toolbar.importPDFAuto" = "Import PDF (auto)";
```

Existing keys (`content.toolbar.importPDF`, plus the raw inline string `"New entry"` that today's `square.and.pencil` button uses) are left in place — no removal — to avoid churning unrelated translations on parallel branches. Future cleanup of the now-orphaned keys can be done in a follow-up pass.

Tooltips (`.help(...)`) are already correct in the current code and remain unchanged.

## Component map

| File | What changes |
|---|---|
| `Sources/Rubien/RubienApp.swift` | Remove the `.toolbar { ToolbarItem(.primaryAction) { SyncStatusIcon } }` block on the `WindowGroup`. |
| `Sources/Rubien/Views/ContentView.swift` | Rewrite the `.toolbar` content block: new `principal` item with title + sync icon (reading `@EnvironmentObject var syncCoordinator: SyncCoordinator`), reorder the `.primaryAction` group, gate pending-queue button on `!isEmpty`. |
| `Sources/Rubien/Views/ReferenceTableView.swift` | Remove `.navigationTitle(...)` (line 86) **and** `.navigationSubtitle(subtitleText)` (line 87). Render `subtitleText` as a small caption row at the top of the list-column body to preserve the "Recently added · N" affordance. The `ToolbarItem(placement: .navigation)` Properties button block (lines 88–104) is unchanged. |
| `Sources/Rubien/Views/AddReferenceView.swift` | Update one string at line 62 (`"New reference"` → `"Add reference manually"`). |
| `Sources/Rubien/Resources/en.lproj/Localizable.strings` | Add three new keys to the "Content view / main shell" section (see Localization). |

Estimated total: ~30–50 changed lines, no new files.

## Behavioural contract

The following must be true after the change:

- Sync status icon is visible at all times in the title area, never gated on window width, never overlapping action buttons. Its tooltip and the 8 visual states from `SyncStatusIcon` are unchanged.
- The "Recently added · N" (or equivalent) descriptor remains visible somewhere in the list column header — either as a caption row above the table or, if that fallback is taken, in the existing list footer.
- "Add by identifier" and "Web clip" sit adjacent and lead the primary-action group.
- "Add manually" opens the same sheet that "New entry" opens today; "Import PDF (auto)" runs the same `importPDFWithMetadata` flow as "Import PDF" does today.
- The Pending Queue button is absent from the toolbar when `viewModel.pendingMetadataIntakes.isEmpty` and present (with badge) otherwise. The sheet it opens is unchanged.
- All other toolbar items (search, more-import menu, sub-items in the menu) behave identically to today.
- Keyboard shortcut for search (⌘F) still works.

## Testing

No XCTest contract is affected. Verification is manual on macOS:

1. Build the Mac app (`swift run Rubien` or via `./scripts/build-app.sh`).
2. Confirm "References" + sync icon render together in the title area (principal slot), not in the right-side action cluster, and no second auto-title appears.
2a. Confirm a subtitle-like row ("Recently added · N" or current equivalent) is still visible at the top of the list column.
3. Confirm toolbar order matches the design.
4. With an empty pending queue, confirm the pending button is absent.
5. Trigger a `.candidate` outcome (e.g., import a PDF that the resolver cannot fully verify) and confirm the pending button appears with its count badge; click and confirm the queue sheet opens.
6. Click "Add manually" — confirm `AddReferenceView` opens with heading "Add reference manually".
7. Click "Import PDF (auto)" — confirm the open-panel and resolver flow run as today.
8. Resize the window narrow → confirm the toolbar overflow chevron behaves correctly with the new layout.

CLI tests, sync tests, and core tests are unaffected — no need to rerun beyond a smoke `swift build` and `swift test --filter RubienCoreTests` to confirm nothing in the surrounding code was disturbed.

## Risks

- **Principal slot vs auto-title race.** `.unified(showsTitle: true)` auto-populates the principal slot from `.navigationTitle`. We must remove both `.navigationTitle` and the principal-slot-relevant `.navigationSubtitle` from `ReferenceTableView` in the same change as adding our custom principal item, otherwise AppKit on macOS 15 resolves the conflict non-deterministically (sometimes the auto title wins, sometimes ours does, sometimes both render stacked).
- **Subtitle replacement.** `.navigationSubtitle` is rendered through the nav-system pipeline, so once we own the principal slot the subtitle's automatic layout vanishes. The mitigation in this spec is to render `subtitleText` ourselves as a caption row at the top of the list column. If the implementer finds the inline caption visually noisy compared to the system subtitle, an acceptable fallback is to drop the subtitle entirely — the "References" + count is also surfaced in the list footer and the sidebar.
- **Title styling.** Without `.navigationTitle`, the principal `Text` does not pick up the system title font automatically. The spec prescribes `.font(.headline)` as the starting point; if it reads visibly off compared to the previous chrome, swap for `.font(.system(size: 13, weight: .semibold))`. This is a visual judgment call to be made during implementation.
- **SyncCoordinator availability.** Today the sync icon is declared inside `RubienApp.swift` where `syncCoordinator` is the `@StateObject` source of truth. After the move, `ContentView` reads `syncCoordinator` via `@EnvironmentObject`. This is already how `SyncStatusBanner` consumes it elsewhere, so no new wiring is required.
- **Conditional toolbar item identity.** Removing/re-adding a `ToolbarItem` based on a state predicate is the normal SwiftUI pattern; SwiftUI handles the recomposition. There is no animation requirement.
