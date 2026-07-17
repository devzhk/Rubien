# Agent Home and Reading Activity — Design Spec

**Date:** 2026-07-15
**Status:** Implemented on `codex/agent-home`; technical review incorporated
2026-07-15 and final visual-QA decisions reconciled 2026-07-16
**Scope:** New default main-window Home destination, library-wide Assistant chat,
and a Reading Activity panel. Implementation checkpoints are recorded in the
[implementation plan](../plans/2026-07-15-agent-home.md).

## 1. Summary

Rubien should open into an agent-first **Home** instead of immediately placing
the user in the All References table. Home uses the existing main-window
sidebar, replaces the center table with a library-wide Assistant conversation,
and replaces the selected-reference detail card with a Reading Activity panel.

This is additive, not a removal of reference management. **All References** and
saved views remain one click away under a Library section, with their current
table, filters, columns, and reference-detail behavior unchanged.

The activity panel shows compact metrics, a calendar heatmap, and recent papers.
When the agent intentionally points to openable documents—including academic
papers, web articles, and blog posts—Home renders validated native document cards
inside the transcript so the reference leads directly to a reader or an explicit
web/import action.
Rubien already stores `Reference.lastReadAt` and an approximate `readCount`, but
those aggregates cannot reconstruct daily history. The proposed data addition
is therefore deliberately bounded: one monotonic active-seconds component per
installation, paper, and local calendar day; one metadata-only fact per
successfully started Rubien Assistant conversation; and a reset fence that makes
user-initiated clearing durable across sync. Rubien stores no prompts,
transcripts, or reader focus-event timeline for statistics.

## 2. Approved product decisions

1. **Home is the launch default; Library remains available.** The traditional
   table is preserved rather than hidden behind the agent or deleted.
2. **Home chat is library-scoped.** It has no implicit current paper. Users can
   search the library naturally or attach paper context with `@paper` mentions.
3. **Activity replaces Details only on Home.** Library destinations keep the
   existing selected-reference Details card.
4. **Estimated active reading time is the source of truth.** Seconds accrue while
   the PDF/web reader is key, visible, and the app is active; cumulative counters
   persist every minute and on pause/close. A paper-day counts as read only when
   its cross-device total reaches 60 seconds.
5. **Calendar dates are captured in the user's local time at the moment of the
   activity.** Later travel or time-zone changes do not move past squares.
6. **No fabricated history.** Detailed daily history starts when this feature
   ships. Existing open-based `lastReadAt` values do not satisfy the new
   60-second definition and are excluded from Home metrics rather than expanded
   into fictional earlier days.
7. **Activity metadata syncs through the existing private CloudKit library when
   iCloud library sync is enabled.** No product analytics service is introduced.
8. **AI statistics count only conversations started inside Rubien.** The ledger
   stores metadata only; unrelated Claude/Codex conversations and provider-owned
   transcript/history behavior are excluded.
9. **The heatmap offers Month, Quarter, and Year ranges.** Quarter is the default
   and means the calendar quarter containing the anchor date. Daily intensity
   uses fixed estimated-time bands so the same color always means the same
   amount of active reading.
10. **A fresh Home conversation leads with the composer.** The composer sits
    near the visual center of the chat canvas, with quieter initial suggestions
    directly above it. Committing the first valid user message immediately hides
    the suggestions and moves the composer to the normal bottom-docked position.
11. **Agent-referenced documents are native, actionable transcript content.** A
    validated saved document opens its PDF/Web Reader; an external web document
    opens its source and offers an explicit Add to Rubien flow.
12. **Reading Activity is a top-pinned floating card, not a full-height
    inspector.** Its neutral glass surface hugs its content and leaves the Home
    canvas visible beneath it.

The user approved D1–D7 on 2026-07-15. Section 15 records those choices and their
rationale. This approval finalizes the design branch; it does not by itself
authorize implementation.

## 3. Goals

- Make the Assistant the first, primary surface of Rubien.
- Let the agent search, compare, summarize, and organize the whole library.
- Make papers selected by the agent recognizable and safely actionable without
  making the user search for the same title in the Library table.
- Preserve every existing table-based reference-management workflow.
- Give the user an honest, glanceable picture of reading frequency.
- Define every metric precisely enough that the value is testable.
- Keep daily activity useful across devices without storing document content,
  prompts, or transcripts.
- Reuse the existing provider, history, approvals, attachments, rendering, and
  MCP infrastructure instead of creating a second chat stack.
- Keep the Home conversation alive while the user visits Library views and
  returns during the same main-window lifetime.

## 4. Non-goals

- Removing All References, saved views, filters, sorts, grouping, columns, or
  reference Details.
- Replacing the independent PDF and web reader windows.
- Treating the mutable Status option `Read` as a canonical completion signal.
- Claiming that opening or engaging with a paper means the paper was completed.
- Claiming exact reading, gaze, comprehension, or attention time. Rubien reports
  an estimate from foreground-reader activity and stores cumulative daily
  seconds, not a start/stop event timeline.
- Reconstructing daily history from `readCount`, annotations, Status, or
  `pdfCache.lastOpenedAt`.
- Persisting Assistant prompts, answers, transcript previews, attachment names,
  or provider runtime IDs in Rubien's analytics tables.
- Silently adding every web recommendation to the library or downloading its
  PDF merely because the agent mentioned it.
- A separate full-screen analytics product, goals, badges, social comparison,
  reminders, or gamification.
- Automatically injecting reading history into every agent prompt.
- Redesigning the reader-scoped Assistant experience beyond the context
  generalization necessary to share its chat surface.

## 5. Information architecture

The sidebar gains a permanent Home row above a newly explicit Library section:

```text
Home

Library
  All References
  Saved view 1
  Saved view 2
```

`Home` uses a stable icon such as `sparkles` or the existing Assistant glyph and
has no count badge. The seeded default database view remains the first Library
row, but it no longer overrides the Home startup selection.

The destination contract is:

| Destination | Center | Trailing panel | Trailing toolbar action |
|---|---|---|---|
| Home | Library-wide Assistant | Reading Activity | Activity |
| Library view | Existing reference table | Existing selected-reference detail | Details |

Model this as a destination enum such as `.home` and `.library(SidebarItem)`;
do not force Home into the reference-scope enum. `LibraryViewModel` starts at
Home. Its existing `selectDefaultViewIfNeeded()` startup path must not run on a
Home → Library reveal: an explicit reveal selects unfiltered **All References**
and must not be immediately replaced by a filtered default view. Direct sidebar
selection remains the only way to enter the seeded default view. While Home is
selected, the global Search overlay explicitly maps its reference scope to
`.all` so a previously selected saved view cannot silently constrain Home
search.

Home and Library use separate panel visibility and width state. Hiding Activity
must not unexpectedly hide reference Details, and resizing one must not resize
the other.

Sidebar selection styling follows the active destination. While Home is active,
no Library row—including **All References** or a saved view—retains its accent
selection treatment; its remembered scope becomes selected again only after the
user returns to Library.

Search and add/import remain global. A search result or explicit **Reveal in
Library** action switches to unfiltered All References and selects the paper. A
recent-activity row instead opens the available PDF/web reader and leaves Home
visible; only its no-reader fallback reveals the paper in Library. The Home
conversation remains in memory and is restored when Home is selected again.

The toolbar is destination-aware. Home keeps Search and add/import, shows the
Activity toggle, and removes table-only grouping/column/filter affordances;
Library preserves its current toolbar and Details toggle.

### 5.1 Layout sketch

```text
┌──────────────────┬────────────────────────────────────┬────────────────────────┐
│ Home             │ Assistant                 History │ ┌ Reading Activity ───┐ │
│                  │                                    │ │ metric grid          │ │
│ Library          │                                    │ │ range heatmap        │ │
│   All References │  [ + ] Ask your library…   [Send] │ │ recent papers        │ │
│   Saved view…    │  [Read next] [Find on web]        │ └─────────────────────┘ │
│                  │  [Summarize this week]             │                        │
│                  │                                    │  Home canvas continues │
└──────────────────┴────────────────────────────────────┴────────────────────────┘
```

The sketch shows a fresh conversation. The composer is centered horizontally
inside the chat canvas and its midpoint sits around 45% of the usable content
height, leaving balanced room around the suggestions above it. It is centered within the
chat column, not the entire window, so showing or hiding Activity does not make
the input look offset. There is no large welcome heading or decorative hero
above it competing for first attention.

Home's internal chat header is visually transparent: it has no leading Rubien
icon/title and no bottom separator. Only trailing **New** and **History** actions
remain, each rendered as an icon plus text with neutral hover feedback. Reader
Assistant headers retain their existing title, icon, and separator.

Keep the empty-state cluster at a comfortable maximum width of 700 points
with responsive side margins. Typing, adding a mention, or attaching a file
does not move it. When the first valid Send/Return action commits the user's
message, the suggestions disappear and the transcript layout immediately docks
the composer to the bottom, before provider output begins. Resuming a
conversation that already has content starts in that bottom-docked layout. The
docked composer retains the same maximum width and intrinsic-height footprint
as the fresh composer; only its vertical position and surrounding content
change.
**New conversation** restores the centered state. Use a subtle position
transition; with Reduce Motion, switch positions without animation. At short
heights or large accessibility text sizes, prefer safe top padding over literal
centering that clips content.

An empty input, local validation failure, attachment-preparation failure, or
turn-gate refusal before the user message is committed does not trigger the
transition: retain the centered composer, suggestions, and recoverable draft.
Once the user message is committed, a later provider failure does not return to
the empty layout because the conversation now contains user content.

At normal window widths a transparent trailing rail reserves enough width that
the Activity card never covers the transcript or composer. Only the
content-height card receives glass/background treatment; do not paint or border
the empty rail beneath it, and do not stretch the card to the window bottom. Its
ideal width is approximately 380 points, with a restrained resize range around
360–520 points. Reclaiming the unused lower-right rail for transcript flow is not
required in v1; predictable reading width is preferable to shape-aware text
reflow.

