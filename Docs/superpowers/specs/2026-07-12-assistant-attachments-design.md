# Assistant Sidebar Attachments — Design

**Date:** 2026-07-12
**Status:** Approved by the user on 2026-07-12
**Scope:** Images plus Markdown/plain-text files in the PDF and web reader Assistant sidebar

## 1. Summary

Enable the existing disabled **Add files or photos** item in the Assistant
sidebar. A user can attach still images and UTF-8 Markdown/plain-text files to
the next message, including an attachment-only message. Rubien copies accepted
files into managed per-conversation storage inside the configured Assistant
workspace, sends images through each provider's native multimodal input, and
gives both providers structured paths to staged text files.

The feature is local to the Assistant layer. Attachments are not reference
attachments, do not enter Rubien's database, do not sync through CloudKit, and
do not extend `rubien-cli`'s data contract.

## 2. Goals

- Activate **Add files or photos** in the composer's `+` menu.
- Accept still images and `.md`, `.markdown`, and `.txt` files.
- Support a standard macOS file picker, Finder drag-and-drop, and pasted images
  or file URLs.
- Show pending attachments in the composer and sent attachments in the visible
  transcript without exposing internal workspace paths.
- Allow messages containing attachments but no typed text.
- Preserve sent staged files so provider-owned conversation history can still
  access them after Rubien restarts or the original file moves.
- Give Claude and Codex equivalent user-visible behavior while using each
  runtime's native image representation.
- Reject bad inputs locally with actionable errors before starting a provider
  turn.

## 3. Non-goals

- PDFs, CSV, office documents, folders, packages, aliases, or arbitrary binary
  files.
- Video, audio, or animation-aware analysis. An animated image is treated as a
  still image using its first frame.
- Importing an Assistant attachment into the Rubien reference library.
- CloudKit sync, database persistence, or a new CLI command for attachments.
- A separate Photos Library browser or Photos permission flow. Image files use
  the same macOS file picker as text files.
- Automatic deletion of sent historical attachments in v1.
- Provider-hosted file upload APIs or Rubien-managed API keys.

## 4. User experience

### 4.1 Adding attachments

The `+` menu's existing disabled **Add files or photos** action becomes active.
It opens a multi-selection macOS file picker filtered to images, Markdown, and
plain text. The same staging pipeline accepts:

1. Files selected in the picker.
2. File URLs dropped from Finder onto the composer.
3. Image data or file URLs pasted while the composer is focused.

Normal pasted text continues to edit the draft rather than becoming a file.
The app accepts any image type ImageIO can decode; it does not rely only on the
filename extension.

### 4.2 Pending presentation

Pending attachments appear inside the composer above the text editor. Each row
or chip contains:

- An image thumbnail or text-document icon.
- The original display filename.
- A compact byte-size label.
- A remove button.
- A staging/validation state when work has not finished.

The send control is enabled when the provider is sendable, no attachment is
still staging, and either the trimmed draft is non-empty or at least one
attachment is ready. Invalid attachments do not count toward sendability.

### 4.3 Sending and clearing

The controller snapshots the typed text, staged reader selection, and ready
attachments into one turn. An attachment-only turn receives an internal neutral
instruction such as "Inspect the attached files." That fallback is sent to the
provider but is not rendered as invented user text.

Attachments are consumed only after `AssistantTurnGate` admits the turn. If the
conversation is busy in another window, pending attachment chips stay available
for retry. Once admitted, the visible user row is rendered with the real typed
text, if any, and attachment presentation metadata; pending chips then clear.

Removing a pending attachment deletes its unsent staged copy. Starting a new
conversation deletes all unsent staged copies. Sent copies remain in managed
storage. Switching providers starts a fresh conversation under existing rules,
but a draft and its still-pending attachments remain available to send through
the newly selected provider, matching the current behavior of typed draft text.
The store rehomes those pending copies into the new conversation directory
before they can be sent; a move failure leaves the affected item pending with an
inline error rather than silently losing it.

### 4.4 Transcript and history

Live user rows show attachment chips or thumbnails together with the typed
message. The render log retains attachment presentation metadata so collapsing
and reopening the sidebar can replay the same row.

The provider prompt carries a versioned attachment manifest. Claude and Codex
history readers recognize that manifest, remove it from visible message text,
and reconstruct filename/kind metadata when a past session is resumed. A staged
file that was manually deleted still appears in history with a **File
unavailable** state.

## 5. Architecture

### 5.1 Provider-neutral models

Add a value model with the conceptual shape:

```swift
struct ChatAttachment: Identifiable, Sendable, Equatable {
    let id: UUID
    let displayName: String
    let kind: Kind              // image or text
    let stagedURL: URL
    let mediaType: String
    let byteCount: Int64
}
```

Thumbnail decoding stays in the presentation layer; provider wire fields must
not leak into the shared type. `AgentTurnRequest` gains an attachment array so
the controller continues to dispatch one immutable snapshot per turn.

`ChatRenderMessage` gains presentation-only attachment descriptors. The
transcript sink/JavaScript boundary renders those descriptors and never receives
absolute staged paths.

