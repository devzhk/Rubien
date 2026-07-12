# Assistant Sidebar Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users attach still images and UTF-8 Markdown/plain-text files to Claude or Codex turns from either reader's Assistant sidebar, with picker/drop/paste UX, local managed storage, transcript/history presentation, and provider-native image inputs.

**Architecture:** Provider-neutral attachment values and a versioned manifest sit at the center. An actor stages validated files under `<Assistant workspace>/.rubien/attachments/<conversation UUID>/`; the controller owns pending UI state and snapshots attachments only after the turn gate admits the send. Claude maps normalized images to base64 image content blocks, Codex maps them to app-server `localImage` inputs, and transcript/history receive presentation descriptors with no absolute paths.

**Tech Stack:** Swift 6, SwiftUI/AppKit (macOS 15), Foundation/UniformTypeIdentifiers, ImageIO/CoreGraphics, Claude stream-JSON, Codex app-server JSON-RPC, XCTest, JavaScript/DOMPurify renderer tests under Node.js.

**Spec:** `Docs/superpowers/specs/2026-07-12-assistant-attachments-design.md` (commit `06e8edf`). Read it before starting.

## Global Constraints

- Swift 6.x; macOS deployment target 15.0. Gate APIs introduced later than 15.0.
- Supported inputs are still images and `.md`, `.markdown`, `.txt` only.
- Exact limits: 10 attachments/turn; 5 MB/text file; 2,576 px image longest edge; 5 MB/normalized image; 20 MB combined normalized image bytes.
- Staged paths stay below `<Assistant workspace>/.rubien/attachments/<conversation UUID>/`; no database, CloudKit, library-attachment, or CLI JSON changes.
- Never modify originals. Delete unsent copies on removal/explicit New Conversation; retain sent copies. Provider switch preserves and rehomes pending copies.
- Never expose an absolute staged path or synthetic attachment-only instruction to the visible transcript.
- Wrap every new `Tests/RubienTests/*.swift` file in `#if os(macOS)` / `#endif`.
- Use `RubienLogger`, never `os.Logger`; keep image/file work off the main actor.
- Do not hand-edit `Sources/Rubien/Resources/ChatTranscript.html`; rebuild it from `scripts/chat-renderer`.
- Each task ends with focused green tests and a coherent commit. Preserve unrelated user files.

## File Structure

**Create**

- `Sources/Rubien/Assistant/AssistantAttachments.swift` — attachment values and versioned manifest.
- `Sources/Rubien/Assistant/AssistantAttachmentStore.swift` — staging/removal/rehoming actor.
- `Sources/Rubien/Assistant/AssistantImageNormalizer.swift` — deterministic ImageIO normalization.
- `Tests/RubienTests/AssistantAttachmentManifestTests.swift`
- `Tests/RubienTests/AssistantAttachmentStoreTests.swift`

**Modify**

- `AgentProvider.swift` and both provider/protocol implementations — request/wire support.
- `ChatSessionController.swift` and `ChatSidebarView.swift` — state, lifecycle, and UX.
- Transcript Swift models/bridge plus `scripts/chat-renderer` source/tests/generated HTML.
- `ClaudeSessionStore.swift` and `CodexAppServerProtocol.swift` — history reconstruction.
- Existing focused XCTest files and fake-provider fixtures.

---

### Task 1: Attachment values and versioned manifest

**Files:**
- Create: `Sources/Rubien/Assistant/AssistantAttachments.swift`
- Create: `Tests/RubienTests/AssistantAttachmentManifestTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum ChatAttachmentKind: String, Codable, Sendable { case image, text }
  struct ChatAttachment: Identifiable, Sendable, Equatable
  struct ChatAttachmentPresentation: Codable, Sendable, Equatable
  struct StagingChatAttachment: Identifiable, Sendable, Equatable
  struct ChatAttachmentIssue: Identifiable, Sendable, Equatable
  struct ParsedAttachmentMessage: Sendable, Equatable
  enum AssistantAttachmentManifest {
      static func providerPrompt(base: String, visibleText: String,
                                 attachments: [ChatAttachment]) -> String
      static func parse(_ text: String, managedRoot: URL,
                        fileManager: FileManager = .default) -> ParsedAttachmentMessage
  }
  ```

- [ ] **Step 1: Write failing manifest tests**

Create `AssistantAttachmentManifestTests.swift`:

```swift
#if os(macOS)
import Foundation
import XCTest
@testable import Rubien

final class AssistantAttachmentManifestTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/ws/.rubien/attachments", isDirectory: true)

    private func attachment(path: String? = nil) -> ChatAttachment {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return ChatAttachment(
            id: id, displayName: "notes \"α\".md", kind: .text,
            stagedURL: URL(fileURLWithPath: path ??
                "/tmp/ws/.rubien/attachments/C/\(id.uuidString)-notes.md"),
            mediaType: "text/markdown", byteCount: 42,
            sourceIdentity: "/original/notes.md")
    }

    func testRoundTripKeepsProviderAndVisibleTextSeparate() {
        let prompt = AssistantAttachmentManifest.providerPrompt(
            base: "Inspect the attached files.", visibleText: "", attachments: [attachment()])
        let parsed = AssistantAttachmentManifest.parse(prompt, managedRoot: root)
        XCTAssertEqual(parsed.visibleText, "")
        XCTAssertEqual(parsed.attachments.map(\.displayName), ["notes \"α\".md"])
        XCTAssertTrue(prompt.contains("<rubien-attachments-v1>"))
    }

    func testMalformedAndOutsideRootManifestsStayVisible() {
        let lookalike = "hello\n<rubien-attachments-v1>\n{}\n</rubien-attachments-v1>"
        XCTAssertEqual(AssistantAttachmentManifest.parse(lookalike, managedRoot: root).visibleText,
                       lookalike)
        let outside = AssistantAttachmentManifest.providerPrompt(
            base: "Q", visibleText: "Q", attachments: [attachment(path: "/etc/passwd")])
        XCTAssertEqual(AssistantAttachmentManifest.parse(outside, managedRoot: root).visibleText,
                       outside)
    }

    func testMissingStagedFileBecomesUnavailablePresentation() {
        let prompt = AssistantAttachmentManifest.providerPrompt(
            base: "Q", visibleText: "Q", attachments: [attachment()])
        XCTAssertEqual(
            AssistantAttachmentManifest.parse(prompt, managedRoot: root).attachments.first?.isAvailable,
            false)
    }
}
#endif
```

- [ ] **Step 2: Run tests and confirm red**

Run: `swift test --filter RubienTests.AssistantAttachmentManifestTests`

Expected: compile failure because the attachment types do not exist.

- [ ] **Step 3: Implement the values and manifest**

Create `AssistantAttachments.swift` with these exact public/internal shapes:

