# Attach supplementary files from Assistant document cards

**Date:** 2026-11-21
**Status:** Design approved 2026-11-21 (decisions in §9). Phases 1 and 2
implemented with focused tests. The CLI URL attach was smoke-tested against a
loopback server. The chooser sheet has not yet been checked on screen. Surfaces
without a library database (test/debug roots, scheduled-run transcripts) keep
today's Add Reference route.
**Scope:** Assistant document cards and a new chooser sheet (app),
`ReferenceAttachmentStore` and a supplement URL detector (Core),
`rubien-cli attachment add`, native and npm MCP.

## 1. Problem

An Assistant answer about *SpeeDiff* shows two document cards: the library paper
and "SpeeDiff — CVPR 2026 Supplementary Material" as a **PDF candidate**. The
candidate's **Add to Rubien…** button creates a second reference.

The current path is: `chat.js` posts `addPaperSource {url}` →
`ChatTranscriptView` → `ReaderChatPaperActions.addSource` in reader windows, or
`beginSuggestedReferenceImport` on Home → `AddReferenceFlowSheet(initialInput:)`.
A `.pdf` URL routes `.file` → `AddReferenceSourceSheet` →
`ImportSourceMaterializer` downloads it → PDF import review → **new reference**.

Reference attachments already exist (spec:
[2026-09-28-reference-attachments-design](../specs/2026-09-28-reference-attachments-design.md)).
`ReferenceAttachmentStore.importFile(at:referenceId:)` stores PDFs and Markdown
per reference, deduplicates by SHA-256, and feeds the Details **Attachments**
section, attachment readers (with their own annotations and Assistant history),
`rubien-cli attachment *`, `rubien_attachment_*` in both MCP servers, and gated
CloudKit sync. Two pieces are missing:

1. A route from a card URL into that store.
2. A way to tell which reference a candidate belongs to.

This design adds both without adding any storage model.

## 2. Decisions

| Topic | Decision |
|---|---|
| Storage | Reuse `importFile`; no new table, field, or record type. |
| Card action | Keep the single **Add to Rubien…** button. For attachable files it opens a chooser sheet: **Attach to ‹suggested paper›** / **Attach to another reference…** / **Add as a new reference**. |
| Who chooses | The agent suggests a parent through a new optional field on the card tool. Rubien adds heuristic suggestions. The user always finalizes in the sheet. |
| Dedupe | Existing per-reference hash check after download; repeats report "Already attached". |
| Source URL | Not stored (no schema change). |
| Display name | The card title (≤255 chars, editable in the sheet); `originalFilename` keeps the URL basename for export. |
| Parity | `attachment add` accepts HTTP(S) URLs and `--name` in the CLI, native MCP, and npm MCP. |
| Sync | No change; inherits attachment sync as it is today. |

## 3. Card and chooser sheet

**Cards.** Cards keep their current layout and **Add to Rubien…** label.
Detected supplements show the badge `Supplement candidate`. What a click does
depends on the candidate:

| Candidate | Click opens |
|---|---|
| Attachable file: `PDF candidate`, `Document candidate` (`.md`), or `Supplement candidate` | The chooser sheet below. |
| `Paper candidate` or `Web candidate` | Today's Add Reference flow, unchanged. |

The chooser is presented by the window that hosts the transcript: the main
window for Home, the reader window for reader chats. Attaching needs nothing from
the library window.

```text
┌ Add “SpeeDiff — CVPR 2026 Supplementary Material” ──────────────┐
│ openaccess.thecvf.com · PDF                                      │
│                                                                  │
│ (•) Attach to  SpeeDiff: Scalable Pixel-Anchored End-to-End …    │
│                Suggested by the Assistant                        │
│ ( ) Attach to  ‹other plausible match, if any›                   │
│ ( ) Attach to another reference…  [ Search library…          ]   │
│ ( ) Add as a new reference                                       │
│                                                                  │
│ Attachment name  [ SpeeDiff — CVPR 2026 Supplementary Material ] │
│                                         [Cancel]  [Attach]       │
└──────────────────────────────────────────────────────────────────┘
```

**Default selection:**

