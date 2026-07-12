# Assistant paper mentions — implementation plan

**Date:** 2026-07-12
**Branch:** `codex/paper-mentions`
**Worktree:** `/private/tmp/Rubien-paper-mentions`

## Outcome

Typing `@` in the PDF or web reader Assistant composer opens a searchable
library popover. Choosing a result inserts `@<paper title>` into the visible
draft and sends the selected reference's stable database ID to the provider, so
comparison prompts can name several papers without relying on ambiguous title
matching.

## Constraints

- Keep the user's visible message as ordinary readable Markdown; provider-only
  IDs must not leak into the transcript or History search.
- Treat titles/authors as untrusted metadata in the provider context.
- Search SQLite off the main actor, exclude the reader's current reference, and
  debounce typing.
- Do not change the CLI/data schema: this is an Assistant UI/context feature.
- Develop in an isolated worktree because another agent is changing the same
  composer for paste/drop attachments.

## Steps

1. Add pure mention-query/token helpers and unit tests.
2. Inject a library-search closure into `ChatSessionController`; production
   wiring uses `AppDatabase`, while tests/harnesses retain a no-op default.
3. Extend the existing private provider manifest with mentioned-reference IDs
   and metadata, preserving visible History reconstruction.
4. Wire SwiftUI's macOS 15 `TextSelection` API into the composer, add a debounced
   result popover, keyboard navigation, selection insertion, and send-time
   mention snapshots.
5. Run targeted tests/build, inspect the diff, then perform the repository's
   independent review and simplify sweep before final verification.

## Integration note

The attachment branch replaces `TextEditor` with an AppKit-backed
`ComposerTextView`. Most of this branch is independent; during integration, the
small selection/query callbacks in `ChatSidebarView` should be carried into that
wrapper rather than restoring the SwiftUI `TextEditor`.
