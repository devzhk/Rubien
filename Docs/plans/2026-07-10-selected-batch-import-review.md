# Selected Batch Import Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every multi-item macOS import workflow one review-before-commit sheet with subset selection and a `Confirm N selected` action, while preserving single-item and CLI/MCP behavior.

**Architecture:** An app-owned `ImportReviewSession` presents source-neutral rows and delegates candidate/proposal actions, commit, and cleanup to an `ImportReviewContext`. Source-specific contexts retain prepared payloads without writing until confirmation. RubienPDFKit gains prepare/commit APIs for PDFs and Zotero folders; immediate wrapper APIs remain for CLI compatibility.

**Tech Stack:** Swift 6.x, SwiftUI/AppKit on macOS 15+, GRDB 7.10, PDFKit/RubienPDFKit, XCTest.

## Global Constraints

- Work only in `/private/tmp/rubien-import-source-sheet`; preserve the user's dirty primary checkout.
- Use TDD for every behavior change: witness red, implement the smallest change, then run focused tests.
- Use `apply_patch` for source and test edits.
- A review session is required when the initiating request has two or more candidate units, even if preparation leaves only one usable row.
- Ready rows start selected; candidate/proposal/error rows start unselected.
- Preparation must not create a Reference, MetadataIntake, PDF-store file, cache/upload row, or sync mutation.
- Standard Reference groups commit atomically; Zotero selected subsets commit atomically; PDFs and durable pending intakes commit serially per row.
- Remote materialized sources stay alive for retryable/unselected rows and are cleaned only after successful row commit or final discard.
- Single-item app flows and all `rubien-cli`/MCP JSON contracts remain unchanged.
- Do not add schema migrations, CloudKit fields, dependencies, or Linux-only PDF changes.

---

### Task 1: Shared review state, context contract, and sheet

**Files:**
- Create: `Sources/Rubien/Views/ImportReviewSession.swift`
- Create: `Sources/Rubien/Views/ImportReviewSheet.swift`
- Create: `Tests/RubienTests/ImportReviewSessionTests.swift`
- Modify: `Sources/Rubien/Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Produces `ImportReviewItem`, `ImportReviewCommitReport`, `ImportReviewContext`, and `@MainActor final class ImportReviewSession`.
- `ImportReviewContext` owns prepared payloads and exposes `items`, `commit(selectedIDs:)`, `resolveCandidate(itemID:candidate:)`, `useProposedMetadata(itemID:)`, `retry(itemID:)`, and `discard(remainingIDs:)`.
- `ImportReviewSheet(session:)` knows only the session and never switches on PDF/BibTeX/Zotero payload types.

- [ ] **Step 1: Write the failing session tests**

Add a `FakeImportReviewContext` and tests that exercise the exact selection contract:

```swift
@MainActor
final class ImportReviewSessionTests: XCTestCase {
    func testReadyRowsStartSelectedAndNonReadyRowsDoNot() {
        let context = FakeImportReviewContext(items: [
            .ready(title: "Ready A"),
            .needsCandidate(
                title: "Choose B",
                candidates: [MetadataCandidate(source: .translationServer, title: "B", score: 0.8)]
            ),
            .failed(title: "Broken C", message: "Unreadable"),
        ])
        let session = ImportReviewSession(title: "Review import", context: context)

        XCTAssertEqual(session.selectedIDs, [context.items[0].id])
        session.selectAllReady()
        XCTAssertEqual(session.selectedIDs, [context.items[0].id])
        session.selectNone()
        XCTAssertTrue(session.selectedIDs.isEmpty)
    }

    func testConfirmRemovesSuccessAndRetainsAtomicFailure() async {
        let context = FakeImportReviewContext.ready(count: 3)
        context.nextReport = ImportReviewCommitReport(
            succeededIDs: [context.items[0].id],
            failures: [context.items[1].id: "Batch failed", context.items[2].id: "Batch failed"]
        )
        let session = ImportReviewSession(title: "Review import", context: context)

        await session.confirmSelected()

        XCTAssertEqual(session.items.map(\.id), [context.items[1].id, context.items[2].id])
        XCTAssertEqual(Set(session.items.compactMap(\.commitError)), ["Batch failed"])
    }