- The top suggestion (§4), when the agent declared it or the candidate looks
  supplementary.
- Otherwise **Add as a new reference**, which is today's outcome. For example, a
  related paper's PDF in a reader chat lists the current paper as a row but does
  not preselect it.

**Suggestion rows:**

- Each row shows the parent's database title and its source: "Suggested by the
  Assistant", "Current paper", or "Shown above".
- Show at most three rows. Hide duplicates of the same reference.

**Attach to another reference.** A search field over the library, reusing the
query behind the composer's `@` mentions. Choosing a result selects that row.

**Primary button:**

- Reads **Attach** when an attach row is selected, and **Continue…** for a new
  reference.
- **Continue…** closes the sheet and calls the existing add-source route
  unchanged, so the new-reference path keeps its current behavior and tests.
  Trade-off: an unmatched PDF candidate takes one extra click compared with today.

**Progress and results, shown inside the sheet:**

- *Downloading…* (Cancel stops the download task).
- **Attached to SpeeDiff**, with [Open] [Done].
- **Already attached**, with [Open] [Done].
- An error, with [Try again]; the other options stay available.
- **Open** calls `ReaderWindowManager.openAttachment`.

Cards keep no per-click state. Reopening a conversation therefore needs no stored
state either.

## 4. Suggesting the parent reference

The agent can suggest the parent; Rubien's resolver ranks it alongside its own
heuristics. Nothing is attached until the user confirms.

**Agent flag.** The web items of the app-private `rubien_present_document_cards`
tool gain an optional `supplementOf: <referenceId>`.

- The handler (`MCPAppPresentationToolCatalog`) verifies the reference exists, as
  it already does for library items. It emits `parentReferenceId` in the card. A
  missing or deleted reference rejects the call with a clear error, as invalid
  `referenceId` items do today.
- Prompt rule (`documentCardInstruction`): *"When an external file is
  supplementary material (supplement, appendix, supporting information) of a
  saved library document, set `supplementOf` to that document's referenceId; the
  user confirms before anything is attached."*
- The tool is app-private: it is absent from the public native and npm catalogs
  and from the CLI docs. So this needs no npm change.

**Resolver.** `ChatPaperAttachTarget` is a pure, tested resolver that runs in
Swift at click time, with database access. `chat.js` forwards the card's
`parentReferenceId` and the reference IDs of library cards in the same group.
The resolver ranks, then deduplicates:

1. **Declared by the agent:** `parentReferenceId`, re-checked as existing and not
   deleted.
2. **Current paper:** for `.reference(R)` the target is `R`; for `.attachment(A)`
   it is A's parent. It is always listed, because the `@` mention search
   excludes the current paper and the row would otherwise be unreachable. It is
   preselected only under the §3 rule.
3. **Shown above:** a library card in the same group whose short title (before
   the first `:` / ` — `) appears in the candidate title, when the candidate
   looks supplementary.

**"Looks supplementary"** is a Core detector (`SupplementaryMaterialURL`) with tests:

- Keywords in the title or filename: *supplement(al|ary)*, *supp*,
  *appendix/appendices*, *supporting/supplementary information*, *SI*,
  *extended data*, *ESM*.
- Host patterns, recorded in
  [Supported-Paper-URLs](../Supported-Paper-URLs.md): CVF
  `/content/<venue>/supplemental/…`, NeurIPS `…-Supplemental….pdf`, PMLR
  `…-supp.pdf`.
- Corroborating but not required: the same host and venue directory as the
  parent's `url`.
- Cards carry no DOI or landing page, so those signals are not available.

**Trust.**

- Titles in the sheet come from the database, never from agent text.
- The user confirms every attach, so the card's forwarded IDs only affect which
  rows are suggested.
- `render.js` already escapes raw HTML in messages, so message text cannot
  imitate card buttons.
- The URL is re-validated with `ChatExternalLink.classify` before download.

## 5. Attach pipeline

New `AssistantSupplementAttacher`: a main-actor façade whose file and network
work runs detached. The sheet's model drives it.

