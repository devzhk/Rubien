# Tags Delete Confirmation Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deleting a tag from `TagPickerPopover` must show the same confirm-when-in-use prompt that `SelectOptionPicker` already shows for custom select options, instead of silently deleting the tag globally (cascade-removing it from every reference).

**Architecture:** Reuse the existing, tested data-layer probe (`AppDatabase.probeDeletePropertyOption`, whose `isTags` branch counts `referenceTag` rows and throws `optionInUse`). Thread a **`deleteTagUnlessInUse: (Int64) -> Int?`** closure from the `ContentView` view model down to `TagPickerPopover`, mirroring the existing `onDeleteTag` plumbing exactly. `TagPickerPopover` gains a `confirming` state + inline confirm view + the same measured-min-height popover-stability fix already applied to `SelectOptionPicker`.

**Tech Stack:** SwiftUI (macOS 15), GRDB 7, Swift 6 strict concurrency. Mac-only (`#if os(macOS)`).

---

## Revision history

- **v2 (post-codex review, 2026-06-01):** Codex verdict was REWORK. Applied: (1) renamed the tag probe closure (named `deleteUnlessInUse` in v1 of this plan) → **`deleteTagUnlessInUse`** everywhere — the table-path structs already carry an *option* probe named `deleteUnlessInUse: (Int64, String) -> Int?` for `EditableCustomPropertyCell`, so reusing the name would be a duplicate stored property / compile error; the two now coexist with distinct names (parallel to `onDeleteTag` vs `onDeleteOption`). (2) Fixed Task 1 test helpers to the real ones (`tagsProp(_:)`, `makeRef`, `makeTag`). (3) Phase 3 now states explicitly that the restored tag is a **new** CloudKit record. Codex **validated**: Option A has no silent in-use delete path (in-use throws at `AppDatabase.swift:3049/:3071` before `Tag.deleteOne` at `:3078`; wrapper surfaces count only on `optionInUse` at `:3245`); both delete paths converge on `Tag.deleteOne` + the same `referenceTag ON DELETE CASCADE`; the `onGeometryChange`→`@State` height fix is already in production on `SelectOptionPicker:594-600` (no new Swift 6 risk); exactly two `TagPickerPopover(` sites (`InlinePropertyRow.swift:215`, `ReferenceTableView.swift:942`).

## Background — root cause (verified)

- Tags are rendered by a **separate** view, `TagPickerPopover.swift` (last modified 2026-05-15; **untouched** by the June 1 custom-select feature `b0c50a1` and untouched by the uncommitted `SelectOptionPicker` height fix).
- Its trash button (`TagPickerPopover.swift:94-105`) calls `onDeleteTag(id)` immediately with no gate. `onDeleteTag` → `ContentView` `viewModel.deleteTag(id:)` → `AppDatabase.deleteTag(id:)` → `Tag.deleteOne` → FK cascade wipes every `referenceTag` row. No confirmation.
- The data layer **already** supports the confirm: `probeDeletePropertyOption(propertyId:value:)` → `deletePropertyOption(clearInUse:false)` `isTags` branch (`AppDatabase.swift:3042-3080`) returns the in-use count (throws `optionInUse`) for an assigned tag, and deletes an unused tag outright (returning `nil`). Both the probe's unused-delete and `deleteTag` converge on `Tag.deleteOne`, so reusing the probe is consistent.

## Design decision

**Chosen (Option A): reuse `probeDeletePropertyOption` against the seeded Tags `PropertyDefinition`.** Same closure shape and `nil`/count semantics as `SelectOptionPicker.deleteUnlessInUse` — maximal parallelism between the two pickers, reuses tested code, and the doc-stated robustness property ("probe and clear can never disagree on what in-use means") carries over.

**Alternative considered (Option B): a new pure `tagUsageCount(id:) -> Int` helper + delete via `deleteTag`.** Cleaner separation (no probe side effect, single delete path) but introduces a second counting path that could drift from the delete path, and diverges from the `SelectOptionPicker` pattern. Rejected for consistency; flagged for codex's opinion.