Near the existing 900-point window minimum, the panel auto-collapses without
overwriting that window's wide-layout intent. The Activity toolbar button can
show the same top-trailing card temporarily as an overlay whose maximum height
stops above the composer. Returning to a wide window restores the transparent
trailing rail. Like the current Details state, visibility and width are per main
window and are not persisted across relaunch in v1; a saved preference can be
designed separately later.

## 6. Home Assistant experience

### 6.1 Library context

The current Assistant requires a specific `ChatReference`. Replace that
assumption with an explicit conversation context:

```swift
enum AssistantConversationContext: Sendable, Equatable {
    case library
    case reference(ChatReference)
    case unclassifiedResume
}
```

Each surface owns a fixed `surfaceDefaultContext` (`.library` for Home and
`.reference(...)` for a reader) plus an `activeConversationContext`. Reference
context retains the current reader seed and history scoping. Library context
uses a separate one-line seed that identifies the agent as Rubien's library
assistant, names the available Rubien MCP capabilities, and states that there
is no preselected reference. `.unclassifiedResume` is permitted only while
resuming provider history whose origin cannot be recovered; it never seeds a
fresh conversation. A dummy reference ID is forbidden.

Library context changes four behaviors:

- `@paper` search may return every paper; there is no current paper to exclude.
- History defaults to attributed **Home conversations** and has no meaningless
  “This document” option. A secondary all-provider scope remains available as
  defined in §6.6; both scopes still read only the active provider's sessions in
  the configured Assistant workspace.
- The empty state says **Ask your library**, not **Chat about this document**.
- Suggested prompts are library-aware.

### 6.2 Reused chat capabilities

Home reuses the existing:

- Claude/Codex provider picker, model and effort controls.
- Web toggle and user-tool posture.
- Ask/Auto approval behavior and native approval cards.
- Streaming Markdown/LaTeX transcript renderer.
- Attachments, drag/drop, paste, and `@paper` mentions.
- New conversation, provider-owned History, transcript resume, and search.
- Availability/sign-in diagnostics and Recheck action.
- Turn gate, cancellation, error notices, and process teardown.

The primary Home surface should not embed `FloatingChatPanel`, which is a
reader-overlay presentation. Extract or parameterize the reusable chat surface
under `ChatSidebarView` so Home can render it as the center canvas while readers
retain their current solid floating card.

### 6.3 Empty-state composition and prompts

Initial suggestions:

- **What should I read next?**
- **Find recent papers in my field**
- **Summarize what we’ve been reading this week**

Place these immediately above the composer in a quiet, left-aligned vertical
list whose text begins at the editor caret origin. They have no icon, bezel, or
resting fill; a neutral-gray background appears on hover. Use secondary-text
color and 13-point interface type so the 14-point composer text remains the
strongest visual element. The suggestions precede the composer in visual,
keyboard, and VoiceOver order. Suggestions disappear as
soon as the first valid send commits the user message and return only for a new
empty conversation.

When the library is empty, replace paper-dependent suggestions with **Add
papers**, **Import PDFs**, and **Help me choose a field to explore**. Provider
setup failure affects only chat; Reading Activity remains visible. The web
suggestion follows the existing provider Web capability, setting, and approval
behavior; it must not silently change a persistent Web preference.

Prompt suggestions continue to call the existing typed send action. **Add
papers** and **Import PDFs** are native setup actions, not magic transcript
links: the shared surface receives explicit `@MainActor` callbacks (for example
through `ChatSurfaceConfiguration`) wired to the main window's existing add and
import flows. Transcript links retain their current validated HTTP(S)-only
behavior.

### 6.4 Clickable paper recommendations

When the agent answers a request such as **What should I read next?**, it should
normally recommend three papers unless the user requests another count. After a
short explanation, render a native **Document cards** group in the transcript:

```text
Document cards
┌────────────────────────────────────────────────┐
│ Paper A title                                  │
│ Ada Author, Bo Author…          2025 · PDF     │
└────────────────────────────────────────────────┘
┌────────────────────────────────────────────────┐
│ Paper B title                                  │
│ Chen Author                     2024 · Web     │
└────────────────────────────────────────────────┘
┌────────────────────────────────────────────────┐
│ Paper C title                                  │
│ Dev Author          2026 · Paper candidate    │
│ Open source                    Add to Rubien… │
└────────────────────────────────────────────────┘
```

Cards are compact vertical rows rather than image-heavy tiles. Each carries only
a canonical title, a compact truncated author line, year, and source/status
badge. Recommendation rationale stays in the agent's prose above the group; the
presentation contract carries no reason or other agent-authored card copy. Full
title and author metadata remain available in hover/help text; a missing year
displays a localized em dash rather than an invented value. Cards are transparent
at rest and use the same neutral-gray hover feedback as Recently Read, without an
accent hover fill. The entire library row is a button; external rows use
explicit **Open source** and **Add to Rubien…** actions so clicking a citation
does not unexpectedly mutate the library.

The card group uses the same maximum width as an ordinary transcript bubble and
otherwise shrink-wraps each row to its title/metadata content. A short title
must not produce a full-column card with unused horizontal space.

For a library reference, activation re-fetches the row by ID at click time and
uses one shared opening policy: materialized local PDF → PDF Reader; otherwise
supported/clipped URL → Web Reader; otherwise reveal the reference in
unfiltered All References and explain that no readable source is available.
Extract that policy from the existing `ContentView.openReader`/recent-row paths
rather than duplicating it. Existing reader-window reuse still applies.

For a document found on the web but not yet in the library, **Open source** routes
its absolute HTTP(S) URL through the existing external-link classifier and opens
it outside the transcript WebView. **Add to Rubien…** re-validates the URL in
Swift and enters the existing URL intake/review flow: recognized paper URLs go
through metadata resolution, direct supported files go through file intake, and
ordinary pages remain web clips. It never saves or downloads on the model's
authority alone. After an accepted import completes, use the same reader-opening
policy for the new/existing deduplicated reference. PDF download and write
approvals retain their current progress, confirmation, and failure behavior.

Do not implement these actions as model-authored `rubien://` Markdown links and
do not loosen the renderer's HTTP(S)-only Markdown sanitizer. Add a structured
`ChatPaperGroup` render item and dedicated JS→Swift messages. Library activation
may carry only an integer reference ID; Swift must fetch the live canonical row
before opening it and ignore a missing/deleted ID. Web activation may carry only
the validated card URL and must pass the same Swift HTTP(S) safety check as an
ordinary transcript link. Card text is created with DOM `textContent`, never
untrusted HTML.

The agent selects cards through the app-private, read-only
`rubien_present_document_cards` contract in §11.4. Within one Assistant turn, all
successfully decoded calls contribute to one pending **Document cards** group.
Merge calls by invocation order and items by input order, stable-deduplicate
across the entire turn, and retain at most the first ten unique items. Hold that
group until the corresponding final Assistant message is committed, then render
it immediately after that message so the explanation precedes its cards. If the
turn ends without final prose, render the group at turn completion rather than
losing it. Every successfully decoded presentation call replaces its redundant
generic tool chip; malformed/failed calls remain ordinary tool failures and
contribute no items. Live rendering and both provider-History decoders use the
same invocation ordering, deduplication, and per-turn cap. Both built-in seeds
identify the presentation tool as the navigation affordance for openable document
references; the tool description and schema carry the call shape and batching
limit. The merge rule keeps repeated noncompliant calls deterministic;
plain Markdown remains a safe fallback if a provider does not comply.

Provider-owned History remains the transcript source. Claude and Codex History
decoders reconstruct document-card groups from successful `rubien_present_document_cards` calls
and re-resolve library IDs. A reference deleted since the conversation is shown
as unavailable rather than opening a different paper; external candidates retain only
their source metadata from provider History. Rubien adds no transcript or card
table, and cards do not affect activity statistics.

### 6.5 Lifetime and navigation

Each main `WindowGroup` owns one Home renderer/session. The owner lives above
the conditional Home/Library destination so a navigation switch does not
destroy the in-memory render log or stop an in-flight turn. Closing that main
window tears down its provider. Relaunch starts with a fresh pane; History still
resumes sessions from the provider's own store, matching current policy.

The same owner holds a complete `ComposerDraft` (text, structured `@paper`
mentions, and pending attachments) and passes bindings into the shared chat
surface. Merely hoisting the session/renderer is insufficient because those
draft values are currently view-local `@State`. Home → Library → Home preserves
unsent input as well as committed and in-flight turns.

When Home is not selected, its sidebar row reflects the conversation lifecycle:

- A progress indicator while the agent is responding.
- An orange approval-needed badge while a native approval card is waiting.
- An unread completion dot when a hidden turn finishes.
- A compact error badge when a hidden turn fails.

Selecting Home clears the unread completion state and reveals the pending card,
result, or error. If the navigation sidebar is collapsed, the same approval or
completion state remains visible in a compact toolbar indicator; a hidden
approval must never look like a hung turn.

This requires structured state rather than inferring outcome from transcript
text. The controller publishes a turn-generation-keyed outcome
(`responding`, `approvalRequired`, `succeeded`, `failed`, `cancelled`, or
`superseded`) to a `HomeAttentionState` owned above destination switching.
Success/failure becomes unread only when its matching generation finishes while
Home is hidden. Selecting Home clears completed/failed unread state after the
result is visible, but never clears a pending approval. Cancellation,
supersession, and a gate refusal clear progress without fabricating a completion
or error badge.

### 6.6 History context

Home History must not silently resume a reader-seeded conversation as though it
were library-scoped. Keep a local, content-free attribution index under Rubien's
private application-storage root, excluded from CloudKit and never inside the
user-configurable Assistant workspace (which may be shared or versioned). Key
entries by a hash of the workspace identity plus provider/session ID, and store
provider kind, stable Rubien conversation UUID, and context kind; reference
context may include the numeric reference ID. Capture every rotated provider ID
as another alias for the same conversation. The raw provider session ID is not
stored in Rubien's database or synced.

