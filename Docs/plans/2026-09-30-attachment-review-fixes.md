# Attachment review fixes

Address the validated external review before enabling attachment sync.

1. Open the shared database through a throwing startup boundary. Show Retry/Quit
   in the app and report CLI errors without a crash. Transfer the pre-open root
   lease into the database and preserve the moved-library fence.
2. Let published-file reads proceed during imports. Serialize recovery against
   readers separately, with bounded cancellable waits off the main thread. Cache
   verified file signatures within the process and invalidate on file changes.
3. Reuse extracted attachment text in a bounded process cache. Repair changed
   workspace copies and send compact context after a successful unchanged turn;
   reset on conversation/provider changes or failure.
4. Keep parent references intact in Markdown readers. Use non-persistable reader
   annotations with explicit document ownership; observe attachment renames.
5. Clarify moved-library recovery and retained removed files, correct stale design
   status, and compare migration file sizes before hashing.
6. Build and run focused storage, CLI, reader, and chat regression tests. Preserve
   unrelated work, pinned dependencies, the live library, and the installed app.

No iCloud dispatch, release, or commit is part of this change.

## Cache policy

Verification receipts remain in bounded process memory and
include device, inode, size, nanosecond mtime, and nanosecond ctime. Imports seed a
receipt; subsequent opens/status calls reuse it while the file remains unchanged.
Each new CLI process verifies independently. No synced schema fields are added.
Text extraction uses a bounded 64 MiB process cache keyed by source path, content
hash, and extractor version. Workspace copies are compared and repaired on each
send. Removal and source integrity checks still run before serving cached text.
Successful unchanged turns send document/annotation pointers. New or resumed
conversations, failed turns, and changed metadata/annotations send full context.

Removed-file byte reclamation stays tracked in the iCloud phase. Removal currently
hides the attachment and retains its bytes until acknowledgement-aware cleanup
can establish ownership.

## Verification

- Mac app and CLI builds passed. Focused tests passed: 39 storage/migration,
  44 CLI/native MCP, 15 reader/chat, and 41 browser-helper tests.
- Linux Swift 6.3.2 on Ubuntu 22.04 built the CLI and passed 79 focused storage,
  CLI, and native MCP tests. The temporary container was stopped and removed.
- npm TypeScript build and all 101 tests passed, including native/npm parity.
- Tests cover retry after a busy move, the moved-root fence, JSON-only startup
  errors, help availability, reads during imports, cancellation while waiting for
  recovery, same-size corruption with restored mtime, cached extraction repair,
  renamed reader titles, annotation ownership, and chat-context reset behavior.
- A grouped reader run exposed a fixture cleanup race: queued GRDB observations
  could read after the temporary SQLite file was deleted. Reader fixtures now use
  an in-memory database; Core tests retain disk-backed persistence coverage.
- `git diff --check` passed; pinned dependency files are unchanged. The app's
  Retry/Quit dialog builds, but has not been manually exercised in this pass.

## Follow-up review

- Replace the remaining presentation MCP handler's fatal shared-database access
  with the throwing entry point; test an error followed by ping in the same server.
- Retain bounded verification receipts while the complete stat signature matches.
  List checks existence/type/size; explicit status, reading, export, and chat keep
  content verification. Document the distinction in CLI and both MCP catalogs.
- Patch the Markdown header title without reloading HTML or restoring scroll.
- Observe attachment metadata once in the document model. The window manager uses
  that publisher for removal and full `attachment — parent` titles; attachment
  views leave native window titles to the manager.

Follow-up verification passed: Mac app/CLI builds, 45 CLI/MCP tests, 24 storage
tests, 10 reader integration tests, and all 101 npm tests. The MCP test verifies
an error response followed by a successful ping from the same server process.
The WebView test scrolls into a long attachment, renames twice, and verifies the
same paragraph remains at the same viewport position, with the DOM retained and
both native window/tab titles including the parent title. This also covers a
longer name that wraps and changes the header height. Dependency pins are unchanged.