```swift
import Foundation

enum ChatAttachmentKind: String, Codable, Sendable, Equatable { case image, text }

struct ChatAttachment: Identifiable, Sendable, Equatable {
    let id: UUID
    let displayName: String
    let kind: ChatAttachmentKind
    let stagedURL: URL
    let mediaType: String
    let byteCount: Int64
    let sourceIdentity: String
    let thumbnailDataURL: String?

    init(id: UUID, displayName: String, kind: ChatAttachmentKind,
         stagedURL: URL, mediaType: String, byteCount: Int64,
         sourceIdentity: String, thumbnailDataURL: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.stagedURL = stagedURL
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sourceIdentity = sourceIdentity
        self.thumbnailDataURL = thumbnailDataURL
    }

    var presentation: ChatAttachmentPresentation {
        ChatAttachmentPresentation(
            id: id, displayName: displayName, kind: kind, byteCount: byteCount,
            isAvailable: true, thumbnailDataURL: thumbnailDataURL)
    }
}

struct ChatAttachmentPresentation: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let displayName: String
    let kind: ChatAttachmentKind
    let byteCount: Int64
    let isAvailable: Bool
    let thumbnailDataURL: String?
}

struct ChatAttachmentIssue: Identifiable, Sendable, Equatable {
    let id = UUID()
    let displayName: String
    let message: String
}

struct StagingChatAttachment: Identifiable, Sendable, Equatable {
    let id: UUID
    let displayName: String
}

struct ParsedAttachmentMessage: Sendable, Equatable {
    let visibleText: String
    let attachments: [ChatAttachmentPresentation]
}
```

Implement a private Codable envelope `{version, visibleText, warning, attachments}` between terminal delimiters `<rubien-attachments-v1>` and `</rubien-attachments-v1>`. `providerPrompt` JSON-encodes filenames/paths. `parse` strips only when all conditions hold: terminal delimiter, version 1, nonempty entries, canonical path components start with `managedRoot.standardizedFileURL.pathComponents`, and every staged basename begins with `entry.id.uuidString + "-"`. Otherwise return the original text and no attachments. Build presentations with `fileExists(atPath:)` and no thumbnail.

- [ ] **Step 4: Run tests and confirm green**

Run: `swift test --filter RubienTests.AssistantAttachmentManifestTests`

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/AssistantAttachments.swift Tests/RubienTests/AssistantAttachmentManifestTests.swift
git commit -m "feat(assistant): add attachment values and manifest"
```

---

### Task 2: Text staging and pending-file lifecycle

**Files:**
- Create: `Sources/Rubien/Assistant/AssistantAttachmentStore.swift`
- Create: `Tests/RubienTests/AssistantAttachmentStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 attachment values.
- Produces:
  ```swift
  actor AssistantAttachmentStore {
      static let relativeRoot = ".rubien/attachments"
      static let maxTextBytes: Int64 = 5 * 1_024 * 1_024
      init(workspaceURL: URL, fileManager: FileManager = .default)
      nonisolated let managedRoot: URL
      func stageFile(_ sourceURL: URL, id: UUID = UUID(),
                     conversationID: UUID) throws -> ChatAttachment
      func stageImageData(_ data: Data, suggestedName: String,
                          id: UUID = UUID(), conversationID: UUID) throws -> ChatAttachment
      func removePending(_ attachments: [ChatAttachment])
      func rehomePending(_ attachments: [ChatAttachment], to: UUID) throws -> [ChatAttachment]
  }
  enum AssistantAttachmentStoreError: LocalizedError, Equatable
  ```

- [ ] **Step 1: Write failing store tests**

Create a temporary workspace/store fixture and these tests:

```swift
func testStagesUTF8MarkdownWithoutChangingSource() async throws {
    let source = workspace.appendingPathComponent("source.md")
    let original = Data("# Café\n".utf8)
    try original.write(to: source)
    let conversation = UUID()
    let a = try await store.stageFile(source, conversationID: conversation)
    XCTAssertEqual(a.kind, .text)
    XCTAssertEqual(a.mediaType, "text/markdown")
    XCTAssertEqual(try Data(contentsOf: a.stagedURL), original)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertTrue(a.stagedURL.path.contains("/.rubien/attachments/\(conversation.uuidString)/"))
    XCTAssertTrue(a.stagedURL.lastPathComponent.hasPrefix(a.id.uuidString + "-"))
}

func testRejectsCSVNonUTF8AndOversizedText() async {
    for (name, data) in [
        ("x.csv", Data("a,b".utf8)),
        ("x.txt", Data([0xff, 0xfe, 0xfd])),
        ("large.md", Data(repeating: 0x61,
                          count: Int(AssistantAttachmentStore.maxTextBytes + 1))),
    ] {
        let url = workspace.appendingPathComponent(name)
        try! data.write(to: url)
        await XCTAssertThrowsErrorAsync(try await store.stageFile(url, conversationID: UUID()))
    }
}

func testRehomeThenRemovePendingPreservesIdentity() async throws {
    let source = workspace.appendingPathComponent("note.txt")
    try Data("hello".utf8).write(to: source)
    let first = try await store.stageFile(source, conversationID: UUID())
    let moved = try await store.rehomePending([first], to: UUID())
    XCTAssertEqual(moved[0].id, first.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.stagedURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved[0].stagedURL.path))
    await store.removePending(moved)
    XCTAssertFalse(FileManager.default.fileExists(atPath: moved[0].stagedURL.path))
}
```

Wrap the file for macOS and include an async `XCTAssertThrowsErrorAsync` helper.

- [ ] **Step 2: Run tests and confirm red**

Run: `swift test --filter RubienTests.AssistantAttachmentStoreTests`

Expected: compile failure because `AssistantAttachmentStore` is undefined.

- [ ] **Step 3: Implement text validation and lifecycle**

Implement `AssistantAttachmentStoreError` with filename-specific `errorDescription` cases: `unsupported`, `notRegularFile`, `unreadable`, `nonUTF8`, `tooLarge`, `imageDecode`, `imageEncode`.

Implement `stageFile` as follows:

```swift
let values = try sourceURL.resourceValues(forKeys: [
    .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey,
])
guard values.isRegularFile == true,
      values.isSymbolicLink != true,
      values.isAliasFile != true else {
    throw AssistantAttachmentStoreError.notRegularFile(name)
}
let ext = sourceURL.pathExtension.lowercased()
guard ["md", "markdown", "txt"].contains(ext) else {
    if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
        return try stageImageFile(sourceURL, id: id, conversationID: conversationID)
    }
    throw AssistantAttachmentStoreError.unsupported(name)
}
guard Int64(values.fileSize ?? 0) <= Self.maxTextBytes else {
    throw AssistantAttachmentStoreError.tooLarge(name)
}
let data = try read(sourceURL)
let body = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
guard String(data: body, encoding: .utf8) != nil else {
    throw AssistantAttachmentStoreError.nonUTF8(name)
}
return try write(data: data, displayName: name, kind: .text,
                 mediaType: ext == "txt" ? "text/plain" : "text/markdown",
                 sourceIdentity: sourceURL.standardizedFileURL.path,
                 pathExtension: ext, conversationID: conversationID)
```

`stageFile`/`stageImageData` pass their caller-supplied ID to `write`. This regular-file gate rejects directories, packages, symlinks, and Finder aliases before reading content. `write` must sanitize the display basename, create the conversation directory, atomically write `"<UUID>-<sanitized>.<ext>"`, and return `ChatAttachment`; its `thumbnailDataURL` argument defaults to nil for text. Implement `removePending` with best-effort deletion. Implement `rehomePending` with same-volume `moveItem`, preserving IDs, metadata, and `thumbnailDataURL` while returning updated URLs. Make rehome transactional: if one move fails, move every already-moved item back to its original URL before throwing, so the controller's preserved pending array never points at half-moved files. Until Task 3, declare `stageImageFile(_:id:conversationID:)` and `stageImageData(_:suggestedName:id:conversationID:)` with their final signatures and have them throw `imageDecode`.

