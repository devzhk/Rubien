# Rubien-owned Assistant transcripts and Codex runtime broker — Design Spec

**Date:** 2026-07-21

**Status:** Implemented in an isolated worktree; UI validation and integration pending

**Scope:** Home and reader Assistant history, scheduled-run progress, provider
continuation, and Codex process/concurrency ownership

**Related documents:**

- [Assistant chat sidebar](2026-07-04-assistant-chat-sidebar-design.md)
- [Codex app-server provider](2026-07-06-codex-app-server-phase3b-design.md)
- [Codex model and effort discovery](2026-07-10-codex-model-autodiscovery-design.md)
- [Agent Home and Reading Activity](2026-07-15-agent-home-design.md)
- [Scheduled Assistant jobs](2026-07-16-scheduled-jobs-design.md)

This design deliberately revises the provider-owned-transcript decisions in the
Agent Home and scheduled-jobs designs. Those decisions were appropriate when
Rubien had one reader sidebar and no durable background work. They now force
Home, readers, model discovery, History, and scheduled jobs to share one live
Codex transport for both optional metadata and user-critical turns.

## 1. Summary

Rubien should make two coordinated structural changes:

1. **Persist a normalized, local Rubien transcript for every conversation that
   Rubien starts.** This transcript becomes the source for Home/reader History,
   scheduled-run results, live scheduled progress, and transcript rendering.
   Claude/Codex session IDs remain the authority for continuing a provider
   conversation, but provider History is no longer on Rubien's normal UI path.
2. **Replace the shared Codex mega-actor with an app-level runtime broker and an
   explicit state machine.** Foreground turns, scheduled turns, and optional
   metadata have distinct admission policies. Metadata is always preemptible.
   Until a version-gated socket/daemon spike proves a narrower isolation boundary,
   sent metadata must finish or its app-server process generation must be reaped
   before a higher-priority turn is admitted.

The target architecture is:

```text
Home / PDF reader / Web reader / Scheduled UI
                    │
                    ▼
       AssistantConversationService
       ├── local transcript store ───────► History + live rendering
       └── provider continuation id
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
 ClaudeTurnRuntime       CodexRuntimeBroker
 (process per turn)      ├── interactive lane
                         ├── scheduled lane
                         └── disposable metadata lane
                                  │
                                  ▼
                       one Codex runtime generation
                       (stdio or Rubien-owned socket listener)
```

This removes optional provider reads from interactive startup, gives scheduled
runs a durable live transcript, and turns Codex lifecycle behavior into explicit
state transitions rather than an expanding set of flags and generation checks.

## 2. Why the current architecture is failing

The failures are not a collection of unrelated Codex defects. They cluster at
one ownership boundary.

### 2.1 One process carries unrelated workloads

Production currently shares one app-lifetime `codex app-server` across Home,
reader sidebars, History, model discovery, and scheduled jobs. This protects the
user's shared `~/.codex` home from concurrent Rubien app-servers and makes normal
follow-up turns fast, but it also creates one global failure domain.

A slow `thread/read` or `model/list` can therefore block `thread/start` from a
reader. A scheduled run can affect Home History. A process replacement caused by
one metadata timeout fails every other request correlated through that server.

### 2.2 Local cancellation is not server cancellation

Rubien can cancel a Swift task or resolve its local continuation as superseded.
Codex may still be executing the JSON-RPC request. Removing an ID from the local
pending map does not remove the work from the server.

The July 21 reader failure was exactly this sequence:

1. a History `thread/read` began;
2. a newer cached History lookup superseded its Rubien waiter;
3. Codex continued the abandoned read;
4. the PDF reader saw no locally pending History request and reused the process;
5. `thread/start` queued behind the abandoned work and the turn ended before a
   session was created.

The immediate fix tracks abandoned server-side work. The structural design must
make this invariant impossible to forget for a future metadata method.

### 2.3 Actor isolation is not transaction isolation

`CodexAppServerConnection` is actor-isolated, so individual state mutations are
data-race free. Its methods still suspend at process waits, handshakes, request
responses, recovery delays, and queue promotion. Other actor calls can interleave
at every `await`.

The actor currently owns process spawning, handshake state, request correlation,
turn scheduling, cross-window ownership, approvals, History generations, model
metadata, timeouts, process reaping, crash reporting, and invocation posture.
Correctness depends on preserving invariants across all those interleavings.
Tokens and booleans protect known races, but do not provide one explicit model of
which transitions are legal.

### 2.4 Provider-owned History is now an operational dependency

Rubien deliberately stores no transcript today. That avoids duplicating provider
history, but means every remount, History list, search, resume, and scheduled-run
open may need provider storage. Claude reads local JSONL without touching a live
turn process. Codex must use the app-server wire API, placing presentation and
navigation work onto the same runtime as user turns.

Scheduled progress illustrates the mismatch most clearly:
`ScheduledJobCoordinator` already builds a normalized live progress snapshot
from runner `AgentEvent`s and retains a bounded in-memory terminal cache, but a
restart still requires re-reading the provider transcript. The data needed for
durable live progress already crosses Rubien; the missing piece is a local store.

### 2.5 The integration outgrew its original lifecycle

The original Codex design specified one provider/server per conversation window.
The product later added process-wide sharing, Agent Home, model discovery,
attachments, scheduled execution, and cross-surface History. Each addition was
reasonable, but the shared connection became a runtime coordinator without being
redesigned as one.

## 3. Product decisions proposed for approval

| ID | Decision | Rationale |
|---|---|---|
| D1 | Rubien stores normalized transcripts for conversations started inside Rubien. | History and rendering should not depend on a live provider process. |
| D2 | Transcripts are local-only in the first release: no CloudKit records or sync triggers. | Prompts, answers, and tool details are materially more sensitive than the current activity metadata. Sync can be designed separately. |
| D3 | The provider remains authoritative for continuation; Rubien is authoritative for presentation. | A local transcript cannot replace Claude `--resume` or Codex `thread/resume`, but provider loss should not erase the visible result. |
| D4 | Scheduled runs persist their transcript incrementally and expose it read-only while running. | The run page can show live progress without subscribing to or resuming the provider turn. |
| D5 | Default History lists only Rubien-owned local conversations. | Normal navigation becomes fast, deterministic, and provider-independent. |
| D6 | Existing/external provider conversations remain available through an explicit **Provider History…** legacy/import action. | Compatibility is preserved without putting provider metadata on mount or send paths. |
| D7 | Codex has one app-level broker and at most one broker-controlled Codex root process tree at a time, whether a stdio app-server, Rubien-owned socket listener, or standalone probe. | Rubien has reproduced startup interference when independent metadata and turn processes overlap against the same Codex home. The broker also gives every future probe one admission/reap boundary instead of assuming unrelated launches are safe. Codex's separately managed detached daemon is not broker-owned by default. |
| D8 | Work has three classes: interactive, scheduled, and metadata. Metadata is always preemptible and must never delay a turn. The initial stdio policy forbids overlap; a multi-connection socket policy may allow proven-safe overlap after the Phase D checkpoint. | Optional reads must not delay a user prompt or disturb a live turn, while keeping the admission contract independent of transport topology. |
| D9 | For the currently verified stdio topology, an app-server generation—not a Swift task or closed client connection—is the safe preemption boundary for a sent metadata request. Revisit this only after the Phase D socket/daemon spike. | Codex exposes no general cancellation RPC for `thread/read`, `thread/list`, or `model/list`; Codex 0.145.0 also allows a handler that already started to finish after its connection closes. |
| D10 | Rubien stores only user-visible normalized content, never raw provider frames, hidden reasoning, or chain-of-thought. | The transcript store should match the product surface and minimize sensitive implementation data. |
| D11 | Transcript storage is functional application state, not analytics. It is always enabled for ordinary Rubien conversations in v1, with per-conversation delete and **Clear Assistant Conversations…** controls. | A silent no-save mode would either break History/scheduled results or reintroduce provider reads. A future explicit private conversation can be designed without fallback reads. |
| D12 | Assistant transcript data is readable/deletable through `rubien-cli`, but is not exposed as an MCP tool by default. | New data-layer entities require CLI parity; automatic model access would be an unrelated privacy expansion. |

## 4. Goals

- Make sending a Home or reader prompt independent of History/model metadata.
- Load and search Rubien conversations without spawning Claude or Codex.
- Open a scheduled run while it is running and observe progress within a bounded
  persistence-to-UI delay.
- Preserve completed results even if provider History is pruned, corrupted, or
  temporarily unavailable.
- Continue conversations through the provider's native session/thread ID.
- Guarantee that Rubien owns at most one Codex root process tree and never
  launches an app-server, version/auth probe, or isolation command before its
  predecessor is reaped.
- Give interactive, scheduled, and metadata work explicit and testable priority
  rules.
- Keep scheduling/admission independent of whether the selected Codex transport
  is one stdio connection or multiple initialized connections to one
  Rubien-owned socket listener.
- Keep the wire decoder tolerant of Codex versions while isolating protocol
  changes from scheduling and UI state.
- Preserve Home/reader transcript rendering, approvals, attachments, paper cards,
  model selection, and scheduled read-only isolation.
- Retain access to pre-migration and same-workspace external provider sessions
  through an explicit compatibility path.

## 5. Non-goals

- Syncing prompts, answers, attachments, or tool details through CloudKit.
- Replacing provider-native continuation with prompt replay.
- Importing every Claude/Codex conversation automatically at migration time.
- Parsing Codex's private on-disk store as the primary History implementation.
- Running multiple Codex root process trees concurrently for higher throughput.
- Preempting an already-running scheduled turn merely because a user opens a
  foreground composer. Priority affects admission; an admitted turn is not killed
  without an explicit cancellation policy.
- Persisting reasoning deltas, hidden system/developer instructions, raw approval
  payloads, complete command output, or arbitrary MCP result bodies.
- Changing the user's provider-owned history or claiming that deleting a Rubien
  transcript deletes the corresponding Claude/Codex session.
- Adding transcript content to reading/Assistant activity analytics.
- Building a generic event-sourcing system for the rest of Rubien.

## 6. Source-of-truth boundaries

The design uses different authorities for different questions:

| Question | Authority |
|---|---|
| What should Rubien render? | Local normalized transcript |
| What appears in normal Home/reader History? | Local conversation index |
| What is a scheduled run doing now? | Local persisted turn/entry state |
| Which provider session continues the conversation? | Latest provider session ID captured by Rubien |
| What actually happened in a provider session outside Rubien? | Provider History, only through explicit import |
| Whether a Codex process may receive work | `CodexRuntimeBroker` state machine |
| Whether a provider request/notification is current | Runtime generation + work ID + request/item ID |

Provider continuation and Rubien presentation may diverge after a crash. Rubien
must show that honestly: retain the last durable partial transcript, mark its turn
interrupted, and offer an explicit provider refresh/import when available. Never
silently replace local visible content during an active conversation.

## 7. Persistent data model

Implementation must add a new immutable migration after the latest migration at
the time work begins. The current repository ends at `v9`; do not edit `v8` or
`v9`. These tables are local-only and must not be added to CloudKit entity maps,
dirty triggers, or `RubienSync` record types.

### 7.1 `assistantConversation`

