# Zotero Local Library Import

## Outcome

Replace the Zotero export-first app workflow with a primary “Import from Zotero…” flow that:

- detects a running Zotero desktop client through Zotero’s supported local API;
- loads My Library’s collection hierarchy and direct item counts;
- lets the user choose the whole library or one or more collections, with optional subcollection inclusion;
- imports the selected scope through Rubien’s existing review-before-commit UI;
- attaches the best available local PDF (favoring one with supported annotations) with the existing atomic copy/database behavior;
- transfers supported PDF highlights, underlines, and anchored notes.

The local API is read-only and loopback-only. Rubien never edits Zotero. If Zotero is not running or its local API preference is disabled, the sheet gives an actionable retry message instead of reading `zotero.sqlite` directly.

## Design

### Supported integration boundary

Use Zotero API v3 at `http://127.0.0.1:23119/api/`, request the explicit `Zotero-API-Version: 3` header, and use user ID `0` for the current local user. The initial collection request distinguishes:

- connection failure: Zotero is not running;
- HTTP 403: Zotero is running but local API access is disabled; and
- an unsupported advertised API version.

Do not open or copy Zotero’s private SQLite database. Its schema is not Rubien’s contract, and reading the live database would require lock/WAL handling.

### Collection selection

Fetch `/users/0/collections`, decode each collection’s key, name, parent key, direct item count, and child count, and build a stable depth-first hierarchy in the app.

Each collection row has a disclosure control. Opening it lazily fetches that collection's direct items with lightweight `data` metadata, then shows each paper title and any PDF filenames present in the bounded response. A disclosure request decodes at most 500 Zotero objects and renders at most 200 papers; larger collections show that the preview is partial while the eventual import scope remains complete. This is a read-only preview: expanding a row does not select it or change the eventual import scope, and child collections remain their own rows.

The picker supports two mutually exclusive scopes through one collection list:

- Select All, which imports the entire library including unfiled references; or
- one or more explicit collection keys.

Select All is the explicit whole-library action. Checking every collection row manually remains an exact collection scope, so it does not silently add unfiled references; the selection summary distinguishes the two states.

“Include subcollections” defaults on. Expansion is computed from the fetched hierarchy before item requests. Item keys are de-duplicated because Zotero items may belong to multiple collections.

### Item and attachment preparation

For the whole library, fetch `/users/0/items?include=data,bibtex&itemType=-annotation`. For ordinary collection selections, fetch `/users/0/collections/<key>/items?include=data,bibtex`. Page full import and annotation responses in bounded chunks while preserving Zotero's `Total-Results` contract. When both collection count and direct-item estimates show that most of a large tree is selected, fetch one library snapshot and filter it by each regular item's direct `data.collections` membership; this avoids dozens of sequential collection requests without turning many mostly-empty folders into an unnecessarily large BibTeX response or accidentally including unfiled references.

The response includes both regular items and child attachments. Parse each regular item’s included BibTeX with the existing `BibTeXImporter`, and associate PDF attachment envelopes through `data.parentItem`. Prefer the attachment’s `links.enclosure.href` file URL; for linked-file attachments without an enclosure, resolve Zotero’s supported `/items/<key>/file/view/url` endpoint. Verify the file when preparing the plan. Invalid, unavailable, or missing PDF URLs are surfaced in review rather than blocking metadata import.

When annotation import is enabled (the default), fetch each selected PDF's children for narrow scopes, or fetch library annotation items once for the whole library and broad, high-volume selections, then associate records through PDF attachment keys. If a reference has multiple PDFs, prefer the available attachment with the most transferable annotations and preserve Zotero attachment order when candidates tie. Map Zotero `highlight`, `underline`, and `note` records to `PDFAnnotationRecord`: zero-based `pageIndex` is unchanged, each `[x1, y1, x2, y2]` rectangle becomes a Rubien `CGRect`, `annotationText` becomes selected text, `annotationComment` becomes note text, and Zotero’s hex color is preserved. Preserve annotation text literally so equations and code containing angle brackets are not mistaken for HTML. Count `ink`, `image`, malformed-position, and annotations belonging to an unavailable or unselected PDF as skipped.

Annotation insertion shares the reference/PDF transaction, rebinds drafts to the resolved Rubien reference ID, and de-duplicates exact type/page/rect/text matches so re-importing the same Zotero scope is idempotent. Geometry is written only when the Zotero PDF is the exact file adopted by the transaction, or when a pre-existing Rubien PDF has an identical SHA-256 and its stable cache filename still matches inside the transaction. Otherwise annotations are skipped and counted, preventing coordinates from being applied to a different edition.

The local importer produces the same plan entry shape consumed by `ZoteroImportReviewContext`. Extend that plan so an entry owns concrete attachment URLs while preserving exported-folder labels and security-scoped folder behavior. Both sources continue through one selected-subset commit implementation.

Zotero's `dateAdded` and `dateModified` values describe the source library and are not copied onto a Rubien reference. Fresh rows receive both lifecycle timestamps inside the Rubien commit transaction, so time spent in the review sheet is not misreported as time already present in the library. Existing Rubien rows retain their original added time when an import merges into them.

### UI flow

Rename the toolbar action to “Import from Zotero…”. It opens a sheet that:

- probes and loads automatically;
- shows actionable unavailable/disabled states with Retry;
- shows a searchable, indented, expandable collection list with lazy paper/PDF previews when connected;
- offers whole-library scope and subcollection inclusion;
- offers a default-on “Import PDF annotations” toggle;
- retains the existing property/value stamping controls.

Disclosure, retry, scope, cancel, and confirmation buttons reuse Rubien's shared hover/pressed button styles so every explicit action has visible pointer feedback. Native checkboxes add a matching hover highlight around their full hit area.

After confirmation, dismiss the source sheet before asynchronous preparation. Multi-item scopes open the existing import-review sheet; a one-item scope retains immediate import behavior.

## Verification

- Unit-test local API status mapping, collection decoding/hierarchy expansion, lazy collection-item summaries, item de-duplication, large-selection snapshot filtering, BibTeX conversion, linked-file and PDF association, multi-PDF preference, annotation conversion, unsupported counts, and re-import de-duplication with an injected transport.
- Extend Zotero importer tests to prove concrete local PDF URLs copy correctly and transactional cleanup remains intact.
- Add app tests for source-sheet presentation logic that does not require a live Zotero process.
- Run targeted Zotero tests, `swift build`, and `swift test`.
- Run independent review and simplify passes required by `AGENTS.md`, address accepted findings, then re-run validation.
