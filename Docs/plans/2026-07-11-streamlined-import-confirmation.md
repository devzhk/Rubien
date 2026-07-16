# Streamlined Import Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make usable non-authoritative metadata directly selectable without a separate button, and make Return trigger the initial PDF/Markdown Import action.

**Architecture:** Keep each source context's existing `useProposedMetadata` hook so it continues to create the correct manually verified envelope and evidence, but invoke that hook from `ImportReviewSession.confirmSelected()` instead of exposing it as a row action. Distinguish “selectable” from “selected by default” so proposals are eligible but initially unselected. Add the standard SwiftUI default-action shortcut to the source sheet and centralize its enabled/busy predicate in the testable state model.

**Tech Stack:** Swift 6, SwiftUI, XCTest, RubienCore metadata-resolution types; macOS 15.0+.

## Global Constraints

- Work only in the isolated worktree `/private/tmp/rubien-import-source-sheet`.
- Use `apply_patch` for source, test, and documentation edits.
- Preserve CLI, MCP, schema, migration, CloudKit, and single-item import contracts.
- Authoritative rows start selected; usable proposals start unselected; candidate and unusable rows remain unselectable.
- Proposal acceptance occurs only when the user confirms a selected proposal; no import-stage metadata editor is added.
- Run tests with the full Xcode toolchain and Swift 6 strict-concurrency checks.

---

### Task 1: Select and confirm proposed metadata directly

**Files:**
- Modify: `Sources/Rubien/Views/ImportReviewSession.swift`
- Modify: `Sources/Rubien/Views/ImportReviewSheet.swift`
- Modify: `Sources/Rubien/Resources/en.lproj/Localizable.strings`
- Modify: `Tests/RubienTests/ImportReviewSessionTests.swift`
- Modify: `Tests/RubienTests/PDFImportReviewContextTests.swift`
- Modify: `Tests/RubienTests/MetadataImportReviewContextTests.swift`
- Modify: `Tests/RubienTests/PendingMetadataReviewContextTests.swift`

**Interfaces:**
- Consumes: `ImportReviewContext.useProposedMetadata(itemID:) -> ImportReviewItem`, including the existing PDF, identifier, and pending-metadata implementations.
- Produces: `ImportReviewItem.isSelectedByDefault: Bool`; proposal rows remain `.needsProposal` internally but become directly selectable; `ImportReviewSession.confirmSelected()` promotes selected proposals before calling `commit(selectedIDs:)`.

- [ ] **Step 1: Write failing shared-session tests**

Add tests proving a proposal is selectable but not initially selected, `selectAllReady()` can include it, and explicitly selecting then confirming it calls the context promotion hook before commit:

```swift
func testProposalIsSelectableButStartsUnselected() {
    let verified = makeItem(title: "Verified", readiness: .ready)
    let proposal = makeItem(title: "Proposal", readiness: .needsProposal)
    let context = FakeImportReviewContext(items: [verified, proposal])
    let session = ImportReviewSession(title: "Review", context: context)

    XCTAssertTrue(proposal.isSelectable)
    XCTAssertEqual(session.selectedIDs, [verified.id])

    session.selectAllReady()
    XCTAssertEqual(session.selectedIDs, [verified.id, proposal.id])
}

func testConfirmingSelectedProposalAcceptsItBeforeCommit() async {
    let proposal = makeItem(title: "Proposal", readiness: .needsProposal)
    let context = FakeImportReviewContext(items: [proposal])
    context.proposedItem = makeItem(id: proposal.id, title: "Proposal", readiness: .ready)
    context.nextReport = ImportReviewCommitReport(succeededIDs: [proposal.id], failures: [:])
    let session = ImportReviewSession(title: "Review", context: context)

    session.setSelected(true, itemID: proposal.id)
    await session.confirmSelected()

    XCTAssertEqual(context.proposalCalls, [proposal.id])
    XCTAssertEqual(context.commitCalls, [[proposal.id]])
    XCTAssertTrue(session.items.isEmpty)
}
```

Extend `FakeImportReviewContext` with `proposedItem` and `commitCalls`, returning the ready replacement from `useProposedMetadata`.

- [ ] **Step 2: Run the shared-session tests and verify RED**

Run:

```bash
swift test --filter ImportReviewSessionTests
```

Expected: the proposal is not selectable and cannot reach the promotion/commit assertions.

- [ ] **Step 3: Separate selectability from default selection and promote during confirmation**

In `ImportReviewItem`, keep the existing readiness cases and add:

```swift
var isSelectable: Bool {
    !isWorking && (readiness == .ready || readiness == .needsProposal)
}

var isSelectedByDefault: Bool {
    readiness == .ready && !isWorking
}
```

Initialize the session with only default-selected rows:

```swift
self.selectedIDs = Set(context.items.filter(\.isSelectedByDefault).map(\.id))
```

Keep `selectAllReady()` based on `isSelectable`, so it includes proposals on explicit request. Update `replaceItem(_:)` to preserve an existing explicit selection, select newly verified candidate results, and leave a retry-produced proposal unselected:

```swift
private func replaceItem(_ updated: ImportReviewItem) {
    guard let index = items.firstIndex(where: { $0.id == updated.id }) else { return }
    let wasSelected = selectedIDs.contains(updated.id)
    items[index] = updated
    if updated.isSelectable {
        if wasSelected || updated.isSelectedByDefault {
            selectedIDs.insert(updated.id)
        }
    } else {
        selectedIDs.remove(updated.id)
    }
}
```

At the start of `confirmSelected()`, after admission checks and before `context.commit`, promote only selected proposal rows through the existing source-specific hook:

```swift
for id in selection where items.first(where: { $0.id == id })?.readiness == .needsProposal {
    replaceItem(context.useProposedMetadata(itemID: id))
}
```

Then recompute the commit selection from the originally selected IDs whose updated rows are `.ready`. If promotion unexpectedly does not produce `.ready`, retain that row and attach a clear commit error instead of calling the context committer with an unresolved payload.

- [ ] **Step 4: Remove the visible proposal action**

In `ImportReviewSheet.rowAction`, render no secondary button for `.needsProposal`:

```swift
case .ready, .needsProposal:
    EmptyView()
```

Remove the now-unused `"Use proposed metadata"` localization entry. Keep the internal context hook; it is now the source-specific promotion mechanism invoked by selected confirmation.

- [ ] **Step 5: Add source-context regressions**

For PDF, identifier, and durable pending contexts, add one focused test each that constructs a usable `.needsProposal` row, creates an `ImportReviewSession`, verifies it starts unselected, selects it, confirms, and asserts the existing committer receives manually verified metadata. Convert the existing PDF proposal test to `async throws` and replace its direct `context.useProposedMetadata` call with:

```swift
XCTAssertEqual(context.items[0].readiness, .needsProposal)
let session = ImportReviewSession(title: "Review PDFs", context: context)
XCTAssertTrue(session.selectedIDs.isEmpty)

session.setSelected(true, itemID: context.items[0].id)
await session.confirmSelected()

XCTAssertTrue(session.items.isEmpty)
let imported = try database.fetchAllReferences()
XCTAssertEqual(imported.count, 1)
XCTAssertEqual(imported[0].verificationStatus, .verifiedManual)
XCTAssertFalse(FileManager.default.fileExists(atPath: source.temporaryDirectoryURL!.path))
```

Convert `testUseProposedMetadataStagesSeedBlockedAndRejectedReferences` to drive all three identifier proposals through one session, call `selectAllReady()`, confirm, and assert three manually verified references were written in input order. For pending metadata, resolve an intake candidate to a `.seedOnly` result with a usable fallback, assert the session updates to `.needsProposal` and remains unselected, then select and confirm; assert the original intake ID leaves the pending fetch, exactly one reference is written, and no replacement intake is created.

- [ ] **Step 6: Run focused and app tests**

Run:

```bash
swift test --filter ImportReviewSessionTests
swift test --filter PDFImportReviewContextTests
swift test --filter MetadataImportReviewContextTests
swift test --filter PendingMetadataReviewContextTests
swift test --filter RubienTests
```

Expected: all tests pass; proposal rows start unselected and commit only after explicit selection plus footer confirmation.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/Rubien/Views/ImportReviewSession.swift \
  Sources/Rubien/Views/ImportReviewSheet.swift \
  Sources/Rubien/Resources/en.lproj/Localizable.strings \
  Tests/RubienTests/ImportReviewSessionTests.swift \
  Tests/RubienTests/PDFImportReviewContextTests.swift \
  Tests/RubienTests/MetadataImportReviewContextTests.swift \
  Tests/RubienTests/PendingMetadataReviewContextTests.swift