    func testDiscardIsIdempotentAndIncludesEveryRemainingRow() {
        let context = FakeImportReviewContext.ready(count: 2)
        let session = ImportReviewSession(title: "Review import", context: context)
        session.discardRemaining()
        session.discardRemaining()
        XCTAssertEqual(context.discardCalls, [Set(context.items.map(\.id))])
    }
}
```

- [ ] **Step 2: Run the tests and witness red**

Run: `swift test --filter ImportReviewSessionTests`

Expected: compilation fails because `ImportReviewSession`, `ImportReviewItem`, and `ImportReviewContext` do not exist.

- [ ] **Step 3: Implement the minimal source-neutral model and session**

Use these public-in-target shapes so later tasks share one contract:

```swift
struct ImportReviewItem: Identifiable, Equatable {
    enum Readiness: Equatable { case ready, needsCandidate, needsProposal, blocked, failed }
    let id: UUID
    var title: String
    var subtitle: String?
    var message: String?
    var reference: Reference?
    var candidates: [MetadataCandidate]
    var readiness: Readiness
    var commitError: String?
    var isWorking: Bool

    var isSelectable: Bool { readiness == .ready && !isWorking }
}

struct ImportReviewCommitReport: Equatable {
    var succeededIDs: Set<UUID>
    var failures: [UUID: String]
}

@MainActor
protocol ImportReviewContext: AnyObject {
    var items: [ImportReviewItem] { get }
    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport
    func resolveCandidate(itemID: UUID, candidate: MetadataCandidate) async -> ImportReviewItem
    func useProposedMetadata(itemID: UUID) -> ImportReviewItem
    func retry(itemID: UUID) async -> ImportReviewItem
    func discard(remainingIDs: Set<UUID>)
}
```

Provide protocol defaults that return the unchanged item for unsupported candidate/proposal/retry actions. `ImportReviewSession` owns selection, working state, row replacement, commit report application, and idempotent discard; it never persists data itself.

- [ ] **Step 4: Build the shared SwiftUI sheet**

Implement a `List` with checkbox-style row selection, metadata preview, candidate/proposal/retry actions, and this footer behavior:

```swift
HStack {
    Text(String(format: String(localized: "%d selected", bundle: .module), session.selectedIDs.count))
    Button("Select all ready", bundle: .module) { session.selectAllReady() }
    Button("Select none", bundle: .module) { session.selectNone() }
    Spacer()
    Button("Close", bundle: .module) { session.discardRemaining(); dismiss() }
    Button(String(format: String(localized: "Confirm %d selected", bundle: .module), session.selectedIDs.count)) {
        Task { await session.confirmSelected(); if session.items.isEmpty { dismiss() } }
    }
    .buttonStyle(SLPrimaryButtonStyle())
    .disabled(session.selectedIDs.isEmpty || session.isCommitting)
}
```

Use `MetadataCandidatePickerView` for `.needsCandidate`; `onImportSelected` calls `session.resolveCandidate`. Apply existing hover-aware primary/secondary styles to footer actions.

- [ ] **Step 5: Run focused tests and commit**

Run: `swift test --filter ImportReviewSessionTests && swift test --filter RubienTests`

Expected: session tests pass and the app target compiles.

Commit:

```bash
git add Sources/Rubien/Views/ImportReviewSession.swift Sources/Rubien/Views/ImportReviewSheet.swift Sources/Rubien/Resources/en.lproj/Localizable.strings Tests/RubienTests/ImportReviewSessionTests.swift
git commit -m "feat(app): add shared batch import review sheet"
```

### Task 2: Side-effect-free reference preparation and atomic standard commits

**Files:**
- Create: `Sources/Rubien/Services/ReferenceImportReviewContext.swift`
- Create: `Tests/RubienTests/ReferenceImportReviewContextTests.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`
- Modify: `Tests/RubienTests/MarkdownImportWorkerTests.swift`

**Interfaces:**
- Produces `PreparedReferenceImport` (`id`, `reference`, `sourceLabel`) and `ReferenceImportReviewContext(database:entries:mergePolicy:)`.
- Splits `MarkdownImportWorker.prepareSources(_:)` from persistence; commit remains `AppDatabase.batchImportReferences(_:mergePolicy:)`.
- ContentView owns `@State private var importReviewSession: ImportReviewSession?` and a single `.sheet(item:)` for ephemeral batch review.

- [ ] **Step 1: Write failing preparation and atomic-selection tests**

Cover:

```swift
func testReferenceContextCommitsOnlySelectedRowsInOneTransaction() async throws {
    let db = try makeDatabase()
    let entries = ["A", "B", "C"].map { PreparedReferenceImport(reference: Reference(title: $0), sourceLabel: $0) }
    let context = ReferenceImportReviewContext(database: db, entries: entries, mergePolicy: .standard)

    let selected = Set([context.items[0].id, context.items[2].id])
    let report = await context.commit(selectedIDs: selected)

    XCTAssertEqual(report.succeededIDs, selected)
    XCTAssertEqual(Set(try db.fetchAllReferences().map(\.title)), ["A", "C"])
}

