# Selected Batch Import Review — Design

- **Date:** 2026-07-10
- **Status:** Awaiting written-spec review
- **Scope:** macOS app batch-import workflows. `rubien-cli` and MCP remain
non-interactive and retain their current immediate-import contracts.

## Goal

Every macOS workflow that can produce more than one reference must let the
user review the proposed references, choose a subset, and explicitly confirm
only that subset before Rubien writes anything to the library.

Covered workflows:

- multi-file PDF and Markdown import;
- identifier batch import;
- BibTeX import;
- RIS import;
- Zotero-folder import; and
- the existing durable pending-metadata queue.

## Decisions

| Topic | Decision |
|---|---|
| Interaction model | One shared review-before-commit experience, rather than source-specific dialogs. |
| Review threshold | Open the selection sheet only when preparation yields two or more importable/candidate entries. A single usable entry follows its existing immediate-import behavior. |
| Initial selection | Every import-ready entry starts selected. Entries requiring a candidate choice or with an error start unselected and disabled until they are ready. |
| Confirmation | The primary action is `Confirm N selected`; it persists exactly the selected, ready entries. |
| Unselected entries | They are never persisted. They remain in the review session after a partial confirmation and are discarded if the user closes the sheet. |
| Candidate metadata | A row with multiple metadata candidates requires a per-row match choice first. The chosen candidate becomes a ready, selectable proposal; merely choosing it does not write to the database. |
| Existing pending queue | It gains the same selection controls. Its rows already exist durably, so closing leaves them in the queue; confirming only selected rows removes only those rows. |
| CLI / MCP | No interactive selection is added. Their argument/JSON contracts remain unchanged. |

## Non-goals

- Changing the behavior of single-item imports.
- Adding a terminal prompt or a new interactive MCP protocol.
- Persisting a queue record just to hold a batch draft.
- Importing and then deleting deselected references as a substitute for
  confirmation.
- Changing schema, migrations, CloudKit record fields, or sync semantics.

## Architecture

### Shared review session

The app gains an app-owned `ImportReviewSession` and reusable
`ImportReviewSheet`. A session is created only for a prepared batch of two or
more importable/candidate entries; single-entry paths retain their current
direct behavior. A session owns the prepared work for exactly one source batch
and exposes a source-neutral collection of rows:

- stable row ID;
- source label and optional attachment indication;
- proposed `Reference` preview (title, authors, year, venue/type);
- readiness state: ready, needs candidate selection, working, or failed;
- selected state; and
- source-specific commit payload retained privately by the session.

The sheet presents rows with checkboxes and a footer containing:

- a selected-count summary;
- **Select all ready**;
- **Select none**; and
- a primary **Confirm N selected** button.

Ready rows are selected by default. Failed rows show their actionable error
and cannot be selected. A candidate row exposes **Choose match…**; choosing a
candidate changes only that row's in-memory proposal, then enables its
checkbox. The footer never auto-confirms an unchosen candidate.

Confirmation is serialized per session. While committing, selected rows show
progress and all selection controls are disabled. Successfully committed rows
are removed from the session; unselected rows remain available for another
partial confirmation. When no rows remain, the sheet dismisses. Closing an
ephemeral session discards the remaining proposals and cleans its temporary
files.

### Preparation is side-effect free

Each source workflow is split into **prepare** and **commit** phases. Prepare
may read files, extract PDF text, call metadata services, and classify
duplicates, but it must not create a Reference, MetadataIntake, `pdfCache`
row, PDF-store file, upload-queue row, or sync dirty record. Commit is the
first persistence boundary.

This separation is essential: a deselected item must leave the database and
PDF store exactly as it was before the import began.

The shared session receives a source-specific committer rather than trying to
erase each importer's domain rules. A committer accepts selected row IDs,
persists only their retained payloads, reports per-row success/failure, and
owns any source-specific cleanup. The UI knows only row state and selection;
it never contains BibTeX, PDF, or Zotero persistence logic.

### PDF and Markdown multi-file import

`ImportSourceSheet` continues to materialize local/remote PDF and Markdown
sources, but the ContentView coordinator turns those sources into an
ephemeral review session instead of importing immediately.

- Markdown preparation reads and parses every source with `MarkdownImporter`.
  Valid parsed references become ready rows. Per-file read failures become
  disabled error rows. Confirmation sends only selected references through
  the existing `.markdownFillOnly` batch merge policy.
- `PDFImportCoordinator` gains an explicitly split API. Preparation performs
  extraction and metadata resolution against the caller-owned source file,
  but does not call `PDFService.prepareImportedPDF` or persist metadata.
  Commit copies a selected PDF into the library store and persists the
  already-prepared resolution atomically, preserving the current duplicate
  ownership checks and notifications.