- [ ] **Step 4: Run tests and confirm green**

Run: `swift test --filter RubienTests.AssistantAttachmentStoreTests`

Expected: the 3 text/lifecycle tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/AssistantAttachmentStore.swift Tests/RubienTests/AssistantAttachmentStoreTests.swift
git commit -m "feat(assistant): stage text attachments"
```

---

### Task 3: Image normalization and image staging

**Files:**
- Create: `Sources/Rubien/Assistant/AssistantImageNormalizer.swift`
- Modify: `Sources/Rubien/Assistant/AssistantAttachmentStore.swift`
- Modify: `Tests/RubienTests/AssistantAttachmentStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct NormalizedAssistantImage: Sendable, Equatable {
      let data: Data
      let mediaType: String
      let pathExtension: String
      let width: Int
      let height: Int
      let thumbnailDataURL: String
  }
  enum AssistantImageNormalizer {
      static let maxPixelSize = 2_576
      static let maxBytes = 5 * 1_024 * 1_024
      static func normalize(_ data: Data, displayName: String,
                            maxPixelSize: Int = maxPixelSize,
                            maxBytes: Int = maxBytes) throws -> NormalizedAssistantImage
  }
  ```

- [ ] **Step 1: Add failing image tests**

Add CoreGraphics/ImageIO test helpers and these cases to `AssistantAttachmentStoreTests`:

```swift
func testLargeOpaqueImageStagesAsBoundedJPEG() async throws {
    let source = workspace.appendingPathComponent("large.tiff")
    try makeImageData(width: 4_000, height: 2_000, alpha: false, type: .tiff).write(to: source)
    let a = try await store.stageFile(source, conversationID: UUID())
    XCTAssertEqual(a.kind, .image)
    XCTAssertEqual(a.mediaType, "image/jpeg")
    XCTAssertEqual(a.stagedURL.pathExtension, "jpg")
    XCTAssertLessThanOrEqual(a.byteCount, Int64(AssistantImageNormalizer.maxBytes))
    let src = try XCTUnwrap(CGImageSourceCreateWithURL(a.stagedURL as CFURL, nil))
    let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    XCTAssertLessThanOrEqual(p[kCGImagePropertyPixelWidth] as? Int ?? .max, 2_576)
}

func testPastedTransparentImageUsesPNG() async throws {
    let data = try makeImageData(width: 64, height: 64, alpha: true, type: .png)
    let a = try await store.stageImageData(data, suggestedName: "clipboard.png",
                                           conversationID: UUID())
    XCTAssertEqual(a.mediaType, "image/png")
    XCTAssertEqual(a.stagedURL.pathExtension, "png")
}

func testInvalidAndImpossibleImageFailsLocally() async {
    await XCTAssertThrowsErrorAsync(try await store.stageImageData(
        Data("not image".utf8), suggestedName: "bad.png", conversationID: UUID()))
    XCTAssertThrowsError(try AssistantImageNormalizer.normalize(
        try! makeImageData(width: 512, height: 512, alpha: false, type: .png),
        displayName: "x.png", maxPixelSize: 16, maxBytes: 8))
}
```

`makeImageData` must create deterministic pixels in a `CGContext`, encode with `CGImageDestinationCreateWithData`, and finalize the requested `UTType`.

- [ ] **Step 2: Run tests and confirm red**

Run: `swift test --filter RubienTests.AssistantAttachmentStoreTests`

Expected: compile failure because `AssistantImageNormalizer` does not exist.

- [ ] **Step 3: Implement bounded ImageIO normalization**

Decode frame index 0 with `CGImageSourceCreateWithData` (animated inputs intentionally use their first frame), then iterate deduplicated descending edges `[min(sourceMax, 2576), 2048, 1600, 1280, 1024, 768, 512]`. For each edge create an oriented thumbnail:

```swift
let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: edge,
]
guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
else { throw AssistantAttachmentStoreError.imageDecode(displayName) }
```

If the image has alpha, try PNG first. Otherwise, or when PNG exceeds 5 MB, composite onto white and try JPEG qualities `[0.90, 0.82, 0.74, 0.64, 0.52]`. Use `CGImageDestinationCreateWithData`, verify `CGImageDestinationFinalize`, and return the first candidate within `maxBytes`; throw `.imageEncode(displayName)` after all candidates fail. Before returning, render a second, maximum-160-pixel JPEG/PNG thumbnail and prefix its base64 with either `data:image/png;base64,` or `data:image/jpeg;base64,` in `thumbnailDataURL`.

Replace the Task 2 image stubs:

```swift
func stageImageData(_ data: Data, suggestedName: String,
                    id: UUID = UUID(), conversationID: UUID) throws -> ChatAttachment {
    let n = try AssistantImageNormalizer.normalize(data, displayName: suggestedName)
    return try write(data: n.data, displayName: suggestedName, kind: .image,
                     mediaType: n.mediaType,
                     sourceIdentity: "clipboard:\(UUID().uuidString)",
                     pathExtension: n.pathExtension, conversationID: conversationID,
                     id: id, thumbnailDataURL: n.thumbnailDataURL)
}

private func stageImageFile(_ source: URL, id: UUID,
                            conversationID: UUID) throws -> ChatAttachment {
    let n = try AssistantImageNormalizer.normalize(try read(source),
                                                   displayName: source.lastPathComponent)
    return try write(data: n.data, displayName: source.lastPathComponent, kind: .image,
                     mediaType: n.mediaType, sourceIdentity: source.standardizedFileURL.path,
                     pathExtension: n.pathExtension, conversationID: conversationID,
                     id: id, thumbnailDataURL: n.thumbnailDataURL)
}
```

The image branch in `stageFile` calls `stageImageFile(sourceURL, id: id, conversationID: conversationID)`, so the staging-row ID, staged basename, ready attachment, manifest entry, and removal action all use one identity.

- [ ] **Step 4: Run tests and confirm green**

Run: `swift test --filter RubienTests.AssistantAttachmentStoreTests`

Expected: text, lifecycle, and image tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/AssistantImageNormalizer.swift Sources/Rubien/Assistant/AssistantAttachmentStore.swift Tests/RubienTests/AssistantAttachmentStoreTests.swift
git commit -m "feat(assistant): normalize image attachments"
```

---

### Task 4: Structured transcript attachment presentation

**Files:**
- Modify: `Sources/Rubien/Assistant/ChatTranscriptModels.swift`
- Modify: `Sources/Rubien/Assistant/ChatTranscriptJS.swift`
- Modify: `Sources/Rubien/Assistant/ChatTranscriptController.swift`
- Modify: `Sources/Rubien/Assistant/ChatSessionController.swift` (sink overload only)
- Modify: `Tests/RubienTests/ChatTranscriptJSTests.swift`
- Modify: `Tests/RubienTests/ChatSessionControllerTests.swift` (spy overload only)
- Modify: `scripts/chat-renderer/src/chat.js`, `src/chat.css`, `test/integration.test.js`
- Generate: `Sources/Rubien/Resources/ChatTranscript.html`