func testMarkdownPreparationDoesNotWriteBeforeCommit() async throws {
    let db = try makeDatabase()
    let result = await MarkdownImportWorker.prepareSources(sources)
    XCTAssertEqual(result.entries.count, 2)
    XCTAssertEqual(try db.referenceCount(), 0)
}
```

Also inject a database failure and assert every selected ID receives the same failure while no reference is committed.

- [ ] **Step 2: Witness red**

Run: `swift test --filter ReferenceImportReviewContextTests && swift test --filter MarkdownImportWorkerTests`

Expected: compilation fails because the context/preparation result is absent and the worker still persists immediately.

- [ ] **Step 3: Implement the reference context and split Markdown preparation**

`ReferenceImportReviewContext.commit` must preserve atomicity:

```swift
func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
    let selected = entries.filter { selectedIDs.contains($0.id) }
    do {
        _ = try database.batchImportReferences(selected.map(\.reference), mergePolicy: mergePolicy)
        return .init(succeededIDs: selectedIDs, failures: [:])
    } catch {
        return .init(succeededIDs: [], failures: Dictionary(uniqueKeysWithValues: selectedIDs.map { ($0, error.localizedDescription) }))
    }
}
```

`MarkdownImportWorker.prepareSources` returns parsed entries plus unreadable filenames and never receives an `AppDatabase`.

- [ ] **Step 4: Route BibTeX and RIS through review when parsed count is greater than one**

Refactor the existing detached readers into async preparation helpers. For one parsed entry, call the existing immediate batch import. For two or more, create `ReferenceImportReviewContext(..., mergePolicy: .standard)` and present `ImportReviewSession`. Zero entries/error retain current feedback.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter ReferenceImportReviewContextTests && swift test --filter MarkdownImportWorkerTests && swift test --filter RubienTests`

Commit:

```bash
git add Sources/Rubien/Services/ReferenceImportReviewContext.swift Sources/Rubien/Views/ContentView.swift Tests/RubienTests/ReferenceImportReviewContextTests.swift Tests/RubienTests/MarkdownImportWorkerTests.swift
git commit -m "feat(app): review selected reference batch imports"
```

### Task 3: Split PDF preparation from durable commit and integrate mixed PDF/Markdown review

**Files:**
- Modify: `Sources/RubienPDFKit/PDFService.swift`
- Modify: `Sources/RubienPDFKit/PDFImportCoordinator.swift`
- Modify: `Tests/RubienCoreTests/PDFImportCoordinatorTests.swift`
- Create: `Sources/Rubien/Services/PDFImportReviewContext.swift`
- Create: `Sources/Rubien/Services/CompositeImportReviewContext.swift`
- Create: `Tests/RubienTests/PDFImportReviewContextTests.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`
- Modify: `Tests/RubienTests/PendingMetadataIntakePresentationTests.swift`

**Interfaces:**
- Produces `PreparedPDFImport(sourceURL:resolution:)`, `PDFImportCoordinator.preparePDF`, and `PDFImportCoordinator.commitPreparedPDF`.
- Keeps `PDFImportCoordinator.importPDF` as prepare+commit immediate wrapper for CLI/MCP/single-item app compatibility.
- Produces `PDFImportReviewContext` and `CompositeImportReviewContext` for mixed file selections.

- [ ] **Step 1: Add failing coordinator tests**

Add tests proving preparation does not copy or write and commit does:

```swift
func testPreparePDFDoesNotCopyOrPersist() async throws {
    let db = try makeDatabase()
    let before = Set(try FileManager.default.contentsOfDirectory(atPath: AppDatabase.pdfStorageURL.path))
    let prepared = await PDFImportCoordinator.preparePDF(from: sourceURL, resolver: { _, _ in verifiedResolution() })
    XCTAssertEqual(try db.referenceCount(), 0)
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: AppDatabase.pdfStorageURL.path)), before)
    _ = prepared
}

func testCommitPreparedPDFPersistsOnlyAfterConfirmation() async throws {
    let prepared = await PDFImportCoordinator.preparePDF(from: sourceURL, resolver: resolver)
    let outcome = try PDFImportCoordinator.commitPreparedPDF(prepared, database: db)
    guard case .imported(let reference) = outcome else { return XCTFail() }
    let referenceID = try XCTUnwrap(reference.id)
    XCTAssertNotNil(try db.pdfFilename(for: referenceID))
}
```

- [ ] **Step 2: Witness red**

Run: `swift test --filter PDFImportCoordinatorTests`

Expected: compilation fails because the split APIs do not exist.

- [ ] **Step 3: Implement copy-only PDF storage and prepare/commit APIs**

Extract `PDFService.copyImportedPDF(from:) -> String` from `prepareImportedPDF`; retain security-scoped acquisition in both extraction/copy paths. Implement:

```swift
public struct PreparedPDFImport: Sendable {
    public let sourceURL: URL
    public var resolution: MetadataResolutionResult
}

public static func preparePDF(from sourceURL: URL, resolver: @escaping Resolver = ImportedPDFMetadataResolver.resolve) async -> PreparedPDFImport {
    let extracted = PDFService.extractMetadata(from: sourceURL)
    return PreparedPDFImport(sourceURL: sourceURL, resolution: await resolver(sourceURL, extracted))
}

public static func commitPreparedPDF(_ prepared: PreparedPDFImport, database: AppDatabase) throws -> PDFImportOutcome
```

Commit copies first, persists the retained resolution with `preferredPDFPath`, deletes an unowned copy on failure/duplicate exactly like the current coordinator, and leaves the caller-owned source untouched. `importPDF` delegates to the two functions.

- [ ] **Step 4: Implement PDF and composite review contexts**

`PDFImportReviewContext` maps prepared results to ready/candidate/proposal/blocked rows, retains each `MaterializedImportSource`, and commits selected IDs serially. Candidate choice uses `MetadataResolver.resolveCandidate(...treatingManualSelectionAsConfirmation: true)` but stores the result in memory. `useProposedMetadata` stages a manually verified reference without persistence. Successful rows call `source.cleanup()`; failed/unselected rows retain sources until `discard`.

`CompositeImportReviewContext` concatenates child items, partitions selected IDs by child, runs child commits sequentially, and merges reports. Use it for mixed Markdown/PDF selections.

- [ ] **Step 5: Integrate multi-source import threshold and cleanup ownership**

For exactly one materialized source, keep `importFilesWithMetadata`'s current immediate behavior. For two or more sources:

1. prepare Markdown rows and PDFs without persistence;
2. create reference/PDF child contexts;
3. present the composite session even if only one row prepared and sibling rows failed; and
4. remove the coordinator-level `defer { sources.forEach { cleanup() } }` from the review path.

Add regression coverage for two sources with one failure and one ready row: no database write before confirmation, review still opens, and the failed/unselected remote source survives until dismissal.

- [ ] **Step 6: Verify and commit**

Run: `swift test --filter PDFImportCoordinatorTests && swift test --filter PDFImportReviewContextTests && swift test --filter PendingMetadataIntakePresentationTests && swift test --filter RubienTests`

Commit:

```bash
git add Sources/RubienPDFKit/PDFService.swift Sources/RubienPDFKit/PDFImportCoordinator.swift Sources/Rubien/Services/PDFImportReviewContext.swift Sources/Rubien/Services/CompositeImportReviewContext.swift Sources/Rubien/Views/ContentView.swift Tests/RubienCoreTests/PDFImportCoordinatorTests.swift Tests/RubienTests/PDFImportReviewContextTests.swift Tests/RubienTests/PendingMetadataIntakePresentationTests.swift
git commit -m "feat(app): review selected PDF and markdown batches"
```