```text
assistantConversation
  id                       TEXT      PRIMARY KEY  // Rubien UUID, lowercase
  provider                 TEXT      NOT NULL     // claude | codex; unknown-safe
  origin                   TEXT      NOT NULL     // rubien | providerImport | legacyStub
  workspaceIdentityHash    TEXT      NULL         // SHA-256 of standardized workspace
  contextKind              TEXT      NOT NULL     // library | reference | unclassified
  referenceId              INTEGER   NULL REFERENCES reference(id) ON DELETE SET NULL
  scheduledJobRunId        TEXT      NULL UNIQUE
                                      REFERENCES scheduledJobRun(id) ON DELETE CASCADE
  continuedFromConversationId TEXT   NULL UNIQUE
                                      REFERENCES assistantConversation(id) ON DELETE SET NULL
  continuationTransferredAt DATETIME NULL
  latestProviderSessionId  TEXT      NULL
  latestSessionTurnOrdinal INTEGER   NULL
  latestSessionEventOrdinal INTEGER  NULL
  createdAt                DATETIME  NOT NULL
  lastActivityAt           DATETIME  NOT NULL
  archivedAt               DATETIME  NULL
```

The same migration adds two local transcript-lifecycle fields to the existing
run table:

```text
scheduledJobRun.assistantTranscriptState TEXT NOT NULL DEFAULT 'none'
  // none | legacyEligible | legacyAttempted | legacyRetrying | capturing |
  // available | deleted; unknown-safe
scheduledJobRun.assistantTranscriptStatusCode TEXT NULL
  // alreadyLocal | deletedLocal | providerUnavailable | notFound | cancelled |
  // interrupted | storageFailure | unknown; unknown-safe
```

Migration sets an existing visible run to `legacyEligible` only when it has a
non-empty usable `providerSessionId`; visible runs without one become `none`, and
existing hidden tombstones become `deleted`. Newly created runs begin `none`,
become `capturing` when their conversation is linked, and become `available` in
the atomic terminal transaction or interrupted-run recovery when a durable
partial exists. Only `legacyEligible` permits automatic one-time import when an
old run is opened. The opener first snapshots the local alias. A live owner or
tombstone consumes eligibility to `legacyAttempted` without provider traffic and
presents the existing local conversation or deletion explanation; it never
converts an ordinary conversation into a run-owned result. The local resolution
is one transaction that compare-and-swaps `legacyEligible` to `legacyAttempted`
and sets `assistantTranscriptStatusCode` to `alreadyLocal` or `deletedLocal`;
only the winner changes state. `alreadyLocal` offers **Open local conversation**,
while `deletedLocal` offers only the explicit Provider History path—not inline
Retry.

For an absent alias, the opener requests metadata-lane admission. A pre-admission
busy or unavailable result performs no provider traffic and leaves it eligible.
Immediately before the first provider RPC write, the admitted work
compare-and-swaps it to `legacyAttempted`; only the winner may fetch. Success
links the conversation and changes the state to `available` atomically. Failure,
post-admission cancellation, or process death leaves `legacyAttempted`, so
another ordinary open never retries provider traffic; the run shows the saved
resolution/failure kind and an explicit **Retry import** action when retry is
meaningful.

An explicit Retry compare-and-swaps `legacyAttempted` to `legacyRetrying`; only
the winning service lease may fetch. Success becomes `available`, failure returns
to `legacyAttempted` with its status code, and launch recovery converts abandoned
`legacyRetrying` to `legacyAttempted` with `interrupted`. Retry is offered only for
retryable provider/import status codes. It never applies to `alreadyLocal` or
reclaims `deletedLocal`; the latter requires a newly selected Provider History
action under §7.5.

Conversation Delete/Clear sets a linked run to `deleted` in the same transaction;
reopening that run must not import it again. Explicit Provider History can still
import the provider session as an ordinary conversation, but does not silently
relink a user-deleted run. Unknown values never auto-import.

The non-null `none` default makes SQLite `ALTER TABLE` valid and keeps an older
writer that omits the column from failing after downgrade; such a newly written
run remains `none` and requires explicit Provider History rather than being
mistaken for a pre-migration import candidate.

`assistantTranscriptStatusCode` describes only capture/import availability and
must never overwrite the run's existing execution `failureKind`. New capture,
successful import, and `available` clear it. Import failure stores a bounded enum
code, not provider text or a localized sentence; the UI derives the precise
actionable message. Unknown codes render a generic import-unavailable state.

Rules:

- `id` is the existing stable Rubien conversation UUID generated before the first
  provider turn. It is not a provider thread/session ID.
- `workspaceIdentityHash` uses the same standardized workspace identity and
  SHA-256 construction as the current attribution store. Raw workspace paths are
  not needed for History filtering. New Rubien conversations and completed
  provider imports always have a non-null value. `NULL` is reserved for migrated
  one-way-hash legacy stubs; those rows are excluded from normal workspace-scoped
  History until a provider listing enriches them.
- `origin == legacyStub` is non-continuable and never appears in normal History.
  It exists only so a later explicit Provider History listing can recompute the
  alias key from a raw session ID, enrich the row, and change its origin in the
  same import transaction. Unknown origin values decode as non-visible until the
  app understands them.
- Valid context combinations are normalized as follows: `library` and
  `unclassified` require `referenceId == NULL`; a newly-created `reference`
  conversation requires a non-null ID; and `reference` plus `NULL` is the one
  sanctioned detached state produced by `ON DELETE SET NULL`. Enforce
  `contextKind == 'reference' OR referenceId IS NULL` in SQL, enforce the
  new-reference requirement in the creation API, and decode unknown context
  kinds as unclassified only when their reference ID is null. Deleting a paper
  does not erase a conversation; the UI renders its former document context as
  unavailable.
- `scheduledJobRunId` links exactly one conversation to a run. A physical run-row
  deletion cascades its locally captured result. The current user-facing Delete
  action retains a scrubbed `scheduledJobRun` tombstone for recurrence safety, so
  that operation must explicitly delete the linked conversation in the same
  database transaction before it hides the run.
- Deleting a scheduled job physically deletes its run rows today. That cascade
  intentionally deletes their local conversations and managed attachments too.
  The confirmation must say **job, run history, and locally saved run
  transcripts/attachments**; it must also say ordinary continuation chats and
  provider-owned History are not deleted. Active runs continue to block job
  deletion.
- A scheduled result remains run-owned and read-only. Its first interactive
  continuation creates one ordinary child conversation with
  `continuedFromConversationId` pointing to the result; it never appends later
  chat turns to the run-owned row. Creation is allowed only after the scheduled
  turn is terminal **and** its identity gate has closed (or bounded teardown has
  proved no later session identity can arrive); a persisted terminal result with
  an identity-open execution lease shows **Finishing…** rather than enabling
  Continue. In the same transaction, move that session's
  aliases plus latest session/binding tuple to the child and clear the parent's
  latest binding, then stamp `continuationTransferredAt`. Increment each moved
  alias's owner revision. The child's turn allocator starts at
  `max(MAX(child turn ordinal), transferred latestSessionTurnOrdinal) + 1`, so
  its first session event is strictly newer than the transferred binding rather
  than restarting at ordinal one. This is the only
  sanctioned alias-owner transfer, and it succeeds only when the parent is the
  current owner. The child renderer may show the parent as a read-only prelude
  while it exists. Deleting the run/job deletes that prelude and sets the child's
  link to null, but never deletes the later ordinary chat.
  Creation validates that the parent is a terminal scheduled result and forbids
  self-links or chains/cycles; only one direct child is allowed, and a stamped
  parent never silently creates a replacement if the user later deletes that
  child. The transaction rechecks terminal state, absence of an execution lease,
  and closed identity ownership so a late `.sessionStarted` cannot recreate an
  alias on the parent after transfer.
- `latestProviderSessionId` is local continuation state. Claude may rotate it;
  Codex normally keeps a stable thread ID. Record every accepted session alias
  idempotently, but update the latest binding only by compare-and-swap on
  `(turnOrdinal, identityEventOrdinal)`. A late same-attempt ID after Stop may
  advance its own turn; an older turn can never overwrite a binding established
  by a newer turn. This identity update does not make late content events current.
- Every transaction that commits new or changed user-visible transcript content
  also advances `lastActivityAt` monotonically to that durable activity's time.
  This includes streaming partials and imported visible entries. Alias/session
  identity events, model/account metadata, and other invisible repairs do not
  reorder History. An import derives activity time from its newest normalized
  visible entry, falling back to import time only when the provider supplied no
  usable timestamp.
- Conversation deletion cascades turns, entries, and attachment rows. Session
  aliases become ownerless revisioned tombstones as specified in §7.5 rather
  than disappearing. Managed attachment-directory deletion runs after the database commit;
  a launch-time retry/reconciliation sweep removes orphaned conversation
  directories and final attachment IDs with no storage row, so a filesystem
  failure cannot resurrect content, leak a pre-commit copy indefinitely, or roll
  back the DB deletion.

Indexes:

- `(workspaceIdentityHash, lastActivityAt DESC, id DESC)` for History;
- `(contextKind, referenceId, lastActivityAt DESC)` for reader-scoped History;
- `(origin, workspaceIdentityHash, lastActivityAt DESC)` for excluding/enriching
  legacy stubs;
- `(scheduledJobRunId)` is covered by its uniqueness constraint;
- `(continuedFromConversationId)` is covered by its uniqueness constraint;
- `(archivedAt, lastActivityAt DESC)` for active/archived lists.

### 7.2 `assistantTurn`

```text
assistantTurn
  id                  TEXT      PRIMARY KEY       // Rubien turn UUID
  conversationId      TEXT      NOT NULL REFERENCES assistantConversation(id)
                                        ON DELETE CASCADE
  ordinal             INTEGER   NOT NULL
  providerTurnId      TEXT      NULL
  status              TEXT      NOT NULL          // queued | starting | running |
                                                  // succeeded | failed | interrupted
  requestedModel      TEXT      NULL
  requestedEffort     TEXT      NULL
  resolvedModel       TEXT      NULL
  resolvedEffort      TEXT      NULL
  failureKind         TEXT      NULL
  inputTokens         INTEGER   NULL
  outputTokens        INTEGER   NULL
  cacheReadTokens     INTEGER   NULL
  cacheCreationTokens INTEGER   NULL
  totalCostUSD        REAL      NULL
  startedAt           DATETIME  NULL
  finishedAt          DATETIME  NULL
  dateModified        DATETIME  NOT NULL
  UNIQUE (conversationId, ordinal)
```

The user message and terminal state are committed even when admission or provider
startup fails. This makes a failed send visible and prevents the UI from implying
that a submitted prompt never existed.

Unknown status/failure raw values decode to safe display fallbacks.
`requestedModel`/`requestedEffort` preserve what Rubien sent. Resolved fields are
written only when the provider reports them; never present a requested or default
effort as provider-confirmed. Usage columns intentionally cover every field in
the current `AgentUsage`, including cache-creation tokens and total cost. All are
optional accounting metadata; absence is not an error.

### 7.3 `assistantTranscriptEntry`

```text
assistantTranscriptEntry
  rowId             INTEGER   PRIMARY KEY AUTOINCREMENT // stable FTS content key
  id                TEXT      NOT NULL UNIQUE
  turnId            TEXT      NOT NULL REFERENCES assistantTurn(id) ON DELETE CASCADE
  sequence          INTEGER   NOT NULL
  providerItemId    TEXT      NULL
  kind              TEXT      NOT NULL  // user | assistant | tool | notice | paper
  body              TEXT      NOT NULL
  payloadVersion    INTEGER   NOT NULL  // normalized presentation contract
  payloadJSON       TEXT      NULL      // kind-specific safe presentation
  searchText        TEXT      NOT NULL  // normalized FTS projection
  status            TEXT      NULL      // streaming/completed/denied/interrupted/failed
  createdAt         DATETIME  NOT NULL
  dateModified      DATETIME  NOT NULL
  UNIQUE (turnId, sequence)
```

