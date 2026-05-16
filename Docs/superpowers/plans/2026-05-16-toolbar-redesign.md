# Main-Window Toolbar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relocate the iCloud sync icon next to the "References" title, regroup the add-reference toolbar actions so the most-frequent flows lead, rename "New entry" → "Add manually" and "Import PDF" → "Import PDF (auto)", and hide the pending-metadata queue button when empty.

**Architecture:** Pure UI change to the main `WindowGroup`'s toolbar and the list column's title. No resolver, no schema, no sync engine, no new sheets, no migrations. Five files touched; one new ToolbarItem in `.principal` placement; two `.navigationTitle`/`.navigationSubtitle` modifiers removed; one toolbar primary-action block rewritten; one in-sheet heading string updated; three new localization keys.

**Tech Stack:** SwiftUI on macOS 15.0 (Sequoia), Swift 6 toolchain. Uses `.unified(showsTitle: true)` window style.

**Spec:** `Docs/superpowers/specs/2026-05-16-toolbar-redesign-design.md`

---

## File Map

| File | Change |
|---|---|
| `Sources/Rubien/Resources/en.lproj/Localizable.strings` | Add 3 keys in the "Content view / main shell" section. |
| `Sources/Rubien/RubienApp.swift` | Delete the `.toolbar { ToolbarItem(.primaryAction) { SyncStatusIcon } }` block (lines 40-44). |
| `Sources/Rubien/Views/ReferenceTableView.swift` | Remove `.navigationTitle` (line 86) and `.navigationSubtitle` (line 87). Add a caption-row above `tableContentView` rendering `subtitleText`. |
| `Sources/Rubien/Views/ContentView.swift` | Add a `ToolbarItem(placement: .principal)` rendering "References" + sync icon. Rewrite the `.primaryAction` group: reorder, rename, gate the pending button on `!isEmpty`. |
| `Sources/Rubien/Views/AddReferenceView.swift` | Change `Text("New reference", …)` at line 62 to `Text("Add reference manually", …)`. |

---

### Task 1: Add localization keys

**Files:**
- Modify: `Sources/Rubien/Resources/en.lproj/Localizable.strings` (under `// MARK: - Content view / main shell`, after `"content.toolbar.importPDF"`)

- [ ] **Step 1: Open the strings file and locate the marker**

Run: `grep -n "MARK: - Content view / main shell" Sources/Rubien/Resources/en.lproj/Localizable.strings`
Expected output: one line like `64:// MARK: - Content view / main shell` (exact line may differ).

The section's existing keys are roughly grouped by topic (search/add/import/progress) rather than strictly alphabetized. Slot the three new keys near the existing `content.toolbar.*` lines — the exact line is shown in Step 2 below.

- [ ] **Step 2: Insert the three new keys**

Use Edit on `Sources/Rubien/Resources/en.lproj/Localizable.strings`. Find the existing line:

```
"content.toolbar.importPDF" = "Import PDF";
```

Replace it with this block (preserving the surrounding lines):

```
"addReference.sheet.title" = "Add reference manually";
"content.toolbar.addManually" = "Add manually";
"content.toolbar.importPDF" = "Import PDF";
"content.toolbar.importPDFAuto" = "Import PDF (auto)";
```

Note: the three new keys sit together adjacent to the existing `content.toolbar.importPDF`. `addReference.sheet.title` is not a `content.toolbar.*` key, but co-locating it here keeps the redesign's strings in one block and matches the file's topic-grouping convention.

- [ ] **Step 3: Verify the keys parse**

Run:

```bash
swift build 2>&1 | tail -20
```

Expected: build proceeds past the resource compile step without complaints about the strings file. (Resource validation is part of the regular build.) If it fails with a syntax error on the strings file, you forgot a semicolon — fix and rerun.

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/Resources/en.lproj/Localizable.strings
git commit -m "i18n: add toolbar redesign localization keys

Three new keys for the toolbar redesign: addReference.sheet.title,
content.toolbar.addManually, content.toolbar.importPDFAuto. Existing
keys (e.g. content.toolbar.importPDF) are left in place to avoid
churning unrelated translations.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Relocate the sync icon to the principal slot, replace navigationSubtitle with a caption row