### Task 4: Plan and commit selected Zotero entries

**Files:**
- Modify: `Sources/RubienPDFKit/ZoteroFolderImporter.swift`
- Modify: `Tests/RubienCoreTests/ZoteroFolderImporterTests.swift`
- Create: `Sources/Rubien/Services/ZoteroImportReviewContext.swift`
- Create: `Tests/RubienTests/ZoteroImportReviewContextTests.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`
- Modify: `Sources/Rubien/Views/ZoteroImportSheet.swift`

**Interfaces:**
- Produces `ZoteroFolderImportPlan` with stable entry IDs and `ZoteroFolderImporter.prepareFolder` / `commit(plan:selectedEntryIDs:db:)`.
- Keeps `importFolder` as an immediate wrapper over prepare+commit-all for CLI.
- `ZoteroImportReviewContext` delegates selected-subset commit to RubienPDFKit.

- [ ] **Step 1: Write failing plan/selection tests**

Cover no-write planning, selected-only property/PDF behavior, and the reviewed duplicate edge:

```swift
func testSelectedLaterDuplicateStillReceivesPDF() throws {
    let plan = try ZoteroFolderImporter.prepareFolder(at: folder, db: db, propertyTarget: nil)
    XCTAssertEqual(try db.referenceCount(), 0)
    let selected = Set([plan.entries[1].id])

    let result = try ZoteroFolderImporter.commit(plan: plan, selectedEntryIDs: selected, db: db)

    XCTAssertEqual(result.imported, 1)
    XCTAssertEqual(result.attached, 1)
    XCTAssertEqual(try db.fetchAllReferences().count, 1)
}
```

Add a second partial commit and assert classification reruns against the current database and original selected-entry order.

- [ ] **Step 2: Witness red**

Run: `swift test --filter ZoteroFolderImporterTests`

Expected: compilation fails because planning/selected commit APIs do not exist.

- [ ] **Step 3: Split planning from commit**

Planning validates the property target, reacquires security scope, locates/reads `.bib`, parses entries, and returns original export order without classifying/copying/writing. Commit:

```swift
let selectedEntries = plan.entries
    .filter { selectedEntryIDs.contains($0.id) }
    .sorted { $0.sourceIndex < $1.sourceIndex }
let classifications = try db.classifyImportEntries(selectedEntries.map { $0.entry.reference })
```

Then reuse the existing copy/transaction/rollback logic on that selected array only. `importFolder` prepares and commits all IDs so CLI output remains unchanged.

- [ ] **Step 4: Route multi-entry app imports through review**

After the property-target sheet, prepare the folder off the main actor. One entry uses immediate import; two or more create `ZoteroImportReviewContext`. Closing review performs no source deletion (the user owns the folder); each planning and commit call independently reacquires the folder's security scope.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter ZoteroFolderImporterTests && swift test --filter ZoteroImportReviewContextTests && swift test --filter RubienTests`

Commit:

```bash
git add Sources/RubienPDFKit/ZoteroFolderImporter.swift Sources/Rubien/Services/ZoteroImportReviewContext.swift Sources/Rubien/Views/ContentView.swift Sources/Rubien/Views/ZoteroImportSheet.swift Tests/RubienCoreTests/ZoteroFolderImporterTests.swift Tests/RubienTests/ZoteroImportReviewContextTests.swift
git commit -m "feat(app): review selected Zotero entries"
```

### Task 5: Stage identifier candidates and confirm selected results

**Files:**
- Create: `Sources/Rubien/Services/MetadataImportReviewContext.swift`
- Create: `Tests/RubienTests/MetadataImportReviewContextTests.swift`
- Modify: `Sources/Rubien/Views/BatchImportView.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`
- Modify: `Tests/RubienTests/MetadataResolverTests.swift`

**Interfaces:**
- Produces `PreparedMetadataImport` (`id`, `input`, `result`) and `MetadataImportReviewContext` for ephemeral identifier results.
- `BatchImportView` reports prepared results to ContentView without persisting candidates/intakes.

- [ ] **Step 1: Add failing no-write and candidate-staging tests**