**Probe side effect to keep in mind:** for an **unused** tag the probe deletes it outright (via `deletePropertyOption` → `Tag.deleteOne`) and returns `nil`. So `requestDelete` does nothing further in that case — identical to `SelectOptionPicker`. The confirmed in-use path calls the existing `onDeleteTag` (→ `deleteTag`).

**Fail-closed fallback:** if the Tags `PropertyDefinition` id can't be resolved (`propertyDefs` not yet loaded), the probe closure returns `nil` *without* deleting — the trash becomes a no-op rather than an unconfirmed destructive delete. Safer than the status quo.

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/Rubien/Views/TagPickerPopover.swift` | The leaf picker | Add `deleteTagUnlessInUse` param, `confirming` + `listContentHeight` state, `confirmView`, `requestDelete`, and the measured-min-height scroll fix |
| `Sources/Rubien/Views/InlinePropertyRow.swift` | Threads to `TagPickerPopover@215` | Add `deleteTagUnlessInUse` decl (`:190`) + pass (`:220`) |
| `Sources/Rubien/Views/ReferenceTableView.swift` | Threads to `TagPickerPopover@942` | Add `deleteTagUnlessInUse` to 3 structs (decls `:24,:430,:899`; passes `:177,:625,:947`) — **coexists** with the existing option probe `deleteUnlessInUse: (Int64, String) -> Int?` (`:27,:433`); distinct name, no collision |
| `Sources/Rubien/Views/ReferenceDetailView.swift` | Threads tags via `InlineTagsRow` (`:355`; it does **not** construct `TagPickerPopover` directly) | Add optional `deleteTagUnlessInUse` (decl `:17`, init `:47`, assign `:59`, pass `:355`) |
| `Sources/Rubien/Views/ContentView.swift` | Roots the closures | Add `viewModel.probeDeleteTag(id:)`; wire `deleteTagUnlessInUse:` at `:814` and `:880` |
| `Tests/RubienCoreTests/TagsPropertyRoutingTests.swift` | Data-layer contract | Add probe-on-Tags tests |

**Threading rule (uniform):** wherever the existing `onDeleteTag` appears, add a parallel **`deleteTagUnlessInUse`** with the **same optionality and the same passing**, only with return type `Int?` instead of `Void`. Where `onDeleteTag` is `(Int64) -> Void`, `deleteTagUnlessInUse` is `(Int64) -> Int?`. In `ReferenceDetailView` where `onDeleteTag` is `((Int64) -> Void)?`, `deleteTagUnlessInUse` is `((Int64) -> Int?)?` and bridges with `{ tagId in deleteTagUnlessInUse?(tagId) ?? nil }`. **Do not** touch the unrelated option probe `deleteUnlessInUse: (Int64, String) -> Int?` that some of these structs already carry for `EditableCustomPropertyCell` — the two are independent.

---

## Task 1: Lock the data-layer contract (probe on Tags)

**Files:**
- Test: `Tests/RubienCoreTests/TagsPropertyRoutingTests.swift`

- [ ] **Step 1: Write failing tests** using this file's existing helpers verbatim — `makeDB()`, `tagsProp(_:) -> PropertyDefinition`, `makeRef(_:title:) -> Int64`, `makeTag(_:name:color:) -> Int64`, and `db.setTags(forReference:tagIds:)` / `db.fetchAllTags()` (real APIs, confirmed).

```swift
func testProbeDeleteUnusedTagDeletesItAndReturnsNil() throws {
    let db = try makeDB()
    let prop = try tagsProp(db)
    let tagId = try makeTag(db, name: "orphan", color: "#FF0000")

    let count = db.probeDeletePropertyOption(propertyId: prop.id!, value: String(tagId))

    XCTAssertNil(count)                                              // unused → deleted outright, no confirm
    XCTAssertNil(try db.fetchAllTags().first { $0.id == tagId })   // tag is gone
}