Expose that index through a shared `AssistantSessionAttributionStore` actor with
atomic file replacement, because Home and multiple reader windows can start or
rotate sessions concurrently. It provides lookup and alias-recording by
workspace/provider/session hash; no view reads or rewrites the file directly.
Current provider APIs filter only by optional reference ID, so **Home
conversations** cannot fetch a fixed 25 rows and filter afterward. Recents and
search progressively overfetch 50, 100, 200, then at most 500 provider results
until they find 25 attributed Home matches or exhaust the provider. If the cap
is reached, the UI says that older matches may be available under **All provider
history** rather than presenting the result as complete.

Home History defaults to **Home conversations**. A secondary **All provider
history** scope may include document-scoped or pre-feature/unclassified sessions,
but labels known context and warns that a resumed conversation preserves its
original context. Reader History keeps its current document attribution
behavior. Losing or changing the Assistant workspace may make old sessions
unclassified; it must not mislabel them as Home conversations.

On History resume, the pane abandons its prior active identity and adopts the
selected entry's indexed Rubien UUID and original effective context. If a
referenced paper no longer exists, or the entry is unclassified, use a
non-counting ephemeral identity with `.unclassifiedResume`; never relabel it as
the surface default. **New conversation**, a provider switch, or a Codex model
change after content creates a new UUID and restores
`activeConversationContext = surfaceDefaultContext`.

Since a provider can emit `.sessionStarted` more than once or rotate its runtime
ID, activity recording uses a strict per-conversation once guard in addition to
a database uniqueness check. The attribution index is functional History
metadata and continues to record while **Record AI session statistics** is off;
that behavior is disclosed beside the toggle. It is independent of the
Assistant-statistics ledger and is not removed when those statistics are disabled
or cleared. The statistics once guard still consumes the first start while
capture is off, so re-enabling it cannot retroactively count the same
conversation.

## 7. Reading Activity panel

The panel is one top-pinned, content-hugging floating card with four sections.
Do not give its root an infinite maximum height or insert a flexible spacer that
pushes its bottom to the window edge. At normal heights it takes only its natural
content height. If that height would exceed the available content area, cap the
card with a consistent bottom margin and scroll its sections internally; the
glass outline still ends around the capped card rather than merging into the
window edge.

Reuse the repository's neutral inspector treatment:
`neutralGlassCard(cornerRadius: 14)`. On macOS 26 this uses the untinted
`NSGlassEffectView` Liquid Glass surface and soft shadow; on the macOS 14.4–15
deployment range it falls back to the existing clipped `VisualEffectView`
material and equivalent shadow. Do not hard-code a macOS-26-only API or replace
the neutral surface with accent-tinted glass. Reuse the current floating-panel
top/trailing margins and leading resize interaction where practical.

### 7.1 Header

- Title: **Reading Activity**.
- An info button explains the activity definition, local-day behavior, sync scope,
  capture controls, and the fact that detailed daily history begins with this
  feature. It also explains that time is estimated from foreground-reader state,
  saved about once per active minute plus pause/close, and may double-count
  simultaneous activity on two devices.
- Before the first clear, do not add a permanent coverage sentence beneath the
  header; the info popover explains when tracking began and how it works. After a
  clear, show **Reading activity reset <localized date>; earlier activity is
  excluded**. Independent Assistant clearing gives the AI card its own
  **Since <date>** period.
- When local capture is disabled, show **Recording off on this Mac**. The capture
  control remains in Settings; synced facts from other devices can still be
  displayed.
- No prominent goal, score, or judgmental empty-state language.

### 7.2 Metric grid

Use a two-column grid with six compact cards:

1. **Papers read** — distinct tracked papers still present in the library that
   met the 60-second threshold.
2. **Total reading time** — estimated cumulative time on qualified paper-days.
3. **Papers this week** — distinct papers meeting the threshold in the current
   locale-defined week.
4. **Time this week** — estimated active time on those qualified paper-days.
5. **AI sessions** — fresh Rubien Assistant conversations that successfully
   started since this feature or the last clear.
6. **Streak** — current consecutive reading days as the primary value, with the
   longest tracked streak since tracking/reset as a labeled secondary value.

The approved label is **Papers read**, not **Papers completed** or a bare
**Total**. Its help text says “Distinct papers kept active in Rubien's PDF or web
reader for at least 60 seconds; this is an engagement threshold, not proof of
completion. Deleted papers and activity before Rubien began tracking are not
included.” The AI card carries a short effective-period label: **Since tracking
began** before a clear, or **Since <localized reset date>** afterward. The streak
card uses its secondary line for **Longest <duration>**.

Time cards visibly say **Estimated** and format the largest useful units, such as
`10h 55m`; their help text defines active foreground time and gives the complete
hours/minutes value. A paper-day below 60 seconds contributes neither a paper nor
time to dashboard totals. Once it qualifies, all of its accumulated seconds,
including the first 60, contribute.

### 7.3 Calendar heatmap

- A compact segmented control offers **Month**, **Quarter**, and **Year**.
  **Quarter** is the default for a new installation and means the calendar
  quarter containing the anchor date (Q1–Q4). The exact inclusive date range,
  such as **Apr 1 – Jun 30, 2026**, is always visible beside the navigation.
- Month is the calendar month containing the anchor date. Year is the Gregorian
  calendar year containing it. Previous/next navigation shifts by one calendar
  month, three calendar months, or one calendar year respectively. Forward
  navigation stops at the window containing today, and future cells in that
  current window are visually unavailable rather than presented as zero-reading
  days.
- Switching granularity preserves the anchor date. The selected granularity is
  persisted with observable SwiftUI state and defaults to Quarter; the viewed
  anchor is per main window, starts at today, and is not persisted in v1.
- Columns are weeks and rows are locale-aware weekdays. A month label appears
  above the first week column that starts within that month, avoiding a label
  over a leading cell from the prior month.
- The complete grid is centered in the Activity card whenever it fits. Month,
  Quarter, and Year all use the same 12-point rounded squares, spacing, and hover
  behavior; wider ranges scroll horizontally rather than changing cell scale.
- Each cell represents **estimated active reading time** for that local date:
  sum the active seconds across all paper-days that individually meet the
  60-second threshold. Several sessions for the same paper accumulate time, but
  sub-threshold paper-days remain excluded exactly as they are from the time
  cards.
- Each paper-day at 0–59 seconds is excluded before the daily sum; a day with no
  qualified paper-day renders in the empty state. Five fixed active levels use
  the summed qualified time with start-inclusive, end-exclusive boundaries:
  **Level 1** = 60–899 seconds
  (1–<15 minutes), **Level 2** = 900–1,799 seconds (15–<30 minutes), **Level
  3** = 1,800–3,599 seconds (30–<60 minutes), **Level 4** = 3,600–7,199
  seconds (60–<120 minutes), and **Level 5** = at least 7,200 seconds (2 hours
  or more). Exactly 15, 30, 60, or 120 minutes therefore enters the next level.
  Fixed bands keep days and ranges comparable; they do not rescale to the
  user's busiest period.
- Color is derived from the current accent color at increasing contrast, not a
  hard-coded purple. Empty cells retain a visible border in high-contrast mode.
- Hover/help text reports the full date, exact distinct-paper count, and
  qualified estimated active time, with correct singular/plural wording. The
  legend labels the fixed duration bands rather than relying on an unexplained
  Less/More scale.
- Hovering an available day gently expands the square and adds a restrained
  accent glow while an immediate centered readout shows that date's estimated
  reading time and paper count. The native help tooltip carries the same detail;
  Reduce Motion disables the expansion animation.
- Timing buckets split at local midnight; a continuously active reader starts
  accruing into the next day's component without requiring a reopen.
- Selecting a non-empty cell may filter the recent list to that date in a later
  iteration; it is not required for v1.

Do not place 365 cells individually in the normal Tab order. VoiceOver exposes
an accessible summary and a chronological list of reading days.

### 7.4 Recent papers

Show up to five distinct papers whose latest qualifying reading activity occurred
within the rolling 24 hours ending at the snapshot time. This is independent of
the selected Month/Quarter/Year window and ordered by the maximum `lastActiveAt`
descending. Do not fall back to the incompatible open-based
`Reference.lastReadAt`. Each item reuses the clickable paper-card language with
canonical title, a single-line brief author list (first two authors plus **et
al.** when needed), and right-aligned `year · PDF/Web/Library` metadata on the
same compact second line; the full author list is available on hover. Cards are
transparent at rest and use only a neutral-gray hover fill and border treatment.
Descending card order conveys recency, so no timestamp is shown. Activating the
whole card opens its available PDF/web reader; if neither is available on this
device, it reveals the reference in Library.

An empty state says: **Keep a paper active in Rubien's reader for at least one
minute to begin recording activity.** Importing or briefly opening a paper does
not count.

## 8. Metric contract

| Metric | Normative definition |
|---|---|
| Qualifying foreground time | Elapsed time while the paper's PDF/web reader is key and visible, the app is active, and the Mac is awake. Losing key status, minimizing/closing the window, app deactivation, or sleep pauses accrual. CLI, MCP, metadata previews, Quick Look, and Assistant tool reads accrue zero. |
| Activity component | One installation's monotonic cumulative active seconds for a paper and captured local date. |
| Qualified paper-day | A paper whose current-generation activity components sum to at least 60 seconds for a local date. All of its seconds, including the first 60, contribute to that day's estimated heatmap time. |
| Legacy reader open | The shipped `lastReadAt`/`readCount` mutation remains open-based for compatibility and is not reinterpreted or used by Home statistics. |
| Papers read | Count of distinct existing references with at least one qualified current-generation paper-day. Deleted papers and pre-feature opens are absent; this is tracked history, not a complete lifetime claim. |
| Estimated active reading time | Sum of component seconds only for qualified paper-days. Sub-threshold paper-days are stored for continuity but excluded from displayed time. |
| Papers this week | Distinct qualified references from `weekStartDay` through `todayDay`; future local-day components do not count. |
| Time this week | Estimated active seconds belonging to those qualified paper-days in the same week interval. |
| Heatmap value | Sum of estimated active seconds across qualified paper-days for the selected `localDay`. Each 0–59-second paper-day is excluded first; a day with no qualified paper-day is empty. Active Levels 1–5 are `60–899`, `900–1,799`, `1,800–3,599`, `3,600–7,199`, and `7,200+` seconds. |
| Reading day | A local date with at least one qualified paper-day. |
| Current streak | If today is a reading day, the number of consecutive reading days ending today. Otherwise, if yesterday is a reading day, the number ending yesterday; otherwise `0`. A streak therefore does not break merely because the current local day is still in progress. |
| Longest streak | Maximum consecutive reading-day run in recorded daily history. Ties do not need special presentation. |
| AI session | A fresh conversation initiated in Rubien Home or a Rubien reader Assistant whose first admitted turn produces `.sessionStarted`. Empty conversations, unrelated provider-workspace conversations, retries before provider start, additional turns, rotating resume IDs, and History resumes do not increment it. |