Test a two-input batch containing a verified result and a candidate result. Assert zero references/intakes before confirmation, candidate choice changes only the in-memory row, and commit writes only selected ready results.

```swift
func testCandidateChoiceIsStagedUntilConfirmSelected() async throws {
    let context = MetadataImportReviewContext(database: db, resolver: resolver, entries: entries)
    let candidateID = context.items[1].id
    _ = await context.resolveCandidate(itemID: candidateID, candidate: candidate)
    XCTAssertEqual(try db.referenceCount(), 0)
    XCTAssertTrue(try db.fetchPendingMetadataIntakes().isEmpty)

    let report = await context.commit(selectedIDs: [candidateID])
    XCTAssertEqual(report.succeededIDs, [candidateID])
    XCTAssertEqual(try db.referenceCount(), 1)
}
```

Cover seed-only/blocked/rejected results with a proposed reference (`Use proposed metadata` enables selection) and without one (disabled; retry remains available).

- [ ] **Step 2: Witness red**

Run: `swift test --filter MetadataImportReviewContextTests`

Expected: compilation fails because the context is absent and BatchImport still persists unresolved results while resolving.

- [ ] **Step 3: Implement metadata result projection and staging**

The context projects each enum case into candidates, proposed reference (`currentReference ?? fallbackReference`), message, and evidence. Candidate resolution calls `MetadataResolver.resolveCandidate` and retains only a `.verified` result as ready. `Use proposed metadata` applies `MetadataVerifier.manuallyVerified` in memory. Standard selected ready references commit atomically with `batchImportReferences`.

- [ ] **Step 4: Refactor BatchImportView to hand off results**

Replace `onImport`/`onQueueResult` with:

```swift
let onPrepared: ([PreparedMetadataImport]) -> Void
```

Keep concurrent resolution/progress. For a true one-line input, preserve current immediate verified/pending behavior. For two or more lines, call `onPrepared` only after all resolution finishes, then let ContentView open the shared session. Do not call `persistMetadataResolution` during preparation.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter MetadataImportReviewContextTests && swift test --filter MetadataResolverTests && swift test --filter RubienTests`

Commit:

```bash
git add Sources/Rubien/Services/MetadataImportReviewContext.swift Sources/Rubien/Views/BatchImportView.swift Sources/Rubien/Views/ContentView.swift Tests/RubienTests/MetadataImportReviewContextTests.swift Tests/RubienTests/MetadataResolverTests.swift
git commit -m "feat(app): stage selected identifier imports"
```

### Task 6: Add selected confirmation to the durable pending queue

**Files:**
- Modify: `Sources/RubienCore/Database/AppDatabase.swift`
- Modify: `Tests/RubienCoreTests/AppDatabaseTests.swift`
- Create: `Sources/Rubien/Services/PendingMetadataReviewContext.swift`
- Create: `Tests/RubienTests/PendingMetadataReviewContextTests.swift`
- Modify: `Sources/Rubien/Views/PendingMetadataQueueView.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift`

**Interfaces:**
- Adds `AppDatabase.confirmMetadataIntake(_:stagedReference:evidence:reviewedBy:)` while preserving the existing overload.
- `PendingMetadataReviewContext` stages candidate/proposal choices and commits selected intake IDs serially.
- `PendingMetadataQueueView` becomes a thin wrapper around `ImportReviewSheet` or directly hosts the same session/footer controls.

- [ ] **Step 1: Write failing Core commit tests**

```swift
func testConfirmMetadataIntakeUsesStagedReferenceAndRetainsVerifiedAuditRow() throws {
    let intake = try makePendingIntake(title: "Fallback")
    let staged = Reference(title: "Chosen candidate", authors: [.init(given: "Ada", family: "Lovelace")])

    let reference = try db.confirmMetadataIntake(
        intake,
        stagedReference: staged,
        evidence: nil,
        reviewedBy: "candidate-selection"
    )

    XCTAssertEqual(reference.title, "Chosen candidate")
    XCTAssertTrue(try db.fetchPendingMetadataIntakes().isEmpty)
    let intakeID = try XCTUnwrap(intake.id)
    let stored = try XCTUnwrap(try db.dbWriter.read { database in
        try MetadataIntake.fetchOne(database, id: intakeID)
    })
    XCTAssertEqual(stored.verificationStatus, .verifiedManual)
}
```

Also assert the intake PDF handoff is promoted and a failed/unverified staged result cannot create a second intake.

- [ ] **Step 2: Witness red**

Run: `swift test --filter AppDatabaseTests/testConfirmMetadataIntakeUsesStagedReference`

Expected: compilation fails because the staged-reference overload/fetch helper is absent.

- [ ] **Step 3: Implement one transactional staged-intake commit**

Refactor the existing confirmation body so both overloads share one transaction: manually verify `stagedReference ?? intake.bestAvailableReference`, save/merge it, attach `intake.pdfPath`, update that same intake to `.verifiedManual`, and upsert optional evidence against the existing intake/reference. Do not delete the intake row.

- [ ] **Step 4: Implement the durable context and selected queue UI**

`PendingMetadataReviewContext` uses stable UUID-to-intake-ID mapping, stages candidates in memory, defaults directly confirmable rows to selected, commits selected IDs sequentially through the new overload, and returns per-row failures. `discard` is intentionally a no-op so closing preserves pending rows. Retry may persist refreshed pending data only when the user explicitly invokes Retry; candidate choice itself remains side-effect free.

Replace the per-row immediate `Confirm & import` buttons with checkbox selection plus shared **Confirm N selected**. Keep per-row Retry/Delete menus. Preserve ContentView's scoped new-batch IDs and full toolbar queue behavior.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter AppDatabaseTests && swift test --filter PendingMetadataReviewContextTests && swift test --filter PendingMetadataIntakePresentationTests && swift test --filter RubienTests`