**Interfaces:**
- Produces:
  ```swift
  struct ChatUserMessagePayload: Codable, Sendable, Equatable {
      let body: String
      let attachments: [ChatAttachmentPresentation]
  }
  // ChatRenderMessage gains a backward-compatible field:
  let attachments: [ChatAttachmentPresentation]
  // Swift/JS sink gains:
  func addUserMessage(_ payload: ChatUserMessagePayload)
  ```

- [ ] **Step 1: Write failing Swift and Node tests**

Add to `ChatTranscriptJSTests`:

```swift
func testStructuredUserPayloadAndLegacyDecode() throws {
    let a = ChatAttachmentPresentation(
        id: UUID(), displayName: "figure.png", kind: .image, byteCount: 123,
        isAvailable: true, thumbnailDataURL: "data:image/png;base64,AA==")
    let payload = ChatUserMessagePayload(body: "Look", attachments: [a])
    let arg = try extractArgument(from: ChatTranscriptJS.addUserMessage(payload),
                                  fn: "addUserMessage")
    XCTAssertEqual(try JSONDecoder().decode(ChatUserMessagePayload.self,
                                            from: Data(arg.utf8)), payload)
    let legacy = #"{"role":"user","body":"old","seq":0}"#
    XCTAssertEqual(try JSONDecoder().decode(ChatRenderMessage.self,
                                            from: Data(legacy.utf8)).attachments, [])
}
```

Add to `scripts/chat-renderer/test/integration.test.js`:

```javascript
test('user attachment payload renders safe chips and unavailable state', async () => {
  const { R, T } = await boot()
  R.addUserMessage({ body: '', attachments: [
    { id: '1', displayName: '<img onerror=alert(1)>.md', kind: 'text', byteCount: 42, isAvailable: true },
    { id: '2', displayName: 'gone.png', kind: 'image', byteCount: 99, isAvailable: false },
  ] })
  await tick()
  const bubble = T().querySelector('.chat-msg-user .chat-bubble')
  assert.equal(bubble.querySelectorAll('.chat-attachment').length, 2)
  assert.match(bubble.textContent, /<img onerror=alert\(1\)>\.md/)
  assert.match(bubble.textContent, /File unavailable/)
  assert.equal(bubble.querySelectorAll('[onerror]').length, 0)
})
```

- [ ] **Step 2: Run tests and confirm red**

Run: `swift test --filter RubienTests.ChatTranscriptJSTests`

Run from `scripts/chat-renderer`: `npm test`

Expected: Swift compile failure for new types/field; Node failure because the object becomes `[object Object]`.

- [ ] **Step 3: Implement Swift bridge and safe DOM rendering**

Add `ChatUserMessagePayload`. Add `attachments` to `ChatRenderMessage`, add `attachments: [ChatAttachmentPresentation] = []` to its initializer, and add a custom decoder using `decodeIfPresent([ChatAttachmentPresentation].self, forKey: .attachments) ?? []`. Add structured overloads while retaining the exact legacy string encoding:

```swift
static func addUserMessage(_ payload: ChatUserMessagePayload) -> String {
    jsCall("addUserMessage", [encodeArg(payload)])
}
static func addUserMessage(_ markdown: String) -> String {
    jsCall("addUserMessage", [encodeArg(markdown)])
}
```

Mirror through `ChatTranscriptController`, `ChatTranscriptSink`, and `SpyTranscriptSink.Call.addUserPayload` without yet changing controller send behavior.

In `chat.js`, normalize string/object inputs, build attachment nodes with `textContent`, accept thumbnails only when matching `^data:image/(png|jpeg);base64,`, and share one `renderUserPayload` between live `addUserMessage` and restored `appendRecord`. Add compact `.chat-attachment*` CSS and a text `File unavailable` state. Do not insert filenames or paths with `innerHTML`.

Regenerate the artifact:

```bash
cd scripts/chat-renderer
npm run build
npm test
```

- [ ] **Step 4: Run tests and confirm green**

Run: `swift test --filter RubienTests.ChatTranscriptJSTests`

Run from `scripts/chat-renderer`: `npm test`

Expected: both suites pass and the generated HTML is current.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/ChatTranscriptModels.swift Sources/Rubien/Assistant/ChatTranscriptJS.swift Sources/Rubien/Assistant/ChatTranscriptController.swift Sources/Rubien/Assistant/ChatSessionController.swift Tests/RubienTests/ChatTranscriptJSTests.swift Tests/RubienTests/ChatSessionControllerTests.swift scripts/chat-renderer/src/chat.js scripts/chat-renderer/src/chat.css scripts/chat-renderer/test/integration.test.js Sources/Rubien/Resources/ChatTranscript.html
git commit -m "feat(assistant): render transcript attachments"
```

---

### Task 5: Controller staging state, gate-safe send, and attachment lifecycle

**Files:**
- Modify: `Sources/Rubien/Assistant/AgentProvider.swift`
- Modify: `Sources/Rubien/Assistant/ChatSessionController.swift`
- Modify: `Tests/RubienTests/ChatSessionControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4 store, manifest, presentation, and structured transcript sink.
- Produces for Task 8:
  ```swift
      @Published private(set) var pendingAttachments: [ChatAttachment]
      @Published private(set) var stagingAttachments: [StagingChatAttachment]
      @Published private(set) var attachmentIssues: [ChatAttachmentIssue]
      var isStagingAttachments: Bool { get }
  var hasReadyAttachments: Bool { get }
  func stageAttachments(_ urls: [URL])
  func stagePastedImage(_ data: Data, suggestedName: String)
  func removePendingAttachment(id: UUID)
  func clearAttachmentIssues()
  func canSend(draft: String) -> Bool
  ```

- [ ] **Step 1: Write failing controller tests**

Add a temporary-workspace controller fixture and tests:

```swift
func testAttachmentOnlyTurnUsesHiddenFallbackAndStructuredVisibleRow() async throws {
    let (controller, provider, sink, source) = try makeAttachmentController()
    controller.stageAttachments([source])
    await waitUntil { !controller.isStagingAttachments }
    XCTAssertTrue(controller.canSend(draft: ""))

    controller.send("")
    let task = controller.turnTask
    await provider.waitUntilStreaming()
    XCTAssertTrue(provider.lastRequest?.prompt.contains("Inspect the attached files.") == true)
    XCTAssertEqual(provider.lastRequest?.attachments.count, 1)
    provider.finishStream()
    await task?.value

    let payload = try XCTUnwrap(sink.calls.compactMap {
        if case .addUserPayload(let p) = $0 { return p }; return nil
    }.first)
    XCTAssertEqual(payload.body, "", "synthetic fallback is never visible")
    XCTAssertEqual(payload.attachments.map(\.displayName), [source.lastPathComponent])
    XCTAssertTrue(controller.pendingAttachments.isEmpty)
}

func testBusyGateKeepsPendingAttachmentForRetry() async throws {
    let gate = AssistantTurnGate()
    let (first, firstProvider) = makeResumedController(gate: gate, sessionID: "shared")
    let (second, secondProvider, _, source) = try makeAttachmentController(
        gate: gate, sessionID: "shared")
    first.send("hold")
    await firstProvider.waitUntilStreaming()
    second.stageAttachments([source])
    await waitUntil { !second.isStagingAttachments }
    second.send("")
    await second.turnTask?.value
    XCTAssertTrue(secondProvider.requests.isEmpty)
    XCTAssertEqual(second.pendingAttachments.count, 1)
    firstProvider.finishStream()
    await first.turnTask?.value
}

func testNewConversationDeletesPendingWhileProviderSwitchRehomesIt() async throws {
    let (controller, _, _, source) = try makeAttachmentController(withProviderFactory: true)
    controller.stageAttachments([source])
    await waitUntil { !controller.isStagingAttachments }
    let oldPath = try XCTUnwrap(controller.pendingAttachments.first?.stagedURL)
    controller.switchProvider(to: .codex)
    await waitUntil { !controller.isStagingAttachments }
    let movedPath = try XCTUnwrap(controller.pendingAttachments.first?.stagedURL)
    XCTAssertNotEqual(oldPath, movedPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: movedPath.path))
    controller.newConversation()
    await waitUntil { !FileManager.default.fileExists(atPath: movedPath.path) }
}
```