The coordinator uses a monotonic active-duration clock and an in-memory
accumulator keyed by
`(epochRevision, generation, installationId, referenceId, localDay)`, initialized
from the stored component. It also carries the optional stable pending-clear
`intentId` associated with that epoch. While time accrues, it flushes the new cumulative total
after each 60 seconds of additional active time and when the local counter first
crosses 60 seconds. It also flushes immediately on pause, minimization, close,
app deactivation, sleep, local-midnight rollover, and best-effort app
termination; a time-zone/calendar change flushes the old bucket before deriving
a new local-day key. This preserves sub-threshold progress across focus changes
and relaunches. A crash can lose less than one minute accrued since the last
successful flush.

Each installation uses a random persisted UUID, not a hardware identifier.
Within one component, local async writes and CloudKit conflicts merge with
`max(activeSeconds)` and `max(lastActiveAt)`; across installation components,
queries sum seconds. This grow-only-counter shape prevents concurrent device
writes from losing time. Simultaneous foreground reading of the same paper on
two devices will be double-counted, so every duration is labeled **Estimated**.
Rubien stores daily cumulative counters, not the underlying start/stop intervals,
and therefore cannot reconstruct a gaze timeline or de-overlap devices exactly.

Day keys use a Gregorian calendar configured with the user's current locale and
time zone. Week queries use that calendar's locale-derived first-weekday and
minimum-days rules. Each stored `localDay` is the ISO `yyyy-MM-dd` date captured
at occurrence; stored past dates never shift after travel or after the user
changes calendar preferences.

The selected heatmap window bounds only `dailyActivity`. Tracked papers/time,
current/longest streaks, and recent papers are separate aggregates over all
retained history in the current generation, so a streak can cross January 1, the
longest streak can live in an earlier unselected range, and recent papers are not
year-bounded. Future-dated components are excluded from current-week and
current-streak calculations; they do not make a future streak look active.

## 9. Data model

### 9.1 Per-installation daily activity counters

Prefer mergeable daily counters rather than a raw focus-event stream:

```text
readingActivity
  installationId  TEXT     NOT NULL  // random per-installation UUID
  referenceId      INTEGER  NOT NULL  FK reference ON DELETE CASCADE
  localDay         TEXT     NOT NULL  // strict Gregorian YYYY-MM-DD at occurrence
  epochRevision    INTEGER  NOT NULL
  generation       TEXT     NOT NULL  // current opaque reading generation token
  activeSeconds    INTEGER  NOT NULL  CHECK activeSeconds >= 0
  lastActiveAt     DATETIME NOT NULL
  dateModified     DATETIME NOT NULL
  PRIMARY KEY (generation, installationId, referenceId, localDay)
```

`ReaderWindowManager` supplies reader lifecycle/key-window events to a shared
`ReadingActivityCoordinator`. The coordinator also observes app activation,
window visibility/minimization, sleep/wake, local-midnight boundaries, and
time-zone/calendar changes. It captures the occurrence day before asynchronously
flushing at the approved one-minute cadence, first local threshold crossing,
and every pause/close boundary. An upsert creates the component or advances
`activeSeconds = max(existing, incoming)` and
`lastActiveAt = max(existing, incoming)`, then stamps `dateModified` in Swift.
This makes delayed local writes and same-component CloudKit conflicts monotonic.
The one-minute cadence is a local SQLite durability cadence; it only marks the
component dirty. It must not force `CKSyncEngine.sendChanges()` every minute—the
existing sync scheduler coalesces counter updates.

The existing fresh-open path may continue updating legacy
`lastReadAt`/`readCount` for compatibility, but those fields do not participate
in Home metrics. The activity coordinator is the only producer of
`readingActivity`.

The composite primary key is the deduplication rule. Its sync `entityId` is
`<generation>/<installationId>/<referenceId>/<localDay>` and the actual CKRecord
name is therefore
`readingActivity:<generation>/<installationId>/<referenceId>/<localDay>`.
Generation and installation tokens must not contain `/`. Including generation
prevents an old-generation delete already ingested by `CKSyncEngine` from racing
a same-day post-clear save; including installation isolates concurrent grow-only
counters. Dirty-trigger SQL emits the unqualified entity ID exactly. The payload
carries every column, including estimated seconds and timestamps.

This table can answer estimated daily active time but intentionally cannot
reconstruct minute-by-minute behavior, individual sessions, scroll activity, or
whether the user was looking at the screen.

Generate `installationId` once in device-local app preferences (using the App
Group preference domain for the signed app), never from hardware identifiers and
never from synced/library SQLite state. Copy the UUID into each component. If the
preference is lost, a new component is safe—the aggregate may split across two
installation IDs, but monotonic time is not overwritten.

### 9.2 Assistant session metadata

```text
assistantActivity
  id           TEXT     PRIMARY KEY  // Rubien-generated conversation UUID
  provider     TEXT     NOT NULL     // claude | codex, unknown-safe decode
  epochRevision INTEGER NOT NULL
  generation   TEXT     NOT NULL     // current opaque Assistant generation token
  startedAt    DATETIME NOT NULL
  localDay     TEXT     NOT NULL
  dateModified DATETIME NOT NULL
```

`ChatSessionController` generates a stable Rubien conversation UUID. An injected
`ActivityRecording` service exposes an asynchronous, idempotent
`recordAssistantStart(...)` operation; the `@MainActor` event handler schedules
that operation after the first `.sessionStarted` without synchronously touching
SQLite. The controller's once guard and the UUID primary key make repeated start
events harmless. It does not store the provider session ID because that ID can
rotate and is not the logical conversation identity. `resume(_:)` marks the
conversation as existing and never inserts a new row.

The scheduled insert carries the Assistant epoch pair and optional pending-clear
`intentId` observed when `.sessionStarted` was admitted. Its write transaction
compares both with current local state. An exact pair writes normally; a changed
pair with the same pending `intentId` writes under the rebased pair because the
conversation began after the same user clear. Any other mismatch means a distinct
clear superseded it, so the insert is dropped rather than counting a pre-clear
conversation inside the new generation. A pending-clear rebase after a successful
insert uses the fact-retagging rule in §9.3.

Only `ChatSessionController` instances created for Rubien Home or reader
Assistant surfaces receive this recorder. Provider-history discovery, other
Claude/Codex clients using the same workspace, and MCP clients outside Rubien
have no insertion path and never affect the total.

No reference ID, prompt, preview, transcript, model, attachment, tool call,
token count, or cost is stored. Deleting a reference therefore does not rewrite
the AI-session total.

### 9.3 Durable reset fence

Because activity follows the approved iCloud-library-sync setting, capture and
clearing require one small control table that syncs with the facts:

```text
activityEpoch
  kind         TEXT     PRIMARY KEY  // reading | assistant
  revision     INTEGER  NOT NULL     // monotonic Lamport-style revision
  generation   TEXT     NOT NULL     // deterministic initial token; UUID after clear
  resetAt      DATETIME NULL         // visible coverage/clear boundary
  dateModified DATETIME NOT NULL
```

The migration seeds revision `0` with versioned deterministic generations (for
example `reading-v7-initial` and `assistant-v7-initial`), so devices that upgrade
independently agree. Every fact carries both epoch fields, and queries count only
the current pair. Clearing a kind is one local transaction: increment the known
revision, generate a UUID generation plus a separate stable clear-intent UUID,
set `resetAt`, persist the typed local
`activityPendingClear` intent defined below, delete that kind's existing facts,
and commit the new epoch. An in-app clear also tells the coordinator to discard
matching reading accumulators; a cross-process clear is handled by the flush
guard below. The new reading generation gives same-day facts a new
per-installation CKRecord identity. The incompatible open-based
`lastReadAt`/`readCount` columns are not part of this ledger clear and remain
unchanged; Home statistics never use them before or after a reset.

Sync treats a clear as acknowledged only when CloudKit saves that exact
`(revision, generation)` pair. A fact from a new generation is not uploaded
until its epoch is acknowledged. If `.serverRecordChanged` or a fetch reveals a
newer/equal competing epoch while `activityPendingClear` exists, preserve the
user's intent: in one transaction, rebase it to
`max(localRevision, serverRevision) + 1` with a new UUID, keep the original reset
boundary and stable clear `intentId`, and re-key every fact in that kind's ledger
carrying the exact losing pending pair to the rebased pair. For reading rows this
changes the composite primary key and sync entity ID; the transaction removes
stale `syncState`/cached-system-field entries and never-uploaded tombstones for the
losing IDs, then marks the rebased IDs dirty. Assistant rows keep their UUID
record identities but update their generation fields and dirty bookkeeping
equivalently. The stable `activityEpoch:<kind>` sync-state entry adopts the
winning server record's current system fields before the rebased epoch is marked
dirty, so its retry mutates rather than recreates that CKRecord. This preserves
activity created after the user's clear: the losing pending generation was
save-gated and never acknowledged, so no peer can own a conflicting fact under that
UUID. Retry until the exact rebased epoch is acknowledged. Without a local
pending clear, the higher revision wins; an equal-revision tie is resolved
deterministically by generation so every peer converges.