Create a partial unique index on `(turnId, providerItemId)` when
`providerItemId IS NOT NULL`. Provider adapters should preserve Codex item IDs and
Claude message/tool-use IDs. When no provider ID exists, the recorder assigns a
Rubien ID once and keeps it for later updates. If a provider ID names a parent
containing multiple visible logical items, the adapter derives a stable composite
sub-ID rather than forcing unrelated projections through one unique key.

`rowId` is storage-only and never leaves the database API. Making it an explicit
`INTEGER PRIMARY KEY` keeps the external-content FTS key stable across `VACUUM`;
the UUID `id` remains the application identity and foreign-key target.

`payloadVersion` is entry-grained because one long-lived conversation may contain
entries written by many Rubien versions. Decoders dispatch by `(kind,
payloadVersion)`, ignore unknown payload fields, and fall back to `body` plus an
unavailable-detail indicator when a future or corrupt payload cannot be decoded.
An upgrade never rewrites old payloads merely to bump their version.

Storage is normalized to the existing renderer contract:

- `user` and `assistant`: visible Markdown body;
- `tool`: the visible safe tool-chip name/detail/status, not the raw request;
- `paper`: versioned `ChatPaperGroup` presentation metadata;
- `notice`: only notices rendered as conversation content;
- attachments: the storage-specific representation below, never a
  provider-facing absolute staged path.

A stable provider item identifies one logical projection, not one immutable
render kind. For example, a provisional tool chip may later be suppressed in
favor of a paper card with the same call/item ID. That upsert retains `id` and
`sequence` while atomically replacing `kind`, `body`, `payloadVersion`,
`payloadJSON`, `searchText`, and status; it must not append a duplicate row.

Do not persist reasoning items, internal plans, system/developer seeds, ignored
notifications, raw command output, or unrecognized provider payload fields.

### 7.4 Stored attachments

Do not encode `ChatAttachmentPresentation` directly: it intentionally lacks the
durable path and media type needed to reopen content. Add a normalized local
table (and a matching portable RubienCore DTO for the CLI/UI boundary):

```text
assistantAttachment
  id             TEXT     PRIMARY KEY              // attachment UUID
  entryId        TEXT     NOT NULL REFERENCES assistantTranscriptEntry(id)
                                      ON DELETE CASCADE
  displayName    TEXT     NOT NULL
  kind           TEXT     NOT NULL                 // image | text; unknown-safe
  relativePath   TEXT     NULL                     // unavailable import when null
  mediaType      TEXT     NOT NULL
  byteCount      INTEGER  NOT NULL
  sha256         TEXT     NULL
  createdAt      DATETIME NOT NULL
```

Index `entryId`. The creation API permits attachments only on a user entry. The
DTO mirrors these storage fields; the renderer derives `isAvailable` and its
thumbnail at read time rather than persisting either transient value.

```swift
struct StoredAssistantAttachment: Codable, Sendable, Equatable {
    let id: UUID
    let displayName: String
    let kind: StoredAssistantAttachmentKind
    let relativePath: String?       // nil only for an unavailable imported item
    let mediaType: String
    let byteCount: Int64
    let sha256: String?
}
```

For Rubien-captured input, the recorder copies the accepted staged file into a
temporary file beneath a library-owned pending directory, validates size/hash,
then atomically renames it to a conversation-owned final path immediately before
the entry/attachment database transaction commits. Rollback removes the final or
temporary file best-effort. A valid stored path is non-empty, non-absolute,
contains no `.` or `..` component after standardization, resolves beneath the
expected conversation directory after symlink resolution, and has the attachment
UUID as its canonical first component. Invalid or missing paths decode as
unavailable and are never opened. Provider imports may store
`relativePath == nil` when only presentation metadata survives.

Startup runs before recorder admission and removes abandoned pending files. It
also reconciles every final attachment path against `assistantAttachment`, so a
crash after rename but before DB commit cannot leak a file merely because its
conversation row survived. Conversely, a DB row whose file is missing remains as
unavailable metadata; the sweep never invents or re-downloads content.
Attachment replacement/removal captures obsolete relative paths in the database
transaction result, removes them after commit, and relies on the same
reconciliation sweep after a crash.

The existing workspace `AssistantAttachmentStore` remains the provider-facing
staging boundary; it is not the durable transcript store. Its absolute URL is
used only long enough to validate/copy the file, then discarded from the storage
payload.

Do not persist unbounded thumbnail data URLs in SQLite. Image thumbnails are
regenerated on demand into an evictable cache, capped at 256 KiB and 512 pixels
on the longest edge; absence never makes the original unavailable. Conversation
deletion owns both the durable attachment directory and any derived cache.

### 7.5 `assistantSessionAlias`

```text
assistantSessionAlias
  keyHash          TEXT      PRIMARY KEY
  conversationId   TEXT      NULL REFERENCES assistantConversation(id)
                                  ON DELETE SET NULL
  provider         TEXT      NOT NULL
  ownerRevision    INTEGER   NOT NULL
  recordedAt       DATETIME  NOT NULL
```

`keyHash = SHA256(standardizedWorkspace + separator + provider + separator +
providerSessionId)`, matching the current attribution-store key. The alias table
supports Claude session-ID rotation and maps explicit provider-History imports
back to the stable Rubien conversation without retaining every raw historical ID.
The conversation's raw latest ID remains on `assistantConversation` because
continuation requires it; `scheduledJobRun.providerSessionId` keeps its existing
separate result pointer, while aliases retain hashes only.

An ownerless alias is a small deletion tombstone: it retains only the provider
and one-way key hash, not a raw session ID or transcript. A database-owned
`BEFORE DELETE` trigger clears `conversationId` and increments `ownerRevision`
for every alias owned by the deleted conversation; `ON DELETE SET NULL` is the
foreign-key fallback. This preserves a cross-process generation boundary even
when CLI deletion races a UI provider fetch. Tombstones may be pruned only under
a separately specified retention policy, never opportunistically on launch.

Before a provider fetch, the importer records an alias snapshot: absent, live
`(conversationId, ownerRevision)`, or tombstoned `ownerRevision`. A live owner is
navigated immediately without fetching or mutating its local transcript. V1 has
no implicit refresh operation: this is essential after a scheduled result has
split into an immutable parent and a continuation child. If an alias was absent,
the eventual transaction may insert it only if it is still absent. If it was
tombstoned, only a newly initiated, explicit Provider History selection may
compare-and-swap that exact tombstone to a new owner. An automatic legacy import
never reclaims a tombstone.

Alias lookup, conversation insert-or-select, and alias claim otherwise occur in
one database transaction. Reclaiming the same `keyHash` for the same conversation
is idempotent. If a concurrently imported session has a live owner, that owner
wins and the uncommitted candidate is discarded. If the pre-fetch snapshot was
live but is missing, tombstoned, revision-changed, or reassigned at commit, the
older import intent aborts; it never resurrects the deleted owner. A user may
start a new explicit import after deletion, which captures the tombstone's new
revision and may reclaim it. This makes concurrent import and import-versus-delete
deterministic across the provider network gap.

A live recorder collision is an invariant failure rather than an implicit merge:
keep the existing alias owner, do not update the new conversation's latest
session ID, mark its turn non-continuable with `sessionBindingConflict`, and
retain already-visible content for diagnosis. The sole automatic owner-change
API is the explicit scheduled-result continuation transaction in §7.1; it
compare-and-swaps aliases from that exact parent and revision to its unique child
while incrementing `ownerRevision`.

### 7.6 Full-text search projection

Create an external-content FTS5 table `assistantTranscriptEntryFts`, synchronized
with `assistantTranscriptEntry` by its explicit integer `rowId` and using the
`unicode61` tokenizer, with one indexed `searchText` column. The recorder
materializes `searchText` rather than asking SQL to parse `payloadJSON`:

- user/assistant entries use their visible body;
- paper entries use normalized paper titles from the decoded payload;
- tool, notice, and attachment metadata are empty in v1 unless a later product
  decision explicitly makes them searchable.

FTS maintenance is database-owned, using GRDB
`FTS5.synchronize(withTable:)` or equivalent SQLite insert/update/delete triggers;
it must not depend on recorder methods because FK cascades and direct database
APIs bypass them. Entry writes and all direct/cascading deletes therefore update
FTS in the same SQLite transaction, and the migration backfills the index before
commit. Conversation search joins FTS rowids through entry and turn to
conversation, filters workspace and context before presentation, groups one hit
per conversation, and orders by best `bm25(assistantTranscriptEntryFts)` score
ascending followed by `lastActivityAt DESC, id DESC` for deterministic ties.
Prefix-query and escaping behavior should follow the existing reference search
conventions. Unknown/corrupt payloads remain searchable through their already
materialized `searchText` without decoding JSON during a query.

### 7.7 Database API and CLI parity

Models and CRUD/query operations live in `RubienCore`, remain Foundation/GRDB
only, and compile on Linux. Add a dedicated database extension rather than
expanding `AppDatabase.swift` beyond migration registration.

Define storage enums/DTOs in `RubienCore`; do not move an app-layer dependency
downward or make `RubienCore` import the `Rubien` target. The macOS Assistant maps
those storage values to `ChatRenderMessage`/renderer payloads at its existing
presentation boundary. Shared value types may move to `RubienCore` only when they
are genuinely provider/UI-neutral and all portable-call-site tests move with them.

Required CLI surface:

```text
rubien-cli assistant-conversations list [--provider ...] [--reference-id ...] [--search ...] [--limit ...]
rubien-cli assistant-conversations get <conversation-id>
rubien-cli assistant-conversations delete <conversation-id>
rubien-cli assistant-conversations clear [--before <ISO-8601>] --confirm
```

`list` returns metadata and a bounded preview. `get` returns conversation, turns,
normalized entries, and attachment metadata (never file bytes or absolute paths)
in deterministic order. Mutations use explicit IDs and confirmation conventions.
Because `scheduledJobRun` also gains local transcript fields, existing
`rubien-cli jobs runs`
JSON adds `assistantTranscriptState` and `assistantTranscriptStatusCode`; job/run
encoders, `Docs/CLI-Reference.md`, and both conversation/job CLI JSON tests update
in the same implementation phase.
Assistant transcript mutations and existing job/run deletion commands that can
cascade into them must acquire the §8.3 library execution lock and return a
stable busy error when another process owns it.

Do not add MCP tools for these commands. A future agent-facing conversation
search requires a separate privacy and prompt-injection design.

## 8. Transcript write path

### 8.1 `AssistantConversationRecorder`

Introduce an actor responsible for durable normalized conversation writes. A
controller or scheduled runner owns one recorder handle per Rubien conversation.
The recorder exposes operations such as:

```swift
beginConversation(...)
beginTurn(attempt:request:)
recordSessionAlias(..., attempt:)
record(envelope:)
finishTurn(attempt:completion:)
markInterruptedAfterCrash(...)
```

It is not a provider and does not understand JSON-RPC or Claude stream JSON. It
consumes provider-neutral events enriched with stable work/item identity.

`AssistantConversationService` grants one execution lease for a conversation
turn before the recorder accepts events. The lease contains the immutable attempt
identity defined in §11 and has separate `contentOpen` and `identityOpen` gates.
Only the current content gate may update visible content or terminal state;
revocation makes later buffered writes fail as stale rather than recreate deleted
rows. Stop closes `contentOpen` but retains `identityOpen` until that provider
stream ends. A queued successor does not dispatch until the outgoing stream has
closed its identity gate (or bounded teardown proves no later identity can
arrive). Conversation deletion revokes both.

### 8.2 Ordering and idempotency

- The controller generates the Rubien turn ID before dispatch.
- The turn row and user entry are inserted in one transaction before provider
  admission.