Also test duplicate source rejection, 10-item cap, and stale staging completion after `newConversation()`. Extract the combined-image decision as internal pure helper `static func acceptsImageBytes(existing: Int64, adding: Int64) -> Bool` and test boundary values `20 MB - 1 + 1` (accepted) and `20 MB + 1` (rejected), avoiding large allocations.

- [ ] **Step 2: Run tests and confirm red**

Run: `swift test --filter RubienTests.ChatSessionControllerTests`

Expected: compile failure because controller attachment APIs and `AgentTurnRequest.attachments` do not exist.

- [ ] **Step 3: Implement staging and lifecycle state**

First add `let attachments: [ChatAttachment]` to `AgentTurnRequest` and an initializer argument `attachments: [ChatAttachment] = []`; the default preserves every existing call site and test fixture. Then inject `AssistantAttachmentStore` in the controller initializer, defaulting to `AssistantAttachmentStore(workspaceURL:)`. Add:

```swift
@Published private(set) var pendingAttachments: [ChatAttachment] = []
@Published private(set) var stagingAttachments: [StagingChatAttachment] = []
@Published private(set) var attachmentIssues: [ChatAttachmentIssue] = []
@Published private(set) var isRehomingAttachments = false
private let attachmentStore: AssistantAttachmentStore
private var attachmentConversationID = UUID()
private var attachmentGeneration = 0
private var attachmentTask: Task<Void, Never>?
private var cancelledAttachmentIDs: Set<UUID> = []

var hasReadyAttachments: Bool { !pendingAttachments.isEmpty }
var isStagingAttachments: Bool {
    !stagingAttachments.isEmpty || isRehomingAttachments
}
func canSend(draft: String) -> Bool {
    canSendWithCurrentAvailability && !isResponding && !isStagingAttachments
        && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasReadyAttachments)
}
```

Implement `stageAttachments` as one serial task. Before starting, create one `StagingChatAttachment(id: UUID(), displayName: url.lastPathComponent)` per admitted URL and publish it immediately. Reject duplicate `sourceIdentity`, stop after 10 total ready+staging items, call `try await attachmentStore.stageFile(url, id: staging.id, conversationID: attachmentConversationID)`, and retain valid siblings when another throws. Remove each staging row when its file succeeds or fails. If adding an image would put `pendingAttachments.filter(kind == .image).sum(byteCount)` above 20 MB, immediately `removePending([newAttachment])` and append a filename-specific issue. Guard every publication with captured `attachmentGeneration`; stale or user-cancelled successful outputs are deleted.

Implement clipboard staging through the same publication/limit helper. `removePendingAttachment` handles both ready and staging IDs: it synchronously removes the row, records a staging ID in `cancelledAttachmentIDs`, and asynchronously deletes any ready copy; when a cancelled staging call returns, delete its new copy instead of publishing it. `isStagingAttachments` is derived from `!stagingAttachments.isEmpty || isRehomingAttachments`. `clearAttachmentIssues` empties the inline list.

Refactor conversation reset into an explicit attachment policy:

```swift
private enum PendingAttachmentReset { case discard, preserveAndRehome }
private func resetConversationState(attachments policy: PendingAttachmentReset) {
    let captured = pendingAttachments
    attachmentTask?.cancel()
    attachmentGeneration += 1
    attachmentConversationID = UUID()
    provider.cancel()
    generation += 1
    conversationEpoch += 1
    transcript.reset()
    toolDetails.removeAll()
    renderLog.removeAll()
    renderSeq = 0
    isResponding = false
    statusText = nil
    busyElsewhere = false
    pendingApprovals.removeAll()
    stagedSelection = nil
    resolvedModel = nil

    switch policy {
    case .discard:
        pendingAttachments.removeAll()
        stagingAttachments.removeAll()
        cancelledAttachmentIDs.removeAll()
        attachmentIssues.removeAll()
        isRehomingAttachments = false
        Task { await attachmentStore.removePending(captured) }
    case .preserveAndRehome:
        guard !captured.isEmpty else { isRehomingAttachments = false; return }
        isRehomingAttachments = true
        let token = attachmentGeneration
        let destination = attachmentConversationID
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let moved = try await attachmentStore.rehomePending(captured, to: destination)
                guard token == attachmentGeneration else {
                    await attachmentStore.removePending(moved)
                    return
                }
                pendingAttachments = moved
            } catch {
                attachmentIssues = [ChatAttachmentIssue(
                    displayName: "Attachments", message: error.localizedDescription)]
            }
            if token == attachmentGeneration { isRehomingAttachments = false }
        }
    }
}
```

`newConversation()` and history resume use `.discard`; `switchProvider` uses `.preserveAndRehome`. Both bump `attachmentGeneration` and rotate `attachmentConversationID`; the switch sets `isStagingAttachments` until `rehomePending` returns, while explicit new conversation clears immediately and deletes captured files. Add `guard !isStagingAttachments` to `switchProvider`; the UI disables the provider picker during staging, so a half-decoded image is never lost during a switch.

- [ ] **Step 4: Implement gate-safe composition and rendering**

Replace the text-only guard/composition in `send`:

```swift
let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
guard canSend(draft: text) else { return }
let attachments = pendingAttachments
let visible = composeVisibleUserMessage(text)
let base = visible.isEmpty ? "Inspect the attached files." : visible
let providerPrompt = AssistantAttachmentManifest.providerPrompt(
    base: base, visibleText: visible, attachments: attachments)
let request = AgentTurnRequest(
    workspaceURL: workspaceURL, resumeSessionID: resumeID,
    prompt: providerPrompt, attachments: attachments,
    seed: seedSent ? nil : AssistantContext.seed(for: reference),
    webAccess: webAccess, codexSandbox: codexSandbox,
    modelOverride: modelOverride, effortOverride: effortOverride)
```

Only after `gate.tryAcquire` and generation checks succeed:

```swift
let payload = ChatUserMessagePayload(
    body: visible,
    attachments: attachments.map { $0.presentation })
self.renderUserMessage(payload)
self.pendingAttachments.removeAll()
self.attachmentIssues.removeAll()
```