Every reading accumulator is bound to the epoch pair and optional clear
`intentId` current when it begins. Each flush transaction reads `activityEpoch`
and `activityPendingClear` before writing. If the pair changed but the accumulator
and current pending row carry the same `intentId`, the transition is a rebase of
the same user clear: the flush retags the accumulator to the rebased pair and
preserves its post-clear cumulative seconds. For every other mismatch—including a
new `rubien-cli stats-clear` intent—the flush discards and reinitializes the stale
cumulative baseline; it must not stamp pre-clear seconds onto the new generation.
The CLI mutation also calls the existing cross-process library-change notifier,
and the coordinator observes `activityEpoch` changes to reset promptly, but this
transactional pair/intent comparison is the correctness boundary when
notification or observation races.

Within a fetched batch, epochs apply before facts. Across batches, a fact with a
higher revision or an equal revision/unknown generation is quarantined in the
typed local-only state below and triggers epoch reconciliation; it is never
deleted merely because opaque tokens differ. Only after the corresponding epoch
is known and its winning pair is server-acknowledged may a lower/losing-generation
fact be discarded and tombstoned. Activity recorded by an offline peer before it
learns a completed clear can consequently be discarded; the confirmation copy
states this cross-device boundary.

```text
activityPendingClear                 // local-only; one row per kind
  kind          TEXT PRIMARY KEY     // reading | assistant
  intentId      TEXT NOT NULL        // stable across retries/rebases
  revision      INTEGER NOT NULL
  generation    TEXT NOT NULL
  resetAt       DATETIME NOT NULL    // original user-visible boundary
  dateModified  DATETIME NOT NULL

activityQuarantine                   // local-only; facts awaiting reconciliation
  recordName    TEXT PRIMARY KEY
  entityType    TEXT NOT NULL        // readingActivity | assistantActivity
  reason        TEXT NOT NULL        // epoch | reference
  epochRevision INTEGER NOT NULL
  generation    TEXT NOT NULL
  recordData    BLOB NOT NULL        // bounded secure CKRecord envelope
  receivedAt    DATETIME NOT NULL
```

`recordData` contains only the already-bounded activity record and its CloudKit
system fields so the engine may advance its change token and replay the exact fact
after epoch or parent-reference reconciliation. Both tables are ordinary SQLite
state so pending intent, rebase, quarantine, and fact changes can commit
atomically. They have no
sync triggers, CKRecord mapping, `SyncEntityType`, or schema-invariant parity
requirement and do not use the `CKSyncEngine.State` sidecar. Tests cover
local-clear-versus-server-initial, concurrent clears, facts arriving before
epochs, relaunch with pending/quarantined state, same-day post-clear activity, and
stale offline facts. While iCloud library sync is off, the same revision semantics
remain local and no CloudKit acknowledgement/quarantine path runs until sync is
enabled.

### 9.4 Migration and history

Add a new immutable `v7` migration; do not edit v1, v4, or any other shipped
migration. The migration creates the three synced activity tables, the two
triggerless local-only control tables above, indexes, sync triggers only for the
three synced tables, and no historical activity rows. Two migration paths are
mandatory tests: a fresh empty library and a real v6 → v7 upgrade.

The v1 migration currently iterates `AppDatabase.syncedTables`; that list is part
of the shipped v1 behavior and must remain frozen. Do **not** append the v7 tables
to it, because a fresh migration would try to create triggers before the tables
exist. The v7 block emits its own insert/update/delete trigger sets, including
the composite
`generation || '/' || installationId || '/' || referenceId || '/' || localDay`
expression.
It explicitly upserts both seeded epoch rows into `syncState` after their
triggers exist: an upgraded v6 library's one-shot initial baseline is already
complete and will not discover new entity types. Update the current schema
version without changing a released migration body.

There is no honest daily or AI backfill:

- `readCount` has no dates.
- `lastReadAt` provides only the latest known day per paper.
- `pdfCache.lastOpenedAt` is not a production reader history source.
- Status is user-extensible and has no transition timestamp.
- Annotations miss every unannotated reading session.
- Provider-owned history is workspace/backend dependent and can be deleted.

The Activity coverage line therefore says that all reading metrics and Rubien
AI-session statistics begin with this feature on upgraded devices. No Home card,
heatmap cell, streak, or recent row is backfilled from incompatible open-based
fields. Values remain aggregates over papers still present in the library, not
claims of complete lifetime activity.

## 10. Query and observation API

Add a Core-level immutable snapshot, conceptually:

```swift
struct ReadingActivitySnapshot: Sendable, Equatable {
    var asOfLocalDay: LocalDay
    var dailyActivityStartDay: LocalDay
    var dailyActivityEndDay: LocalDay
    var papersReadTracked: Int
    var estimatedActiveSecondsTracked: Int64
    var papersReadThisWeek: Int
    var estimatedActiveSecondsThisWeek: Int64
    var assistantSessionsTracked: Int
    var currentStreakDays: Int
    var longestStreakDays: Int
    var dailyActivity: [DailyReadingActivity]
    var recentPapers: [RecentReading]
    var coverage: ActivityCoverage
}

struct DailyReadingActivity: Sendable, Equatable {
    var localDay: LocalDay
    var paperCount: Int
    var estimatedActiveSeconds: Int64
}

struct RecentReading: Sendable, Equatable {
    var referenceId: Int64
    var title: String
    var byline: String?
    var venue: String?
    var lastActiveAt: Date
}

struct ActivityCoverage: Sendable, Equatable {
    var trackingIntroducedInVersion: String
    var readingResetAt: Date?
    var assistantResetAt: Date?
}
```

`AppDatabase` first groups current-generation components by paper/day, sums
`activeSeconds`, and applies `HAVING SUM(activeSeconds) >= 60`. It exposes a
bounded daily activity fetch for an inclusive `LocalDay` range plus an
observation that
re-emits when `reference`, `readingActivity`, `assistantActivity`, or
`activityEpoch` changes. Current/longest streaks are computed separately over
all distinct qualified days using bounded SQL aggregation/window functions;
they are not accidentally limited to the visible range. The CLI and MCP year
query call this same API with that calendar year's first and last day.
Statistics must never
depend on `LibraryViewModel.references`, because that array is scoped and
filtered by the active Library view.

The three `*Tracked` totals and longest streak cover their corresponding current
generations since tracking began or the most recent reset; they are not literal
lifetime claims. `recentPapers` is likewise independent of the selected heatmap
range: it returns the five most recent qualified, still-existing papers across the
current reading generation. `asOfLocalDay` freezes the current-week and
current-streak boundary so UI, CLI, MCP, and tests describe the same local day.

Indexes cover `readingActivity(generation, localDay, referenceId)`,
`readingActivity(generation, lastActiveAt)`, and
`assistantActivity(generation, startedAt)`. Aggregate in SQLite; do not load an
unbounded event history or all references onto the main actor. Coalesce sync
bursts before publishing to SwiftUI, following the existing
reference-observation pattern.

The paper-day components are already compact daily aggregates rather than raw
focus events. v1 intentionally retains them at daily resolution for as long as
the current generation remains active because historical Year views and longest
streak require that history. At five paper-days per day this is approximately
1,825 reading rows per installation-year, plus one row per counted Rubien
conversation; multiple installations scale linearly. Core query tests and sync
initial-pull tests include representative 10,000–50,000-row libraries. No
automatic age-based compaction ships in v1; a future aggregate tier requires a
separate migration and must preserve every published metric exactly.

## 11. Sync, CLI, and MCP contracts

### 11.1 CloudKit

Under approved D2, all three activity entities sync when iCloud library sync is
enabled. The `activityPendingClear` and `activityQuarantine` coordination tables
always remain local-only. When sync is off, the activity entities also remain
local. Add:

- `SyncEntityType.readingActivity`, `.assistantActivity`, and `.activityEpoch`.
- The full `populate(record:)`, `makeRecord(...)`, and `init(record:)` mapping
  for each model, with every SQLite column represented on the CKRecord.
- Explicit identities: reading-component `entityId` is
  `<generation>/<installationId>/<referenceId>/<localDay>` and record name is
  `readingActivity:<generation>/<installationId>/<referenceId>/<localDay>`;
  Assistant record name is `assistantActivity:<uuid>`; epoch record name is
  `activityEpoch:<reading|assistant>`.
- Initial-baseline special cases: `readingActivity` selects
  `generation || '/' || installationId || '/' || referenceId || '/' || localDay`,
  `assistantActivity` selects `id`, and `activityEpoch` selects `kind`. The v7
  migration explicitly dirties seeded epochs for already-baselined libraries.
  Composite/UUID/kind dispatch may not fall through existing
  `Int64(entityId)` paths.
- Apply/build/delete dispatch, reference-before-reading-activity and
  epoch-before-component ordering, unknown-generation quarantine, epoch-save
  gating, `max` merge for one installation's counters, the pending-clear retry
  state machine, dirty tracking, tombstones, record cache, and schema-invariant
  coverage. `referenceId` remains a plain CKRecord numeric value, never a
  `CKRecord.Reference`.
- Parent-reference reconciliation for reading facts is explicit across fetched
  batches. A fact whose reference is absent and not tombstoned enters
  `activityQuarantine` with reason `reference` until the parent arrives. A fact
  for a known tombstoned reference is consumed without insertion and its server
  record is queued for deletion. At the end of a completed zone-fetch cycle
  (`moreComing == false`), a still-parentless fact is classified as a permanent
  orphan and handled the same way. Applying a reference deletion also removes and
  tombstones any already-staged or quarantined reading children even when the
  parent row is absent, so both child→delete and delete→child ordering converge
  without wedging a mixed batch.
- Forward-compatible provider decoding; an unknown provider is preserved or
  displayed as **Other**, never allowed to crash an older peer.

Rows contain cumulative activity metadata only and live in the user's private
CloudKit library. Rubien sends nothing to a product analytics endpoint.

### 11.2 CLI parity

The repository's data-layer lockstep rule requires a CLI surface. Add a
read-only command such as:

```text
rubien-cli stats [--year <yyyy>]
```

Omitting `--year` selects the current Gregorian year in the machine's current
time zone. Accept decimal years `1970...9999`; any other value is an argument
error and produces no partial success JSON.