1. Re-check the selected parent (it exists and is not deleted) and the URL.
2. Call `ImportSourceMaterializer.materialize(url, localPathPolicy: .requireAbsolute)`.
   This performs the same content-type and magic-byte checks and GitHub-blob
   normalization as Add Reference.
3. Call `ReferenceAttachmentStore.importFile(at:referenceId:displayName:)`. The
   new optional `displayName` defaults to the filename, so existing callers are
   unchanged.
4. `cleanup()` removes the temporary directory in a `defer`. Cancel cancels the
   task and removes the temporary directory.
5. The store's file lock already serializes imports; `.busy` maps to "Try again".

Markdown candidates (`.md`) use the same path. Small Core fix:
`ImportSourceKind` accepts `.markdown`, but `importFile` accepts only `pdf`/`md`.
Accept `markdown` there too, with a test.

## 6. Dedupe

- **Existing rule.** On the same reference, an active attachment with the same
  kind and SHA-256 makes the import a duplicate (`wasDuplicate`), shown as
  "Already attached". This covers repeat clicks, reopened conversations, and
  mirror URLs.
- **Different references.** Identical bytes on a different reference are allowed,
  since attachments belong to one reference.
- **Removed attachments** do not count. Re-attaching after removal creates a new
  UUID, consistent with the attachment spec's removal markers.
- **Primary PDF bytes.** Bytes identical to the primary PDF may be attached; this
  is allowed by the spec.
- **Concurrent devices.** Two Macs may create two UUIDs for the same bytes. Both
  are kept, unchanged from the spec.
- **Download first.** Each attach downloads before the duplicate check, because
  the source URL is not stored.

## 7. How the attachment appears afterwards