Change `renderUserMessage` to call the structured sink and append `ChatRenderMessage(role:.user, body:payload.body, attachments:payload.attachments, seq:)`. A gate refusal leaves the pending arrays untouched. Keep text-only turns byte-for-byte compatible.

Run: `swift test --filter RubienTests.ChatSessionControllerTests`

Expected: all controller tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/AgentProvider.swift Sources/Rubien/Assistant/ChatSessionController.swift Tests/RubienTests/ChatSessionControllerTests.swift
git commit -m "feat(assistant): manage attachment turns"
```

---

### Task 6: Provider-native Claude and Codex image inputs

**Files:**
- Modify: `Sources/Rubien/Assistant/AgentProvider.swift`
- Modify: `Sources/Rubien/Assistant/ClaudeStreamParser.swift`
- Modify: `Sources/Rubien/Assistant/ClaudeCodeProvider.swift`
- Modify: `Sources/Rubien/Assistant/CodexAppServerProtocol.swift`
- Modify: `Sources/Rubien/Assistant/CodexProvider.swift`
- Modify: `Tests/RubienTests/ClaudeStreamParserTests.swift`
- Modify: `Tests/RubienTests/ClaudeCodeProviderTests.swift`
- Modify: `Tests/RubienTests/CodexAppServerProtocolTests.swift`
- Modify: `Tests/RubienTests/Fixtures/fake-claude.py`

**Interfaces:**
- Consumes: `ChatAttachment` snapshots from Task 5.
- Produces:
  ```swift
  // AgentTurnRequest:
  let attachments: [ChatAttachment] // default [] in initializer
  struct ClaudeImageInput: Sendable, Equatable { let mediaType: String; let base64Data: String }
  static func ClaudeControlProtocol.userMessage(prompt: String,
                                                 images: [ClaudeImageInput]) -> String
  static func CodexAppServerProtocol.turnStart(requestID: Int, threadId: String,
                                                prompt: String, imagePaths: [String],
                                                effort: String?) -> String
  ```

- [ ] **Step 1: Write failing wire-codec tests**

Add to `ClaudeStreamParserTests`:

```swift
func testUserMessagePlacesImagesBeforeText() throws {
    let line = ClaudeControlProtocol.userMessage(
        prompt: "What is shown?",
        images: [ClaudeImageInput(mediaType: "image/png", base64Data: "AA==")])
    let obj = try decode(line)
    let message = try XCTUnwrap(obj["message"] as? [String: Any])
    let content = try XCTUnwrap(message["content"] as? [[String: Any]])
    XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
    XCTAssertEqual((content[0]["source"] as? [String: Any])?["media_type"] as? String,
                   "image/png")
    XCTAssertEqual(content[1]["text"] as? String, "What is shown?")
}
```

Replace/extend the Codex turn-start test:

```swift
func testTurnStartCarriesTextThenLocalImagesAndEffort() {
    let obj = json(CodexAppServerProtocol.turnStart(
        requestID: 3, threadId: "t", prompt: "hi",
        imagePaths: ["/ws/a.png", "/ws/b.jpg"], effort: "medium"))
    let input = ((obj["params"] as? [String: Any])?["input"] as? [[String: Any]]) ?? []
    XCTAssertEqual(input.map { $0["type"] as? String }, ["text", "localImage", "localImage"])
    XCTAssertEqual(input[1]["path"] as? String, "/ws/a.png")
}
```

- [ ] **Step 2: Run codec tests and confirm red**

Run: `swift test --filter RubienTests.ClaudeStreamParserTests`

Run: `swift test --filter RubienTests.CodexAppServerProtocolTests`

Expected: compile failures for the new image arguments/types.

- [ ] **Step 3: Implement provider errors and wire codecs**

Task 5 already added `AgentTurnRequest.attachments`. Add `AgentProviderError.attachmentUnreadable(String)` plus a `LocalizedError` message built with the associated filename: `"The attachment \(name) could not be read before sending."`.

Encode Claude content blocks exactly:

```swift
static func userMessage(prompt: String, images: [ClaudeImageInput] = []) -> String {
    let imageBlocks: [[String: Any]] = images.map {
        ["type": "image", "source": ["type": "base64",
          "media_type": $0.mediaType, "data": $0.base64Data]]
    }
    return encode([
        "type": "user", "session_id": "",
        "message": ["role": "user",
                    "content": imageBlocks + [["type": "text", "text": prompt]]],
        "parent_tool_use_id": NSNull(),
    ])
}
```

Before `ClaudeTurnEngine` spawns the process, read every image staged URL, validate media type is PNG/JPEG, base64-encode it, and build the final user-message line. On read failure, finish the stream with `.attachmentUnreadable(displayName)` and do not spawn/write any bytes. After spawn, write the prebuilt line.

Codex `turnStart` builds text first and appends `imagePaths.map { ["type":"localImage", "path":$0] }`; `CodexProvider` passes only `request.attachments` whose kind is `.image`, in user order.

- [ ] **Step 4: Add fake-provider payload assertions and run green**

Extend `fake-claude.py` to write the received `type:"user"` object to `fake-claude-user.json`. Add a provider test that stages a tiny PNG, sends it, reads that JSON, and asserts the first content block is the expected base64 image and the last is text. Extend the existing fake Codex observed-request assertion to verify `localImage` input paths.

Run: `swift test --filter RubienTests.ClaudeStreamParserTests`

Run: `swift test --filter RubienTests.ClaudeCodeProviderTests`

Run: `swift test --filter RubienTests.CodexAppServerProtocolTests`

Run: `swift test --filter RubienTests.CodexProviderTests`

Expected: all four suites pass without a live provider request.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/AgentProvider.swift Sources/Rubien/Assistant/ClaudeStreamParser.swift Sources/Rubien/Assistant/ClaudeCodeProvider.swift Sources/Rubien/Assistant/CodexAppServerProtocol.swift Sources/Rubien/Assistant/CodexProvider.swift Tests/RubienTests/ClaudeStreamParserTests.swift Tests/RubienTests/ClaudeCodeProviderTests.swift Tests/RubienTests/CodexAppServerProtocolTests.swift Tests/RubienTests/CodexProviderTests.swift Tests/RubienTests/Fixtures/fake-claude.py
git commit -m "feat(assistant): send native image inputs"
```

---

### Task 7: Provider-owned history reconstruction

**Files:**
- Modify: `Sources/Rubien/Assistant/ClaudeSessionStore.swift`
- Modify: `Sources/Rubien/Assistant/CodexAppServerProtocol.swift`
- Modify: `Sources/Rubien/Assistant/CodexProvider.swift`
- Modify: `Tests/RubienTests/ClaudeSessionStoreTests.swift`
- Modify: `Tests/RubienTests/CodexAppServerProtocolTests.swift`

**Interfaces:**
- Consumes: Task 1 manifest parser and Task 4 `ChatRenderMessage.attachments`.
- Produces:
  ```swift
  static func CodexAppServerProtocol.decodeThreadTranscript(
      _ result: [String: Any], managedAttachmentsRoot: URL? = nil
  ) -> [ChatRenderMessage]
  ```

- [ ] **Step 1: Write failing Claude/Codex history tests**