The JSON contract is a dedicated, scope-explicit DTO, not a serialized
`Reference` or Swift dictionary. Dates with no qualified paper-day are omitted
from the daily array, even if they contain stored sub-threshold seconds; included
entries are ordered chronologically. Nullable display strings remain explicit
`null`. Durations are integer seconds so clients can format them without parsing
localized strings. The shape below is normative (values, locale-derived week
start, and `<shipping-version>` are illustrative):

```json
{
  "asOfLocalDay": "2026-07-15",
  "trackedTotals": {
    "papersRead": 127,
    "estimatedActiveSeconds": 39300,
    "assistantSessions": 19
  },
  "currentWeek": {
    "startDay": "2026-07-13",
    "throughDay": "2026-07-15",
    "papersRead": 3,
    "estimatedActiveSeconds": 1980
  },
  "streaks": {
    "currentDays": 4,
    "longestDays": 12
  },
  "yearActivity": {
    "year": 2026,
    "dailyActivity": [
      { "localDay": "2026-07-14", "paperCount": 2, "estimatedActiveSeconds": 1500 },
      { "localDay": "2026-07-15", "paperCount": 1, "estimatedActiveSeconds": 480 }
    ]
  },
  "recentPapers": [
    {
      "referenceId": 42,
      "title": "Example paper",
      "byline": "A. Author et al.",
      "venue": null,
      "lastActiveAt": "2026-07-15T18:42:00Z"
    }
  ],
  "coverage": {
    "trackingIntroducedInVersion": "<shipping-version>",
    "readingResetAt": null,
    "assistantResetAt": null
  }
}
```

`trackedTotals` and `streaks.longestDays` cover the applicable current generation
since tracking or reset, not the selected year or a complete lifetime.
`currentWeek` and `streaks.currentDays` are evaluated on `asOfLocalDay`;
`yearActivity` is the only object selected by `--year`. `recentPapers` is not
year-bounded and contains the five most recent qualified papers across the
current reading generation. The two reset values are nullable ISO-8601 instants;
Reading and Assistant clears update only their corresponding coverage boundary.

The command help and CLI reference carry the same no-backfill and mixed-version
disclosure as the UI. The Settings mutations require lockstep CLI commands:
`rubien-cli stats-clear --kind reading --yes` and
`rubien-cli stats-clear --kind assistant --yes`, returning
`{"cleared":"reading"}` or `{"cleared":"assistant"}`. Update
`RubienCLITests` and `Docs/CLI-Reference.md` in the same implementation phase.
Both commands call the same transactional clear primitive as Settings, emit the
existing cross-process library-change notification after commit, and return
without waiting for CloudKit. Epoch acknowledgement and old-fact tombstone
drainage are asynchronous. A running app's next reading flush still performs the
authoritative epoch comparison in §9.3 and discards rather than re-stamps a stale
accumulator.

### 11.3 Agent access

Add a read-only `rubien_reading_activity` MCP tool backed by the same Core/CLI
query. This makes **Summarize what we’ve been reading this week** truthful instead
of asking the model to infer activity from reference metadata. The tool is
called on demand; no activity snapshot is silently inserted into every Home
prompt. When invoked inside an Assistant turn, its returned summary is sent to
the configured Claude/Codex provider like any other tool result; the UI/help
must disclose that boundary.

Its exact input schema is:

```json
{
  "type": "object",
  "properties": {
    "year": { "type": "integer", "minimum": 1970, "maximum": 9999 }
  },
  "additionalProperties": false
}
```

Omitted `year` uses the same current-local-Gregorian-year default as the CLI.
Invalid input returns the standard MCP invalid-arguments error, and successful
content is exactly the normative CLI DTO rather than a provider-specific
summary.

Register it as `.read` in `RubienMCPToolPolicy`. Keep both MCP implementations
drop-in compatible: update the native Swift catalog/handler and the Node
TypeScript schema/registration/handler, catalog and policy/parity tests, server
README/tool counts, `MIN_CLI_BUILD`, and package/server versioning together.

### 11.4 App-private structured document-card presentation

`rubien_present_document_cards` is an MCP tool on the provider wire, but it is a private
Rubien-app presentation capability rather than a general library API. It has no
standalone `rubien-cli` command and is not registered by the public Node MCP
package or a normal `rubien-cli mcp` launch. It lets an agent running inside
Rubien explicitly identify every openable saved or external web document it
intentionally references without encoding actions in prose. The input is:

```json
{
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "minItems": 1,
      "maxItems": 10,
      "items": {
        "oneOf": [
          {
            "type": "object",
            "properties": {
              "referenceId": { "type": "integer" }
            },
            "required": ["referenceId"],
            "additionalProperties": false
          },
          {
            "type": "object",
            "properties": {
              "url": { "type": "string", "maxLength": 2048 },
              "title": { "type": "string", "minLength": 1, "maxLength": 500 },
              "authors": { "type": "string", "minLength": 1, "maxLength": 1000 },
              "year": { "type": "integer", "minimum": 1, "maximum": 9999 }
            },
            "required": ["url", "title"],
            "additionalProperties": false
          }
        ]
      }
    }
  },
  "required": ["items"],
  "additionalProperties": false
}
```

Rubien owns and localizes the fixed **Document cards** heading; the agent cannot
override it. Preserve input order and stable-deduplicate repeated library IDs and
web-card deduplication keys. A web card retains its validated original URL as its
activation URL; its separate deduplication key lowercases scheme and host,
removes only that scheme's default port, and normalizes an empty path to `/`.
Preserve HTTP versus HTTPS, `www`, path case, non-root trailing slashes,
percent-encoded path/query content, query parameters, query order, and fragments;
an arbitrary HTTP(S) candidate may use its fragment as routing identity. The
first occurrence wins. Do not reuse the publisher-specific
`PaperURLResolver.canonicalize`, which intentionally performs stronger rewrites.
For a library item, the server requires an existing
reference and returns canonical current title, compact authors, nullable year, and per-device
reader availability from which Rubien derives the badge. It never exposes a
local PDF path. For an external item, require an absolute host-bearing HTTP(S)
URL, title, and optional authors/year. Rubien—not the agent—derives its badge
through the shared Add Reference router: **Paper candidate** for
metadata-resolvable paper URLs, **PDF candidate** or **Document candidate** for
supported file URLs, and **Web candidate** for ordinary pages. Presentation does
not fetch the URL or claim the supplied metadata was verified.

Host the tool in a separate optional native catalog, conceptually
`MCPAppPresentationToolCatalog`, so `MCPToolCatalog.allTools`, its exact public
policy invariant, the Node tool list, and CLI documentation remain unchanged.
When Rubien constructs its private `MCPContentChannel`, it adds
`RUBIEN_APP_PRESENTATION=1` beside `RUBIEN_LIBRARY_ROOT`; only that server mode
appends the optional catalog. The environment switch is a capability-selection
contract, not a security boundary—the tool is read-only even if another caller
sets it. `ChatSessionController` recognizes its exact name through a separate
app-presentation read policy instead of weakening the unknown-tool denial rule.

The tool introduces no database entity, standalone CLI JSON contract, CloudKit
mapping, Node implementation, public MCP tool count, or `MIN_CLI_BUILD` change.
Mark it as non-attributing in `ReferenceAttribution`: presenting related papers
must not reclassify the conversation's original Home/reader context. Tests must
prove that normal native/Node catalogs remain unchanged and that the app-enabled
native server adds exactly this one capability with the schema above.

Provider adapters currently discard tool-result bodies after completion. Extend
their portable event contract only for this exact tool (or with a bounded typed
result envelope), cap accepted presentation JSON at 64 KiB, and decode it into
Foundation-only `ChatPaperGroup`/`ChatPaper` types. At tool-call start, capture the
provider call ID plus a zero-based invocation ordinal within the current turn;
the successful terminal event carries both, and repeated terminal/history events
for an already-consumed call ID are ignored. Merge successful calls by invocation
ordinal and then item index, never by completion order. History reconstruction
derives the same ordinal from transcript tool-call order. The first ten unique
items across the turn render; later unique items are deterministically omitted,
and the context seed's one-call instruction prevents this defensive cap from
becoming normal behavior. Do not expose arbitrary MCP result HTML to the
renderer. Claude live streams, Codex app-server events, and both History decoders
must produce the same structured group and ordering.

## 12. Privacy and deletion

- The new ledger records a random installation UUID, paper ID, occurrence-local
  day, monotonic cumulative active seconds, last-active/sync timestamps,
  revision/generation, or Rubien Assistant provider/start metadata. It records
  no hardware identifier, start/stop interval timeline, scroll events, gaze, or
  document content.
- Provider transcripts remain in Claude/Codex-owned stores. Clearing Rubien
  activity must never claim to delete those transcripts.