Commit:

```bash
git add Sources/RubienCore/Database/AppDatabase.swift Sources/Rubien/Services/PendingMetadataReviewContext.swift Sources/Rubien/Views/PendingMetadataQueueView.swift Sources/Rubien/Views/ContentView.swift Tests/RubienCoreTests/AppDatabaseTests.swift Tests/RubienTests/PendingMetadataReviewContextTests.swift Tests/RubienTests/PendingMetadataIntakePresentationTests.swift
git commit -m "feat(app): confirm selected pending metadata"
```

### Task 7: Full contract verification and manual smoke test

**Files:**
- Modify only files required by verification findings.
- Update: `Docs/specs/2026-07-10-selected-batch-import-review-design.md` status if implementation matches the approved design.

**Interfaces:**
- No new interfaces; this task verifies all previous ones compose correctly.

- [ ] **Step 1: Run formatting/diff checks**

Run: `git diff --check && git status --short && git log --oneline -12`

Expected: no whitespace errors; only intentional import-review files differ from the last task commit.

- [ ] **Step 2: Run the complete Swift and MCP matrix**

Run: `swift test`

Expected: all Swift targets pass.

Run: `npm --prefix mcp-server test && npm --prefix mcp-server run build`

Expected: MCP tests/build pass with unchanged import tool/CLI compatibility contracts.

- [ ] **Step 3: Relaunch the scratch app and smoke-test every multi-item route**

Run the app from the isolated worktree with:

```bash
RUBIEN_LIBRARY_ROOT=/private/tmp/rubien-manual-import-check swift run Rubien
```

Verify:

- two local PDFs: deselect one, confirm one, only one reference/PDF appears;
- mixed PDF/Markdown: select a subset, verify source-specific merge/attachment behavior;
- two-line identifier batch: candidate choice does not write before footer confirmation;
- multi-entry BibTeX and RIS: default-all selection, deselect, atomic selected commit;
- Zotero: selected-only stamp/PDF attach, including later duplicate selection;
- pending queue: confirm a subset, close, and verify remaining rows stay pending; and
- hover/pressed states on selection/footer buttons.

Inspect `/private/tmp` for abandoned `RubienImport-*` directories only after every review session is closed; open retryable sessions must retain their sources.

- [ ] **Step 4: Final inline review and commit fixes**

Review the complete branch diff against the design acceptance criteria. Do not launch implementation subagents unless the user explicitly requests one. Apply only evidence-backed fixes, rerun the full matrix, and commit any final corrections:

```bash
git add -A
git commit -m "fix(app): polish selected batch import review"
```