### 5.2 Attachment store

An `AssistantAttachmentStore` owns validation, copying, normalization, and
deleting unsent copies. File work must run off the main actor; published composer
state remains main-actor isolated through `ChatSessionController`.

Managed paths live under:

```text
<Assistant workspace>/.rubien/attachments/<conversation UUID>/
```

Every staged filename uses a generated collision-resistant prefix plus a
sanitized display filename. Provider manifests use the absolute staged URL and
JSON-safe escaping; user-controlled filenames can never alter the manifest
structure. The store rejects directories, packages, and non-regular files.

The store distinguishes pending from sent files. It deletes a pending copy on
removal/new-conversation cleanup, but it never silently deletes a sent copy in
v1. Users can inspect or clear the workspace themselves; a managed-history UI or
retention setting is future work.

### 5.3 Image normalization

Rubien decodes the first image frame with ImageIO/Core Graphics and writes a
provider-safe derivative without modifying the source:

- Preserve transparency with PNG when it fits the limits.
- Otherwise encode JPEG, reducing quality and dimensions as necessary.
- Apply image orientation so the provider sees the same orientation as Preview.
- Cap the longest edge at 2,576 pixels.
- Cap the final encoded file at 5 MB.

HEIC, TIFF, WebP, GIF, and other macOS-decodable inputs therefore become PNG or
JPEG before provider dispatch. The transcript thumbnail is derived from the
staged normalized image rather than the original URL.

### 5.4 Text staging

Accepted text extensions are `.md`, `.markdown`, and `.txt`, case-insensitive.
The store accepts UTF-8 with or without a BOM and preserves the validated bytes
in the staged copy. It does not inline the file into the prompt, rewrite
Markdown, normalize line endings, or interpret frontmatter.

The provider receives the staged path and reads the file with its normal local
file tools. The attachment manifest labels file contents as user-provided,
untrusted data, consistent with the Assistant's existing soft-boundary model.

### 5.5 Versioned manifest

Provider-visible text includes a delimited, versioned manifest generated only by
Rubien. It records each staged absolute path, display filename, and kind. The
format must be deterministic and parseable without heuristics; its concrete
encoding should be JSON within a uniquely named Rubien delimiter.

The provider prompt and visible transcript are separate values:

- Provider prompt: reader-selection quote, optional attachment-only fallback,
  typed user text, and hidden attachment manifest.
- Visible user row: reader-selection quote, actual typed text, and attachment
  presentation descriptors.

History parsing strips only a fully valid Rubien manifest. Malformed or
ordinary lookalikes remain visible text rather than being discarded. A
strip-eligible manifest must be the terminal delimited block, match the supported
schema/version, contain generated attachment IDs, and contain only canonical
paths below the configured managed attachments root. This is display hygiene,
not a security boundary.

## 6. Provider mapping

### 6.1 Codex

The installed Codex app-server protocol's `turn/start.input` accepts a sequence
of `UserInput` values. Rubien emits:

1. One `text` input containing the composed provider prompt and manifest.
2. One `localImage` input per staged image, carrying its absolute normalized
   path.

`CodexAppServerProtocol.turnStart` must encode arbitrary ordered turn inputs
rather than manufacturing a text-only array. History parsing must continue to
join visible text while recognizing the Rubien manifest and image entries.

### 6.2 Claude

Claude's stream-JSON user message becomes a content-block array:

1. Native image blocks for staged images, encoded from their normalized local
   files.
2. One text block containing the composed provider prompt and manifest.

The text block remains last so a user's question naturally follows the visual
inputs. Text files are path-backed and are not converted into giant prompt
blocks. The control protocol and approval stream are otherwise unchanged.

Image encoding must complete before spawning/writing the turn. If the staged
file becomes unreadable after validation, the provider throws before writing any
stream-JSON bytes; the controller then uses the existing provider-failure notice
path rather than sending a partial user message.

## 7. Validation and limits

The first release uses these explicit limits:

| Constraint | Limit |
|---|---:|
| Total attachments per message | 10 |
| UTF-8 Markdown/text file | 5 MB each |
| Normalized image longest edge | 2,576 px |
| Normalized PNG/JPEG file bytes | 5 MB each |
| Combined normalized image file bytes | 20 MB |

Validation happens before send. A batch is partial-success: valid files remain
attached even when other items fail. Errors identify the filename and reason,
including unsupported type, unreadable input, non-UTF-8 text, decode failure,
size/count limit, duplicate pending file, or copy/permission failure.

The store deduplicates the same canonical source file within the pending set.
Reattaching a file after its earlier copy was sent is allowed because it belongs
to a new user turn.

If image normalization cannot satisfy the per-image limit without producing a
valid non-empty image, staging fails. Rubien never sends an input that it knows
violates its local limits.

## 8. Error handling and concurrency

- Staging is cancellable and cannot publish results into a superseded/new
  conversation generation.
- Per-file failures are presented inline; they do not add invalid attachment
  objects to the outgoing request.
- Send is disabled while any attachment is still staging. Once staging settles,
  the snapshot includes every ready attachment and excludes failed items.