- Candidate PDF results retain the source and result in memory. A user can
  choose a candidate in the review sheet; only the later confirmation copies
  the PDF and persists the manually-confirmed result.
- Remote materialization directories are held until the review session ends.
  They are cleaned after successful confirmation, partial failure, cancel, or
  sheet dismissal. Local caller-owned files are never removed. Security-scoped
  access is reacquired only while a preparation or commit operation reads a
  local file.

### Identifier batch import

`BatchImportView` remains responsible for accepting lines of input and
resolving them concurrently. Instead of immediately calling `onImport` for
verified results or persisting unresolved results, it passes all results into
the common review session:

- verified results are ready rows;
- candidate/seed-only/blocked/rejected results are candidate or blocked rows;
- a chosen candidate is resolved into an in-memory ready proposal; and
- confirm persists only selected ready references through the normal reference
  batch-import path.

This removes the current split behavior where verified results wait in the
Batch Import view while unresolved results are immediately written to the
durable pending queue.

### BibTeX and RIS

The existing background parsing steps remain unchanged semantically, but
their parsed `[Reference]` output becomes an ephemeral review session rather
than an immediate `batchImportReferences` call. The review preview represents
exactly the parsed fields. Confirmation submits only the selected references
in one standard batch transaction, preserving existing duplicate/merge rules.

Unreadable input or a parse result with zero entries shows the existing error
feedback and never opens an empty review sheet.

### Zotero folders

`ZoteroFolderImporter` gains a planning path in addition to its current
immediate `importFolder` API so CLI behavior remains stable:

1. validate the selected property target and locate/read the folder's `.bib`;
2. parse `BibTeXEntry` values and build review rows without copying PDFs or
   writing references;
3. on confirmation, recompute duplicate classification immediately before
   committing selected entries, copy PDFs only for those selected rows that
   still need them, and insert/merge selected references plus their aligned
   `pdfFilenames` in one transaction; and
4. remove any copied PDF on a transaction failure, as the existing importer
   already does.

The property stamp is applied only to selected rows. Missing/rejected
attachments appear as row-specific information rather than causing an
otherwise valid reference to be unselectable. This retains existing behavior:
a reference without an importable PDF can still be imported.

### Durable pending-metadata queue

`PendingMetadataQueueView` is the one persistent review consumer. It gets the
same selected-count footer and selection state, scoped to the IDs supplied by
ContentView when a new batch opens it.

- Directly confirmable rows start selected.
- Candidate rows become selectable only after an in-sheet candidate choice.
- **Confirm N selected** processes only the selected IDs, sequentially, and
  removes their completed intakes from the durable queue.
- Retry and Delete remain per-row operations; Delete is not folded into the
  batch confirmation action.
- Closing the sheet preserves all unconfirmed durable intakes, including
  queue entries that predate the current batch scope.

## State and failure handling

- A batch may have a mixture of ready, candidate, and failed rows. A failed
  row never blocks confirmation of other selected rows.
- A commit failure changes only that row to a visible error/retry state;
  successfully committed siblings remain committed.
- The sheet does not dismiss on a partial failure or partial confirmation.
- A stale duplicate classification is never trusted at commit time. Zotero
  and PDF commit paths re-check current database ownership before copy/attach.
- All commit notifications retain the current semantics: library changes are
  emitted after successful writes, and PDF upload-drainer notifications occur
  only for a newly owned library PDF.

## Testing

Add focused tests at the pure-state and persistence boundaries:

1. `ImportReviewSession` selection behavior: defaults, select-all-ready,
   select-none, candidate gating, selected-count labels, partial confirmation,
   and dismiss cleanup.
2. PDF coordinator: preparation performs no durable write/copy; selected-only
   commits create the expected reference/PDF or intake; deselected sources do
   not; temporary remote files are cleaned on every terminal path.
3. Markdown/BibTeX/RIS: parsed proposals produce no writes until confirmation;
   only selected references reach their existing merge policies.
4. Zotero: planning performs no PDF copy or database mutation; selected rows
   alone receive property stamps and aligned attachments; a failed transaction
   removes copies made for that selection.
5. Identifier batches and the durable queue: candidate choice remains
   unpersisted until `Confirm N selected`; only selected IDs are persisted or
   promoted.
6. App regression coverage for scoped new-batch review and the toolbar's full
   pending queue.

Run focused tests while implementing, then `swift test`, plus the existing
MCP test/build matrix to verify the untouched noninteractive contracts.

## Acceptance criteria

- In every covered app workflow, the user can deselect one or more proposed
  entries and confirm the rest.
- No deselected entry becomes a reference, intake, PDF-store file, cache row,
  upload record, or sync change.
- A selected Zotero entry gets its existing PDF/stamp behavior; an unselected
  one does not.
- Candidate selection does not persist before the final confirmation.
- Existing single-item and CLI/MCP import behavior remains unchanged.