git commit -m "fix(app): streamline proposed metadata confirmation"
```

---

### Task 2: Make Return submit the import source sheet

**Files:**
- Modify: `Sources/Rubien/Views/ImportSourceSheet.swift`
- Modify: `Tests/RubienTests/ImportSourceSheetModelTests.swift`

**Interfaces:**
- Consumes: `ImportSourceSheetState.canImport` and the existing `beginImport()` action.
- Produces: `ImportSourceSheetState.canSubmit(isAcquiring:) -> Bool`; the Import button becomes SwiftUI's `.defaultAction`.

- [ ] **Step 1: Write failing state tests for typed, selected, and busy submission**

Add:

```swift
func testSubmissionRequiresSourceAndIdleState() {
    var state = ImportSourceSheetState()
    XCTAssertFalse(state.canSubmit(isAcquiring: false))

    state.setTypedInput("/tmp/paper.pdf")
    XCTAssertTrue(state.canSubmit(isAcquiring: false))
    XCTAssertFalse(state.canSubmit(isAcquiring: true))

    state.setStagedURLs([
        URL(fileURLWithPath: "/tmp/one.pdf"),
        URL(fileURLWithPath: "/tmp/two.md"),
    ])
    XCTAssertTrue(state.canSubmit(isAcquiring: false))
    XCTAssertFalse(state.canSubmit(isAcquiring: true))
}
```

- [ ] **Step 2: Run the source-sheet model tests and verify RED**

Run:

```bash
swift test --filter ImportSourceSheetModelTests
```

Expected: compile failure because `canSubmit(isAcquiring:)` does not exist.

- [ ] **Step 3: Add the shared submission predicate**

In `ImportSourceSheetState` add:

```swift
func canSubmit(isAcquiring: Bool) -> Bool {
    canImport && !isAcquiring
}
```

Use the same predicate for the button and the action guard:

```swift
.disabled(!state.canSubmit(isAcquiring: isAcquiring))
```

```swift
private func beginImport() {
    guard state.canSubmit(isAcquiring: isAcquiring) else { return }

    Task { @MainActor in
        isAcquiring = true
        acquisitionError = nil

        do {
            let sources = try await materializeSources()
            isAcquiring = false
            onImport(sources)
            dismiss()
        } catch {
            isAcquiring = false
            acquisitionError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Mark Import as the default action**

Attach the standard SwiftUI shortcut to the existing primary button after its button style:

```swift
.buttonStyle(SLPrimaryButtonStyle())
.keyboardShortcut(.defaultAction)
.disabled(!state.canSubmit(isAcquiring: isAcquiring))
```

Do not add a text-field `onSubmit` or an event monitor. The button shortcut must work both for typed input and after focus returns from **Choose…**, and SwiftUI automatically respects the disabled state.

- [ ] **Step 5: Run focused and app tests**

Run:

```bash
swift test --filter ImportSourceSheetModelTests
swift test --filter RubienTests
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/Rubien/Views/ImportSourceSheet.swift \
  Tests/RubienTests/ImportSourceSheetModelTests.swift
git commit -m "fix(app): submit import sheet with return"
```

---

### Task 3: Final verification and manual smoke

**Files:**
- Modify only files required by evidence-backed verification findings.

**Interfaces:**
- No new interfaces; verify Tasks 1 and 2 compose with the existing selected-batch review feature.

- [ ] **Step 1: Run diff hygiene and the full contract matrix**

Run:

```bash
git diff --check
swift test
npm --prefix mcp-server test
npm --prefix mcp-server run build
```

Expected: Swift tests pass with zero failures; MCP passes 36 tests; TypeScript build succeeds; no whitespace errors.

- [ ] **Step 2: Relaunch the isolated app**

Run:

```bash
RUBIEN_LIBRARY_ROOT=/private/tmp/rubien-manual-import-check swift run Rubien
```

Expected: the app opens against the scratch library.

- [ ] **Step 3: Manually verify both interactions**

Verify:

- a PDF with usable non-authoritative metadata shows no **Use proposed metadata** button;
- that proposal starts unselected, can be selected, and imports on **Confirm 1 selected**;
- authoritative rows still start selected and candidate rows still require **Choose match…**;
- Return imports a valid typed absolute path or URL;
- after choosing multiple files, Return starts preparation without clicking **Import**; and
- Return does nothing while the Import button is disabled or busy.

- [ ] **Step 4: Request final review and commit evidence-backed fixes**

Review the complete diff from `583fc2e` to `HEAD` against the approved spec. Fix any Critical or Important findings, rerun the full matrix, and commit only if a correction is required:

```bash
git add -A
git commit -m "fix(app): polish streamlined import confirmation"
```
