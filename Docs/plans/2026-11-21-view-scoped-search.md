# View-scoped library search (⌘F)

Status: implemented; focused tests and a live preview check pass.

## Problem

`SearchOverlay` searches `db.fetchReferences(scope:filter:…)` where `scope` is the
current view's `ReferenceScope` (`.all` / `.tag`). The view's `ViewFilter`s
(Status, Year, property conditions — applied client-side by `FilterEngine` in
`ReferenceTableView`) are ignored, nothing in the overlay says which scope is in
effect, and Enter always jumps to unfiltered All References, leaving the view.

## Design

**Scope choice.** When ⌘F opens over a library list that hides something (a
saved view with a tag scope or at least one filter, including unsaved draft
filters currently on screen), the overlay shows two pills at the left of its
filter bar: `[view icon] <View name>` and `Library`. The active pill is
highlighted; the caption under the content picker names the scope.

- **This view** = the view's `ReferenceScope` + its live `viewFilters`, then the
  overlay's own Type / PDF / Year / Title-only pills on top.
- **Library** = the whole library (`.all`). Today a tag-scoped view silently
  limits search to its tag; that becomes explicit in "This view" instead.

When the list hides nothing (unfiltered All References or a view without
filters/tag), no pills are shown; search is the library, as today.

**Filtering.** A `LibrarySearchViewScope` value carries the list's scope,
filters, tag map, property values, and property definitions from the view
model; if a sync changes it while the overlay is open, the search re-runs. The
search worker fetches with the view's DB scope, then runs `FilterEngine.apply`
with a `PipelineContext` built by the same helper the table uses
(`PipelineContext.library(db:…)`, extracted from
`ReferenceTableView.pipelineContext`). With view filters present, the DB fetch
runs unlimited, reads only the table's light columns, and the 20-row "Recent"
cap is applied after filtering, so the recent list is not short-changed.
Relevance order is preserved.

Revealing a result in the current list expands a collapsed group that holds
it, which marks a grouped saved view as edited, the same as expanding it by
hand.

**Selection.** In "This view", Enter / click / "Open selected" sets
`selectedId` and bumps `tableScrollRequest` without changing the sidebar, so the
view (and any unsaved draft) stays put and the table reveal scrolls to the row.
The same in-place reveal applies when the current list hides nothing (the row
is guaranteed visible). "Library" keeps `revealReference` (switch to
All References).

## Decisions (confirmed 2026-11-21)

1. **Default scope:** "This view" whenever the view narrows; "Library" is one
   click away. Not persisted.
2. **Notes & highlights:** view filters apply to the note's or highlight's
   reference, like the other segments, so the in-view reveal stays valid.
3. **Home:** library only, no scope pills; selecting opens All References.
4. **`searchText`:** removed with `activeFilter`, `scheduleSearchDebounce`,
   and the then-orphaned `SearchQuery` and its tests.

## Files

- `Sources/Rubien/Views/SearchReferenceView.swift`: scope pills, caption,
  worker, selection callback.
- `Sources/Rubien/Views/LibrarySearchScope.swift` (new): `LibrarySearchViewScope`
  (with the single `hidesReferences` rule) and the pure fetch-and-narrow function.
- `Sources/Rubien/Views/ContentView.swift`: build the view scope, in-place
  reveal, (decision 4) the `searchText` path.
- `Sources/Rubien/Views/ReferenceTableView.swift`: `PipelineContext.library`,
  the context helper shared by the table and search (not the selection scroller).
- `Tests/RubienTests/LibrarySearchScopeTests.swift` (new, `#if os(macOS)`).

## Tests

In-memory `AppDatabase`: view scope applies `ViewFilter`s to keyword results;
tag scope + filter; Library ignores view filters; Notes & highlights results
narrowed per decision 2; Recent cap applied after filtering; "hides nothing"
detection; relevance order kept after narrowing.

## Verification

`scripts/preview-app.sh`, then in a "Status = Unread" style view: ⌘F, type a
term matching read and unread papers, confirm only unread results in
"This view", switch to Library and confirm more, Enter in "This view" keeps the
sidebar on the view with the row selected.