For Claude, create a real staged file under `workspace/.rubien/attachments/<UUID>/`, build a provider prompt with `AssistantAttachmentManifest.providerPrompt`, JSON-encode it into a user content block, then assert:

```swift
let rows = store.fullTranscript(sessionID: "attached", workspaceURL: workspace)
XCTAssertEqual(rows.first?.role, .user)
XCTAssertEqual(rows.first?.body, "Compare these")
XCTAssertEqual(rows.first?.attachments.map(\.displayName), ["notes.md"])
XCTAssertFalse(rows.first?.body.contains("rubien-attachments-v1") == true)
XCTAssertEqual(store.summarize(fileURL: sessionURL,
                               expectedCWD: workspace.path)?.preview,
               "Compare these")
```

Add a second attachment-only case whose history summary is `"Attached: figure.png"`, while its transcript row body stays empty and contains the image presentation.

For Codex, add:

```swift
func testHistoryManifestRestoresAttachmentAndHidesInternalPrompt() throws {
    let workspace = temporaryWorkspace()
    let attachment = try makeStagedAttachment(in: workspace, name: "figure.png")
    let prompt = AssistantAttachmentManifest.providerPrompt(
        base: "Inspect the attached files.", visibleText: "", attachments: [attachment])
    let result: [String: Any] = ["thread": ["turns": [["items": [[
        "type": "userMessage", "content": [
            ["type": "text", "text": prompt],
            ["type": "localImage", "path": attachment.stagedURL.path],
        ]
    ]]]]]]
    let rows = CodexAppServerProtocol.decodeThreadTranscript(
        result, managedAttachmentsRoot: workspace
            .appendingPathComponent(AssistantAttachmentStore.relativeRoot))
    XCTAssertEqual(rows.first?.body, "")
    XCTAssertEqual(rows.first?.attachments.map(\.displayName), ["figure.png"])
}
```

Also assert a deleted path yields `isAvailable == false`, and an invalid/outside-root manifest remains visible text.

- [ ] **Step 2: Run tests and confirm red**

Run: `swift test --filter RubienTests.ClaudeSessionStoreTests`

Run: `swift test --filter RubienTests.CodexAppServerProtocolTests`

Expected: tests fail because history currently joins text and discards non-text metadata.

- [ ] **Step 3: Implement shared history parsing**

In `ClaudeSessionStore.fullTranscript`, parse only user text through the manifest and append attachments:

```swift
let root = workspaceURL.appendingPathComponent(AssistantAttachmentStore.relativeRoot)
if let text = Self.messageText(entry.message) {
    let parsed = AssistantAttachmentManifest.parse(text, managedRoot: root,
                                                   fileManager: fileManager)
    rows.append(ChatRenderMessage(role: .user, body: parsed.visibleText,
                                  attachments: parsed.attachments, seq: rows.count))
}
```

Thread `managedRoot` through `summarize`, `firstUserText`, `firstMatchSnippet`, and search. Preview/search text uses `parsed.visibleText` when nonempty; for an attachment-only row use `"Attached: " + parsed.attachments.map(\.displayName).joined(separator: ", ")`. Assistant messages keep their existing text-only behavior.

In Codex transcript decoding, join text blocks, parse the result only when a root is supplied, and create a user row when either visible text or parsed attachments is nonempty. Preserve the default `nil` argument so existing codec tests remain source-compatible. `CodexProvider.readTranscript` supplies the workspace managed root.

- [ ] **Step 4: Run tests and confirm green**

Run: `swift test --filter RubienTests.ClaudeSessionStoreTests`

Run: `swift test --filter RubienTests.CodexAppServerProtocolTests`

Run: `swift test --filter RubienTests.CodexProviderTests`

Expected: all suites pass; previews/search contain no manifest paths.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/ClaudeSessionStore.swift Sources/Rubien/Assistant/CodexAppServerProtocol.swift Sources/Rubien/Assistant/CodexProvider.swift Tests/RubienTests/ClaudeSessionStoreTests.swift Tests/RubienTests/CodexAppServerProtocolTests.swift Tests/RubienTests/CodexProviderTests.swift
git commit -m "feat(assistant): restore attachments from history"
```

---

### Task 8: Composer picker, chips, drag/drop, and paste

**Files:**
- Modify: `Sources/Rubien/Assistant/ChatSidebarView.swift`
- Modify: `Sources/Rubien/Assistant/ChatSidebarHarness.swift`
- Test: `Tests/RubienTests/ChatSessionControllerTests.swift`

**Interfaces:**
- Consumes: Task 5 controller API and staged thumbnail data URLs.
- Produces: complete user-facing attachment UX in both PDF and web readers through their shared `ChatSidebarView`.

- [ ] **Step 1: Add failing send-eligibility tests**

Add controller tests for the pure decisions the SwiftUI view relies on:

```swift
func testCanSendRequiresReadyContentAndNoStaging() async throws {
    let (controller, _, _, source) = try makeAttachmentController()
    XCTAssertFalse(controller.canSend(draft: "   "))
    XCTAssertTrue(controller.canSend(draft: "hello"))
    controller.stageAttachments([source])
    XCTAssertFalse(controller.canSend(draft: "hello"), "staging blocks an accidental partial send")
    await waitUntil { !controller.isStagingAttachments }
    XCTAssertTrue(controller.canSend(draft: ""), "ready attachment permits attachment-only send")
}

