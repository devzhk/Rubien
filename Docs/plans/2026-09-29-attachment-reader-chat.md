# Attachment reader chat

Add the normal chat sidebar to PDF and Markdown attachments, with separate
conversation histories and the attachment as the active document. This supersedes
the first attachment design's decision to defer reader Assistant support.

1. Add a local-only conversation attachment UUID in a new additive migration.
   Preserve primary-reference history and retain the UUID through continuation.
2. Add attachment conversation context and history filtering/restoration. New
   conversation and provider changes retain the reader's attachment identity.
3. Before dispatch, verify the attachment is still available and prepare its text
   in the assistant workspace. Pass document identity, a bounded text excerpt,
   and the full text/PDF paths as provider context; preserve existing approvals.
   Use attachment annotations and never substitute parent paper content.
4. Enable the existing sidebar, selection actions, and sizing in both readers.
5. Test document/history isolation, reopen, removal, and provider request content;
   build and inspect the isolated checkout preview. Update the design and CLI
   conversation JSON documentation for the additive local field.

Do not migrate the live library, change dependencies, commit, or implement iCloud
attachment sync in this step. Preserve unrelated edits in the shared checkout.

## Implementation and verification

- Added local v16 conversation attachment identity, scoped list/search, restoration,
  and CLI `assistant-conversations list --attachment-id` with JSON contract coverage.
- Enabled both reader sidebars and existing selection actions. Each turn verifies
  the attachment, extracts PDF pages or Markdown, and supplies its context separately
  from the visible user message. Missing or removed files block provider dispatch.
- Prepared text remains inside the Assistant workspace; symlinked output folders
  are rejected. Repeated preparation reuses existing directories safely.
- Passed 31 focused app tests, 23 Core conversation/migration tests, and 3 CLI
  contract tests. App and CLI builds passed; `git diff --check` passed.
- Visually checked PDF and Markdown sidebars in the isolated preview. Selecting
  Markdown text and clicking Ask staged the correct passage in the composer.
  Provider dispatch/history were tested with mocks; no live model prompt was sent.
- Refreshed the isolated checkout preview with the final executable from
  `.xcodebuild/Build/Products/Debug/Rubien` and its resource bundles after quitting
  the old preview. Reopened Research Notes.md and verified its Assistant sidebar.
  The installed app and live library were not changed.

## Independent review follow-up

- Fixed cancellation of detached attachment extraction. Reader teardown and New
  Conversation now cancel the worker, allowing its per-page checks to stop PDF
  extraction and release the resumed conversation's gate.
- Added regression tests that cancel during extraction, verify no provider turn
  is dispatched, and resume the original conversation through the same gate.
- The app build and all 12 focused attachment reader/chat tests passed, including
  both cancellation cases. Refreshed the isolated development preview with the fix.
