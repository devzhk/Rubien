# Assistant history bounds and provider attachment import

## Goal

Fix two post-merge review findings without changing provider-owned history:

1. Provider-history imports must not fail when distinct provider sessions contain
   the same source attachment UUID.
2. Local History previews and transcript reads must have explicit memory and
   response-size bounds.

## Decisions

- Keep `assistantAttachment.id` globally unique. It is Rubien-owned identity and
  participates in the managed-file layout; changing it to an entry-scoped key
  would require a schema migration and broaden every attachment API.
- During each provider-history import, map each distinct source attachment UUID
  to a fresh Rubien UUID. Repeated appearances inside that one transcript remain
  collapsed to the first occurrence.
- Limit normalized History previews to 240 characters. The SQL query reads only
  a bounded prefix of the first user body before Swift collapses whitespace and
  applies the final ellipsis.
- `fetchAssistantConversationDetail` becomes a bounded newest-first page read.
  Its opaque, conversation-scoped keyset cursor orders by
  `(turn.ordinal, entry.sequence)`; attachment and turn rows are fetched only
  for entries in that page. Indexed per-turn reads keep database work bounded
  even when one turn has a very large tool trace.
- The default page size is 200 and the hard maximum is 500.
- Home, reader, and scheduled-run transcripts initially render the newest page.
  A native **Load earlier messages** control fetches the next page. Older rows
  are prepended through a renderer API that preserves the reader's viewport.
- `rubien-cli assistant-conversations get` accepts `--limit` and `--cursor`.
  The returned detail includes `olderCursor`; callers repeat until it is null.

## Implementation

1. Add collision and bounded-read regression tests.
2. Remap provider attachment IDs before durable adoption and database import.
3. Add bounded preview normalization and cursor/page DTO behavior in RubienCore.
4. Update all transcript-detail callers to consume pages.
5. Add renderer prepend support and native page controls.
6. Update CLI documentation and tests.
7. Build, run renderer tests, focused Swift tests, then the complete suite.

## Acceptance

- Two distinct provider sessions containing the same source attachment UUID both
  import, retain readable independent copies, and store different local IDs.
- Summary queries never return more than 240 preview characters.
- A detail read returns at most its requested bounded page and includes a stable
  cursor when older entries exist.
- Paging yields every entry exactly once in deterministic chronological order.
- Opening a long Home, reader, scheduled-run, or CLI transcript reads only one
  page; earlier pages load only on request.