- Each provider event carries the full attempt identity and, where available, a
  provider item ID. Repeated or out-of-order events upsert the same logical entry
  rather than append duplicates.
- Entry `sequence` is allocated by the recorder, never by completion order from
  concurrent provider tool calls.
- Terminal completion and the final authoritative assistant body commit in one
  transaction when they arrive together.
- Content events tagged with a stale conversation epoch, turn ID, work ID, or
  runtime generation are ignored before persistence as well as before rendering.
- Continuation identity is a separate channel from visible content. A late
  `.sessionStarted` for an attempt whose identity gate remains open may update the
  alias after Stop and may update the latest provider session only through the
  monotonic turn/event compare-and-swap in §7.1, preserving the existing no-fork
  invariant without permitting an older attempt to win. It cannot append content,
  clear interruption, or revive a fully revoked/deleted lease.

### 8.3 Streaming durability and write pressure

Do not write every token. Buffer assistant deltas and flush the current streaming
entry when any of these occurs:

- 250 milliseconds elapsed since the last flush;
- buffered UTF-8 content grew by at least 4 KiB;
- a non-delta event needs ordering after the text;
- the turn completes, is cancelled, or the provider stream closes.

The renderer may receive deltas immediately in memory; database observation
provides cross-window/scheduled progress with a target delay below 500 ms. The
final provider message replaces the streaming body authoritatively.

Before recovery or any new recorder/scheduler/provider admission, the app obtains
an exclusive OS advisory lock scoped to the resolved Rubien library root and
holds it for the app lifetime. The lock—not a PID file—is the authority that no
other Rubien process currently owns Assistant execution for that library. A
second app instance may observe transcripts read-only but must not run recovery,
dispatch provider work, or mutate Assistant transcript/runtime state; it shows
which instance owns execution. CLI Assistant delete/clear attempts the same lock
and fails explicitly while an app owns it, while CLI reads remain available. OS
release after process death makes the next owner eligible to recover. Phase D's
runtime lock extends/reuses this same library-scoped ownership rather than
introducing an independent lock.

After acquiring that lock and before new provider admission, recovery classifies
all pre-existing `queued`, `starting`, or `running` turns and nonterminal runs
from one pre-update snapshot/CTE, then applies all mutations in one transaction.
This ordering prevents an early `interrupted` update from destroying the state
needed to classify a scheduled capture. Non-scheduled turns become
`interrupted`; their last flushed assistant body is retained and visually marked
partial. An execution ID from a previous lock ownership/launch is never treated
as live.

The same recovery transaction changes every abandoned `legacyRetrying` state to
`legacyAttempted` with transcript status `interrupted`, regardless of run terminal
status. No prior retry service lease survives loss of the library execution lock.

The scheduled classification matrix is:

- `none` becomes a failed/interrupted run with no transcript;
- `capturing` with a valid linked conversation, pre-update nonterminal turn, and
  at least one durable visible entry interrupts the turn, fails the run, and
  becomes `available` so the partial result remains openable;
- `capturing` with a missing/invalid link or turn fails the run and becomes
  `none`, cleaning any unreachable partial rows in the same transaction;
- `capturing` with a valid link and pre-update nonterminal turn but zero visible
  entries interrupts the turn, removes the empty linked conversation, fails the
  run, and becomes `none`;
- `available` fails the stale run but preserves its readable transcript;
- `deleted` fails the stale run and remains deleted;
- migration-only `legacyEligible`/`legacyAttempted` fail the stale run but retain
  their compatibility state; a pre-snapshot `legacyRetrying` has already returned
  to `legacyAttempted`. Only `legacyEligible` can later win the one-time automatic
  import gate.

Unknown transcript states fail closed and never trigger provider traffic. This
matrix covers a crash after durable run claim/reservation but before conversation
linkage as well as a crash during capture.

### 8.4 Failure to persist

- An interactive conversation may continue ephemerally after a local write
  failure, but the pane must show one durable warning that History for this turn
  will not be saved. It must not silently fall back to provider History.
- A scheduled run must fail before provider dispatch if its conversation/turn
  rows cannot be created. A scheduled result promises durable inspectability.
- After scheduled dispatch, a transient flush failure retries with bounded
  backoff (2 seconds total) while retaining at most 1 MiB of unflushed normalized
  content. If either bound is exceeded, cancel the provider owner, stop accepting
  further visible content, and keep the last durable partial transcript. When
  SQLite becomes writable, finish the turn/run atomically as a storage failure;
  if it remains unavailable, leave the pair preterminal for startup recovery.
  Scheduled execution never continues with an unbounded memory buffer or reports
  provider success after incremental durability was lost.
- Scheduled terminal state is one transaction that writes the final transcript
  entry, finishes `assistantTurn`, and finishes `scheduledJobRun`. If that
  transaction cannot commit, neither row is reported terminal: the coordinator
  shows an in-memory storage error, retries within a bound, and startup recovery
  later marks the turn `interrupted` and the run `failed` with failure kind
  `interrupted` in one transaction. Do not promise a second `failed` write when
  the database itself is unavailable.

### 8.5 Deletion and active recorders

In v1, conversation delete and Clear reject any target with a `queued`,
`starting`, or `running` turn or an active service lease. This check and database
delete occur through the conversation service; CLI deletion applies the same
nonterminal-turn check in its transaction only after obtaining the library
Assistant execution lock, and otherwise fails as busy. A future cancel-and-delete
action must first revoke the lease and await the recorder's final flush before
deletion.
The same lock token is required by every app/CLI database API that can delete or
scrub a scheduled job/run, cascade a linked transcript, or change
`assistantTranscriptState`; this explicitly includes scheduled-job Delete and
run-result Delete, not only `assistant-conversations delete/clear`. Job edits
that cannot touch run/transcript rows remain outside this restriction.
Recorder upserts may update only existing conversation/turn rows and must never
recreate a missing parent, so a cross-process delete race fails visibly without
resurrection. An idle open controller observes external deletion, invalidates its
local conversation ID, and starts a fresh empty conversation ID before a later
send; it does not replay the deleted transcript. `beginConversation` may insert
only an ID explicitly registered as new, never a deleted resume target.

## 9. Read, History, and resume paths

### 9.1 Normal History

Home and reader History query `assistantConversation` and the first/last visible
entries. They do not call the provider seams `recentSessionsResult`,
`searchSessionsResult`, or `sessionTranscript` (the bare recent/search methods
are convenience wrappers).

- Home defaults to `contextKind == library` in the current workspace.
- Reader History defaults to the current `referenceId`, with the existing
  **All documents** option mapping to the workspace.
- Search uses the local FTS projection in §7.6 for normalized user/assistant
  bodies and document-card titles. Tool details and notices are excluded.
- Selecting a row loads the local transcript immediately and sets
  `latestProviderSessionId` as the continuation target.
- A provider process starts only when the user sends the next turn.

### 9.2 Scheduled runs

Every new scheduled run creates its conversation before provider dispatch and
links it through `scheduledJobRunId`.

Activating a running row opens a read-only Home transcript backed by database
observation. It does not create a second provider wrapper, resume the provider
thread, or subscribe directly to the runtime. Cancel remains routed to the
single scheduled runner owner.

After terminal completion, the transcript remains readable. Continue stays in a
bounded **Finishing…** state until the scheduled execution's identity gate closes
or teardown proves that no later session ID can arrive. If the provider session
ID then exists, **Continue** first creates/deduplicates the ordinary child and
atomically transfers continuation binding as specified in §7.1; the scheduled
conversation stays an immutable run result. The broker then resumes the provider
session with interactive posture if the scheduled read-only process configuration
differs. Reopening Continue navigates to the existing child rather than creating
another. If that child was deleted, the stamped result shows **Continuation
deleted locally** and leaves reimport/resume to explicit Provider History rather
than silently recreating it.

`ScheduledJobProgress` becomes a bounded view projection over persisted entries,
not the only copy of live content. It may retain an in-memory cache for animation,
but correctness cannot depend on that cache.

### 9.3 Provider History and legacy import

Add an explicit **Provider History…** action below local History. It is the only
normal History UI that calls provider list/search/read APIs; the sole automatic
exception is a one-time open of a migrated `legacyEligible` scheduled run.

Policy:

1. Provider History is never fetched automatically on Home/reader mount.
2. It is unavailable while an interactive or scheduled Codex turn is active.
3. A user request enters the broker's metadata lane with a short overall deadline.
4. Selecting a provider conversation first snapshots its alias as specified in
   §7.5. A live local owner opens immediately with no transcript fetch or
   mutation. V1 intentionally provides no implicit refresh of an owned transcript.
5. For an absent alias or an explicitly selected tombstone, fetch and normalize
   the provider transcript before changing panes. The commit validates the
   pre-fetch alias snapshot, inserts the conversation/transcript, and claims the
   alias in one transaction. A concurrent live owner wins; a deletion or revision
   change aborts the older import intent rather than resurrecting it.
6. Successful import behaves like local History.
7. Failure leaves the current pane untouched and offers Retry.

Existing scheduled runs without a local conversation use this same importer.
It first resolves the alias locally. A live owner consumes eligibility without a
provider call and opens that existing ordinary/continuation conversation; it is
not converted to a run-owned row, and the run records an **Already in Local
History** resolution. A tombstone likewise records the local-deletion
explanation. Each outcome compare-and-swaps `legacyEligible` to
`legacyAttempted` and stores `alreadyLocal` or `deletedLocal` atomically; a loser
reloads the winner. Neither outcome enters the broker, and `deletedLocal` offers
Provider History rather than inline Retry. For an absent alias, pre-admission
busy/unavailable leaves `legacyEligible` because no provider request began.
Immediately before its first RPC write, the admitted work atomically consumes
`legacyEligible` into `legacyAttempted`; only the compare-and-swap winner performs
provider traffic. Successful import links the conversation and moves the run to
`available` in the same transaction. Failure, post-admission cancellation, or
launch recovery leaves `legacyAttempted`, stores the corresponding transcript
status code without changing the run's execution failure, retains the run
metadata, and offers an explicit **Retry import**; ordinary reopen never retries.
Retry first
compare-and-swaps `legacyAttempted` to `legacyRetrying`, so double-clicks or
separate windows cannot issue two fetches; its terminal paths return to
`legacyAttempted` or advance to `available`, and launch recovery repairs an
abandoned retry. Inline Retry does
not reclaim an alias tombstone. Re-creating content after a local deletion
requires a newly selected Provider History row, whose explicit tombstone-reclaim
transaction imports an ordinary conversation and does not silently relink the
run. `deleted` means the user deliberately removed the local transcript and must
never trigger automatic reimport; show **Local transcript deleted** and leave
explicit Provider History as the only reimport path. Automatic legacy import
treats an alias tombstone as a consumed/deleted local projection and does not
reclaim it.

The current `assistant-session-attribution.json` remains a read-only legacy index
during migration. Its hashed keys can seed `assistantSessionAlias` and metadata
stubs where possible, but a one-way hash cannot recover a provider session ID or
workspace identity. Such `legacyStub` rows are non-continuable and excluded from
normal History until an explicit provider listing supplies a raw session ID whose
recomputed key matches. Migration must not scan or parse every provider
transcript. Remove the JSON writer only after new-session DB attribution and the
legacy importer have shipped and been validated.

A future **Import all from this workspace…** bulk action may run the same bounded,
transactional importer over provider pages. It is useful migration UX but not a
prerequisite for replacing automatic provider History.

### 9.4 Provider loss and continuation failure

Local History remains readable when Claude/Codex is missing, signed out, or has
pruned the session. The composer explains why continuation is unavailable and
offers Recheck. A later **Continue as new conversation** feature may seed a new
provider thread from a bounded visible transcript, but that is not part of this
design and must not be silently substituted for native resume.