**Files:**
- Modify: `Sources/Rubien/RubienApp.swift:40-44`
- Modify: `Sources/Rubien/Views/ReferenceTableView.swift:60-87` (remove `.navigationTitle`/`.navigationSubtitle`, add a `subtitleRow` view above `tableContentView`)
- Modify: `Sources/Rubien/Views/ContentView.swift:869` (add a new `ToolbarItem(placement: .principal)` inside the existing `.toolbar { ... }` block)

- [ ] **Step 1: Remove the sync-icon toolbar block from `RubienApp.swift`**

Use Edit on `Sources/Rubien/RubienApp.swift`. Replace:

```swift
                .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
                    let title = (note.userInfo?[RubienClipImportedKeys.title] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = String(localized: "Saved web clip", bundle: .module)
                    let fmt = String(localized: "Saved web clip: %@", bundle: .module)
                    let message = title.flatMap { !$0.isEmpty ? String(format: fmt, $0) : nil } ?? fallback
                    showToast(message, tone: .success)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SyncStatusIcon(status: syncCoordinator.status)
                    }
                }
        }
```

with:

```swift
                .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
                    let title = (note.userInfo?[RubienClipImportedKeys.title] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = String(localized: "Saved web clip", bundle: .module)
                    let fmt = String(localized: "Saved web clip: %@", bundle: .module)
                    let message = title.flatMap { !$0.isEmpty ? String(format: fmt, $0) : nil } ?? fallback
                    showToast(message, tone: .success)
                }
        }
```

(Removes 4 lines — the `.toolbar { ... }` block and its contents. Everything above and below is preserved verbatim.)

- [ ] **Step 2: Remove `.navigationTitle` and `.navigationSubtitle` from `ReferenceTableView.swift`; inject a subtitle caption row**

Use Edit on `Sources/Rubien/Views/ReferenceTableView.swift`. Replace this block (around lines 60-87):

```swift
        return VStack(spacing: 0) {
            ViewChromeBar(
                viewName: viewName,
                filters: $filters,
                sorts: $sorts,
                groupBy: $groupBy,
                columnWraps: $viewColumnWraps,
                isColumnVisible: { id in columnCustomization[visibility: id] != .hidden },
                tags: allTags,
                propertyDefs: propertyDefs,
                currentBuckets: buckets ?? [],
                isDirty: isDirty,
                onSave: onSaveView,
                onDiscard: onDiscardView
            )
            if references.isEmpty {
                emptyState
            } else if processed.isEmpty {
                filteredEmptyState
            } else {
                tableContentView(processed: processed, buckets: buckets)
                if !selection.isEmpty {
                    batchToolbar
                }
            }
        }
        .navigationTitle(String(localized: "References", bundle: .module))
        .navigationSubtitle(subtitleText)
        .toolbar {
```

with:

```swift
        return VStack(spacing: 0) {
            ViewChromeBar(
                viewName: viewName,
                filters: $filters,
                sorts: $sorts,
                groupBy: $groupBy,
                columnWraps: $viewColumnWraps,
                isColumnVisible: { id in columnCustomization[visibility: id] != .hidden },
                tags: allTags,
                propertyDefs: propertyDefs,
                currentBuckets: buckets ?? [],
                isDirty: isDirty,
                onSave: onSaveView,
                onDiscard: onDiscardView
            )
            subtitleRow
            if references.isEmpty {
                emptyState
            } else if processed.isEmpty {
                filteredEmptyState
            } else {
                tableContentView(processed: processed, buckets: buckets)
                if !selection.isEmpty {
                    batchToolbar
                }
            }
        }
        .toolbar {
```

(Removes the two `.navigationTitle`/`.navigationSubtitle` modifier lines. Inserts a `subtitleRow` view inside the VStack just below `ViewChromeBar`.)

- [ ] **Step 3: Add the `subtitleRow` private view to `ReferenceTableView`**

Use Edit on `Sources/Rubien/Views/ReferenceTableView.swift`. Find the existing `subtitleText` computed property (around line 382):

```swift
    private var subtitleText: String {
        if !selection.isEmpty {
            return String(format: String(localized: "%d / %d selected", bundle: .module), selection.count, references.count)
        }
        return String(format: String(localized: "%d references", bundle: .module), references.count)
    }
```

Insert a new computed view immediately before it:

```swift
    /// Renders the count caption that used to live in `.navigationSubtitle`.
    /// Sits at the top of the list column under the chrome bar.
    private var subtitleRow: some View {
        HStack(spacing: 0) {
            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var subtitleText: String {
        if !selection.isEmpty {
            return String(format: String(localized: "%d / %d selected", bundle: .module), selection.count, references.count)
        }
        return String(format: String(localized: "%d references", bundle: .module), references.count)
    }
```

(Adds `subtitleRow` directly above the existing `subtitleText` property. No other property in the file moves.)

- [ ] **Step 4: Add the principal toolbar item to `ContentView.swift`**

Use Edit on `Sources/Rubien/Views/ContentView.swift`. Find the existing `.toolbar(content: { ... })` block start (around line 869). Replace:

```swift
        .toolbar(content: {
            ToolbarItemGroup(placement: .primaryAction) {
```

with:

```swift
        .toolbar(content: {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("References", bundle: .module)
                        .font(.headline)
                    SyncStatusIcon(status: syncCoordinator.status)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
```

(Inserts a new `ToolbarItem(placement: .principal)` immediately before the existing `ToolbarItemGroup`. The rest of the toolbar block is untouched in this task — it gets rewritten in Task 3.)

`syncCoordinator` is already an `@EnvironmentObject` on `ContentView` (declared at line 723), so no new wiring is required.

- [ ] **Step 5: Build and verify the title+icon render**