func testProbeDeleteInUseTagReturnsCountWithoutDeleting() throws {
    let db = try makeDB()
    let prop = try tagsProp(db)
    let refId = try makeRef(db, title: "Paper")
    let tagId = try makeTag(db, name: "acceleration", color: "#FF9500")
    try db.setTags(forReference: refId, tagIds: [tagId])

    let count = db.probeDeletePropertyOption(propertyId: prop.id!, value: String(tagId))

    XCTAssertEqual(count, 1)                                         // in use → confirm, nothing deleted
    XCTAssertNotNil(try db.fetchAllTags().first { $0.id == tagId }) // tag still present
}
```

> The two assertions (unused → nil + gone; in-use → count + intact) are the contract `TagPickerPopover` depends on; keep them exact.

- [ ] **Step 2: Run, verify they fail** (or pass — see note)

Run: `swift test --filter RubienCoreTests.TagsPropertyRoutingTests`
Expected: the two new tests are **green** if the probe already behaves correctly (this task is a *characterization* test that pins the contract `TagPickerPopover` will depend on). If either is red, the probe has a Tags bug — STOP and fix `deletePropertyOption`'s `isTags` branch before any UI work.

- [ ] **Step 3: Commit**

```bash
git add Tests/RubienCoreTests/TagsPropertyRoutingTests.swift
git commit -m "test: pin probeDeletePropertyOption contract on the Tags property"
```

---

## Task 2: TagPickerPopover — confirm gate + height stability

**Files:**
- Modify: `Sources/Rubien/Views/TagPickerPopover.swift`

- [ ] **Step 1: Add the probe param + state** (after `let onDeleteTag: (Int64) -> Void`, line 15, and the `@State` block)

```swift
    let onDeleteTag: (Int64) -> Void
    /// Probe (mirrors SelectOptionPicker.deleteUnlessInUse): returns the in-use
    /// reference count when the tag is still assigned (→ inline confirm), or nil
    /// when it was deleted outright because unused, or could not be probed
    /// (fail-closed no-op). Always wired — required, not optional — so a tag
    /// delete can never skip the gate.
    let deleteTagUnlessInUse: (Int64) -> Int?
    @State private var search = ""
    @State private var localIds: Set<Int64> = []
    /// Set while an in-use tag awaits delete confirmation; renders the inline
    /// confirm prompt in place of the tag list.
    @State private var confirming: (id: Int64, name: String, count: Int)?
    /// Measured natural height of the tag list — floors the scroll area at
    /// min(content, 200) once measured so the popover restores its height after
    /// the (shorter) confirm view swaps back. Same fix as SelectOptionPicker.
    @State private var listContentHeight: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
```

- [ ] **Step 2: Split `body` into a Group that swaps confirm/list** (replace the `var body` opening through the first `VStack(alignment: .leading, spacing: 0) {` so the existing list VStack becomes `pickerBody`)

```swift
    var body: some View {
        Group {
            if let pending = confirming {
                confirmView(pending)
            } else {
                pickerBody
            }
        }
        .frame(width: 220)
        .onAppear {
            localIds = Set(assignedTags.compactMap(\.id))
            DispatchQueue.main.async { isSearchFocused = true }
        }
    }

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
```

> Keep the existing search header, `Divider`, and `ScrollView` body verbatim *inside* `pickerBody`. Remove the old `.frame(width: 220)` and `.onAppear { … }` that previously trailed the list VStack (they moved onto the `Group` above). The closing `}` of the list VStack now closes `pickerBody`.

- [ ] **Step 3: Make the trash button request a gated delete** (replace the trash `Button` action, lines 94-105)

```swift
                            Button {
                                requestDelete(tag)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete tag")
```

- [ ] **Step 4: Apply the measured-min-height fix** (on the list's inner content VStack `.padding(.vertical, 4)` and the `ScrollView`'s `.frame`, mirroring InlinePropertyRow.swift)

```swift
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listContentHeight = height
                }
            }
            .frame(
                minHeight: listContentHeight > 0 ? min(listContentHeight, 200) : nil,
                maxHeight: 200
            )