## 10. Codex runtime broker

### 10.1 Responsibilities and component split

Replace the `CodexAppServerConnection` actor currently embedded in
`CodexProvider.swift` with five focused components:

```text
CodexRuntimeBroker (app-lifetime actor/state machine)
  ├── CodexWorkScheduler       priority/admission/ownership
  ├── CodexProcessGate        exclusive root-process launch/reap lease
  ├── CodexServerTransport     one root generation + connection/RPC correlation
  ├── CodexTurnAdapter         thread/turn/approval → AgentEvent
  └── CodexMetadataAdapter     explicit provider History + model/list
```

`CodexServerTransport` knows process generation, connection IDs, request IDs,
handshake state, stdout/stderr drains, and reaping. It can implement one stdio
connection or multiple connections to a Rubien-owned Unix-socket listener without
changing broker callers or the work-identity contract. It does not know about
Home, History scope, scheduled jobs, or renderer events.

`CodexRuntimeBroker` knows work purpose, priority, process posture, and legal
state transitions. It does not decode transcript item shapes or render events.

`CodexProcessGate` grants the exclusive lease for every Rubien-launched Codex
root process that shares the resolved binary and the user's Codex home. The live
app-server, `--version`/auth checks, and scheduled MCP-isolation discovery all use
this gate in production. A higher-priority turn may cancel a standalone probe,
but receives the lease only after that probe's process group is reaped.

`CodexTurnAdapter` owns one admitted turn's thread/turn IDs, approvals, provider
notification routing, and provider-neutral event mapping.

`CodexMetadataAdapter` implements the explicit legacy importer and model catalog
through broker-owned metadata work. Under the initial stdio policy it cannot
obtain a transport while a turn is admitted; a proven multi-connection topology
may grant only its dedicated metadata connection without weakening work identity
or turn-ownership rules.

### 10.2 Work classes

```swift
enum CodexWorkPurpose {
    case interactive(ownerID: UUID, conversationID: UUID, turnID: UUID)
    case scheduled(runID: String, conversationID: UUID, turnID: UUID)
    case metadata(kind: MetadataKind, requestID: UUID)
}
```

Conservative stdio admission policy (the socket/daemon spike may relax only
metadata overlap, not turn ownership or reservation rules):

| Existing work | Incoming interactive | Incoming scheduled | Incoming metadata |
|---|---|---|---|
| none/idle | admit | admit | admit |
| metadata | preempt metadata, initiate reap, then admit | preempt metadata, initiate reap, then admit | supersede older metadata or coalesce identical work |
| interactive turn | fail fast as busy for another surface | queue FIFO | return unavailable/retry; do not queue stale UI work |
| scheduled turn | show busy/running-job notice; do not kill it | queue FIFO | return unavailable/retry |
| reaping/recovery | honor an existing reservation, otherwise reserve interactive | honor an existing reservation, otherwise reserve scheduled | return unavailable/retry |

Priority applies before admission. Once an interactive or scheduled turn has
started, it is not preempted by another surface. Stop/cancel remains token-scoped
to the owner.

Priority must not starve a durable claimed run. Interactive work may win while a
scheduled occurrence is merely due but unclaimed. Once the coordinator claims a
run and the broker accepts its reservation, that reservation is the next turn
after any already-admitted/reserved turn; later interactive requests receive a
bounded busy/queued state and cannot leapfrog it. A reservation survives
metadata reap and configuration restart, but is released if the run is cancelled
or its durable claim is lost. Tests use event order, not wall-clock timing, to
prove this bound.

### 10.3 Explicit runtime states

```swift
struct CodexActiveRuntimeState {
    let generation: Int
    let configuration: SpawnConfiguration
    var turn: RunningTurn?
    var metadata: RunningMetadata?
}

enum CodexRuntimeState {
    case stopped
    case probing(generation: Int, workID: UUID, kind: CodexProbeKind)
    case starting(generation: Int, purpose: CodexWorkPurpose, configuration: SpawnConfiguration)
    case ready(CodexActiveRuntimeState)
    case reaping(generation: Int, reason: ReapReason, next: ReservedWork?)
    case blocked(reason: RuntimeBlockReason)
}
```

Under the stdio policy, `ready` may have a turn or metadata work but never both.
The representation deliberately permits both slots so a proven multi-connection
socket policy does not require redesigning the broker state; each slot still has
exactly one work ID/owner and dedicated connection routing. `ready` with both
slots nil is the former idle state.

All subprocess callbacks, including standalone probe completion, carry
`generation` and `workID`. A callback that does not match the current state is
stale and cannot mutate the runtime or a transcript.

Avoid actor methods that perform a multi-step state transition while suspended.
The broker records a transition synchronously, starts an asynchronous operation,
and receives its tagged completion as a new event. This event-loop shape makes
reentrancy explicit: only `handle(event:)` changes runtime state.

### 10.4 Process-generation cancellation

Metadata cancellation follows one rule:

> Under the verified stdio policy, once a metadata JSON-RPC request has been
> written, that app-server generation cannot admit a turn until every sent
> metadata request has completed or the process tree has been killed and reaped.

Therefore:

- superseding metadata before it is written only removes it from the queue;
- superseding it after write marks the work cancelled and either waits for its
  prompt response or kills the process when higher-priority work arrives;
- an interactive or reserved scheduled arrival always kills/reaps a generation
  with unfinished sent metadata, then starts on a clean generation;
- late stdout from an old generation is ignored;
- closing a client connection is not treated as cancellation: Codex 0.145.0's
  connection RPC gate explicitly lets handlers that already acquired a token
  finish;
- no new process spawns until the prior leader has a confirmed wait status and
  its process group no longer exists;
- failure to reap moves the broker to `blocked` and fails closed instead of
  creating overlapping app-servers.

This conservative rule replaces method-specific `isHistory` flags and
abandoned-request sets with a transport-wide invariant. The Phase D spike may
prove that unfinished metadata and a turn can safely coexist in one socket
listener, but it must not claim that connection teardown cancelled
already-started work.

`CodexProcessGate` retains the dedicated positive process-group ID recorded at
spawn independently of the leader PID and refuses group operations unless that
identity is valid.
After `SIGTERM` and the bounded grace interval it escalates the whole group with
`SIGKILL`. Do not reap the leader immediately: observe its exit with
`waitid(..., WEXITED | WNOWAIT)` so its PID continues to reserve the PGID, then
use a platform `ProcessGroupInspector` (macOS `KERN_PROC_PGRP`/libproc behind a
testable adapter) to wait until no non-leader group members remain. Only then reap
the leader and release the gate. `kill(-pgid, 0)` is a supplemental signal/probe,
not sole identity proof after reap. If membership cannot be established within
the bound, move to `blocked`; a numeric PGID observed after leader reap is never
assumed to identify the original group.

### 10.5 Spawn configuration

`webAccess`, `loadUserTools`, and scheduled `readOnlyLibrary` posture are
process-scoped today. The broker records them in `SpawnConfiguration`.

- matching configuration reuses an idle server;
- different configuration transitions through `reaping` before a new spawn;
- metadata may reuse an idle configuration only when no turn is admitted and its
  adapter requires no posture change;
- scheduled isolation discovery happens before `starting` is committed or as a
  tagged start substep; failure cannot leave a half-owned server;
- Settings binary-path changes are adopted through an explicit broker restart
  when idle or on next launch, never silently ignored by a registry key.

### 10.6 Model catalog and availability

Model discovery remains optional picker metadata:

- cache the last successful catalog locally, keyed by resolved binary path and
  exact `codex --version` output;
- refresh through the metadata lane only when the picker needs it or the user
  explicitly rechecks;
- show the cached catalog while refresh is pending;
- never block `send` on catalog refresh;
- under the stdio policy, an interactive arrival preempts an in-flight
  `model/list` generation; a selected multi-connection policy must still prove
  zero send delay before allowing overlap.

Binary/version/auth probes stay single-flight and bounded, and every production
launch acquires `CodexProcessGate`; tests may inject an isolated gate. Production
`CodexProvider.isAvailable()` and Settings Recheck must route through the broker's
availability service instead of calling `AgentBinaryProbe` directly.

- If a standalone cold probe owns the gate when a turn arrives, cancel it, reap
  it, and reserve the lease for the turn before spawning app-server.
- If app-server is already live and idle, use its recorded binary/version and
  current health, and use `account/read` where supported for authentication
  state, rather than launching concurrent `codex --version` or login-status
  processes. During a turn, the stdio policy reports Recheck busy/deferred.
- A cold Recheck may still need a bounded standalone version probe or app-server
  startup on older compatible Codex versions; it uses the same gate and does not
  prove that `--version` caused the historical metadata startup race.
- An explicit Recheck may recycle an idle app-server before probing. During an
  admitted turn it reports busy/deferred and must not kill the healthy turn.
- Scheduled MCP-isolation discovery is a standalone Codex process and follows
  the same lease/reap rule before the scheduled app-server starts.
- The first failed probe may still retry once, but cleanup and lease release must
  complete before retry. A second caller joins that same probe instead of
  launching another process.

This makes the repeated “first Recheck fails, second succeeds” symptom a tested
ownership invariant rather than a timing workaround.

### 10.7 App-level ownership

Construct one `CodexRuntimeBroker` and its `CodexProcessGate` in the application
composition root and inject lightweight client handles into Home, readers,
Settings, and the scheduler. Do not let each `CodexProvider` acquire a
process-wide singleton whose first caller silently pins immutable configuration,
and do not leave any production Codex launch path outside the gate.

Client handles contain owner IDs and token-scoped cancellation only. Closing a
window releases its handle and interrupts only its active turn; it does not own or
tear down the app-level broker. Application termination performs the final broker
shutdown.

### 10.8 Required socket/daemon spike before Phase D

