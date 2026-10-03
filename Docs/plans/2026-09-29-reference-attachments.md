# Reference attachments implementation

Design: [reference attachments](../specs/2026-09-28-reference-attachments-design.md).

## Delivery checkpoints

- [ ] Core foundation and local reader state.
- [x] Document-specific readers, annotations, and attachment chat with separate history.
- [x] Details attachment list, multi-select/drop, and file actions.
- [x] Interactive UI verification after the Mac is unlocked.
- [x] CLI and matching native/npm MCP contracts.
- [ ] CloudKit mappings, receive/removal guards, quarantine, and terminal policy.
- [ ] Metadata-only inventory and durable targeted downloads.
- [ ] Isolated two-Mac sync checks and release gates under the release runbook.

## Current checkpoint

The user moved reader integration and Details ahead of iCloud on 2026-09-29.
Expose a local-only attachment workflow with an explicit “On this Mac” label.
Keep CloudKit dispatch disabled until the sync phases are implemented. This
supersedes the design's original requirement to finish sync before local UI.

Reuse the existing PDF/Markdown renderers with attachment-specific annotation and
position stores. Key reader windows by document identity. The later
[attachment chat plan](2026-09-29-attachment-reader-chat.md) supersedes the initial
Assistant deferral. Test multiple supplements, parent and
attachment isolation, file actions, removal, and reopen behavior.

Use temporary libraries for tests and UI checks; do not launch this intermediate
build against the live library. Preserve the existing printing, reading-comfort,
and website changes. No dependency upgrades, commits, or production CloudKit changes.

### Implemented so far

- Additive v15 tables and dirty tracking for attachment metadata and annotations.
- Managed PDF/UTF-8 Markdown import, streaming SHA-256, per-reference duplicate
  detection, rename, verified export, and retained removal markers.
- Import journal recovery and an attachment file lock to keep recovery from
  deleting an active import's files.
- Separate annotation storage with versioned PDF/Markdown anchors and permanent
  individual removal markers.
- Whole-tree attachment promotion and hash verification before publishing SQLite,
  including hidden staging and quarantine directories.
- Schema upgrade, import/rollback/recovery, annotation isolation, and promotion tests.

### Core checkpoint follow-up

- Root promotion now coordinates open libraries and attachment operations through
  shared/exclusive leases; SQLite exclusive locking also rejects active writers
  that do not participate in the lease protocol. Interrupted publication retains
  its destination identity for retry. See the storage/API continuation below.
- Add acknowledgement-aware file cleanup when the sync ownership contract is
  wired up. Reader-position accessors are implemented.
- Extend the journal for received assets, including expected hash/size and transfer
  phases. The current recovery path handles local imports only.
- Confirmed the shared 250 MiB PDF and 50 MiB Markdown bounds with exact-boundary
  import/read checks and one-byte-over rejection. Synthetic fixtures verify byte
  handling; they do not guarantee rendering performance for every large document.

No new attachment CloudKit types are dispatched yet. The local UI precedes those
phases at the user’s request; syncing attachments remains unavailable.

### Verification — 2026-09-29

- All macOS products built with automatic dependency resolution disabled.
- Direct XCTest run passed 42 tests: `ReferenceAttachmentStoreTests`,
  `MigrationV15Tests`, `AppDatabaseMigrationTests`, and `MigrationV14Tests`.
- The focused test product builds. The full test graph encountered an existing
  `Row`/`Sendable` compile error in `SyncOrphanToleranceTests`; it was not changed.
- `git diff --check` passed; `Package.resolved` is unchanged.
- No live library was migrated and no app was launched. Linux, reader/UI,
  CloudKit, and two-Mac checks remain pending.

### Local readers and Details — 2026-09-29

- Reused PDF and Markdown readers with explicit attachment inputs. Primary readers
  retain their existing annotation stores and Assistant sessions.
- Added document-keyed windows, independent annotations and local positions,
  Markdown Find, existing reader printing, and original-byte export.
- Added multi-select/drop imports, per-file results, cancellation between files,
  open, rename, Finder reveal, Save a Copy, and removal in Details.
- Removal closes the corresponding reader; rename updates its window title.
- The panel says “On this Mac · Not synced”; CloudKit type dispatch is unchanged.
- Passed 26 app tests (attachment integration, primary reader windows, main-thread
  responsiveness, and reader layout metrics) and 44 Core storage/migration tests.
- Visual UI testing is blocked: computer-use tools report that the Mac is locked.
  The user was asked to unlock it. No installed Rubien app was opened, and all
  automated reader checks used temporary libraries.
- CLI/MCP parity, shared promotion locking, iCloud, Linux verification, and real
  two-Mac testing remain separate checkpoints.

### Attachment controls follow-up

The user requested exactly three per-file actions: Reveal, Open, and Remove.
The panel now shows those actions directly, uses the existing hover/pressed button
styles, and displays filenames as text. Add Files and Cancel Remaining also use
hover feedback. The build passes; the preview uses the same isolated library and
retains the sample attachments the user added.

### Preview SDK and layout investigation

After Xcode license setup, both SwiftPM and Xcode 27 debug builds recorded SDK
14.4 in `LC_BUILD_VERSION`, despite compiling against SDK 27.0. The Swift driver
passes `--sysroot` to Clang; a direct Clang probe showed that this records the
deployment target as the SDK version. Passing `-isysroot` records SDK 27.0.

The corrected debug build passed with this additional Xcode argument:

```sh
'OTHER_LDFLAGS=$(inherited) -Xclang-linker -isysroot -Xclang-linker $(SDKROOT)'
```

The checked build used the absolute selected SDK path in place of `$(SDKROOT)`.
`otool -l` confirmed `minos 14.4` and `sdk 27.0`. Keep dependency resolution
disabled and use the isolated preview library when reproducing this check.

Removed the provisional toolbar, sidebar scroll/divider, and table-offset
workarounds to test normal layout with the corrected SDK metadata. Retained the
requested white Home workspace and Reading Activity card border and soft shadow.
The initial visual check was blocked by the locked Mac. After unlocking, the
corrected executable was copied into the existing isolated preview bundle and
checked through the app UI:

- Direct clicks on the visible Home and All References rows navigated correctly.
- Activity and Details controls appeared at the far right and toggled their panels.
- The sidebar edge aligned with the toolbar, and the table's Title column was visible.
- Home had a continuous white workspace with a bordered, softly shadowed activity card.
- The Details list showed Reveal, Open, Remove, and the file-drop hint.
- Open displayed the supplementary PDF and rendered Markdown in separate readers.

`scripts/build-app.sh` now passes the selected SDK through `-isysroot` for debug
and release builds. An unsigned debug build with the exact setting passed;
`otool` confirmed SDK 27.0 and minimum OS 14.4. Shell syntax and diff checks passed.
Release packaging was not run. The checkout preview remains open on Home.


### Storage and API continuation

The next local phase is tracked in
[storage safety and CLI/MCP](2026-09-30-attachment-storage-and-api.md). It adds
promotion leases and API parity. Received-file journals and acknowledgement-aware
cleanup stay in the iCloud phase; new CloudKit dispatch remains disabled.