- **Details.** It appears live in the Attachments row
  (`ReferenceAttachmentsModel`'s `ValueObservation`): kind, display name, size,
  and "On this Mac" or the sync state.
- **Reader.** It opens in the attachment PDF reader, with its own window,
  annotations, Assistant history, and printing.
- **Assistant in the attachment reader.** It gets full context through
  `AttachmentChatContext`, as today.
- **Assistant in the parent reader or Home.** The agent reaches the attachment
  through `rubien_attachment_list` and `rubien_attachment_read`. Add both names to
  the reader prompt's tool list (prompt-only change).
- **Not covered.** `rubien_grep_text` and library search do not see attachment
  bodies. That is existing deferred work (attachment spec §9).
- **Follow-up, not in this plan:** an Attachments menu in the primary reader
  toolbar, so you need not go through Details.

## 8. Parity, sync, and a related fix

**CLI and MCP.** The Core mutation gains URL input and `displayName`, so CLI
parity applies:

- `rubien-cli attachment add <ref> <file-or-url>... [--name <display>]`.
  - HTTP(S) inputs go through `ImportSourceMaterializer`, as `create` already
    does; this works on Linux too.
  - `--name` requires exactly one input.
  - The JSON shape is unchanged: `{file, outcome, status?, error?}`.
- Native `rubien_attachment_add` and npm `attachments.ts`:
  - `files` may contain URLs; a new optional `name` is `string, 1…255`;
    descriptions are updated.
  - Bump npm `MIN_CLI_BUILD` to the shipping build, because an older CLI would
    treat a URL as a path. Do this in the release-prep commit together with
    `BUILD.txt` and the stub CLI fixture, as 0.8.0 did (`7c953162`). Bumping it
    earlier fails the npm native-parity tests against the current build.
- Users can also say "attach the supplement to this paper". The agent then uses
  the existing write-approval path rather than the sheet.
- The `supplementOf` field changes only the app-private presentation tool
  (`MCPAppPresentationToolCatalog`, `ChatPaperModels`, `chat.js`); the npm server
  needs no change for it.
- Update `Docs/CLI-Reference.md`.

**Sync.** No new tables, fields, record types, or dispatch. The path ends in the
existing `importFile` transaction: metadata row, cache row, upload queue, and the
`attachmentAsset` dirty state. So it behaves exactly like a Details import:
"On this Mac" while attachment sync is off (the default), and
`CDReferenceAttachment` / `CDAttachmentAsset` when it is on. The display name is
set at insert, so no extra rename save is sent. The
[Sync Development](../Sync-Development.md) rules are not engaged.

**Related fix (pre-existing).** NeurIPS supplements
(`/paper_files/paper/<y>/file/<hash>-Supplemental-Conference.pdf`) and PMLR
supplements (`/v<n>/<id>/<id>-supp.pdf`) match the `KnownPaperHost` PDF patterns
(`PaperURLResolver.swift:797-805`). `ImportRouter` sends every match to the
resolver, so these show as "Paper candidate" and Add resolves them as the paper
itself. The plan excludes supplement patterns from those host matches, so they
route as attachable files. This is registry-governed: update
Supported-Paper-URLs and the classification, rewrite, and resolver tests
together.

## 9. Product decisions (2026-11-21)

1. **Card action:** the chooser sheet behind the existing **Add to Rubien…**
   button, rather than a direct **Attach to ‹paper›** button.
2. **Agent role:** the agent suggests a parent through `supplementOf`, and the
   user finalizes in the sheet. Reading of this decision: **Attach to another
   reference…** (library search) ships in v1 inside the sheet, as shown in the
   chosen option.
3. **Source URL:** not stored; dedupe by content hash after download.

## 10. Phases and tests

Each phase builds, passes its focused tests, and is one commit after the
AGENTS.md review step.

**Phase 1: Core, CLI, and MCP.**

- `SupplementaryMaterialURL` detector, plus the supplement-first
  `externalCandidateBadge`.
- `KnownPaperHost` exclusions and a registry update.
- `importFile(displayName:)` and acceptance of the `.markdown` extension.
- CLI URL inputs and `--name`; native and npm schemas; docs.
- Tests:
  - `RubienCoreTests`: detector matrix (keywords, CVF/NeurIPS/PMLR, ordinary
    paper titles as negatives); `KnownPaperHostClassifyTests` and
    `PaperURLRewriteTests` for the exclusions; `AddReferenceInputRouterTests`;
    `ReferenceAttachmentStoreTests` for `displayName`, `.markdown`, and
    duplicates preserving the existing name.
  - `RubienCLITests.AttachmentCommandTests`: URL input against a local fixture
    server, `--name` with one versus many inputs, HTTP failure and non-PDF payload
    as per-input errors, JSON shape.
  - `MCPServerTests`: the `rubien_attachment_add` schema.
  - `mcp-server`: `npm run build && npm test`.

**Phase 2: suggestion flag and chooser sheet (app).**

- Presentation tool: `supplementOf` → `parentReferenceId`.
- `ChatPaper` field and `validatedGroup` bounds; history encode/decode.
- `chat.js` forwards `parentReferenceId` and sibling IDs in `addPaperSource`;
  rebuild `ChatTranscript.html` with `npm run build` in `scripts/chat-renderer`.
- `ChatPaperAttachTarget` resolver.
- The chooser sheet and a pure `SupplementAttachChoiceModel`.
- `AssistantSupplementAttacher`.
- Library search for **Attach to another reference…**.
- Prompt updates.
- Tests:
  - `RubienCLITests.MCPServerTests`: `supplementOf` validation (missing or
    deleted reference, wrong type, extra keys still rejected).
  - `RubienTests.ChatPaperPresentationTests`: round-trip and restore; old history
    without the field still decodes.
  - Resolver tests: declared, current paper, shown above, ranking and
    deduplication, a deleted suggestion dropped, none.
  - Choice-model tests: default selection, the button label per selection,
    progress → added / duplicate / error → retry, cancel cleans the temporary
    directory, a parent deleted while the sheet is open.
  - Routing tests: attachable candidates open the chooser; paper and web
    candidates keep today's flow; **Continue…** posts the unchanged add-source
    route.
  - `AssistantContextTests`: prompt text.
  - `scripts/chat-renderer` integration tests: the payload carries the parent and
    sibling IDs, and nothing happens on render.
- Manual check: `scripts/preview-app.sh`; reproduce the SpeeDiff answer in Home
  and in a reader; attach, attach again (Already attached), search for another
  target, add as a new reference, open the attachment, and check Details. Use the
  CLAUDE.md click-center checks.