Codex 0.145.0 adds Unix-socket and WebSocket transports, multiple initialized
connections to one server process, `account/read`, and separately managed
`app-server daemon`/`proxy` commands; see the official
[app-server documentation](https://learn.chatgpt.com/docs/app-server). Two
lifecycles must not be conflated:

1. **Rubien-owned socket listener (preferred candidate):** launch the selected
   binary as `codex app-server --listen unix://<rubien-private-path>`. It remains
   Rubien's child/process-group root, uses the broker's exact configuration, and
   can accept dedicated turn and metadata connections while satisfying D7.
2. **Codex-managed daemon:** `codex app-server daemon start` launches a detached
   [`setsid()` process](https://github.com/openai/codex/blob/rust-v0.145.0/codex-rs/app-server-daemon/src/backend/pid.rs), stores global lifecycle state under
   `$CODEX_HOME/app-server-daemon`, and may use Codex's managed app-server install.
   The short-lived lifecycle command is not the daemon's process-group owner, and
   other clients may share it. Rubien must not adopt or stop this daemon unless a
   later policy specifies PID-plus-start-time ownership, selected-binary/config
   parity, coexistence with non-Rubien clients, upgrade behavior, and stop
   authority.

The first topology is the only candidate that preserves the current
single-Rubien-owned-root-process invariant without expanding Rubien's authority,
but being a child is insufficient after the Rubien app crashes. It is adoptable
only through a Rubien-owned bootstrap/watchdog protocol; a state file written
after an ordinary spawn has an unrecoverable spawn-to-`fsync` crash window.

The watchdog stays **outside** the target listener process group and holds the
child-lifecycle lock plus an app-lifetime pipe/port whose disappearance means
Rubien died. It spawns a separate listener wrapper as the positive process-group
leader; that wrapper waits behind a start gate before it can exec Codex or listen.
The watchdog atomically writes and `fsync`s both file and parent directory for a
private record containing a random instance ID, watchdog and listener PIDs plus
kernel process start times, positive listener PGID, resolved
executable/configuration hash, and socket identity. It verifies the wrapper's
current PGID equals its recorded PID/PGID, then releases the wrapper to exec
`codex app-server --listen ...`. Start-gate EOF is an abort, so watchdog death
before durable release cannot create an unrecorded listener.

If the app endpoint disappears, the out-of-group watchdog sends TERM/KILL to the
exact target group, observes the leader without immediately reaping it, waits
until no listener/helper member remains, reaps the leader, removes and `fsync`s
the runtime record/socket directory, and only then releases the lifecycle lock
and exits. Normal app shutdown uses the same cleanup path.

On restart, the app must acquire the library execution lock and the child-
lifecycle lock before recovery or spawn. A normally completed watchdog cleanup
leaves no record. If a prior record remains after the lock is acquired, recovery
may signal the group only when the recorded listener PID plus start time and
executable identity are live **and its current PGID equals the recorded PGID**.
If that exact leader is absent and the process-group inspector finds no member of
the recorded PGID, recovery may remove the stale record/socket as already clean.
Any other combination—including members under the numeric PGID without the exact
recorded leader—is ambiguous and enters `blocked` without signalling. After an
identified group is reclaimed, recovery proves all members disappeared, removes
and `fsync`s the record/socket directory, and only then starts a new watchdog.
The start gate plus lifecycle lock closes both the pre-record and record/spawn
races.

A stale socket or numeric PID/PGID alone is never ownership proof. If prior
identity or group disappearance cannot be established, the broker enters
`blocked` rather than overlapping listeners. The spike must validate this
bootstrap/watchdog and reclamation protocol under forced app death before a
socket policy can satisfy D7. Neither topology removes the broker.

There is one important negative result already: the tagged 0.145.0
[`ConnectionRpcGate`](https://github.com/openai/codex/blob/rust-v0.145.0/codex-rs/app-server/src/connection_rpc_gate.rs)
closes admission for queued handlers while allowing handlers that already began
to finish. Therefore disconnecting the metadata client is **not** a demonstrated
request-cancellation primitive.

Before Phase D freezes `CodexServerTransport`, run a version-exact spike against
the oldest supported compatibility baseline (currently 0.142.5) and the current
supported Codex release. It must measure and record:

1. direct Unix-listener and daemon/proxy availability plus fallback behavior on
   the older baseline;
2. independent initialization and notification routing across two connections;
3. `thread/list`, `thread/read`, and `model/list` overlapping a real turn, both on
   unrelated and resumed threads;
4. what happens to each request, subscription, approval, and turn when either
   connection closes;
5. configuration/sandbox/MCP isolation and whether one connection can mutate
   process-wide posture used by the other;
6. direct-listener crash, forced Rubien-app death, PID/start-time and instance
   validation, app restart, private/stale socket cleanup, and complete prior-group
   disappearance without PID/PGID-reuse mistakes;
7. whether `account/read` can replace warm auth probes without changing cold
   availability behavior;
8. if the managed daemon is evaluated at all, its actual binary/config selection,
   PID/start-time record, proxy failure, other-client coexistence, upgrade, and
   stop semantics without claiming its detached process group as Rubien's child.

Adopt multiple connections first through the Rubien-owned listener, and only if
the spike proves notification/configuration isolation, bounded recovery,
compatibility fallback, private socket permissions, and no turn-latency
regression. Even then, the broker retains work identity, reservations, attempt
leases, and one-root-tree ownership. If unfinished metadata can safely run
concurrently, the selected transport may relax process retirement; if not, retain
the conservative generation rule in §10.4. Experimental WebSocket support and
the detached managed daemon are not required dependencies when the direct Unix
listener suffices.

### 10.8 Transport spike record (2026-07-22)

Codex CLI 0.145.0 exposes `--listen unix://PATH`, creates the socket with mode
`0600` inside a caller-owned `0700` directory, accepts two independently
initialized WebSocket clients, and routes `model/list` on one connection while
the other remains initialized. Interrupting the listener removed the socket.
The separately documented `app-server proxy --sock` was not a transparent client
for a directly launched listener in this configuration; a direct WebSocket
client was required.

This is useful evidence for the preferred topology, but it does not satisfy the
full matrix above: the 0.142.5 baseline, real and resumed turns, approval routing,
posture isolation, request-close behavior, watchdog recovery, and complete
process-group reclamation remain unproven. Phase D therefore retains the
conservative stdio transport. The broker extraction must not claim metadata/turn
overlap or adopt the Unix listener until the remaining evidence and watchdog
protocol land.

## 11. Provider-neutral event contract

The current `AgentEvent` is sufficient for rendering but lacks stable identity
for durable idempotent updates. Extend the internal stream envelope rather than
placing database concerns in provider decoders:

```swift
struct AssistantAttemptIdentity: Sendable, Equatable {
    let conversationID: UUID
    let conversationEpoch: Int
    let turnID: UUID
    let workID: UUID
    let runtimeGeneration: Int?
}

struct AgentEventEnvelope: Sendable {
    let attempt: AssistantAttemptIdentity
    let providerItemID: String?
    let event: AgentEvent
}
```

The turn service assigns `workID` before provider dispatch. Codex supplies its
broker generation; Claude supplies the generation of its per-turn process (or
`nil` only for imported historical events, which never enter a live recorder).
Provider adapters supply native item IDs where available. The turn service
assigns a stable synthetic ID for identity-less logical items and reuses it for
their updates. UI rendering may continue switching over `AgentEvent`;
persistence consumes the envelope.

Approval IDs remain provider request IDs and are not transcript-entry IDs.
Tool-start/tool-complete pairing should migrate from name-based FIFO matching to
provider item identity where each backend exposes it. The FIFO fallback remains
only for older/identity-less events: it deterministically completes the oldest
open item of that name and surfaces an unmatched completion as degraded notice
rather than rewriting an already-completed item. It cannot reconstruct semantic
pairing that the provider never identified.

This adapter/identity seam lands in Phase B with durable capture. Phase D may
extract the Codex transport implementation, but must not invent a second event
identity layer or postpone native IDs until after the recorder ships.

## 12. Scheduled execution integration

`ScheduledJobRunner` should use the same `AssistantConversationService` as an
interactive controller but with a headless transcript sink and scheduled broker
work purpose. `ScheduledJobRunner` emits normalized envelopes;
`ScheduledJobCoordinator` owns the observable, bounded in-memory projection, while
SQLite is the durable source.

Execution order:

1. claim the durable scheduled run and obtain its non-starvable broker
   reservation;
2. create/link `assistantConversation`, its first `assistantTurn`, and execution
   lease;
3. mark the scheduled run and turn started in one transaction;
4. submit scheduled provider work with the reserved work ID;
5. persist every normalized event through the recorder;
6. claim the alias and update `providerSessionId` on run metadata plus
   `latestProviderSessionId` on conversation in one transaction when emitted;
7. atomically persist the final entry, finish the turn/run, and set transcript
   state `available`;
8. publish notification/unread state only after durable finish.

Failure before provider dispatch releases the reservation and terminally updates
or recovers the durable claim; it cannot leave an invisible claimed run holding
the scheduler indefinitely.

If the provider succeeds but transcript finalization cannot commit, neither the
turn nor run becomes terminal. The coordinator shows the storage failure in
memory, performs a bounded retry, and leaves launch recovery an unambiguous pair
to mark as an interrupted turn/failed run rather than advertising an unreadable
success.

Opening a running run observes SQLite and never competes for the provider runtime.
This directly enables click-through live progress from Agent Home.

## 13. UI behavior

### 13.1 History

- Open instantly from local metadata; show a local loading skeleton only for the
  SQLite read, not a provider spinner.
- A conversation row can show provider, context, latest time, scheduled badge,
  and a first-user-message preview derived from normalized entries.
- Search results load locally and preserve current document/all-documents scope.
- **Provider History…** is visually secondary and explains that it may be slower
  and requires the provider runtime to be idle.
- Imported legacy conversations receive a small one-time **Imported** badge, not
  a permanent separate rendering mode.

### 13.2 Live scheduled run

- Opening a running row displays persisted entries and a **Running** status.
- The composer is disabled while the scheduled owner holds the turn.
- New entries appear through database observation within the 500 ms target.
- Cancel acts on the scheduled runner; closing the view does not cancel.
- After completion, normal continuation controls become available if the provider
  session is resumable.

### 13.3 Failure and degraded states

Use precise, actionable states:

- **Transcript unavailable locally** — storage/create failure; conversation may
  continue ephemerally only for an interactive turn.
- **Conversation is active** — delete/Clear is rejected until its live turn
  finishes or is explicitly stopped and its recorder lease drains.
- **Assistant active in another Rubien instance** — transcripts remain readable,
  but this process cannot recover, send, schedule, import, Retry, delete, or Clear
  Assistant state until it acquires the library execution lock.
- **Provider unavailable** — local transcript readable; continuation disabled.
- **Provider History busy** — a foreground/scheduled Codex turn owns the runtime;
  explicit Retry remains available.
- **Older run has no transcript ID** — a pre-capture run without a usable
  provider session remains visible but cannot offer automatic import.
- **Legacy import needs attention** — `legacyAttempted` shows its precise failure
  and explicit Retry; `legacyRetrying` disables duplicate Retry controls.
- **Finishing session identity** — a terminal scheduled transcript is readable,
  but Continue waits for identity ownership to drain or teardown to prove closure.
- **Codex runtime recovering** — a killed generation is being reaped; a reserved
  interactive turn waits with bounded progress.
- **Codex runtime blocked** — predecessor could not be reaped; do not spin or spawn
  another process. Recheck may retry only after process liveness is resolved.

Generic “ended unexpectedly” remains a last-resort crash notice, not the message
for known admission, timeout, storage, or recovery states.

## 14. Privacy, security, and deletion

- Transcript tables are local-only in the library SQLite database. They inherit
  the same filesystem protection as Rubien notes/reference metadata; the product
  must not claim additional at-rest encryption.
- No transcript table receives CloudKit dirty triggers. `RubienSync` schema
  invariants must confirm the tables are absent from synced entities.
- Conversation content is never added to `assistantActivity`; analytics continues
  to store only its approved metadata fact.
- Persist only content already rendered to the user. Hidden reasoning, ignored
  notifications, provider configuration, environment variables, and raw MCP
  payloads are excluded.
- Absolute attachment staging paths and thumbnail data URLs never enter
  transcript payloads. Managed attachments use the validated conversation-local
  DTO and path policy in §7.4.
- Deleting one conversation removes its conversation/turn/entry/attachment and
  FTS rows plus its managed attachment/cache directory. It retains only the
  revisioned, one-way-hash alias tombstones required by §7.5 to make concurrent
  deletion win over an older import; no raw provider ID or content remains.
  Provider History remains untouched, and confirmation text says so.
- Deleting a scheduled job intentionally cascades its runs and local
  run-owned transcripts/attachments, but never ordinary continuation children;
  deleting one terminal run deletes its linked local result, marks
  `assistantTranscriptState = deleted`, and then retains the scrubbed recurrence
  tombstone. Conversation Delete/Clear applies the same state transition to
  linked surviving runs. Both confirmations distinguish local data from provider
  History.
- **Clear Assistant Conversations…** deletes local transcript conversations and
  managed attachments, but does not clear Assistant activity statistics or
  provider History. **Clear Assistant Activity…** remains a separate metadata
  operation and does not delete transcripts.
- Transcripts have no automatic age- or size-based eviction in v1. They remain
  until the user deletes a conversation, deletes its scheduled-run result, or
  uses Clear; list and transcript reads are paginated so retention does not imply
  loading the full corpus into memory.
- SQLite/WAL, filesystem snapshots, and backups mean deletion is logical, not a
  guarantee of forensic secure erasure.
- Direct CLI reads require the same local filesystem/library access as other
  Rubien data. MCP does not receive a conversation-search tool in this scope.

## 15. Alternatives considered

### 15.1 Continue patching the shared actor

Rejected as the long-term design. The immediate abandoned-request marker is
correct and should ship, but each new metadata method would need to remember the
same lifecycle rule. The component still mixes scheduling, transport, UI work,
and recovery.

### 15.2 Run a second metadata app-server concurrently

Rejected as the default. Earlier model-discovery behavior reproduced startup
interference when an independent metadata app-server raced the first real turn
against the same Codex home. That is empirical Rubien evidence, not a claim that
Codex can never coordinate two processes. Rubien has no verified cross-version
contract for shared-home concurrency, so separate root trees remain serialized
and fully reaped by policy.

### 15.3 One socket listener with separate turn and metadata connections

Open pending the required §10.8 spike. Codex 0.145.0 lets Rubien launch its
selected app-server binary directly on a private Unix socket and initialize
multiple connections, which may isolate routing and remove some head-of-line
latency while preserving the single-Rubien-owned-root-process invariant. It does
not establish connection-close cancellation: already-started handlers continue. This
topology may replace the stdio transport mechanism in Phase D, but not the
broker, recorder, attempt identity, admission policy, or recovery model. The
separately managed detached Codex daemon is a distinct alternative and remains
out of scope unless the ownership questions in §10.8 are resolved.

### 15.4 Parse Codex's on-disk thread store directly

Rejected as the primary source. It would remove app-server History traffic but
couple Rubien to an internal storage format and still would not provide durable
scheduled progress while a turn is running.

### 15.5 Persist raw provider event logs

Rejected. Raw logs are version-specific, contain more sensitive/internal data,
and force replay code to understand obsolete provider schemas. Persist the stable
visible projection instead.

### 15.6 Keep provider-owned History and use an ephemeral server for every read

Rejected. It reduces contamination but retains slow provider-dependent UI,
cannot show durable live scheduled progress, and repeatedly pays spawn/handshake
cost. It is suitable only for the explicit legacy importer.

### 15.7 Prompt-replay continuation from the local transcript

Rejected as an automatic behavior. A rendered transcript omits hidden provider
state, tool results, and instructions, so replay is not equivalent to native
resume. Local content is for presentation; provider IDs remain for continuation.

### 15.8 OpenClaw comparison

OpenClaw is a useful production precedent, but its runtime boundary is not the
same as Rubien's current one. At
[`5e651d5`](https://github.com/openclaw/openclaw/tree/5e651d5ac76ce2ad41e1a0205bed210f818ad8b9),
OpenClaw has four relevant mechanisms:

1. It explicitly keeps an OpenClaw-owned
   [transcript mirror](https://github.com/openclaw/openclaw/blob/5e651d5ac76ce2ad41e1a0205bed210f818ad8b9/docs/plugins/codex-harness-runtime.md#compaction-and-transcript-mirror)
   for channel History, search, reset, and runtime switching while Codex remains
   authoritative for native continuation and compaction.
2. Its
   [shared-client registry](https://github.com/openclaw/openclaw/blob/5e651d5ac76ce2ad41e1a0205bed210f818ad8b9/extensions/codex/src/app-server/shared-client.ts)
   is a map keyed by immutable start/auth/agent identity. Acquires hold explicit
   leases; graceful retirement waits for active leases and pending acquires to
   drain, while a suspected client can fail its leaseholders immediately.
3. Its
   [session-binding store](https://github.com/openclaw/openclaw/blob/5e651d5ac76ce2ad41e1a0205bed210f818ad8b9/extensions/codex/src/app-server/session-binding.ts)
   gives each logical conversation an atomic, renewable ownership lease so a
   stale run cannot replace the current thread binding.
4. Per-attempt lifecycle code adds terminal-progress watchdogs, best-effort
   interrupt, bounded cleanup, and poisoned-client retirement when app-server
   accepts a turn but stops producing terminal progress.

OpenClaw also normally gives the harness an agent-scoped Codex home and bridges
the selected auth profile into it. It does not simply make every UI surface and
metadata read share the user's native CLI thread store. That isolation lets it
pool clients by immutable configuration without reproducing Rubien's observed
same-home startup interference.

The precedent supports adopting transcript mirroring, stable conversation/thread
bindings, explicit attempt leases, watchdogs, and generation retirement here.
It does **not** justify copying OpenClaw's multi-client pool while Rubien still
uses the user's real Codex home and user configuration. A future managed
`CODEX_HOME` design could revisit keyed concurrent clients, but it must first
specify auth bridging, user-plugin/config behavior, native History visibility,
and migration. The local transcript/service boundary in this proposal remains
valid under either process policy.

OpenClaw's own incidents are also instructive. Its earlier single shared-client
replacement behavior could strand an overlapping turn
([issue #80618](https://github.com/openclaw/openclaw/issues/80618)), and it added
a watchdog after an accepted turn failed to emit a terminal notification
([issue #75205](https://github.com/openclaw/openclaw/issues/75205)). The lesson is
not that app-server needs no defensive architecture; it is that mature clients
make ownership and recovery explicit and regression-test the failures they have
observed.

## 16. Migration and compatibility

1. Add local transcript tables in the next migration; never edit `v8`/`v9`.
2. Do not parse provider histories during migration or app launch.
3. New Rubien conversations begin durable capture immediately after the schema
   ships.
4. Existing scheduled runs retain `providerSessionId`. A visible run is
   `legacyEligible` only when that ID is usable; one without an ID becomes `none`
   and shows that no pre-capture transcript is available instead of offering a
   doomed import. Opening an eligible run invokes the importer automatically
   once. After broker admission and immediately before the first RPC write, it
   consumes that state to `legacyAttempted`, then either links the resulting
   local conversation and marks it `available` atomically or requires an
   explicit retry after failure. Pre-admission busy/unavailable does not consume
   eligibility.
5. Existing hidden scheduled-run tombstones do not receive conversations. After
   migration, the user-facing run Delete transaction deletes any linked
   conversation before scrubbing/hiding the run row.
6. Scheduled-job Delete keeps its current physical job/run cascade and extends
   confirmation copy to local transcripts and attachments. Provider History is
   never included in that cascade.
7. Existing attribution JSON remains available for classifying legacy provider
   results. Migrate hashed aliases and non-visible `legacyStub` rows
   opportunistically, not destructively; do not guess a workspace/session ID from
   a one-way hash.
8. History may temporarily show two sections: **Rubien Conversations** and
   **Provider History…**. Do not merge rows until alias matching is deterministic.
9. Provider session deletion never cascades into Rubien because it is external.
10. Removing a local conversation never issues provider deletion commands.

The migration creates no transcript for conversations that Rubien did not
observe. This is an honest boundary, not data loss.

## 17. Implementation phases

Each phase should be a coherent buildable/tested commit series. Use the
repository's independent review and simplification workflow for every phase.

### Phase A — data foundation

- Add the next immutable migration, models, database APIs, normalized payload
  codecs, entry-grained versions, FTS projection, attachment DTO/store, deletion
  cleanup, and CLI commands/docs.
- Lock the context/origin/nullability rules, complete usage/model fields, alias
  conflict semantics, scheduled job/run cascades, and active-delete policy before
  shipping the migration. Additive migrations remain possible, but avoid known
  schema churn.
- Add database migration, CRUD, ordering, cascade, FTS, payload-version, path
  validation, and Linux compile tests.
- Do not change current History behavior yet.

### Phase B — durable capture

- Add `AssistantAttemptIdentity`, the provider item-identity adapter seam,
  `AgentEventEnvelope`, conversation execution leases, and
  `AssistantConversationRecorder`.
- Add the per-library Assistant execution lock before recovery, recorder,
  scheduled-run, or provider admission; keep non-owning app instances and CLI
  Assistant mutations read-only/fail-fast.
- Capture Home and reader user/assistant/tool/paper/notice entries.
- Integrate scheduled runner capture and replace ephemeral-only progress with a
  persisted projection plus atomic turn/run terminal writes.
- Add queued/starting/running crash recovery, late-session-ID binding behavior,
  active-delete rejection, and write-failure behavior.
- Continue provider-owned History as a fallback during this phase.

### Phase C — local History and legacy importer

- Switch normal Home/reader History, search, transcript load, and scheduled-run
  open to the local repository.
- Add explicit **Provider History…** and import-on-selection.
- Make import alias-snapshot validation, revisioned tombstone reclaim, and
  claim/deduplication transactional; existing live owners navigate without
  transcript replacement. Keep hashed legacy stubs non-visible/non-continuable
  until provider enrichment.
- Keep the old provider History implementations only behind the importer.
- Stop automatic provider History/model traffic from surface mount paths.

### Phase D entry checkpoint

- Run and publish the §10.8 socket/daemon connection spike against the compatibility
  baseline and current Codex release.
- Choose stdio-generation retirement or a Rubien-owned multi-connection socket
  listener by evidence, then
  update only the transport-specific clauses of this spec before implementation.
- Port the full existing `CodexProviderTests` behavior suite to the broker/fake
  transport harness first. Every current guard represents shipped behavior, not
  just the July 21 History regression.

### Phase D — Codex broker extraction

- Extract transport and turn/metadata adapters without changing the Phase B event
  identity contract.
- Introduce the explicit broker state/event machine and work admission table.
- Route all production Codex clients through the app composition root.
- If the checkpoint chooses a Unix listener, implement the proven
  bootstrap/watchdog, durable pre-listen identity record, and lifecycle lock as
  part of transport ownership rather than launching Codex directly.
- Make metadata generations disposable/preemptible and remove method-specific
  History ownership flags.
- Preserve exact invocation, sandbox, MCP, approval, and process-group behavior.

### Phase E — cleanup and policy finalization

- Remove the JSON attribution writer after compatibility coverage proves DB alias
  parity; retain a read-only migration path for one release if needed.
- Remove dead in-memory-only scheduled transcript ownership.
- Split or remove obsolete `AgentProvider` History methods once the legacy
  importer has its own protocol.
- Update older specs with short superseded-by notes; do not rewrite their
  historical decision records.

## 18. Verification strategy

### 18.1 Data and transcript tests

- fresh migration and upgrade from every supported schema version;
- migration marks only visible historical runs with usable provider session IDs
  `legacyEligible`; visible ID-less runs become `none`, hidden runs `deleted`;
- local-only tables have no sync triggers/CKRecord mappings;
- begin/stream/finalize persists deterministic entry order;
- mixed payload versions decode in one conversation; unknown/corrupt payloads
  fall back to body without crashing;
- duplicate, missing, and out-of-order provider item/tool events with native IDs
  are idempotent, including two tools with identical names and a tool projection
  replaced by a paper card; identity-less fallback is deterministic and degrades
  honestly when pairing is unknowable;
- delta flush followed by authoritative completion replaces the partial body;
- app-crash recovery marks queued/starting/running turns interrupted and
  preserves partial text;
- recovery moves a linked scheduled run from `capturing` to readable `available`
  while failing the run/interruption atomically; an active `none` run and a
  broken capture link fail with no transcript and become/remain `none`; recovery
  classifies pre-update state, and a valid capture with zero visible entries
  becomes an empty failed run rather than a readable partial;
- crash injection after conversation/turn insert, reservation, session capture,
  partial flush, terminal write, run finish, notification, and attachment cleanup
  leaves a transactionally valid/recoverable state;
- FTS insert/update/delete is atomic with entries, paper titles are searchable,
  excluded kinds are not, and direct SQL plus every FK-cascade deletion path
  leaves no orphan hits without invoking the recorder;
- reference deletion nulls context without deleting conversation;
- impossible context/reference combinations are rejected and null-workspace
  legacy stubs never enter normal History;
- scheduled-run deletion cascades its transcript and attachments;
- scheduled-job deletion cascades runs, transcripts, FTS rows, and attachments;
- deleting/clearing a scheduled conversation marks the surviving run `deleted`,
  and reopening it never auto-imports or resurrects content;
- interactive continuation creates one child, transfers aliases atomically, and
  survives deletion of its parent run/job with a null prelude link; deleting that
  child does not silently create a second continuation; the child's first turn
  ordinal exceeds the transferred latest-binding ordinal;
- visible entry creation/flush/import updates `lastActivityAt` atomically and
  monotonically, while late identity-only events do not reorder History;
- conversation deletion leaves only revisioned alias tombstones; a fetch begun
  against an older owner/revision cannot resurrect it, while a newly initiated
  explicit post-delete import may reclaim the exact tombstone;
- a failed/crashed automatic legacy import consumes `legacyEligible`, performs
  no provider traffic on ordinary reopen, and succeeds only through explicit
  Retry; concurrent opens issue at most one automatic fetch, while
  pre-admission busy/unavailable consumes nothing;
- live-owner and tombstone alias outcomes atomically consume eligibility with
  `alreadyLocal`/`deletedLocal`, perform no RPC, and expose Open-local or Provider
  History respectively without repeating admission on reopen;
- concurrent explicit Retry actions have one `legacyRetrying` winner; crash
  recovery returns the state to `legacyAttempted`, and inline Retry never
  reclaims a deleted alias tombstone;
- conversation deletion does not touch provider stores or Assistant activity;
- active conversation/clear deletion is rejected while buffered writes cannot
  recreate a deleted parent;
- user-facing scheduled-run Delete removes its linked conversation while
  retaining the scrubbed recurrence tombstone;
- attachment paths reject absolute, traversal, symlink-escape, mismatched-ID, and
  oversized-thumbnail cases; missing files render unavailable;
- a failed attachment-directory deletion is completed by the orphan retry sweep;
- `SQLITE_BUSY`, disk-full/write failure, and corrupt-payload paths produce the
  specified degraded state without false success;
- a scheduled mid-stream flush failure obeys retry/buffer bounds, cancels its
  provider owner, and preserves only the last durable partial result;
- CLI list/get/delete/clear JSON contracts and Linux compilation.
- CLI Assistant mutations plus scheduled job/run deletions fail with a stable
  busy result while another process holds the library execution lock; JSON
  includes both transcript lifecycle and status-code fields.

### 18.2 UI/controller tests

- History list/search/transcript load makes zero provider calls;
- selecting local History loads before any provider process starts;
- resume sends the latest provider session ID only on the next turn;
- provider missing leaves local transcript readable;
- running scheduled row streams persisted progress and closing its view does not
  cancel the run;
- storage failure is explicit and scheduled work fails before dispatch;
- cancel before session ID followed by a late same-attempt session ID preserves
  continuation without rendering late content;
- scheduled Continue remains disabled until identity ownership closes; a late
  session ID lands before transfer and cannot recreate an alias on the parent;
- a late identity from an older turn records its alias but cannot overwrite the
  newer turn's continuation binding;
- stream EOF without a terminal event leaves an interrupted/failed turn rather
  than success;
- imported provider transcript becomes a normal local row without duplicates;
  selecting Provider History for a live alias navigates without fetching or
  replacing its transcript, including a scheduled parent/continuation split;
- concurrent import of the same session, import-versus-delete, and retry after a
  rolled-back transaction each resolve through the alias owner/revision
  deterministically.
- a second Rubien process cannot run recovery or mutate Assistant state while the
  first holds the library execution lock; reads remain available, and recovery
  starts only after simulated owner death releases the OS lock;

### 18.3 Codex broker state-machine tests

Use the fake app-server to cover every transition, not only end results:

- interactive turn on stopped/idle runtime;
- identical-configuration reuse and configuration-change reap/respawn;
- metadata superseded before write;
- metadata superseded after write, followed by interactive preemption;
- metadata response arriving just before preemption permits safe reuse;
- interactive arrival during metadata-owned initialize;
- reserved scheduled arrival during metadata initiates the same preempt/reap
  sequence as interactive work;
- interactive arrival during the first `codex --version` or auth probe cancels
  and reaps that probe before app-server spawn;
- concurrent first availability checks join one probe and observe one result;
- Settings Recheck during an admitted turn never launches another Codex process;
- scheduled isolation discovery is fully reaped before app-server spawn;
- stale response/notification from an old generation is ignored;
- two interactive surfaces cannot displace one another;
- scheduled work queues behind interactive work;
- an unclaimed due job does not displace foreground work, while a claimed
  scheduled reservation cannot be leapfrogged by a steady interactive stream;
- interactive arriving during an admitted scheduled turn receives a busy state;
- server crash fails only the owning work and reaps helper children;
- process that closes stdout without exit is killed and bounded;
- a helper child that ignores `SIGTERM` keeps the group live until `SIGKILL` and
  inspector-confirmed disappearance; leader exit alone never permits respawn,
  and the leader stays unreaped until helpers are gone;
- PID/PGID reuse and inspector failure cannot be mistaken for the original
  group's clean exit;
- forced app death leaves either no listener after watchdog cleanup or a
  verifiable PID/start-time runtime record; restart reclaims that exact prior
  group and stale socket before spawn, and ambiguous identity blocks rather than
  overlapping;
- crash injection before durable runtime record, after record but before listener
  release, and after listen proves the bootstrap lifecycle lock closes every
  spawn gap; a live PID whose current PGID differs from the record is never group-
  signalled;
- the out-of-group watchdog survives TERM/KILL escalation, removes and `fsync`s
  its record/socket before lock release, and restart safely cleans a stale record
  only when both the exact leader and all recorded-group members are absent;
- failed leader/group reap blocks respawn;
- shutdown/cancel is owner-token scoped;
- no more than one fake Codex root process group exists at any assertion point;
- socket/daemon spike fixtures verify initialize/notification/close behavior and
  protocol compatibility against 0.142.5 plus the current supported Codex
  version before transport policy changes.

Retain the July 21 cached-History/superseded-read regression until provider
History leaves the normal path; then move its equivalent to metadata-importer
broker tests rather than deleting the coverage.

### 18.4 End-to-end acceptance scenarios

1. Start Home with Codex, open a paper card, open its PDF, and send **Summarize
   this document** while Home History/model metadata is pending. The reader turn
   starts on time and no metadata result changes its pane.
2. Run a scheduled paper job, open its row while running, and observe assistant
   text/tool/paper entries without resuming or creating another Codex process.
3. Restart Rubien after a completed scheduled run with Codex unavailable. The
   result remains readable; continuation is disabled with a precise explanation.
4. Search a corpus of 100,000 searchable transcript entries without starting a
   provider process; paper-title and body hits follow deterministic rank/recency.
5. Explicitly import an older provider conversation, then reopen it from local
   History with no second provider read.
6. Change Codex runtime posture between scheduled and interactive work. The old
   process is fully reaped before the new generation starts.
7. On a cold launch, trigger Settings Recheck and immediately send from Home or a
   reader. The probe is joined or preempted, the first turn starts successfully,
   and no second Codex root process overlaps it.

## 19. Performance and reliability budgets

- Local History first page: target under 100 ms for 1,000 conversations on the
  supported Mac baseline.
- Local transcript open: target under 100 ms for a 10,000-entry conversation,
  with incremental renderer loading if visual measurement requires it.
- Local FTS search: first 50 conversation hits under 150 ms for 100,000
  searchable entries on the supported Mac baseline; no payload JSON decoding in
  the query path.
- Live scheduled progress: durable and visible within 500 ms under normal load.
- Interactive admission: never waits for metadata to finish naturally; under the
  stdio policy it may wait only for bounded kill/reap/restart of the preempted
  generation.
- Scheduled admission: once durably claimed and reserved, later interactive work
  cannot bypass it; an already-admitted turn may finish.
- Process cleanup: retain the current 2-second hard bound for TERM/KILL/reap/group
  disappearance; failure blocks overlap.
- Provider metadata: bounded overall deadline, partial/Retry UI, never an
  unbounded spinner.
- Transcript writes: no main-actor synchronous SQLite I/O and no per-token write.

## 20. Observability

Add structured, privacy-preserving logs for:

- broker state transition, runtime generation, work ID, purpose, and reason;
- process PID/PGID, transport topology, connection ID, spawn configuration hash,
  initialize duration, leader status, and group-disappearance status;
- JSON-RPC method, work ID, and duration without params or response content;
- transcript recorder flush count/bytes/duration without body text;
- scheduled run ID and conversation ID, but no prompt or provider session ID;
- stale callback/recorder drops, reservation promotion, alias conflicts, and
  invariant violations.

In DEBUG/test builds, expose a broker snapshot containing state, generation,
queued work classes, and process PID. Do not expose pending request payloads.
This replaces log archaeology across unrelated PIDs with one inspectable runtime
timeline.

## 21. Acceptance criteria

The structural fix is complete when all of the following hold:

1. Normal Home/reader History and scheduled-run open perform no provider History
   RPCs or provider file reads, except the explicitly marked one-time
   `legacyEligible` compatibility import. A `deleted` run never uses that
   exception.
2. A scheduled run can be opened during execution and shows durable live progress.
3. A provider outage cannot erase or prevent reading a completed Rubien result.
4. Under the stdio policy, Codex turns cannot share a process generation with
   unfinished sent metadata. A multi-connection policy may relax this only after
   §10.8 proves isolation on supported versions; connection close is never
   treated as cancellation of an already-started handler.
5. Exactly one broker-controlled Codex root process tree exists at a time across
   app-server, availability, and isolation commands. A new generation starts only
   after the current child is reaped or an exactly identified pre-crash listener
   group has confirmed no surviving members.
6. Recovery and all Assistant mutations/provider admissions occur only while the
   process owns the resolved library's execution lock; a second Rubien instance
   cannot interrupt the first instance's live turns.
7. Broker legal transitions, scheduled reservation/fairness, and priority rules
   are exhaustively unit tested.
8. Transcript storage is local-only, contains no hidden reasoning/raw frames, and
   has explicit deletion behavior.
9. Provider-native continuation still works for Claude and Codex, including
   Claude session-ID rotation and Codex thread reuse.
10. Existing scheduled runs and provider History remain accessible through the
   explicit compatibility importer.
11. Scheduled run/turn completion is atomic, and local search/attachment storage
    meet the schema and performance rules in §§7 and 19.
12. Mac full tests, Linux-compatible core/CLI tests, browser-host tests, and sync
    schema invariants pass.

## 22. Recommended decision

Approve the combined direction, but implement it in the phases above rather than
as one rewrite. Transcript persistence delivers the largest product and
reliability gain first: local History, durable scheduled results, and live run
progress immediately remove most optional traffic from Codex. The broker phase
then replaces the remaining process-lifecycle risk with a formal invariant. Do
not freeze its transport topology until the required 0.142.5/current-version
socket/daemon spike is complete; the evidence may choose a Rubien-owned
multi-connection listener, but does not remove the broker boundary or silently
adopt the detached managed daemon.

The July 21 preemption patch should remain in the release candidate. It is a
correct guard for the current architecture and protects users while this design
is implemented; this proposal is not a reason to delay that patch release.