Run:

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds. If it fails complaining `SyncStatusIcon` isn't visible from `ContentView`, that's because `ContentView` lives in module `Rubien` and `SyncStatusIcon` is in the same module — no import change is needed. (Sanity-check by `grep -l "import RubienSync" Sources/Rubien/Views/ContentView.swift` — if absent, `SyncStatusIcon`'s `RubienSync.SyncStatus` parameter still resolves because `SyncStatusIcon` itself imports `RubienSync`.)

Run the app:

```bash
swift run Rubien
```

Visually verify in the running window:
- "References" appears as the title in the centre of the toolbar.
- The sync-status SF symbol appears immediately to the right of "References" (a checkmark.icloud.fill when idle).
- The icon is NOT in the right-side action cluster next to the search button.
- A small "%d references" (or "%d / %d selected") caption row appears at the top of the list column, just below the filter chrome bar.
- The right-side toolbar (Search, [New entry, Web clip], [Pending, Add by identifier, Import PDF, More menu]) still renders unchanged.
- Resize the window to ~900pt wide and confirm the principal item doesn't get truncated or pushed into overflow.

If the title looks visibly bolder/thinner than the previous chrome title, swap `.font(.headline)` for `.font(.system(size: 13, weight: .semibold))` in the principal `Text` (spec lists this as the acceptable fallback).

- [ ] **Step 6: Quit the app, run the test suite**

Run:

```bash
swift test --filter RubienCoreTests 2>&1 | tail -10
```

Expected: all RubienCoreTests pass. This is a sanity check that nothing accidentally broke in the surrounding code; this UI change has no XCTest coverage of its own.

- [ ] **Step 7: Commit**

```bash
git add Sources/Rubien/RubienApp.swift \
        Sources/Rubien/Views/ReferenceTableView.swift \
        Sources/Rubien/Views/ContentView.swift
git commit -m "UI: relocate iCloud sync icon next to References title

Moves SyncStatusIcon out of the .primaryAction cluster (where it
crowded the search button) into a new ToolbarItem(placement: .principal)
holding 'References' + the icon. Drops the navigationTitle and
navigationSubtitle modifiers from ReferenceTableView since the
principal slot now owns the title; re-renders the count caption as a
subtitleRow above the table.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Regroup toolbar actions, rename labels, gate the pending button, update sheet heading

**Files:**
- Modify: `Sources/Rubien/Views/ContentView.swift:870-942` (the existing `ToolbarItemGroup(placement: .primaryAction) { ... }` body)
- Modify: `Sources/Rubien/Views/AddReferenceView.swift:62`

- [ ] **Step 1: Rewrite the primary-action toolbar group in `ContentView.swift`**

Use Edit on `Sources/Rubien/Views/ContentView.swift`. After Task 2's edit the `.toolbar(content: { ... })` block now starts with the new principal item, followed by the `ToolbarItemGroup`. Replace the entire `ToolbarItemGroup(placement: .primaryAction) { ... }` body. Find:

```swift
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                Button {
                    showSearch = true
                } label: {
                    Label(String(localized: "common.search", bundle: .module), systemImage: "magnifyingglass")
                }
                .help(String(localized: "Search references", bundle: .module))
                .keyboardShortcut("f", modifiers: .command)

                ControlGroup {
                    Button(action: {
                        addReferenceInitialType = .journalArticle
                        showAddReference = true
                    }) {
                        Label(String(localized: "New entry", bundle: .module), systemImage: "square.and.pencil")
                    }
                    .help(String(localized: "Create a blank reference and fill in its fields", bundle: .module))

                    Button(action: {
                        showWebImport = true
                    }) {
                        Label(String(localized: "Web clip", bundle: .module), systemImage: "globe")
                    }
                    .help(String(localized: "Paste a URL and let Rubien clip the title, abstract, and article body", bundle: .module))
                }

                ControlGroup {
                    Button(action: { showPendingMetadataQueue = true }) {
                        HStack(spacing: 6) {
                            Label(String(localized: "content.toolbar.pendingQueue", bundle: .module), systemImage: "clock.badge.exclamationmark")
                            if !viewModel.pendingMetadataIntakes.isEmpty {
                                Text("\(viewModel.pendingMetadataIntakes.count)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .help(String(localized: "Open the pending metadata queue to review candidates or confirm manually", bundle: .module))
                    .disabled(viewModel.pendingMetadataIntakes.isEmpty)

                    Button(action: { showAddByIdentifier = true }) {
                        Label(String(localized: "content.toolbar.addByIdentifier", bundle: .module), systemImage: "text.magnifyingglass")
                    }
                    .help(String(localized: "Paste a DOI, arXiv ID, PMID, or ISBN and fetch metadata automatically", bundle: .module))

                    Button(action: { importPDFWithMetadata() }) {
                        Label(String(localized: "content.toolbar.importPDF", bundle: .module), systemImage: "doc.badge.plus")
                    }
                    .help(String(localized: "Import a PDF and auto-fill its metadata when possible", bundle: .module))

                    Menu {
                        Button(String(localized: "content.toolbar.batchImport", bundle: .module) + "…") { showBatchImport = true }
                        Divider()
                        Button(String(localized: "content.toolbar.importBibTeX", bundle: .module)) { importBibTeX() }
                        Button(String(localized: "content.toolbar.importRIS", bundle: .module)) { importRIS() }
                        Button(String(localized: "content.toolbar.importZoteroFolder", bundle: .module)) { pickZoteroFolder() }
                        Divider()
                        Button(String(localized: "Import citation styles (.csl)…", bundle: .module)) { importCitationStyles() }
                    } label: {
                        Label(String(localized: "More import options", bundle: .module), systemImage: "tray.and.arrow.down")
                    }
                    .help(String(localized: "More import options", bundle: .module))
                    .disabled(viewModel.isImporting)
                }
                }
                .labelStyle(.titleAndIcon)
            }
```

with:

```swift
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                Button {
                    showSearch = true
                } label: {
                    Label(String(localized: "common.search", bundle: .module), systemImage: "magnifyingglass")
                }
                .help(String(localized: "Search references", bundle: .module))
                .keyboardShortcut("f", modifiers: .command)

                // Primary add group: the two most-frequent flows.
                ControlGroup {
                    Button(action: { showAddByIdentifier = true }) {
                        Label(String(localized: "content.toolbar.addByIdentifier", bundle: .module), systemImage: "text.magnifyingglass")
                    }
                    .help(String(localized: "Paste a DOI, arXiv ID, PMID, or ISBN and fetch metadata automatically", bundle: .module))

                    Button(action: {
                        showWebImport = true
                    }) {
                        Label(String(localized: "Web clip", bundle: .module), systemImage: "globe")
                    }
                    .help(String(localized: "Paste a URL and let Rubien clip the title, abstract, and article body", bundle: .module))
                }

                // Secondary add group: manual entry and PDF-with-auto-metadata.
                ControlGroup {
                    Button(action: {
                        addReferenceInitialType = .journalArticle
                        showAddReference = true
                    }) {
                        Label(String(localized: "content.toolbar.addManually", bundle: .module), systemImage: "square.and.pencil")
                    }
                    .help(String(localized: "Create a blank reference and fill in its fields", bundle: .module))

                    Button(action: { importPDFWithMetadata() }) {
                        Label(String(localized: "content.toolbar.importPDFAuto", bundle: .module), systemImage: "doc.badge.plus")
                    }
                    .help(String(localized: "Import a PDF and auto-fill its metadata when possible", bundle: .module))
                }

                // Pending queue: only present when there is something to review.
                if !viewModel.pendingMetadataIntakes.isEmpty {
                    Button(action: { showPendingMetadataQueue = true }) {
                        HStack(spacing: 6) {
                            Label(String(localized: "content.toolbar.pendingQueue", bundle: .module), systemImage: "clock.badge.exclamationmark")
                            Text("\(viewModel.pendingMetadataIntakes.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    .help(String(localized: "Open the pending metadata queue to review candidates or confirm manually", bundle: .module))
                }

                Menu {
                    Button(String(localized: "content.toolbar.batchImport", bundle: .module) + "…") { showBatchImport = true }
                    Divider()
                    Button(String(localized: "content.toolbar.importBibTeX", bundle: .module)) { importBibTeX() }
                    Button(String(localized: "content.toolbar.importRIS", bundle: .module)) { importRIS() }
                    Button(String(localized: "content.toolbar.importZoteroFolder", bundle: .module)) { pickZoteroFolder() }
                    Divider()
                    Button(String(localized: "Import citation styles (.csl)…", bundle: .module)) { importCitationStyles() }
                } label: {
                    Label(String(localized: "More import options", bundle: .module), systemImage: "tray.and.arrow.down")
                }
                .help(String(localized: "More import options", bundle: .module))
                .disabled(viewModel.isImporting)
                }
                .labelStyle(.titleAndIcon)
            }
```

Notable structural changes vs the old code:
- The `More` menu is no longer nested inside a `ControlGroup`. In the old layout it lived with the pending-queue + Add-by-identifier + Import-PDF buttons. Now those siblings are gone (pending is conditional and moved out; the other two are in the primary group), so the menu stands alone — wrapping a single item in `ControlGroup` adds an unhelpful border.
- The pending-queue button is rendered conditionally via `if !viewModel.pendingMetadataIntakes.isEmpty { ... }`. The `.disabled(...)` modifier is removed (now unreachable). The badge text is unwrapped because it's only rendered when `count > 0`.

- [ ] **Step 2: Update the sheet heading in `AddReferenceView.swift`**

Use Edit on `Sources/Rubien/Views/AddReferenceView.swift`. Replace:

```swift
                Text("New reference", bundle: .module)
                    .font(.headline)
```

with:

```swift
                Text("addReference.sheet.title", bundle: .module)
                    .font(.headline)
```

(This switches from the inline raw string `"New reference"` — whose value also doubles as its localization key — to the new explicit key `addReference.sheet.title` that we added in Task 1. The visible English text is now "Add reference manually".)

- [ ] **Step 3: Build and verify the toolbar**

Run:

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds. If you see a "missing argument" error inside a `ControlGroup`, you accidentally deleted a brace — re-read the diff.

Run the app:

```bash
swift run Rubien
```

Visually verify, in left-to-right order across the top-right toolbar:
1. 🔍 Search
2. ControlGroup pill: 📑 Add by Identifier, 🌐 Web clip
3. ControlGroup pill: ✎ Add manually, 📄 Import PDF (auto)
4. Tray-and-arrow More menu — and **no** Pending queue button (assuming the queue is empty for a normal dev library)
5. Hover-tooltips match the labels above

Click "Add manually" — confirm the sheet's title reads "Add reference manually" (previously "New reference"). Cancel.

Click "Import PDF (auto)" — confirm the open-panel opens. Cancel.

To exercise the conditional pending button: temporarily seed a fake intake from a debug context (or skip this — covered by Task 4 regression check).

- [ ] **Step 4: Quit the app, run the test suite**

Run:

```bash
swift test --filter RubienCoreTests 2>&1 | tail -10
```

Expected: all RubienCoreTests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Views/ContentView.swift \
        Sources/Rubien/Views/AddReferenceView.swift
git commit -m "UI: regroup toolbar add-actions, hide pending button when empty

Most-frequent add flows (Add by identifier, Web clip) lead the toolbar
in their own ControlGroup; the less-frequent manual flows (Add
manually, Import PDF (auto)) follow in a second ControlGroup. 'New
entry' is renamed 'Add manually' and 'Import PDF' is renamed 'Import
PDF (auto)' so the difference between manual entry and PDF-driven
auto-resolution is visible from the labels. The pending-metadata
queue button is now rendered only when the queue is non-empty
(previously: always rendered, disabled when empty). The sheet
heading in AddReferenceView is updated to match.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: End-to-end verification

**Files:** none modified.

- [ ] **Step 1: Full build**

Run:

```bash
swift build 2>&1 | tail -20
```

Expected: build succeeds, no warnings introduced.

- [ ] **Step 2: Run the broader test set**

Run:

```bash
swift test 2>&1 | tail -30
```

Expected: all targets pass. If `RubienCLITests` is slow on first run, that's normal — it spawns subprocesses. If anything fails that isn't already broken on `main` pre-redesign, treat as a regression and stop.

- [ ] **Step 3: Manual UI smoke pass**

Run:

```bash
swift run Rubien
```

Walk through this checklist:

1. ✅ "References" + sync icon render together in the title centre of the toolbar.
2. ✅ Sync icon shows `checkmark.icloud.fill` (idle / accentColor) for an enabled sync, or `icloud.slash` (disabled / secondary) when sync is off in Settings.
3. ✅ Caption row "%d references" visible just under the chrome bar at top of list column.
4. ✅ Toolbar order on the right: Search → primary group [Add by identifier, Web clip] → secondary group [Add manually, Import PDF (auto)] → More menu (no pending button on a clean library).
5. ✅ Window resize to narrow (~900pt) doesn't push the principal item into overflow or wrap weirdly.
6. ✅ ⌘F still focuses the search overlay.
7. ✅ "Add manually" opens the AddReferenceView sheet with heading "Add reference manually".
8. ✅ "Import PDF (auto)" opens the file picker (cancel to dismiss).
9. ✅ Trigger a candidate-state metadata resolution (use `Import PDF (auto)` on a paper without an extractable DOI / known title — or via the Batch Import sheet) and confirm the pending queue button appears in the toolbar with an orange count badge.
10. ✅ Open Settings → toggle iCloud sync off and on; confirm the sync icon updates in real time.

- [ ] **Step 4: No commit needed**

This task introduces no code changes. If the smoke pass uncovers any issue, return to Task 2 or 3 and fix; otherwise the redesign is complete.

---

## Self-Review

Spec coverage check:

- ✅ Sync icon to principal slot — Task 2 Steps 4, 5
- ✅ Drop `.navigationTitle` from ReferenceTableView — Task 2 Step 2
- ✅ Drop `.navigationSubtitle` and rebuild as caption row — Task 2 Steps 2, 3
- ✅ Remove sync icon from RubienApp toolbar — Task 2 Step 1
- ✅ Reorder primary group: Add by identifier + Web clip — Task 3 Step 1
- ✅ Secondary group: Add manually (rename), Import PDF (auto) (rename) — Task 3 Step 1
- ✅ Conditional pending button — Task 3 Step 1
- ✅ More menu unchanged contents — Task 3 Step 1 (kept verbatim)
- ✅ AddReferenceView heading update — Task 3 Step 2
- ✅ Three new localization keys — Task 1
- ✅ Build + test verification — Task 2 Step 6, Task 3 Step 4, Task 4

No placeholders. No TBDs. No "implement later". All code blocks contain executable Swift; all commands are exact.

Type/API consistency: `SyncStatusIcon(status:)` is called in both Task 2 Step 4 (new ContentView principal item) and matches the existing signature in `Sources/Rubien/Views/SyncStatusIcon.swift`. `syncCoordinator.status` is the same property already consumed by `SyncStatusBanner` and the deleted RubienApp toolbar. `viewModel.pendingMetadataIntakes` is the same `@Published` array referenced in the old `.disabled(...)` call. `addReferenceInitialType` / `showAddReference` / `showWebImport` / `showAddByIdentifier` / `showPendingMetadataQueue` / `showBatchImport` / `importPDFWithMetadata` / `importBibTeX` / `importRIS` / `pickZoteroFolder` / `importCitationStyles` are all preserved exactly as in the pre-redesign code.