func testRemovingPendingAttachmentDeletesItAndDisablesEmptySend() async throws {
    let (controller, _, _, source) = try makeAttachmentController()
    controller.stageAttachments([source])
    await waitUntil { !controller.isStagingAttachments }
    let pending = try XCTUnwrap(controller.pendingAttachments.first)
    controller.removePendingAttachment(id: pending.id)
    await waitUntil { !FileManager.default.fileExists(atPath: pending.stagedURL.path) }
    XCTAssertFalse(controller.canSend(draft: ""))
}
```

- [ ] **Step 2: Run tests and confirm baseline behavior**

Run: `swift test --filter RubienTests.ChatSessionControllerTests`

Expected: tests pass if Task 5 is correct; if either fails, fix controller semantics before adding UI.

- [ ] **Step 3: Enable picker and add native pending tray**

Import `UniformTypeIdentifiers`. Replace the disabled menu button:

```swift
Button(action: chooseAttachments) {
    Label("Add files or photos", systemImage: "paperclip")
}
```

Implement the picker with no Photos-library permission:

```swift
private func chooseAttachments() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [
        .image,
        UTType(filenameExtension: "md")!,
        UTType(filenameExtension: "markdown")!,
        UTType(filenameExtension: "txt")!,
    ]
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    guard panel.runModal() == .OK else { return }
    session.stageAttachments(panel.urls)
}
```

Inside `composerBox`, above `composerEditor`, render `pendingAttachmentTray` when staging, attachments, or issues exist. Render every `session.stagingAttachments` entry immediately with its filename, a `ProgressView`, and a remove button that calls `removePendingAttachment(id:)`. Each ready chip uses a 28 pt thumbnail when `thumbnailDataURL` decodes, otherwise `photo`/`doc.text`; includes filename, `ByteCountFormatter`, and a remove button whose label is `"Remove \(attachment.displayName)"`. Show issues in an inline secondary/red row with a dismiss button.

- [ ] **Step 4: Add drop/paste and unify send conditions**

Use the macOS-15-compatible `dropDestination(for:action:isTargeted:)` overload on `composerBox`:

```swift
.dropDestination(for: URL.self) { urls, _ in
    session.stageAttachments(urls)
    return !urls.isEmpty
} isTargeted: { isDropTargeted = $0 }
```

Use `onPasteCommand(of: [.fileURL, .image])` on the composer. Normal text paste remains owned by `TextEditor` because plain text is not in the supported types. Route providers with this helper:

```swift
private func handlePaste(_ providers: [NSItemProvider]) {
    for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url = (item as? URL)
                    ?? (item as? NSURL).map { $0 as URL }
                    ?? (item as? Data).map {
                        NSURL(absoluteURLWithDataRepresentation: $0, relativeTo: nil) as URL
                    }
                guard let url else { return }
                Task { @MainActor in session.stageAttachments([url]) }
            }
            continue
        }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { continue }
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                session.stagePastedImage(data, suggestedName: "Pasted Image.png")
            }
        }
    }
}
```

Replace both button and ⌘↩ guards with `session.canSend(draft: draft)`. `sendDraft` clears `draft` only after that guard succeeds; attachment clearing remains controller-owned after gate admission. Disable `providerPicker` while `session.isStagingAttachments` as well as while responding. Add a visible drop-target stroke and help text `"Add images, Markdown, or text files"`.

Update `ChatSidebarHarness` with one staged text and image preview scenario so manual QA can inspect light/dark layout without a live provider.

- [ ] **Step 5: Build, test, and commit**

Run: `swift test --filter RubienTests.ChatSessionControllerTests`

Run: `swift build`

Expected: tests pass and app target builds without availability or strict-concurrency errors.

```bash
git add Sources/Rubien/Assistant/ChatSidebarView.swift Sources/Rubien/Assistant/ChatSidebarHarness.swift Tests/RubienTests/ChatSessionControllerTests.swift
git commit -m "feat(assistant): add attachment composer UX"
```

---

### Task 9: Full verification, independent review, and cleanup

**Files:**
- Modify only files implicated by failing verification or accepted review findings.

**Interfaces:**
- Consumes: complete Tasks 1–8 feature.
- Produces: verified, reviewed branch ready for integration.

- [ ] **Step 1: Run the complete focused verification matrix**

```bash
swift test --filter RubienTests.AssistantAttachmentManifestTests
swift test --filter RubienTests.AssistantAttachmentStoreTests
swift test --filter RubienTests.ChatTranscriptJSTests
swift test --filter RubienTests.ChatSessionControllerTests
swift test --filter RubienTests.ClaudeStreamParserTests
swift test --filter RubienTests.ClaudeCodeProviderTests
swift test --filter RubienTests.CodexAppServerProtocolTests
swift test --filter RubienTests.CodexProviderTests
```

Expected: every command exits 0.

Run from `scripts/chat-renderer`:

```bash
npm run build
npm test
```

Expected: build succeeds; all Node tests pass; `git diff --exit-code Sources/Rubien/Resources/ChatTranscript.html` shows the committed artifact is current.

- [ ] **Step 2: Run project-level verification**

Run: `swift build`

Run: `swift test --filter RubienTests`

Expected: build succeeds and the full app-level test target passes with zero failures. Do not use a CommandLineTools-only toolchain; `xcode-select -p` must point at full Xcode.

- [ ] **Step 3: Manual QA in both shared-sidebar hosts**

Use the DEBUG harness, one PDF reader, and one web reader. Verify: picker filters; multi-select partial success; Finder drop; clipboard image; attachment-only send; text+attachment; removal; duplicate rejection; 10/20 MB limits; gate refusal retention; provider switch rehome; explicit New Conversation deletion; sidebar close/reopen replay; history resume; missing-file state; light/dark; VoiceOver labels; keyboard-only removal and ⌘↩.

- [ ] **Step 4: Independent review and simplify sweep**

Following `AGENTS.md`, ask `codex-rescue` to review the cumulative attachment change (`git diff 06e8edf..HEAD`) and return findings inline. For a large diff, launch the companion in background at `--effort medium`, never pass `--model`, and poll/cancel per the repository review foot-guns. Then run `/simplify` as three parallel reviews for reuse, quality, and efficiency. Record each finding and explicitly accept or reject it on technical merit.

Fix accepted findings with new regression tests first, rerun the focused test that demonstrates each fix, then rerun Step 2. Do not change behavior merely to satisfy stylistic comments.

- [ ] **Step 5: Commit review fixes, or record a clean review**

If fixes were required:

```bash
git add Sources/Rubien/Assistant/AssistantAttachments.swift Sources/Rubien/Assistant/AssistantAttachmentStore.swift Sources/Rubien/Assistant/AssistantImageNormalizer.swift Sources/Rubien/Assistant/AgentProvider.swift Sources/Rubien/Assistant/ChatSessionController.swift Sources/Rubien/Assistant/ChatSidebarView.swift Sources/Rubien/Assistant/ChatSidebarHarness.swift Sources/Rubien/Assistant/ChatTranscriptModels.swift Sources/Rubien/Assistant/ChatTranscriptJS.swift Sources/Rubien/Assistant/ChatTranscriptController.swift Sources/Rubien/Assistant/ClaudeStreamParser.swift Sources/Rubien/Assistant/ClaudeCodeProvider.swift Sources/Rubien/Assistant/CodexAppServerProtocol.swift Sources/Rubien/Assistant/CodexProvider.swift Sources/Rubien/Assistant/ClaudeSessionStore.swift Tests/RubienTests/AssistantAttachmentManifestTests.swift Tests/RubienTests/AssistantAttachmentStoreTests.swift Tests/RubienTests/ChatTranscriptJSTests.swift Tests/RubienTests/ChatSessionControllerTests.swift Tests/RubienTests/ClaudeStreamParserTests.swift Tests/RubienTests/ClaudeCodeProviderTests.swift Tests/RubienTests/CodexAppServerProtocolTests.swift Tests/RubienTests/CodexProviderTests.swift Tests/RubienTests/ClaudeSessionStoreTests.swift Tests/RubienTests/Fixtures/fake-claude.py scripts/chat-renderer/src/chat.js scripts/chat-renderer/src/chat.css scripts/chat-renderer/test/integration.test.js Sources/Rubien/Resources/ChatTranscript.html
git commit -m "fix(assistant): address attachment review findings"
```

If no fixes were required, create no empty commit. Confirm `git status --short` contains only the user's pre-existing unrelated files and `git log -9 --oneline` shows the coherent task commits.

---

## Completion Checklist

- [ ] Picker, Finder drop, image/file paste, pending chips, and attachment-only sends work.
- [ ] Text files remain path-backed; images are normalized and sent natively to both providers.
- [ ] Gate refusal preserves pending attachments; explicit New Conversation deletes them; provider switch rehomes them.
- [ ] Live transcript/replay/history show safe presentation metadata and never absolute paths or synthetic prompt text.
- [ ] Missing historical files show **File unavailable**.
- [ ] Limits and partial-success errors are enforced locally.
- [ ] No database, sync, or CLI contract changed.
- [ ] Swift, Node, project-level tests, manual QA, codex-rescue, and simplify sweep are complete.