- Settings ships with capture, not as a later privacy patch. It has two
  device-local, default-on controls: **Record reading activity on this Mac** and
  **Record AI session statistics on this Mac**. Disabling reading capture gates
  the activity coordinator, counter writes, and the existing
  `lastReadAt`/`readCount` mutation;
  disabling AI capture gates new `assistantActivity` rows. The content-free,
  local History-attribution index remains active as functional History metadata,
  and the setting copy says so. Existing synced data remains visible. Implement
  the controls with observable SwiftUI state
  (`@AppStorage` or the repository's `@State` mirror/write-through pattern), not
  a non-invalidating direct binding to `RubienPreferences`.
- Deleting a paper cascades its materialized `readingActivity` component set,
  removes any quarantined reading fact for that reference, and produces the
  corresponding synced tombstones.
- **Clear Reading Activity…** rotates the reading epoch, persists the pending
  clear, and deletes reading-day ledger rows in one SQLite transaction. The
  in-app coordinator then discards matching accumulators; a running app after a
  CLI clear is protected by the transactional pair/intent guard in §9.3. The
  panel becomes empty immediately; when iCloud sync is enabled, the queued
  CloudKit record deletions drain in bounded batches and the pending clear
  remains until the exact epoch is acknowledged. The confirmation explains that
  older offline activity may be discarded on reconnect and that the legacy
  open-based **Last Read** and **Read Count** Library columns are separate
  compatibility metadata and remain unchanged. Resetting those unfenced fields
  would dirty and repush every full Reference record without making the new
  ledger clear more durable.
- **Clear Assistant Activity…** rotates the Assistant epoch and deletes only
  `assistantActivity` statistics rows. It preserves the local, content-free
  History-attribution index, because that index is functional navigation metadata
  rather than a statistic. Its confirmation says provider History/transcripts
  and Rubien's Home/reader classification are unaffected. Applying a newer
  Assistant epoch never clears attribution on a peer. If Rubien later needs a
  privacy action for that index, it is a separate per-device **Forget Assistant
  History Classification…** operation with an explicit navigation consequence,
  not part of the synced statistics epoch.
- Both clear actions, the reset fence, confirmations, and equivalent CLI
  mutations ship in the same data-foundation phase as capture. When iCloud
  library sync is enabled, the clear applies to the private synced library;
  activity from a device that was offline before learning the reset can be
  discarded when it reconnects.
- No activity is automatically sent to Claude/Codex. If the user asks the agent
  a question that invokes `rubien_reading_activity`, the returned activity DTO
  becomes provider input for that turn, exactly as disclosed in MCP help.

## 13. States, responsiveness, and accessibility

### States

- **Loading:** preserve panel geometry with placeholders; show a spinner only if
  the local query is not immediate.
- **No library:** zero metrics, empty heatmap, add/import actions, usable chat.
- **Library but no qualified reading:** reading cards are zero; the Rubien AI
  card may be nonzero. The heatmap explains the 60-second threshold and that
  tracking starts with this feature.
- **Assistant unavailable:** existing provider-specific setup card and Recheck;
  statistics continue to work.
- **Statistics failure:** retain the last snapshot if available, show a compact
  warning and Retry; unknown values display `—`, never a misleading zero.
- **Offline:** local statistics and local library tools remain available; the
  agent explains web/provider limitations through existing error paths.

### Accessibility

- Each metric card exposes one combined VoiceOver label with name, value,
  period, and short definition.
- Heatmap color is never the only signal: the Month/Quarter/Year control, exact
  range title, fixed duration legend, per-day paper/time help text,
  contrast-aware borders, and an accessible reading-day list are all exposed.
- Each paper recommendation is one keyboard-focusable action with a combined
  VoiceOver label covering title, authors, year, badge, and the result of
  activation. External candidates expose **Open source** and **Add to
  Rubien…** as distinct actions.
- Respect Increase Contrast, Differentiate Without Color, Reduce Motion, and
  large accessibility text sizes.
- The floating Activity card retains a visible boundary and sufficient text/cell
  contrast over both light and dark Home backgrounds; its internal scroll area
  exposes normal keyboard and VoiceOver scrolling when height-constrained.
- In a fresh conversation the quick suggestions precede the composer in visual,
  keyboard, and VoiceOver order; long labels wrap within the vertical list
  without changing that order.
- Streamed Assistant answers should not announce every token; reuse or add a
  throttled completion announcement.
- Home, Activity toggle, range control/navigation, recent rows, History, provider
  controls, suggestions, approvals, and composer are keyboard reachable.

## 14. Implementation shape and phases

Implementation starts only after this draft is approved.

### Phase A — Data foundation

Phase A is one user-visible delivery but is implemented as four coherent,
buildable checkpoints. Capture remains unexposed until A1–A4, the privacy
controls, and both clear paths are complete.

#### A1 — Schema, static sync surface, and queries

- v7 models and immutable migration for the three synced entities plus
  `activityPendingClear`/`activityQuarantine`, explicit triggers, indexes, fresh
  and v6-upgrade coverage, and schema invariants.
- Record mappings/identities and baseline enumeration sufficient to keep the new
  schema in Core/CLI/CloudKit lockstep.
- Core qualified-activity queries, calendar/streak logic, observation snapshots,
  and 10,000–50,000-row scale fixtures.

#### A2 — Epoch-aware local capture and clears

- Per-installation active-time coordinator with epoch-bound one-minute and
  lifecycle flushes, including transactional mismatch discard after an in-app or
  CLI clear.
- Asynchronous/idempotent Rubien Assistant-session capture with its
  expected-epoch check.
- Device-local capture preferences and shared transactional Reading/Assistant
  clear primitives, with immediate UI invalidation and legacy/attribution scope
  fixed as §12 defines.

#### A3 — Reset and sync state machines

- Exact-epoch acknowledgement gating, durable pending-clear retry, rebase that
  preserves both ledgers and rewrites reading sync identities, and bounded
  old-fact deletion drainage.
- Durable unknown-epoch/missing-reference quarantine, permanent-orphan cleanup,
  apply/delete dispatch, tombstones, record cache, and multi-batch initial-pull
  coverage.

#### A4 — CLI, MCP, Settings, and documentation

- CLI `stats`/`stats-clear`, both `rubien_reading_activity` MCP implementations,
  scope-explicit DTOs, policy/version updates, Settings controls/confirmations,
  docs, and contract/parity tests.

### Phase B — Assistant context refactor

- `AssistantConversationContext` and context-specific seeds.
- Shared production session factory with reader convenience wrapper.
- Parameterized chat copy, suggestions, mention exclusion, and History scope.
- Home session owner that survives destination switches.
- App-private `rubien_present_document_cards` native capability, bounded provider-event
  decoding, structured render-log/History reconstruction, and optional-catalog/
  security tests.

### Phase C — Main-window Home

- Home sidebar row and the approved v1 Home-default launch behavior; no
  launch-destination preference ships in v1.
- Mode-aware center content and toolbar.
- Centered fresh-conversation composer, subordinate suggestions, and the
  content-start transition to a bottom-docked composer.
- Native document-card groups, validated open/add bridges, and shared reader-opening
  policy.
- Top-pinned, content-hugging glass Activity card, responsive height/width,
  metrics, Month/Quarter/Year heatmap, recent rows, and empty/error states.
- Light/dark, compact-width, keyboard, VoiceOver, and Reduce Motion QA.

Each phase should build and pass targeted tests independently. No prior migration
is modified, and every new app-target SwiftUI file is wrapped in
`#if os(macOS)` for Linux CI.

## 15. Approved decisions record

### D1 — 60-second threshold plus estimated active time *(approved 2026-07-15)*

Rubien persists per-installation cumulative active seconds every additional
minute and on pause/close, then sums components across devices. A paper-day
qualifies at 60 seconds; total and weekly time sum only qualified paper-days.
The estimate deliberately treats foreground-reader time as a proxy and can
double-count simultaneous use on two devices, but the grow-only component model
does not lose concurrent increments. Because existing open-based
`lastReadAt`/`readCount` values cannot supply seconds, all Home reading metrics
start with the feature and receive no legacy backfill.

Status = `Read` remains unsuitable as a canonical signal because Status values
are user-extensible, renameable, and have no change timestamps.

### D2 — Follow iCloud library sync *(approved 2026-07-15)*

The minimal facts and reset epochs sync through the user's existing private
CloudKit library when iCloud library sync is enabled. With sync off, activity is
recorded and shown locally; enabling sync later reconciles it through the same
epoch protocol. No separate product analytics service is introduced.

### D3 — Count Rubien conversations only *(approved 2026-07-15)*

The AI total counts only fresh conversations initiated in Rubien Home or a
Rubien reader Assistant. Each fact stores the Rubien UUID, provider, start date,
and reset revision/generation only. Provider histories remain available for
History navigation but do not contribute statistics; unrelated Claude/Codex
conversations in the same workspace never count.

### D4 — Month, calendar-quarter, and year heatmap *(revised 2026-07-16)*

The heatmap uses a compact Month/Quarter/Year segmented control with Quarter as
the default. Quarter is the calendar Q1–Q4 window containing the anchor date.
The selection persists, navigation preserves an anchor date, and the UI always
shows the exact date range. Intensity is the fixed daily amount
of estimated active time across qualified paper-days. Each paper-day below one
minute is unqualified; Levels 1–5 are `1–<15m`, `15–<30m`, `30–<60m`, `1–<2h`, and
`2h+`. It never rescales by range or reading history. The exact time and
distinct-paper count remain available in hover and accessibility detail. Every
calendar day is drawn as an equal-width, equal-height square with subtle
continuous rounded corners; the legend uses the same rounded-square language.

### D5 — Centered-composer empty Home *(revised 2026-07-16)*

A fresh Home conversation centers the composer horizontally and places it
slightly above the vertical midpoint of the chat canvas. The three initial
suggestions sit directly above it with lower visual emphasis: **What should I
read next?**, **Find recent papers in my field**, and **Summarize what I’ve
been reading this week**. Their text aligns with the composer editor's caret
origin rather than with the outer card edge and uses the system secondary-text
tone so the composer remains the visual focus. No hero content precedes the input. When the first
valid send commits the user message, the composer immediately moves to the
familiar bottom edge and the suggestions disappear, without waiting for
provider output. Populated History starts there as well; a new empty conversation
restores the initial layout.

Conversation and editor content use the transcript's 14-point base size.
Secondary interface text—empty-state guidance, shortcut hints, Agent/provider/
model/effort controls, Home suggestions, and **New**/**History**—uses one shared
13-point size. The fresh and bottom-docked composers share the same 700-point
maximum width and intrinsic-height footprint. Reader Assistant composers use
that same compact height, while the reader Assistant panel has a 420-point
minimum width so the single-line control row does not crowd or force an
unreported expansion.

### D6 — Clickable native document references *(approved 2026-07-15)*

When the agent intentionally points the user to specific openable documents, it
uses a bounded app-private, read-only presentation capability and Rubien renders
canonical native document cards after the explanation. Existing library documents
open the local PDF Reader when available,
then the Web Reader, then fall back to a Library reveal. Web-only candidates
open their validated source externally and expose an explicit **Add to Rubien…**
flow; they are never imported merely because the model mentioned them. Typed
render items and validated Swift bridges are required instead of custom Markdown
URL schemes, and provider History can reconstruct the same cards without Rubien
storing transcripts.

### D7 — Top-pinned content-height Activity card *(approved 2026-07-15)*

Reading Activity is not a full-height inspector. Its neutral Liquid Glass card
is aligned to the top-right and hugs the natural height of its metrics, heatmap,
and recent rows, leaving the Home canvas visible below. A transparent wide-mode
rail prevents chat overlap without painting an empty column. Only a genuinely
height-constrained window introduces internal card scrolling. The implementation
reuses Rubien's macOS 26 neutral glass treatment and macOS 14.4–15 visual-effect
fallback rather than making the feature availability-dependent.

### D8 — Reader sidebar parity and persistence *(revised 2026-07-16)*

As a shared-reader visual-QA refinement, the PDF and web readers' left utility
sidebars both default to 225 points when no saved choice exists. PDF remains
resizable across 200–400 points; web remains resizable across 225–400 points.
Each reader independently remembers its last width and visibility in device-local
preferences and restores them in a new reader window; an already-open
per-reference reader keeps its in-memory state. Both use an exact state-backed
resize handle so the displayed width and the persisted width cannot diverge. A
one-time preference migration discards the legacy web width that `HSplitView`
could derive from automatic layout rather than an actual user drag.

## 16. Acceptance criteria

- A new main window selects Home and shows library-scoped chat plus Activity.
- At wide sizes the Activity card is pinned to the top-trailing margin, preserves
  its 360–520-point resize range, and ends at its natural content height; no
  opaque/material surface or border continues to the window bottom. The
  transparent rail keeps chat unobscured. If vertical space is insufficient,
  the card keeps a bottom margin and scrolls internally. At compact width it is
  auto-collapsed and an explicit toolbar reveal overlays it above the composer.
- The card uses neutral Liquid Glass and shadow on macOS 26 plus the existing
  material fallback on macOS 14.4–15, with verified light/dark, Increase
  Contrast, keyboard-scroll, and VoiceOver behavior.
- Every interactive Agent Home control has visible hover feedback: neutral gray
  for ordinary buttons, tabs, suggestions, and document cards; the heatmap retains
  its restrained accent expansion/glow. Disabled controls remain visually inert.
- A fresh or newly reset Home conversation places the composer around 45% of
  the chat canvas height with suggestions immediately above and no competing
  hero. Drafting and attachments do not move it. The first valid Send/Return
  commits the user message, immediately removes suggestions, and switches to a
  bottom-docked composer with the same width and intrinsic height before provider
  output; a populated History resume also starts bottom-docked. A pre-commit
  rejection retains the centered layout and
  recoverable draft, while a post-commit provider failure remains in conversation
  layout. Reduce Motion, short-height, narrow-width, and accessibility-text
  behavior remain usable.
- The three nonempty-library suggestions use the approved copy and form a
  left-aligned vertical list above the composer in visual, keyboard, and
  VoiceOver order. Their text aligns with the editor caret, and the empty-library
  variants expose native Add and Import actions.
- Both built-in seeds remain minimal: they identify
  `rubien_present_document_cards` as the replacement for Markdown navigation when
  the agent points to an openable document. The tool description and schema carry
  batching and argument details. One or
  more successful `rubien_present_document_cards` calls nevertheless render exactly one
  ordered native group after the final explanation (or at turn completion if no
  final prose arrives) and do not leave redundant successful tool chips. Calls
  merge by call-start ordinal, then item index; repeated events with the same call
  ID are ignored; stable deduplication and the ten-unique-item cap apply across
  the whole turn. Cards show title, a truncated author line, year (or a localized
  em dash), and badge, with full title/authors available as hover text. The schema
  rejects agent-supplied heading, reason, or venue fields.
  Plain Markdown remains the non-interactive fallback when the provider does not
  call the tool.
- A saved document card re-fetches its integer ID and opens PDF → Web → Library
  reveal through one shared policy. A deleted/stale ID cannot open another row.
  An external candidate passes HTTP(S) safety checks, opens only on explicit
  **Open source**, and enters metadata, supported-file, or reviewed web intake
  according to Rubien's classification only on explicit **Add to Rubien…**; a
  model mention alone causes no import or download.
- A normal `rubien-cli mcp` launch and the public Node server do not advertise
  `rubien_present_document_cards`; Rubien's native helper with
  `RUBIEN_APP_PRESENTATION=1` advertises exactly that optional tool. There is no
  standalone CLI command. Its input/result decoder rejects malformed or
  oversized data and caps the merged per-turn group at ten unique items.
  Renderer tests cover hostile titles/URLs, DOM `textContent`, keyboard and
  VoiceOver labels, reader precedence, missing IDs, conservative web-URL dedup
  keys, call-ID replay suppression, invocation-versus-completion ordering, and
  matching Claude/Codex History restoration.
- One click reaches the unchanged All References/default Library table.
- Switching Home → Library → Home preserves the current in-memory conversation
  and any in-flight turn, unsent draft text, structured paper mentions, and
  pending attachments.
- Reader assistants remain reference-scoped with their current behavior.
- Home History defaults to attributed Home conversations; reader History still
  supports document scope, and unclassified sessions are never mislabeled. A
  resume adopts the selected conversation's UUID/context rather than the pane's
  abandoned identity.
- Hidden turn success/failure/approval state comes from a generation-keyed
  structured outcome, with cancellation and supersession never shown as unread
  completion.
- At 59 active seconds a flushed component remains excluded from papers, time,
  heatmap, and streaks; at 60 the paper-day qualifies and contributes all 60
  seconds. The first local threshold crossing and each additional active minute
  flush, while pause/minimize/close/app deactivation/sleep/day rollover also
  flush immediately. Relaunch resumes the stored counter, app inactivity/sleep
  accrue nothing, local midnight/time-zone changes split components, and a crash
  loses less than one unflushed minute.
- Every reading accumulator carries its expected epoch pair. A concurrent
  `rubien-cli stats-clear` cannot produce a stale-generation write or resurrect
  pre-clear seconds: the flush transaction detects the mismatch, discards the
  ambiguous unflushed delta, and restarts under the current pair. Cross-process
  notification accelerates the reset but is not the correctness boundary.
- Same-installation writes and conflicts take monotonic maxima; different
  installation components sum without losing increments. Simultaneous-device
  time is intentionally double-counted and every duration is labeled Estimated.
- Month, calendar Quarter, and Year windows preserve their anchor across
  range changes, navigate by their defined intervals, stop forward navigation
  at the current window, remember the selected granularity, and distinguish
  future cells from zero-reading days. Daily intensity excludes every
  0–59-second paper-day and uses fixed `60–899`, `900–1,799`, `1,800–3,599`,
  `3,600–7,199`, and `7,200+` second Levels 1–5 in every range; exact-boundary
  tests cover 59/60, 899/900, 1,799/1,800, 3,599/3,600, and 7,199/7,200.
  Hover and VoiceOver expose exact estimated time and distinct-paper count.
- The heatmap, streaks, current-week boundary, leap day, year boundary, and
  local-day capture are covered by deterministic calendar tests, including a
  cross-January streak and a future-dated qualified component. Current-streak
  tests cover a qualified today, an unqualified today with a run ending yesterday,
  and neither today nor yesterday qualified.
- A fresh Assistant conversation records exactly once after provider start;
  empty/new, failed-before-start, extra turns, ID rotation, and resume do not;
  provider/content-bearing model switches start a new logical conversation.
  Claude/Codex conversations not initiated inside Rubien never count. A delayed
  Assistant-start write follows a same-intent rebase but is dropped if a distinct
  clear superseded its expected epoch before commit.
- Activity queries are independent of the selected/saved table view.
- Current-generation queries retain exact results and remain bounded at both
  10,000 and 50,000 representative activity rows; no age-based compaction ships
  in v1.
- Home global Search always uses all-library scope.
- Sync round-trips all three entities while the two coordination tables remain
  local-only and pass their persistence/relaunch tests plus
  `SyncSchemaInvariantTests`; fresh and v6 → v7 migrations both pass without
  changing v1's trigger table list. Offline upgrades share deterministic initial
  generations, seeded epochs are explicitly dirtied, and no Home query reads the
  incompatible legacy open fields before or after a reset.
- A pending clear rebases until its exact epoch is server-acknowledged. Rebase
  preserves post-clear reading and Assistant facts, rewrites reading identities
  and dirty/cache/tombstone bookkeeping, marks Assistant facts under the rebased
  pair, and retags the matching in-memory reading accumulator. Concurrent clears
  converge, and a same-day post-clear component uses a different CKRecord
  identity.
- Unknown-epoch and temporarily parentless components persist in quarantine
  across fetched batches. Both child→delete and delete→child converge; a known or
  end-of-fetch permanent orphan is discarded and queued for server deletion
  without failing unrelated records. An initial-pull fixture containing thousands
  of activity records exceeds the fetch batch size and proves parent resolution,
  orphan cleanup, and continued batch progress.
- Activity stays local while iCloud library sync is off and joins the private
  synced library when the existing sync setting is enabled.
- CLI JSON and both native/Node MCP outputs are documented, policy-classified,
  and contract/parity-tested. Tests pin the `trackedTotals`, `currentWeek`,
  `streaks`, `yearActivity`, `recentPapers`, and `coverage` scopes: changing
  `--year` changes only `yearActivity`, while recent papers remain
  current-generation and not year-bounded.
- Capture toggles and durable clear actions ship with capture and correctly
  invalidate the UI. A local clear takes effect without waiting for CloudKit and
  queued old-fact deletions drain through the normal bounded scheduler. Reading
  clear leaves legacy `lastReadAt`/`readCount` unchanged; Assistant clear leaves
  functional History attribution unchanged; neither action claims to delete
  provider transcripts.
- No new activity row contains a prompt, answer, preview, attachment name,
  provider runtime ID, document content, token count, cost, hardware identifier,
  focus-event interval, scroll event, or gaze signal.
- The tracked reading-time and current-week time cards match the qualified SQL
  aggregates, visibly say Estimated, and expose complete formatted durations to
  VoiceOver/help text.
- The 900-point minimum window remains usable; chat is never covered by an
  automatically shown Activity panel.
- Empty, setup-failed, offline, and statistics-failed states remain actionable.
- Light/dark mode, accent colors, high contrast, Reduce Motion, keyboard, and
  VoiceOver receive visual/manual verification.