- Gate refusal preserves all pending attachment state.
- Once the user row has rendered, a provider failure follows the existing notice
  path; sent files remain available to the provider-owned history if the runtime
  recorded the turn and are never deleted as a consequence of the failure.
- Removing a chip while its staging task is running cancels or supersedes the
  task and deletes any copy produced afterward.
- File operations use coordinated, bounded work so selecting several large
  images does not block SwiftUI or allocate every decoded bitmap simultaneously.
- Provider switching/new-conversation generation guards prevent a stale staging
  result or turn from mutating the current conversation.
- Provider switching rehomes pending files to the new conversation directory;
  explicit **New conversation** instead deletes them, matching the approved
  composer behavior.

## 9. Privacy and storage behavior

- Originals are read only for validation/copying/normalization and are never
  modified.
- Staged files live under the user's configured Assistant workspace, not the
  Rubien library storage root.
- No attachment row, bookmark, path, or content enters SQLite or CloudKit.
- Rubien does not upload a file until the user sends the message. The selected
  Claude/Codex runtime determines the eventual provider transport under its
  existing authenticated session.
- Absolute workspace paths are provider-visible but are hidden from Rubien's
  rendered transcript UI.
- Sent staged files persist until the user manually removes them or a future
  explicit retention feature is implemented.

## 10. Testing

### 10.1 Store and validation tests

- Accept `.md`, `.markdown`, `.txt`, and supported image inputs.
- Reject unsupported extensions/types, directories, unreadable files, and
  non-UTF-8 text.
- Enforce count, per-file, dimension, and combined-payload limits.
- Preserve valid siblings in a partially invalid selection batch.
- Normalize orientation, transparency, HEIC/TIFF-style inputs, large dimensions,
  and first-frame animation behavior.
- Generate collision-safe paths and delete only unsent staged copies.
- Cancel/supersede staging without leaking a late copy into current state.

### 10.2 Controller tests

- Text-only behavior remains unchanged.
- Attachment-only send is admitted and renders no artificial user text.
- A draft or a ready attachment independently enables send.
- Gate refusal keeps attachments pending.
- Successful admission consumes attachments once.
- New conversation removes unsent copies; provider switching preserves a pending
  draft and attachments.
- Stop, provider failure, and stale-generation paths do not double-delete sent
  files or reuse attachments in a later turn.

### 10.3 Protocol/provider tests

- Codex `turn/start` contains one text input plus ordered `localImage` inputs.
- Claude stream JSON contains ordered image blocks plus the final text block.
- Filenames/paths containing quotes, Unicode, newlines, and delimiter-like text
  cannot corrupt the manifest.
- Only a terminal, schema-valid manifest whose canonical paths are contained by
  the managed attachments root is stripped from history presentation.
- Fake Claude/Codex providers assert exact payloads without paid live requests.
- Existing text-only fixtures remain valid through default-empty attachment
  arrays.

### 10.4 Renderer and history tests

- Live user rows render filenames, text icons, image thumbnails, and optional
  typed text.
- Render-log replay restores attachment presentation after sidebar remount.
- Claude and Codex history readers reconstruct valid manifests and hide their
  internal text.
- Deleted staged paths render **File unavailable**.
- Malformed manifest lookalikes remain visible and cannot suppress user text.
- Theme changes and transcript sanitization remain intact.

### 10.5 Manual verification

Use the DEBUG Assistant harness and both reader types to verify file picking,
drag/drop, clipboard images, chip removal, attachment-only send, provider
switching, history resume, dark mode, VoiceOver labels, and keyboard-only removal
and sending. Run the full Rubien build/test cycle after focused Assistant tests.

## 11. Expected implementation surface

The implementation plan should confirm exact boundaries, but the likely touched
surface is:

- `Sources/Rubien/Assistant/ChatSidebarView.swift`
- `Sources/Rubien/Assistant/ChatSessionController.swift`
- `Sources/Rubien/Assistant/AgentProvider.swift`
- `Sources/Rubien/Assistant/ClaudeStreamParser.swift`
- `Sources/Rubien/Assistant/ClaudeCodeProvider.swift`
- `Sources/Rubien/Assistant/CodexAppServerProtocol.swift`
- `Sources/Rubien/Assistant/CodexProvider.swift`
- `Sources/Rubien/Assistant/ChatTranscriptModels.swift`
- `Sources/Rubien/Assistant/ChatTranscriptJS.swift`
- `Sources/Rubien/Resources/ChatTranscript.html`
- A new Assistant attachment model/store file
- Corresponding `RubienTests`

No migration, synced model, `RubienCore` data API, or CLI JSON change is expected.

## 12. Acceptance criteria

The feature is complete when a user can pick, drop, or paste an accepted image or
text file; see and remove it in the composer; send it with or without typed text;
and receive a response from either Claude or Codex with the provider given the
correct structured input. The visible transcript must show the attachment without
revealing managed paths, gate refusal must preserve it, history resume must retain
its identity, invalid inputs must fail locally with clear reasons, and the full
test suite must remain green.