```

- [ ] **Step 5: Add `requestDelete` + `confirmView`** (before the closing `}` of the struct)

```swift
    /// Trash tapped on `tag`. Probe for usage: an in-use tag surfaces the inline
    /// confirm; an unused tag is deleted outright by the probe (nothing more to
    /// do — mirrors SelectOptionPicker.requestDelete).
    private func requestDelete(_ tag: Tag) {
        guard let id = tag.id else { return }
        if let count = deleteTagUnlessInUse(id) {
            confirming = (id, tag.name, count)
        }
    }

    @ViewBuilder
    private func confirmView(_ pending: (id: Int64, name: String, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete the tag \u{201C}\(pending.name)\u{201D}?")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("This removes it from \(pending.count) reference\(pending.count == 1 ? "" : "s").")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirming = nil }
                    .buttonStyle(.bordered)
                Button("Delete") {
                    // Mirror the original trash ordering: drop the per-reference
                    // pivot first (defensive), then the global delete.
                    localIds.remove(pending.id)
                    flushCommit()
                    onDeleteTag(pending.id)
                    confirming = nil
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(12)
    }
```

- [ ] **Step 6: Build**

Run: `swift build --target Rubien`
Expected: FAIL — the two `TagPickerPopover(` call sites (`InlinePropertyRow.swift:215`, `ReferenceTableView.swift:942`) now miss the required `deleteTagUnlessInUse:` argument. That is the cue for Tasks 3-4.

---

## Task 3: Thread `deleteTagUnlessInUse` through the view chain

**Files:**
- Modify: `Sources/Rubien/Views/InlinePropertyRow.swift`
- Modify: `Sources/Rubien/Views/ReferenceTableView.swift`
- Modify: `Sources/Rubien/Views/ReferenceDetailView.swift`

- [ ] **Step 1: `InlinePropertyRow`** — beside `let onDeleteTag: (Int64) -> Void` (`:190`) add:

```swift
    let deleteTagUnlessInUse: (Int64) -> Int?
```
and beside `onDeleteTag: onDeleteTag` in the `TagPickerPopover(...)` call (`:220`) add:
```swift
                    deleteTagUnlessInUse: deleteTagUnlessInUse,
```

- [ ] **Step 2: `ReferenceTableView`** — for each of the three structs that declare `onDeleteTag` (`:24`, `:430`, `:899`), add `let deleteTagUnlessInUse: (Int64) -> Int?` beside it (it sits *next to*, not replacing, the existing option probe `deleteUnlessInUse: (Int64, String) -> Int?` at `:27,:433`); and beside each `onDeleteTag: onDeleteTag` pass (`:177`, `:625`, `:947`) add `deleteTagUnlessInUse: deleteTagUnlessInUse,`. The new closure must reach `TagsCellView` (which builds `TagPickerPopover@942`); leave the option probe routed to `EditableCustomPropertyCell` untouched.

- [ ] **Step 3: `ReferenceDetailView`** — `onDeleteTag` here is **optional**. Beside `var onDeleteTag: ((Int64) -> Void)?` (`:17`) add `var deleteTagUnlessInUse: ((Int64) -> Int?)?`; add the matching `init` param after `onDeleteTag:` (`:47`) as `deleteTagUnlessInUse: ((Int64) -> Int?)? = nil,`; add `self.deleteTagUnlessInUse = deleteTagUnlessInUse` beside `:59`; and where `onDeleteTag` is passed to `InlineTagsRow` (`:355`) pass:
```swift
                deleteTagUnlessInUse: { tagId in deleteTagUnlessInUse?(tagId) ?? nil },
```

- [ ] **Step 4: Build (still expected to fail at ContentView roots)**

Run: `swift build --target Rubien`
Expected: FAIL only at `ContentView.swift:814,880` (missing `deleteTagUnlessInUse:`). All threading structs compile.

---

## Task 4: Root the probe closure in ContentView

**Files:**
- Modify: `Sources/Rubien/Views/ContentView.swift`

- [ ] **Step 1: Add the view-model probe** (near `func deleteTag(id:)`, ~`:476`; the view model has `@Published var propertyDefs` `:87` and `let db` `:108`)

```swift
    /// Probe whether a tag can be deleted, fail-closed. Returns the in-use
    /// reference count (→ confirm) or nil (deleted outright because unused, or
    /// Tags property not resolvable — a safe no-op). Routes through the seeded
    /// Tags PropertyDefinition so it shares deletePropertyOption's counting path.
    func probeDeleteTag(id: Int64) -> Int? {
        guard let tagsPropId = propertyDefs.first(where: { $0.isTags })?.id else { return nil }
        return db.probeDeletePropertyOption(propertyId: tagsPropId, value: String(id))
    }
```

- [ ] **Step 2: Wire both roots** — beside each `onDeleteTag: { tagId in viewModel.deleteTag(id: tagId) },` (`:814`, `:880`) add:

```swift
                deleteTagUnlessInUse: { tagId in viewModel.probeDeleteTag(id: tagId) },
```

- [ ] **Step 3: Build the app**

Run: `swift build --target Rubien`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien/Views/TagPickerPopover.swift Sources/Rubien/Views/InlinePropertyRow.swift Sources/Rubien/Views/ReferenceTableView.swift Sources/Rubien/Views/ReferenceDetailView.swift Sources/Rubien/Views/ContentView.swift
git commit -m "fix(tags): confirm-when-in-use before deleting a tag, matching custom select options"
```

---

## Task 5: Verify

- [ ] **Step 1: Full suite**

Run: `swift test`
Expected: green (≥ 793: prior 791 + 2 new), 0 failures.

- [ ] **Step 2: Manual visual check** via `swift run Rubien` (pure UI; no entitlement needed — but it touches the real library, so use a throwaway tag):
  - Create a tag, assign it to ≥1 reference, click its trash in the tag picker → **confirm appears** ("removes it from N references"); **Cancel** → list returns at the **same height**; **Delete** → tag removed.
  - Create a tag, assign it to **nothing**, trash it → deleted outright, **no** confirm (correct).
  - Open/scroll the tag picker normally → first-open height unchanged (no regression).

---

## Phase 3 (separate, ops — not TDD): restore the `acceleration` tag

Pre-req: the `swift run Rubien` / installed app is **quit** (no `.build/.../Rubien` or `/Applications/Rubien.app` process holding the DB).

Source of truth: `~/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien/.backup-pre-prod-switch-20260530-150837/library.sqlite` — has tag `acceleration` (read its `color`) on 11 references (ids 1529-1545 in the backup).

- [ ] Extract from the backup: the tag color, and the **DOIs** (fallback **titles**) of the 11 references it tagged.
- [ ] Target the live library explicitly to avoid the empty App-Support DB: `export RUBIEN_LIBRARY_ROOT="$HOME/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien"`. Confirm with `rubien-cli list` (or `properties list`) that it sees **112** references before writing.
- [ ] Re-create the tag and assign it to the live references that match those DOIs/titles, going through the data layer (`rubien-cli`, Tags route through `properties`) so sync triggers fire and the restore propagates to other devices.
  > **Identity note (codex):** the deleted tag's CloudKit record is permanently gone (the delete tombstoned it). Re-creating produces a **new** local rowID → **new** CloudKit `recordName`, which pushes to other devices as a net-new tag *addition*, not a conflict-resolved restore. The tag name, color, and the 11 assignments come back; the original record identity does not. Acceptable for this recovery.
- [ ] Verify: `acceleration` is back on its references; `rubien-cli sync status` shows the restored rows dirty/queued.

---

## Self-review

- **Spec coverage:** confirm gate (Tasks 2-4), data-layer contract (Task 1), popover-height regression prevented (Task 2 Step 4), every threading point enumerated with line numbers (Task 3), data restore (Phase 3). ✔
- **Placeholders:** none — the one soft reference is "use this file's existing tag/ref helpers," which is correct DRY guidance, not a TODO.
- **Type consistency:** `deleteTagUnlessInUse: (Int64) -> Int?` everywhere except `ReferenceDetailView` (optional + bridge); `probeDeleteTag(id:) -> Int?`; `confirming: (id:name:count:)`. Distinct from the pre-existing option probe `deleteUnlessInUse: (Int64, String) -> Int?`. Names match across tasks. ✔
- **Open question for codex:** Option A vs B (reuse probe with its unused-delete side effect, vs a pure `tagUsageCount` + `deleteTag`); whether the duplicated confirm-view + height-fix across the two pickers warrants extracting a shared component now or as a follow-up.
